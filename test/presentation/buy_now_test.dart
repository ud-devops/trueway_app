/// "Buy now" buys one thing, and leaves the basket alone.
///
/// The client's requirement, in one sentence: tapping Buy now goes to checkout
/// with **that product only**, and whatever the customer had already added to
/// their basket is neither carried along nor wiped out.
///
/// Both halves needed the same thing — a second cart. This backend mints one on
/// request (`POST /cart` with no id returns a fresh uuid,
/// `CartController::store`, verified live), so the shortcut checks out a
/// throwaway cart of its own while the basket sits untouched under its own id
/// and its own rebuild mirror.
///
/// The earlier attempt kept one cart and remembered which line the last Buy now
/// had added, removing it on the next tap. That fixed Buy-now-then-Buy-now, but
/// it could never satisfy the first half of the requirement: anything added
/// with "Add to cart" still turned up on the checkout screen.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/data/models/server_cart.dart';
import 'package:trueway_farms/data/repositories/cart_repository.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/server_cart_provider.dart';

import '../support/fake_cart_repository.dart';

const _honey = 118;
const _ghee = 121;
const _wheat = 130;

/// Two carts behind one repository, addressed by id — which is what the server
/// does. The shared [FakeCartRepository] keeps one basket, so it cannot show
/// the thing these tests are about: that writes to one cart do not reach the
/// other.
class _TwoCarts implements CartRepository {
  _TwoCarts({List<FakeCartLine> basket = const []})
      : basket = FakeCartRepository(cartId: 'cart-basket', lines: basket),
        buyNow = FakeCartRepository(cartId: 'cart-buy-now-1');

  final FakeCartRepository basket;

  /// Replaced on every [createCart] — see there.
  FakeCartRepository buyNow;

  int _minted = 1;

  FakeCartRepository _of(String cartId) =>
      cartId == basket.cartId ? basket : buyNow;

  /// Mints a **new, empty** cart, which is what the server does.
  ///
  /// `POST /cart` with no id runs `$identifier = $id ?: Str::uuid()` and
  /// restores against that fresh identifier, so the cart it returns holds only
  /// what this call put in it. Modelling it as "add to the cart already there"
  /// hid the whole point of `startBuyNow` — that abandoning the id is enough to
  /// leave the previous product behind — and made two Buy nows look like they
  /// stacked.
  ///
  /// Only ever reached by an instance holding no id, which after
  /// [ServerCartNotifier.forget] is the buy-now one.
  @override
  Future<CartMutationResult> createCart({
    required int productId,
    int qty = 1,
  }) {
    _minted++;
    buyNow = FakeCartRepository(cartId: 'cart-buy-now-$_minted');
    return buyNow.createCart(productId: productId, qty: qty);
  }

  @override
  Future<ServerCart> fetch(String cartId) => _of(cartId).fetch(cartId);

  @override
  Future<CartMutationResult> addItem({
    required String cartId,
    required int productId,
    int qty = 1,
  }) =>
      _of(cartId).addItem(cartId: cartId, productId: productId, qty: qty);

  @override
  Future<CartMutationResult> setQuantity({
    required String cartId,
    required CartLineId line,
    required int qty,
  }) =>
      _of(cartId).setQuantity(cartId: cartId, line: line, qty: qty);

  @override
  Future<CartMutationResult> removeItem({
    required String cartId,
    required CartLineId line,
  }) =>
      _of(cartId).removeItem(cartId: cartId, line: line);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<({ProviderContainer container, _TwoCarts repo})> _app({
  List<FakeCartLine> basket = const [],
}) async {
  final repo = _TwoCarts(basket: basket);

  // Only the basket's id is persisted. The buy-now cart has none until a Buy
  // now creates one, which is exactly the state a fresh install is in.
  SharedPreferences.setMockInitialValues(
    basket.isEmpty ? {} : {'server_cart_id_v1': repo.basket.cartId},
  );
  final prefs = await SharedPreferences.getInstance();

  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      cartRepositoryProvider.overrideWithValue(repo),
      isAuthenticatedProvider.overrideWithValue(true),
    ],
  );
  addTearDown(container.dispose);

  if (basket.isNotEmpty) {
    await container.read(serverCartProvider.notifier).refresh();
  }
  return (container: container, repo: repo);
}

List<int> _ids(ServerCartState state) =>
    [for (final item in state.cart?.items ?? const []) item.lineId.value];

void main() {
  group('the basket is left alone', () {
    test('what the customer added stays in it, untouched', () async {
      // The half the single-cart version could never satisfy.
      final (:container, :repo) = await _app(
        basket: const [
          FakeCartLine(id: _wheat, name: 'Wheat', quantity: 2, unitPrice: 900),
        ],
      );

      await container.read(buyNowCartProvider.notifier).startBuyNow(_honey);

      expect(_ids(container.read(serverCartProvider)), [_wheat]);
      expect(container.read(serverCartProvider).quantityOfProduct(_wheat), 2);
      expect(
        repo.basket.calls.where((c) => c.startsWith('removeItem')),
        isEmpty,
        reason: 'nothing was taken out of the basket',
      );
    });

    test('and the Buy-now product does not join it', () async {
      final container = (await _app(
        basket: const [
          FakeCartLine(id: _wheat, name: 'Wheat', quantity: 2, unitPrice: 900),
        ],
      )).container;

      await container.read(buyNowCartProvider.notifier).startBuyNow(_honey);

      expect(
        _ids(container.read(serverCartProvider)),
        isNot(contains(_honey)),
      );
    });
  });

  group('the Buy-now cart holds one thing', () {
    test('exactly the product tapped, one unit', () async {
      final container = (await _app()).container;

      expect(
        await container.read(buyNowCartProvider.notifier).startBuyNow(_honey),
        isNull,
      );

      final state = container.read(buyNowCartProvider);
      expect(_ids(state), [_honey]);
      expect(state.quantityOfProduct(_honey), 1);
    });

    test('a second Buy now replaces the first', () async {
      // Two taps used to stack two products on the checkout screen. The cart is
      // abandoned and rebuilt rather than edited, so there is nothing to stack.
      final container = (await _app()).container;
      final buyNow = container.read(buyNowCartProvider.notifier);

      await buyNow.startBuyNow(_honey);
      await buyNow.startBuyNow(_ghee);

      expect(_ids(container.read(buyNowCartProvider)), [_ghee]);
    });

    test('it is a different server cart from the basket', () async {
      final (:container, :repo) = await _app(
        basket: const [
          FakeCartLine(id: _wheat, name: 'Wheat', quantity: 1, unitPrice: 900),
        ],
      );

      await container.read(buyNowCartProvider.notifier).startBuyNow(_honey);

      expect(container.read(serverCartProvider).cart!.id, repo.basket.cartId);
      expect(container.read(buyNowCartProvider).cart!.id, repo.buyNow.cartId);
      expect(repo.buyNow.cartId, isNot(repo.basket.cartId));
    });
  });

  group('checkout spends the cart it was opened for', () {
    test('the flag routes the bill to the Buy-now cart', () async {
      final container = (await _app(
        basket: const [
          FakeCartLine(id: _wheat, name: 'Wheat', quantity: 2, unitPrice: 900),
        ],
      )).container;
      await container.read(buyNowCartProvider.notifier).startBuyNow(_honey);

      container.read(checkoutCartProvider.notifier).state = CheckoutCart.buyNow;
      expect(_ids(container.read(activeCartProvider)), [_honey]);

      container.read(checkoutCartProvider.notifier).state = CheckoutCart.basket;
      expect(_ids(container.read(activeCartProvider)), [_wheat]);
    });

    test('it defaults to the basket', () async {
      // Every other way into checkout — the cart tab's button — must land on
      // the basket without setting anything.
      final container = (await _app(
        basket: const [
          FakeCartLine(id: _wheat, name: 'Wheat', quantity: 1, unitPrice: 900),
        ],
      )).container;

      expect(container.read(checkoutCartProvider), CheckoutCart.basket);
      expect(_ids(container.read(activeCartProvider)), [_wheat]);
    });

    test('a paid Buy-now order forgets its own cart, not the basket',
        () async {
      // What `forget()` clears is the cart id and the rebuild mirror. Pointed
      // at the basket after a Buy-now order, it would throw away the handle to
      // shopping the customer never checked out.
      final container = (await _app(
        basket: const [
          FakeCartLine(id: _wheat, name: 'Wheat', quantity: 2, unitPrice: 900),
        ],
      )).container;
      await container.read(buyNowCartProvider.notifier).startBuyNow(_honey);
      container.read(checkoutCartProvider.notifier).state = CheckoutCart.buyNow;

      await container.read(activeCartNotifierProvider).forget();

      expect(container.read(buyNowCartProvider).cart, isNull);
      expect(_ids(container.read(serverCartProvider)), [_wheat]);
    });
  });

  group('going back to the basket', () {
    test('the Checkout button puts the flag back, however it was left',
        () async {
      // The bug this pins, in the customer's own words: "cart have 9 items,
      // I Buy now one product, then I open the cart and press Checkout and it
      // shows the single item."
      //
      // The flag was being reset from lifecycle callbacks. Both were dead. The
      // cart screen's `initState` runs once in the app's lifetime — the tabs
      // live in an `IndexedStack`, so returning to the Cart tab rebuilds
      // nothing — and the checkout screen's `dispose` wrote to a provider
      // during teardown. So the flag stayed on `buyNow` and every later
      // checkout spent the throwaway cart.
      //
      // It is set at the two navigation points now, which is what this asserts:
      // whatever the flag was, pressing Checkout in the basket makes it the
      // basket.
      final container = (await _app(
        basket: const [
          FakeCartLine(id: _wheat, name: 'Wheat', quantity: 9, unitPrice: 900),
        ],
      )).container;
      await container.read(buyNowCartProvider.notifier).startBuyNow(_honey);
      container.read(checkoutCartProvider.notifier).state = CheckoutCart.buyNow;

      // Buy now really did narrow it to the one product...
      expect(_ids(container.read(activeCartProvider)), [_honey]);

      // ...and the basket's own button widens it back.
      container.read(checkoutCartProvider.notifier).state = CheckoutCart.basket;

      expect(_ids(container.read(activeCartProvider)), [_wheat]);
      expect(
        container.read(activeCartProvider).quantityOfProduct(_wheat),
        9,
        reason: 'all nine, not the one bought a moment ago',
      );
    });

    test('and the Buy-now cart is still there to go back to', () async {
      // Switching the flag is not destructive either way — neither cart is
      // touched by being looked away from.
      final container = (await _app(
        basket: const [
          FakeCartLine(id: _wheat, name: 'Wheat', quantity: 9, unitPrice: 900),
        ],
      )).container;
      await container.read(buyNowCartProvider.notifier).startBuyNow(_honey);

      container.read(checkoutCartProvider.notifier).state = CheckoutCart.basket;
      container.read(checkoutCartProvider.notifier).state = CheckoutCart.buyNow;

      expect(_ids(container.read(activeCartProvider)), [_honey]);
    });
  });

  group('the two carts keep their own storage', () {
    test('neither can overwrite the other\'s id or mirror', () async {
      // The single thing that makes two instances of one notifier safe. Shared
      // keys would have the shortcut quietly stamp its own cart id over the
      // basket's, and the basket would be unreachable — the server offers no
      // other way to find it.
      final (:container, :repo) = await _app(
        basket: const [
          FakeCartLine(id: _wheat, name: 'Wheat', quantity: 1, unitPrice: 900),
        ],
      );

      await container.read(buyNowCartProvider.notifier).startBuyNow(_honey);

      final prefs = container.read(sharedPreferencesProvider);
      expect(prefs.getString('server_cart_id_v1'), repo.basket.cartId);
      expect(
        prefs.getString('server_cart_id_v1_buy_now'),
        repo.buyNow.cartId,
      );
    });
  });
}

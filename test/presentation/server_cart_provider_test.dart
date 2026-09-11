import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/data/models/product_model.dart';
import 'package:trueway_farms/data/models/server_cart.dart';
import 'package:trueway_farms/data/repositories/cart_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/server_cart_provider.dart';

/// The cart notifier, against the backend it actually has to survive.
///
/// `Cart::restore()` deletes the stored cart row as it loads it, and every
/// controller error path returns before `store()` writes it back — so a
/// **refused** mutation destroys the whole basket, not just the line it refused
/// (docs/BACKEND_BUGS.md finding 0). The client cannot fix that. What it can do
/// is never show a basket the server no longer has, and that is what most of
/// this file pins down: after any failure the state is whatever the re-read
/// returned, never what was on screen before.

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

Map<String, dynamic> _cartJson({
  String id = 'cart-1',
  List<Map<String, dynamic>>? items,
}) {
  final lines = items ??
      [
        {
          'id': 118,
          'row_id': 'abc',
          'name': 'Desi Khand',
          'quantity': 2,
          'price': 899,
          'weight': 5100,
        },
      ];
  return {
    'id': id,
    'count': lines.fold<int>(0, (sum, l) => sum + (l['quantity']! as int)),
    'cart_items': lines,
    'raw_sub_total': 1798,
    'discounted_sub_total': 1798,
    'discounted_tax_amount': 89.9,
    'order_total': 1887.9,
  };
}

ServerCart _cart({String id = 'cart-1', List<Map<String, dynamic>>? items}) =>
    ServerCart.fromJson(_cartJson(id: id, items: items));

/// The cart the server is left holding after a refused mutation wiped it.
ServerCart _emptyCart([String id = 'cart-1']) =>
    ServerCart.fromJson(_cartJson(id: id, items: const []));

Product _product({int id = 118}) => Product.fromJson({
      'id': id,
      'slug': 'desi-khand',
      'name': 'Desi Khand',
      'sku': 'TRW3215',
      'price': 899,
      'quantity': 50,
      'is_out_of_stock': false,
    });

ApiException _refusal([String message = 'Maximum quantity is 93!']) =>
    ApiException(message, kind: ApiErrorKind.businessRule, statusCode: 200);

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Records every call and replays whatever each test queued.
///
/// `implements` + [noSuchMethod] so a route this notifier is not supposed to
/// touch throws rather than quietly returning null.
class _FakeCartRepo implements CartRepository {
  final List<String> calls = [];

  /// What [fetch] returns. Throw-able by setting [fetchError].
  ServerCart? cartOnFetch = _cart();
  ApiException? fetchError;

  /// What each mutation returns. Defaults to success with [cartOnFetch].
  CartMutationResult? nextResult;

  /// Holds the *next* cart-minting call open, so a test can land a second
  /// caller while the first is still in flight.
  Completer<void>? gate;

  Future<void> _hold() async {
    final open = gate;
    if (open == null) return;
    gate = null;
    await open.future;
  }

  @override
  Future<ServerCart> fetch(String cartId) async {
    calls.add('fetch($cartId)');
    if (fetchError != null) throw fetchError!;
    return cartOnFetch ?? _cart(id: cartId);
  }

  CartMutationResult _result() =>
      nextResult ?? CartMutationResult(cart: cartOnFetch ?? _cart());

  @override
  Future<CartMutationResult> createCart({
    required int productId,
    int qty = 1,
  }) async {
    calls.add('createCart($productId, $qty)');
    await _hold();
    return _result();
  }

  @override
  Future<CartMutationResult> addItem({
    required String cartId,
    required int productId,
    int qty = 1,
  }) async {
    calls.add('addItem($cartId, $productId, $qty)');
    await _hold();
    return _result();
  }

  @override
  Future<CartMutationResult> setQuantity({
    required String cartId,
    required CartLineId line,
    required int qty,
  }) async {
    calls.add('setQuantity($cartId, ${line.value}, $qty)');
    return _result();
  }

  @override
  Future<CartMutationResult> removeItem({
    required String cartId,
    required CartLineId line,
  }) async {
    calls.add('removeItem($cartId, ${line.value})');
    return _result();
  }

  @override
  Future<CartMutationResult> applyCoupon({
    required String cartId,
    required String code,
  }) async {
    calls.add('applyCoupon($cartId, $code)');
    return _result();
  }

  @override
  Future<CartMutationResult> removeCoupon({required String cartId}) async {
    calls.add('removeCoupon($cartId)');
    return _result();
  }

  /// The recovery the notifier now runs whenever a refusal is found to have
  /// left the cart short of the mirror.
  ///
  /// It has to be here at all because the mirror is no longer written only by a
  /// mutation: a plain read seeds it too, so an ordinary `_host(cartId: …)`
  /// arrives at its first refusal already holding one. The default outcome is
  /// "everything went back", which keeps the tests below about the *refusal*;
  /// the real rebuild is driven over a faked transport in
  /// `cart_rebuild_test.dart`.
  CartRebuildOutcome? nextRebuild;

  @override
  Future<CartRebuildOutcome> rebuild({
    required String cartId,
    required List<CartMirrorLine> lines,
    String? couponCode,
    ServerCart? survivor,
  }) async {
    calls.add('rebuild($cartId, ${lines.length} lines)');
    return nextRebuild ??
        CartRebuildOutcome(
          cart: survivor,
          linesRestored: lines.length,
          couponRestored: couponCode != null,
        );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The mirror as it stands on disk, or null when there is none.
CartMirror? _mirrorOf(_Host h) =>
    CartMirror.tryDecode(h.prefs.getString('server_cart_mirror_v1'));

typedef _Host = ({
  ProviderContainer container,
  _FakeCartRepo repo,
  SharedPreferences prefs,
});

Future<_Host> _host({
  String? cartId,
  String? legacyCart,
  _FakeCartRepo? repo,
}) async {
  SharedPreferences.setMockInitialValues({
    if (cartId != null) 'server_cart_id_v1': cartId,
    if (legacyCart != null) 'cart_items_v1': legacyCart,
  });
  final prefs = await SharedPreferences.getInstance();
  final fake = repo ?? _FakeCartRepo();

  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      cartRepositoryProvider.overrideWithValue(fake),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, repo: fake, prefs: prefs);
}

/// Reads the notifier and lets its constructor-time restore settle.
Future<ServerCartNotifier> _start(_Host h) async {
  final notifier = h.container.read(serverCartProvider.notifier);
  await _settle(h.container);
  return notifier;
}

/// Pumps microtasks until the first load finishes, with a bound so a hang fails
/// the test instead of hanging the suite.
Future<void> _settle(ProviderContainer container) async {
  for (var i = 0; i < 100; i++) {
    if (!container.read(serverCartProvider).loading) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('cart never finished loading');
}

ServerCartState _state(_Host h) => h.container.read(serverCartProvider);

void main() {
  // -------------------------------------------------------------------------
  group('restore', () {
    test('a fresh install makes no request — a cart exists once you add',
        () async {
      final h = await _host();
      await _start(h);

      expect(h.repo.calls, isEmpty);
      expect(_state(h).loading, isFalse);
      expect(_state(h).cart, isNull);
      expect(_state(h).count, 0);
    });

    test('a stored id is read back from the server', () async {
      final h = await _host(cartId: 'cart-1');
      await _start(h);

      expect(h.repo.calls, ['fetch(cart-1)']);
      expect(_state(h).count, 2);
      expect(_state(h).isReady, isTrue);
    });

    // The id, and the mirror the id's cart is rebuilt from. Nothing else — and
    // in particular no cached *contents*: the mirror records what to re-POST
    // (line ids, quantities, the coupon), never prices or stock, both of which
    // would go stale and be found out at payment. Nothing is ever rendered from
    // it; see `_mirrorOf` and the 'the local mirror' group below.
    test('nothing but the id and the rebuild mirror is persisted', () async {
      final h = await _host(cartId: 'cart-1');
      await _start(h);

      expect(
        h.prefs.getKeys().where((k) => k.contains('cart')),
        unorderedEquals(['server_cart_id_v1', 'server_cart_mirror_v1']),
      );
      final encoded = h.prefs.getString('server_cart_mirror_v1')!;
      for (final priced in ['price', 'raw_sub_total', 'order_total', '899']) {
        expect(encoded, isNot(contains(priced)));
      }
    });

    test('an unreadable cart is unknown, not empty', () async {
      final repo = _FakeCartRepo()..fetchError = _refusal('Server error');
      final h = await _host(cartId: 'cart-1', repo: repo);
      await _start(h);

      expect(_state(h).contentsUnknown, isTrue);
      expect(_state(h).cart, isNull);
      expect(_state(h).error, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  group('the local mirror', () {
    // The mirror is what a wiped cart is rebuilt from, and it used to be
    // written *only* after a successful mutation. That left every install
    // upgrading with a `server_cart_id_v1` already in prefs holding no mirror
    // at all — so its very first refusal had nothing to rebuild from and the
    // basket was gone for real, which is the one outcome the mirror exists to
    // prevent. A read seeds it.
    test('is seeded from a read, so an upgraded install is covered at once',
        () async {
      final h = await _host(cartId: 'cart-1');
      await _start(h);

      final mirror = _mirrorOf(h)!;
      expect(mirror.cartId, 'cart-1');
      expect(mirror.lines.map((l) => l.productId), [118]);
      expect(mirror.lines.map((l) => l.qty), [2]);
    });

    // The seed is the whole point: without it this refusal would find no
    // mirror, skip the rebuild, and leave the customer with the empty cart the
    // server was left holding.
    test('the seeded mirror is what the first refusal rebuilds from', () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      h.repo.calls.clear();
      h.repo.nextResult = CartMutationResult(
        cart: _emptyCart(),
        error: _refusal(),
      );

      await notifier.add(_product());

      expect(h.repo.calls, [
        'addItem(cart-1, 118, 1)',
        'rebuild(cart-1, 1 lines)',
      ]);
      expect(_state(h).wasRebuilt, isTrue);
    });

    // A wipe and an honestly-emptied cart are the same GET, so a read is
    // allowed to *widen* the mirror and never to shrink it. Adopting this one
    // would throw away the only record of what to put back.
    test('a read that comes back empty cannot empty the mirror', () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      expect(_mirrorOf(h)!.lines, hasLength(1));

      h.repo.cartOnFetch = _emptyCart();
      await notifier.refresh();

      expect(_state(h).isEmpty, isTrue, reason: 'the screen tells the truth');
      expect(_mirrorOf(h)!.lines.map((l) => l.productId), [118],
          reason: 'the mirror still knows what to put back',);
    });

    test('a read that comes back short keeps the line it did not mention',
        () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);

      h.repo.cartOnFetch = _cart(items: [
        {'id': 121, 'row_id': 'v', 'name': 'Wheat', 'quantity': 1, 'price': 500},
      ],);
      await notifier.refresh();

      expect(
        _mirrorOf(h)!.lines.map((l) => l.productId),
        unorderedEquals([118, 121]),
      );
    });

    test('a read that shows more units widens the mirror to match', () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      expect(_mirrorOf(h)!.lines.single.qty, 2);

      h.repo.cartOnFetch = _cart(items: [
        {
          'id': 118,
          'row_id': 'abc',
          'name': 'Desi Khand',
          'quantity': 5,
          'price': 899,
        },
      ],);
      await notifier.refresh();

      expect(_mirrorOf(h)!.lines.single.qty, 5);
    });

    // A cart bought on another device, or one this install has no handle on.
    // The mirror is scoped to the id it was captured from because the coupon is
    // stamped on *that* cart's first line.
    test('a read never seeds a mirror for a cart id it did not read', () async {
      final h = await _host(cartId: 'cart-1');
      await _start(h);

      expect(_mirrorOf(h)!.cartId, 'cart-1');
    });
  });

  // -------------------------------------------------------------------------
  group('add', () {
    test('the first item creates the cart and persists its id', () async {
      final h = await _host();
      final notifier = await _start(h);

      final message = await notifier.add(_product());

      expect(message, isNull);
      expect(h.repo.calls, ['createCart(118, 1)']);
      expect(h.prefs.getString('server_cart_id_v1'), 'cart-1');
      expect(_state(h).count, 2);
    });

    test('a later item goes to the existing cart', () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      h.repo.calls.clear();

      await notifier.add(_product(), quantity: 3);

      expect(h.repo.calls, ['addItem(cart-1, 118, 3)']);
    });

    test("returns the server's own sentence on refusal", () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      h.repo.nextResult = CartMutationResult(
        cart: _cart(),
        error: _refusal(),
      );

      final message = await notifier.add(_product());

      expect(message, 'Maximum quantity is 93!');
      expect(_state(h).error?.message, 'Maximum quantity is 93!');
    });
  });

  // -------------------------------------------------------------------------
  group('a refused mutation that wiped the cart', () {
    // The finding-0 case, and the reason nothing in this notifier is optimistic:
    // the add was refused AND the basket is gone. The UI must show the empty
    // cart the server actually has, not the two lines it had a moment ago.
    test('adopts the surviving cart rather than the one on screen', () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      expect(_state(h).count, 2, reason: 'precondition: cart has lines');

      h.repo.nextResult = CartMutationResult(
        cart: _emptyCart(),
        error: _refusal(),
      );
      final message = await notifier.add(_product());

      expect(message, 'Maximum quantity is 93!');
      expect(_state(h).count, 0, reason: 'the server wiped it; say so');
      expect(_state(h).isEmpty, isTrue);
      expect(_state(h).error, isNotNull);
      // It is empty, not unknowable — the re-read succeeded.
      expect(_state(h).contentsUnknown, isFalse);
    });

    // Mutation refused *and* the follow-up read failed. Showing the previous
    // cart here would be a guess, and a total built on a guess is the one thing
    // worse than no total.
    test('reports the contents unknown when the re-read also failed', () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);

      h.repo.nextResult = CartMutationResult(
        error: _refusal(),
        refreshError: _refusal('No internet connection'),
      );
      await notifier.add(_product());

      expect(_state(h).contentsUnknown, isTrue);
      expect(_state(h).cart, isNull);
      expect(_state(h).count, 0);
      expect(_state(h).error, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  group('quantity', () {
    test('increment sets the absolute quantity, because PUT is not a delta',
        () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      h.repo.calls.clear();

      await notifier.increment(const CartLineId.forSimpleProduct(118));

      // The line holds 2, so the next value is 3 — not "+1".
      expect(h.repo.calls, ['setQuantity(cart-1, 118, 3)']);
    });

    // The server does not treat 0 as a delete: qty 0 left the line sitting at
    // 1 unit and qty -1 silently deleted it. Neither is a usable way to empty a
    // line, so the notifier routes to DELETE itself.
    test('decrementing the last unit removes the line instead of sending 0',
        () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      h.repo.cartOnFetch = _cart(items: [
        {
          'id': 118,
          'row_id': 'abc',
          'name': 'Desi Khand',
          'quantity': 1,
          'price': 899,
        },
      ],);
      await notifier.refresh();
      h.repo.calls.clear();

      await notifier.decrement(const CartLineId.forSimpleProduct(118));

      expect(h.repo.calls, ['removeItem(cart-1, 118)']);
    });

    test('setQuantity below 1 never reaches PUT', () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      h.repo.calls.clear();

      await notifier.setQuantity(const CartLineId.forSimpleProduct(118), 0);

      expect(h.repo.calls, ['removeItem(cart-1, 118)']);
    });
  });

  // -------------------------------------------------------------------------
  group('serialised writes', () {
    // Concurrent writes are how this backend loses a cart: two mutations
    // interleaving between `restore()` and `store()` leave one of them writing
    // back a basket the other already changed. The notifier refuses the second
    // rather than racing, and the UI disables its steppers while busy.
    test('a second mutation is dropped while one is in flight', () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      h.repo.calls.clear();

      final first = notifier.add(_product());
      final second = notifier.add(_product());

      await Future.wait([first, second]);

      expect(h.repo.calls, hasLength(1), reason: 'the second never went out');
    });

    test('busy is set during the write and cleared after', () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);

      final pending = notifier.add(_product());
      expect(_state(h).busy, isTrue);

      await pending;
      expect(_state(h).busy, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('coupons', () {
    // The app no longer scores coupons — no table, no rules. The server decides
    // whether a code is valid, what it is worth, and whether it frees shipping.
    test('apply goes to the server and the code comes back from the cart',
        () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      h.repo.calls.clear();
      h.repo.cartOnFetch = ServerCart.fromJson({
        ..._cartJson(),
        'applied_coupon_code': 'FRESH10',
        'coupon_discount_amount': 179.8,
      });

      final message = await notifier.applyCoupon('FRESH10');

      expect(message, isNull);
      expect(h.repo.calls, ['applyCoupon(cart-1, FRESH10)']);
      expect(_state(h).appliedCouponCode, 'FRESH10');
    });

    test('a rejected code returns the server wording', () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      h.repo.nextResult = CartMutationResult(
        cart: _emptyCart(),
        error: _refusal('This coupon is invalid or expired!'),
      );

      final message = await notifier.applyCoupon('NOPE');

      expect(message, 'This coupon is invalid or expired!');
      // …and it took the cart with it, which the state now reflects.
      expect(_state(h).isEmpty, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('legacy migration', () {
    // `POST /ecommerce/cart/refresh` — the bulk endpoint that exists for exactly
    // this — is unreachable: it is declared after `POST /cart/{id}` and Laravel
    // matches in registration order, so the request binds `{id} = "refresh"` and
    // creates a cart named "refresh". Items go across one at a time.
    test('moves a pre-existing local cart onto the server', () async {
      final h = await _host(
        legacyCart: jsonEncode([
          {'product_id': 118, 'quantity': 2},
          {'product_id': 119, 'quantity': 1},
        ]),
      );
      await _start(h);

      expect(h.repo.calls, [
        'createCart(118, 2)',
        'addItem(cart-1, 119, 1)',
        'fetch(cart-1)',
      ]);
      expect(h.prefs.getString('server_cart_id_v1'), 'cart-1');
    });

    // Leaving the key would re-run the migration on the next launch and
    // duplicate whatever did get through.
    test('clears the legacy key even when the move fails', () async {
      final h = await _host(
        legacyCart: jsonEncode([
          {'product_id': 118, 'quantity': 2},
        ]),
      );
      h.repo.nextResult = CartMutationResult(error: _refusal());
      await _start(h);

      expect(h.prefs.getString('cart_items_v1'), isNull);
    });

    test('a refusal stops the move rather than compounding it', () async {
      final h = await _host(
        legacyCart: jsonEncode([
          {'product_id': 118, 'quantity': 2},
          {'product_id': 119, 'quantity': 1},
        ]),
      );
      h.repo.nextResult = CartMutationResult(error: _refusal());
      await _start(h);

      expect(h.repo.calls, ['createCart(118, 2)'],
          reason: 'the second item was not attempted',);
    });

    test('junk in the legacy key is discarded, not fatal', () async {
      final h = await _host(legacyCart: 'not json');
      await _start(h);

      expect(h.repo.calls, isEmpty);
      expect(h.prefs.getString('cart_items_v1'), isNull);
      expect(_state(h).loading, isFalse);
    });

    // The migration's first item *mints* the cart, and `CartRepository`
    // serialises `createCart` on its own minting queue rather than on a cart id
    // — there is no id yet to queue on. So a tap landing mid-migration used to
    // find `_storedId` still null, queue its own `createCart` behind this one,
    // and mint a **second** cart. Whichever `_storeId` landed last orphaned the
    // other for good: the server issues no way to look a cart up again.
    test('holds busy while it runs, so a tap cannot mint a second cart',
        () async {
      final gate = Completer<void>();
      final repo = _FakeCartRepo()..gate = gate;
      final h = await _host(
        legacyCart: jsonEncode([
          {'product_id': 118, 'quantity': 2},
        ]),
        repo: repo,
      );
      final notifier = h.container.read(serverCartProvider.notifier);

      // The mint is in flight and the flag is up before anything can be tapped.
      expect(_state(h).busy, isTrue);
      expect(repo.calls, ['createCart(118, 2)']);

      final tapped = notifier.add(_product(id: 119));
      gate.complete();
      await tapped;
      await _settle(h.container);

      expect(
        repo.calls,
        ['createCart(118, 2)', 'fetch(cart-1)'],
        reason: 'the tap was dropped, exactly as a second stepper tap is',
      );
      expect(h.prefs.getString('server_cart_id_v1'), 'cart-1');
    });

    test('releases busy once it is done', () async {
      final h = await _host(
        legacyCart: jsonEncode([
          {'product_id': 118, 'quantity': 2},
        ]),
      );
      final notifier = await _start(h);
      expect(_state(h).busy, isFalse);
      h.repo.calls.clear();

      await notifier.add(_product());

      expect(h.repo.calls, ['addItem(cart-1, 118, 1)']);
    });

    // Exactly one cart is ever minted, however many taps land on top of the
    // migration. An orphaned cart is unrecoverable, so this is the assertion
    // that actually matters.
    test('mints exactly one cart no matter how many taps land on it', () async {
      final gate = Completer<void>();
      final repo = _FakeCartRepo()..gate = gate;
      final h = await _host(
        legacyCart: jsonEncode([
          {'product_id': 118, 'quantity': 2},
          {'product_id': 119, 'quantity': 1},
        ]),
        repo: repo,
      );
      final notifier = h.container.read(serverCartProvider.notifier);

      final taps = [
        notifier.add(_product(id: 120)),
        notifier.add(_product(id: 121)),
        notifier.addProductId(122, quantity: 4),
      ];
      gate.complete();
      await Future.wait(taps);
      await _settle(h.container);

      expect(repo.calls.where((c) => c.startsWith('createCart')), hasLength(1));
      expect(h.prefs.getString('server_cart_id_v1'), 'cart-1');
    });
  });

  // -------------------------------------------------------------------------
  group('forget', () {
    // Used after an order is placed: the server has consumed the cart, so the
    // id no longer refers to anything worth reading.
    test('drops the id and the contents', () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      expect(_state(h).count, 2);

      await notifier.forget();

      expect(h.prefs.getString('server_cart_id_v1'), isNull);
      expect(_state(h).cart, isNull);
      expect(_state(h).count, 0);
    });
  });

  // -------------------------------------------------------------------------
  group('variable products', () {
    /// The cart the server returns after `POST {product_id: 120}` — a line
    /// under the **default variation's** id, 121, which nothing in the payload
    /// links back to 120.
    ServerCart resolvedTo121() => _cart(items: [
          {
            'id': 121,
            'row_id': 'v',
            'name': 'Sona Moti Wheat',
            'quantity': 1,
            'price': 921.5,
            'variation_attributes': '(Pack Size: 5 KG (Pack of 1))',
          },
        ],);

    // Without this the tile that added the item keeps showing ADD, and tapping
    // again silently buys a second one.
    test('learns which line the server resolved the parent to', () async {
      final h = await _host();
      final notifier = await _start(h);
      h.repo.cartOnFetch = resolvedTo121();

      await notifier.addProductId(120);

      expect(_state(h).quantityOfProduct(120), 1);
      expect(
        _state(h).lineForProduct(120),
        const CartLineId.forSimpleProduct(121),
      );
    });

    // The stepper has to drive the variation line: PUT on a parent id adds a
    // duplicate line, and DELETE on one 404s — which wipes the cart.
    test('the resolved line is what a stepper drives', () async {
      final h = await _host();
      final notifier = await _start(h);
      h.repo.cartOnFetch = resolvedTo121();
      await notifier.addProductId(120);
      h.repo.calls.clear();

      await notifier.increment(_state(h).lineForProduct(120)!);

      expect(h.repo.calls, ['setQuantity(cart-1, 121, 2)']);
      expect(h.repo.calls, isNot(contains(contains('120'))));
    });

    test('the mapping survives later mutations', () async {
      final h = await _host();
      final notifier = await _start(h);
      h.repo.cartOnFetch = resolvedTo121();
      await notifier.addProductId(120);

      await notifier.increment(const CartLineId.forSimpleProduct(121));

      expect(_state(h).lineForProduct(120)?.value, 121);
    });

    // A simple product needs no mapping — its line id *is* its product id — and
    // inventing one would be a second answer to a question already settled.
    test('a simple product records nothing', () async {
      final h = await _host();
      final notifier = await _start(h);

      await notifier.addProductId(118);

      expect(_state(h).variationLines, isEmpty);
      expect(
        _state(h).lineForProduct(118),
        const CartLineId.forSimpleProduct(118),
      );
    });

    // The mapping names a line; when that line is gone, so is the answer.
    test('stops resolving once the line leaves the cart', () async {
      final h = await _host();
      final notifier = await _start(h);
      h.repo.cartOnFetch = resolvedTo121();
      await notifier.addProductId(120);
      expect(_state(h).lineForProduct(120), isNotNull);

      h.repo.cartOnFetch = _emptyCart();
      await notifier.remove(const CartLineId.forSimpleProduct(121));

      expect(_state(h).lineForProduct(120), isNull);
      expect(_state(h).quantityOfProduct(120), 0);
    });
  });

  // -------------------------------------------------------------------------
  group('quantityOfProduct', () {
    test('finds a simple product by its id', () async {
      final h = await _host(cartId: 'cart-1');
      await _start(h);

      expect(_state(h).quantityOfProduct(118), 2);
      expect(_state(h).quantityOfProduct(999), 0);
    });

    // A variable product's line carries the *variation* id, so the grid tile —
    // which only holds the parent — cannot find it. Reporting 0 is the honest
    // answer: the tile does not know which variation was chosen.
    test('reports 0 for a variation line, which carries the variation id',
        () async {
      final h = await _host(cartId: 'cart-1');
      final notifier = await _start(h);
      h.repo.cartOnFetch = _cart(items: [
        {
          'id': 116, // the variation the server resolved 111 to
          'row_id': 'v',
          'name': 'Pack of 1',
          'quantity': 1,
          'price': 500,
          'variation_attributes': '(Pack Size: 5 KG)',
        },
      ],);
      await notifier.refresh();

      expect(_state(h).quantityOfProduct(111), 0);
      expect(_state(h).quantityOf(const CartLineId.forSimpleProduct(116)), 1);
    });
  });
}

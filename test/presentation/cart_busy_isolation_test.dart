/// A cart write belongs to one line, and only that line may react to it.
///
/// The bug: [ServerCartState] carried a single `busy` flag, and every per-item
/// control in the app read it. Tapping ADD on one product card, or "+" on one
/// basket row, made *every* card and *every* row flip state at once —
/// steppers across the screen faded, and a tile holding three jars turned into
/// an "ADD" button and back, because `_AddControl` chose its shape from whether
/// its callbacks happened to be null.
///
/// Two separate faults, so two separate groups below: what the state says, and
/// what the widget does with it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/server_cart.dart';
import 'package:trueway_farms/data/models/product_model.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/server_cart_provider.dart';
import 'package:trueway_farms/presentation/widgets/product_card.dart';

import '../support/fake_cart_repository.dart';
import '../support/fake_catalog_repository.dart';
import '../support/fake_home_repository.dart';

/// Two products, both already in the basket — the situation the bug needs.
const _wheatId = 1;
const _honeyId = 2;

FakeCartRepository _repoWithBoth() => FakeCartRepository(
      lines: const [
        FakeCartLine(id: _wheatId, name: 'Wheat', quantity: 3, unitPrice: 900),
        FakeCartLine(id: _honeyId, name: 'Honey', quantity: 2, unitPrice: 600),
      ],
    );

Product _product(int id, String name) => Product.fromJson({
      'id': id,
      'slug': 'p-$id',
      'name': name,
      'price': 900.0,
      'weight': 5000,
      'quantity': 100,
      'is_out_of_stock': false,
    });

/// A container wired to [repo], with the cart already read.
Future<ProviderContainer> _container(FakeCartRepository repo) async {
  SharedPreferences.setMockInitialValues({'server_cart_id_v1': repo.cartId});
  final prefs = await SharedPreferences.getInstance();

  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      cartRepositoryProvider.overrideWithValue(repo),
      catalogRepositoryProvider
          .overrideWithValue(FakeCatalogRepository(product: _product(1, 'W'))),
      homeRepositoryProvider.overrideWithValue(FakeHomeRepository()),
      isAuthenticatedProvider.overrideWithValue(true),
    ],
  );
  addTearDown(container.dispose);

  await container.read(serverCartProvider.notifier).refresh();
  return container;
}

void main() {
  group('the state names the line it is writing', () {
    test('only that line is busy, though the cart as a whole is', () async {
      final repo = _repoWithBoth();
      final container = await _container(repo);
      final notifier = container.read(serverCartProvider.notifier);

      // Hold the write open so the mid-flight state can be read.
      repo.gate = Completer<void>();
      final pending = notifier.increment(CartLineId.forSimpleProduct(_wheatId));
      await Future<void>.delayed(Duration.zero);

      final state = container.read(serverCartProvider);
      expect(state.busy, isTrue, reason: 'globally, a write is in flight');
      expect(
        state.isBusyLine(CartLineId.forSimpleProduct(_wheatId)),
        isTrue,
        reason: 'the line being written',
      );
      expect(
        state.isBusyLine(CartLineId.forSimpleProduct(_honeyId)),
        isFalse,
        reason: 'the line that was not touched — this was the bug',
      );

      repo.gate!.complete();
      await pending;
    });

    test('and nothing stays busy once the write lands', () async {
      final repo = _repoWithBoth();
      final container = await _container(repo);

      await container
          .read(serverCartProvider.notifier)
          .increment(CartLineId.forSimpleProduct(_wheatId));

      final state = container.read(serverCartProvider);
      expect(state.busy, isFalse);
      expect(state.busyLine, isNull);
      expect(state.isBusyLine(CartLineId.forSimpleProduct(_wheatId)), isFalse);
    });

    test('a removal is scoped to its line too', () async {
      final repo = _repoWithBoth();
      final container = await _container(repo);
      final notifier = container.read(serverCartProvider.notifier);

      repo.gate = Completer<void>();
      final pending = notifier.remove(CartLineId.forSimpleProduct(_honeyId));
      await Future<void>.delayed(Duration.zero);

      final state = container.read(serverCartProvider);
      expect(state.isBusyLine(CartLineId.forSimpleProduct(_honeyId)), isTrue);
      expect(state.isBusyLine(CartLineId.forSimpleProduct(_wheatId)), isFalse);

      repo.gate!.complete();
      await pending;
    });

    test('a coupon blames no line, because it is not about one', () async {
      // The global flag still exists and still governs Checkout, Clear cart and
      // the coupon field. What it must not do is reach a per-item control.
      final repo = _repoWithBoth();
      final container = await _container(repo);
      final notifier = container.read(serverCartProvider.notifier);

      repo.gate = Completer<void>();
      final pending = notifier.applyCoupon('M20');
      await Future<void>.delayed(Duration.zero);

      final state = container.read(serverCartProvider);
      expect(state.busy, isTrue);
      expect(state.busyLine, isNull);
      expect(state.isBusyLine(CartLineId.forSimpleProduct(_wheatId)), isFalse);

      repo.gate!.complete();
      await pending;
    });
  });

  group('the tile keeps its shape', () {
    /// A card for [product], sharing [repo] with whatever else is writing.
    Future<void> pump(
      WidgetTester tester,
      FakeCartRepository repo,
      Product product,
    ) async {
      SharedPreferences.setMockInitialValues({'server_cart_id_v1': repo.cartId});
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            cartRepositoryProvider.overrideWithValue(repo),
            catalogRepositoryProvider
                .overrideWithValue(FakeCatalogRepository(product: product)),
            homeRepositoryProvider.overrideWithValue(FakeHomeRepository()),
            isAuthenticatedProvider.overrideWithValue(true),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 140,
                  height: 300,
                  child: ProductCard(product: product),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a stepper stays a stepper while another line writes',
        (tester) async {
      final repo = _repoWithBoth();
      await pump(tester, repo, _product(_honeyId, 'Honey'));

      // The honey tile is holding two units, so it shows a stepper.
      expect(find.text('2'), findsOneWidget);
      expect(find.text('ADD'), findsNothing);

      // Now write to the *wheat* line and hold it open.
      repo.gate = Completer<void>();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductCard)),
      );
      final pending = container
          .read(serverCartProvider.notifier)
          .increment(CartLineId.forSimpleProduct(_wheatId));
      await tester.pump();

      // The honey tile must be exactly as it was. It used to turn into "ADD".
      expect(find.text('2'), findsOneWidget);
      expect(find.text('ADD'), findsNothing);

      repo.gate!.complete();
      await pending;
      await tester.pump();
    });

    testWidgets('its own write shows a spinner where the number was',
        (tester) async {
      // The acknowledgement. A tap on a 16dp button with nothing happening
      // reads as a missed tap, and the customer taps again — which this
      // backend answers by dropping the second write, so they get nothing
      // twice over.
      final repo = _repoWithBoth();
      await pump(tester, repo, _product(_honeyId, 'Honey'));

      expect(find.byKey(const Key('card-stepper-busy')), findsNothing);

      repo.gate = Completer<void>();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductCard)),
      );
      final pending = container
          .read(serverCartProvider.notifier)
          .increment(CartLineId.forSimpleProduct(_honeyId));
      await tester.pump();

      expect(find.byKey(const Key('card-stepper-busy')), findsOneWidget);
      expect(find.text('2'), findsNothing, reason: 'the spinner took its slot');

      repo.gate!.complete();
      await pending;
      await tester.pump();

      // And it hands the slot back.
      expect(find.byKey(const Key('card-stepper-busy')), findsNothing);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('another line writing leaves this number alone',
        (tester) async {
      final repo = _repoWithBoth();
      await pump(tester, repo, _product(_honeyId, 'Honey'));

      repo.gate = Completer<void>();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductCard)),
      );
      final pending = container
          .read(serverCartProvider.notifier)
          .increment(CartLineId.forSimpleProduct(_wheatId));
      await tester.pump();

      expect(find.byKey(const Key('card-stepper-busy')), findsNothing);
      expect(find.text('2'), findsOneWidget);

      repo.gate!.complete();
      await pending;
      await tester.pump();
    });

    testWidgets('and stays a stepper while its own line writes',
        (tester) async {
      // Being momentarily inert is not the same as having nothing in it. The
      // quantity is still 2 and the control must still say so.
      final repo = _repoWithBoth();
      await pump(tester, repo, _product(_honeyId, 'Honey'));

      repo.gate = Completer<void>();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductCard)),
      );
      final pending = container
          .read(serverCartProvider.notifier)
          .increment(CartLineId.forSimpleProduct(_honeyId));
      await tester.pump();

      expect(find.text('ADD'), findsNothing);

      repo.gate!.complete();
      await pending;
      await tester.pump();
    });
  });
}

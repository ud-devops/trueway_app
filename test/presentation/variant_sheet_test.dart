import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_palette.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/product_model.dart';
import 'package:trueway_farms/data/models/product_variation.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/widgets/product_card.dart';

import '../data/product_variation_test.dart' show detailEnvelope, resolvedVariation;
import '../support/fake_cart_repository.dart';
import '../support/fake_catalog_repository.dart';
import '../support/fake_home_repository.dart';

/// Choosing a pack from a grid tile.
///
/// The whole point: a bare `POST {product_id: parent}` resolves to whichever
/// variation the server calls default — for this product the ₹921.50 pack. A
/// customer who wanted the ₹493.50 one has no way to say so from a tile unless
/// the tile offers the choice.

Product _variableProduct() => Product.fromJson({
      'id': 120,
      'slug': 'sona-moti-wheat',
      'name': 'Trueway Farms Organic Sona Moti Wheat',
      'sku': 'TRW3214',
      'price': 921.501,
      'original_price': 1296.75,
      'quantity': 3980,
      'is_out_of_stock': false,
      'weight': 5000,
    });

Product _simpleProduct() => Product.fromJson({
      'id': 118,
      'slug': 'desi-khand',
      'name': 'Desi Khand',
      'sku': 'TRW3215',
      'price': 943.95,
      'quantity': 94,
      'is_out_of_stock': false,
      'weight': 5100,
    });

ProductVariationOptions _options() =>
    ProductVariationOptions.fromEnvelope(detailEnvelope());

typedef _Host = ({
  Widget widget,
  FakeCatalogRepository catalog,
  FakeCartRepository cart,
  FakeHomeRepository home,
});

/// [variable] wires the two-request scan that tells a tile a product has packs:
/// `/filters` supplies the attribute ids, and `/products?attributes[]=…` comes
/// back with the products carrying them. Only variable products carry any, so
/// that list *is* the variable set.
Future<_Host> _host({
  required Product product,
  bool variable = true,
  ProductVariation? resolved,
  List<FakeCartLine> inCart = const [],
}) async {
  SharedPreferences.setMockInitialValues(
    inCart.isEmpty ? {} : {'server_cart_id_v1': 'cart-test'},
  );
  final prefs = await SharedPreferences.getInstance();

  final catalog = FakeCatalogRepository(
    product: product,
    variations: variable ? _options() : null,
    variableProducts: variable ? [product] : const [],
  )..resolved = resolved;
  final cart = FakeCartRepository(lines: inCart);
  final home = FakeHomeRepository(
    attributeSets: variable ? kPackSizeAttributeSets : const [],
  );

  return (
    widget: ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        cartRepositoryProvider.overrideWithValue(cart),
        catalogRepositoryProvider.overrideWithValue(catalog),
        homeRepositoryProvider.overrideWithValue(home),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              height: 260,
              child: ProductCard(product: product),
            ),
          ),
        ),
      ),
    ),
    catalog: catalog,
    cart: cart,
    home: home,
  );
}

/// The 1.85 kg pack — attribute 21 resolves to variation 122.
ProductVariation _pack185() => ProductVariation.fromJson({
      ...resolvedVariation(),
      'id': 122,
    });

/// ADD buttons *inside the sheet*. The product tile behind it has one too, and
/// both are InkWells, so the count has to be scoped.
Finder _sheetAddButtons() => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text('ADD'),
    );

void main() {
  // -------------------------------------------------------------------------
  group('the tile', () {
    // The point of the two-request scan: the hint is there before the customer
    // touches anything, and survives a restart because it is re-derived rather
    // than remembered.
    testWidgets('shows the option count without being tapped', (tester) async {
      final h = await _host(product: _variableProduct());
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();

      // Three packs on attribute set 6.
      expect(find.text('3 options'), findsOneWidget);
      expect(find.text('ADD'), findsOneWidget);
    });

    // Which products are variable is established once for the whole catalogue,
    // not once per tile — otherwise a 20-product grid fires 20 lookups.
    testWidgets('establishes the variable set in two requests', (tester) async {
      final h = await _host(product: _variableProduct());
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();

      expect(h.home.filterCalls, 1);
      expect(h.catalog.attributeQueries, [
        [21, 22, 23],
      ]);
      // Only the products that scan says are variable then cost a detail read.
      expect(h.catalog.detailRequests, ['sona-moti-wheat']);
    });

    testWidgets('a variable product opens the sheet with no further lookup',
        (tester) async {
      final h = await _host(product: _variableProduct());
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();
      final before = h.catalog.detailRequests.length;

      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();

      expect(find.text('1.85 KG (Pack of 1)'), findsOneWidget);
      expect(h.catalog.detailRequests, hasLength(before));
    });
  });

  // -------------------------------------------------------------------------
  group('the options button', () {
    // The two-line button was cramped: at 50×30 with an 8px second line, the
    // text sat against the border on every side and "2 options" ellipsised to
    // "2 opt…". The reference grows the button rather than shrinking the text,
    // and only for this variant — the plain ADD keeps its compact size so the
    // pack label keeps its budget on the simple products that fill a grid.
    //
    // Asserted on *rendered* size, like the pack-pill regressions above: the
    // default test font draws every glyph as a full em square, so an
    // ellipsis-based check reports truncation even for a correct layout.

    // Height is uniform across every state — plain ADD, this two-line variant
    // and the stepper. When the options button was taller, the button rows sat
    // at different heights across a grid and neighbouring cards visibly
    // disagreed about where their price block started.
    testWidgets('is exactly as tall as a plain ADD', (tester) async {
      final h = await _host(product: _variableProduct());
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();

      // `.first` is the *innermost* ancestor — the button's own frame.
      // `.last` would be the tile's 160x260 SizedBox and pass no matter what.
      final button = tester.getSize(
        find
            .ancestor(
              of: find.text('3 options'),
              matching: find.byType(SizedBox),
            )
            .first,
      );

      expect(button.height, 32, reason: 'the one height every state uses');
      // Wider, though: "3 options" does not fit a 50dp box.
      expect(button.width, greaterThan(50));
      // And not so wide it has eaten the pack label beside it.
      expect(button.width, lessThan(64));
    });

    testWidgets('gives the count a full line, not an ellipsis', (tester) async {
      final h = await _host(product: _variableProduct());
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();

      // Both lines rendered, neither collapsed to nothing.
      expect(find.text('ADD'), findsOneWidget);
      expect(tester.getSize(find.text('3 options')).height, greaterThan(0));
      expect(tester.getSize(find.text('3 options')).width, greaterThan(20));
    });

    // The count belongs on the button's bottom edge, under a centred ADD.
    // Centring the pair as one block — which is what this did first — leaves
    // ADD sitting high and the count floating in the middle of the box.
    testWidgets('sits the count on the bottom edge, under ADD', (tester) async {
      final h = await _host(product: _variableProduct());
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();

      final button = tester.getRect(
        find
            .ancestor(
              of: find.text('3 options'),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      final count = tester.getRect(find.text('3 options'));
      final add = tester.getRect(find.text('ADD'));

      expect(count.top, greaterThan(add.bottom), reason: 'below ADD');
      // In the bottom third of the button, not floating at its centre.
      expect(
        count.center.dy,
        greaterThan(button.top + button.height * 0.66),
        reason: 'the count should hug the bottom edge',
      );
      expect(count.bottom, lessThanOrEqualTo(button.bottom));
    });

    testWidgets('lays out without overflowing the tile', (tester) async {
      final h = await _host(product: _variableProduct());
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    // The wider button is taken out of the pack label's share of the row, and
    // at 64dp it cost enough that "5 kg" rendered as "5 …" on a phone tile.
    // Same metric as the pack-pill regressions in product_card_test: rendered
    // width, because the test font draws every glyph as a full em square.
    testWidgets('leaves the pack label its room', (tester) async {
      final h = await _host(product: _variableProduct());
      await tester.pumpWidget(
        ProviderScope(
          overrides: (h.widget as ProviderScope).overrides.toList(),
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: Center(
                // A three-across phone tile, which is the tightest case.
                child: SizedBox(
                  width: 117,
                  height: 210,
                  child: ProductCard(product: _variableProduct()),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('3 options'), findsOneWidget);
      expect(find.text('5 kg'), findsOneWidget);
      expect(
        tester.getSize(find.text('5 kg')).width,
        greaterThan(28),
        reason: '"5 kg" squeezed to "5 …" when the button took 64dp',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('a simple product', () {
    // No sheet, nothing extra on the button, and — because the scan already
    // said it is simple — no detail lookup before the add either.
    testWidgets('adds straight away and shows no options line', (tester) async {
      final h = await _host(product: _simpleProduct(), variable: false);
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();

      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.textContaining('options'), findsNothing);
      expect(h.cart.calls, ['createCart(118, 1)', 'addItem(118, 1)']);
      expect(h.catalog.detailRequests, isEmpty,
          reason: 'a known-simple product costs no lookup',);
    });

    // The scan is an optimisation, not a gate. If it fails, ADD falls back to
    // asking per product, and the server still rules on the result.
    testWidgets('still adds when the scan finds nothing', (tester) async {
      final h = await _host(product: _simpleProduct(), variable: false);
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();

      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();

      expect(h.cart.calls, isNotEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('the sheet', () {
    testWidgets('opens on ADD with a row per pack', (tester) async {
      final h = await _host(product: _variableProduct());
      await tester.pumpWidget(h.widget);
      await tester.pump();

      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();

      expect(find.text('1.85 KG (Pack of 1)'), findsOneWidget);
      expect(find.text('5 KG (Pack of 1)'), findsOneWidget);
      expect(find.text('5 KG (Pack of 2)'), findsOneWidget);
    });

    // Each option's own price, straight off the detail payload — no request per
    // row. This is what lets the customer compare before committing.
    testWidgets('prices every pack without another request', (tester) async {
      final h = await _host(product: _variableProduct());
      await tester.pumpWidget(h.widget);
      await tester.pump();

      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();

      expect(find.text('₹493.50'), findsOneWidget);
      expect(find.text('₹921.50'), findsWidgets);
      // MRP struck through beside it.
      expect(find.text('₹571.20'), findsOneWidget);
      expect(h.catalog.detailRequests, hasLength(1));
      expect(h.catalog.resolveRequests, isEmpty, reason: 'nothing committed yet');
    });

    // The headline claim: adding the 1.85 kg pack posts variation 122, not the
    // parent 120 and not the default 121.
    testWidgets('adds the chosen variation, not the parent', (tester) async {
      final h = await _host(product: _variableProduct(), resolved: _pack185());
      await tester.pumpWidget(h.widget);
      await tester.pump();

      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();

      // The first row is the 1.85 kg pack; its ADD is the second in the tree.
      await tester.tap(find.byKey(const ValueKey('variant-add-21')));
      await tester.pumpAndSettle();

      expect(h.catalog.resolveRequests, [
        [21],
      ]);
      expect(h.cart.calls, contains('createCart(122, 1)'));
      expect(h.cart.calls, isNot(contains('createCart(120, 1)')));
      expect(h.cart.calls, isNot(contains('createCart(121, 1)')));
    });

    // A pack already in the basket must offer a counter, not another ADD —
    // otherwise the only way to change a quantity is to leave for the cart.
    testWidgets('shows a stepper for a pack already in the basket',
        (tester) async {
      final h = await _host(
        product: _variableProduct(),
        inCart: const [
          FakeCartLine(
            id: 122,
            name: 'Sona Moti Wheat',
            quantity: 2,
            unitPrice: 470,
            variationLabel: '(Pack Size: 1.85 KG (Pack of 1))',
          ),
        ],
      );
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();

      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();

      // The 1.85 kg row carries the counter…
      expect(find.text('2'), findsOneWidget);
      expect(find.byIcon(Icons.remove_rounded), findsOneWidget);
      expect(find.byIcon(Icons.add_rounded), findsOneWidget);
      // …and the two packs that are not in the basket still say ADD.
      expect(_sheetAddButtons(), findsNWidgets(2));
    });

    testWidgets('the stepper drives the variation line, not the parent',
        (tester) async {
      final h = await _host(
        product: _variableProduct(),
        inCart: const [
          FakeCartLine(
            id: 122,
            name: 'Sona Moti Wheat',
            quantity: 2,
            unitPrice: 470,
            variationLabel: '(Pack Size: 1.85 KG (Pack of 1))',
          ),
        ],
      );
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();
      h.cart.calls.clear();

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();

      // PUT on the variation id. The parent (120) would add a duplicate line.
      expect(h.cart.calls, ['setQuantity(122, 3)']);
      expect(find.text('3'), findsOneWidget);
    });

    // The server does not treat qty 0 as a delete, so the last unit has to go
    // out as a DELETE rather than a PUT.
    testWidgets('decrementing the last unit removes the line', (tester) async {
      final h = await _host(
        product: _variableProduct(),
        inCart: const [
          FakeCartLine(
            id: 122,
            name: 'Sona Moti Wheat',
            quantity: 1,
            unitPrice: 470,
            variationLabel: '(Pack Size: 1.85 KG (Pack of 1))',
          ),
        ],
      );
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();
      h.cart.calls.clear();

      await tester.tap(find.byIcon(Icons.remove_rounded));
      await tester.pumpAndSettle();

      expect(h.cart.calls, ['removeItem(122)']);
      expect(_sheetAddButtons(), findsNWidgets(3));
    });

    // "5 KG (Pack of 1)" must not match a line for "5 KG (Pack of 1) Refill".
    // The label is parsed on the server's own `(Set: Title)` format rather than
    // substring-matched, so a near-miss leaves the row offering ADD.
    testWidgets('does not mistake a similarly named pack for this one',
        (tester) async {
      final h = await _host(
        product: _variableProduct(),
        inCart: const [
          FakeCartLine(
            id: 999,
            name: 'Sona Moti Wheat',
            quantity: 4,
            unitPrice: 470,
            variationLabel: '(Pack Size: 5 KG (Pack of 1) Refill)',
          ),
        ],
      );
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();

      expect(find.text('4'), findsNothing);
      expect(_sheetAddButtons(), findsNWidgets(3));
    });

    // Cart writes are serialised, so while one pack is being added the others
    // cannot write. They must not *look* unavailable for it: greying every
    // row's button turned the whole sheet dead for the length of one request.
    testWidgets('adding one pack does not grey out the others', (tester) async {
      final h = await _host(product: _variableProduct(), resolved: _pack185());
      await tester.pumpWidget(h.widget);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();

      // Hold the write open and inspect the sheet mid-flight.
      h.cart.gate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('variant-add-21')));
      await tester.pump();

      // The row being added shows a spinner…
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // …and the other two still offer an ordinary ADD.
      expect(_sheetAddButtons(), findsNWidgets(2));
      for (final id in [22, 23]) {
        final material = tester.widget<Material>(
          find.descendant(
            of: find.byKey(ValueKey('variant-add-$id')),
            matching: find.byType(Material),
          ),
        );
        expect(
          material.color,
          isNot(AppTheme.light.extension<AppPalette>()!.surfaceAlt),
          reason: 'a waiting row must not be painted as unavailable',
        );
      }

      h.cart.gate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('a pack that will not resolve is reported, not added',
        (tester) async {
      // `resolved` left null — the server names no variation.
      final h = await _host(product: _variableProduct());
      await tester.pumpWidget(h.widget);
      await tester.pump();

      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('variant-add-21')));
      await tester.pumpAndSettle();

      expect(h.cart.calls, isEmpty, reason: 'nothing was added');
      expect(find.textContaining('not available'), findsOneWidget);
    });
  });
}

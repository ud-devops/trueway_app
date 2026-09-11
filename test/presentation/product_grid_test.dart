import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/data/models/product_model.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/widgets/product_card.dart';
import 'package:trueway_farms/presentation/widgets/product_grid.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';

import '../support/fake_home_repository.dart';

/// Covers the grid widgets the catalogue screens now share. Each screen used to
/// build its own grid, so a layout fault could only be caught by opening that
/// screen; one break here now means all five are broken.
Product _product(int id) => Product.fromJson({
      'id': id,
      'slug': 'product-$id',
      'name': 'Organic Product $id',
      'price': 100.0,
      'original_price': 150.0,
      'weight': 1000,
      'quantity': 10,
      'is_out_of_stock': false,
      'stock_status_label': 'In stock',
    });

Future<Widget> _wrap(Widget child, {Size size = const Size(411, 890)}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      // Every product tile asks which products are variable, because a listing
      // row cannot say. Stubbed empty: no attribute sets, so no scan.
      homeRepositoryProvider.overrideWithValue(FakeHomeRepository()),
    ],
    child: MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  final products = List.generate(6, _product);

  testWidgets('ProductGrid lays out a card per product', (tester) async {
    await tester.pumpWidget(await _wrap(ProductGrid(products: products)));
    await tester.pump();

    expect(find.byType(ProductCard), findsWidgets);
  });

  testWidgets('ProductGrid appends load-more tiles only when asked', (tester) async {
    await tester.pumpWidget(await _wrap(ProductGrid(products: products)));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pumpWidget(
      await _wrap(ProductGrid(products: products, showLoadMore: true)),
    );
    await tester.pump();
    // The sentinel tiles sit past the fold, so scroll them into view.
    await tester.drag(find.byType(GridView), const Offset(0, -2000));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets('ProductSliverGrid renders inside a CustomScrollView', (tester) async {
    await tester.pumpWidget(await _wrap(
      CustomScrollView(slivers: [ProductSliverGrid(products: products)]),
    ),);
    await tester.pump();

    expect(find.byType(ProductCard), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  // Home puts the skeleton in a SliverToBoxAdapter, which imposes no height
  // limit — without shrinkWrap the grid throws "Vertical viewport was given
  // unbounded height" and the whole feed fails to build while loading.
  testWidgets('ProductGridSkeleton survives an unbounded height constraint', (tester) async {
    await tester.pumpWidget(await _wrap(
      CustomScrollView(
        slivers: const [
          SliverToBoxAdapter(child: ProductGridSkeleton(itemCount: 4)),
        ],
      ),
    ),);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('ProductGridSkeleton renders the requested tile count', (tester) async {
    await tester.pumpWidget(
      await _wrap(const ProductGridSkeleton(itemCount: 4)),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow grid honours its column and aspect overrides', (tester) async {
    // Mirrors the Categories screen, whose grid gives 88dp to the rail.
    await tester.pumpWidget(await _wrap(
      Row(
        children: [
          const SizedBox(width: 88),
          Expanded(
            child: ProductGrid(
              products: products,
              columns: 2,
              aspectRatio: 0.52,
            ),
          ),
        ],
      ),
    ),);
    await tester.pump();

    final delegate = tester.widget<GridView>(find.byType(GridView)).gridDelegate
        as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 2);
    expect(delegate.childAspectRatio, 0.52);
  });
}

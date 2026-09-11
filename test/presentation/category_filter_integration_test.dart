import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/network/api_response.dart';
import 'package:trueway_farms/data/models/category_model.dart';
import 'package:trueway_farms/data/models/product_model.dart';
import 'package:trueway_farms/data/repositories/catalog_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/home_providers.dart';
import 'package:trueway_farms/presentation/screens/categories/category_browse_screen.dart';

import '../support/fake_home_repository.dart';

/// Filters reaching the server from the screen a customer actually uses.
///
/// This project has twice mistaken "the repository has a method for it" for
/// "the app does it", so the assertions here drive the real screen and check
/// what arrived at the repository.

Product _product(int id, String name, {bool outOfStock = false}) =>
    Product.fromJson({
      'id': id,
      'slug': 'p$id',
      'name': name,
      'price': 100,
      'quantity': outOfStock ? 0 : 10,
      'is_out_of_stock': outOfStock,
    });

/// Records what the listing was asked for.
class _RecordingCatalogRepository implements CatalogRepository {
  _RecordingCatalogRepository({this.items = const []});

  final List<Product> items;

  final List<
      ({
        int categoryId,
        List<int> attributeIds,
        List<int> tagIds,
        List<int> brandIds,
        List<String> ratings,
        List<String> discounts,
        List<int> collectionIds,
        double? minPrice,
        double? maxPrice,
        bool inStockOnly,
        String? sort,
      })> calls = [];

  @override
  Future<PaginatedResponse<Product>> productsByCategory(
    int categoryId, {
    int page = 1,
    int perPage = 20,
    String? sort,
    List<int> attributeIds = const [],
    List<int> tagIds = const [],
    List<int> brandIds = const [],
    List<String> ratings = const [],
    List<String> discounts = const [],
    List<int> collectionIds = const [],
    double? minPrice,
    double? maxPrice,
    bool inStockOnly = false,
  }) async {
    calls.add(
      (
        categoryId: categoryId,
        attributeIds: attributeIds,
        tagIds: tagIds,
        brandIds: brandIds,
        ratings: ratings,
        discounts: discounts,
        collectionIds: collectionIds,
        minPrice: minPrice,
        maxPrice: maxPrice,
        inStockOnly: inStockOnly,
        sort: sort,
      ),
    );
    return PaginatedResponse(
      items: items,
      meta: PaginationMeta.single(items.length),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'FakeCatalogRepository does not implement ${invocation.memberName}',
      );
}

List<Category> _tree() => [
      Category(
        id: 17,
        name: 'Wheat',
        slug: 'wheat',
        parentId: 0,
        children: const [],
      ),
    ];

Future<_RecordingCatalogRepository> _pump(
  WidgetTester tester, {
  List<Product> items = const [],
}) async {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final catalog = _RecordingCatalogRepository(items: items);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        categoriesProvider.overrideWith((ref) async => _tree()),
        catalogRepositoryProvider.overrideWithValue(catalog),
        homeRepositoryProvider.overrideWithValue(
          FakeHomeRepository(
            attributeSets: kPackSizeAttributeSets,
            tags: kHealthTags,
            collections: kCollections,
            discountRanges: kDiscountRanges,
            ratingRanges: kRatingRanges,
            maxPrice: 4200,
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const CategoryBrowseScreen(categoryId: 17),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return catalog;
}

Future<void> _chooseFacet(WidgetTester tester, String facetKey) async {
  await tester.tap(find.textContaining('Filters'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(facetKey)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('filter-apply')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the listing starts with no facets', (tester) async {
    final catalog = await _pump(tester);

    expect(catalog.calls, isNotEmpty);
    expect(catalog.calls.first.attributeIds, isEmpty);
    expect(catalog.calls.first.tagIds, isEmpty);
  });

  testWidgets('choosing an attribute refetches with it', (tester) async {
    final catalog = await _pump(tester);
    final before = catalog.calls.length;

    await _chooseFacet(tester, 'facet-22');

    expect(catalog.calls.length, greaterThan(before), reason: 'it must refetch');
    expect(catalog.calls.last.attributeIds, [22]);
    expect(catalog.calls.last.categoryId, 17);
  });

  testWidgets('choosing a tag refetches with it', (tester) async {
    final catalog = await _pump(tester);

    await _chooseFacet(tester, 'facet-15');

    expect(catalog.calls.last.tagIds, [15]);
  });

  testWidgets('the pill counts the applied filters', (tester) async {
    await _pump(tester);
    expect(find.text('Filters'), findsOneWidget, reason: 'the premise');

    await _chooseFacet(tester, 'facet-22');

    expect(find.text('Filters · 1'), findsOneWidget);
  });

  // `in_stock=1` exists now, so this reaches the query — which is what lets
  // paging stay on. The local sweep stays as a safety net because the parameter
  // could not be proven on a store where nothing is out of stock.
  testWidgets('in stock only goes to the server and is swept locally too',
      (tester) async {
    final catalog = await _pump(
      tester,
      items: [
        _product(1, 'In stock item'),
        _product(2, 'Sold out item', outOfStock: true),
      ],
    );

    await tester.tap(find.textContaining('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-in-stock')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-apply')));
    await tester.pumpAndSettle();

    expect(catalog.calls.last.inStockOnly, isTrue);
    expect(find.text('In stock item'), findsOneWidget);
    expect(find.text('Sold out item'), findsNothing);
  });

  testWidgets('clearing the filters refetches without them', (tester) async {
    final catalog = await _pump(tester);
    await _chooseFacet(tester, 'facet-22');
    expect(catalog.calls.last.attributeIds, [22], reason: 'the premise');

    await tester.tap(find.textContaining('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-apply')));
    await tester.pumpAndSettle();

    expect(catalog.calls.last.attributeIds, isEmpty);
    expect(find.text('Filters'), findsOneWidget);
  });

  // The prefixed token has to survive the whole path: a bare `4` reaches the
  // server, parses, and filters nothing.
  testWidgets('a rating threshold reaches the query as rating_N',
      (tester) async {
    final catalog = await _pump(tester);

    await _chooseFacet(tester, 'facet-rating_4');

    expect(catalog.calls.last.ratings, ['rating_4']);
  });

  testWidgets('an offer reaches the query as its token', (tester) async {
    final catalog = await _pump(tester);

    await _chooseFacet(tester, 'facet-on_sale');

    expect(catalog.calls.last.discounts, ['on_sale']);
  });

  testWidgets('a collection reaches the query by id', (tester) async {
    final catalog = await _pump(tester);

    await _chooseFacet(tester, 'facet-1');

    expect(catalog.calls.last.collectionIds, [1]);
  });

  // Shippable only since the backend started comparing the displayed price.
  testWidgets('a price band reaches the query as rupee bounds',
      (tester) async {
    final catalog = await _pump(tester);

    await tester.tap(find.textContaining('Filters'));
    await tester.pumpAndSettle();
    tester
        .widget<RangeSlider>(find.byType(RangeSlider))
        .onChanged!(const RangeValues(0, 900));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-apply')));
    await tester.pumpAndSettle();

    expect(catalog.calls.last.maxPrice, 900);
  });

  testWidgets('a facet survives a sort change', (tester) async {
    final catalog = await _pump(tester);
    await _chooseFacet(tester, 'facet-22');

    await tester.tap(find.text('Recommended'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Price: Low to High'));
    await tester.pumpAndSettle();

    expect(catalog.calls.last.sort, 'price_asc');
    expect(catalog.calls.last.attributeIds, [22]);
  });
}

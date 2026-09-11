import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/repositories/catalog_repository.dart';
import 'package:trueway_farms/presentation/providers/catalog_filter_provider.dart';
import 'package:trueway_farms/presentation/providers/products_provider.dart';

/// Facet filtering on a category listing.
///
/// `ProductCategoryController::products` merges the category into `categories`
/// and hands the request to the same `GetProductService` the flat product list
/// uses, so every filter that works there works on this route too. Verified
/// live against category 17 on 2026-08-11: baseline 5 products,
/// `attributes[]=22` → 2, `tags[]=15` → 2.

class _FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({'error': false, 'data': <dynamic>[]}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<({CatalogRepository repo, _FakeAdapter adapter})> _build() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter();
  final dio = Dio()..httpClientAdapter = adapter;
  return (repo: CatalogRepository(ApiClient(prefs: prefs, dio: dio)), adapter: adapter);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('productsByCategory', () {
    test('sends nothing extra when no facet is chosen', () async {
      final t = await _build();

      await t.repo.productsByCategory(17);

      final query = t.adapter.requests.single.queryParameters;
      expect(query['attributes[]'], isNull);
      expect(query['tags[]'], isNull);
      expect(query['brands[]'], isNull);
    });

    test('sends each facet as a repeated key', () async {
      final t = await _build();

      await t.repo.productsByCategory(
        17,
        attributeIds: const [21, 22],
        tagIds: const [15],
        brandIds: const [8],
      );

      final query = t.adapter.requests.single.queryParameters;
      expect(query['attributes[]'], [21, 22]);
      expect(query['tags[]'], [15]);
      expect(query['brands[]'], [8]);
    });

    // `min_price`/`max_price` filter on a price that is not the one the app
    // shows — live, `max_price=900` returns a product listed at ₹943.95 — so a
    // rupee slider would contradict the prices beside it. Left unsent until the
    // server agrees with itself.
    test('never sends a price bound', () async {
      final t = await _build();

      await t.repo.productsByCategory(17, attributeIds: const [21]);

      final query = t.adapter.requests.single.queryParameters;
      expect(query.containsKey('min_price'), isFalse);
      expect(query.containsKey('max_price'), isFalse);
    });

    test('keeps the sort alongside the facets', () async {
      final t = await _build();

      await t.repo.productsByCategory(17, sort: 'price_asc', tagIds: const [15]);

      final query = t.adapter.requests.single.queryParameters;
      expect(query['sort-by'], 'price_asc');
      expect(query['tags[]'], [15]);
    });
  });

  // The list provider is keyed on ProductQuery. If a changed selection compared
  // equal, applying a filter would silently re-use the previous list — the
  // filter would appear to do nothing.
  group('ProductQuery identity', () {
    const base = ProductQuery(categoryId: 17);

    test('a changed facet is a different query', () {
      expect(base.copyWith(attributeIds: const [22]), isNot(base));
      expect(base.copyWith(tagIds: const [15]), isNot(base));
      expect(base.copyWith(brandIds: const [8]), isNot(base));
    });

    test('the same facets are the same query', () {
      expect(
        base.copyWith(attributeIds: const [21, 22]),
        base.copyWith(attributeIds: const [21, 22]),
      );
      expect(
        base.copyWith(attributeIds: const [21, 22]).hashCode,
        base.copyWith(attributeIds: const [21, 22]).hashCode,
      );
    });

    test('facets survive a sort change', () {
      final withFacets = base.copyWith(tagIds: const [15]);
      expect(withFacets.copyWith(sort: 'price_asc').tagIds, [15]);
    });
  });

  group('FilterSelection', () {
    test('toggling adds then removes', () {
      var s = const FilterSelection();
      s = s.toggleAttribute(21);
      expect(s.attributeIds, {21});
      s = s.toggleAttribute(21);
      expect(s.attributeIds, isEmpty);
    });

    test('counts every kind of choice', () {
      const s = FilterSelection(
        attributeIds: {21, 22},
        tagIds: {15},
        inStockOnly: true,
      );
      expect(s.count, 4);
      expect(s.isEmpty, isFalse);
    });

    // Sorted, so two selections made in a different order produce the same
    // query and the provider does not refetch what it already holds.
    test('emits ids in a stable order', () {
      const a = FilterSelection(attributeIds: {22, 21});
      const b = FilterSelection(attributeIds: {21, 22});
      expect(a.sortedAttributeIds, [21, 22]);
      expect(a.sortedAttributeIds, b.sortedAttributeIds);
      expect(a, b);
    });

    test('an untouched selection is empty', () {
      expect(const FilterSelection().isEmpty, isTrue);
      expect(const FilterSelection().count, 0);
    });
  });
}

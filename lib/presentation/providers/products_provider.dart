import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/network/api_response.dart';
import '../../data/models/product_model.dart';
import '../../data/models/product_variation.dart';
import 'auth_provider.dart';
import 'core_providers.dart';

/// Query key for a catalog listing (catalog / search / by-category / by-brand).
class ProductQuery {
  const ProductQuery({
    this.search,
    this.categoryId,
    this.brandId,
    this.sort,
    this.attributeIds = const [],
    this.tagIds = const [],
    this.brandIds = const [],
    this.ratings = const [],
    this.discounts = const [],
    this.collectionIds = const [],
    this.minPrice,
    this.maxPrice,
    this.inStockOnly = false,
  });

  final String? search;
  final int? categoryId;
  final int? brandId;
  final String? sort;

  /// Facet selections, as sent to `GetProductService`. Each is an AND against
  /// the others and an OR within itself, which is what the server does.
  final List<int> attributeIds;
  final List<int> tagIds;
  final List<int> brandIds;

  /// `rating_4` / `on_sale` / `discount_25` — prefixed tokens, not numbers.
  final List<String> ratings;
  final List<String> discounts;
  final List<int> collectionIds;

  /// Rupees, against the price the cards show.
  final double? minPrice;
  final double? maxPrice;

  /// `in_stock=1`. Part of the query — unlike the local pass that backs it up —
  /// so paging asks the server for more *in-stock* products rather than more
  /// products it then has to hide.
  final bool inStockOnly;

  bool get hasFacets =>
      attributeIds.isNotEmpty ||
      tagIds.isNotEmpty ||
      brandIds.isNotEmpty ||
      ratings.isNotEmpty ||
      discounts.isNotEmpty ||
      collectionIds.isNotEmpty ||
      minPrice != null ||
      maxPrice != null ||
      inStockOnly;

  int get facetCount =>
      attributeIds.length +
      tagIds.length +
      brandIds.length +
      ratings.length +
      discounts.length +
      collectionIds.length +
      (minPrice == null && maxPrice == null ? 0 : 1) +
      (inStockOnly ? 1 : 0);

  ProductQuery copyWith({
    String? sort,
    List<int>? attributeIds,
    List<int>? tagIds,
    List<int>? brandIds,
    List<String>? ratings,
    List<String>? discounts,
    List<int>? collectionIds,
    double? minPrice,
    double? maxPrice,
    bool? inStockOnly,
    bool clearSort = false,
  }) =>
      ProductQuery(
        search: search,
        categoryId: categoryId,
        brandId: brandId,
        sort: clearSort ? null : (sort ?? this.sort),
        attributeIds: attributeIds ?? this.attributeIds,
        tagIds: tagIds ?? this.tagIds,
        brandIds: brandIds ?? this.brandIds,
        ratings: ratings ?? this.ratings,
        discounts: discounts ?? this.discounts,
        collectionIds: collectionIds ?? this.collectionIds,
        minPrice: minPrice ?? this.minPrice,
        maxPrice: maxPrice ?? this.maxPrice,
        inStockOnly: inStockOnly ?? this.inStockOnly,
      );

  @override
  bool operator ==(Object other) =>
      other is ProductQuery &&
      other.search == search &&
      other.categoryId == categoryId &&
      other.brandId == brandId &&
      other.sort == sort &&
      // The provider is keyed on this object, so a changed selection has to
      // change equality or applying a filter would re-use the old list.
      _sameIds(other.attributeIds, attributeIds) &&
      _sameIds(other.tagIds, tagIds) &&
      _sameIds(other.brandIds, brandIds) &&
      _sameTokens(other.ratings, ratings) &&
      _sameTokens(other.discounts, discounts) &&
      _sameIds(other.collectionIds, collectionIds) &&
      other.minPrice == minPrice &&
      other.maxPrice == maxPrice &&
      other.inStockOnly == inStockOnly;

  @override
  int get hashCode => Object.hash(
        search,
        categoryId,
        brandId,
        sort,
        Object.hashAll(attributeIds),
        Object.hashAll(tagIds),
        Object.hashAll(brandIds),
        Object.hashAll(ratings),
        Object.hashAll(discounts),
        Object.hashAll(collectionIds),
        minPrice,
        maxPrice,
        inStockOnly,
      );

  static bool _sameTokens(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameIds(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class ProductListState {
  const ProductListState({
    this.items = const [],
    this.loading = true,
    this.loadingMore = false,
    this.hasMore = false,
    this.page = 1,
    this.error,
  });

  final List<Product> items;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final int page;

  /// The failure itself, not a flattened string — the UI needs the server's
  /// message, its field errors and the error kind to render properly.
  final ApiException? error;

  bool get isEmpty => !loading && error == null && items.isEmpty;

  ProductListState copyWith({
    List<Product>? items,
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    int? page,
    ApiException? error,
    bool clearError = false,
  }) =>
      ProductListState(
        items: items ?? this.items,
        loading: loading ?? this.loading,
        loadingMore: loadingMore ?? this.loadingMore,
        hasMore: hasMore ?? this.hasMore,
        page: page ?? this.page,
        error: clearError ? null : (error ?? this.error),
      );
}

class ProductsNotifier extends StateNotifier<ProductListState> {
  ProductsNotifier(this._ref, this.query) : super(const ProductListState()) {
    load();
  }

  final Ref _ref;
  final ProductQuery query;
  static const _perPage = 20;

  /// Runs the query for [page].
  ///
  /// Category and brand filtering go through their dedicated routes: the
  /// `categories[]=` query parameter on `/ecommerce/products` is accepted but
  /// never filters, so a category listing built on it always came back empty.
  /// A search term wins over both — the search endpoint is the only one that
  /// takes a keyword.
  Future<PaginatedResponse<Product>> _fetch(int page) {
    final repo = _ref.read(catalogRepositoryProvider);
    final hasSearch = (query.search ?? '').isNotEmpty;

    if (!hasSearch && query.categoryId != null) {
      return repo.productsByCategory(
        query.categoryId!,
        page: page,
        perPage: _perPage,
        sort: query.sort,
        attributeIds: query.attributeIds,
        tagIds: query.tagIds,
        brandIds: query.brandIds,
        ratings: query.ratings,
        discounts: query.discounts,
        collectionIds: query.collectionIds,
        minPrice: query.minPrice,
        maxPrice: query.maxPrice,
        inStockOnly: query.inStockOnly,
      );
    }
    if (!hasSearch && query.brandId != null) {
      return repo.productsByBrand(
        query.brandId!,
        page: page,
        perPage: _perPage,
        sort: query.sort,
      );
    }
    return repo.products(
      page: page,
      perPage: _perPage,
      search: query.search,
      sort: query.sort,
    );
  }

  Future<void> load() async {
    state = const ProductListState(loading: true);
    try {
      final res = await _fetch(1);
      state = ProductListState(
        items: res.items,
        loading: false,
        hasMore: res.hasMore,
        page: 1,
      );
    } on ApiException catch (e) {
      // Already logged by ApiClient — just surface it.
      state = ProductListState(loading: false, error: e);
    }
  }

  Future<void> loadMore() async {
    if (state.loadingMore || !state.hasMore || state.loading) return;
    state = state.copyWith(loadingMore: true);
    try {
      final next = state.page + 1;
      final res = await _fetch(next);
      state = state.copyWith(
        items: [...state.items, ...res.items],
        loadingMore: false,
        hasMore: res.hasMore,
        page: next,
      );
    } on ApiException catch (e) {
      state = state.copyWith(loadingMore: false, error: e);
    }
  }

  Future<void> refresh() => load();
}

final productsProvider = StateNotifierProvider.autoDispose
    .family<ProductsNotifier, ProductListState, ProductQuery>(
  (ref, query) => ProductsNotifier(ref, query),
);

/// Whether this customer has already asked to be told when a product returns.
///
/// Only meaningful signed in — the endpoint is behind `auth:sanctum`, and an
/// anonymous call is answered with a redirect to the web login page, so it is
/// not even attempted. Signed out the answer is simply false, and the button it
/// drives sends the customer to sign in.
final stockSubscriptionProvider =
    FutureProvider.autoDispose.family<bool, int>((ref, productId) async {
  if (!ref.watch(isAuthenticatedProvider)) return false;
  return ref.watch(catalogRepositoryProvider).isSubscribedToStock(productId);
});

/// Merchandising rails on the product page.
///
/// Both are `autoDispose` — they are worth one request while a product page is
/// open and nothing afterwards — and both resolve to an empty list rather than
/// an error, because a missing "you may also like" is not a reason to show the
/// customer a failure on a page that otherwise loaded.
final relatedProductsProvider =
    FutureProvider.autoDispose.family<List<Product>, String>((ref, slug) async {
  return ref.watch(catalogRepositoryProvider).relatedProducts(slug);
});

final crossSaleProductsProvider =
    FutureProvider.autoDispose.family<List<Product>, String>((ref, slug) async {
  return ref.watch(catalogRepositoryProvider).crossSaleProducts(slug);
});

/// Detail lookup by slug (deep links / cart snapshots), **with variations**.
///
/// The variation block rides on this one response as siblings of `data`, so a
/// screen that has this has everything it needs to render a picker — no second
/// request, and no way for the two to disagree.
final productDetailProvider =
    FutureProvider.autoDispose.family<ProductDetail?, String>((ref, slug) async {
  return ref.watch(catalogRepositoryProvider).productDetail(slug);
});

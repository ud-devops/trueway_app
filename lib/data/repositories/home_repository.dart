import '../../core/errors/api_exception.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_response.dart';
import '../models/brand_model.dart';
import '../models/home_sections.dart';

/// Home screen + catalogue-chrome reads: the four product carousels, the filter
/// facets, flash sales and brands.
///
/// All calls are public (no bearer needed) and flow through [ApiClient], which
/// injects the API key and normalizes failures to [ApiException].
class HomeRepository {
  HomeRepository(this._api);

  final ApiClient _api;

  /// The `limit` the endpoint is asked for by default. The controller's own
  /// default is 4 and it hard-caps at 20.
  static const int defaultSectionLimit = 4;

  /// `?limit=1` makes the endpoint return **HTTP 500** (verified live, twice —
  /// the top-selling query's `distinct()` + `limit(1)` blows up on the join).
  /// Anything from 2 up is fine, so one product per carousel is simply not
  /// orderable; ask for two and let the UI take the first.
  static const int minSectionLimit = 2;
  static const int maxSectionLimit = 20;

  /// The four home carousels in a single round trip.
  ///
  /// Replaces four separate list calls — that is the entire point of this
  /// endpoint.
  ///
  /// The route moved: it is now registered under `api/v1/ecommerce`, and the
  /// old unprefixed path 404s (verified live). [ApiEndpoints.topProductsGroup]
  /// still holds the old path and is not ours to change, so the prefixed path
  /// is tried first and the constant is kept as the fallback — whichever the
  /// deployed backend serves, this works. See the follow-up note in the report.
  Future<HomeSections> sections({int limit = defaultSectionLimit}) async {
    final safeLimit = limit.clamp(minSectionLimit, maxSectionLimit);
    final query = {'limit': safeLimit};

    dynamic body;
    try {
      body = (await _api.get(_topProductsGroupPrefixed, query: query)).data;
    } on ApiException catch (e) {
      if (e.kind != ApiErrorKind.notFound) rethrow;
      body = (await _api.get(ApiEndpoints.topProductsGroup, query: query)).data;
    }

    if (body is! Map) return HomeSections.empty;
    return HomeSections.fromJson(Map<String, dynamic>.from(body));
  }

  static const String _topProductsGroupPrefixed =
      '/ecommerce/top-products-group';

  /// Facets for the catalogue UI.
  ///
  /// [categoryId] scopes the facets (it narrows `max_price` and prunes brands
  /// and tags to that branch). It does NOT make the categories usable as a
  /// product query — see [FilterCategoryNode].
  ///
  /// [priceRanges] must be echoed back for [CatalogFilters.priceRanges] to be
  /// populated at all. `EcommerceHelper::dataPriceRangesForFilter` reads
  /// `request()->query('price_ranges')` and returns the entries verbatim — the
  /// server never originates one — so omitting the parameter, as this method
  /// used to, guaranteed an empty list on every call and made the whole
  /// [FilterPriceRange] type unreachable.
  Future<CatalogFilters> filters({
    int? categoryId,
    List<FilterPriceRange> priceRanges = const [],
  }) async {
    final res = await _api.get(
      ApiEndpoints.filters,
      query: {
        if (categoryId != null) 'categories[]': categoryId,
        if (priceRanges.isNotEmpty)
          'price_ranges': [for (final r in priceRanges) r.toQuery()],
      },
    );
    final body = res.data;
    if (body is! Map) return CatalogFilters.empty;
    return CatalogFilters.fromJson(Map<String, dynamic>.from(body));
  }

  /// Active flash sales.
  ///
  /// Returned `{"error":false,"data":[],"message":null}` on every probe — this
  /// store has never run one, so the populated row shape is source-derived
  /// only. Callers should treat a non-empty result as unproven and degrade
  /// gracefully rather than assuming fields are present.
  ///
  /// [ids] maps to the endpoint's `keys` parameter, which despite its name is
  /// matched against flash sale **ids** (`whereIn('id', $keys)`). Passing a
  /// non-array `keys` is a 422.
  Future<List<FlashSale>> flashSales({List<int>? ids}) async {
    final res = await _api.get(
      ApiEndpoints.flashSales,
      query: {
        if (ids != null && ids.isNotEmpty) 'keys[]': ids,
      },
    );
    return unwrapList(res.data, FlashSale.fromJson);
  }

  /// Only the sales worth putting on screen.
  Future<List<FlashSale>> liveFlashSales() async =>
      (await flashSales()).where((s) => s.isLive).toList();

  /// Brands, for a brand filter — **every** page, not just the first.
  ///
  /// `BrandController::index` ends in `->paginate(config('ecommerce.pagination
  /// .per_page', 16))`: the documented `per_page` query parameter is never
  /// read, so 16 rows per page is a hard ceiling and paging is the only way
  /// past it. Taking page 1 as the whole list — which is what this did, and
  /// what `CatalogRepository.brands()` still does — silently hides brand 17
  /// onwards from the filter, and a filter that omits brands is worse than no
  /// filter. The store has one brand today, so the loop costs one request now
  /// and stays correct later.
  ///
  /// Unlike categories, `brands[]=` on the product list is honoured, so these
  /// ids are real query parameters.
  static const int maxBrandPages = 20;

  Future<List<Brand>> brands() async {
    final all = <Brand>[];
    for (var page = 1; page <= maxBrandPages; page++) {
      final res = await _api.get(ApiEndpoints.brands, query: {'page': page});
      final result = _brandPage(res.data);
      all.addAll(result.items);
      if (result.items.isEmpty || !result.hasMore) break;
    }
    return all;
  }

  /// The brands envelope is the hybrid one — `data` + `links` + `meta` *and*
  /// `error`/`message`. [PaginatedResponse.fromJson] hard-casts `data` to a
  /// `List`, so anything else (a `{data: {...}}` body, a bare array, a string)
  /// is unwrapped the tolerant way and reported as a single terminal page.
  PaginatedResponse<Brand> _brandPage(dynamic body) {
    if (body is Map<String, dynamic> && body['data'] is List) {
      return PaginatedResponse.fromJson(body, Brand.fromJson);
    }
    final items = unwrapList(body, Brand.fromJson);
    return PaginatedResponse(
      items: items,
      meta: PaginationMeta.single(items.length),
    );
  }
}

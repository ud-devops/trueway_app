import '../../core/errors/api_exception.dart';
import '../../core/errors/error_presenter.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_response.dart';
import '../../core/utils/json_utils.dart';
import '../models/ad_model.dart';
import '../models/brand_model.dart';
import '../models/category_model.dart';
import '../models/product_model.dart';
import '../models/product_variation.dart';
import '../models/slider_model.dart';

/// Read-only catalog access. All calls flow through [ApiClient], which injects
/// the API key + bearer token and normalizes errors to ApiException.
class CatalogRepository {
  CatalogRepository(this._api);

  final ApiClient _api;

  /// [attributeIds] filters to products carrying any of those attribute values.
  ///
  /// Only *variable* products carry attributes, so passing every attribute id
  /// in the catalogue returns exactly the set of variable products — which is
  /// the only way the app can find out, since a listing row does not say. See
  /// `variableProductIdsProvider`.
  Future<PaginatedResponse<Product>> products({
    int page = 1,
    int perPage = 20,
    String? search,
    int? categoryId,
    int? brandId,
    List<int>? attributeIds,
    String? sort,
  }) async {
    final res = await _api.get(
      ApiEndpoints.products,
      query: {
        'page': page,
        'per_page': perPage,
        // The backend's search parameter is `q`. This sent `keyword`, which the
        // API silently ignores — it returned the FULL catalogue for every
        // query, so search results were never actually filtered. Verified live:
        // `?keyword=khand` -> 4 results (all of them), `?q=khand` -> 1.
        if (search != null && search.isNotEmpty) 'q': search,
        if (categoryId != null) 'categories[]': categoryId,
        if (brandId != null) 'brands[]': brandId,
        if (attributeIds != null && attributeIds.isNotEmpty)
          'attributes[]': attributeIds,
        if (sort != null) 'sort-by': sort,
      },
    );
    return PaginatedResponse.fromJson(
      res.data as Map<String, dynamic>,
      Product.fromJson,
    );
  }

  /// Product detail.
  ///
  /// `GET /ecommerce/products/{slug}` DOES work (verified live: HTTP 200 with a
  /// full product object), contrary to the earlier note here claiming the dev
  /// backend had no stable by-slug route. The fallback below is kept as a
  /// safety net but should almost never run.
  ///
  /// The fallback used to fetch the first 100 products and linear-scan them,
  /// which downloaded the whole catalogue on every deep link and silently
  /// returned "not found" for anything past item 100. It now searches on the
  /// slug's own words, so the cost stays flat as the catalogue grows.
  Future<Product?> productBySlug(String slug) async =>
      (await productDetail(slug))?.product;

  /// Product detail **with its variations**.
  ///
  /// `GET /ecommerce/products/{slug}` returns the variation block as four
  /// **siblings of `data`** — `default_product_variation`, `attribute_sets`,
  /// `unavailable_attribute_ids`, `selected_attributes`. A parser that only
  /// unwraps `data` drops the entire feature, which is what [productBySlug] did
  /// until now: variable products rendered as though they had one fixed price.
  ///
  /// The fallback paths cannot carry variations — search and the catalogue scan
  /// return list rows, which have no such keys — so they yield
  /// [ProductVariationOptions.none] and the screen shows a simple product.
  /// That is the honest degradation: better a product without a picker than a
  /// picker built from attributes nobody sent.
  Future<ProductDetail?> productDetail(String slug) async {
    try {
      final res = await _api.get(ApiEndpoints.productBySlug(slug));
      final obj = unwrapObject(res.data, Product.fromJson);
      if (obj != null) {
        final body = res.data;
        return ProductDetail(
          product: obj,
          variations: body is Map
              ? ProductVariationOptions.fromEnvelope(
                  Map<String, dynamic>.from(body),
                )
              : ProductVariationOptions.none,
        );
      }
    } on ApiException {
      // Detail route unavailable for this backend — fall through to search.
    }

    final found = await _productBySlugFallback(slug);
    return found == null
        ? null
        : ProductDetail(
            product: found,
            variations: ProductVariationOptions.none,
          );
  }

  /// Resolves an attribute selection to one buyable variation.
  ///
  /// [parentId] is the **parent** product's id — the endpoint is
  /// `/product-variation/{parent}?attributes[]=…`, not `/{variation}`.
  ///
  /// Returns null when [attributeIds] is empty. The backend's written guide
  /// says that case returns 400; it returns **200 with the base product**
  /// (verified live), which would look like a successful resolve to a caller
  /// and put the *parent* id in the cart. Treating it as a no-op here is what
  /// stops that.
  Future<ProductVariation?> resolveVariation({
    required int parentId,
    required List<int> attributeIds,
  }) async {
    if (attributeIds.isEmpty) return null;

    final res = await _api.get(
      ApiEndpoints.productVariation(parentId),
      query: {'attributes[]': attributeIds},
    );

    final body = res.data;
    final data = body is Map && body['data'] is Map ? body['data'] : body;
    if (data is! Map) return null;

    final variation = ProductVariation.fromJson(
      Map<String, dynamic>.from(data),
    );
    // A resolve that came back without an id resolved nothing; adding that to
    // the cart would post product 0.
    return variation.id > 0 ? variation : null;
  }

  Future<Product?> _productBySlugFallback(String slug) async {

    // Slugs are hyphenated names ("organic-sona-moti-wheat"), so the words make
    // a good keyword query.
    final keyword = slug.replaceAll('-', ' ').trim();
    if (keyword.isEmpty) return null;

    final matches = await products(search: keyword, perPage: _slugSearchPageSize);
    for (final p in matches.items) {
      if (p.slug == slug) return p;
    }

    // Keyword search can miss when the slug diverges from the product name
    // (renamed products keep their original slug). Fall back to a bounded scan
    // rather than an unbounded one.
    return _findBySlugInCatalog(slug);
  }

  static const int _slugSearchPageSize = 30;
  static const int _maxFallbackPages = 5;

  Future<Product?> _findBySlugInCatalog(String slug) async {
    for (var page = 1; page <= _maxFallbackPages; page++) {
      final res = await products(page: page, perPage: _slugSearchPageSize);
      for (final p in res.items) {
        if (p.slug == slug) return p;
      }
      if (!res.hasMore) break;
    }
    return null;
  }

  /// Products the merchant has linked as related to [slug].
  ///
  /// Rows use the same `AvailableProductResource` shape as a listing, so they
  /// render in the ordinary grid tile. Verified live: 3 rows for SKU 118.
  ///
  /// Merchandising, not a core path — an empty list simply means nothing was
  /// linked, and a failure means the section is not drawn. Neither is worth
  /// interrupting a product page for, so [relatedProducts] and
  /// [crossSaleProducts] both answer with an empty list rather than throwing.
  Future<List<Product>> relatedProducts(String slug) =>
      _merchandising(ApiEndpoints.relatedProducts(slug), 'related');

  /// Products the merchant cross-sells with [slug] ("frequently bought with").
  ///
  /// Live on this store this is **empty for every product** — nothing has been
  /// configured in admin. The call is wired anyway because it costs one request
  /// only where it is watched, and the section hides itself when empty.
  Future<List<Product>> crossSaleProducts(String slug) =>
      _merchandising(ApiEndpoints.crossSaleProducts(slug), 'cross-sale');

  Future<List<Product>> _merchandising(String path, String label) async {
    try {
      final res = await _api.get(path);
      return unwrapList(res.data, Product.fromJson);
    } on ApiException catch (e) {
      // Already logged by ApiClient. A missing merchandising block must never
      // take the product page down with it.
      ErrorLog.capture(e, context: 'catalog.$label');
      return const [];
    }
  }

  // ---- back-in-stock ------------------------------------------------------
  //
  // The only writes in this otherwise read-only repository. They live here
  // because they are keyed on a product, and both need a bearer token —
  // `ProductNotifyController` is inside the `auth:sanctum` group, and an
  // unauthenticated call is answered with a 302 to the web login page rather
  // than a 401.

  /// Asks the server to email this customer when [productId] is back in stock.
  ///
  /// Returns the server's own sentence either way. It is written for the
  /// customer and says more than a generic toast could — the controller
  /// distinguishes *"We will notify you…"* from *"You will be notified…"* for
  /// an existing subscription, and refuses with a reason:
  ///
  ///  * `Your account does not have a valid email address.` — the notification
  ///    is an email, so a phone-only OTP account cannot subscribe;
  ///  * `Product not found.` — also returned for a **variation** id, since the
  ///    controller filters `is_variation: false`;
  ///  * `This product is already in stock.`
  ///
  /// A refusal arrives as HTTP 200 with `error: true`, which `ApiClient` has
  /// already turned into an [ApiException]; it is caught here so the caller
  /// gets one shape rather than a mix of returns and throws.
  Future<({bool subscribed, String message})> notifyWhenInStock(
    int productId,
  ) async {
    try {
      final res = await _api.post(ApiEndpoints.notifyMe(productId));
      final data = asMap(res.data)['data'];
      return (
        subscribed: asBool(asMap(data)['is_subscribed'], true),
        message: asString(
          asMap(res.data)['message'],
          'We will notify you when this product is back in stock.',
        ),
      );
    } on ApiException catch (e) {
      return (subscribed: false, message: e.message);
    }
  }

  /// Whether this customer already asked to be told about [productId].
  ///
  /// False on any failure: the button it drives is an offer, and offering it
  /// twice is a smaller wrong than hiding it because a status check failed.
  Future<bool> isSubscribedToStock(int productId) async {
    try {
      final res = await _api.get(ApiEndpoints.notifyMeStatus(productId));
      return asBool(asMap(asMap(res.data)['data'])['is_subscribed']);
    } on ApiException catch (e) {
      ErrorLog.capture(e, context: 'catalog.notifyMeStatus');
      return false;
    }
  }

  /// Top-level shop categories, each with its children attached.
  ///
  /// The endpoint returns a flat list; [Category.buildTree] nests it.
  Future<List<Category>> categories() async {
    final res = await _api.get(ApiEndpoints.productCategories);
    return Category.buildTree(unwrapList(res.data, Category.fromJson));
  }

  /// The flat, unnested category list — for pickers that don't want a tree.
  Future<List<Category>> allCategories() async {
    final res = await _api.get(ApiEndpoints.productCategories);
    return unwrapList(res.data, Category.fromJson);
  }

  /// Products in a category.
  ///
  /// Uses the path route rather than `?categories[]=`, which the API accepts
  /// but silently ignores — it returns 0 rows for every id.
  /// The facet filters this route honours, verified live against category 17.
  ///
  /// `ProductCategoryController::products` merges the category (and its
  /// children) into `categories` and hands the request to the **same**
  /// `GetProductService` the flat product list uses — so every filter that
  /// works there works here too. Confirmed on 2026-08-11: baseline 5 products,
  /// `attributes[]=22` → 2, `tags[]=15` → 2, `ratings[]=rating_4` → 2,
  /// `discounts[]=on_sale` → 5, `discounts[]=discount_40` → 0.
  ///
  /// `min_price` / `max_price` compare the **same `price` the product resource
  /// returns**, since the backend fix of 2026-08-12. Re-verified that day:
  /// `max_price=900` returns only the ₹445.20 product, `min_price=900&
  /// max_price=950` returns exactly the three in that band, and `sort-by=
  /// price_asc` is now monotonic — the product that used to jump between both
  /// ends of the sort had a null key and no longer does. Before that fix a
  /// rupee slider would have contradicted the prices beside it.
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
    final res = await _api.get(
      ApiEndpoints.productsInCategory(categoryId),
      query: {
        'page': page,
        'per_page': perPage,
        if (sort != null) 'sort-by': sort,
        // Repeated keys rather than a comma-joined string. `parseFilterParams`
        // accepts either, but the repeated form is what the rest of this file
        // already sends and what the storefront's own links use.
        if (attributeIds.isNotEmpty) 'attributes[]': attributeIds,
        if (tagIds.isNotEmpty) 'tags[]': tagIds,
        if (brandIds.isNotEmpty) 'brands[]': brandIds,
        // Prefixed tokens, not bare numbers. `ProductRepository` matches these
        // with `str_starts_with($f, 'rating_')` and `'discount_'`, so
        // `ratings[]=4` parses fine and then filters nothing at all — which is
        // exactly how this looked broken on first probe.
        if (ratings.isNotEmpty) 'ratings[]': ratings,
        if (discounts.isNotEmpty) 'discounts[]': discounts,
        if (collectionIds.isNotEmpty) 'collections[]': collectionIds,
        if (minPrice != null) 'min_price': minPrice,
        if (maxPrice != null) 'max_price': maxPrice,
        if (inStockOnly) 'in_stock': 1,
      },
    );
    return _paginated(res.data);
  }

  /// Products for a brand. `brands[]=` *is* honoured, but the dedicated route
  /// keeps this symmetrical with categories.
  Future<PaginatedResponse<Product>> productsByBrand(
    int brandId, {
    int page = 1,
    int perPage = 20,
    String? sort,
  }) async {
    final res = await _api.get(
      ApiEndpoints.productsInBrand(brandId),
      query: {
        'page': page,
        'per_page': perPage,
        if (sort != null) 'sort-by': sort,
      },
    );
    return _paginated(res.data);
  }

  /// Some list routes return a bare `{data: [...]}` with no pagination meta.
  PaginatedResponse<Product> _paginated(dynamic body) {
    if (body is Map<String, dynamic>) {
      return PaginatedResponse.fromJson(body, Product.fromJson);
    }
    final items = unwrapList(body, Product.fromJson);
    return PaginatedResponse(
      items: items,
      meta: PaginationMeta.single(items.length),
    );
  }

  Future<List<Brand>> brands() async {
    final res = await _api.get(ApiEndpoints.brands);
    return unwrapList(res.data, Brand.fromJson);
  }

  Future<List<HomeSlider>> sliders() async {
    final res = await _api.get(ApiEndpoints.sliders);
    final all = unwrapList(res.data, HomeSlider.fromJson);
    // Keep only sliders that actually have items.
    return all.where((s) => s.items.isNotEmpty).toList();
  }

  Future<List<AdBanner>> ads() async {
    final res = await _api.get(ApiEndpoints.ads);
    final all = unwrapList(res.data, AdBanner.fromJson)
      ..sort((a, b) => a.order.compareTo(b.order));
    return all.where((a) => a.image.isNotEmpty).toList();
  }
}

import 'package:trueway_farms/core/network/api_response.dart';
import 'package:trueway_farms/data/models/product_model.dart';
import 'package:trueway_farms/data/models/product_variation.dart';
import 'package:trueway_farms/data/repositories/catalog_repository.dart';

/// Stands in for product detail, which the catalogue **listing** cannot answer.
///
/// A grid tile's ADD has to know whether the product has packs to choose from,
/// and `AvailableProductResource` does not say — a simple and a variable
/// product serialise identically in a listing. So the tile asks
/// `GET /products/{slug}`, and this is that seam. Without it a widget test
/// reaches for a real `ApiClient`.
///
/// Defaults to a **simple** product, which is what most tests want: ADD adds.
class FakeCatalogRepository implements CatalogRepository {
  FakeCatalogRepository({
    this.product,
    this.variations,
    this.variableProducts = const [],
  });

  /// What `products(attributeIds: …)` answers with — the variable products, in
  /// the one query that can identify them.
  final List<Product> variableProducts;

  final List<List<int>> attributeQueries = [];

  /// The product `productDetail` answers with. Null yields a not-found, which
  /// callers must treat as "assume simple" rather than as a blocker.
  final Product? product;

  /// The variation block. Null means a simple product.
  final ProductVariationOptions? variations;

  final List<String> detailRequests = [];
  final List<List<int>> resolveRequests = [];

  /// The variation `resolveVariation` answers with, if any.
  ProductVariation? resolved;

  @override
  Future<ProductDetail?> productDetail(String slug) async {
    detailRequests.add(slug);
    final p = product;
    if (p == null) return null;
    return ProductDetail(
      product: p,
      variations: variations ?? ProductVariationOptions.none,
    );
  }

  @override
  Future<Product?> productBySlug(String slug) async =>
      (await productDetail(slug))?.product;

  @override
  Future<PaginatedResponse<Product>> products({
    int page = 1,
    int perPage = 20,
    String? search,
    int? categoryId,
    int? brandId,
    List<int>? attributeIds,
    String? sort,
  }) async {
    if (attributeIds != null) attributeQueries.add(attributeIds);
    // Only the attribute-filtered form is used by the code under test; a
    // second page would loop, so page 2 is always empty.
    final items = page == 1 && attributeIds != null ? variableProducts : const <Product>[];
    return PaginatedResponse<Product>(
      items: items,
      meta: PaginationMeta(
        currentPage: page,
        lastPage: 1,
        perPage: perPage,
        total: items.length,
      ),
    );
  }

  @override
  Future<ProductVariation?> resolveVariation({
    required int parentId,
    required List<int> attributeIds,
  }) async {
    resolveRequests.add(attributeIds);
    return resolved;
  }

  /// Back-in-stock subscribe calls, in order. Ids only — the endpoint takes
  /// nothing else.
  final List<int> notifyRequests = [];

  /// What `notifyWhenInStock` answers with. The real repository turns a
  /// refusal into `(subscribed: false, message: <the server's sentence>)`
  /// rather than throwing, so a refusal is set here, not with an exception.
  ({bool subscribed, String message}) notifyResult = (
    subscribed: true,
    message: 'We will notify you when this product is back in stock.',
  );

  /// What `isSubscribedToStock` answers with.
  bool subscribedToStock = false;

  @override
  Future<({bool subscribed, String message})> notifyWhenInStock(
    int productId,
  ) async {
    notifyRequests.add(productId);
    return notifyResult;
  }

  @override
  Future<bool> isSubscribedToStock(int productId) async => subscribedToStock;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'FakeCatalogRepository does not implement ${invocation.memberName}',
      );
}

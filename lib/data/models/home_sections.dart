import '../../core/utils/json_utils.dart';
import '../../core/utils/price_utils.dart';
import 'product_model.dart';

/// The four home carousels, delivered by one call to `/top-products-group`.
///
/// The backend serializes every carousel item with `AvailableProductResource` —
/// the *same* resource `/ecommerce/products` uses. Verified key-for-key against
/// the captured payloads: both produce the identical 28-key object, so
/// [Product.fromJson] is the correct parser here and no home-specific product
/// model is needed.
class HomeSections {
  const HomeSections({
    required this.topSelling,
    required this.trending,
    required this.recentlyAdded,
    required this.topRated,
  });

  final List<Product> topSelling;
  final List<Product> trending;
  final List<Product> recentlyAdded;
  final List<Product> topRated;

  static const HomeSections empty = HomeSections(
    topSelling: [],
    trending: [],
    recentlyAdded: [],
    topRated: [],
  );

  /// True when every carousel came back empty.
  ///
  /// Individual sections empty out routinely — `top_selling` is computed from
  /// paid orders in the last 30 days and `top_rated` needs reviews, so a quiet
  /// month legitimately yields two empty carousels. Only the all-empty case
  /// means "nothing to show".
  bool get isEmpty =>
      topSelling.isEmpty &&
      trending.isEmpty &&
      recentlyAdded.isEmpty &&
      topRated.isEmpty;

  /// The non-empty carousels in display order, ready to render.
  List<HomeSection> get sections => [
        HomeSection(HomeSectionKind.topSelling, topSelling),
        HomeSection(HomeSectionKind.trending, trending),
        HomeSection(HomeSectionKind.recentlyAdded, recentlyAdded),
        HomeSection(HomeSectionKind.topRated, topRated),
      ].where((s) => s.products.isNotEmpty).toList();

  /// Accepts either the full envelope (`{error, data, message}`) or the bare
  /// `data` object, so callers can hand over whichever they hold.
  factory HomeSections.fromJson(Map<String, dynamic> json) {
    final data = json['data'] is Map ? asMap(json['data']) : json;
    List<Product> section(String key) =>
        asMapList(data[key]).map(Product.fromJson).toList();

    return HomeSections(
      topSelling: section('top_selling'),
      trending: section('trending'),
      recentlyAdded: section('recently_added'),
      topRated: section('top_rated'),
    );
  }
}

enum HomeSectionKind {
  topSelling('Best sellers'),
  trending('Trending now'),
  recentlyAdded('New arrivals'),
  topRated('Top rated');

  const HomeSectionKind(this.title);

  final String title;
}

class HomeSection {
  const HomeSection(this.kind, this.products);

  final HomeSectionKind kind;
  final List<Product> products;

  String get title => kind.title;
}

// =============================================================================
// /ecommerce/filters
// =============================================================================

/// A category advertised by the filter endpoint.
///
/// Deliberately *not* a query parameter. `/ecommerce/products?categories[]=17`
/// is accepted and silently ignored (0 rows for every id), so these entries are
/// navigation targets — push the category products route with [id] instead.
class FilterCategoryNode {
  const FilterCategoryNode({
    required this.id,
    required this.name,
    required this.slug,
    required this.url,
    required this.parentId,
  });

  final int id;
  final String name;
  final String slug;

  /// Relative web path, e.g. `product-categories/wheat-flour` — not an API URL.
  final String url;

  /// 0 for a top-level category.
  final int parentId;

  bool get isRoot => parentId == 0;

  factory FilterCategoryNode.fromJson(Map<String, dynamic> j) =>
      FilterCategoryNode(
        id: asInt(j['id']),
        name: asString(j['name']),
        slug: asString(j['slug']),
        url: asString(j['url']),
        parentId: asInt(j['parent_id']),
      );
}

/// A brand or tag facet. Both arrive with an identical five-key shape, so one
/// class covers them; [CatalogFilters.brands] and [CatalogFilters.tags] keep
/// them apart.
class FilterFacet {
  const FilterFacet({
    required this.id,
    required this.name,
    required this.slug,
    required this.url,
    required this.productsCount,
  });

  final int id;
  final String name;
  final String slug;

  /// Absolute storefront URL the web site would navigate to. Useless to the
  /// app beyond debugging — the id is what the API takes.
  final String url;
  final int productsCount;

  factory FilterFacet.fromJson(Map<String, dynamic> j) => FilterFacet(
        id: asInt(j['id']),
        name: asString(j['name']),
        slug: asString(j['slug']),
        url: asString(j['url']),
        productsCount: asInt(j['products_count']),
      );
}

/// One `price_ranges[n]` entry.
///
/// Not a facet the server computes: `EcommerceHelper::dataPriceRangesForFilter`
/// simply echoes back whatever `price_ranges[]` the *request* carried, dropping
/// entries that aren't numeric. It is therefore empty on every unfiltered call,
/// and the echo comes back as strings (`{"from":"0","to":"500"}`) even when the
/// request sent numbers — hence [asDouble] on both ends.
class FilterPriceRange {
  const FilterPriceRange({required this.from, required this.to});

  final double from;
  final double to;

  String get label => '${PriceUtils.format(from)} – ${PriceUtils.format(to)}';

  factory FilterPriceRange.fromJson(Map<String, dynamic> j) => FilterPriceRange(
        from: asDouble(j['from']),
        to: asDouble(j['to']),
      );

  Map<String, dynamic> toQuery() => {'from': from, 'to': to};
}

/// One selectable value inside an attribute set ("5 Kg", "1.85 KG (Pack of 1)").
class FilterAttributeValue {
  const FilterAttributeValue({
    required this.id,
    required this.title,
    required this.slug,
    required this.isDefault,
    required this.isSelected,
    this.color,
    this.imageUrl,
  });

  final int id;
  final String title;
  final String slug;

  /// `is_default` arrives as int 1/0, `is_selected` as a real bool — [asBool]
  /// flattens both.
  final bool isDefault;
  final bool isSelected;

  /// CSS colour string like `rgb(0, 0, 0)`, or null: the server sends `""` for
  /// "no swatch", which [asStringOrNull] maps to null.
  final String? color;
  final String? imageUrl;

  factory FilterAttributeValue.fromJson(Map<String, dynamic> j) =>
      FilterAttributeValue(
        id: asInt(j['id']),
        title: asString(j['title']),
        slug: asString(j['slug']),
        isDefault: asBool(j['is_default']),
        isSelected: asBool(j['is_selected']),
        color: asStringOrNull(j['color']),
        imageUrl: asStringOrNull(j['image']),
      );
}

/// An attribute set — "Weight", "Pack Size" — and its values.
class FilterAttributeSet {
  const FilterAttributeSet({
    required this.id,
    required this.title,
    required this.slug,
    required this.displayLayout,
    required this.values,
  });

  final int id;
  final String title;
  final String slug;

  /// Server's rendering hint (`price-box`, `swatch-color`, …). Advisory only.
  final String displayLayout;
  final List<FilterAttributeValue> values;

  List<FilterAttributeValue> get selected =>
      values.where((v) => v.isSelected).toList();

  factory FilterAttributeSet.fromJson(Map<String, dynamic> j) =>
      FilterAttributeSet(
        id: asInt(j['id']),
        title: asString(j['title']),
        slug: asString(j['slug']),
        displayLayout: asString(j['display_layout']),
        values: asMapList(j['attributes'])
            .map(FilterAttributeValue.fromJson)
            .toList(),
      );
}

/// Facets for the catalogue UI, from `GET /ecommerce/filters`.
/// A facet the server identifies by a **string token** rather than an id —
/// `on_sale`, `discount_20`, `rating_4`.
///
/// The token goes back verbatim in `discounts[]` / `ratings[]`; the app does no
/// prefix handling of its own. It used to hardcode this vocabulary out of the
/// PHP source, which meant an admin could not change the bands without a mobile
/// release.
class FilterTokenFacet {
  const FilterTokenFacet({
    required this.token,
    required this.name,
    required this.productsCount,
  });

  final String token;
  final String name;
  final int productsCount;

  factory FilterTokenFacet.fromJson(Map<String, dynamic> j) => FilterTokenFacet(
        token: asString(j['id']),
        name: asString(j['name']),
        productsCount: asInt(j['products_count']),
      );
}

class CatalogFilters {
  const CatalogFilters({
    required this.categories,
    required this.brands,
    required this.tags,
    required this.priceRanges,
    required this.maxPrice,
    required this.currentCategoryId,
    required this.currentFilterCategoryIds,
    required this.attributeSets,
    this.collections = const [],
    this.discountRanges = const [],
    this.ratingRanges = const [],
  });

  final List<FilterCategoryNode> categories;
  final List<FilterFacet> brands;
  final List<FilterFacet> tags;
  final List<FilterPriceRange> priceRanges;

  /// Highest product price in the current scope — the upper bound for a price
  /// slider. Narrows when the request is scoped to a category (4444 for
  /// category 17 vs 40005 unscoped).
  final double maxPrice;

  /// Observed as 0 on every probe, including requests that *did* carry
  /// `categories[]` — the server reports the scoping category in
  /// [currentFilterCategoryIds] instead. Treat 0 as "unscoped".
  final int currentCategoryId;

  /// Echo of the request's `categories[]`. Arrives as strings (`["17"]`), and
  /// occasionally as a JSON **object** — see [_categoryIds].
  final List<int> currentFilterCategoryIds;

  final List<FilterAttributeSet> attributeSets;

  /// Merchandising groups — "New Arrival", "Special Offer". Shaped like
  /// [brands] and [tags], and filtered the same way, with `collections[]=<id>`.
  final List<FilterFacet> collections;

  /// Offer and rating bands, e.g. `on_sale` / "On Sale" and `rating_4` /
  /// "4+ Stars". Only bands that match products are returned, and the counts
  /// follow the request's category scope.
  final List<FilterTokenFacet> discountRanges;
  final List<FilterTokenFacet> ratingRanges;

  static const CatalogFilters empty = CatalogFilters(
    categories: [],
    brands: [],
    tags: [],
    priceRanges: [],
    maxPrice: 0,
    currentCategoryId: 0,
    currentFilterCategoryIds: [],
    attributeSets: [],
  );

  List<FilterCategoryNode> get rootCategories =>
      categories.where((c) => c.isRoot).toList();

  List<FilterCategoryNode> childrenOf(int parentId) =>
      categories.where((c) => c.parentId == parentId).toList();

  /// Accepts the full envelope or the bare `data` object.
  factory CatalogFilters.fromJson(Map<String, dynamic> json) {
    final d = json['data'] is Map ? asMap(json['data']) : json;
    return CatalogFilters(
      categories:
          asMapList(d['categories']).map(FilterCategoryNode.fromJson).toList(),
      brands: asMapList(d['brands']).map(FilterFacet.fromJson).toList(),
      tags: asMapList(d['tags']).map(FilterFacet.fromJson).toList(),
      priceRanges:
          asMapList(d['price_ranges']).map(FilterPriceRange.fromJson).toList(),
      maxPrice: asDouble(d['max_price']),
      currentCategoryId: asInt(d['current_category_id']),
      currentFilterCategoryIds: _categoryIds(d['current_filter_categories']),
      attributeSets:
          asMapList(d['attributes']).map(FilterAttributeSet.fromJson).toList(),
      collections:
          asMapList(d['collections']).map(FilterFacet.fromJson).toList(),
      discountRanges: asMapList(d['discount_ranges'])
          .map(FilterTokenFacet.fromJson)
          .toList(),
      ratingRanges:
          asMapList(d['rating_ranges']).map(FilterTokenFacet.fromJson).toList(),
    );
  }

  /// `current_filter_categories` is the one collection in this payload that
  /// `FilterResource` does not run through `->values()`. It is produced by
  /// `EcommerceHelper::dataForFilter` as
  /// `$categoriesRequest = array_filter($categoriesRequest)`, and PHP's
  /// `array_filter` **preserves keys** — so as soon as a falsy entry is dropped
  /// from anywhere but the tail (a `categories[]=0`, or the `array_merge([$id,
  /// $parent_id], …)` branch where a root category's `parent_id` is 0) the
  /// array becomes sparse and `json_encode` emits an object: `{"1":"17"}`
  /// instead of `["17"]`. A List-only check silently returns no scoping ids at
  /// all, so both shapes are accepted.
  static List<int> _categoryIds(dynamic raw) {
    final values = switch (raw) {
      final List l => l,
      final Map m => m.values,
      _ => const [],
    };
    return values.map(asInt).where((id) => id > 0).toList();
  }
}

// =============================================================================
// /ecommerce/flash-sales
// =============================================================================

/// A product inside a flash sale.
///
/// UNVERIFIED AGAINST LIVE DATA: `/ecommerce/flash-sales` returned `[]` on every
/// probe, so this shape is derived from the backend source
/// (`FlashSaleController::formatFlashSale` + `FlashSaleProductResource`) rather
/// than from a captured response. Every field is read defensively; treat a
/// populated response as needing re-verification before shipping UI on it.
///
/// The resource extends `AvailableProductResource` and then *overrides* two of
/// its keys from the pivot row:
///   * `price` becomes the sale price (`original_price` stays the regular one,
///     so [Product.hasDiscount] works out of the box), and
///   * `quantity` becomes the units allocated to the sale, NOT the stock level.
/// The second is a trap, so [product] is parsed from a copy with `quantity`
/// removed — the allocation lives on [saleQuantity] where it belongs, and
/// stock questions go through `product.isOutOfStock`, which stays authoritative.
class FlashSaleProduct {
  const FlashSaleProduct({
    required this.product,
    required this.salePrice,
    required this.salePriceFormatted,
    required this.saleQuantity,
    required this.sold,
    required this.saleCountLeft,
    required this.salePercent,
  });

  final Product product;

  /// Pivot price. Also present as `product.price`.
  final double salePrice;
  final String salePriceFormatted;

  /// Units allocated to this sale.
  final int saleQuantity;
  final int sold;

  /// Server-computed `quantity - sold`. Can go negative if the sale oversells,
  /// so clamp before showing it — see [remaining].
  final int saleCountLeft;

  /// Percentage of the allocation sold, 0–100 (server sends 0 when
  /// [saleQuantity] is 0, avoiding a divide-by-zero).
  final double salePercent;

  int get remaining => saleCountLeft < 0 ? 0 : saleCountLeft;

  /// 0–1, for a progress bar.
  double get soldFraction => (salePercent / 100).clamp(0, 1).toDouble();

  bool get isSoldOut => saleQuantity > 0 && remaining == 0;

  /// The only stock question worth asking about a flash-sale row.
  ///
  /// [Product.inStock] is NOT sufficient here and must not be used on its own:
  /// it reflects `is_out_of_stock`, which `AvailableProductResource` computes
  /// from the **warehouse** quantity and which knows nothing about the sale
  /// allocation. A sale whose 50 units are gone still reports the product as in
  /// stock (the warehouse holds 93), so a card gated on `product.inStock` would
  /// happily add a sold-out unit and let the server price it at full price.
  bool get isPurchasable => product.inStock && !isSoldOut;

  String get priceLabel => PriceUtils.resolve(salePriceFormatted, salePrice);

  factory FlashSaleProduct.fromJson(Map<String, dynamic> j) {
    final forProduct = Map<String, dynamic>.from(j)..remove('quantity');

    // `ec_flash_sale_products.price` is a NULLABLE column (see the plugin's
    // 2021_01_01_044147 migration) and the resource copies it through
    // unguarded, so a row written outside the admin form — which does enforce
    // `products_extra.*.price => required|numeric` — can arrive with
    // `price: null`. Left alone that becomes ₹0.00 next to a "100% OFF" badge,
    // because `original_price` survives the override. Fall back to the regular
    // price instead: no discount is far better than a free product.
    if (forProduct['price'] == null) {
      forProduct['price'] = forProduct['original_price'];
      forProduct['price_formatted'] = forProduct['original_price_formatted'];
    }

    return FlashSaleProduct(
      product: Product.fromJson(forProduct),
      salePrice: asDouble(forProduct['price']),
      salePriceFormatted: asString(forProduct['price_formatted']),
      saleQuantity: asInt(j['quantity']),
      sold: asInt(j['sold']),
      saleCountLeft:
          asInt(j['sale_count_left'], asInt(j['quantity']) - asInt(j['sold'])),
      salePercent: asDouble(j['sale_percent']),
    );
  }
}

/// A flash sale campaign.
///
/// See [FlashSaleProduct] for the verification caveat — the whole flash-sale
/// shape is source-derived, never observed populated.
class FlashSale {
  const FlashSale({
    required this.id,
    required this.name,
    required this.endsAt,
    required this.expired,
    required this.products,
  });

  final int id;
  final String name;

  /// From `end_date`, in **device local time**.
  ///
  /// The wire format is `Y-m-d H:i:s` with no offset (see
  /// `FlashSaleController::formatFlashSale`), and the server's clock is UTC:
  /// `config/app.php` sets `'timezone' => 'UTC'`, and every other timestamp on
  /// this API comes back with a trailing `Z` matching UTC. Handing that bare
  /// string to `DateTime.parse` yields a *device-local* DateTime, which on an
  /// IST phone is 5 h 30 min early — the countdown would hit zero, and
  /// [timeLeft] return `Duration.zero`, while the sale is still running. So it
  /// is parsed as UTC and converted. Null if unparseable.
  final DateTime? endsAt;

  /// The server's own verdict (`end_date < now` at response time). Prefer it
  /// over comparing [endsAt] to the device clock, which may be skewed.
  final bool expired;

  final List<FlashSaleProduct> products;

  /// Only sales worth rendering: not expired, and with something to sell.
  bool get isLive => !expired && products.isNotEmpty;

  Duration? get timeLeft {
    final end = endsAt;
    if (end == null) return null;
    final left = end.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  factory FlashSale.fromJson(Map<String, dynamic> j) => FlashSale(
        id: asInt(j['id']),
        name: asString(j['name']),
        endsAt: parseServerDate(j['end_date']),
        expired: asBool(j['expired']),
        products:
            asMapList(j['products']).map(FlashSaleProduct.fromJson).toList(),
      );

  /// Parses one of this backend's offset-less `Y-m-d H:i:s` timestamps.
  ///
  /// Anything already carrying a zone (`...Z`, `...+05:30`) is honoured as
  /// sent; a bare timestamp is read as UTC — see [endsAt] for why — and
  /// returned in device local time so it can be compared to `DateTime.now()`.
  static DateTime? parseServerDate(dynamic value) {
    final raw = asString(value).trim();
    if (raw.isEmpty) return null;
    final hasZone = RegExp(r'(?:Z|z|[+-]\d{2}:?\d{2})$').hasMatch(raw);
    return DateTime.tryParse(hasZone ? raw : '${raw}Z')?.toLocal();
  }
}

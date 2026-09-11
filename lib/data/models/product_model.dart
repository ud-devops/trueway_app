import '../../core/utils/json_utils.dart';
import '../../core/utils/price_utils.dart';

/// What the catalogue says about a product's diet, when it says anything.
///
/// Only these two, and only when stated outright — see [Product.dietType] for
/// where the fact comes from and why "unknown" is a third, silent case rather
/// than a default.
enum DietType { vegetarian, nonVegetarian }

class ProductStore {
  const ProductStore({required this.id, required this.name, this.slug, this.zipCode});

  final int id;
  final String name;
  final String? slug;
  final String? zipCode;

  factory ProductStore.fromJson(Map<String, dynamic> j) => ProductStore(
        id: asInt(j['id']),
        name: asString(j['name']),
        slug: asStringOrNull(j['slug']),
        zipCode: asStringOrNull(j['zip_code']),
      );
}

/// A clip attached to a product.
///
/// **[url] is not necessarily a media file.** Verified on the live catalogue:
/// four products carry videos and none of them is an mp4 —
///
/// * 119, 120: `provider: "youtube"`, `https://www.youtube.com/embed/<id>?...`
/// * 123, 125: `provider: "video"`, an **Amazon Live page**
///   (`https://www.amazon.in/live/video/<id>`)
///
/// Both are HTML pages (both answer 200 `text/html`). Handing either to a
/// `<video src>` element renders a broken player, which is exactly what the
/// product page showed. [thumbnail] is a genuine still in every case, so it is
/// safe to display — unlike a *review* video's thumbnail, which is the clip.
class ProductVideo {
  const ProductVideo({required this.url, this.thumbnail, this.provider});

  final String url;
  final String? thumbnail;

  /// The server's own word for the source: `youtube` or `video` today. Note
  /// `video` does **not** mean "a video file" — product 125 uses it for an
  /// Amazon Live page — so it is a label, not a playback instruction.
  final String? provider;

  factory ProductVideo.fromJson(Map<String, dynamic> j) => ProductVideo(
        url: asString(j['url'] ?? j['video'] ?? j['link']),
        thumbnail: asStringOrNull(j['thumbnail'] ?? j['thumb']),
        provider: asStringOrNull(j['provider']),
      );
}

/// One badge from the product's `product_conditions` — the merchant's own
/// promises for this product ("Free delivery", "Secure payment", "No Return").
///
/// These are **per product and merchant-managed**, which is why the app must
/// not invent them. Verified live: product 120 returns four, product 125
/// returns an empty array, and 120's fourth badge reads *"No Return"* — the
/// opposite of the "Easy returns" the app used to hard-code on every product.
///
/// [image] is a real uploaded icon URL; [description] and [pageReference] are
/// null on every row seen so far, but the API declares them.
class ProductCondition {
  const ProductCondition({
    required this.title,
    this.image,
    this.description,
    this.pageReference,
  });

  final String title;
  final String? image;
  final String? description;
  final String? pageReference;

  /// Null when the row carries no title — there is nothing to show for a badge
  /// with no words, and an icon on its own states nothing.
  static ProductCondition? tryParse(Map<String, dynamic> j) {
    final title = asString(j['title']).trim();
    if (title.isEmpty) return null;
    return ProductCondition(
      title: title,
      image: asStringOrNull(j['image']),
      description: asStringOrNull(j['description']),
      pageReference: asStringOrNull(j['page_reference']),
    );
  }
}

class ProductOptionValue {
  const ProductOptionValue({
    required this.id,
    required this.label,
    this.affectPrice = 0,
    this.affectType = 0,
  });

  final int id;
  final String label;
  final double affectPrice;
  final int affectType; // 0 = fixed amount, 1 = percent

  factory ProductOptionValue.fromJson(Map<String, dynamic> j) => ProductOptionValue(
        id: asInt(j['id']),
        label: asString(j['label'] ?? j['option_value'] ?? j['name']),
        affectPrice: asDouble(j['affect_price']),
        affectType: asInt(j['affect_type']),
      );
}

class ProductOption {
  const ProductOption({
    required this.id,
    required this.name,
    required this.required,
    required this.values,
  });

  final int id;
  final String name;
  final bool required;
  final List<ProductOptionValue> values;

  factory ProductOption.fromJson(Map<String, dynamic> j) => ProductOption(
        id: asInt(j['id']),
        name: asString(j['name']),
        required: asBool(j['required']),
        values: asMapList(j['values'] ?? j['option_values'])
            .map(ProductOptionValue.fromJson)
            .toList(),
      );
}

class Product {
  const Product({
    required this.id,
    required this.slug,
    required this.name,
    required this.sku,
    // Defaulted, not required: a server that predates `min_cart_quantity` /
    // `max_cart_quantity` must still build a Product. 1 and 1000 are the
    // server's own fallbacks (`Product.php:862,875`), so an older backend
    // behaves exactly as it did before rather than capping anything at 0.
    this.minCartQuantity = 1,
    this.maxCartQuantity = 1000,
    required this.price,
    required this.originalPrice,
    required this.priceFormatted,
    required this.originalPriceFormatted,
    required this.imageUrl,
    required this.images,
    required this.imagesThumb,
    required this.description,
    required this.content,
    required this.quantity,
    required this.isOutOfStock,
    required this.stockStatusLabel,
    required this.reviewsAvg,
    required this.reviewsCount,
    required this.videos,
    required this.options,
    this.conditions = const [],
    this.store,
    this.weightGrams = 0,
    this.lengthCm = 0,
    this.wideCm = 0,
    this.heightCm = 0,
  });

  final int id;
  final String slug;
  final String name;
  final String sku;
  final double price;
  final double originalPrice;
  final String priceFormatted;
  final String originalPriceFormatted;
  final String imageUrl;
  final List<String> images;
  final List<String> imagesThumb;
  final String description; // HTML spec table
  final String content; // HTML "About this item"
  final int quantity;
  final bool isOutOfStock;
  final String stockStatusLabel;

  /// Fewest units the server will accept in one line, from `min_cart_quantity`.
  ///
  /// Not always 1: `Sona Moti Wheat` is sold in twos on this catalogue. So the
  /// first "ADD" has to put [minCartQuantity] in the basket, not one — adding
  /// one and letting the server refuse it is both a wasted round trip and, on
  /// this backend, a wiped cart (`BACKEND_BUGS.md` finding 0).
  final int minCartQuantity;

  /// Most units the server will accept in one line, from `max_cart_quantity`.
  ///
  /// This is the **server's own computed cap**, not something derived here.
  /// Botble resolves it as
  /// `maximum_order_quantity ?: (with_storehouse_management ? quantity : 1000)`
  /// (`Product.php:867-876`), and only the first of those three is a column the
  /// app could otherwise see.
  ///
  /// ⚠ [quantity] is **not** a substitute and must never be used as one. A live
  /// product on this catalogue reports `quantity: 0` with `max_cart_quantity:
  /// 1000` — its stock simply is not tracked — so capping at `quantity` would
  /// make it unbuyable. See [inStock] for the same trap.
  final int maxCartQuantity;

  /// The quantity a fresh "ADD" should put in the basket.
  int get initialCartQuantity => minCartQuantity;

  /// Whether one more unit can be added to [current] without the server
  /// refusing it.
  bool canAdd(int current) => current < maxCartQuantity;

  /// [wanted] brought inside the server's limits.
  int clampCartQuantity(int wanted) =>
      wanted.clamp(minCartQuantity, maxCartQuantity);
  final double? reviewsAvg;
  final int reviewsCount;
  final List<ProductVideo> videos;
  final List<ProductOption> options;

  /// The merchant's badges for this product, from `product_conditions`.
  ///
  /// Empty is a real answer, not a gap to fill: product 125 returns `[]`, and
  /// the row is simply not drawn there. Defaulted rather than required so a
  /// list payload — which omits the key entirely — still builds a Product.
  final List<ProductCondition> conditions;

  final ProductStore? store;

  /// Shipping weight in grams, from the API's `weight` field.
  ///
  /// Doubles as the pack size — the catalogue sells by weight, so 5000 here
  /// means a 5 kg bag. 0 when the backend has none recorded.
  final int weightGrams;

  /// Packed size in centimetres, from the API's `length` / `wide` / `height`.
  ///
  /// The same three columns `PackageDimensionCalculator::fromShippingItems()`
  /// reads on the web, so the app can build the identical parcel for a
  /// serviceability quote instead of guessing a box. 0 when the backend records
  /// none — which the calculator treats as "no dimension", not as zero.
  final double lengthCm;
  final double wideCm;
  final double heightCm;

  bool get hasDiscount => originalPrice > price && originalPrice > 0;
  int get discountPercent => PriceUtils.discountPercent(price, originalPrice);

  /// Pack size for the card pill: "5 kg", "15.2 kg", "500 g".
  ///
  /// Null when the backend records no weight, so the pill is simply omitted
  /// rather than showing a meaningless "0 g".
  String? get packLabel {
    if (weightGrams <= 0) return null;
    if (weightGrams < 1000) return '$weightGrams g';
    final kg = weightGrams / 1000;
    // Drop the decimal on whole kilograms: 5 kg, not 5.0 kg.
    return kg == kg.roundToDouble()
        ? '${kg.toStringAsFixed(0)} kg'
        : '${kg.toStringAsFixed(1)} kg';
  }

  /// Comparable unit price: "₹184.30/kg" or "₹7.69/100 g".
  ///
  /// Per-kilogram for anything from 200 g up, per-100 g below that — the same
  /// convention grocery apps use, so small packs stay readable.
  String? get unitPriceLabel {
    if (weightGrams <= 0 || price <= 0) return null;
    if (weightGrams >= 200) {
      return '${PriceUtils.format(price / (weightGrams / 1000))}/kg';
    }
    return '${PriceUtils.format(price / (weightGrams / 100))}/100 g';
  }

  /// A stock note worth surfacing, or null when stock is unremarkable.
  ///
  /// The backend sends labels like "In stock", "On backorder",
  /// "Out of stock" — only the exceptions are worth card space.
  String? get stockNote {
    final label = stockStatusLabel.trim();
    if (label.isEmpty || label.toLowerCase() == 'in stock') return null;
    return label;
  }

  /// "3 options" hint for products with required variants.
  String? get optionsLabel {
    if (options.isEmpty) return null;
    return '${options.length} option${options.length == 1 ? '' : 's'}';
  }

  /// Whether the product can be added to the cart.
  ///
  /// `is_out_of_stock` is the backend's authoritative answer, so that is all we
  /// check. `quantity` cannot refine it: products with untracked inventory also
  /// report `quantity: 0` while remaining purchasable, so the client has no way
  /// to tell "sold out" from "not tracked".
  ///
  /// (This was `!isOutOfStock && quantity > 0 || (!isOutOfStock)`, which
  /// reduces to `!isOutOfStock` — the quantity term could never change the
  /// result. Behaviour is unchanged; the dead term is gone.)
  bool get inStock => !isOutOfStock;

  double get rating => reviewsAvg ?? 0;

  /// Whether the catalogue states this is vegetarian, and nothing more.
  ///
  /// **There is no field for this.** Verified across the whole live catalogue:
  /// no `is_veg`, no `food_type`, no diet attribute, and no symbol image on any
  /// endpoint. The only place the fact exists is a `Diet Type` row inside the
  /// `description` HTML — an Amazon-scraped spec table, carrying Amazon's own
  /// `po-diet_type` class — and it is present on 3 of the 6 products (111, 119,
  /// 120), all of them "Vegetarian".
  ///
  /// So this reads the table, and it reads it strictly: a row that is missing,
  /// empty, or says something the parser does not recognise yields **null**,
  /// and null must render nothing. A green dot is a food-safety claim, and
  /// "most of this catalogue is vegetarian" is not a reason to stamp one on a
  /// product whose merchant never said so.
  DietType? get dietType => _dietFrom(description);

  /// The `Diet Type` cell, or null.
  ///
  /// Two anchors, because the merchant's HTML is pasted, not generated: the
  /// `po-diet_type` class Amazon puts on the row, and failing that a row whose
  /// first cell reads "Diet Type". Both then take the *last* cell's text.
  static DietType? _dietFrom(String html) {
    if (html.isEmpty) return null;

    final row = RegExp(
          r'<tr[^>]*po-diet_type[^>]*>(.*?)</tr>',
          caseSensitive: false,
          dotAll: true,
        ).firstMatch(html) ??
        RegExp(
          r'<tr[^>]*>(?=(?:(?!</tr>).)*?diet\s*type)(.*?)</tr>',
          caseSensitive: false,
          dotAll: true,
        ).firstMatch(html);
    if (row == null) return null;

    final cells = RegExp(
      r'<td[^>]*>(.*?)</td>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(row.group(1)!).toList();
    if (cells.length < 2) return null;

    final value = _plainText(cells.last.group(1)!).toLowerCase();

    // Order matters: "non-vegetarian" contains "vegetarian", so the negative
    // has to be tested first or every non-veg product would read as veg.
    if (RegExp(r'non[\s\-_]*veg').hasMatch(value)) return DietType.nonVegetarian;
    if (RegExp(r'\bvegan\b|\bveg(etarian)?\b').hasMatch(value)) {
      return DietType.vegetarian;
    }
    // Deliberately no fallback. "Eggetarian", a blank cell, or wording nobody
    // anticipated all land here, and an unknown diet shows no mark at all.
    return null;
  }

  static String _plainText(String html) => html
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Best gallery: prefer medium-size images; fall back to raw/thumb/single.
  List<String> get gallery {
    if (images.isNotEmpty) return images;
    if (imageUrl.isNotEmpty) return [imageUrl];
    return const [];
  }

  String get primaryImage => imageUrl.isNotEmpty
      ? imageUrl
      : (images.isNotEmpty ? images.first : '');

  factory Product.fromJson(Map<String, dynamic> j) {
    final sizes = asMap(j['image_with_sizes']);
    List<String> pickSize(String key, List<String> fallback) {
      final v = sizes[key];
      final list = asStringList(v);
      return list.isNotEmpty ? list : fallback;
    }

    final rawImages = asStringList(j['images']);
    final medium = pickSize('medium', pickSize('product-thumb', rawImages));

    return Product(
      id: asInt(j['id']),
      slug: asString(j['slug']),
      name: asString(j['name']),
      sku: asString(j['sku']),
      price: asDouble(j['price']),
      originalPrice: asDouble(j['original_price'], asDouble(j['price'])),
      priceFormatted: asString(j['price_formatted']),
      originalPriceFormatted: asString(j['original_price_formatted']),
      imageUrl: asString(j['image_url']),
      images: medium,
      imagesThumb: asStringList(j['images_thumb']),
      description: asString(j['description']),
      content: asString(j['content']),
      quantity: asInt(j['quantity']),
      // The server's computed limits. `?: 1` / `?: 1000` mirror Botble's own
      // fallbacks, so a null or an absent key lands where the server would.
      // A max of 0 would make the product unbuyable, so it is treated as
      // "not stated" rather than "none allowed".
      minCartQuantity: asInt(j['min_cart_quantity'], 1).clamp(1, 1 << 30),
      maxCartQuantity: asInt(j['max_cart_quantity']) > 0
          ? asInt(j['max_cart_quantity'])
          : 1000,
      isOutOfStock: asBool(j['is_out_of_stock']),
      stockStatusLabel: asString(j['stock_status_label'], 'In stock'),
      reviewsAvg: j['reviews_avg'] == null ? null : asDouble(j['reviews_avg']),
      reviewsCount: asInt(j['reviews_count']),
      videos: asMapList(j['videos']).map(ProductVideo.fromJson).toList(),
      options: asMapList(j['product_options']).map(ProductOption.fromJson).toList(),
      conditions: [
        for (final row in asMapList(j['product_conditions']))
          if (ProductCondition.tryParse(row) case final c?) c,
      ],
      store: j['store'] is Map ? ProductStore.fromJson(asMap(j['store'])) : null,
      weightGrams: asInt(j['weight']),
      lengthCm: asDouble(j['length']),
      wideCm: asDouble(j['wide']),
      heightCm: asDouble(j['height']),
    );
  }
}

/// Product variations, as the two endpoints that describe them actually behave.
///
/// A variable product ("Sona Moti Wheat") is a parent whose real, buyable rows
/// are its **variations** ("5 KG (Pack of 1)"). The customer picks attributes;
/// the server resolves those to one variation with its own id, price, stock and
/// images; the cart takes *that* id.
///
/// ## The trap
///
/// The two endpoints do not share a serializer, and they disagree about what
/// `price` means:
///
/// | | `/products/{slug}` | `/product-variation/{id}` |
/// |---|---|---|
/// | serializer | `AvailableProductResource` | `ProductVariationResource` |
/// | selling price | `price` = 921.50 | `sale_price` = 493.50 |
/// | MRP | `original_price` | `original_price` |
/// | `price` means | the selling price | **the MRP** |
///
/// Feeding a resolve response to `Product.fromJson` therefore shows the MRP as
/// the selling price — the customer is quoted ₹571.20 for a ₹493.50 pack — and
/// blanks every formatted string. [ProductVariation] is a separate parser for
/// exactly that reason.
library;

import '../../core/utils/json_utils.dart';
import '../../core/utils/price_utils.dart';
import 'product_model.dart';

/// A product together with its variation block.
///
/// They arrive in one response but at different levels — the product under
/// `data`, the variations as siblings of it — so they travel together rather
/// than forcing every caller to make a second request for something it was
/// already sent.
class ProductDetail {
  const ProductDetail({required this.product, required this.variations});

  final Product product;
  final ProductVariationOptions variations;

  /// True when the customer must choose before there is anything to add.
  bool get isVariable => variations.isVariable;
}

/// One selectable option, e.g. "5 KG (Pack of 1)".
///
/// Carries its **own** price and weight on the product-detail payload, so the
/// selector can price every option without a request. Only committing to one
/// needs the round trip.
class VariationAttribute {
  const VariationAttribute({
    required this.id,
    required this.title,
    required this.slug,
    this.color = '',
    this.image = '',
    this.order = 0,
    this.price = 0,
    this.originalPrice = 0,
    this.weightGrams = 0,
    this.lengthCm = 0,
    this.wideCm = 0,
    this.heightCm = 0,
  });

  final int id;
  final String title;
  final String slug;

  /// A CSS colour string (`"rgb(0, 0, 0)"`) or empty. Populated only for
  /// attribute sets meant to render as swatches.
  final String color;

  final String image;
  final int order;

  /// Selling price for this option, tax **included** — the catalogue
  /// convention. The cart reports the same money ex-tax (470 against ₹493.50),
  /// so never compare the two directly.
  final double price;

  /// MRP, before the product-level discount.
  final double originalPrice;

  final double weightGrams;
  final double lengthCm;
  final double wideCm;
  final double heightCm;

  bool get hasDiscount => originalPrice > price && originalPrice > 0;

  int get discountPercent => PriceUtils.discountPercent(price, originalPrice);

  /// "5 kg", "1.85 kg", "500 g" — the pack size, for a subtitle under the
  /// option's own title.
  String? get packLabel {
    if (weightGrams <= 0) return null;
    if (weightGrams < 1000) return '${weightGrams.round()} g';
    final kg = weightGrams / 1000;
    return kg == kg.roundToDouble()
        ? '${kg.toStringAsFixed(0)} kg'
        : '${kg.toStringAsFixed(1)} kg';
  }

  factory VariationAttribute.fromJson(Map<String, dynamic> j) =>
      VariationAttribute(
        id: asInt(j['id']),
        title: asString(j['title'] ?? j['name']),
        slug: asString(j['slug']),
        color: asString(j['color']),
        image: asString(j['image']),
        order: asInt(j['order']),
        price: asDouble(j['price']),
        originalPrice: asDouble(j['original_price'], asDouble(j['price'])),
        weightGrams: asDouble(j['weight']),
        lengthCm: asDouble(j['length']),
        wideCm: asDouble(j['wide']),
        heightCm: asDouble(j['height']),
      );
}

/// A group of options the customer chooses one of, e.g. "Pack Size".
class VariationAttributeSet {
  const VariationAttributeSet({
    required this.id,
    required this.title,
    required this.slug,
    required this.attributes,
    this.order = 0,
    this.displayLayout = '',
  });

  final int id;
  final String title;
  final String slug;
  final int order;

  /// The backend's rendering hint — `"price-box"`, `"swatch"`, `"dropdown"`,
  /// `"text"`. Advisory: the app picks a layout it can actually render, but a
  /// set that names a colour swatch is worth honouring.
  final String displayLayout;

  final List<VariationAttribute> attributes;

  /// True when this set's options are distinguished by colour rather than text.
  bool get isSwatch =>
      displayLayout.contains('swatch') ||
      attributes.any((a) => a.color.trim().isNotEmpty);

  /// True when the options differ in price, which is what justifies showing a
  /// price beside each one.
  bool get hasVaryingPrices =>
      attributes.map((a) => a.price).toSet().length > 1;

  factory VariationAttributeSet.fromJson(Map<String, dynamic> j) {
    final attributes = asMapList(j['attributes'])
        .map(VariationAttribute.fromJson)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    return VariationAttributeSet(
      id: asInt(j['id']),
      title: asString(j['title'] ?? j['name']),
      slug: asString(j['slug']),
      order: asInt(j['order']),
      displayLayout: asString(j['display_layout']),
      attributes: attributes,
    );
  }
}

/// A resolved variation — one buyable row.
///
/// Parsed from `GET /ecommerce/product-variation/{parentId}?attributes[]=…`,
/// whose price fields are inverted relative to the rest of the API. See the
/// library doc.
class ProductVariation {
  const ProductVariation({
    required this.id,
    required this.name,
    required this.price,
    required this.originalPrice,
    required this.priceFormatted,
    required this.originalPriceFormatted,
    required this.quantity,
    required this.isOutOfStock,
    required this.stockStatusLabel,
    required this.images,
    required this.selectedAttributeIds,
    required this.unavailableAttributeIds,
    this.sku,
    this.salePercentage,
    this.successMessage,
    this.errorMessage,
    this.warningMessage,
    this.weightGrams = 0,
    this.lengthCm = 0,
    this.wideCm = 0,
    this.heightCm = 0,
    // The server's own fallbacks, so a backend without these keys behaves as it
    // did before. See [Product.maxCartQuantity] for why `quantity` cannot stand
    // in for the cap.
    this.minCartQuantity = 1,
    this.maxCartQuantity = 1000,
  });

  /// **The id to put in the cart.** Not the parent's — posting the parent gets
  /// the default variation and silently discards the customer's pick.
  final int id;

  final String name;

  /// Selling price, tax included.
  ///
  /// Read from `sale_price`, falling back to `price` when there is no sale.
  /// Reading `price` unconditionally yields the MRP.
  final double price;

  /// MRP. `original_price` on this endpoint, which does mean what it says.
  final double originalPrice;

  /// The server's own rendering — `display_sale_price` / `display_price`.
  /// Preferred over formatting [price] here, because PHP and Dart round
  /// `921.501` differently.
  final String priceFormatted;
  final String originalPriceFormatted;

  final int quantity;
  final bool isOutOfStock;
  final String stockStatusLabel;

  /// The server's computed cart limits for **this variation**, which are its
  /// own — a 5 kg pack and a 500 g pack of the same product routinely differ.
  ///
  /// Read from `min_cart_quantity` / `max_cart_quantity` on the variation
  /// endpoint. See [Product.maxCartQuantity] for why [quantity] cannot stand in
  /// for the cap.
  final int minCartQuantity;
  final int maxCartQuantity;

  /// The quantity a fresh "ADD" should put in the basket.
  int get initialCartQuantity => minCartQuantity;

  bool canAdd(int current) => current < maxCartQuantity;

  int clampCartQuantity(int wanted) =>
      wanted.clamp(minCartQuantity, maxCartQuantity);

  /// Gallery for this variation, medium size where available.
  ///
  /// Populated on this endpoint, unlike `default_product_variation` where it
  /// arrives null — so a screen showing the default must fall back to the
  /// parent's images, while one showing a resolved variation need not.
  final List<String> images;

  final List<int> selectedAttributeIds;

  /// Options that cannot be picked alongside the current selection. The
  /// selector greys these out rather than letting the customer choose a
  /// combination that does not exist.
  final List<int> unavailableAttributeIds;

  final String? sku;

  /// Server-computed discount badge, e.g. `"-13%"`.
  final String? salePercentage;

  /// Server-authored messages. Shown **verbatim** — they name the actual
  /// constraint ("98 products available") far better than anything the client
  /// could compose.
  final String? successMessage;
  final String? errorMessage;
  final String? warningMessage;

  final double weightGrams;
  final double lengthCm;
  final double wideCm;
  final double heightCm;

  /// Comparable unit price for **this pack** — "₹184.30/kg", "₹2.87/100 g".
  ///
  /// The variation's own price against the variation's own weight. Reading the
  /// parent's would quote a 5 kg pack's rate under a 500 g one.
  ///
  /// Same convention as [Product.unitPriceLabel]: per kilogram from 200 g up,
  /// per 100 g below that, so a small pack does not read as a fraction.
  String? get unitPriceLabel {
    if (weightGrams <= 0 || price <= 0) return null;
    if (weightGrams >= 200) {
      return '${PriceUtils.format(price / (weightGrams / 1000))}/kg';
    }
    return '${PriceUtils.format(price / (weightGrams / 100))}/100 g';
  }

  bool get hasDiscount => originalPrice > price && originalPrice > 0;

  int get discountPercent => PriceUtils.discountPercent(price, originalPrice);

  /// The badge to show: the server's own string when it sent one, else derived.
  String get discountLabel {
    final fromServer = salePercentage?.trim();
    if (fromServer != null && fromServer.isNotEmpty) {
      // The server sends "-13%"; the app's badges read "13% OFF".
      final digits = fromServer.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.isNotEmpty) return '$digits% OFF';
    }
    return '$discountPercent% OFF';
  }

  bool get inStock => !isOutOfStock;

  /// Parses **both** variation shapes, which use three naming conventions
  /// between them.
  ///
  /// `default_product_variation` (on `/products/{slug}`) follows the ordinary
  /// catalogue convention — `price` is the selling price, labels are
  /// `price_formatted` / `original_price_formatted`, and there is no
  /// `sale_price` key at all. A resolved variation (on `/product-variation`)
  /// inverts it — `price` is the MRP, `sale_price` is what the customer pays,
  /// and the labels are `formatted_sale_price` / `formatted_original_price`.
  ///
  /// Keying off the presence of `sale_price` rather than the endpoint keeps one
  /// parser honest for both:
  ///
  /// ```
  /// default:  price 921.501, original_price 1296.75          -> pays 921.50
  /// resolved: price 571.2, sale_price 493.5, original 571.2  -> pays 493.50
  /// ```
  factory ProductVariation.fromJson(Map<String, dynamic> j) {
    final salePrice = asDouble(j['sale_price']);
    final listPrice = asDouble(j['price']);
    final onSale = salePrice > 0;

    // What the customer pays.
    final effective = onSale ? salePrice : listPrice;
    // Struck-through MRP. `original_price` means the same thing on both shapes.
    final mrp = asDouble(j['original_price'], listPrice);

    // Server labels, never re-formatted here: PHP renders 921.501 as ₹921.50
    // and Dart's own rounding does not always agree.
    final sellingLabel = onSale
        ? asStringOrNull(j['formatted_sale_price'] ?? j['display_sale_price'])
        : asStringOrNull(
            j['price_formatted'] ?? j['formatted_price'] ?? j['display_price'],
          );
    final mrpLabel = asStringOrNull(
      j['original_price_formatted'] ?? j['formatted_original_price'],
    );

    return ProductVariation(
      id: asInt(j['id']),
      name: asString(j['name']),
      price: effective,
      originalPrice: mrp,
      priceFormatted: PriceUtils.resolve(sellingLabel, effective),
      originalPriceFormatted: PriceUtils.resolve(mrpLabel, mrp),
      quantity: asInt(j['quantity']),
      // A max of 0 would make the variation unbuyable, so it reads as "not
      // stated" and falls back to the server's own 1000.
      minCartQuantity: asInt(j['min_cart_quantity'], 1).clamp(1, 1 << 30),
      maxCartQuantity: asInt(j['max_cart_quantity']) > 0
          ? asInt(j['max_cart_quantity'])
          : 1000,
      isOutOfStock: asBool(j['is_out_of_stock']),
      stockStatusLabel: asString(j['stock_status_label'], 'In stock'),
      images: _galleryOf(j['image_with_sizes']),
      selectedAttributeIds: _idsOf(j['selected_attributes']),
      unavailableAttributeIds: _intList(j['unavailable_attribute_ids']),
      sku: asStringOrNull(j['sku']),
      salePercentage: asStringOrNull(j['sale_percentage']),
      successMessage: asStringOrNull(j['success_message']),
      errorMessage: asStringOrNull(j['error_message']),
      warningMessage: asStringOrNull(j['warning_message']),
      weightGrams: asDouble(j['weight']),
      lengthCm: asDouble(j['length']),
      wideCm: asDouble(j['wide']),
      heightCm: asDouble(j['height']),
    );
  }

  /// Prefers medium images, then the product thumb, then the originals.
  static List<String> _galleryOf(dynamic raw) {
    final sizes = asMap(raw);
    for (final key in const ['medium', 'product-thumb', 'origin', 'thumb']) {
      final list = asStringList(sizes[key]);
      if (list.isNotEmpty) return list;
    }
    return const [];
  }

  /// `selected_attributes` has **two shapes under one key**: flat entries here
  /// (`{id, slug, set_slug, set_id}`) and, on `/products/{slug}`, entries that
  /// nest a whole `attribute_set` object. Only the ids are wanted either way,
  /// and both shapes carry `id` at the top level.
  static List<int> _idsOf(dynamic raw) =>
      asMapList(raw).map((e) => asInt(e['id'])).where((id) => id > 0).toList();

  static List<int> _intList(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map(asInt).where((id) => id > 0).toList();
  }
}

/// The variation block that rides alongside a product on `/products/{slug}`.
///
/// These four keys are **siblings of `data`**, not nested inside it, so a
/// parser that only reads `data` drops the whole feature — which is what the
/// app did until now.
class ProductVariationOptions {
  const ProductVariationOptions({
    required this.attributeSets,
    required this.unavailableAttributeIds,
    required this.selectedAttributeIds,
    this.defaultVariation,
  });

  final List<VariationAttributeSet> attributeSets;
  final List<int> unavailableAttributeIds;

  /// What the server considers selected on first load — the default variation's
  /// attributes.
  final List<int> selectedAttributeIds;

  /// The variation shown before the customer touches anything.
  ///
  /// ⚠ Arrives with `image_with_sizes: null` and `weight/height/wide/length:
  /// null`, unlike a resolved variation. Fall back to the parent product's
  /// images, and to the selected attribute's own `weight` — the per-attribute
  /// values *are* populated.
  final ProductVariation? defaultVariation;

  static const ProductVariationOptions none = ProductVariationOptions(
    attributeSets: [],
    unavailableAttributeIds: [],
    selectedAttributeIds: [],
  );

  /// True when this product is actually variable and needs a picker.
  bool get isVariable =>
      attributeSets.isNotEmpty &&
      attributeSets.any((s) => s.attributes.isNotEmpty);

  /// Every attribute across every set, for id lookups.
  Iterable<VariationAttribute> get allAttributes =>
      attributeSets.expand((s) => s.attributes);

  VariationAttribute? attributeById(int id) {
    for (final a in allAttributes) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// The default selection, one attribute per set.
  ///
  /// Prefers what the server marked selected; falls back to the first available
  /// option in each set so a picker is never rendered with nothing chosen.
  Map<int, int> get defaultSelection {
    final selection = <int, int>{};
    for (final set in attributeSets) {
      final chosen = set.attributes
          .where((a) => selectedAttributeIds.contains(a.id))
          .firstOrNull;
      final fallback = set.attributes
          .where((a) => !unavailableAttributeIds.contains(a.id))
          .firstOrNull;
      final pick = chosen ?? fallback ?? set.attributes.firstOrNull;
      if (pick != null) selection[set.id] = pick.id;
    }
    return selection;
  }

  /// Reads the four sibling keys off a product-detail envelope.
  factory ProductVariationOptions.fromEnvelope(Map<String, dynamic> j) {
    final sets = asMapList(j['attribute_sets'])
        .map(VariationAttributeSet.fromJson)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    final rawDefault = j['default_product_variation'];

    return ProductVariationOptions(
      attributeSets: sets,
      unavailableAttributeIds:
          ProductVariation._intList(j['unavailable_attribute_ids']),
      selectedAttributeIds:
          ProductVariation._idsOf(j['selected_attributes']),
      defaultVariation: rawDefault is Map
          ? ProductVariation.fromJson(Map<String, dynamic>.from(rawDefault))
          : null,
    );
  }
}

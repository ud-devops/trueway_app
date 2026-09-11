import '../../core/config/app_config.dart';
import '../../core/utils/json_utils.dart';
import '../../core/utils/price_utils.dart';

/// A server-side amount and the label the server rendered for it.
///
/// Every money field in the cart arrives twice — `order_total: 1887.9` and
/// `order_total_formatted: "₹1,887.90"`. The raw number is `num` here but a
/// 2dp string on other endpoints, and Dart's own formatting of `1843.002`
/// rounds differently from PHP's, so the label is what gets displayed and the
/// number is only for arithmetic and comparisons.
class CartMoney {
  const CartMoney(this.amount, [this.formatted]);

  final double amount;

  /// The server's own rendering, e.g. `"₹1,887.90"`. Null when the key was
  /// absent — the raw Cart `content` shape carries no `_formatted` twins.
  final String? formatted;

  String get display => PriceUtils.resolve(formatted, amount);

  bool get isZero => amount == 0;

  /// Reads `key` and `key_formatted` as a pair.
  static CartMoney read(Map<String, dynamic> j, String key) => CartMoney(
        asDouble(j[key]),
        asStringOrNull(j['${key}_formatted']),
      );

  @override
  String toString() => display;
}

/// The id a cart mutation has to target.
///
/// **This is not always the product id you added.** For a variable product the
/// server resolves the parent to its default variation and the resulting line's
/// `id` is the *variation* id: `POST {product_id: 111}` yields a line with
/// `id: 116`. `PUT` and `DELETE` match lines on that id, so sending 111 takes
/// the "not in cart" branch — which returns 404 **and wipes the entire cart**
/// (docs/BACKEND_BUGS.md finding 0).
///
/// Wrapping the int means a caller cannot pass a product id to `removeItem` or
/// `setQuantity` by accident; the only unchecked way to make one is
/// [CartLineId.forSimpleProduct], which is greppable.
class CartLineId {
  const CartLineId._(this.value);

  /// Escape hatch for when the cart has not been read yet.
  ///
  /// Correct **only** for a product with no variations, where the line id
  /// equals the product id (verified for 118 and 119). For anything variable,
  /// read the line back from [ServerCart] and use its [ServerCartItem.lineId].
  const CartLineId.forSimpleProduct(this.value);

  final int value;

  @override
  bool operator ==(Object other) =>
      other is CartLineId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'CartLineId($value)';
}

/// One configurable option chosen on a line (`options[]` on a cart item).
///
/// Every captured payload had this empty — the catalogue has no products with
/// options — so the field names come from `CartItemResource::toArray()` rather
/// than from observed data.
class CartLineOption {
  const CartLineOption({
    required this.type,
    required this.value,
    required this.priceLabel,
    this.affectType = 0,
    this.affectPrice = 0,
  });

  final String type;
  final String value;

  /// Pre-formatted price effect, e.g. `"₹50.00"`.
  final String priceLabel;

  /// 1 = percentage of the original price, otherwise a flat amount.
  final int affectType;
  final double affectPrice;

  factory CartLineOption.fromJson(Map<String, dynamic> j) => CartLineOption(
        type: asString(j['option_type']),
        value: asString(j['values'] ?? j['value']),
        priceLabel: asString(j['price_label']),
        affectType: asInt(j['affect_type']),
        affectPrice: asDouble(j['affect_price']),
      );

  /// The server serializes this as `[]` when empty but as a keyed object when
  /// populated, because it maps over a PHP associative array.
  ///
  /// Only entries that actually look like an option are kept. This matters:
  /// pass the raw `Cart` **content** shape's `options` here and you are handing
  /// it the cart-options *bag* (`{image, attributes, taxRate, taxClasses: {…},
  /// options: [], extras: [], sku, weight, …}`), whose nested `taxClasses` map
  /// would otherwise be minted into a blank option. Verified against
  /// api-probe/coupons_remove_success-full-cart.json. [ServerCartItem.fromJson]
  /// also refuses to pass that bag in, so this is the second line of defence.
  static List<CartLineOption> listFrom(dynamic raw) {
    final maps = raw is Map ? raw.values.toList() : (raw is List ? raw : const []);
    return maps
        .whereType<Map>()
        .where((e) => e.containsKey('option_type'))
        .map((e) => CartLineOption.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}

/// Courier box the server picked for the whole cart. Null when the logistics
/// plugin is off or its calculator threw — the controller swallows that.
class CartPackageDimensions {
  const CartPackageDimensions({
    required this.length,
    required this.breadth,
    required this.height,
    required this.weight,
    this.boxId,
    this.boxName,
  });

  final double length;
  final double breadth;
  final double height;

  /// Kilograms here, unlike the grams on a line's `weight`.
  final double weight;

  final int? boxId;
  final String? boxName;

  factory CartPackageDimensions.fromJson(Map<String, dynamic> j) =>
      CartPackageDimensions(
        length: asDouble(j['length']),
        breadth: asDouble(j['breadth']),
        height: asDouble(j['height']),
        weight: asDouble(j['weight']),
        boxId: j['box_id'] == null ? null : asInt(j['box_id']),
        boxName: asStringOrNull(j['box_name']),
      );
}

/// A line in the server-side cart.
///
/// Parses both shapes the backend emits for a line:
///   * `cart_items` — the `CartItemResource` shape, with `row_id`, `quantity`
///     and a `_formatted` twin for every amount. This is what GET/POST/PUT
///     return and what the UI should use.
///   * `content` — the raw `Cart` collection, with `rowId`, `qty`, a per-unit
///     `tax` and no formatted labels. It appears under `content` on POST, and
///     is what the coupon endpoints put in `cart_items`.
class ServerCartItem {
  const ServerCartItem({
    required this.lineId,
    required this.rowId,
    required this.name,
    required this.quantity,
    // The server's own fallbacks, so a backend without these keys behaves
    // exactly as it did before rather than capping a line at 0.
    this.minCartQuantity = 1,
    this.maxCartQuantity = 1000,
    required this.unitPrice,
    required this.subtotal,
    required this.lineTotal,
    required this.unitTax,
    required this.totalTax,
    required this.taxRate,
    required this.imageUrl,
    this.originalPrice,
    this.variationLabel,
    this.sku,
    this.description,
    this.weight,
    this.height,
    this.length,
    this.wide,
    this.storeZipCode,
    this.options = const [],
    this.optionsPayload = const {},
  });

  /// What `CartRepository.setQuantity` and `CartRepository.removeItem` must be
  /// given. See [CartLineId] — for a variable product this is the variation id,
  /// not the id that was added.
  final CartLineId lineId;

  /// Server-side hash of product + options. Identifies the line for a human
  /// reading logs; no endpoint accepts it as input.
  final String rowId;

  final String name;
  final int quantity;

  /// The server's own cart limits for this line, from `min_cart_quantity` and
  /// `max_cart_quantity` on the cart response.
  ///
  /// Per **line**, not per product: a cart of two variations of one product has
  /// its own cap on each. Botble resolves them as
  /// `minimum_order_quantity ?: 1` and
  /// `maximum_order_quantity ?: (with_storehouse_management ? quantity : 1000)`
  /// (`Product.php:862-876`).
  ///
  /// These matter more here than anywhere else in the app: pushing a line past
  /// its maximum does not merely fail, it takes the **whole basket** with it.
  /// `Cart::restore()` deletes the stored row before the mutation runs and the
  /// over-quantity branch returns before `store()` writes it back — see
  /// `docs/BACKEND_BUGS.md` finding 0. Stopping the "+" button is what keeps
  /// that path from being entered at all.
  final int minCartQuantity;
  final int maxCartQuantity;

  /// True while one more unit would still be accepted.
  bool get canIncrement => quantity < maxCartQuantity;

  /// True while one fewer unit would still be a legal line.
  ///
  /// False at the minimum — where the only legal move is removing the line, not
  /// stepping below it.
  bool get canDecrement => quantity > minCartQuantity;

  /// True when the line is sitting at the most the server will allow.
  bool get isAtMaximum => quantity >= maxCartQuantity;

  /// Per-unit price **excluding tax** — `price` on both line shapes.
  ///
  /// This is not the number the catalogue shows. Tax is added on top here
  /// (`raw_sub_total` + `discounted_tax_amount` = `order_total`), so line 118
  /// reads ₹899.00 in the cart against ₹943.95 elsewhere. Showing this beside a
  /// catalogue price makes it look like the price changed on the way to the
  /// basket; show [lineTotal] (or the cart's `orderTotal`) when comparing.
  final CartMoney unitPrice;

  /// Pre-discount price. Null on every product observed — the server only sets
  /// it from a `original_price` cart option that nothing populates.
  final CartMoney? originalPrice;

  /// `unitPrice * quantity`, excluding tax.
  final CartMoney subtotal;

  /// `subtotal + totalTax`.
  final CartMoney lineTotal;

  final CartMoney unitTax;
  final CartMoney totalTax;

  /// Percent, e.g. `5` for 5% GST.
  final double taxRate;

  final String imageUrl;

  /// Rendered variation attributes, e.g. `"(Pack Size: 5 KG (Pack of 1))"`.
  /// Null for a simple product, where the server sends an empty string.
  final String? variationLabel;

  final String? sku;
  final String? description;

  /// Grams, per unit.
  final double? weight;
  final double? height;
  final double? length;
  final double? wide;

  /// The marketplace store this line ships from —
  /// `cart_options.store.zip_code`, e.g. `"311001"`.
  ///
  /// Rung 2 of the server's own `ShipRocketService::getPickupPostcode()` chain
  /// (`:1715-1745`), and the only rung reachable from the mobile API. Read by
  /// `ShippingQuery.fromCart` so a courier quote ships *from* wherever the
  /// catalogue says the goods are, instead of from a constant that has to be
  /// found and edited when the warehouse moves.
  ///
  /// Null on the raw `content` line shape (no `cart_options` bag) and whenever
  /// the marketplace plugin does not attach a store. Kept as the server's own
  /// string — no validation here; the caller decides what counts as usable.
  final String? storeZipCode;

  final List<CartLineOption> options;

  /// The chosen options exactly as the server serialized them — the keyed
  /// object `{"7": {"option_type": …, "values": …}}` that
  /// `POST /ecommerce/cart/{id}` accepts straight back under `options`.
  ///
  /// [options] is the same data parsed for display, and it drops the keys. A
  /// rebuild needs them: the server matches `options.{option_id}.values`
  /// against `ec_option_values`, and a product whose options are *required*
  /// answers a POST without them with "Please select product options!" — one of
  /// the nine paths that destroy the whole cart. Re-posting a line without its
  /// options would therefore trade one wipe for another.
  ///
  /// Empty for every line in this catalogue (no product has options yet), and
  /// empty on the raw `content` shape, whose `options` key is the cart-options
  /// bag rather than the customer's choices.
  final Map<String, dynamic> optionsPayload;

  bool get isVariation => variationLabel != null;

  factory ServerCartItem.fromJson(Map<String, dynamic> j) {
    // The two line shapes disagree about what `options` means, and getting this
    // wrong is silent: the resource shape puts the cart-options *bag* under
    // `cart_options` and the customer's *chosen* options under `options`, while
    // the raw content shape has no `cart_options` at all and puts the bag under
    // `options`. So `cart_options` is the shape discriminator, and `options` is
    // only a chosen-options list when it is present.
    final rawCartOptions = j['cart_options'];
    final isResourceShape = rawCartOptions is Map;
    final cartOptions = asMap(isResourceShape ? rawCartOptions : j['options']);

    final quantity = asInt(j['quantity'] ?? j['qty'], 1);
    final unitPrice = CartMoney.read(j, 'price');

    // The content shape has neither line totals nor tax totals; derive them so
    // a coupon response renders the same as a cart response. Server-supplied
    // values always win — nothing here recomputes what the server sent.
    final subtotal = j.containsKey('subtotal')
        ? CartMoney.read(j, 'subtotal')
        : CartMoney(unitPrice.amount * quantity);
    final unitTax = j.containsKey('tax_price')
        ? CartMoney.read(j, 'tax_price')
        : CartMoney(asDouble(j['tax']));
    final totalTax = j.containsKey('tax_total')
        ? CartMoney.read(j, 'tax_total')
        : CartMoney(unitTax.amount * quantity);
    final lineTotal = j.containsKey('total_price')
        ? CartMoney.read(j, 'total_price')
        : CartMoney(subtotal.amount + totalTax.amount);

    final variation = asStringOrNull(
      j['variation_attributes'] ?? cartOptions['attributes'],
    );

    return ServerCartItem(
      lineId: CartLineId._(asInt(j['id'])),
      rowId: asString(j['row_id'] ?? j['rowId']),
      name: asString(j['name'] ?? cartOptions['name']),
      quantity: quantity,
      // A max of 0 would strand the line at zero and disable both buttons, so
      // it reads as "not stated" and falls back to the server's own 1000.
      minCartQuantity: asInt(j['min_cart_quantity'], 1).clamp(1, 1 << 30),
      maxCartQuantity: asInt(j['max_cart_quantity']) > 0
          ? asInt(j['max_cart_quantity'])
          : 1000,
      unitPrice: unitPrice,
      originalPrice: j['original_price'] == null
          ? null
          : CartMoney.read(j, 'original_price'),
      subtotal: subtotal,
      lineTotal: lineTotal,
      unitTax: unitTax,
      totalTax: totalTax,
      taxRate: asDouble(j['tax_rate'] ?? cartOptions['taxRate']),
      imageUrl: _resolveImage(j['image_url'] ?? j['image'] ?? cartOptions['image']),
      variationLabel: variation,
      sku: asStringOrNull(cartOptions['sku']),
      description: asStringOrNull(j['description']),
      weight: _optionalNum(j['weight'] ?? cartOptions['weight']),
      height: _optionalNum(j['height'] ?? cartOptions['height']),
      length: _optionalNum(j['length'] ?? cartOptions['length']),
      wide: _optionalNum(j['wide'] ?? cartOptions['wide']),
      storeZipCode: _storeZip(cartOptions['store']),
      // Never `j['options']` unconditionally — on the content shape that key
      // holds the cart-options bag, not the chosen options.
      options: CartLineOption.listFrom(isResourceShape ? j['options'] : null),
      optionsPayload: isResourceShape && j['options'] is Map
          ? asMap(j['options'])
          : const {},
    );
  }

  static double? _optionalNum(dynamic v) => v == null ? null : asDouble(v);

  /// `cart_options.store.zip_code`, or null when there is no store block.
  ///
  /// Read through [asStringOrNull] because the field has been observed as both
  /// a JSON string (`"311001"`) and, on other endpoints carrying the same
  /// column, a number.
  static String? _storeZip(dynamic store) {
    if (store is! Map) return null;
    final zip = asStringOrNull(asMap(store)['zip_code'])?.trim();
    return (zip == null || zip.isEmpty) ? null : zip;
  }

  /// `image_url` is absolute, but the raw content shape carries a storage-
  /// relative path (`products/…/x.jpg`) that has to be joined to `/storage`.
  static String _resolveImage(dynamic raw) {
    final value = asString(raw).trim();
    if (value.isEmpty) return '';
    if (value.startsWith('http')) return value;
    final clean = value.startsWith('/') ? value.substring(1) : value;
    return '${AppConfig.storageBase}/$clean';
  }
}

/// The server-side cart: lines plus the pricing block, exactly as the server
/// computed it.
///
/// **Nothing here is recomputed.** The server discounts on the pre-tax base and
/// then scales GST to the discounted value; reproducing that client-side would
/// drift from the order the customer is actually charged for. Every total is
/// read straight out of the payload.
class ServerCart {
  const ServerCart({
    required this.id,
    required this.items,
    required this.count,
    required this.rawSubTotal,
    required this.rawTotal,
    required this.promotionDiscount,
    required this.couponDiscount,
    required this.discountedSubTotal,
    required this.discountedTax,
    required this.orderTotal,
    this.appliedCouponCode,
    this.packageDimensions,
    this.totalWeight = 0,
    this.totalHeight = 0,
    this.totalWide = 0,
    this.totalLength = 0,
    this.totalVolume = 0,
  });

  /// The opaque cart identifier used in every cart path. Whoever holds it can
  /// read and write the cart; there is no ownership check.
  final String id;

  final List<ServerCartItem> items;

  /// Total units, not lines — 2 of one product reports `count: 2`.
  final int count;

  final double totalWeight;
  final double totalHeight;
  final double totalWide;
  final double totalLength;
  final double totalVolume;

  final CartPackageDimensions? packageDimensions;

  /// Sum of line subtotals, before tax and before any discount.
  final CartMoney rawSubTotal;

  /// [rawSubTotal] plus tax, before any discount.
  final CartMoney rawTotal;

  final CartMoney promotionDiscount;
  final CartMoney couponDiscount;

  /// Null unless a coupon is attached to a line. Note the coupon endpoints have
  /// been observed returning null here immediately after reporting the coupon
  /// applied successfully, which is why `CartRepository` re-reads the cart
  /// instead of trusting their response body.
  final String? appliedCouponCode;

  /// Sub-total after discounts, still excluding tax.
  final CartMoney discountedSubTotal;

  /// Tax recomputed on [discountedSubTotal].
  final CartMoney discountedTax;

  /// What the customer pays for goods — the only total to show as "Total".
  final CartMoney orderTotal;

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;
  bool get hasCoupon => (appliedCouponCode ?? '').isNotEmpty;
  bool get hasDiscount => !promotionDiscount.isZero || !couponDiscount.isZero;

  ServerCartItem? lineFor(CartLineId lineId) {
    for (final item in items) {
      if (item.lineId == lineId) return item;
    }
    return null;
  }

  /// Total units of one line, or 0 when it is not in the cart.
  int quantityOf(CartLineId lineId) => lineFor(lineId)?.quantity ?? 0;

  /// An empty cart for [id] — for seeding state before the first fetch. Never
  /// use it to stand in for a cart whose real state is unknown.
  factory ServerCart.empty(String id) => ServerCart(
        id: id,
        items: const [],
        count: 0,
        rawSubTotal: const CartMoney(0),
        rawTotal: const CartMoney(0),
        promotionDiscount: const CartMoney(0),
        couponDiscount: const CartMoney(0),
        discountedSubTotal: const CartMoney(0),
        discountedTax: const CartMoney(0),
        orderTotal: const CartMoney(0),
      );

  factory ServerCart.fromJson(Map<String, dynamic> j, {String? fallbackId}) {
    final rawItems = j.containsKey('cart_items') ? j['cart_items'] : j['content'];
    return ServerCart(
      // The coupon endpoints echo the identifier as `cart_id`; every cart
      // endpoint calls it `id`.
      id: asString(j['id'] ?? j['cart_id'] ?? fallbackId ?? ''),
      items: _readItems(rawItems),
      count: asInt(j['count']),
      totalWeight: asDouble(j['total_weight']),
      totalHeight: asDouble(j['total_height']),
      totalWide: asDouble(j['total_wide']),
      totalLength: asDouble(j['total_length']),
      totalVolume: asDouble(j['total_volume']),
      packageDimensions: j['package_dimensions'] is Map
          ? CartPackageDimensions.fromJson(asMap(j['package_dimensions']))
          : null,
      rawSubTotal: CartMoney.read(j, 'raw_sub_total'),
      rawTotal: CartMoney.read(j, 'raw_total'),
      promotionDiscount: CartMoney.read(j, 'promotion_discount_amount'),
      couponDiscount: CartMoney.read(j, 'coupon_discount_amount'),
      appliedCouponCode: asStringOrNull(j['applied_coupon_code']),
      discountedSubTotal: CartMoney.read(j, 'discounted_sub_total'),
      discountedTax: CartMoney.read(j, 'discounted_tax_amount'),
      orderTotal: CartMoney.read(j, 'order_total'),
    );
  }

  /// Parses a cart out of any response that might contain one, or returns null.
  ///
  /// Needed because the cart endpoints do not agree on an envelope: GET/POST/PUT
  /// return a bare object, the coupon endpoints wrap it in
  /// `{error, data, message}`, and DELETE returns the bare JSON *string*
  /// `"Cart item removed successfully"`. Callers use the null to decide they
  /// have to re-read the cart.
  static ServerCart? tryFrom(dynamic body, {String? fallbackId}) {
    final source = body is Map && body['data'] is Map ? body['data'] : body;
    if (source is! Map) return null;
    final json = Map<String, dynamic>.from(source);
    // `cart_items` is the discriminator: a business-error envelope has a null
    // `data`, and an unrelated object has neither key.
    if (!json.containsKey('cart_items') && !json.containsKey('content')) {
      return null;
    }
    return ServerCart.fromJson(json, fallbackId: fallbackId);
  }

  /// `cart_items` is a map keyed by row id when populated and a JSON **array**
  /// when empty, so a plain `as Map` throws on exactly the empty cart every
  /// wipe produces.
  static List<ServerCartItem> _readItems(dynamic raw) {
    final Iterable<dynamic> values;
    if (raw is Map) {
      values = raw.values;
    } else if (raw is List) {
      values = raw;
    } else {
      return const [];
    }
    return values
        .whereType<Map>()
        .map((e) => ServerCartItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}

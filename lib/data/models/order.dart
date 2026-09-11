import '../../core/config/app_config.dart';
import '../../core/utils/json_utils.dart';
import '../../core/utils/price_utils.dart';
import '../../core/utils/refund_notice.dart';

/// A `{value, label}` pair.
///
/// Every status-like field on an order is an OBJECT, never a string:
/// `status`, `shipping_status`, `payment_status`, `shipping_method`,
/// `payment_method`, plus `action` on history rows and `cod_status` on
/// shipments. Two degenerate forms occur on the live 90-order dataset and both
/// mean "unset":
///
///   `{"value": null, "label": ""}`  — 7/90 orders with no shipment row
///   `{"value": "",   "label": ""}`  — 5/90 orders with no shipping method
///
/// so [value] is nullable and empty strings normalize to null. Compare with
/// [matches], never `status.value == 'x'` on a raw map.
class StatusValue {
  const StatusValue({this.value, this.label = ''});

  /// Machine value — the token to compare and to send back as a filter.
  final String? value;

  /// Server-rendered display text ("Ready to be shipped out").
  final String label;

  static const StatusValue none = StatusValue();

  factory StatusValue.fromJson(dynamic raw) {
    if (raw is Map) {
      return StatusValue(
        value: asStringOrNull(raw['value']),
        label: decodeEntities(asString(raw['label'])),
      );
    }
    // Orders always send the object form. Other resources in this backend send
    // a bare string for the same concept, so accept it rather than dropping the
    // status entirely if a route is ever reshaped.
    final plain = asStringOrNull(raw);
    return plain == null ? none : StatusValue(value: plain, label: humanize(plain));
  }

  bool get isEmpty => value == null && label.isEmpty;
  bool get isNotEmpty => !isEmpty;

  /// Text to show. Falls back to a humanized [value] because the server sends
  /// `label: ""` alongside a real value on history rows.
  String get display => label.isNotEmpty ? label : humanize(value ?? '');

  bool matches(String other) => value == other;

  /// `ready_to_be_shipped_out` -> `Ready to be shipped out`.
  static String humanize(String raw) {
    if (raw.isEmpty) return '';
    final spaced = raw.replaceAll('_', ' ').replaceAll('-', ' ');
    return spaced[0].toUpperCase() + spaced.substring(1);
  }

  @override
  String toString() => 'StatusValue(${value ?? '-'}, "$label")';
}

/// Order status tokens, as spelled by the backend.
///
/// Note `canceled` — one L. American spelling, and the filter is matched
/// exactly: `?status=cancelled` returns HTTP 200 with an empty list rather than
/// a 422, so a typo looks like "you have no cancelled orders".
class OrderStatuses {
  OrderStatuses._();

  static const String pending = 'pending';
  static const String processing = 'processing';
  static const String completed = 'completed';
  static const String canceled = 'canceled';
}

/// Shipment status tokens, from `ShippingStatusEnum`.
///
/// Only the ones the app branches on. The enum is long — `not_approved`,
/// `arrange_shipment`, `picking`, `manifested`, `in_transit`,
/// `out_for_delivery`, `rto` and more — but everything before delivery is the
/// same answer to the only question asked here.
class ShippingStatuses {
  ShippingStatuses._();

  static const String delivered = 'delivered';
}

/// Product names arrive HTML-escaped ("Chana Dal 1.85 Kg &amp; Kali Masoor"),
/// as do pagination labels ("&laquo; Previous"). Only the handful of entities
/// the backend actually emits are decoded — a full parser is not worth pulling
/// in for this.
String decodeEntities(String input) {
  if (!input.contains('&')) return input;
  return input
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&laquo;', '«')
      .replaceAll('&raquo;', '»')
      // `&amp;` LAST. Decoding it first turns a doubly-escaped `&amp;lt;` into
      // `&lt;` and then into `<`, silently injecting markup the server escaped
      // on purpose.
      .replaceAll('&amp;', '&');
}

/// Resolve an image reference that may be absolute or a bare storage path.
///
/// The order list and detail routes return absolute URLs, but the tracking
/// route dumps the raw Eloquent column ("map-location.png",
/// "products/dals/61a1sdxqijl-sx569.jpg") which only resolves under
/// `/storage/`. Verified live: `GET /storage/map-location.png` -> 200.
String resolveOrderMedia(dynamic raw) {
  final path = asStringOrNull(raw);
  if (path == null) return '';
  if (path.startsWith('http')) return path;
  final clean = path.startsWith('/') ? path.substring(1) : path;
  return '${AppConfig.storageBase}/$clean';
}

/// Pick the display string for a money field that has a `*_formatted` twin.
///
/// The twins come from Laravel's `format_price()`, which **drops the sign**:
/// order 14's first line sends `amount: "-123.00"` with
/// `amount_formatted: "₹123.00"`, and `total: -123` with
/// `total_formatted: "₹123.00"`. Rendering the twin verbatim would show a
/// ₹123 credit as a ₹123 charge, so a negative raw value is formatted locally
/// and the twin is used everywhere else (where it carries the shop's own
/// grouping and symbol).
String formatOrderMoney(String? formatted, double raw) =>
    raw < 0 ? PriceUtils.format(raw) : PriceUtils.resolve(formatted, raw);

/// Server timestamps.
///
/// Orders use ISO-8601 with an offset ("2026-07-16T17:04:00+05:30"); returns
/// use "2026-05-14 16:58:52" with NO zone, which therefore parses as device
/// local time. Both formats are accepted by [DateTime.parse]; the zoneless one
/// is only correct while the device is on IST, which is the shop's market.
DateTime? parseOrderDate(dynamic raw) {
  final text = asStringOrNull(raw);
  return text == null ? null : DateTime.tryParse(text);
}

/// Name/address block shared by `shipping_info` and `billing_info`.
class OrderContact {
  const OrderContact({
    this.name,
    this.phone,
    this.email,
    this.address,
    this.city,
    this.state,
    this.country,
    this.zipCode,
    this.landmark,
    this.district,
    this.otherCity,
    this.fullAddress,
  });

  final String? name;
  final String? phone;
  final String? email;
  final String? address;

  /// Usually a place name, occasionally still a raw geo id.
  ///
  /// `OrderResource`/`OrderDetailResource` emit `city_name`/`state_name`, which
  /// `LocationTrait` resolves — verified live: order 277 returns `"Ahmedabad"` /
  /// `"Gujarat"` where the column itself holds `"574"` / `"11"`.
  ///
  /// The accessor **falls back to the stored value** when it cannot resolve it,
  /// so an id whose `states`/`cities` row was deleted or unpublished still
  /// arrives here as `"11"`. Rows are also genuinely mixed — one live address
  /// stores state `"11"` beside city `"Ahmadabad City"` — so "the server
  /// resolves it now" is not the same as "this is always a name".
  ///
  /// [streetLine] therefore filters on the value itself rather than trusting
  /// the endpoint; see [_looksLikeGeoId].
  final String? city;
  final String? state;

  /// A country name ("India") on the order routes.
  final String? country;
  final String? zipCode;

  /// The nearest landmark, folded into [fullAddress] between the street line
  /// and the city.
  final String? landmark;

  /// Free text, never part of the rendered line.
  final String? district;

  /// The town, when [city] is the literal `"other"`.
  ///
  /// The server does **not** substitute it into its own rendering — an
  /// other-city row comes back with `city_name: "other"` — so [streetLine] puts
  /// it back. See `Address.displayAddress`, which does the same for the address
  /// book.
  final String? otherCity;

  /// The whole address on one line, rendered server-side.
  ///
  /// Preferred over composing the parts when the resource sends it: it orders
  /// the segments the way the courier reads them and resolves the geo ids. Null
  /// on a response that predates it, which is why [streetLine] keeps its own
  /// composition as a fallback.
  final String? fullAddress;

  /// Returns null for an absent block.
  ///
  /// `billing_info` is all-nulls on 82/90 orders (the resource emits a
  /// null-object address), and the Laravel resource's `whenLoaded` default is
  /// `[]`, which serializes as a JSON *array* — so a Map cast would throw.
  /// Both collapse to null here so callers can just null-check.
  /// Whether this is the same place as [other], for the purpose of deciding
  /// whether it is worth printing twice.
  ///
  /// Compared on the parts a customer would read — who, where, and the phone —
  /// rather than field-for-field: `billing_info` and `shipping_info` come from
  /// two different rows written at different moments, so one can carry a
  /// landmark or an email the other does not while naming the identical
  /// doorstep. Printing that as a second "Billing address" block is noise.
  bool sameAs(OrderContact? other) {
    if (other == null) return false;
    String norm(String? v) => (v ?? '').trim().toLowerCase();
    return norm(name) == norm(other.name) &&
        norm(phone) == norm(other.phone) &&
        norm(address) == norm(other.address) &&
        norm(city) == norm(other.city) &&
        norm(state) == norm(other.state) &&
        norm(zipCode) == norm(other.zipCode);
  }

  static OrderContact? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final contact = OrderContact(
      name: asStringOrNull(raw['name']),
      phone: asStringOrNull(raw['phone']),
      email: asStringOrNull(raw['email']),
      address: asStringOrNull(raw['address']),
      city: asStringOrNull(raw['city']),
      state: asStringOrNull(raw['state']),
      country: asStringOrNull(raw['country']),
      zipCode: asStringOrNull(raw['zip_code']),
      landmark: asStringOrNull(raw['landmark']),
      district: asStringOrNull(raw['district']),
      otherCity: asStringOrNull(raw['other_city']),
      fullAddress: asStringOrNull(raw['full_address']),
    );
    return contact.isEmpty ? null : contact;
  }

  bool get isEmpty =>
      name == null &&
      phone == null &&
      email == null &&
      address == null &&
      city == null &&
      state == null &&
      country == null &&
      zipCode == null &&
      landmark == null &&
      district == null &&
      otherCity == null &&
      fullAddress == null;

  /// A bare geo foreign key, e.g. `"574"`.
  ///
  /// Deliberately narrow: only an all-digit string. No Indian city or state is
  /// named in digits, and a *partly* numeric name ("Sector 12") must survive.
  /// The address the way it is written on a parcel — one entry per line.
  ///
  /// [streetLine] joins these same parts with commas, for the places that have
  /// room for exactly one line. **Splitting that string back apart is not the
  /// same thing**: a street line legitimately contains commas of its own
  /// ("306, Ring Road", "402, ganesh rivera"), and splitting shreds it into two
  /// lines. This builds the lines from the fields instead.
  ///
  /// Shares [_cityName]/[_stateName], so a row still carrying a raw geo id
  /// ("574", "11") is dropped here exactly as it is from the single-line form.
  List<String> get addressLines {
    final cityStateZip = [_cityName, _stateName, zipCode]
        .whereType<String>()
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join(', ');

    return [
      for (final line in [
        address,
        landmark,
        cityStateZip,
        country,
      ])
        if ((line ?? '').trim().isNotEmpty) line!.trim(),
    ];
  }

  static bool _looksLikeGeoId(String value) =>
      RegExp(r'^\d+$').hasMatch(value.trim());

  /// The full address on one line.
  ///
  /// [city] and [state] used to be excluded outright, because both order routes
  /// served raw ids and the line would have read
  /// `"306, Ring Road, 574, 11, 382415"`. The order resources now resolve them,
  /// so dropping them would hide the two fields a customer most wants to check.
  ///
  /// They are filtered by **value**, not by which endpoint supplied them: the
  /// tracking route still sends ids into this same class, and a caller cannot
  /// be trusted to know which resource it is holding. An id is skipped, a name
  /// is shown, and a row that is half-and-half — they exist, e.g. state `"11"`
  /// with city `"Ahmadabad City"` — renders the half that reads as a place.
  /// [city] if it reads as a place, else null. Same for [state].
  ///
  /// The id filter is applied **only** to these two. It must not touch
  /// [zipCode], which is legitimately all digits — running the whole list
  /// through one filter silently drops the PIN code.
  String? get _cityName => _placeOrNull(_displayCity);
  String? get _stateName => _placeOrNull(state);

  /// The city to show: the town the customer typed when this order used the
  /// "not in the list" escape hatch, otherwise whatever the resource sent.
  String? get _displayCity {
    final typed = otherCity?.trim() ?? '';
    if (typed.isNotEmpty) return typed;
    return city;
  }

  static String? _placeOrNull(String? value) {
    final v = value?.trim() ?? '';
    return v.isEmpty || _looksLikeGeoId(v) ? null : v;
  }

  /// The full address on one line.
  ///
  /// Prefers the server's own `full_address` when the resource sends one — it
  /// orders the segments the way the courier reads them, and it is the same
  /// string the website prints. The composition below is the fallback for a
  /// response that carries no such key, which includes every cached order and
  /// the public tracking route.
  ///
  /// The one edit made to the server's string is the other-city substitution:
  /// it renders the literal word "other" in the city slot, which is not where
  /// anyone lives.
  String get streetLine {
    final full = fullAddress?.trim() ?? '';
    if (full.isNotEmpty) return _withOtherCity(full);
    return [
      address,
      landmark,
      _cityName,
      _stateName,
      zipCode,
      country,
    ].whereType<String>().where((e) => e.trim().isNotEmpty).join(', ');
  }

  /// Swaps the server's literal `other` segment for the town the customer
  /// typed. Only a **whole** segment is replaced, so a street called "Other
  /// Lane" survives.
  String _withOtherCity(String full) {
    final typed = otherCity?.trim() ?? '';
    if (typed.isEmpty) return full;
    var replaced = false;
    final parts = [for (final part in full.split(',')) part.trim()];
    for (var i = 0; i < parts.length; i++) {
      if (!replaced && parts[i].toLowerCase() == 'other') {
        parts[i] = typed;
        replaced = true;
      }
    }
    return replaced ? parts.where((p) => p.isNotEmpty).join(', ') : full;
  }
}

class OrderCustomer {
  const OrderCustomer({this.name, this.email, this.phone});

  final String? name;
  final String? email;
  final String? phone;

  static OrderCustomer? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final customer = OrderCustomer(
      name: asStringOrNull(raw['name']),
      email: asStringOrNull(raw['email']),
      phone: asStringOrNull(raw['phone']),
    );
    return customer.name == null && customer.email == null && customer.phone == null
        ? null
        : customer;
  }
}

/// One chosen attribute of a variable product, e.g. Pack Size / "5 KG".
class OrderVariationAttribute {
  const OrderVariationAttribute({
    required this.setTitle,
    required this.title,
    this.color,
    this.image,
  });

  final String setTitle;
  final String title;
  final String? color;
  final String? image;

  factory OrderVariationAttribute.fromJson(Map<String, dynamic> j) =>
      OrderVariationAttribute(
        setTitle: decodeEntities(asString(j['attribute_set_title'])),
        title: decodeEntities(asString(j['title'])),
        color: asStringOrNull(j['color']),
        image: asStringOrNull(j['image']),
      );

  String get display => setTitle.isEmpty ? title : '$setTitle: $title';
}

/// A line item. Present on the order DETAIL response only.
class OrderLine {
  const OrderLine({
    required this.id,
    required this.productId,
    required this.name,
    required this.imageUrl,
    required this.quantity,
    required this.unitPrice,
    required this.total,
    this.unitPriceFormatted,
    this.totalFormatted,
    this.sku,
    this.attributes,
    this.productUrl,
    this.weightGrams = 0,
    this.variationAttributes = const [],
    this.storeName,
    this.storeUrl,
  });

  /// `ec_order_product.id` — the id a return request must reference as
  /// `order_item_id`. NOT the catalogue product id.
  final int id;
  final int productId;
  final String name;
  final String imageUrl;
  final int quantity;
  final double unitPrice;
  final double total;
  final String? unitPriceFormatted;
  final String? totalFormatted;
  final String? sku;

  /// Free-text variant summary the server stored at purchase time,
  /// e.g. "(Weight: 10 Kg)". Independent of [variationAttributes], which is
  /// only present for products that are still variations today.
  final String? attributes;
  final String? productUrl;
  final int weightGrams;
  final List<OrderVariationAttribute> variationAttributes;
  final String? storeName;
  final String? storeUrl;

  factory OrderLine.fromJson(Map<String, dynamic> j) {
    final options = _unwrapOptions(j['options']);
    final soldBy = asMap(j['sold_by']);
    return OrderLine(
      id: asInt(j['id']),
      productId: asInt(j['product_id']),
      name: decodeEntities(asString(j['product_name'])),
      imageUrl: resolveOrderMedia(j['product_image']),
      quantity: asInt(j['quantity'] ?? j['qty']),
      unitPrice: asDouble(j['amount'] ?? j['price']),
      // `total` is an int on 151/157 captured lines and a double on 6.
      total: asDouble(j['total']),
      unitPriceFormatted: asStringOrNull(j['amount_formatted']),
      totalFormatted: asStringOrNull(j['total_formatted']),
      // The resource reads sku/attributes with `Arr::get($product->options,…)`,
      // which fails whenever `options` came back as the serialized cart object
      // — so both are null on 38/157 lines *even though the data is right
      // there* inside options. Recover it instead of showing a blank SKU.
      sku: asStringOrNull(j['sku']) ?? asStringOrNull(options['sku']),
      attributes:
          asStringOrNull(j['attributes']) ?? asStringOrNull(options['attributes']),
      productUrl: asStringOrNull(j['product_url']),
      weightGrams: asInt(options['weight']),
      variationAttributes: asMapList(j['variation_attributes'])
          .map(OrderVariationAttribute.fromJson)
          .toList(),
      storeName: asStringOrNull(soldBy['store_name']),
      storeUrl: asStringOrNull(soldBy['store_url']),
    );
  }

  /// `options` arrives in two shapes for the same data:
  ///   detail route  -> `{"\u0000*\u0000items": {...}, "\u0000*\u0000escape…": false}`
  ///                    (PHP's private-property mangling, leaked by json_encode
  ///                    of a serialized Cart item)
  ///   tracking route-> the flat `{"sku": …, "weight": …}` map
  /// Both are unwrapped to the flat map.
  static Map<String, dynamic> _unwrapOptions(dynamic raw) {
    final map = asMap(raw);
    for (final key in map.keys) {
      if (key.endsWith('items') && map[key] is Map) return asMap(map[key]);
    }
    return map;
  }

  String get unitPriceDisplay => formatOrderMoney(unitPriceFormatted, unitPrice);
  String get totalDisplay => formatOrderMoney(totalFormatted, total);

  /// Variant text for the row, preferring the structured attributes.
  String? get variantLabel {
    if (variationAttributes.isNotEmpty) {
      return variationAttributes.map((a) => a.display).join(' · ');
    }
    return attributes;
  }
}

class OrderInvoiceLinks {
  const OrderInvoiceLinks({this.print, this.download});

  /// Both are null when the order has no invoice — verified on every canceled
  /// order in the dataset, where `is_invoice_available` is false and the two
  /// keys are still present with null values.
  final String? print;
  final String? download;

  factory OrderInvoiceLinks.fromJson(dynamic raw) {
    final map = asMap(raw);
    return OrderInvoiceLinks(
      print: asStringOrNull(map['print']),
      download: asStringOrNull(map['download']),
    );
  }

  bool get isAvailable => print != null || download != null;
}

/// A customer order.
///
/// One class covers both shapes the backend returns, because they share 20 of
/// their keys and differ only by what each one *adds*:
///
///   `GET /ecommerce/orders`      list row — adds products_count, product_image,
///                                product_images. Has NO line items, NO
///                                sub_total and NO discount_amount.
///   `GET /ecommerce/orders/{id}` detail  — adds products[], discount_amount,
///                                coupon_code and the four can_* capability
///                                flags. Has NO product_images.
///
/// [hasLineItems] says which one you are holding. An order list screen must
/// render from the list row alone (thumbnails come from [productImages]); only
/// the detail screen may call [OrderRepository.order], otherwise a 90-row list
/// fires 90 requests.
class Order {
  const Order({
    required this.id,
    required this.code,
    required this.status,
    required this.shippingStatus,
    required this.paymentStatus,
    required this.shippingMethod,
    required this.paymentMethod,
    required this.amount,
    required this.taxAmount,
    required this.shippingAmount,
    required this.discountAmount,
    required this.hasLineItems,
    this.serverSubTotal,
    this.paymentFee,
    this.amountFormatted,
    this.taxAmountFormatted,
    this.shippingAmountFormatted,
    this.discountAmountFormatted,
    this.subTotalFormatted,
    this.paymentFeeFormatted,
    this.createdAt,
    this.customer,
    this.shippingInfo,
    this.billingInfo,
    this.shippingCompanyName,
    this.productsCount = 0,
    this.productImage,
    this.productImages = const [],
    this.lines = const [],
    this.couponCode,
    this.discountDescription,
    this.canBeCanceled = false,
    this.canConfirmDelivery = false,
    this.canBeReturned = false,
    this.isInvoiceAvailable = false,
    this.invoiceLinks = const OrderInvoiceLinks(),
    this.histories = const [],
    this.cancellationReason,
    this.cancellationMessage,
  });

  /// The order's timeline, **newest first**, as the detail endpoint sends it.
  ///
  /// Detail shape only — the list endpoint omits it, mirroring the website,
  /// whose list page shows no timeline. Empty is the ordinary case for a list
  /// row, so the UI hides the section rather than showing an empty card.
  final List<OrderHistory> histories;

  /// Raw code, e.g. `change-mind`. Null unless the order was cancelled.
  final String? cancellationReason;

  /// The human sentence, including the customer's free-text note when they left
  /// one. Shown beside the status.
  final String? cancellationMessage;

  bool get hasHistory => histories.isNotEmpty;

  final int id;

  /// ⚠ TWO INCOMPATIBLE FORMATS coexist in the same list:
  ///   `SF10000277`     for id >= 61  (65 of 90 orders)
  ///   `#SF-10000016`   for id <= 57  (25 of 90 orders — leading # AND a dash)
  /// Render [displayCode], never `'#$code'`, and never match `^SF\d+$`.
  final String code;

  final StatusValue status;

  /// Empty (`{value: null, label: ""}`) on the 7 orders with no shipment row.
  final StatusValue shippingStatus;
  final StatusValue paymentStatus;

  /// Empty (`{value: "", label: ""}`) on 5 orders — empty strings, not nulls.
  final StatusValue shippingMethod;
  final StatusValue paymentMethod;

  /// Grand total. Arrives as a 2dp STRING ("1274.15"), like every other amount
  /// on this resource.
  final double amount;
  final double taxAmount;
  final double shippingAmount;

  /// Detail only — the list row omits the key entirely, so it reads 0 there.
  final double discountAmount;

  /// `ec_orders.sub_total` as the **server** reports it — goods value before any
  /// discount, exclusive of tax.
  ///
  /// **Nullable on purpose.** Both order resources omitted this key until it was
  /// added to the backend, so a build talking to an older server gets null and
  /// falls back to summing [lines] (see the [subTotal] getter). Prefer this one
  /// whenever it is present: the line sum is only *coincidentally* equal.
  /// `ec_orders.discount_amount` stores the **unclamped** discount while
  /// `sub_total` is floored at zero before the tax is scaled, so a coupon larger
  /// than the basket breaks the equivalence outright.
  final double? serverSubTotal;

  /// `ec_orders.payment_fee` — the payment-channel surcharge. Nullable for the
  /// same reason as [serverSubTotal].
  ///
  /// This is the term that made orders 14, 15 and 17 each display a total ₹10.00
  /// larger than their visible rows summed to. The fee was in the database all
  /// along and simply was not serialized.
  final double? paymentFee;

  final String? amountFormatted;
  final String? taxAmountFormatted;
  final String? shippingAmountFormatted;
  final String? discountAmountFormatted;
  final String? subTotalFormatted;
  final String? paymentFeeFormatted;

  /// True when the server supplied every term of the money identity:
  ///
  ///     amount = max(sub_total − discount_amount, 0)
  ///            + tax_amount + shipping_amount + payment_fee
  ///
  /// Only then can a bill be drawn whose rows actually sum to the total. When
  /// false the screen shows the line items and the grand total and omits the
  /// breakdown, rather than printing rows that do not add up.
  bool get hasFullBreakdown => serverSubTotal != null && paymentFee != null;

  /// What the breakdown rows add up to. Null when the server did not send enough
  /// terms to compute it.
  double? get breakdownTotal => hasFullBreakdown
      ? (serverSubTotal! - discountAmount).clamp(0, double.infinity) +
          taxAmount +
          shippingAmount +
          paymentFee!
      : null;

  /// Whether the rows this order can draw reconcile with [amount], to half a
  /// paise.
  ///
  /// A false here is a real server-side inconsistency rather than something to
  /// paper over — see `docs/BACKEND_BUGS.md` finding 14, where order 52 misses
  /// by ₹0.01 through discount/tax rounding.
  bool get breakdownReconciles {
    final computed = breakdownTotal;
    return computed != null && (computed - amount).abs() < 0.005;
  }

  final DateTime? createdAt;
  final OrderCustomer? customer;
  final OrderContact? shippingInfo;

  /// Null on 82/90 orders. Treat a null billing address as "same as shipping".
  final OrderContact? billingInfo;

  /// The carrier the order was booked with — "Xpressbees Surface 20kg".
  ///
  /// On the **order**, not on a history row: it is one fact about the shipment
  /// rather than something a step reported, which is why the timeline is handed
  /// it rather than reading it per entry.
  ///
  /// Nullable: an order with no shipment yet has no carrier.
  final String? shippingCompanyName;

  /// Number of line *rows* (not units). List row only.
  final int productsCount;

  /// First thumbnail, null on 9/90 rows whose products were hard-deleted.
  final String? productImage;

  /// Thumbnails for the list row; empty on those same 9 rows.
  final List<String> productImages;

  /// Detail only. Empty on a list row — see [hasLineItems].
  final List<OrderLine> lines;

  /// True when this came from the detail route, i.e. [lines] is authoritative.
  /// An order can legitimately have zero lines, so `lines.isEmpty` is not the
  /// same question.
  final bool hasLineItems;

  final String? couponCode;
  final String? discountDescription;

  /// Capability flags. Detail only — they default to false on a list row, so
  /// action buttons must live on the detail screen.
  final bool canBeCanceled;
  final bool canConfirmDelivery;
  final bool canBeReturned;
  final bool isInvoiceAvailable;
  final OrderInvoiceLinks invoiceLinks;

  factory Order.fromJson(Map<String, dynamic> j) {
    final lines = asMapList(j['products']).map(OrderLine.fromJson).toList();
    return Order(
      id: asInt(j['id']),
      code: asString(j['code']),
      status: StatusValue.fromJson(j['status']),
      shippingStatus: StatusValue.fromJson(j['shipping_status']),
      paymentStatus: StatusValue.fromJson(j['payment_status']),
      shippingMethod: StatusValue.fromJson(j['shipping_method']),
      paymentMethod: StatusValue.fromJson(j['payment_method']),
      amount: asDouble(j['amount']),
      taxAmount: asDouble(j['tax_amount']),
      shippingAmount: asDouble(j['shipping_amount']),
      discountAmount: asDouble(j['discount_amount']),
      // Nullable, not `asDouble`: a server that predates these keys must read as
      // "did not say", never as 0.00. See [Order.serverSubTotal].
      serverSubTotal: asDoubleOrNull(j['sub_total']),
      paymentFee: asDoubleOrNull(j['payment_fee']),
      amountFormatted: asStringOrNull(j['amount_formatted']),
      taxAmountFormatted: asStringOrNull(j['tax_amount_formatted']),
      shippingAmountFormatted: asStringOrNull(j['shipping_amount_formatted']),
      discountAmountFormatted: asStringOrNull(j['discount_amount_formatted']),
      subTotalFormatted: asStringOrNull(j['sub_total_formatted']),
      paymentFeeFormatted: asStringOrNull(j['payment_fee_formatted']),
      createdAt: parseOrderDate(j['created_at']),
      customer: OrderCustomer.fromJson(j['customer']),
      shippingInfo: OrderContact.fromJson(j['shipping_info']),
      billingInfo: OrderContact.fromJson(j['billing_info']),
      shippingCompanyName: asStringOrNull(j['shipping_company_name']),
      productsCount:
          j.containsKey('products_count') ? asInt(j['products_count']) : lines.length,
      productImage: asStringOrNull(j['product_image']),
      productImages: asStringList(j['product_images']),
      lines: lines,
      hasLineItems: j.containsKey('products'),
      couponCode: asStringOrNull(j['coupon_code']),
      discountDescription: asStringOrNull(j['discount_description']),
      canBeCanceled: asBool(j['can_be_canceled']),
      canConfirmDelivery: asBool(j['can_confirm_delivery']),
      canBeReturned: asBool(j['can_be_returned']),
      isInvoiceAvailable: asBool(j['is_invoice_available']),
      invoiceLinks: OrderInvoiceLinks.fromJson(j['invoice_links']),
      // Defaulted, not required: the list endpoint omits the key entirely and
      // so does any response cached before the server started sending it.
      histories: asMapList(j['histories']).map(OrderHistory.fromJson).toList(),
      cancellationReason: asStringOrNull(j['cancellation_reason']),
      // Two names for one thing. The authenticated detail endpoint sends
      // `cancellation_reason_message`; the public tracking endpoint sends
      // `cancellation_reason_description` — captured on the live order 286.
      // Reading both means neither resource has to change for this to work.
      cancellationMessage: asStringOrNull(j['cancellation_reason_message']) ??
          asStringOrNull(j['cancellation_reason_description']),
    );
  }

  /// The code as it should appear in the UI, for both stored formats.
  /// Legacy codes already contain the '#'; new ones must not gain one.
  String get displayCode => code.startsWith('#') ? code.substring(1) : code;

  /// Cash on delivery. The money arrived as cash, so a refund cannot go back
  /// "the way it came".
  bool get isCashOnDelivery => paymentMethod.matches('cod');

  /// Whether the shop is actually holding this customer's money.
  ///
  /// `refunded` counts: it means money *was* taken and has since gone back, so
  /// an order in that state was paid. `pending` does not — nothing was taken,
  /// and there is nothing to return. Live spread across 100 orders:
  /// completed 84, refunded 10, pending 6.
  bool get wasPaid =>
      paymentStatus.matches('completed') || paymentStatus.matches('refunded');

  /// The shop has already sent the money back.
  bool get isRefunded => paymentStatus.matches('refunded');

  /// Whether this order's money is coming back at all — cancelled, or already
  /// refunded. A delivered order the customer is happy with must not be shown
  /// a refund window.
  bool get hasRefundDue => wasPaid && (isCanceled || isRefunded);

  /// Everything a customer might type when hunting for this order.
  ///
  /// The list shape carries no product names — `products` only exists on the
  /// detail route — so this is what a row actually knows: its code, what state
  /// it is in, and what it cost. In practice the code is what people search
  /// for; the rest costs nothing and occasionally helps.
  String get searchHaystack => [
        code,
        displayCode,
        status.display,
        paymentStatus.display,
        shippingStatus.display,
        amountDisplay,
      ].map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).join(' ');

  /// Whether this order answers [query].
  ///
  /// Every whitespace-separated term has to appear somewhere, in any order — so
  /// "10000315 cancel" finds the cancelled order 315 while "10000315 delivered"
  /// finds nothing. A blank query matches everything.
  bool matches(String query) {
    final terms = query.toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((t) => t.isEmpty);
    if (terms.isEmpty) return true;
    final haystack = searchHaystack;
    return terms.every(haystack.contains);
  }

  /// Money is owed but has not gone back yet.
  ///
  /// Live, the two states are genuinely independent: the 10 refunded orders
  /// are `processing` (8) and `completed` (2), **not** cancelled — the shop
  /// refunds through the payment status, whatever the order is doing. So this
  /// is "cancelled and still holding the money", which is the case a customer
  /// chases.
  bool get isRefundInProgress => isCanceled && wasPaid && !isRefunded;

  /// Whether the order carries a billing address worth showing.
  ///
  /// `billing_info` is all-nulls on 82 of 90 orders — the resource emits the
  /// keys either way — and even when present it is usually the delivery
  /// address again. Only a genuinely different one earns a second block.
  bool get hasSeparateBillingAddress =>
      billingInfo != null && !billingInfo!.sameAs(shippingInfo);

  /// What to tell the customer about their money when this order is cancelled,
  /// or null when there is nothing to say.
  ///
  /// Null for an unpaid order. Every one of the account's 13 cancelled orders
  /// was `payment_status: completed`, so the common case does carry a line —
  /// but a COD or pending order must not be told a refund is coming.
  String? get refundNotice {
    if (!wasPaid) return null;
    if (isRefunded) return RefundNotice.issued;
    return isCashOnDelivery
        ? RefundNotice.processed
        : RefundNotice.toOriginalMethod;
  }

  String get amountDisplay => formatOrderMoney(amountFormatted, amount);
  String get taxDisplay => formatOrderMoney(taxAmountFormatted, taxAmount);
  String get shippingDisplay =>
      formatOrderMoney(shippingAmountFormatted, shippingAmount);
  String get discountDisplay =>
      formatOrderMoney(discountAmountFormatted, discountAmount);

  /// Items subtotal, or **null when this shape cannot answer**.
  ///
  /// Two sources, in order of authority:
  ///
  ///  1. [serverSubTotal] — `ec_orders.sub_total` itself, once the backend
  ///     serializes it. Correct on every order, including the ones the fallback
  ///     gets wrong, and available on the **list row as well as the detail**.
  ///  2. the sum of the server's own per-line totals, for a server that predates
  ///     that field. Detail shape only, because a list row carries no lines.
  ///
  /// The fallback is a good approximation and nothing more. It cannot see a
  /// discount clamped at zero, and it silently omits `payment_fee` — which is
  /// exactly why orders 14, 15 and 17 each showed a grand total ₹10.00 above
  /// their own rows.
  ///
  /// A list row without [serverSubTotal] still returns null rather than deriving
  /// `amount - tax - shipping + discount`. That formula is missing the
  /// `payment_fee` term and is provably wrong on this account: order 14 reports
  /// `amount "487.00"` with tax, shipping and discount all `"0.00"`, while its
  /// two lines total 477 (-123 + 600). The list screen would have shown ₹487 and
  /// the detail screen ₹477 for the same order. Show nothing rather than a
  /// fabricated total — see also orders 15 (587 vs 577) and 17 (7510 vs 7500).
  double? get subTotal {
    final fromServer = serverSubTotal;
    if (fromServer != null) return fromServer;
    if (!hasLineItems) return null;
    return lines.fold<double>(0, (sum, line) => sum + line.total);
  }

  /// Null exactly when [subTotal] is — do not substitute "₹0.00".
  ///
  /// Prefers the server's own `sub_total_formatted` when it came with the
  /// figure, so the currency rendering matches the rest of the bill exactly
  /// rather than being re-formatted client-side.
  String? get subTotalDisplay {
    if (serverSubTotal != null && subTotalFormatted != null) {
      return subTotalFormatted;
    }
    final value = subTotal;
    return value == null ? null : PriceUtils.format(value);
  }

  /// Null when the server does not serialize `payment_fee` — which is not the
  /// same as a fee of zero, and must not render as "₹0.00".
  String? get paymentFeeDisplay {
    final value = paymentFee;
    if (value == null) return null;
    return paymentFeeFormatted ?? PriceUtils.format(value);
  }

  /// Best available thumbnail across both response shapes.
  String? get thumbnail {
    if (productImage != null) return productImage;
    if (productImages.isNotEmpty) return productImages.first;
    for (final line in lines) {
      if (line.imageUrl.isNotEmpty) return line.imageUrl;
    }
    return null;
  }

  bool get isCanceled => status.matches(OrderStatuses.canceled);
  bool get isCompleted => status.matches(OrderStatuses.completed);

  /// Whether the parcel has reached the customer.
  ///
  /// Either signal counts, because the backend ties them together: when a
  /// shipment is set to `delivered`, `ShipmentController` calls
  /// `OrderHelper::shippingStatusDelivered()`, which is
  /// `setOrderCompleted($shipment->order_id, …)` — so a delivered parcel
  /// *becomes* a completed order.
  ///
  /// Reading only `shipping_status` would miss an order completed without a
  /// shipment row (a manual close, a pickup); reading only `status` would miss
  /// the window between the courier's update and the order write. Neither is
  /// worth a customer being told their delivered order has no invoice.
  bool get isDelivered =>
      shippingStatus.matches(ShippingStatuses.delivered) || isCompleted;
}

/// One entry of Laravel's `meta.links` pager.
///
/// Modelled only because the ellipsis entry **omits the `page` key entirely**
/// (`{"url": null, "label": "...", "active": false}` — no `page`) while every
/// other entry has it. It appears as soon as the page count exceeds 10, i.e.
/// at `per_page=1` on this 90-order account, so a required-int decoder would
/// crash there and nowhere else.
class OrderPageLink {
  const OrderPageLink({
    required this.label,
    this.page,
    this.url,
    this.isActive = false,
  });

  final String label;
  final int? page;
  final String? url;
  final bool isActive;

  bool get isEllipsis => page == null && url == null;

  factory OrderPageLink.fromJson(Map<String, dynamic> j) => OrderPageLink(
        label: decodeEntities(asString(j['label'])),
        page: j['page'] == null ? null : asInt(j['page']),
        url: asStringOrNull(j['url']),
        isActive: asBool(j['active']),
      );

  /// Reads the pager out of a paginated body's `meta`.
  static List<OrderPageLink> listFrom(dynamic body) {
    final meta = asMap(body is Map ? body['meta'] : null);
    return asMapList(meta['links']).map(OrderPageLink.fromJson).toList();
  }
}


/// One row of an order's timeline.
///
/// From `GET /ecommerce/orders/{id}`, newest first. The website renders the same
/// rows as a vertical timeline on its "Order information" page.
class OrderHistory {
  const OrderHistory({
    required this.id,
    required this.action,
    required this.description,
    required this.isSystem,
    this.createdAt,
    this.refundAmount,
    this.refundAmountFormatted,
    this.location,
    this.courierName,
  });

  final int id;

  /// `action.value` — the machine code, e.g. `confirm_order`. **Icons and logic
  /// branch on this**, never on `action.label`: no translations exist for these
  /// codes, so the label falls back to the raw code and would render
  /// "send_order_confirmation_email" at a customer.
  ///
  /// Treat the set as open-ended. New codes are added server-side, so anything
  /// keyed on this needs a default branch.
  final String action;

  /// The display text, already resolved server-side.
  ///
  /// ⚠ Only on the **authenticated detail** endpoint. The public
  /// `POST /orders/tracking` returns the same rows with placeholders **unfilled**
  /// — captured live on order 286: `"Order was verified by %user_name%"`. Never
  /// render a history that came from tracking.
  final String description;

  /// True when the system did it, false when a person did.
  ///
  /// **No longer used for anything.** The server now filters the internal rows
  /// out before they are sent — 8 customer-facing steps where the raw table
  /// held 10 — so the person/gear split it used to drive separated nothing:
  /// every remaining row is customer-facing whichever flag it carries. Order
  /// 314 proves it, with `return_order` marked `is_system: true` sitting beside
  /// `refund` marked false, both plainly the customer's business.
  ///
  /// Kept because the field still arrives; the marker branches on [action].
  final bool isSystem;

  /// Where the courier scanned the parcel, when it said. Nullable — a status
  /// moved by hand in admin has no scan behind it.
  final String? location;

  /// The courier that reported this step. Nullable for the same reason.
  ///
  /// Distinct from [Order.shippingCompanyName], which is the carrier the whole
  /// order was booked with: this is who reported *this line*.
  final String? courierName;

  /// Parsed from `created_at`, which carries the server's offset (`+05:30`).
  /// Converted to local time so a timestamp agrees with the device clock.
  ///
  /// The sibling `created_at_formatted` is a server-rendered `dd-mm-yyyy
  /// HH:ii:ss` string and is deliberately not used — it cannot be localised and
  /// cannot be re-formatted.
  final DateTime? createdAt;

  /// Only on `action == "refund"`.
  final double? refundAmount;
  final String? refundAmountFormatted;

  bool get isRefund => action == 'refund';

  factory OrderHistory.fromJson(Map<String, dynamic> j) {
    final rawAction = j['action'];
    return OrderHistory(
      id: asInt(j['id']),
      // An object today. Also read as a bare string, since every other status
      // field in this API has appeared in both shapes at some point.
      action: rawAction is Map
          ? asString(rawAction['value'])
          : asString(rawAction),
      description: asString(j['description']),
      // Defaults to true: an unattributed row is more plausibly the system's
      // than a named person's, and the icon is all that hangs on it.
      isSystem: j['is_system'] == null ? true : asBool(j['is_system']),
      createdAt: parseOrderDate(j['created_at'])?.toLocal(),
      refundAmount: asDoubleOrNull(j['refund_amount']),
      refundAmountFormatted: asStringOrNull(j['refund_amount_formatted']),
      location: asStringOrNull(j['location']),
      courierName: asStringOrNull(j['courier_name']),
    );
  }

  /// The courier's own report of this step, or null when there was none.
  ///
  /// Both halves are nullable and independent — a scan can name a place with no
  /// carrier, or a carrier with no place — so this joins whichever arrived
  /// rather than assuming both.
  String? get courierNote {
    final parts = [
      if ((courierName ?? '').trim().isNotEmpty) courierName!.trim(),
      if ((location ?? '').trim().isNotEmpty) location!.trim(),
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

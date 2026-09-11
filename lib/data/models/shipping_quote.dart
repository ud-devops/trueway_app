/// Shipping models for the three `/logistics/*` routes.
///
/// Two different shapes come back and they are **not** interchangeable:
///
///   * [ShippingQuote] — what `check-pincode` / `batch-check-pincodes` return:
///     the backend already picked one courier for you and collapsed the rate
///     list down to a single number. Good for a "delivers by X for ₹Y" line on
///     a product page. It is *not* a chooser.
///   * [CourierOption] — one row of `check-serviceability`'s
///     `available_courier_companies`, i.e. the same rate list the web's
///     `handle_shipping_fee` filter presents as selectable shipping methods.
///     This is what checkout must show, because the customer's pick becomes the
///     order's `shipping_method` — and the row the *server* prices the order
///     from. See [CourierOption.billedPrice].
///
/// The two do **not** share a "best courier" rule, and this file used to claim
/// they did. `PinCodeDeliveryService::findBestCourier` (`:157-177`) is what
/// collapses a [ShippingQuote] to one courier, and that service serves the
/// product page's "delivers to your pincode" widget only — the web *checkout*
/// preselects nothing (`shipping-methods.blade.php` renders a radio per courier
/// and waits). So a `CourierOption.best` helper existed here mirroring a rule
/// that checkout never applied, and preselecting from it picked Blue Dart Air at
/// ₹1,284.15 over Xpressbees Surface at ₹324.30 on a live quote. It is gone;
/// [sortBest] survives as a *display order* only.
library;

import '../../core/utils/json_utils.dart';
import '../../core/utils/price_utils.dart';

// ---------------------------------------------------------------------------
// Date parsing
// ---------------------------------------------------------------------------

/// Parses `"04-08-2026"` — **dd-MM-yyyy**, not ISO and not US order.
///
/// This is `BaseHelper::formatDate()` output, whose pattern comes from an admin
/// setting (`date_format`), so it is not contractually frozen. Handing the
/// string to `DateTime.parse` yields either a `FormatException` or — worse, for
/// a day <= 12 — a silently wrong date read as yyyy-MM-dd. So: parse the known
/// pattern strictly, fall back to ISO, and otherwise give up and return null
/// rather than invent a delivery date. The raw string is always kept alongside
/// so the UI can still show what the server said.
DateTime? parseDdMmYyyy(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;

  final match = RegExp(r'^(\d{1,2})-(\d{1,2})-(\d{4})$').firstMatch(value);
  if (match != null) {
    final day = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final year = int.parse(match.group(3)!);
    if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      final parsed = DateTime(year, month, day);
      // Rejects 31-02-2026, which DateTime would happily roll into March.
      if (parsed.year == year && parsed.month == month && parsed.day == day) {
        return parsed;
      }
    }
    return null;
  }

  // Not the configured pattern — accept an ISO date if that is what arrived.
  return DateTime.tryParse(value);
}

const List<String> _monthAbbreviations = [
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];

/// Parses Shiprocket's `etd`, `"Aug 04, 2026"`.
///
/// Untouched by the backend — it is upstream's own string, in English month
/// abbreviations regardless of the shop's locale.
DateTime? parseEtd(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;

  final match =
      RegExp(r'^([A-Za-z]{3,})\s+(\d{1,2}),?\s+(\d{4})$').firstMatch(value);
  if (match == null) return null;

  final month = _monthAbbreviations
      .indexOf(match.group(1)!.toLowerCase().substring(0, 3));
  if (month < 0) return null;

  final day = int.parse(match.group(2)!);
  final year = int.parse(match.group(3)!);
  if (day < 1 || day > 31) return null;

  final parsed = DateTime(year, month + 1, day);
  return parsed.day == day ? parsed : null;
}

// ---------------------------------------------------------------------------
// ShippingQuote
// ---------------------------------------------------------------------------

/// The single pre-picked quote from `POST /logistics/check-pincode`.
///
/// Verified live (2026-08-01), `{pin_code: "110001", product_id: 118}`:
///
/// ```
/// 200 {"status":"success","message":"Delivery available","deliverable":true,
///      "pin_code":"110001","estimated_delivery_days":"2",
///      "estimated_delivery_date":"03-08-2026","shipping_charge":321.51,
///      "courier_name":"DTDC Surface 10kg","cod_available":1,"success":true}
/// ```
///
/// Three traps, all confirmed against the live route and
/// `DeliveryController::checkPinCode`:
///
///   1. `estimated_delivery_days` is a **String** (`"2"`), never a number.
///   2. `estimated_delivery_date` is **dd-MM-yyyy**. See [parseDdMmYyyy].
///   3. `cod_available` is an **int** 1/0 — it is `$bestCourier['cod']` passed
///      straight through.
///
/// And one thing the shape implies but does not deliver: `quantity` is accepted
/// by the route and **ignored**. The controller reads only `pin_code` and
/// `product_id`, then bills the *single-unit* weight
/// (`$product->weight / 1000`, floored at 0.1 kg). Probed: qty 1 and qty 5 for
/// product 118 both returned ₹321.51. So this number is a per-product teaser,
/// not a cart shipping fee — for a real cart quote use
/// `LogisticsRepository.serviceability` with the cart's `package_dimensions`.
class ShippingQuote {
  const ShippingQuote({
    required this.deliverable,
    required this.pinCode,
    required this.courierName,
    required this.shippingCharge,
    required this.estimatedDeliveryDays,
    required this.estimatedDeliveryDateRaw,
    required this.estimatedDeliveryDate,
    required this.codAvailable,
    required this.message,
  });

  /// Whether the shop can ship here at all. False also carries a [message]
  /// worth showing — the server writes a usable sentence for every branch.
  final bool deliverable;

  final String pinCode;

  /// Empty when [deliverable] is false — there was no courier to name.
  final String courierName;

  /// The pre-picked courier's `rate`, in rupees. Zero when not deliverable.
  ///
  /// A **teaser**, and deliberately not reconciled with
  /// [CourierOption.billedPrice]: `PinCodeDeliveryService` hand-builds this
  /// payload from `$bestCourier['rate']` for a single-unit product-page line,
  /// and no order is ever priced from it. Cart and checkout money comes from
  /// `check-serviceability` rows.
  final double shippingCharge;

  /// Coerced from the string the API sends. Zero when not deliverable.
  final int estimatedDeliveryDays;

  /// Exactly what the server sent, e.g. `"03-08-2026"`. Kept because
  /// [estimatedDeliveryDate] goes null if the admin changes `date_format`, and
  /// showing the server's own string beats showing nothing.
  final String estimatedDeliveryDateRaw;

  /// Null when the field was absent (not deliverable) or unparseable.
  final DateTime? estimatedDeliveryDate;

  final bool codAvailable;

  /// The server's sentence: "Delivery available", "Unable to check delivery
  /// availability", "Delivery not available for this pin code". Show verbatim.
  final String message;

  factory ShippingQuote.fromJson(Map<String, dynamic> j) => ShippingQuote(
        deliverable: asBool(j['deliverable']),
        pinCode: asString(j['pin_code']),
        courierName: asString(j['courier_name']),
        shippingCharge: asDouble(j['shipping_charge']),
        estimatedDeliveryDays: asInt(j['estimated_delivery_days']),
        estimatedDeliveryDateRaw: asString(j['estimated_delivery_date']),
        estimatedDeliveryDate:
            parseDdMmYyyy(asStringOrNull(j['estimated_delivery_date'])),
        codAvailable: asBool(j['cod_available']),
        message: asString(j['message']),
      );

  /// For the 422 branch, where the body carries no courier data at all.
  ///
  /// `POST /logistics/check-pincode {"pin_code":"123456","product_id":118}`
  /// -> `422 {"status":"error","message":"Unable to check delivery
  /// availability","deliverable":false,"pin_code":"123456","success":false}`
  factory ShippingQuote.notDeliverable(
    String pinCode, {
    required String message,
  }) =>
      ShippingQuote(
        deliverable: false,
        pinCode: pinCode,
        courierName: '',
        shippingCharge: 0,
        estimatedDeliveryDays: 0,
        estimatedDeliveryDateRaw: '',
        estimatedDeliveryDate: null,
        codAvailable: false,
        message: message,
      );

  /// There is no `shipping_charge_formatted` twin on this route — the whole
  /// payload is hand-built in `PinCodeDeliveryService`, not a Botble resource —
  /// so this formats the server's number rather than recomputing anything.
  String get shippingChargeFormatted => PriceUtils.format(shippingCharge);

  /// True when the quote is worth putting a price next to.
  bool get hasCharge => deliverable && shippingCharge > 0;

  @override
  String toString() =>
      'ShippingQuote($pinCode, deliverable: $deliverable, $courierName, '
      '$shippingCharge, ${estimatedDeliveryDays}d)';
}

// ---------------------------------------------------------------------------
// CourierOption
// ---------------------------------------------------------------------------

/// One selectable courier from `POST /logistics/check-serviceability`.
///
/// ## Where these live in the payload
///
/// **`data.data.available_courier_companies`** — verified live, not assumed.
/// `DeliveryController::checkServiceability` puts Shiprocket's *entire*
/// response body under its own `data` key, and Shiprocket's body is itself
/// `{data: {available_courier_companies: [...]}, currency: "INR", ...}`. Hence
/// the doubled `data`. `PinCodeDeliveryService` reads
/// `$result['data']['available_courier_companies']` because it calls Shiprocket
/// directly and never adds the outer wrapper — same array, one level shallower.
///
/// ## Which field is the price — and it is NOT `rate`
///
/// **[billedPrice].** The server does not read `rate` at all. It rebuilds the
/// rate table itself and sums the components:
///
/// ```php
/// // ShipRocketService.php:1874-1886
/// $freightCharge   = (float) Arr::get($courier, 'freight_charge', 0);
/// $coverageCharges = (float) Arr::get($courier, 'coverage_charges', 0);
/// $codCharges      = (float) Arr::get($courier, 'cod_charges', 0);
/// $otherCharges    = (float) Arr::get($courier, 'other_charges', 0);
/// $baseShippingCost = $freightCharge + $coverageCharges;
/// $totalCost        = $baseShippingCost + $otherCharges;
/// if ($this->isCodOrder($originalData)) { $totalCost += $codCharges; }
/// // :1894  'price' => $totalCost
/// ```
///
/// and `API/CheckoutController.php:446` bills exactly that
/// (`$shippingAmount = Arr::get($shippingMethod, 'price', 0)`), adding it to the
/// order at `:462`. So the billed figure is
/// `freight_charge + coverage_charges + other_charges`, plus `cod_charges` only
/// when the quote was a COD one.
///
/// `rate` is upstream's own convenience total and it omits two of those four
/// components. Verified live 2026-08-04, pickup 311001 -> delivery 382415,
/// 5.0 kg 20×7×49, qc_check 0:
///
/// ```
/// declared_value 2400, cod 0   coverage_charges 0 on every row
///   Xpressbees Surface 5kg   rate 272.06  freight 272.06  → billed 272.06  ✓ agree
/// declared_value 2500, cod 0   coverage_charges 49.00 on every row
///   Xpressbees Surface 5kg   rate 272.06  freight 272.06  → billed 321.06  ✗ ₹49 short
/// declared_value 2500, cod 1
///   Xpressbees Surface 5kg   rate 341.31  freight 272.06 + cover 49 + cod 69.25
///                                                        → billed 390.31  ✗ ₹49 short
/// ```
///
/// So `rate` *does* already equal [billedPrice] on some rows — every row whose
/// `coverage_charges` and `other_charges` are both zero, which is every quote
/// below the insurance threshold. That is coincidence, not agreement: `rate` is
/// `freight_charge` on a prepaid quote and `freight_charge + cod_charges` on a
/// COD one, and it never carries coverage or other charges. Summing the
/// components reproduces `rate` exactly on the rows where they agree and is the
/// server's own number on the rows where they do not, so it is correct for both.
///
/// Historical corroboration from real orders: order 275 recorded 802.12
/// = 741.32 freight + 11.80 other + 49.00 coverage; order 266 (COD) recorded
/// 326.31 = 272.06 + 5.90 other + 48.35 cod. `other_charges` is not always zero.
///
/// Do not use `cost` either: it is the empty string `""` on every row of every
/// capture taken.
///
/// ## Ordering
///
/// The array is **not** sorted by price, nor by speed. A live prepaid
/// 110001 -> 560001 call came back 276, 190.11, 212.8, 218.36, 266.65, 319.79,
/// 344.25 with days 5, 5, 5, 6, 6, 3, 3 — that is Shiprocket's own
/// recommendation ranking (`recommended_by: "Recommendation By Shiprocket"`).
/// The client must sort. See [sortBest] / [byBestFirst] / [byCheapest].
///
/// ## Two ids, and picking the wrong one bills ₹0.00
///
/// Every row carries **both** `courier_company_id` (400) and `id`
/// (1016322646). They are not interchangeable and they serve different
/// purposes — see [courierCompanyId] and [rateId].
class CourierOption {
  const CourierOption({
    required this.courierCompanyId,
    required this.courierName,
    required this.rate,
    required this.freightCharge,
    required this.codCharges,
    required this.codAvailable,
    required this.estimatedDeliveryDays,
    required this.etd,
    required this.etdDate,
    required this.city,
    required this.deliveryPerformance,
    this.coverageCharges = 0,
    this.otherCharges = 0,
    this.codQuoted = false,
    this.rateId,
  });

  /// Stable id for this courier. Use it as the **selection key** — [courierName]
  /// is human text and two rows can share a name across weight slabs.
  ///
  /// This is `courier_company_id`, e.g. `400`. It is *not* what checkout puts in
  /// `shipping_option`; that is [rateId]. See [shippingOptionKey].
  final int courierCompanyId;

  /// The **raw Shiprocket rate id** — the row's own `id`, e.g. `"1016322646"`.
  ///
  /// Distinct from [courierCompanyId] and the only field that can build the
  /// `shipping_option` value the checkout endpoint looks up. See
  /// [shippingOptionKey] for why, and for the backend line numbers.
  ///
  /// Nullable and kept verbatim as text:
  ///
  ///   * **Nullable** because nothing in the contract promises the field. The
  ///     backend reads it with `Arr::get($courier, 'id')`
  ///     (`ShipRocketService.php:1870`), which yields `null` for a row without
  ///     one, and every capture to date has had it on every row — but a row that
  ///     lacks it must degrade to "no key" rather than crash or invent one.
  ///   * **Text**, not `int`, because `ShipRocketService.php:1889` builds the key
  ///     by PHP string concatenation. Storing the wire form and concatenating it
  ///     the same way is the only way to be byte-identical for free: no int
  ///     round-trip can drop a leading zero or overflow a wider id later.
  ///
  /// Live capture (2026-08-04, 311001 -> 560001, 10.2 kg 20×7×49): a row with
  /// `"courier_company_id": 400` carried `"id": 1016322646`, and its sibling
  /// `"courier_company_id": 15123` carried `"id": 1051772883`.
  final String? rateId;

  /// e.g. "Delhivery Surface", "DTDC Air 500gm". This is the string the web
  /// stores as the order's `shipping_method`.
  final String courierName;

  /// Upstream's own total, in rupees. **Not the price the customer is quoted.**
  ///
  /// Kept because it is the field every capture and every earlier note refers
  /// to, and because it is a cheap cross-check: on a prepaid quote
  /// `rate == freightCharge`, on a COD quote `rate == freightCharge +
  /// codCharges`. What it never contains is [coverageCharges] or
  /// [otherCharges], which is why quoting it under-bills every basket over the
  /// insurance threshold. Bill [billedPrice]. See the class doc for the live
  /// capture.
  final double rate;

  /// The carriage itself — the first term of [billedPrice] and the one the
  /// server reads (`ShipRocketService.php:1874`).
  final double freightCharge;

  /// Shipment insurance, keyed off `declared_value`, **not** off the courier.
  ///
  /// Absent from [rate] entirely. Zero on every row of a low-value quote and
  /// identical on every row of a high-value one — live 311001 -> 382415 at
  /// declared_value 2400 it was 0 across all six couriers and at 2500 it was
  /// 49.00 across all six. `declared_value` is the basket's own `order_total`,
  /// so this is a step every cart crosses on the way past ~₹2,500.
  final double coverageCharges;

  /// Upstream's catch-all surcharge line (`other_charges`). Zero on the lanes
  /// captured in 2026 but ₹11.80 on order 275 and ₹5.90 on order 266, both of
  /// which the server billed. Absent from [rate].
  final double otherCharges;

  /// The cash-on-delivery surcharge. Zero on every prepaid row.
  ///
  /// Counted in [billedPrice] **only** when [codQuoted] — the server's own
  /// condition is `if ($this->isCodOrder($originalData))`, i.e. a property of
  /// the request, not of the row.
  final double codCharges;

  /// Whether this row came back from a `cod: 1` serviceability request.
  ///
  /// Carried on the row rather than asked for at every call site so that no
  /// screen can price a COD row as if it were prepaid (or the reverse) by
  /// forgetting to thread the flag through. [listFrom] stamps it from the
  /// request the list was fetched with.
  final bool codQuoted;

  /// The upstream `cod` flag: whether this courier can carry cash-on-delivery.
  final bool codAvailable;

  /// Coerced from the string `"3"`.
  final int estimatedDeliveryDays;

  /// Shiprocket's own date string, `"Aug 04, 2026"`. Kept verbatim; see [etdDate].
  final String etd;

  /// [etd] parsed, or null if upstream changed the format.
  final DateTime? etdDate;

  /// Destination city as the courier knows it — casing is inconsistent
  /// ("Bangalore" vs "BANGALORE" in the same response). Informational only.
  final String city;

  /// Upstream's 0-5 score. Arrives as a number on every row observed, but the
  /// sibling `rating`/`pickup_performance` fields have been seen as strings, so
  /// this is coerced too.
  final double deliveryPerformance;

  /// [cod] is the flag the *request* carried, not anything read out of [j] —
  /// see [codQuoted].
  factory CourierOption.fromJson(Map<String, dynamic> j, {bool cod = false}) =>
      CourierOption(
        courierCompanyId: asInt(j['courier_company_id']),
        rateId: parseRateId(j['id']),
        courierName: asString(j['courier_name']),
        rate: asDouble(j['rate']),
        freightCharge: asDouble(j['freight_charge']),
        coverageCharges: asDouble(j['coverage_charges']),
        otherCharges: asDouble(j['other_charges']),
        codCharges: asDouble(j['cod_charges']),
        codQuoted: cod,
        codAvailable: asBool(j['cod']),
        estimatedDeliveryDays: asInt(j['estimated_delivery_days']),
        etd: asString(j['etd']),
        etdDate: parseEtd(asStringOrNull(j['etd'])),
        city: asString(j['city']),
        deliveryPerformance: asDouble(j['delivery_performance']),
      );

  /// **The number the customer is quoted and the server bills.**
  ///
  /// `freight_charge + coverage_charges + other_charges`, plus `cod_charges`
  /// when [codQuoted]. This is `ShipRocketService.php:1880-1886`'s `$totalCost`
  /// term for term, stored by `:1894` as the rate entry's `price` and read back
  /// by `API/CheckoutController.php:446` as the order's shipping amount.
  ///
  /// Reproducing it here is not belt-and-braces: the app deliberately omits
  /// `shipping_amount` from the checkout POST so the server prices the order
  /// (`CheckoutController.php:425` sets `$useClientShippingAmount` from
  /// `$request->has('shipping_amount')` and `:445` skips server pricing when
  /// true), and the app then reconciles the returned total against what the
  /// button said. Quoting [rate] instead made that reconciliation fail by
  /// exactly `coverage_charges` on every basket over the insurance threshold.
  double get billedPrice =>
      freightCharge +
      coverageCharges +
      otherCharges +
      (codQuoted ? codCharges : 0);

  /// [billedPrice], rendered. The only price string a customer may be shown for
  /// a courier.
  String get billedPriceFormatted => PriceUtils.format(billedPrice);

  /// True when [rate] would have quoted something other than [billedPrice].
  ///
  /// Diagnostic only — nothing in the UI branches on it. It exists so a probe
  /// or a test can name the divergence instead of asserting on a magic number.
  bool get rateUnderQuotes => (billedPrice - rate).abs() >= 0.005;

  /// The wire form of a courier row's `id`, or null when there isn't a usable
  /// one.
  ///
  /// Deliberately **not** [asStringOrNull]: that would accept `true` and hand
  /// back `"true"`, and would render a JSON `1016322646.0` as `"1016322646.0"`.
  /// Either would produce a `shipping_option` the server cannot match, and a
  /// key that silently misses is the whole failure this field exists to prevent
  /// — better no key at all, which checkout can detect, than a plausible wrong
  /// one, which it cannot.
  ///
  /// Live payloads send a JSON integer. Strings are accepted because the id is
  /// upstream's and the backend never casts it (`Arr::get` then string
  /// concatenation, `ShipRocketService.php:1870` and `:1889`), so whatever
  /// Shiprocket sends is what the key is built from.
  static String? parseRateId(dynamic v) {
    if (v is int) return v.toString();
    if (v is double) {
      // Only an integral double can be an id; anything else is not one.
      if (v.isNaN || v.isInfinite || v != v.roundToDouble()) return null;
      return v.toInt().toString();
    }
    if (v is String) {
      final s = v.trim();
      return s.isEmpty ? null : s;
    }
    // null, bool, Map, List — none of these is a rate id.
    return null;
  }

  /// Pulls the rate list out of a `check-serviceability` body.
  ///
  /// Walks `data.data.available_courier_companies` defensively: on the upstream
  /// failure branch the body is `{success:false, data:{message, status}}` with
  /// no list at all, and that branch still arrives as **HTTP 200**.
  ///
  /// A missing [rateId] is deliberately **not** a drop reason. Such a row is
  /// still a real, priced offer, and the backend still lists it —
  /// `formatServiceabilityRates` skips only `blocked` rows
  /// (`ShipRocketService.php:1864`). It merely cannot be turned into a
  /// `shipping_option`, and hiding it would silently shrink the customer's
  /// choices over a field they cannot see. Checkout gates on
  /// [hasShippingOptionKey] instead, at the point where the key is needed.
  /// [cod] must be the flag the request was made with; it is stamped onto every
  /// row as [codQuoted] and decides whether `cod_charges` counts toward
  /// [billedPrice].
  static List<CourierOption> listFrom(dynamic body, {bool cod = false}) {
    final outer = asMap(body)['data'];
    final inner = asMap(outer)['data'];
    final rows = asMapList(asMap(inner)['available_courier_companies']);
    return rows
        .map((row) => CourierOption.fromJson(row, cod: cod))
        // A row with no id and no name is not selectable and could not be
        // stored as an order's `shipping_method` either.
        .where((c) => c.courierCompanyId > 0 || c.courierName.isNotEmpty)
        // ...and a row the server would price at zero is not an offer. The
        // guard is on [billedPrice] rather than on `rate` because that is the
        // figure the order is actually charged: an absent `freight_charge`
        // coerces to 0 through [asDouble] here *and* through
        // `(float) Arr::get($courier, 'freight_charge', 0)` on the server, so a
        // row that sums to zero here is a row the server would bill at 0.00 —
        // the bill would print "Delivery FREE" for a shipment the shop still
        // pays a courier to carry. That is precisely the lie the hardcoded FREE
        // line used to tell. Shiprocket never quotes 0; free shipping only ever
        // comes from a coupon, and the backend applies that to the order, not
        // to a courier row.
        .where((c) => c.billedPrice > 0)
        .toList();
  }

  /// The value checkout must send as `shipping_option`, e.g.
  /// `"shiprocket_1016322646"`. Null when this row carried no [rateId].
  ///
  /// ## Why it is the rate id and NOT the courier company id
  ///
  /// The server does not receive a courier — it receives a *string key* and
  /// looks it up in the rate table it rebuilds for itself. That table is keyed
  /// by the Shiprocket rate id:
  ///
  /// ```php
  /// // ShipRocketService.php:1868-1870
  /// // Get the actual courier_company_id (e.g., 225) - NOT the rate id (e.g., 461078944)
  /// $courierCompanyId = Arr::get($courier, 'courier_company_id');
  /// $rateId           = Arr::get($courier, 'id');
  /// ...
  /// // ShipRocketService.php:1889
  /// $rateIdKey = 'shiprocket_' . $rateId;
  /// $rates[$rateIdKey] = [... 'courier_company_id' => $courierCompanyId ...];
  /// ```
  ///
  /// `courier_company_id` survives only as a *payload field* on the entry; it is
  /// never part of the key. So `"shiprocket_400"` is not a key that exists, and
  /// sending it does not fail loudly — the lookup simply misses, the resolved
  /// shipping method is null, and the order is written with
  /// `shipping_amount = 0.00` (`Arr::get($shippingMethod, 'price', 0)`). The
  /// customer gets free delivery they did not earn and the shop eats the
  /// courier bill, with nothing anywhere reporting an error. That silent
  /// undercharge is why this getter exists rather than a `"shiprocket_$id"`
  /// built at the call site from whichever id was nearest.
  ///
  /// ## The key can still miss, and callers must expect it
  ///
  /// A rate id identifies a *quote*, not a courier: it is stable per courier per
  /// rate slab, but not across slabs. Probed live 2026-08-04 — India Post Speed
  /// Post Prepaid came back as `1016312390` for a 0.5 kg parcel and
  /// `1016322646` for a 10.2 kg one, while Blue Dart Air held `913387706` across
  /// two different pickup postcodes. The server re-quotes Shiprocket itself with
  /// its own `store_zip_code`, so the key this app captured may not appear in
  /// the table the server builds — which lands as the same silent 0.00. The
  /// order total the server returns is therefore the only figure that can be
  /// trusted, and checkout has to reconcile it against what the button said
  /// before taking any money.
  String? get shippingOptionKey {
    final id = rateId;
    return id == null ? null : 'shiprocket_$id';
  }

  /// Whether this row can be sent to checkout at all. False means the server
  /// would have nothing to look up.
  bool get hasShippingOptionKey => rateId != null;

  String get codChargesFormatted => PriceUtils.format(codCharges);

  bool get hasCodSurcharge => codCharges > 0;

  /// "Delivered in 3 days" style copy is the caller's job; this is just the
  /// data. Provided because "0 days" must never render as "same day" — the
  /// field is missing on some upstream rows and coerces to 0.
  bool get hasEta => estimatedDeliveryDays > 0;

  // ---- display order ----------------------------------------------------
  //
  // Ordering only. Nothing in this file picks a courier any more: the customer
  // does, and until they do the selection is null. See the library doc.

  /// Fastest first, cheapest as the tie-break — the order the list is *shown*
  /// in.
  ///
  /// This used to be documented as "the web's rule, mirrored exactly", citing
  /// `PinCodeDeliveryService::findBestCourier`. It is a reasonable order to
  /// read a list in and it is **not** a rule the web checkout applies to
  /// anything: `findBestCourier` collapses the product page's pincode widget to
  /// one courier, while `shipping-methods.blade.php` renders every courier as a
  /// radio and preselects none. Sorting is presentation; it must never become a
  /// selection.
  ///
  /// A missing/zero `estimated_delivery_days` sinks to the bottom rather than
  /// floating to the top ([asInt] coerces the absent field to 0, which would
  /// otherwise win every comparison).
  ///
  /// The tie-break is [billedPrice], not `rate`, so the list is ordered by the
  /// same number the rows print.
  static int byBestFirst(CourierOption a, CourierOption b) {
    final daysA = a.hasEta ? a.estimatedDeliveryDays : _unknownDays;
    final daysB = b.hasEta ? b.estimatedDeliveryDays : _unknownDays;
    if (daysA != daysB) return daysA.compareTo(daysB);
    return a.billedPrice.compareTo(b.billedPrice);
  }

  /// Price-first ordering, for a "sort by cheapest" control. Ties break on
  /// speed so the order stays deterministic.
  static int byCheapest(CourierOption a, CourierOption b) {
    final byPrice = a.billedPrice.compareTo(b.billedPrice);
    if (byPrice != 0) return byPrice;
    return byBestFirst(a, b);
  }

  static const int _unknownDays = 999;

  /// A new list in [byBestFirst] order. Never sorts in place — the repository
  /// hands out lists that callers may hold.
  static List<CourierOption> sortBest(List<CourierOption> options) =>
      List<CourierOption>.of(options)..sort(byBestFirst);

  /// The cheapest option, or null for an empty list.
  ///
  /// For labelling a row ("cheapest"), never for choosing one. There is no
  /// `best()` twin: preselecting is the behaviour this round removed.
  static CourierOption? cheapest(List<CourierOption> options) {
    if (options.isEmpty) return null;
    return (List<CourierOption>.of(options)..sort(byCheapest)).first;
  }

  /// Equality is by identity + price so a rebuild with a re-fetched (but
  /// unchanged) rate list does not drop the customer's selection.
  ///
  /// [rateId] is deliberately **not** part of it. It is a quote id, so a
  /// re-fetch can hand back the same courier at the same price under a new one —
  /// and including it would make that re-fetch compare unequal, which is exactly
  /// the dropped selection this narrow equality exists to prevent. Nothing
  /// selects on `==` anyway: the radio group keys on [courierCompanyId] and
  /// `selectedShippingProvider` re-resolves the pin the same way, which is what
  /// keeps the key in play *fresh* rather than an hour old.
  ///
  /// The price term is [billedPrice], not `rate`: two rows that would be billed
  /// the same are the same offer, and a row whose `coverage_charges` moved
  /// because the basket grew is a different one even though `rate` did not
  /// budge.
  @override
  bool operator ==(Object other) =>
      other is CourierOption &&
      other.courierCompanyId == courierCompanyId &&
      other.courierName == courierName &&
      other.billedPrice == billedPrice &&
      other.estimatedDeliveryDays == estimatedDeliveryDays;

  @override
  int get hashCode => Object.hash(
        courierCompanyId,
        courierName,
        billedPrice,
        estimatedDeliveryDays,
      );

  @override
  String toString() =>
      'CourierOption($courierCompanyId, $courierName, billed $billedPrice '
      '(rate $rate), ${estimatedDeliveryDays}d, '
      'option: ${shippingOptionKey ?? "none"})';
}

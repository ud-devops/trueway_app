import '../../core/errors/api_exception.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/utils/json_utils.dart';
import '../models/shipping_quote.dart';

/// Shipping availability and live courier rates.
///
/// ## The flow this exists to serve
///
/// The web does not have a fixed shipping table. `HookServiceProvider` registers
/// `add_filter('handle_shipping_fee', ...)`, which calls
/// `ShipRocketService::getServiceabilityRates()` and returns the courier list
/// under `$result['shiprocket']`; the storefront renders those as selectable
/// shipping methods, preselecting none, and the customer's pick identifies the
/// rate entry the server prices the order from. Mobile mirrors that:
///
///   address chosen -> delivery pincode known
///     -> [serviceability] -> customer picks a [CourierOption]
///       -> that option's `shipping_option` key
///          (`"shiprocket_<rateId>"`) is what checkout sends, and the server
///          prices the order from the entry it resolves to.
///
/// **`shipping_amount` is not sent.** `API/CheckoutController.php:425` sets
/// `$useClientShippingAmount = $request->has('shipping_amount')` and `:445`
/// skips server pricing when that is true, so omitting the field is what turns
/// server pricing *on*. The app still needs the same number to quote the
/// customer before they commit, and to reconcile the total that comes back —
/// that number is [CourierOption.billedPrice], which reproduces
/// `ShipRocketService.php:1880-1886`'s `$totalCost`. It is **not**
/// `CourierOption.rate`, which omits `coverage_charges` and `other_charges`.
///
/// [checkPincode] is the *other* thing: a single pre-picked quote for one
/// product, for a product-page "delivers by" line. It is not a chooser and its
/// number is not a cart shipping fee — see [ShippingQuote].
///
/// Nothing here writes. All three routes are POST but all three are reads.
class LogisticsRepository {
  LogisticsRepository(this._api);

  final ApiClient _api;

  // -------------------------------------------------------------------------
  // check-pincode
  // -------------------------------------------------------------------------

  /// `POST /logistics/check-pincode` — "can we deliver to this pin, and roughly
  /// what does it cost for this product".
  ///
  /// `product_id` is **required**; omitting it is a 400 ("Product information
  /// is required"), not an empty quote.
  ///
  /// [quantity] is sent for forward-compatibility and is **currently ignored by
  /// the server**. `DeliveryController::checkPinCode` reads only `pin_code` and
  /// `product_id` and always quotes one unit's weight. Probed live: qty 1 and
  /// qty 5 of product 118 to 110001 both returned ₹321.51.
  ///
  /// ## Why the 422 is caught
  ///
  /// The controller maps its own success flag to the status code:
  /// `$statusCode = $success ? 200 : 422`. So "we asked Shiprocket and got
  /// nothing back for this pin" arrives as a **422**, which Dio throws on — even
  /// though it is an ordinary, expected answer that the UI should render as
  /// "we don't deliver here" rather than as an error. That branch is converted
  /// back into a [ShippingQuote] with `deliverable: false`.
  ///
  /// The one 422 that is *not* an answer is `PinCodeDeliveryService`'s outage
  /// message (no Shiprocket token, or the upstream call threw). Those rethrow,
  /// because the customer should get a retry button, not "we don't ship to your
  /// area". 400 (bad input) and 404 (no such product) always rethrow — they are
  /// caller bugs.
  Future<ShippingQuote> checkPincode({
    required String pinCode,
    required int productId,
    int quantity = 1,
  }) async {
    try {
      final res = await _api.post(
        ApiEndpoints.checkPincode,
        data: {
          'pin_code': pinCode,
          'product_id': productId,
          'quantity': quantity,
        },
      );
      return ShippingQuote.fromJson(asMap(res.data));
    } on ApiException catch (e) {
      if (e.statusCode == 422 && !_isOutage(e.serverMessage)) {
        return ShippingQuote.notDeliverable(pinCode, message: e.message);
      }
      rethrow;
    }
  }

  /// The two sentences `PinCodeDeliveryService` uses when the *service* failed
  /// rather than the pin being undeliverable. Matched on the server's raw text,
  /// not the display text, so a future presentation change cannot silently turn
  /// an outage back into a "not deliverable".
  static bool _isOutage(String? serverMessage) {
    final m = serverMessage?.toLowerCase() ?? '';
    return m.contains('temporarily unavailable');
  }

  // -------------------------------------------------------------------------
  // check-serviceability
  // -------------------------------------------------------------------------

  /// `POST /logistics/check-serviceability` — the **rate list**, i.e. the direct
  /// analogue of the web's `$result['shiprocket']`.
  ///
  /// All nine fields are required; the controller returns a 400 enumerating
  /// every one you left out (`errors: {weight: "weight is required (kg)", ...}`)
  /// before it ever calls upstream. There are no server-side defaults, so they
  /// are all required parameters here too.
  ///
  /// Units, and they are not the units the cart uses:
  ///   * [weightKg] — **kilograms**, floored at
  ///     [minServiceabilityWeightKg]; use [serviceabilityWeightKg] to convert
  ///     the cart's *grams*. `package_dimensions.weight` is already kg.
  ///   * [lengthCm] / [breadthCm] / [heightCm] — centimetres, matching
  ///     `package_dimensions`.
  ///   * [declaredValue] — rupees.
  ///
  /// ## Why nothing is rounded here
  ///
  /// The four are **not** cast alike. `DeliveryController::checkServiceability`
  /// builds its upstream params at `:261-271`:
  ///
  /// ```php
  /// 'height'         => (int)   $request->input('height'),
  /// 'breadth'        => (int)   $request->input('breadth'),
  /// 'length'         => (int)   $request->input('length'),
  /// 'weight'         => (float) $request->input('weight'),
  /// 'declared_value' => (int)   $request->input('declared_value'),
  /// ```
  ///
  /// So the three **dimensions** are truncated — `(int) 20.5` is 20 — while
  /// [weightKg] keeps its fraction and [declaredValue] is truncated to an int
  /// the web had already made one.
  ///
  /// Raw values still go on the wire for all of them, for two different
  /// reasons. For the dimensions, rounding client-side would send 21 where the
  /// web sends 20.5 and PHP then makes 20 — a different box, one step larger,
  /// on every parcel with a fractional side. `ShipRocketService` hands
  /// `PackageDimensionCalculator`'s one-decimal figures
  /// (`round($x, 1)` — `PackageDimensionCalculator.php:105-107`) straight to
  /// Shiprocket at `ShipRocketService.php:1604-1606`. Truncating the same
  /// figure the server would truncate anyway costs nothing; rounding it first
  /// changes the answer. For [weightKg] there is nothing to lose and nothing to
  /// gain by touching it: `(float)` preserves it exactly, and the web likewise
  /// sends `max($weight, 0.5)` unrounded (`:1600`) — which is what
  /// [minServiceabilityWeightKg] mirrors.
  ///
  /// The one residual gap is the three dimensions: the web can put `20.5` in
  /// front of Shiprocket and mobile cannot. [declaredValue] is **not** a gap —
  /// the web casts it itself, `(int) Arr::get($data, 'order_total')` at
  /// `ShipRocketService.php:1579`, so the endpoint's cast reproduces it. See
  /// the `followUps` note asking for the *dimension* casts to be relaxed to
  /// float; the weight and declared-value casts are correct as they stand.
  ///
  /// [cod] genuinely changes the answer here, unlike on [checkPincode]: with
  /// `cod: 1` prepaid-only couriers drop out of the list and every survivor
  /// carries a non-zero `cod_charges`. It is also the flag that decides whether
  /// that surcharge counts toward the price — the server's condition is
  /// `if ($this->isCodOrder($originalData))`, a property of the *request*, not
  /// of the row — so it is stamped onto each returned option as
  /// [CourierOption.codQuoted] and folded into [CourierOption.billedPrice]
  /// there. Quote with the payment method the customer actually chose; no
  /// caller should ever add `cod_charges` on by hand.
  ///
  /// Returns the list in [CourierOption.byBestFirst] order — the server's order
  /// is Shiprocket's opaque recommendation ranking, which is neither
  /// cheapest-first nor fastest-first, so an unsorted list reads as arbitrary.
  /// That is a **display** order and nothing more: `.first` is not a
  /// recommendation, is not preselected, and must not be treated as one.
  ///
  /// Throws when the upstream call failed. Note that branch is **HTTP 200** with
  /// `success: false` and no courier array — Shiprocket reports its own status
  /// inside the body (`data: {message: "...", status: 404}`) and the controller
  /// passes the transport 200 through, so Dio does not throw and neither does
  /// `ApiException.declaresFailure` (which only looks for `error: true`). If
  /// this check were missing, "Invalid Pickup Pincode" and "No courier service
  /// available between X and Y" would both surface as a silent empty list.
  /// Returns an empty list only for the genuinely-empty case: `success: true`
  /// with zero couriers.
  Future<List<CourierOption>> serviceability({
    required String pickupPostcode,
    required String deliveryPostcode,
    required bool cod,
    required double weightKg,
    required double lengthCm,
    required double breadthCm,
    required double heightCm,
    required double declaredValue,
    bool qcCheck = false,
  }) async {
    final res = await _api.post(
      ApiEndpoints.checkServiceability,
      data: {
        'pickup_postcode': pickupPostcode,
        'delivery_postcode': deliveryPostcode,
        'cod': cod ? 1 : 0,
        'weight': weightKg,
        'length': lengthCm,
        'breadth': breadthCm,
        'height': heightCm,
        'declared_value': declaredValue,
        'qc_check': qcCheck ? 1 : 0,
      },
    );

    final body = asMap(res.data);
    if (!asBool(body['success'])) {
      throw ApiException(
        asStringOrNull(body['message']) ?? 'Shipping rates are unavailable.',
        kind: ApiErrorKind.businessRule,
        statusCode: res.statusCode,
        serverMessage: asStringOrNull(body['message']),
        developerDetail:
            'POST ${ApiEndpoints.checkServiceability} -> HTTP ${res.statusCode} '
            'with success:false (upstream failure passed through as 200)',
      );
    }

    // `cod` is threaded into the parse, not just the request: it is what makes
    // each row's [CourierOption.billedPrice] include `cod_charges`, matching
    // `ShipRocketService.php:1884-1886`.
    return CourierOption.sortBest(CourierOption.listFrom(body, cod: cod));
  }

  // -------------------------------------------------------------------------
  // batch-check-pincodes
  // -------------------------------------------------------------------------

  /// `POST /logistics/batch-check-pincodes` — one [ShippingQuote] per pin, for
  /// annotating a list of saved addresses in a single round trip.
  ///
  /// Returns a map keyed by the pin code **exactly as the server echoed it**,
  /// which is the string form of what was sent. Undeliverable pins are present
  /// in the map with `deliverable: false` rather than absent, and the whole
  /// call is a 200 even when every pin fails. An empty [pinCodes] would 400
  /// ("Pin codes array is required"), so it short-circuits to `{}` instead.
  ///
  /// ⚠ This route does **not** take a product. Despite the sibling route's
  /// signature, `batchCheckPinCodes` reads only `pin_codes`, `weight`,
  /// `length`, `breadth`, `height` and `cod_enabled` — anything else is
  /// discarded. Leaving the dimensions at their defaults quotes a 0.5 kg
  /// 10×10×10 parcel, which is why an unparameterised batch call and
  /// [checkPincode] disagree for the same pin (110001: ₹77.36 batch vs ₹321.51
  /// single, probed live). Pass the real package to get comparable numbers.
  Future<Map<String, ShippingQuote>> batchCheckPincodes({
    required List<String> pinCodes,
    double weightKg = 0.5,
    double lengthCm = 10,
    double breadthCm = 10,
    double heightCm = 10,
    bool cod = false,
  }) async {
    final pins = pinCodes
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toSet()
        .toList();
    if (pins.isEmpty) return const {};

    final res = await _api.post(
      ApiEndpoints.batchCheckPincodes,
      data: {
        'pin_codes': pins,
        'weight': weightKg,
        'length': lengthCm.round(),
        'breadth': breadthCm.round(),
        'height': heightCm.round(),
        'cod_enabled': cod,
      },
    );

    final results = asMap(asMap(res.data)['results']);
    return {
      for (final entry in results.entries)
        if (entry.value is Map)
          entry.key: ShippingQuote.fromJson(asMap(entry.value)),
    };
  }

  // -------------------------------------------------------------------------
  // helpers
  // -------------------------------------------------------------------------

  /// Grams -> kilograms. No floor: the two routes floor at *different* values
  /// and picking one here is how the app came to quote 0.1 kg parcels the web
  /// quotes at 0.5 kg.
  static double kgFromGrams(num grams) => grams <= 0 ? 0 : grams / 1000;

  /// The parcel weight `/logistics/check-serviceability` should be asked for,
  /// given a cart weight in **grams**.
  ///
  /// This is the web's line, verbatim:
  ///
  /// ```php
  /// $weight = $rawWeight / 1000;        // ShipRocketService, grams -> kg
  /// 'weight' => max($weight, 0.5),      // getServiceabilityRates()
  /// ```
  ///
  /// Convert **once**. The cart's `total_weight` is grams while its sibling
  /// `package_dimensions.weight` is already kilograms, and running the kg
  /// figure through here would quote a 10.2 kg order as 10 200 kg.
  static double serviceabilityWeightKg(num grams) =>
      atLeastServiceabilityWeight(kgFromGrams(grams));

  /// The same floor, for a weight that is *already* kilograms — the
  /// `package_dimensions.weight` path, which `PackageDimensionCalculator`
  /// itself clamps with `max($totalWeightKg, 0.5)`.
  static double atLeastServiceabilityWeight(double kg) =>
      kg < minServiceabilityWeightKg ? minServiceabilityWeightKg : kg;

  /// `max($weight, 0.5)` in `ShipRocketService::getServiceabilityRates()`.
  ///
  /// Materially different from [minPinCodeWeightKg], which is what this app
  /// used to apply to serviceability calls: probed live on 2026-08-03 to
  /// 560001, a 10×10×10 parcel came back at ₹73.16 / ₹70.80 on India Post at
  /// 0.1 kg and ₹96.76 / ₹94.40 at 0.5 kg. Every light basket was under-quoted
  /// by ₹23.60 against the website.
  static const double minServiceabilityWeightKg = 0.5;

  /// `DeliveryController::checkPinCode`'s clamp — `if ($weightInKg < 0.1)`.
  ///
  /// Belongs to [checkPincode] **only**. It is not the serviceability floor and
  /// must never be used for one.
  static const double minPinCodeWeightKg = 0.1;
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/errors/api_exception.dart';
import '../../core/validation/address_rules.dart';
import '../../data/models/server_cart.dart';
import '../../data/models/shipping_quote.dart';
import '../../data/repositories/logistics_repository.dart';
import 'core_providers.dart';

/// Live courier rates for a delivery pincode.
///
/// This mirrors what the website does. `HookServiceProvider` registers a
/// `handle_shipping_fee` filter that calls `ShipRocketService::
/// getServiceabilityRates()` and hands the resulting courier list to checkout as
/// selectable shipping options, **preselecting none**; the one the customer
/// picks identifies the rate entry the server prices the order from. The mobile
/// app has to reach the same numbers, so it reads the same endpoint —
/// `POST /logistics/check-serviceability` — rather than inventing a flat fee.
///
/// ## What the money is, and is not
///
/// The app does **not** send `shipping_amount`; the server prices the order from
/// the `shipping_option` key
/// (`API/CheckoutController.php:425` + `:445` — omitting the field is what
/// activates server pricing). So the figure here is what the customer is
/// *quoted* and what the returned total is *reconciled against*, not a number
/// the server is told to use.
///
/// Nothing here computes money either. [CourierOption.billedPrice] is the
/// server's own sum, term for term
/// (`freight_charge + coverage_charges + other_charges`, plus `cod_charges` on a
/// COD quote — `ShipRocketService.php:1880-1886`), and is only ever formatted.
/// It is **not** `CourierOption.rate`: `rate` omits coverage and other charges,
/// which under-quoted every basket past the insurance threshold by exactly the
/// coverage step (₹49.00 on the live 311001 -> 382415 lane at declared_value
/// 2500).
///
/// ## Nothing is preselected
///
/// [selectedShippingProvider] is null until the customer taps a courier, and
/// every money provider below is null with it. Null means "no delivery option
/// chosen", which is a different thing from free delivery and renders
/// differently; none of them may be papered over with a 0.

// ---------------------------------------------------------------------------
// Query key
// ---------------------------------------------------------------------------

/// Last-resort warehouse postcode, used only when the basket's own lines name no
/// store.
///
/// ## A fallback, not the usual answer
///
/// The usual answer is read from the cart. Every line of a live cart response
/// carries the marketplace store it ships from:
///
/// ```json
/// cart_items: { "<rowId>": { "cart_options": { …,
///   "store": {"id":10,"slug":"trueway-farms-1","name":"Trueway Farms",
///             "zip_code":"311001"} } } }
/// ```
///
/// — verified live 2026-08-04 on both `POST /ecommerce/cart` and
/// `GET /ecommerce/cart/{id}`. That is exactly rung 2 of the server's own
/// `ShipRocketService::getPickupPostcode()` chain (`:1715`), so
/// [pickupPinCodeFromCart] reads it and this constant only stands in when the
/// cart is empty or its lines carry no store. Reading it rather than hardcoding
/// it is what makes the app follow a store move instead of drifting silently:
/// the day the warehouse changes postcode, or a second store joins the
/// marketplace, the quote follows the cart and this constant does not have to be
/// found and edited.
///
/// It stays **311001** — the same value the store row holds today — so the
/// fallback and the read agree on the current catalogue and the change can be
/// verified to quote identically. See "Getting it wrong is expensive" below for
/// why the fallback is not simply dropped.
///
/// ## This is not the same setting `check-pincode` uses
///
/// The app used to send `110001` here, on the strength of a probe that
/// reproduced `POST /logistics/check-pincode` to the paisa. That probe was
/// sound and its conclusion was wrong: `check-pincode` is served by
/// `PinCodeDeliveryService`, which reads
/// `setting('logistics_pickup_postcode', '110001')` — Delhi, a *default in the
/// code*. The **web checkout** never touches that setting. Its
/// `ShipRocketService::getPickupPostcode()` walks a different chain entirely:
///
///   1. `origin.zip_code` — `get_ecommerce_setting('store_zip_code')`
///   2. the marketplace store on the cart's products — `stores.zip_code`
///   3. `get_ecommerce_setting('shiprocket_default_pickup_postcode')`
///
/// So `110001` was never on the web's list. Rung 2 *is* readable from the
/// mobile API — off the cart itself, as above — which is what
/// [pickupPinCodeFromCart] now does, called by `checkoutParcelProvider` and
/// carried into every quote by `CheckoutParcel.toQuery`. 311001 is corroborated
/// by the storefront's own contact page ("Kamla Arcade, Ajmer Road,
/// Bhilwara-311001, Rajasthan") and
/// by back-solving 90 real orders: 5 exact matches, 9 more explained by a
/// uniform rate-card revision, and Gujarat pincodes decisively excluded (0/62 —
/// they quote 45-70% low).
///
/// ## Getting it wrong is expensive
///
/// Probed live on 2026-08-03, 2×SKU 118 (10.2 kg, 20×7×49) to 560001:
///
/// ```
/// pickup 110001 -> India Post Speed Post Prepaid ₹1288.56, _2.0 ₹1286.20
/// pickup 311001 -> India Post Speed Post Prepaid ₹1040.76, _2.0 ₹1038.40
/// ```
///
/// ₹247.80 per order, in the customer's disfavour, on every quote the app has
/// ever shown. Shiprocket does substitute the account's own registered pickup
/// location when a *shipment* is created, but it plainly does not do so when
/// *rating* — so a wrong postcode here misquotes the customer even though the
/// parcel ships correctly.
///
/// That is why the fallback is kept rather than made nullable: an empty cart, or
/// a catalogue line the marketplace plugin has no store row for, must still
/// produce a quote from *somewhere plausible*, and 311001 is the only value with
/// evidence behind it. Rungs 1 and 3 of the server chain are ecommerce settings
/// with no public route, so they stay unreachable from here — see `followUps`.
const String kDefaultPickupPinCode = '311001';

/// Where this basket ships **from**: the store on its own lines, or
/// [kDefaultPickupPinCode] when there is none.
///
/// Rung 2 of `ShipRocketService::getPickupPostcode()` (`:1715-1745`) reached
/// from the client, via `cart_items[*].cart_options.store.zip_code` — see
/// [ServerCartItem.storeZipCode] for the live capture. The server walks its own
/// chain independently when it re-quotes at checkout; matching rung 2 is how the
/// app's quote and the server's stay on the same lane without the app being told
/// the answer.
///
/// Two guards, both of which the fallback exists to cover:
///
///   * **Validity.** Only a value that passes the same six-digit rule the rest
///     of the app applies ([CheckoutAddressRules.zipPattern]) is used. Shiprocket
///     answers a malformed pickup postcode with "Invalid Pickup Pincode" inside
///     an HTTP 200, which the repository raises as a business-rule error — that
///     would blame the customer's address for the shop's bad data, so a
///     nonsense store zip is ignored rather than sent.
///   * **Agreement.** If the basket somehow spans two stores with different
///     postcodes, there is no single lane to quote and no way to pick one that
///     is not a guess, so the fallback stands in. The server has the same
///     problem and resolves it by taking the first store it finds; guessing the
///     same way here would look right and be right only by luck. Single-store
///     catalogue today, so this branch is unreached — it exists so that adding a
///     second store degrades to a documented constant rather than to a silently
///     wrong lane.
///
/// The first line's store wins when every line agrees, which is the live case:
/// all lines carry `{id: 10, slug: "trueway-farms-1", zip_code: "311001"}`.
String pickupPinCodeFromCart(ServerCart cart) {
  String? found;
  for (final item in cart.items) {
    final zip = item.storeZipCode?.trim();
    if (zip == null || zip.isEmpty) continue;
    if (!CheckoutAddressRules.zipPattern.hasMatch(zip)) continue;
    if (found != null && found != zip) return kDefaultPickupPinCode;
    found ??= zip;
  }
  return found ?? kDefaultPickupPinCode;
}

/// `PackageDimensionCalculator`'s own `defaults()` — the box the web quotes
/// when not one item in the basket carries a dimension.
///
/// ```php
/// protected const DEFAULT_LENGTH  = 10;
/// protected const DEFAULT_BREADTH = 15;
/// protected const DEFAULT_HEIGHT  = 20;
/// protected const DEFAULT_WEIGHT_KG = 0.5;
/// ```
///
/// Not a cube. The app used to send 10×10×10 — `PinCodeDeliveryService`'s
/// default, which is a different service — for *every* basket, dimensioned or
/// not. See [kPackagingBufferCm] for what that cost.
const double kDefaultParcelLengthCm = 10;
const double kDefaultParcelBreadthCm = 15;
const double kDefaultParcelHeightCm = 20;

/// `PackageDimensionCalculator::SAFETY_BUFFER_CM` — 1 cm of packaging added to
/// each of the three calculated sides.
const double kPackagingBufferCm = 1;

/// Everything `/logistics/check-serviceability` needs, in the units it wants.
///
/// Serviceability is priced per *shipment*, so the quote depends on the whole
/// parcel and not just the pincode — change the cart and the rates change. That
/// is why the weight and dimensions are part of the key: a provider keyed on the
/// pincode alone would serve a stale quote for a heavier basket.
///
/// Units are the ones Shiprocket documents and the backend forwards unchanged:
/// **weight in kilograms**, **dimensions in centimetres**. The cart reports
/// `total_weight` in *grams*, so whoever builds the query converts — on the
/// live path that is `checkoutParcelProvider`, via
/// [LogisticsRepository.serviceabilityWeightKg]. Getting it wrong quotes a
/// 15 kg order at the 15 gram rate.
class ShippingQuery {
  const ShippingQuery({
    required this.pinCode,
    required this.weightKg,
    required this.lengthCm,
    required this.breadthCm,
    required this.heightCm,
    required this.declaredValue,
    this.cod = false,
    this.pickupPinCode = kDefaultPickupPinCode,
  });

  /// Six digits, first digit non-zero — the rule
  /// `PinCodeDeliveryService::validatePinCode()` applies.
  final String pinCode;

  /// Where the parcel ships from. See [kDefaultPickupPinCode].
  final String pickupPinCode;

  final double weightKg;
  final double lengthCm;
  final double breadthCm;
  final double heightCm;

  /// Order value declared to the courier. Insurance and some COD rules key off
  /// it, so it is part of the quote and therefore part of the cache key.
  final double declaredValue;

  /// Whether the customer intends to pay on delivery.
  ///
  /// Not cosmetic: the request sends `cod: 1`, which drops prepaid-only couriers
  /// from the list and folds each survivor's `cod_charges` into its `rate`. A
  /// COD order quoted with `cod: 0` under-bills the shipping line.
  final bool cod;

  /// True when [pinCode] could be a real Indian pincode.
  ///
  /// Checked before spending a request: the endpoint answers a malformed pin
  /// with `400 Please enter a valid 6-digit pin code`, which is a worse thing to
  /// show a customer mid-typing than simply not asking yet.
  ///
  /// The pattern is [CheckoutAddressRules.zipPattern], read from there rather
  /// than restated — the address picker gates on the same constant, so "worth
  /// quoting" and "deliverable" cannot drift apart.
  bool get hasValidPinCode =>
      CheckoutAddressRules.zipPattern.hasMatch(pinCode);

  /// Builds the query from a server cart.
  ///
  /// ## Not the live path, and not a drop-in for it
  ///
  /// **Nothing in `lib/` calls this.** The query the app actually quotes from is
  /// built by `checkoutParcelProvider` and handed out by
  /// `CheckoutParcel.toQuery`. That is not a wrong-constructor bug: the pickup
  /// postcode this factory resolves comes from [pickupPinCodeFromCart], which
  /// is a plain top-level function that `checkoutParcelProvider` calls directly,
  /// so the live path reads the basket's own store exactly as this one does.
  ///
  /// The two do **not** agree on weight, and this one is the wrong of the pair.
  /// It prefers `package_dimensions.weight`, falling back to `total_weight`;
  /// the live path uses `total_weight` only. The web's serviceability call
  /// takes `$rawWeight = Arr::get($data, 'weight', 1000)` in grams, divides by
  /// 1000 and sends `max($weight, 0.5)` (`ShipRocketService.php:1566-1567`,
  /// `:1600`) — i.e. the grams figure, which is `total_weight`. It reads
  /// `$packageDims` for the three *dimensions* only (`:1587-1589`);
  /// `$packageDims['weight']` feeds a different method, the create-shipment
  /// path at `:512`. The two figures happen to coincide on every live cart
  /// captured so far (10200 g / 10.2 kg), so the divergence is latent — which
  /// is exactly why it must not be woken up by wiring this factory in. See
  /// `followUps`.
  ///
  /// It survives because `test/presentation/shipping_selector_test.dart` covers
  /// the gram conversion, the unmeasured-cart floor and the pickup-postcode
  /// rules through it (`:195`, `:218`, `:225`, `:290`, `:304`, `:323`, `:359`).
  ///
  /// ## What it gets right
  ///
  /// `package_dimensions` is produced by the very `PackageDimensionCalculator`
  /// the web checkout calls, box catalogue and all, so taking its three sides
  /// verbatim matches what `ShipRocketService` sends. Its `weight` is
  /// **kilograms** while the sibling `total_weight` is **grams** — hence two
  /// different helpers below. Running one through the other's converter turns a
  /// 10.2 kg order into 10 200 kg.
  ///
  /// `total_length` / `total_wide` / `total_height` are deliberately **not**
  /// used as a fallback: they are `sum(side × qty)` across the basket (38/12/48
  /// for the two-bag cart whose packed parcel is 20×7×49), which is not a box
  /// anyone would ship. When the block is absent the calculator's own defaults
  /// stand in, which is what the web does for a dimensionless basket.
  ///
  /// [declaredValue] is `order_total`, matching
  /// `(int) Arr::get($data, 'order_total')` (`ShipRocketService.php:1579`).
  ///
  /// [pickupPinCode] defaults to the basket's own store — see
  /// [pickupPinCodeFromCart]. Pass it explicitly only to override that.
  factory ShippingQuery.fromCart(
    ServerCart cart, {
    required String pinCode,
    bool cod = false,
    String? pickupPinCode,
  }) {
    final pkg = cart.packageDimensions;
    double side(double? packed, double fallback) =>
        (packed != null && packed > 0) ? packed : fallback;

    final packedWeight = pkg?.weight ?? 0;

    return ShippingQuery(
      pinCode: pinCode,
      // `total_weight` FIRST, and `package_dimensions.weight` only as a
      // fallback. The two answer different questions:
      //
      //   total_weight              — the GOODS, summed in grams
      //   package_dimensions.weight — the PACKED CARTON, in kilograms
      //
      // The web quotes on the goods weight: `getShippingData()` puts
      // `total_weight` in the `weight` parameter it sends Shiprocket, and
      // `package_dimensions.weight` exists to drive the box lookup. This
      // constructor had the precedence the other way round.
      //
      // It costs nothing today, which is exactly why it is worth naming: no
      // `shipping_boxes` row is configured, so `PackageDimensionCalculator`
      // just re-sums the goods and both fields report the same number (verified
      // live: `total_weight: 10200` alongside `package_dimensions.weight: 10.2`,
      // `box_id: null`). The day somebody adds a box in admin, the packed weight
      // starts including the carton and this quote silently drifts above the
      // website's for the same basket.
      //
      // `checkoutParcelProvider` — the path the app actually checks out through
      // — already gets this right. This constructor is reachable only from
      // tests, so the fix is a trap removed rather than a bug repaired.
      weightKg: cart.totalWeight > 0
          ? LogisticsRepository.serviceabilityWeightKg(cart.totalWeight)
          : LogisticsRepository.atLeastServiceabilityWeight(packedWeight),
      lengthCm: side(pkg?.length, kDefaultParcelLengthCm),
      breadthCm: side(pkg?.breadth, kDefaultParcelBreadthCm),
      heightCm: side(pkg?.height, kDefaultParcelHeightCm),
      declaredValue: cart.orderTotal.amount,
      cod: cod,
      pickupPinCode: pickupPinCode ?? pickupPinCodeFromCart(cart),
    );
  }

  ShippingQuery copyWith({String? pinCode, bool? cod}) => ShippingQuery(
        pinCode: pinCode ?? this.pinCode,
        weightKg: weightKg,
        lengthCm: lengthCm,
        breadthCm: breadthCm,
        heightCm: heightCm,
        declaredValue: declaredValue,
        cod: cod ?? this.cod,
        pickupPinCode: pickupPinCode,
      );

  @override
  bool operator ==(Object other) =>
      other is ShippingQuery &&
      other.pinCode == pinCode &&
      other.pickupPinCode == pickupPinCode &&
      other.weightKg == weightKg &&
      other.lengthCm == lengthCm &&
      other.breadthCm == breadthCm &&
      other.heightCm == heightCm &&
      other.declaredValue == declaredValue &&
      other.cod == cod;

  @override
  int get hashCode => Object.hash(
        pinCode,
        pickupPinCode,
        weightKg,
        lengthCm,
        breadthCm,
        heightCm,
        declaredValue,
        cod,
      );

  @override
  String toString() => 'ShippingQuery($pinCode, ${weightKg}kg, cod: $cod)';
}

// ---------------------------------------------------------------------------
// Presentation helpers on the repository model
// ---------------------------------------------------------------------------

/// How a courier's delivery estimate reads on screen.
///
/// An extension rather than a wrapper class so the selector, the bill line and
/// checkout all share one rendering of the estimate, with no parallel view model
/// to fall out of step with the rows themselves.
extension CourierEta on CourierOption {
  /// `Delivery by 04 Aug` — the line customers actually read.
  ///
  /// Prefers the date over the day count because "by Tuesday the 4th" is a
  /// promise and "in 3 days" is arithmetic the customer has to do. Falls back to
  /// the count when upstream sent an empty `etd`, which several couriers do, and
  /// to null when it sent neither — [CourierOption.hasEta] guards the `0` that
  /// would otherwise render as "same day".
  String? get etaLabel {
    final date = etdDate;
    if (date != null) return 'Delivery by ${DateFormat('dd MMM').format(date)}';
    if (!hasEta) return null;
    return estimatedDeliveryDays == 1
        ? 'Delivery in 1 day'
        : 'Delivery in $estimatedDeliveryDays days';
  }
}

/// The answer to one serviceability call.
///
/// [deliverable] is a field and not `options.isNotEmpty` by accident: the
/// endpoint has two distinct ways of saying no — a 200 whose upstream body is
/// `{"message": "No courier service available between 382415 and 999999",
/// "status": 404}`, and a 200 with an empty courier array. Both mean the order
/// cannot ship there, and both have to reach the customer as a refusal rather
/// than as an empty list.
class ShippingRates {
  const ShippingRates({
    required this.options,
    required this.deliverable,
    this.message,
  });

  /// In [CourierOption.byBestFirst] order — upstream returns its own
  /// recommendation ranking, which is neither by price nor by speed.
  ///
  /// Order is presentation. `options.first` is not a recommendation and nothing
  /// may treat it as one; see [selectedShippingProvider].
  final List<CourierOption> options;

  /// False when nothing can carry this parcel to this pincode.
  final bool deliverable;

  /// The server's own explanation, shown verbatim when [deliverable] is false.
  final String? message;

  /// Nothing available — the shape both refusal forms collapse to.
  factory ShippingRates.unavailable([String? message]) =>
      ShippingRates(options: const [], deliverable: false, message: message);

  /// Wraps the repository's courier list.
  ///
  /// An empty list is a refusal: `PinCodeDeliveryService` treats
  /// `empty($availableCouriers)` as "Delivery not available for this pin code",
  /// so the app must not render it as a blank but otherwise fine selector.
  factory ShippingRates.fromCouriers(List<CourierOption> couriers) {
    if (couriers.isEmpty) {
      return ShippingRates.unavailable(
        'No courier delivers to this pincode right now.',
      );
    }
    return ShippingRates(
      options: CourierOption.sortBest(couriers),
      deliverable: true,
    );
  }

  bool get isEmpty => options.isEmpty;

  /// The one row on offer, or null when there are none or several.
  ///
  /// ## No `lib/` caller, and it must stay that way
  ///
  /// **Nothing in `lib/` calls this, by design, and adding a caller is almost
  /// certainly a bug.** It is an arity report — "is there exactly one option?"
  /// — and it is one keystroke away from being an auto-select in a module whose
  /// entire point is that nothing is auto-selected. `CourierOption.best` and
  /// `ShippingRates.best` were deleted for being exactly that, after
  /// preselection put Blue Dart Air at ₹1,284.15 in a bill where the customer
  /// would have picked Xpressbees Surface at ₹324.30. `options.length == 1`
  /// does not make preselection safe: even a single option has to be tapped,
  /// because the tap is the customer accepting a delivery charge, and a bill
  /// that completes itself is a bill nobody agreed to.
  ///
  /// It survives only as the anti-preselection guard's own witness:
  /// `test/presentation/shipping_selector_test.dart` (`:423-424`, `:434`)
  /// asserts it stays null for a six-courier list and for a refusal, and
  /// returns the row only in the genuine arity-of-one case. Deleting it means
  /// deleting those expectations too, in a file this change does not own — see
  /// `followUps`. If it is ever wired into a widget or a provider instead,
  /// delete it rather than reviewing the caller.
  CourierOption? get only => options.length == 1 ? options.first : null;
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// The seam between this slice and the logistics repository.
///
/// Everything below depends on this function rather than on
/// [LogisticsRepository] directly, which keeps the courier-list plumbing to a
/// single override point: widget tests replace it with a canned list, so no test
/// can reach the network even by accident.
typedef ShippingRatesFetcher = Future<ShippingRates> Function(ShippingQuery);

// `logisticsRepositoryProvider` now lives in `core_providers.dart` with the
// other repositories — it was declared here only because that file had no entry
// for it, and two declarations would have given the app two instances.

final shippingRatesFetcherProvider = Provider<ShippingRatesFetcher>((ref) {
  final repo = ref.watch(logisticsRepositoryProvider);
  return (query) async {
    try {
      final couriers = await repo.serviceability(
        pickupPostcode: query.pickupPinCode,
        deliveryPostcode: query.pinCode,
        cod: query.cod,
        weightKg: query.weightKg,
        lengthCm: query.lengthCm,
        breadthCm: query.breadthCm,
        heightCm: query.heightCm,
        declaredValue: query.declaredValue,
      );
      return ShippingRates.fromCouriers(couriers);
    } on ApiException catch (e) {
      // "No courier service available between 382415 and 999999" is not a
      // failure — it is the answer, and the repository can only raise it as one
      // because the upstream reports it inside an HTTP 200 body. Turning it back
      // into data is what lets the selector say "we can't deliver here" instead
      // of offering a pointless retry.
      //
      // Its sibling on the same error kind, "Invalid Pickup Pincode", is a
      // misconfiguration on our side and deliberately still throws: the customer
      // must not be told their address is the problem.
      if (_isUnserviceable(e)) return ShippingRates.unavailable(e.message);
      rethrow;
    }
  };
});

bool _isUnserviceable(ApiException e) =>
    e.kind == ApiErrorKind.businessRule &&
    e.message.toLowerCase().contains('no courier service available');

/// Courier rates for one parcel-and-pincode combination.
///
/// `autoDispose` because a checkout session touches a handful of pincodes at
/// most and a quote goes stale the moment the cart changes; `family` because the
/// quote *is* a function of the query, so two addresses must never share one.
final courierOptionsProvider =
    FutureProvider.autoDispose.family<ShippingRates, ShippingQuery>(
  (ref, query) => ref.watch(shippingRatesFetcherProvider)(query),
);

/// A courier the customer picked by hand, and what they picked it for.
///
/// The query is stored alongside so a stale choice cannot survive an address or
/// basket change: `Delhivery Surface at ₹139.36` was a quote for *that* parcel
/// to *that* pincode, and silently carrying it to the next one bills the wrong
/// amount.
class ShippingChoice {
  const ShippingChoice({required this.query, required this.option});

  final ShippingQuery query;
  final CourierOption option;

  /// The `shipping_option` value this choice would be sent to checkout as, e.g.
  /// `"shiprocket_1016322646"`. Null when the picked row carried no rate id.
  ///
  /// Convenience only — **prefer [shippingOptionKeyProvider]**, which resolves
  /// the pin against the rate list that is live now. This getter reads the
  /// stored snapshot, whose rate id belongs to the quote the customer tapped and
  /// may be stale. See the note on [selectedShippingProvider].
  String? get shippingOptionKey => option.shippingOptionKey;
}

class ShippingChoiceNotifier extends StateNotifier<ShippingChoice?> {
  ShippingChoiceNotifier() : super(null);

  void select(ShippingQuery query, CourierOption option) =>
      state = ShippingChoice(query: query, option: option);

  /// Called once the order is placed, so the next one starts clean.
  void clear() => state = null;
}

final shippingChoiceProvider =
    StateNotifierProvider<ShippingChoiceNotifier, ShippingChoice?>(
  (ref) => ShippingChoiceNotifier(),
);

/// The courier in effect for [query] — **the customer's own pick, or null.**
///
/// ## Nothing is preselected, ever
///
/// This provider used to fall back to `rates.best` when the customer had not
/// chosen, which meant a courier was always "in effect" and the bill always
/// completed itself. That default was fastest-first, cheapest only as a
/// tie-break, so on a live quote it put Blue Dart Air at ₹1,284.15 in the bill
/// when Xpressbees Surface was ₹324.30 two days later — ₹960 the customer never
/// agreed to. The rule it implemented, `PinCodeDeliveryService::findBestCourier`
/// (`:157-177`), belongs to the product page's pincode widget and was never what
/// checkout did: the web renders `shipping-methods.blade.php`, a radio per
/// courier, with none selected.
///
/// So this is null until a tap lands, and stays null for a query the customer
/// has not answered. Callers must render "choose a delivery option", not a
/// number and not a zero — see [shippingChargeProvider].
///
/// ## The pin is a courier, not a price
///
/// [ShippingChoice] stores the [CourierOption] *object* the customer tapped, and
/// that object is a snapshot: it carries the price Shiprocket quoted at that
/// moment. `courierOptionsProvider` is `autoDispose`, so leaving the cart and
/// coming back re-fetches — and Shiprocket does re-price. Handing the stored
/// snapshot straight back would print the price the customer saw an hour ago on
/// both the cart and checkout while the courier now charges something else, and
/// would keep quoting a courier that has since dropped out of the list entirely.
///
/// So the pin is resolved by [CourierOption.courierCompanyId] against the list
/// that is live *now*: the customer's courier at today's price, or null when
/// that courier no longer serves this parcel — which reopens the question
/// instead of quietly substituting an answer.
final selectedShippingProvider =
    Provider.autoDispose.family<CourierOption?, ShippingQuery>((ref, query) {
  final choice = ref.watch(shippingChoiceProvider);
  // A choice made for a different parcel or a different destination is not an
  // answer to this question.
  if (choice == null || choice.query != query) return null;

  final rates = ref.watch(courierOptionsProvider(query)).valueOrNull;
  // No list at all yet — loading, failed, or unserviceable. There is nothing to
  // re-resolve against, and a price from a previous visit is exactly what must
  // not be shown while the card above the bill says "Checking delivery…".
  if (rates == null) return null;

  for (final option in rates.options) {
    if (option.courierCompanyId == choice.option.courierCompanyId) return option;
  }
  return null;
});

/// **The shipping charge for the bill: [CourierOption.billedPrice] of the
/// courier the customer picked.**
///
/// Null means *no delivery option has been chosen*, and that is a different
/// thing from free delivery. It covers every case where there is no number to
/// print — nothing picked yet, quote still loading, quote failed, pincode
/// unserviceable, or the picked courier no longer on offer — and none of them
/// may be rendered as ₹0 or "FREE". A bill with a null here shows the goods
/// total and asks for a delivery option; it must not show a "To pay".
///
/// The figure is the sum the server bills, not upstream's `rate`:
/// `freight_charge + coverage_charges + other_charges`, plus `cod_charges` when
/// [ShippingQuery.cod]. See [CourierOption.billedPrice].
final shippingChargeProvider =
    Provider.autoDispose.family<double?, ShippingQuery>(
  (ref, query) => ref.watch(selectedShippingProvider(query))?.billedPrice,
);

/// The courier's display name, e.g. `"Xpressbees Surface 5kg"` — what the order
/// ends up recording alongside the shipment.
///
/// Null on exactly the same conditions as [shippingChargeProvider], the first of
/// which is "the customer has not chosen". Not the value sent as
/// `shipping_method` on the wire — that is the literal `"shiprocket"`; see
/// [shippingOptionKeyProvider].
final shippingMethodProvider =
    Provider.autoDispose.family<String?, ShippingQuery>(
  (ref, query) => ref.watch(selectedShippingProvider(query))?.courierName,
);

/// **The value checkout sends as `shipping_option`** — e.g.
/// `"shiprocket_1016322646"`.
///
/// This is the provider the checkout POST reads. Null **until the customer picks
/// a courier**, then also while the quote is loading, when the pincode is not
/// serviceable, and when the selected row carried no rate id — all of them mean
/// "there is no key to send", and none may be papered over with a guess. A null
/// here is what keeps the Place order button disabled.
///
/// ## What it pairs with
///
/// The request the web checkout makes, and the one this app now mirrors:
///
/// ```json
/// { "shipping_method": "shiprocket",
///   "shipping_option":  "shiprocket_<rateId>" }
/// ```
///
/// Note the pair is *group key* + *member key*. `shipping_method` is the
/// literal `"shiprocket"` — the group `HookServiceProvider.php:59` registers as
/// `$result['shiprocket']` and `HandleShippingFeeService.php:58` matches with
/// `Arr::get($result, $method)` — **not** the courier's display name. That name
/// is [shippingMethodProvider], which the server derives for itself from the
/// resolved entry; sending it as `shipping_method` would miss the group lookup
/// entirely. The two providers are not alternatives to each other.
///
/// `shipping_amount` is **not** sent — verified in `checkout_repository.dart`,
/// which has no branch that adds the field. The server prices the order from
/// the entry this key resolves to (`'price' => $totalCost`,
/// `ShipRocketService.php:1894`, read back by
/// `API/CheckoutController.php:446`), so the app's own figure is not the one
/// billed.
///
/// ## Why the key is built from the rate id
///
/// `ShipRocketService.php:1889` keys the table `'shiprocket_' . $rateId`, where
/// `:1870` sets `$rateId = Arr::get($courier, 'id')` — the raw Shiprocket rate
/// id, not `courier_company_id`. See [CourierOption.shippingOptionKey], which
/// carries the full derivation and the live capture behind it.
///
/// ## The key is resolved live, not remembered
///
/// It comes off [selectedShippingProvider], so it is the rate id from the list
/// fetched for *this* query, not the one attached to the snapshot the customer
/// tapped an hour ago. A rate id identifies a quote, so a re-fetch can reissue
/// the same courier under a new one — pinning by [CourierOption.courierCompanyId]
/// and re-reading the key is what keeps the two in step.
///
/// ## It can still miss server-side — reconcile
///
/// The server re-quotes Shiprocket with `get_ecommerce_setting('store_zip_code')`
/// as the pickup postcode, not this app's `pickupPinCode`, so its table can be
/// built from a different quote and this key may not be in it. A miss is silent:
/// the resolved method is null and `Arr::get($shippingMethod, 'price', 0)` bills
/// **0.00**. So a sent key is not a guarantee — after `placeOrder` returns, and
/// before the Razorpay sheet opens, the server's `data.total_amount` must be
/// compared with the total the customer was shown, and any difference (over- or
/// under-charge) surfaced for them to decline.
final shippingOptionKeyProvider =
    Provider.autoDispose.family<String?, ShippingQuery>(
  (ref, query) => ref.watch(selectedShippingProvider(query))?.shippingOptionKey,
);

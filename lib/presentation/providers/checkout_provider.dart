import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/errors/api_exception.dart';
import '../../core/errors/error_presenter.dart';
import '../../core/payments/payment_gateway.dart';
import '../../core/pricing/order_pricing.dart';
import '../../core/utils/json_utils.dart';
import '../../core/utils/price_utils.dart';
import '../../core/validation/address_rules.dart';
import '../../data/models/placed_order.dart';
import '../../data/models/tax_information.dart';
import '../../data/repositories/checkout_repository.dart';
import '../../data/repositories/logistics_repository.dart';
import 'core_providers.dart';
import 'server_cart_provider.dart';
import 'shipping_provider.dart';

/// Checkout-scoped input that is the customer's, not the server's.
///
/// The applied coupon used to live here too, alongside a hardcoded `kCoupons`
/// table the app scored itself. It does not any more: a coupon is applied with
/// `POST /ecommerce/coupon/apply` and read back from the cart's
/// `applied_coupon_code`, so the discount, its validity and whether it grants
/// free shipping are all the server's answers. What remains is the tax-invoice
/// block, which no endpoint owns until the order is placed.
class CheckoutState {
  const CheckoutState({this.taxInformation});

  /// The GST invoice details, or null when the customer wants none.
  ///
  /// Only ever a *complete* block. The cart's form holds the half-typed one and
  /// hands this over only once [TaxInformation.violations] is empty, so anything
  /// stored here is safe to attach to an order — there is no partial tax block,
  /// every field is `required_if:with_tax_information,1`.
  final TaxInformation? taxInformation;

  /// The GSTIN alone, for a row that shows the code rather than the block.
  String? get gstin => taxInformation?.companyTaxCode;

  bool get hasTaxInformation => taxInformation != null;

  CheckoutState copyWith({
    TaxInformation? taxInformation,
    bool clearTaxInformation = false,
  }) =>
      CheckoutState(
        taxInformation: clearTaxInformation
            ? null
            : (taxInformation ?? this.taxInformation),
      );
}

class CheckoutNotifier extends StateNotifier<CheckoutState> {
  CheckoutNotifier(this._ref) : super(const CheckoutState());

  final Ref _ref;

  /// Attaches a tax-invoice block to the next order.
  ///
  /// Refuses an incomplete one rather than storing it: the server has no
  /// concept of a partial block (all four fields are required together), so
  /// half of one would either 422 or persist a row no invoice can be raised
  /// from. Returns the first problem, or null when it was accepted.
  String? setTaxInformation(TaxInformation info) {
    final problems = info.violations();
    if (problems.isNotEmpty) return TaxInformation.firstProblem(problems);
    state = state.copyWith(taxInformation: info);
    return null;
  }

  void removeTaxInformation() =>
      state = state.copyWith(clearTaxInformation: true);

  /// Called after a successful order so the next one starts clean.
  ///
  /// Also drops the chosen courier. That choice is a quote for *one* parcel to
  /// *one* pincode — `Delhivery Surface at ₹139.36` for the order that just
  /// went out — and leaving it pinned would have the next order open with the
  /// previous customer-session's shipping line already selected.
  void reset() {
    state = const CheckoutState();
    _ref.read(shippingChoiceProvider.notifier).clear();
  }
}

final checkoutProvider = StateNotifierProvider<CheckoutNotifier, CheckoutState>(
  CheckoutNotifier.new,
);

/// The order total, exactly as the server reports it.
///
/// Every screen that displays money reads this — cart bill, cart checkout bar,
/// and the checkout screen — so they cannot disagree with each other, and none
/// of them can disagree with the server.
final orderSummaryProvider = Provider<OrderSummary>((ref) {
  final cart = ref.watch(activeCartProvider).cart;
  if (cart == null || cart.isEmpty) return OrderSummary.empty;
  return OrderSummary.fromServerCart(cart);
});

/// The same bill, once the courier charge is known.
///
/// [delivery] is `CourierOption.billedPrice` of the courier the customer
/// selected — `freight_charge + coverage_charges + other_charges`, plus
/// `cod_charges` on a COD quote — never a figure this app worked out, and
/// **not** the row's `rate`, which omits coverage and other charges. Read it
/// off [shippingChargeProvider]; nothing else may be passed here.
///
/// Pass null while no courier is quoted and [OrderSummary.payable] stays null,
/// which is what makes checkout label the figure "Subtotal" instead of "To pay"
/// and keep the order button disabled.
final checkoutSummaryProvider =
    Provider.autoDispose.family<OrderSummary, double?>((ref, delivery) {
  final cart = ref.watch(activeCartProvider).cart;
  if (cart == null || cart.isEmpty) return OrderSummary.empty;
  return OrderSummary.fromServerCart(cart, delivery: delivery);
});

// ---------------------------------------------------------------------------
// The parcel
// ---------------------------------------------------------------------------

/// What the courier is actually being asked to price.
///
/// `POST /logistics/check-serviceability` quotes a *shipment*, not a pincode:
/// weight and dimensions are required fields and the rate moves with them. So
/// checkout cannot ask for rates until it knows what is in the box.
///
/// Every field here exists to reproduce one line of
/// `ShipRocketService::getServiceabilityRates()`. That is the whole point of
/// the class — the mobile endpoint is a pass-through that casts and forwards
/// whatever it is handed, so parity is entirely this app's problem, and the
/// customer's complaint that "the app's delivery options don't match the
/// website" was three of these fields being wrong at once.
class CheckoutParcel {
  const CheckoutParcel({
    required this.weightKg,
    required this.lengthCm,
    required this.breadthCm,
    required this.heightCm,
    required this.declaredValue,
    required this.unweighedLines,
    this.pickupPinCode = kDefaultPickupPinCode,
  });

  /// Kilograms, floored at [LogisticsRepository.minServiceabilityWeightKg] —
  /// the web's `max($weight, 0.5)`, not the 0.1 kg `check-pincode` clamp this
  /// app used to borrow.
  final double weightKg;

  /// The packed carton, in centimetres, from the port of
  /// `PackageDimensionCalculator` below.
  final double lengthCm;
  final double breadthCm;
  final double heightCm;

  /// Goods value declared to the courier: the amount the customer pays for the
  /// items, after any coupon, before shipping.
  ///
  /// The web sends `(int) $data['order_total']`. Kept as a double and truncated
  /// server-side, because `DeliveryController` casts with `(int)` anyway and
  /// rounding here would send 1799 where PHP sends 1798.
  final double declaredValue;

  /// Where the parcel ships from — the marketplace store on the basket's own
  /// products, which is rung 2 of `ShipRocketService::getPickupPostcode()`.
  /// Falls back to [kDefaultPickupPinCode].
  final String pickupPinCode;

  /// Cart lines the catalogue records no shipping weight for.
  ///
  /// They contribute nothing to [weightKg], so a quote that includes them is a
  /// *floor*, and checkout says so rather than presenting it as final.
  final int unweighedLines;

  bool get isWeightKnown => unweighedLines == 0;

  /// The rate request for [pinCode].
  ShippingQuery toQuery(String pinCode, {bool cod = false}) => ShippingQuery(
        pinCode: pinCode,
        weightKg: weightKg,
        lengthCm: lengthCm,
        breadthCm: breadthCm,
        heightCm: heightCm,
        declaredValue: declaredValue,
        cod: cod,
        pickupPinCode: pickupPinCode,
      );
}

/// Packs the cart so its contents can be quoted.
///
/// **The server already did this.** `getDataForResponse()` runs the real
/// `PackageDimensionCalculator` — box catalogue included — and returns the
/// result as `package_dimensions`, alongside `total_weight` and `order_total`.
///
/// This provider used to re-implement that calculator in Dart and fetch one
/// product detail per cart line to feed it, because the local cart carried
/// neither weight nor size. Both are gone: the port could not consult the
/// admin-managed `shipping_boxes` table and would have silently diverged the
/// day someone added a box, and the per-line fetches were N round trips for
/// data the cart response already contained. Verified identical on a live cart
/// — two of SKU 118 gives `{length: 20, breadth: 7, height: 49, weight: 10.2}`
/// either way.
final checkoutParcelProvider =
    FutureProvider.autoDispose<CheckoutParcel>((ref) async {
  // The parcel is weighed from whichever cart is being checked out — a
  // Buy-now order must be quoted for its one product, not for the basket.
  final state = ref.watch(activeCartProvider);

  // Building the parcel is now synchronous — everything it needs is in the cart
  // payload — but it stays a FutureProvider because "not knowable yet" is still
  // a real state: until the first cart read lands there is no shipment to
  // quote. Holding the provider in `loading` says that, where returning an
  // empty parcel would quietly ask the courier to price nothing. The pending
  // future is discarded and this body re-run the moment the cart resolves.
  if (state.loading) return Completer<CheckoutParcel>().future;

  final cart = state.cart;
  if (cart == null || cart.isEmpty) {
    return const CheckoutParcel(
      weightKg: LogisticsRepository.minServiceabilityWeightKg,
      lengthCm: kDefaultParcelLengthCm,
      breadthCm: kDefaultParcelBreadthCm,
      heightCm: kDefaultParcelHeightCm,
      declaredValue: 0,
      unweighedLines: 0,
    );
  }

  final pkg = cart.packageDimensions;

  // `total_weight` is the sum of line weights in grams — the same figure
  // `getShippingData()` puts in the web's `weight` parameter, which is the one
  // the rate is quoted on. `package_dimensions.weight` is kilograms and only
  // feeds the box lookup, so it is deliberately not used here.
  final weightKg = cart.totalWeight > 0
      ? LogisticsRepository.serviceabilityWeightKg(cart.totalWeight)
      : LogisticsRepository.minServiceabilityWeightKg;

  return CheckoutParcel(
    weightKg: weightKg,
    lengthCm: pkg?.length ?? kDefaultParcelLengthCm,
    breadthCm: pkg?.breadth ?? kDefaultParcelBreadthCm,
    heightCm: pkg?.height ?? kDefaultParcelHeightCm,
    // The web sends `(int) $data['order_total']`, and this is now that same
    // `order_total` rather than the app's own subtotal-minus-coupon. The two
    // differed because the app treated prices as GST-inclusive while the server
    // adds tax on top — the divergence noted in followUps, now closed.
    declaredValue: cart.orderTotal.amount,
    // A line the catalogue records no weight for makes the quote a floor, and
    // checkout says so rather than presenting it as final.
    unweighedLines: cart.items.where((i) => (i.weight ?? 0) <= 0).length,
    // Rung 2 of `getPickupPostcode()` — the marketplace store on the basket's
    // own lines — read from `cart_items[*].cart_options.store.zip_code` rather
    // than assumed. It resolves to the same 311001 that
    // [kDefaultPickupPinCode] holds today, so no rate moves; what changes is
    // that the app now *follows* the store instead of holding a copy of its
    // postcode. See [pickupPinCodeFromCart] for the fallback rules.
    pickupPinCode: pickupPinCodeFromCart(cart),
  );
});

// ===========================================================================
// The pending-order journal
// ===========================================================================

/// How far one checkout got before the app last stopped looking at it.
///
/// Written to disk **before** each step it names, never after, because the only
/// crash that matters is the one in the middle of the step.
enum PendingOrderStage {
  /// The checkout POST is about to leave, or has left and not been answered —
  /// and, once it has, the order exists and **the payment sheet has not been
  /// opened for it**.
  ///
  /// This is the only stage that may be described to a customer as "nothing has
  /// been charged", and only on a record whose [PendingOrder.version] is at
  /// least [PendingOrder.currentVersion]. Before [paymentOpened] existed this
  /// stage covered the sheet as well, so a v1 record cannot tell the two apart —
  /// see [PendingOrder.sheetNeverOpened].
  created,

  /// **The payment sheet is open, or was open when this app stopped running.**
  ///
  /// Written to disk immediately *before* [PaymentGateway.pay] is called, and
  /// walked back to [created] only when the SDK itself reports that no payment
  /// was taken (a dismissed sheet, or a provider-reported failure with a real
  /// reason).
  ///
  /// The stage exists because without it a process killed while the customer was
  /// in their UPI app is byte-identical on disk to one killed with the checkout
  /// POST in flight. The bank debits, Razorpay captures, the callback never
  /// arrives — and the next launch reads `created` and tells the customer
  /// nothing was charged.
  ///
  /// **Money may have moved on this stage.** Nothing may say otherwise, and the
  /// record is never dropped for age while it stands here.
  paymentOpened,

  /// The Razorpay sheet reported success and the triple is stored. From here
  /// the order can be finalised on a later launch without the customer.
  sdkSuccess,

  /// Confirm-payment was sent at least once.
  confirmSent,

  /// `GET /orders/{id}` reported `payment_status == completed`. Nothing left.
  settled,
}

/// Everything needed to find and finish an order the app has lost sight of.
///
/// **This record is the only handle on an unpaid order.** `GET /orders` and
/// `GET /orders/{id}` both hard-filter `is_finished = 1`, so between the
/// checkout POST and a successful confirm-payment the order is invisible to
/// every read endpoint the app has — it cannot be listed, searched or looked up
/// by anything except the id kept here. Losing this record loses the order: the
/// stock is held, the coupon use is burnt, and the customer has no way to reach
/// it except support.
///
/// Persisted as one JSON blob under [PendingOrderStore.key]. Deliberately flat
/// and tolerant — a record that fails to decode is worse than useless, so
/// [tryDecode] returns null rather than throwing and every field but [cartId]
/// and [stage] is optional.
class PendingOrder {
  const PendingOrder({
    required this.cartId,
    required this.stage,
    required this.createdAt,
    this.orderId,
    this.orderToken,
    this.razorpayOrderId,
    this.razorpayKeyId,
    this.amountPaise,
    this.currency,
    this.totalAmount,
    this.totalAmountValue,
    this.razorpayPaymentId,
    this.razorpaySignature,
    this.customerEmail,
    this.customerPhone,
    this.version = currentVersion,
  });

  /// The journal format this build writes.
  ///
  /// **1** — no [PendingOrderStage.paymentOpened]. On a v1 record `created`
  /// means "the sheet had not opened" *or* "the sheet was open and the app
  /// died in it": the two were indistinguishable, which is the defect
  /// [PendingOrderStage.paymentOpened] fixes. Nothing may claim a v1 `created`
  /// record was never charged.
  ///
  /// **2** — the stages mean what they say.
  ///
  /// Bumping this is preferable to bumping [PendingOrderStore.key], which would
  /// orphan every record already on a device — and a record is the only handle
  /// on an order no read endpoint can see.
  static const int currentVersion = 2;

  /// The cart the order was created from. Held so a settled order can discard
  /// exactly that cart — and so an *unsettled* one provably must not.
  final String cartId;

  final PendingOrderStage stage;
  final DateTime createdAt;

  /// `data.order_id`. Null only while the POST is in flight, or when it came
  /// back unreadable — which is itself the "reconcile, do not repeat" case.
  final int? orderId;

  /// `data.order_token`. No request the app makes takes it, but it is the other
  /// identifier support can find an unfinished order by.
  final String? orderToken;

  /// The `data.razorpay` block, stored verbatim so "retry payment" reopens the
  /// sheet for the **same** Razorpay order. Building a fresh one would mean a
  /// second checkout POST, which is a second real order.
  final String? razorpayOrderId;
  final String? razorpayKeyId;

  /// Already paise. Never multiplied, never derived from [totalAmount].
  final int? amountPaise;
  final String? currency;

  /// `data.total_amount` as the server rendered it (`"₹9,034.20"`), for the
  /// messages that must name a figure before `GET /orders/{id}` is reachable.
  final String? totalAmount;

  /// The same `data.total_amount`, as a number.
  ///
  /// Held for exactly one job: [sheetAmountMatchesTotal]. The customer is asked
  /// to approve `total_amount` and the sheet then opens at `razorpay.amount`,
  /// and until this field existed nothing in the app checked that those were
  /// the same money.
  ///
  /// Null on a record written before the field existed, and on a response whose
  /// total could not be read.
  final double? totalAmountValue;

  /// Which build wrote this record. See [currentVersion].
  final int version;

  /// The SDK triple, stored the instant the sheet succeeds and before
  /// confirm-payment leaves the device. This is the whole crash-recovery story:
  /// with it, a later launch can finish the order unattended; without it, it
  /// cannot.
  final String? razorpayPaymentId;
  final String? razorpaySignature;

  /// Prefill for a reopened sheet. Cosmetic.
  final String? customerEmail;
  final String? customerPhone;

  /// The order exists server-side and can be looked up.
  bool get isIdentified => (orderId ?? 0) > 0;

  /// A complete triple is held, so confirm-payment can be re-sent unattended.
  bool get hasPaymentProof =>
      (razorpayPaymentId ?? '').isNotEmpty &&
      (razorpayOrderId ?? '').isNotEmpty &&
      (razorpaySignature ?? '').isNotEmpty;

  /// **The journal proves the payment sheet was never opened for this order.**
  ///
  /// The one predicate that licenses the sentence "nothing has been charged".
  /// It is true only at [PendingOrderStage.created], and only on a record this
  /// build's staging wrote ([currentVersion]) — a v1 `created` record could have
  /// been left behind by an app killed inside the sheet, because v1 had no
  /// stage for that.
  ///
  /// Everything else — the sheet open, the triple stored, confirm-payment sent,
  /// or a record from a build that could not tell — is [paymentMayHaveHappened].
  bool get sheetNeverOpened =>
      stage == PendingOrderStage.created && version >= currentVersion;

  /// The negation, named for what it forbids: no message about this record may
  /// assert that nothing was charged.
  bool get paymentMayHaveHappened => !sheetNeverOpened;

  /// The sheet's amount **is** the order's total, to the paise.
  ///
  /// `data.razorpay.amount` is `(int) round($order->amount * 100)` server-side,
  /// so the two are one figure in two units. Nothing enforced that: the
  /// divergence sheet's Continue button names `total_amount`, the SDK opens at
  /// `razorpay.amount`, and a server that ever let them part company would
  /// charge a number nobody was shown.
  ///
  /// A null on either side is "cannot check", not "disagree" — [amountPaise] is
  /// still the server's own figure, and refusing on a record written before
  /// [totalAmountValue] existed would strand a payable order. Both known and
  /// unequal is the refusal.
  bool get sheetAmountMatchesTotal {
    final rupees = totalAmountValue;
    final paise = amountPaise;
    if (rupees == null || paise == null) return true;
    return (rupees * 100).round() == paise;
  }

  /// The sheet, reopenable for the same Razorpay order. Null when the record
  /// predates the handoff or the block was unusable.
  PaymentRequest? toPaymentRequest() {
    final key = razorpayKeyId;
    final order = razorpayOrderId;
    final amount = amountPaise;
    if (key == null || key.isEmpty) return null;
    if (order == null || order.isEmpty) return null;
    if (amount == null || amount <= 0) return null;
    return PaymentRequest(
      keyId: key,
      orderId: order,
      amountInPaise: amount,
      currency: (currency ?? '').isEmpty ? 'INR' : currency!,
      // The store name, not the order id. This string is drawn inside the
      // Razorpay sheet, which is as customer-facing as the app itself, and the
      // order *code* is not known at this point — the checkout response
      // carries only `order_id` and `order_token`.
      description: isIdentified ? 'Trueway Farms order' : null,
      customerEmail: customerEmail,
      customerPhone: customerPhone,
    );
  }

  PendingOrder copyWith({
    PendingOrderStage? stage,
    int? orderId,
    String? orderToken,
    String? razorpayOrderId,
    String? razorpayKeyId,
    int? amountPaise,
    String? currency,
    String? totalAmount,
    double? totalAmountValue,
    String? razorpayPaymentId,
    String? razorpaySignature,
  }) =>
      PendingOrder(
        cartId: cartId,
        stage: stage ?? this.stage,
        createdAt: createdAt,
        orderId: orderId ?? this.orderId,
        orderToken: orderToken ?? this.orderToken,
        razorpayOrderId: razorpayOrderId ?? this.razorpayOrderId,
        razorpayKeyId: razorpayKeyId ?? this.razorpayKeyId,
        amountPaise: amountPaise ?? this.amountPaise,
        currency: currency ?? this.currency,
        totalAmount: totalAmount ?? this.totalAmount,
        totalAmountValue: totalAmountValue ?? this.totalAmountValue,
        razorpayPaymentId: razorpayPaymentId ?? this.razorpayPaymentId,
        razorpaySignature: razorpaySignature ?? this.razorpaySignature,
        customerEmail: customerEmail,
        customerPhone: customerPhone,
        // Deliberately carried, not refreshed. The version records what the
        // *staging* of this record can be trusted to mean, and re-stamping a v1
        // record as v2 on the way through would manufacture the proof that
        // [sheetNeverOpened] exists to withhold.
        version: version,
      );

  /// Adopts everything a checkout (or confirm-payment) response carries.
  PendingOrder withOrder(PlacedOrder order) => copyWith(
        orderId: order.orderId,
        orderToken: order.orderToken,
        totalAmount: order.totalAmount.display,
        totalAmountValue: order.totalAmount.amount,
        razorpayOrderId: order.razorpay?.orderId,
        razorpayKeyId: order.razorpay?.keyId,
        amountPaise: order.razorpay?.amountInPaise,
        currency: order.razorpay?.currency,
      );

  Map<String, dynamic> toJson() => {
        'cart_id': cartId,
        'stage': stage.name,
        'v': version,
        'created_at': createdAt.toIso8601String(),
        if (orderId != null) 'order_id': orderId,
        if (orderToken != null) 'order_token': orderToken,
        if (razorpayOrderId != null) 'razorpay_order_id': razorpayOrderId,
        if (razorpayKeyId != null) 'razorpay_key_id': razorpayKeyId,
        if (amountPaise != null) 'amount_paise': amountPaise,
        if (currency != null) 'currency': currency,
        if (totalAmount != null) 'total_amount': totalAmount,
        if (totalAmountValue != null) 'total_amount_value': totalAmountValue,
        if (razorpayPaymentId != null) 'razorpay_payment_id': razorpayPaymentId,
        if (razorpaySignature != null) 'razorpay_signature': razorpaySignature,
        if (customerEmail != null) 'customer_email': customerEmail,
        if (customerPhone != null) 'customer_phone': customerPhone,
      };

  factory PendingOrder.fromJson(Map<String, dynamic> j) => PendingOrder(
        cartId: asString(j['cart_id']),
        stage: PendingOrderStage.values.firstWhere(
          (s) => s.name == asString(j['stage']),
          // An unreadable stage — a missing field, or a name a *newer* build
          // wrote — falls back to the one that asserts nothing. Falling back to
          // `created` would manufacture exactly the proof
          // [sheetNeverOpened] exists to withhold, out of a value this build
          // could not read.
          orElse: () => PendingOrderStage.paymentOpened,
        ),
        // Absent means a record written before the field existed — v1, whose
        // `created` stage cannot be trusted to mean the sheet never opened.
        version: j['v'] == null ? 1 : asInt(j['v'], 1),
        createdAt:
            DateTime.tryParse(asString(j['created_at'])) ?? DateTime.now(),
        orderId: j['order_id'] == null ? null : asInt(j['order_id']),
        orderToken: asStringOrNull(j['order_token']),
        razorpayOrderId: asStringOrNull(j['razorpay_order_id']),
        razorpayKeyId: asStringOrNull(j['razorpay_key_id']),
        amountPaise: j['amount_paise'] == null ? null : asInt(j['amount_paise']),
        currency: asStringOrNull(j['currency']),
        totalAmount: asStringOrNull(j['total_amount']),
        totalAmountValue: j['total_amount_value'] == null
            ? null
            : asDouble(j['total_amount_value']),
        razorpayPaymentId: asStringOrNull(j['razorpay_payment_id']),
        razorpaySignature: asStringOrNull(j['razorpay_signature']),
        customerEmail: asStringOrNull(j['customer_email']),
        customerPhone: asStringOrNull(j['customer_phone']),
      );

  String encode() => jsonEncode(toJson());

  /// Never throws. A record that cannot be read is treated as absent — the
  /// alternative is a failure on every launch for as long as it sits there.
  static PendingOrder? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return PendingOrder.fromJson(Map<String, dynamic>.from(decoded));
    } on Object {
      return null;
    }
  }
}

/// The one place the journal is read and written.
///
/// Reads are synchronous: [SharedPreferences] is already resolved in `main()`,
/// and the record has to be consultable from a build without an await.
class PendingOrderStore {
  const PendingOrderStore(this._prefs);

  final SharedPreferences _prefs;

  static const String key = 'pending_order_v1';

  PendingOrder? read() => PendingOrder.tryDecode(_prefs.getString(key));

  Future<void> write(PendingOrder record) =>
      _prefs.setString(key, record.encode());

  /// Only ever called for an order proved paid, or one that provably never
  /// existed. Anything else keeps its record.
  Future<void> clear() => _prefs.remove(key);
}

final pendingOrderStoreProvider = Provider<PendingOrderStore>(
  (ref) => PendingOrderStore(ref.watch(sharedPreferencesProvider)),
);

// ===========================================================================
// Proving an order is paid
// ===========================================================================

/// What `GET /ecommerce/orders/{id}` said about the money.
enum OrderPaymentLookup {
  /// `payment_status.value == "completed"` — the only value that means paid.
  paid,

  /// The order is finished and the payment is anything else: pending, failed,
  /// refunded. **Finalised is not paid** — the server sets `is_finished`
  /// unconditionally, with no payment-status branch, so reaching this endpoint
  /// at all proves only that the order was processed.
  notPaid,

  /// 404. Both order reads filter `is_finished = 1`, so for an order this app
  /// created itself this means "not finalised yet", never "does not exist".
  notFinished,

  /// The call failed for some other reason. Says nothing either way.
  unreachable,
}

/// Reads the one authoritative payment field.
///
/// Deliberately a function over [Ref] rather than a provider family: every
/// caller wants a *fresh* read at a particular moment, and a cached
/// `FutureProvider` would answer with the state from before the payment.
Future<OrderPaymentLookup> lookUpPayment(Ref ref, int orderId) async {
  if (orderId <= 0) return OrderPaymentLookup.unreachable;
  try {
    final order = await ref.read(orderRepositoryProvider).order(orderId);
    return order.paymentStatus.value == PlacedOrder.paidPaymentStatus
        ? OrderPaymentLookup.paid
        : OrderPaymentLookup.notPaid;
  } on ApiException catch (e) {
    return e.isNotFound
        ? OrderPaymentLookup.notFinished
        : OrderPaymentLookup.unreachable;
  }
}

// ===========================================================================
// Placing the order
// ===========================================================================

/// Where one checkout attempt has got to.
///
/// Nine states rather than "loading / done / error", because this flow has
/// three outcomes that are neither and must not be rendered as either: the
/// payment did not happen but the order exists
/// ([CheckoutPhase.paymentIncomplete]); the payment may have happened and was
/// not confirmed ([CheckoutPhase.verifying]); and nobody knows
/// ([CheckoutPhase.unresolved]).
enum CheckoutPhase {
  idle,

  /// The non-idempotent POST is in flight. The button must stay dead for the
  /// whole of it.
  placing,

  /// **The order exists, nothing has been charged, and the server's total is
  /// not the total the customer was shown.**
  ///
  /// A terminal-until-answered state, and the reason this enum grew: the app no
  /// longer sends `shipping_amount`, so the server prices shipping itself — from
  /// its own `store_zip_code` re-quote, or from `0.00` when the
  /// `shipping_option` key misses its table. Either way the order is created
  /// *before* the app learns the figure, so the only honest move is to stop
  /// short of the Razorpay sheet and let the customer see both numbers.
  ///
  /// The SDK has **not** been opened. [CheckoutFlowNotifier.acceptServerTotal]
  /// opens it at the server's amount; [CheckoutFlowNotifier.declineServerTotal]
  /// leaves the order unpaid with the journal record and the cart intact.
  totalChanged,

  /// The Razorpay sheet is up.
  awaitingPayment,

  /// Confirm-payment is in flight, or the order is being reconciled against
  /// `GET /orders/{id}`.
  confirming,

  /// Paid, and proved. The only phase the success screen may be shown for.
  paid,

  /// The order exists and is unpaid — a dismissed sheet, or a provider-reported
  /// failure. **Do not re-place the order**: offer "retry payment", which
  /// reopens the sheet for the same Razorpay order.
  paymentIncomplete,

  /// TEMPORARY (see `docs/TODO_CANCELLED_PAYMENT_FLOW.md`): the customer
  /// dismissed the Razorpay sheet, and per the interim product decision the
  /// flow abandons the order on the spot — journal settled, state about to be
  /// reset — and the screen pops back to the cart. The next checkout creates a
  /// fresh order.
  ///
  /// One-shot: the screen listens for the transition into this phase, pops,
  /// and resets the flow to [idle]. Nothing else may act on it.
  cancelledBackToCart,

  /// Money may have moved and the app cannot prove the order is paid: a 200
  /// with `payment_status: "pending"`, an invalid signature, or a replay guard
  /// whose order still is not completed. Route to support; keep the record.
  verifying,

  /// The server refused before creating anything — out of stock, cart expired,
  /// minimum order amount. Safe to fix and try again.
  refused,

  /// The request left and no answer came back. **An order may exist.** Never
  /// re-POST; reconcile.
  unresolved,
}

/// What the server billed, beside what the customer was told it would be.
///
/// ## Why this has to exist at all
///
/// The app no longer sends `shipping_amount`. It sends
/// `shipping_method: "shiprocket"` + `shipping_option: "shiprocket_<rateId>"`
/// and lets the server price the shipping line, which is what the web checkout
/// does. That hands two failure modes to a screen that has already created a
/// real order:
///
///   * **higher** — the server re-quotes Shiprocket with
///     `get_ecommerce_setting('store_zip_code')` as the pickup postcode, not the
///     app's `pickupPinCode`, and a different origin is a different price;
///   * **lower** — a `shipping_option` the server's own table does not contain
///     resolves to null, and `Arr::get($shippingMethod, 'price', 0)` bills
///     **0.00**. Nothing anywhere reports an error.
///
/// The second one is the dangerous one to wave through. It is not a discount:
/// it means the shipment carries no courier metadata, so ops cannot dispatch
/// it. Both directions are surfaced, and the customer can decline either.
///
/// Every figure here is the **server's own**, taken from the checkout response.
/// Nothing is re-added from parts — [chargedDisplay] and [shippingDisplay] are
/// the strings the server rendered, down to the paise.
class TotalDivergence {
  const TotalDivergence({
    required this.shown,
    required this.charged,
    required this.chargedDisplay,
    required this.shipping,
    required this.shippingDisplay,
    this.shownShipping,
  });

  /// Rupees, and it is **half a paise** — not the ₹1 it used to be.
  ///
  /// Both sides of this comparison are exact to the paise: the server's money
  /// columns are `decimal(15,2)` and the app's figure is a server-supplied
  /// `order_total` plus a server-supplied courier rate. The only thing that can
  /// separate two figures that mean the same bill is binary floating-point dust
  /// — about 1e-13 at these magnitudes — so anything a paise-rounding could not
  /// have produced is a genuine re-price.
  ///
  /// A ₹1 band waved through up to 99 paise *more than the button said*,
  /// charged with nobody asked. There is no such thing as an acceptable silent
  /// overcharge, however small, so the band is now only as wide as the
  /// arithmetic requires.
  static const double tolerance = 0.005;

  /// The figure on the Place order button when it was tapped —
  /// `OrderSummary.payable`. Read from the one place the button reads it, never
  /// recomputed.
  final double shown;

  /// The courier rate that was inside [shown] — the shipping line the app
  /// quoted and printed on the bill.
  ///
  /// Carried for one reason: it is the only way to tell a **missing** server
  /// shipping line from an order that genuinely costs nothing to ship. Null
  /// when the caller had no quote to report, which the checkout button prevents
  /// by staying dead until a courier has priced the parcel.
  final double? shownShipping;

  /// `data.total_amount`. The number `data.razorpay.amount` is 100× of, and
  /// therefore the number the card is charged.
  final double charged;

  /// `data.total_amount` as the server rendered it, e.g. `"₹1,274.15"`.
  final String chargedDisplay;

  /// `data.shipping_amount` — what the order was really billed for delivery.
  /// **This is the field the reviewer flagged as written-but-never-read**; it
  /// now has exactly one job, which is to be shown here.
  final double shipping;
  final String shippingDisplay;

  /// Positive when the server charged more than the button said.
  double get difference => charged - shown;

  /// **The order was billed nothing for delivery on a parcel a courier priced.**
  ///
  /// Two different backend faults land here and neither is a discount:
  ///
  ///   * the `shipping_option` key missed the server's rate table, so
  ///     `Arr::get($shippingMethod, 'price', 0)` billed 0.00;
  ///   * Shiprocket was **down** when the server re-quoted.
  ///     `HookServiceProvider.php:63-75` swallows the exception and the filter
  ///     returns no rates at all, so the order is written with a 0.00 shipping
  ///     line and no courier metadata on it.
  ///
  /// Either way nobody in the warehouse can dispatch the parcel, so this is
  /// surfaced on its own account — see [isMaterial] — rather than only when the
  /// totals happen to differ by enough.
  bool get isShippingMissing => shipping <= 0 && (shownShipping ?? 0) > 0;

  /// Worth stopping the customer for.
  ///
  /// Either the money moved ([tolerance]) or the delivery line vanished
  /// ([isShippingMissing]). The second disjunct is not redundant: a server that
  /// drops ₹330 of shipping and gains ₹330 somewhere else would net to zero
  /// here, and the parcel would still be undispatchable.
  bool get isMaterial => difference.abs() > tolerance || isShippingMissing;

  bool get isOvercharge => difference > tolerance;

  /// The server billed **less**. Not a win — see the class doc.
  bool get isUndercharge => difference < -tolerance;

  /// Reads the figures off a freshly created order.
  ///
  /// [shownShipping] is the courier rate the app quoted, so a 0.00 server
  /// shipping line can be told apart from a parcel that was always free.
  factory TotalDivergence.between({
    required double shown,
    required PlacedOrder order,
    double? shownShipping,
  }) =>
      TotalDivergence(
        shown: shown,
        shownShipping: shownShipping,
        charged: order.totalAmount.amount,
        chargedDisplay: order.totalAmount.display,
        shipping: order.shippingAmount.amount,
        shippingDisplay: order.shippingAmount.display,
      );
}

/// One checkout attempt, and what the customer should be told about it.
class CheckoutFlowState {
  const CheckoutFlowState({
    this.orderCode,
    this.phase = CheckoutPhase.idle,
    this.message,
    this.fieldErrors = const {},
    this.orderId,
    this.pending,
    this.serverTotal,
    this.divergence,
  });

  final CheckoutPhase phase;

  /// The sentence to show. The server's own wording wherever there is one — it
  /// names the actual constraint ("Product X is out of stock!").
  final String? message;

  /// Address violations keyed by [AddressField] — bare names, so a form can
  /// look one up per field.
  final Map<String, String> fieldErrors;

  /// The numeric shop order id, once there is one. **Internal** — never shown
  /// to a customer; see [orderCode].
  final int? orderId;

  /// The customer-facing order code as rendered — `SF10000315` — when the
  /// server sent one. Already stripped of the leading `#` that a quarter of
  /// this shop's orders carry; see [PlacedOrder.displayCode].
  ///
  /// Null until the backend adds `code` to the checkout payloads — see
  /// [PlacedOrder.code]. The screen prints "Your order" while it is null rather
  /// than falling back to [orderId], which is an internal key the customer sees
  /// nowhere else and support does not ask for.
  final String? orderCode;

  /// The journal entry as it currently stands on disk.
  final PendingOrder? pending;

  /// `data.total_amount`, rendered by the server. Displayed verbatim — the app
  /// never re-adds the parts.
  final String? serverTotal;

  /// The server's figures against the figure the button showed, once an order
  /// exists. Null before the checkout POST answers, and on the paths where no
  /// order was created.
  ///
  /// Present does **not** mean "they disagree" — ask [TotalDivergence.isMaterial]
  /// for that. It is built on every successful checkout so the comparison is
  /// made once, in one place, rather than by whichever screen happens to look.
  final TotalDivergence? divergence;

  /// A request is out. Every control must be frozen: this call is not
  /// idempotent, and a second tap is a second order.
  ///
  /// [CheckoutPhase.totalChanged] is deliberately **not** busy — nothing is in
  /// flight there, the customer is being asked a question. It is excluded from
  /// the Place order button by [needsDecision] instead, which matters: an
  /// enabled Place order button in that phase would create a *second* order.
  bool get isBusy =>
      phase == CheckoutPhase.placing ||
      phase == CheckoutPhase.awaitingPayment ||
      phase == CheckoutPhase.confirming;

  /// **An order exists server-side and this app knows its id.**
  ///
  /// The line the screen turns on: from here the customer's own basket is no
  /// longer the bill. The order was priced by the server the moment it was
  /// created, and the app's live cart total — which moves every time the basket
  /// is edited — describes something that is not being paid for. Only
  /// [serverTotal] / [divergence] may be shown as money past this point.
  bool get hasOrder => (orderId ?? 0) > 0;

  /// An order exists, or the request that would have created one was never
  /// answered. Either way the live cart bill is no longer what is owed, and
  /// "Place order" must not be the action on screen.
  bool get orderMayExist => hasOrder || phase == CheckoutPhase.unresolved;

  /// The order exists and is waiting on the customer accepting or refusing the
  /// server's total. No money has moved and the SDK has not been opened.
  bool get needsDecision =>
      phase == CheckoutPhase.totalChanged && divergence != null;

  /// The customer is stuck on an unpaid order and may abandon it.
  ///
  /// Only [CheckoutPhase.paymentIncomplete], which is exactly "the order exists
  /// and nothing was charged for it". Never [CheckoutPhase.verifying], where
  /// money may already have moved and starting again could pay twice, and never
  /// [CheckoutPhase.totalChanged], which has its own two answers.
  /// Both phases where an order may be sitting unpaid and the customer is
  /// entitled to move on anyway — never [CheckoutPhase.verifying], where money
  /// may already have moved and a second checkout could charge them twice.
  ///
  /// [CheckoutPhase.unresolved] is included deliberately. It is the phase a
  /// never-answered POST leaves behind, and without a way out of it the customer
  /// is locked out of checkout entirely until the journal ages out. The
  /// confirmation for that case does not claim the earlier order is absent — it
  /// says plainly that we cannot tell. See `_startOver`.
  bool get canStartOver =>
      phase == CheckoutPhase.paymentIncomplete ||
      phase == CheckoutPhase.unresolved;

  /// The order exists, is unpaid, and the same Razorpay order can be reopened.
  bool get canRetryPayment =>
      phase == CheckoutPhase.paymentIncomplete &&
      pending?.toPaymentRequest() != null;

  /// Paid and proved — the success screen may be shown.
  bool get isPaid => phase == CheckoutPhase.paid && (orderId ?? 0) > 0;

  /// The customer must not be sent back to the cart to try again: an order may
  /// exist, and a second checkout would duplicate it.
  bool get needsReconciliation =>
      phase == CheckoutPhase.unresolved || phase == CheckoutPhase.verifying;

  CheckoutFlowState copyWith({
    CheckoutPhase? phase,
    String? message,
    Map<String, String>? fieldErrors,
    int? orderId,
    String? orderCode,
    PendingOrder? pending,
    String? serverTotal,
    TotalDivergence? divergence,
  }) =>
      CheckoutFlowState(
        phase: phase ?? this.phase,
        message: message ?? this.message,
        fieldErrors: fieldErrors ?? this.fieldErrors,
        orderCode: orderCode ?? this.orderCode,
        orderId: orderId ?? this.orderId,
        pending: pending ?? this.pending,
        serverTotal: serverTotal ?? this.serverTotal,
        divergence: divergence ?? this.divergence,
      );
}

/// Drives steps 7 to 11 of the checkout sequence.
///
/// ## The three rules this class exists to enforce
///
/// 1. **[CheckoutRepository.placeOrder] is called at most once per attempt and
///    is never retried.** Its de-duplication key server-side is a session
///    token, and the `api` middleware group has no session — so every POST
///    mints a new order, a new Razorpay order and another coupon use.
///    [CheckoutPhase.placing] gates re-entry and there is no retry anywhere in
///    this file.
/// 2. **The journal is written before the step it describes.** The record with
///    the cart id goes down before the POST; the order id and token go down the
///    instant the response arrives; the SDK triple goes down before
///    confirm-payment leaves. A crash at any point is recoverable on the next
///    launch by [PendingOrderRecoveryNotifier].
/// 3. **The cart is discarded only for an order proved paid.** Never on a
///    refusal, never on a dismissed sheet, never on an unknown outcome — those
///    are exactly the cases where the customer still needs their basket.
/// 4. **The sheet never opens at a figure the button did not show.** Shipping is
///    priced by the server now, so the total can move between the tap and the
///    response — in either direction. [placeOrder] compares the two and, when
///    they differ, stops in [CheckoutPhase.totalChanged] with nothing charged
///    rather than putting a different number in front of the customer's card.
///    [_collectPayment] then checks the sheet's own amount against the total
///    that was approved, and refuses to open on a mismatch.
/// 5. **A restart does not lose the order.** The state this notifier starts in
///    is read from the journal ([_rehydrated]), not assumed to be blank, so an
///    order left unpaid by a process kill is still on screen and still payable
///    — and the live cart bill, which describes something that is no longer
///    what is owed, does not come back in its place.
/// 6. **Nothing claims the customer was not charged unless the journal proves
///    it.** [PendingOrder.sheetNeverOpened] is that proof and the only thing
///    licensed to produce the sentence. `GET /orders` and `GET /orders/{id}`
///    cannot supply it: both filter `is_finished = 1`, so an unpaid order is
///    absent from them, and absence is not evidence.
class CheckoutFlowNotifier extends StateNotifier<CheckoutFlowState> {
  CheckoutFlowNotifier(this._ref) : super(_rehydrated(_ref));

  final Ref _ref;

  CheckoutRepository get _repo => _ref.read(checkoutRepositoryProvider);
  PendingOrderStore get _store => _ref.read(pendingOrderStoreProvider);
  PaymentGateway get _gateway => _ref.read(paymentGatewayProvider);

  // ---- rehydration -------------------------------------------------------

  /// The state a **restart** starts in, read from the journal.
  ///
  /// ## What this fixes
  ///
  /// This notifier used to start at `const CheckoutFlowState()` unconditionally,
  /// and the only two journal reads in the class were gated on phases that only
  /// an in-session transition can set. So nothing survived a process kill:
  /// order 288 created for ₹1,274.15 with a live `razorpay` block, sheet
  /// dismissed, force-quit — and the next launch put a **live cart bill** and a
  /// **live Place order button** in front of the customer. The unpaid order was
  /// no longer payable from the app at all, and the next tap created a second
  /// real one.
  ///
  /// ## What it may and may not claim
  ///
  /// Only what the record proves. [PendingOrder.sheetNeverOpened] is the whole
  /// of the distinction: at that stage the sheet was demonstrably not opened, so
  /// the order is unpaid, payable, and safe to describe as uncharged. At every
  /// other stage — the sheet was up, the triple is on disk, confirm-payment
  /// went out, or the record predates the staging that could tell — money may
  /// have moved, so the flow lands in [CheckoutPhase.verifying], which offers no
  /// retry and no Place order and says the payment is being checked.
  ///
  /// ## Ordering
  ///
  /// Side-effect-free and synchronous by design: a constructor may not do I/O
  /// beyond the already-resolved [SharedPreferences], and it must not throw.
  /// The *network* reconciliation of the same record is
  /// [PendingOrderRecoveryNotifier], which runs from the launch gate — normally
  /// before checkout is ever opened, so a record it settles is already gone by
  /// the time this reads.
  static CheckoutFlowState _rehydrated(Ref ref) {
    PendingOrder? record;
    try {
      record = ref.read(pendingOrderStoreProvider).read();
    } on Object {
      // A notifier that cannot be constructed takes the whole checkout screen
      // with it. An unreadable journal is treated as an absent one — the same
      // rule [PendingOrder.tryDecode] follows.
      record = null;
    }

    if (record == null) return const CheckoutFlowState();
    if (record.stage == PendingOrderStage.settled) {
      return const CheckoutFlowState();
    }

    // No id: the POST was never answered, so an order MAY exist and cannot be
    // looked up. `unresolved` is what keeps Place order off the screen.
    if (!record.isIdentified) {
      return CheckoutFlowState(
        phase: CheckoutPhase.unresolved,
        message: _unknownMessage,
        pending: record,
      );
    }

    final orderId = record.orderId;

    if (record.sheetNeverOpened) {
      return CheckoutFlowState(
        phase: CheckoutPhase.paymentIncomplete,
        orderId: orderId,
        // The server's own rendering of `total_amount`, so the screen shows the
        // ORDER's figures rather than a live cart bill for a basket that is no
        // longer what is being paid for.
        serverTotal: record.totalAmount,
        pending: record,
        message: 'Order $orderId was created and has not been paid for. '
            'Nothing has been charged and your basket is untouched — you can '
            'pay for it here without starting again.',
      );
    }

    // ⚠ TEMPORARY — see docs/TODO_CANCELLED_PAYMENT_FLOW.md. A record whose
    // sheet was open when the app stopped, but which holds NO payment triple,
    // used to park the flow at `verifying` forever ("we're checking whether
    // the payment went through") with no way out. Per the interim decision it
    // is abandoned like a cancelled sheet: settle the journal, start blank,
    // and the next checkout creates a fresh order. A record WITH a triple is
    // still handled below — the launch recovery pass can actually finish that
    // one, so it must not be dropped.
    if (record.stage == PendingOrderStage.paymentOpened &&
        !record.hasPaymentProof) {
      unawaited(
        ref
            .read(pendingOrderStoreProvider)
            .write(record.copyWith(stage: PendingOrderStage.settled)),
      );
      return const CheckoutFlowState();
    }

    // The sheet had already succeeded (the triple is on disk) when this app
    // stopped. NOTHING here may say nothing was charged.
    return CheckoutFlowState(
      phase: CheckoutPhase.verifying,
      orderId: orderId,
      serverTotal: record.totalAmount,
      pending: record,
      message: _interruptedPaymentMessage,
    );
  }

  /// Back to a blank slate. Does **not** touch the journal — a record survives
  /// until the order it names is settled or disproved.
  void reset() {
    if (!mounted) return;
    state = const CheckoutFlowState();
  }

  /// Creates the order, reconciles its total, collects the payment, and proves
  /// it landed.
  ///
  /// ## [shippingOptionKey] — how shipping is priced now
  ///
  /// The member key of the courier the customer selected, e.g.
  /// `"shiprocket_1016322646"`, straight from `shippingOptionKeyProvider`. It
  /// replaces the `shipping_amount` this method used to pass: the app no longer
  /// tells the server what delivery costs, it names the *quote* and the server
  /// prices it, exactly as the web checkout does.
  ///
  /// Never substitute a guess for a null one — not `"shiprocket_<courierCompanyId>"`,
  /// not `shipping_method: "default"`, not a resurrected `shipping_amount`. All
  /// three miss the server's lookup and bill 0.00 on an order that is otherwise
  /// completely normal. The repository refuses a missing or malformed key
  /// outright ([CheckoutShippingUnpriced]) rather than letting one through.
  ///
  /// ## [shownTotal] — the figure this attempt is measured against
  ///
  /// The amount printed on the Place order button at the moment it was tapped,
  /// which is `OrderSummary.payable`. Because the server prices shipping for
  /// itself, its total can differ from that figure in **either** direction, and
  /// the order is created before the app can find out. So the response is
  /// reconciled against this number before the Razorpay sheet is allowed to
  /// open: a difference over [TotalDivergence.tolerance] parks the flow in
  /// [CheckoutPhase.totalChanged] with nothing charged, and the customer either
  /// [acceptServerTotal] or [declineServerTotal].
  ///
  /// Required-but-nullable on purpose. Null means "the customer was shown no
  /// total at all", which the checkout button prevents by staying dead until a
  /// courier has quoted; there is then no claim to contradict and no
  /// reconciliation to do. Making it required stops a caller from omitting it
  /// and silently losing the check.
  ///
  /// ## [shownShipping] — the courier rate inside that figure
  ///
  /// The delivery line the bill printed, required-but-nullable for the same
  /// reason. It is what lets a server shipping line of **0.00** be recognised as
  /// a fault rather than as a free delivery — see
  /// [TotalDivergence.isShippingMissing], which a Shiprocket outage on the
  /// server's own re-quote produces just as readily as a missed option key.
  ///
  /// ## [billingAddress] — null means "same as delivery"
  ///
  /// Not an omission but a statement, and the repository turns it into the
  /// explicit `billing_address_same_as_shipping_address: "1"` the server's
  /// validator needs. See `CheckoutRepository.placeOrder` for why leaving that
  /// flag out is a 422 waiting to happen.
  ///
  /// ## [taxInformation] — the GST invoice block
  ///
  /// Collected in the cart, carried here so the order can be raised against a
  /// company. Refused before the POST for the same reason the address is: the
  /// server takes an incomplete block and stores it.
  Future<void> placeOrder({
    required String cartId,
    required CheckoutAddress address,
    required double? shownTotal,
    required double? shownShipping,
    String? shippingOptionKey,
    String? notes,
    CheckoutAddress? billingAddress,
    TaxInformation? taxInformation,
  }) async {
    if (state.isBusy) return;

    // An order already exists (or may), including one rehydrated from the
    // journal on a fresh launch. Every route out of that state is *pay the
    // order that is already there* — [retryPayment], [acceptServerTotal], or an
    // explicit [startOver] — and a second POST here would be a second real
    // order, a second Razorpay order and another coupon use. The screen keeps
    // its Place order button off for the same reason; this is the guard that
    // does not depend on a screen getting it right.
    if (state.orderMayExist) return;

    if (cartId.trim().isEmpty) {
      state = const CheckoutFlowState(
        phase: CheckoutPhase.refused,
        message: 'Your cart is no longer available. Please add the items again.',
      );
      return;
    }

    // Checked here as well as in the repository so the form can paint its
    // errors without a request having been considered at all.
    final problems = address.violations();
    if (problems.isNotEmpty) {
      state = CheckoutFlowState(
        phase: CheckoutPhase.refused,
        message: CheckoutAddressRules.firstProblem(problems),
        fieldErrors: problems,
      );
      return;
    }

    // The billing address gets the same treatment, and it matters more than it
    // looks: `OrderHelper::storeOrderBillingAddress` re-validates it against
    // these same web rules and, on failure, does a bare `return`. The order is
    // written, HTTP 200 comes back, and the billing address is gone — so a
    // refusal here is the only thing that can tell the customer.
    final billingProblems = billingAddress?.violations() ?? const {};
    if (billingProblems.isNotEmpty) {
      state = CheckoutFlowState(
        phase: CheckoutPhase.refused,
        message: 'Billing address: '
            '${CheckoutAddressRules.firstProblem(billingProblems)}',
        // Deliberately NOT merged into `fieldErrors`: that bag paints the
        // *delivery* form, and a billing-only problem would light up the wrong
        // fields two sections up.
      );
      return;
    }

    final taxProblems = taxInformation?.violations() ?? const {};
    if (taxProblems.isNotEmpty) {
      state = CheckoutFlowState(
        phase: CheckoutPhase.refused,
        message: 'GST details: ${TaxInformation.firstProblem(taxProblems)}',
      );
      return;
    }

    state = const CheckoutFlowState(phase: CheckoutPhase.placing);

    // The record goes down BEFORE the network call. If the process dies during
    // the POST, this is all that says an order might exist — and the recovery
    // pass will say so rather than silently losing it.
    var record = PendingOrder(
      cartId: cartId,
      stage: PendingOrderStage.created,
      createdAt: DateTime.now(),
      customerEmail: address.email,
      customerPhone: address.phone,
    );
    try {
      await _store.write(record);
    } on Object catch (e, s) {
      // Nothing has left the device yet, so nothing exists, and refusing is the
      // safe direction: sending the POST without the journal behind it means a
      // crash during it loses the order outright, and no read endpoint can find
      // an unfinished one.
      ErrorLog.capture(e, stackTrace: s, context: 'checkout.journal.open');
      if (!mounted) return;
      state = const CheckoutFlowState(
        phase: CheckoutPhase.refused,
        message: 'We could not start your order on this device. Please try '
            'again — nothing has been sent and nothing has been charged.',
      );
      return;
    }
    if (!mounted) return;
    state = state.copyWith(pending: record);

    final PlaceOrderOutcome outcome;
    try {
      outcome = await _repo.placeOrder(
        cartId: cartId,
        address: address,
        shippingOptionKey: shippingOptionKey,
        notes: notes,
        billingAddress: billingAddress,
        taxInformation: taxInformation?.toJson(),
      );
    } on Object catch (e, s) {
      // The repository documents that it never throws except ArgumentError, and
      // both of those cases are guarded above — but an order may exist by now,
      // so anything unexpected degrades to "unknown" rather than escaping as an
      // exception that would strand the screen on a spinner.
      ErrorLog.capture(e, stackTrace: s, context: 'checkout.placeOrder');
      if (!mounted) return;
      state = state.copyWith(
        phase: CheckoutPhase.unresolved,
        message: _unknownMessage,
      );
      return;
    }
    if (!mounted) return;

    // *** R3. ***
    //
    // The try/catch above covered the repository call and nothing else, so every
    // await that runs once an order EXISTS — the journal write, the cart
    // discard, the checkout reset, the confirm-payment staging — was bare. A
    // [SharedPreferences] failure in any of them (full disk, corrupt prefs
    // file, platform channel torn down under a backgrounded app) escaped this
    // notifier, and the screen awaiting `placeOrder` painted it as a checkout
    // that failed — over a real order that may already have been paid for.
    await _neverStrand(
      'checkout.placeOrder.outcome',
      () => _applyOutcome(
        outcome: outcome,
        record: record,
        shownTotal: shownTotal,
        shownShipping: shownShipping,
      ),
    );
  }

  /// Everything that happens once `POST /checkout/cart/{id}` has answered.
  ///
  /// Split out of [placeOrder] so the whole of it — not just the network call —
  /// runs inside [_neverStrand].
  Future<void> _applyOutcome({
    required PlaceOrderOutcome outcome,
    required PendingOrder record,
    required double? shownTotal,
    required double? shownShipping,
  }) async {
    switch (outcome) {
      case CheckoutAddressRejected(:final address):
        // Unreachable — the same check ran above — but the compiler requires
        // the case, and a silent fallthrough would spin forever.
        await _store.clear();
        if (!mounted) return;
        state = CheckoutFlowState(
          phase: CheckoutPhase.refused,
          message: CheckoutAddressRules.firstProblem(address),
          fieldErrors: address,
        );

      case CheckoutRefused(:final error, :final message, :final orderMayExist):
        // A 4xx is raised before the first write, so nothing exists and the
        // record is a lie worth deleting. A 5xx is not: the controller runs no
        // transaction, so the order row, its histories, its shipment and the
        // coupon's `total_used++` may all be committed already.
        if (!orderMayExist) {
          await _store.clear();
          if (!mounted) return;
        } else {
          // A 5xx here is a normal *return value* of `placeOrder`, not a
          // thrown exception — so it never reached the `catch` a few lines up,
          // and until this line it was never logged anywhere. The customer
          // only ever sees `message`, which is already the display-safe
          // fallback ("The server had a problem") whenever the server's own
          // sentence looked like a stack trace or a raw exception rather than
          // customer wording — exactly the case worth seeing in full to
          // diagnose. `ErrorLog.capture` prints `error.serverMessage` (the
          // unfiltered original) and the rest of `developerDetail` to the
          // dev log, debug/profile builds only.
          ErrorLog.capture(error, context: 'checkout.placeOrder.refused');
        }
        state = CheckoutFlowState(
          phase:
              orderMayExist ? CheckoutPhase.unresolved : CheckoutPhase.refused,
          message: orderMayExist ? '$message $_unknownSuffix' : message,
          fieldErrors: _bareAddressErrors(error),
          pending: orderMayExist ? record : null,
        );

      case CheckoutShippingUnpriced(:final message):
        // Nothing was sent, so nothing exists — same disposal as a 4xx. The
        // caller passed no usable `shipping_option`, which is a bug in the
        // screen's gating rather than something the customer did; the wording
        // still has to be one they can act on.
        await _store.clear();
        if (!mounted) return;
        state = CheckoutFlowState(
          phase: CheckoutPhase.refused,
          message: message,
        );

      case CheckoutOutcomeUnknown(:final error):
        // Same reasoning as the `CheckoutRefused` branch above: this is a
        // normal outcome of `placeOrder`, not a thrown exception, so nothing
        // else on this path logs it.
        ErrorLog.capture(error, context: 'checkout.placeOrder.unknown');
        state = state.copyWith(
          phase: CheckoutPhase.unresolved,
          message: error.message,
        );

      case OrderPlaced(:final order):
        final placed = record.withOrder(order);

        // The reconciliation, made once and stored, so the screen renders a
        // comparison rather than performing one.
        final divergence = shownTotal == null
            ? null
            : TotalDivergence.between(
                shown: shownTotal,
                shownShipping: shownShipping,
                order: order,
              );

        // In memory first. It cannot fail, and it is what tells the screen —
        // and [_neverStrand], if the write below throws — that an order EXISTS.
        state = state.copyWith(
          pending: placed,
          orderId: order.orderId,
          // `displayCode`, not the raw column: a quarter of this shop's orders
          // store the code with a leading `#`. Null unless the server sent one,
          // and then the card falls back to a description rather than the id.
          orderCode: order.displayCode,
          serverTotal: order.totalAmount.display,
          divergence: divergence,
        );

        // Order id and token persisted IMMEDIATELY — before the SDK, before any
        // navigation, before anything else that could fail.
        await _store.write(placed);
        if (!mounted) return;

        // No `razorpay` block means the order was finalised inside the checkout
        // call — a zero-amount order, or an install with the payment plugin
        // off. Opening the sheet would charge for something already paid for,
        // and confirm-payment would 422 on the replay guard.
        //
        // Checked BEFORE the divergence gate on purpose: there is no sheet to
        // withhold here and no money to collect, so parking the flow would
        // strand a finished order behind a question about a payment that is
        // never going to happen.
        if (!order.requiresPayment) {
          await _settle(placed);
          return;
        }

        // *** The gate this whole slice exists for. ***
        //
        // The order is real and unpaid, and the server's total is not the one
        // on the button. The SDK is NOT opened: the customer sees both figures
        // and decides. Nothing has been charged at this point and nothing will
        // be until [acceptServerTotal].
        //
        // ⚠ TEMPORARY — see docs/TODO_CANCELLED_PAYMENT_FLOW.md. Disabled for
        // the client demo: the sheet opens straight at the SERVER's amount
        // (`_collectPayment` uses `data.razorpay.amount`, never the button's
        // figure), so the customer is charged the real total either way — they
        // are just no longer asked about the difference first. Re-enable in
        // the permanent pass.
        const askAboutDivergence = false;
        // ignore: dead_code
        if (askAboutDivergence && divergence != null && divergence.isMaterial) {
          state = state.copyWith(
            phase: CheckoutPhase.totalChanged,
            message: _divergenceMessage(divergence),
            pending: placed,
          );
          return;
        }

        await _collectPayment(placed);
    }
  }

  /// Runs [body] so that no failure inside it can ever be shown as "your order
  /// was not placed".
  ///
  /// Everything this wraps runs *after* the checkout POST has been answered, so
  /// the order either exists or may exist. The two honest degradations are
  /// therefore [CheckoutPhase.verifying] — an order this app can name, whose
  /// payment state it can no longer prove — and [CheckoutPhase.unresolved] —
  /// an order it cannot even name. Neither offers Place order, neither shows a
  /// receipt, and neither discards the journal record or the basket.
  Future<void> _neverStrand(String context, Future<void> Function() body) async {
    try {
      await body();
    } on Object catch (e, s) {
      ErrorLog.capture(e, stackTrace: s, context: context);
      if (!mounted) return;
      final orderId = state.orderId;
      state = state.copyWith(
        phase:
            state.hasOrder ? CheckoutPhase.verifying : CheckoutPhase.unresolved,
        message: state.hasOrder
            ? 'Order $orderId was placed, but this app could not finish '
                'recording it, so we cannot tell you here whether it has been '
                'paid for. Please check My orders rather than ordering again, '
                'and quote that number if you contact us.'
            : _unknownMessage,
      );
    }
  }

  /// The customer accepted the server's figure.
  ///
  /// Opens the sheet for the order that already exists, at the server's amount
  /// — [PendingOrder.amountPaise] is `data.razorpay.amount`, which the server
  /// derived from the very `total_amount` that was just shown to them. No
  /// second checkout POST, so no second order.
  Future<void> acceptServerTotal() async {
    if (state.phase != CheckoutPhase.totalChanged) return;
    final record = state.pending ?? _store.read();
    if (record == null) {
      state = state.copyWith(
        phase: CheckoutPhase.verifying,
        message: 'We could not reopen the payment. Please check your orders '
            'before trying again.',
      );
      return;
    }
    await _neverStrand(
      'checkout.acceptServerTotal',
      () => _collectPayment(record),
    );
  }

  /// The customer refused the server's figure.
  ///
  /// **Nothing was charged** — the Razorpay sheet was never opened. But the
  /// order *was* created, and saying otherwise would be the same lie in the
  /// other direction, so this lands in [CheckoutPhase.paymentIncomplete]: the
  /// journal record survives (it is the only handle on an unfinished order), the
  /// cart survives, and the same Razorpay order can still be paid later.
  void declineServerTotal() {
    if (state.phase != CheckoutPhase.totalChanged) return;
    final orderId = state.orderId;
    state = state.copyWith(
      phase: CheckoutPhase.paymentIncomplete,
      message: 'Nothing has been charged. '
          '${orderId == null ? 'Your order' : 'Order $orderId'} was created and '
          'is unpaid, and your basket is untouched — pay the updated total when '
          "you're ready, or leave it: an unpaid order is never dispatched, and "
          'you can cancel it yourself from My orders once it appears there.',
    );
  }

  /// Abandons an unpaid order so the customer can check out again.
  ///
  /// ## Why this exists
  ///
  /// [declineServerTotal] used to be a one-way door. It parks the flow in
  /// [CheckoutPhase.paymentIncomplete], every button from there is *pay the
  /// order that already exists*, and [reset] is called from nowhere the customer
  /// can reach — so someone who refuses the server's total can never place
  /// another order, in this session or any later one, because
  /// [checkoutFlowProvider] outlives the screen.
  ///
  /// ## What it does and does not touch
  ///
  /// Only the in-memory flow. The basket stays, because it is the customer's
  /// and they are about to use it. **The journal record stays too** — it is the
  /// only handle on an order `GET /orders` cannot see, and dropping it here
  /// would lose the order the moment the customer walked away.
  ///
  /// That record is nonetheless overwritten by the *next* [placeOrder], which
  /// is why the caller must ask first: the second order is real, the first stays
  /// unpaid, and the customer needs the number before it goes. Until they do
  /// place that second order, [PendingOrderRecoveryNotifier] still finds the
  /// first one on the next launch and still reports it truthfully.
  void startOver() {
    if (!mounted) return;
    if (!state.canStartOver) return;
    state = const CheckoutFlowState();
  }

  /// The sentence that goes with [CheckoutPhase.totalChanged].
  ///
  /// Names both figures, in the server's own rendering for the one being
  /// charged. Neither low-total wording reads as good news: a delivery line that
  /// came back 0.00 means the shipment carries no courier metadata — the
  /// `shipping_option` lookup missed, or Shiprocket was down when the server
  /// re-quoted and `HookServiceProvider` swallowed it — and nobody can dispatch
  /// it.
  static String _divergenceMessage(TotalDivergence divergence) {
    final shown = PriceUtils.format(divergence.shown);
    if (divergence.isShippingMissing) {
      final quoted = PriceUtils.format(divergence.shownShipping!);
      return 'No delivery charge reached this order. It was billed '
          '${divergence.shippingDisplay} for shipping, not the $quoted this '
          'parcel was quoted, so its total is ${divergence.chargedDisplay} '
          'instead of $shown. An order with no courier on it cannot be '
          'dispatched.';
    }
    if (divergence.isUndercharge) {
      return 'Shipping was recalculated. Your total is '
          '${divergence.chargedDisplay} — you were shown $shown. The lower '
          'figure means the delivery charge did not reach this order, so it '
          'may not be dispatchable.';
    }
    return 'Shipping was recalculated. Your total is '
        '${divergence.chargedDisplay} — you were shown $shown.';
  }

  /// Reopens the sheet for the order that already exists.
  ///
  /// The stored [PaymentRequest] is reused deliberately: building a fresh one
  /// would mean another `POST /checkout/cart/{id}`, which is another order,
  /// another Razorpay order and another coupon use — for a basket the customer
  /// is trying to pay for once.
  ///
  /// Refused outright on a record whose payment may already have gone through.
  /// The screen keeps the button off in that state, but "do not invite a second
  /// payment" is too expensive a rule to leave to a screen: the journal is the
  /// authority, and it is consulted here.
  Future<void> retryPayment() async {
    if (state.isBusy) return;
    final record = state.pending ?? _store.read();
    if (record != null && record.paymentMayHaveHappened) {
      state = state.copyWith(
        phase: CheckoutPhase.verifying,
        message: _interruptedPaymentMessage,
        pending: record,
      );
      return;
    }
    if (record == null || record.toPaymentRequest() == null) {
      state = state.copyWith(
        phase: CheckoutPhase.verifying,
        message: 'We could not reopen the payment. Please check your orders or '
            'contact support before trying again.',
      );
      return;
    }
    state = state.copyWith(pending: record);
    await _neverStrand('checkout.retryPayment', () => _collectPayment(record));
  }

  // ---- payment -----------------------------------------------------------

  Future<void> _collectPayment(PendingOrder record) async {
    final request = record.toPaymentRequest();
    if (request == null) {
      // The server said money was due and then did not say how to collect it.
      state = state.copyWith(
        phase: CheckoutPhase.verifying,
        message: 'This order could not be sent for payment. Please contact '
            'support with order ${record.orderId ?? ''}.',
        pending: record,
      );
      return;
    }

    // *** R4. The sheet may not open at a figure nobody was shown. ***
    //
    // The divergence sheet's Continue button names `data.total_amount`; the SDK
    // is opened at `data.razorpay.amount`. Server-side the second is
    // `(int) round($order->amount * 100)` of the first, so they are one figure
    // in two units — and nothing in this app compared them until here. If they
    // ever disagree, the sheet does not open: money that has not moved cannot be
    // taken back, and there is no honest way to charge a number the customer
    // never saw.
    if (!record.sheetAmountMatchesTotal) {
      state = state.copyWith(
        phase: CheckoutPhase.verifying,
        message: 'We could not confirm the amount to charge for '
            '${_orderPhrase(record.orderId)}. '
            '${_nothingChargedYet(record)}Please contact support with that '
            'number rather than paying again.',
        pending: record,
      );
      return;
    }

    // *** R2. The stage goes to disk BEFORE the sheet opens. ***
    //
    // Without this the journal cannot tell "killed with the checkout POST in
    // flight" from "killed while the customer was in their UPI app". The second
    // is the one that matters: the bank debits, Razorpay captures, the callback
    // never arrives — and the launch pass then told the customer, in those
    // words, that nothing was charged, and deleted the record three days later.
    final opening = record.copyWith(stage: PendingOrderStage.paymentOpened);
    await _store.write(opening);
    if (!mounted) return;

    state =
        state.copyWith(phase: CheckoutPhase.awaitingPayment, pending: opening);
    final result = await _gateway.pay(request);
    if (!mounted) return;

    // Debug only. There is no crash report or analytics event for which
    // `PaymentResult` variant the SDK actually returned, so a "the order
    // placed even though I cancelled" report has nothing to check against —
    // in Razorpay TEST MODE (`rzp_test_...`, which this backend runs), most
    // test UPI/card flows resolve to a genuine `PaymentSuccess` in one tap,
    // and a customer who dismisses a screen a beat later may be dismissing the
    // SUCCESS confirmation, not cancelling a payment. This line is how to tell
    // the two apart on the next run without instrumenting anything new.
    if (kDebugMode) {
      debugPrint('[checkout] Razorpay result for order ${opening.orderId}: '
          '$result');
    }

    switch (result) {
      case PaymentSuccess(:final paymentId, :final signature):
        // The whole recovery story: the triple is on disk BEFORE the request
        // that uses it leaves the device.
        final proved = opening.copyWith(
          stage: PendingOrderStage.sdkSuccess,
          razorpayPaymentId: paymentId,
          razorpaySignature: signature,
        );
        await _store.write(proved);
        if (!mounted) return;
        state = state.copyWith(pending: proved);
        await _confirm(proved);

      case PaymentCancelled():
        // ⚠ TEMPORARY BEHAVIOUR — see `docs/TODO_CANCELLED_PAYMENT_FLOW.md`
        // for what this replaced and how the permanent version should work.
        //
        // Interim product decision (client demo): a dismissed sheet abandons
        // the order outright instead of parking the flow at
        // `paymentIncomplete` with a retry + "Start a new order" pair. The
        // journal record is settled — this is safe to do ONLY here, because
        // `PaymentCancelled` is the SDK's own report that the sheet closed
        // without a payment, the same evidence `sheetNeverOpened` rests on —
        // and the screen pops back to the cart, where the next checkout
        // creates a fresh order for whatever the basket then holds.
        //
        // The abandoned order itself is untouched server-side: pending,
        // unpaid, invisible to both order reads (`is_finished = 1` filters).
        // There is no delete/cancel call that is safe to make — cancelling an
        // unfinished order over-credits stock (`BACKEND_BUGS.md` §22).
        final abandoned =
            opening.copyWith(stage: PendingOrderStage.settled);
        await _store.write(abandoned);
        if (!mounted) return;
        state = CheckoutFlowState(
          phase: CheckoutPhase.cancelledBackToCart,
          pending: abandoned,
        );

      case PaymentFailed(:final code, :final message):
        // Three codes mean the payment state is genuinely unknown rather than
        // failed: the SDK returned a partial triple, returned one belonging to
        // a different Razorpay order, or never answered at all. Reopening the
        // sheet for any of them risks a second charge.
        final unknown = code == PaymentFailureCodes.incompleteSuccess ||
            code == PaymentFailureCodes.orderMismatch ||
            code == PaymentFailureCodes.noResponse;
        // A named provider failure is the SDK telling us no money moved, so the
        // record goes back to `created`. An unknown one is not, so it stays at
        // `paymentOpened` and every later reader keeps saying "we do not know".
        final after = unknown
            ? opening
            : opening.copyWith(stage: PendingOrderStage.created);
        await _store.write(after);
        if (!mounted) return;
        state = state.copyWith(
          phase: unknown
              ? CheckoutPhase.verifying
              : CheckoutPhase.paymentIncomplete,
          message: unknown
              ? "We couldn't confirm whether your payment went through. Please "
                  'check your orders before paying again.'
              : message,
          pending: after,
        );
    }
  }

  Future<void> _confirm(PendingOrder record) async {
    final orderId = record.orderId;
    if (orderId == null || orderId <= 0) {
      state = state.copyWith(
        phase: CheckoutPhase.verifying,
        message: _verifyMessage,
        pending: record,
      );
      return;
    }

    final sent = record.copyWith(stage: PendingOrderStage.confirmSent);
    await _store.write(sent);
    if (!mounted) return;
    state = state.copyWith(phase: CheckoutPhase.confirming, pending: sent);

    final outcome = await _repo.confirmPayment(
      orderId: orderId,
      razorpayPaymentId: sent.razorpayPaymentId ?? '',
      razorpayOrderId: sent.razorpayOrderId ?? '',
      razorpaySignature: sent.razorpaySignature ?? '',
    );
    if (!mounted) return;

    switch (outcome) {
      case PaymentConfirmed(:final order):
        // Believed, and still proved below: the server never checks that the
        // payment it verified belongs to the order it is confirming.
        await _settle(sent.withOrder(order), verify: true);

      case PaymentNotReceived():
        // HTTP 200, `success: true`, and the money did not land — the server
        // finalises the order either way. Never a success screen.
        state = state.copyWith(
          phase: CheckoutPhase.verifying,
          message: _verifyMessage,
          pending: sent,
        );

      case PaymentAlreadyProcessed():
        // The replay guard runs BEFORE signature verification, so this says
        // nothing about payment. Go and look.
        await _reconcile(sent);

      case PaymentConfirmationRejected(:final message):
        state = state.copyWith(
          phase: CheckoutPhase.verifying,
          message: '$message $_verifySuffix',
          pending: sent,
        );

      case PaymentConfirmationUnresolved():
        state = state.copyWith(
          phase: CheckoutPhase.verifying,
          message: _verifyMessage,
          pending: sent,
        );
    }
  }

  /// `GET /orders/{id}` — the only field in this whole flow that means "paid".
  Future<void> _reconcile(PendingOrder record) async {
    final orderId = record.orderId;
    if (orderId == null || orderId <= 0) {
      state = state.copyWith(
        phase: CheckoutPhase.verifying,
        message: _verifyMessage,
        pending: record,
      );
      return;
    }

    state = state.copyWith(phase: CheckoutPhase.confirming, pending: record);
    final paid = await lookUpPayment(_ref, orderId);
    if (!mounted) return;

    if (paid == OrderPaymentLookup.paid) {
      await _settle(record);
      return;
    }
    state = state.copyWith(
      phase: CheckoutPhase.verifying,
      message: _verifyMessage,
      pending: record,
    );
  }

  // ---- settling ----------------------------------------------------------

  /// The **only** path that touches the cart.
  ///
  /// [verify] re-reads `GET /orders/{id}` first. Confirm-payment's own 200 is
  /// evidence about a Razorpay order, not proof about this one — the only
  /// binding server-side is `Order.user_id == you` — so a receipt is not drawn
  /// on it alone. A read that fails does **not** block the success screen: the
  /// signature verified and the server reported the Razorpay order paid, which
  /// is enough to stop nagging a customer whose money has gone.
  ///
  /// Order of operations matters. The journal is cleared first, so a crash
  /// mid-cleanup cannot leave a record that sends the next launch chasing an
  /// order that is already done. The cart id and its rebuild mirror go next,
  /// then the checkout inputs.
  Future<void> _settle(PendingOrder record, {bool verify = false}) async {
    if (verify && record.isIdentified) {
      state = state.copyWith(phase: CheckoutPhase.confirming, pending: record);
      final paid = await lookUpPayment(_ref, record.orderId!);
      if (!mounted) return;
      if (paid == OrderPaymentLookup.notPaid) {
        state = state.copyWith(
          phase: CheckoutPhase.verifying,
          message: _verifyMessage,
          pending: record,
        );
        return;
      }
    }

    await _store.clear();
    // Discards the cart id AND the rebuild mirror. Doing this anywhere else
    // would orphan a live server cart and destroy the record of how to rebuild
    // it — which is exactly what the old fake "place order" did on every tap.
    // The cart the order consumed — the throwaway one on a Buy now, so a paid
    // shortcut never empties the basket the customer has been filling.
    await _ref.read(activeCartNotifierProvider).forget();
    _ref.read(checkoutProvider.notifier).reset();
    if (!mounted) return;
    state = CheckoutFlowState(
      phase: CheckoutPhase.paid,
      orderId: record.orderId,
      serverTotal: record.totalAmount,
      pending: record.copyWith(stage: PendingOrderStage.settled),
    );
  }

  // ---- wording -----------------------------------------------------------

  static const String _unknownMessage =
      'Your order may have been placed. Please check your orders before trying '
      'again — placing it a second time would create a duplicate.';

  static const String _unknownSuffix =
      'Your order may still have been created — please check your orders '
      'before trying again.';

  static const String _verifyMessage =
      "We're verifying your payment. Your order is saved, and we will update it "
      'as soon as the payment is confirmed.';

  static const String _verifySuffix =
      'Please contact support with your order number rather than paying again.';

  /// What a customer is told when the app was killed with the sheet open.
  ///
  /// The one sentence this file exists to get right. The payment may have
  /// succeeded — the bank debits and Razorpay captures whether or not this
  /// process lives to hear about it — so the app says it does not know and is
  /// checking. It must never say nothing was charged here, and it must never
  /// invite a second payment.
  static const String _interruptedPaymentMessage =
      'Your payment was interrupted before we heard back, so we do not yet know '
      'whether it went through. Your order is saved and we are checking. '
      'Please do not pay for it again — check My orders, or contact support '
      'with your order number.';

  /// "Order 1287", or "this order" when the id was never learnt.
  static String _orderPhrase(int? orderId) =>
      orderId == null || orderId <= 0 ? 'this order' : 'order $orderId';

  /// The sentence "Nothing has been charged.", **only** when the journal proves
  /// it — see [PendingOrder.sheetNeverOpened]. Empty otherwise, so a message
  /// built from it degrades to saying nothing about the money rather than to
  /// saying something false about it.
  static String _nothingChargedYet(PendingOrder record) =>
      record.sheetNeverOpened ? 'Nothing has been charged. ' : '';

  /// Re-keys the server's own 422 bag (`address.name`) to bare field names, so
  /// a form can look one up the same way it looks up
  /// [CheckoutAddressRejected.address].
  static Map<String, String> _bareAddressErrors(ApiException error) {
    final bag = error.fieldErrors;
    if (bag == null) return const {};
    const prefix = 'address.';
    final out = <String, String>{};
    for (final entry in bag.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      if (entry.value.isEmpty || entry.value.first.isEmpty) continue;
      out[entry.key.substring(prefix.length)] = entry.value.first;
    }
    return out;
  }
}

/// The place-order flow.
///
/// Not autoDispose: it has to outlive a rebuild while the Razorpay sheet is up,
/// and its state is what tells a returning screen that an order is sitting there
/// waiting to be paid for.
final checkoutFlowProvider =
    StateNotifierProvider<CheckoutFlowNotifier, CheckoutFlowState>(
  CheckoutFlowNotifier.new,
);

// ===========================================================================
// Recovering an order the app lost sight of
// ===========================================================================

/// What the launch-time reconciliation found.
enum PendingRecoveryPhase {
  /// Nothing to do — no record, or one already settled.
  idle,

  /// A lookup is in flight.
  checking,

  /// The order was paid after all. [PendingRecoveryState.orderId] names it, and
  /// the cart has been cleared.
  paid,

  /// The record was let go. Either it never named an order, or it named one
  /// that could not be resolved inside [PendingOrderRecoveryNotifier.staleAfter].
  /// The cart is untouched, and the customer is always told — this is never a
  /// silent disposal.
  dropped,

  /// **The order exists and has not been paid for.** Nothing was charged, the
  /// basket is untouched, and the record is KEPT.
  ///
  /// This is the state a cancelled payment leaves behind, and it used to be
  /// reported as [dropped] with the sentence "it was not placed" — the exact
  /// opposite of what checkout had just told the same customer, and it threw
  /// away the only handle on the order while doing it. Both order reads filter
  /// `is_finished = 1`, so a 404 for an id the checkout response gave us means
  /// *not finalised*, never *not created*.
  unpaid,

  /// **Nobody knows yet whether the money moved.**
  ///
  /// Three shapes land here, and they share the only response that is honest
  /// for all of them — keep the record, point at support, never invite a second
  /// payment:
  ///
  ///   * the order is finished and its payment status is not `completed`;
  ///   * the order could not be read at all;
  ///   * the app was killed with the payment sheet open
  ///     ([PendingOrderStage.paymentOpened]), so `is_finished` is still 0 and a
  ///     404 says nothing about the debit.
  needsSupport,
}

class PendingRecoveryState {
  const PendingRecoveryState({
    this.phase = PendingRecoveryPhase.idle,
    this.orderId,
    this.message,
  });

  final PendingRecoveryPhase phase;
  final int? orderId;

  /// Set for every outcome the customer must be told about. Null for
  /// [PendingRecoveryPhase.idle] and [PendingRecoveryPhase.checking], which are
  /// silent, and cleared by [PendingOrderRecoveryNotifier.acknowledge].
  final String? message;

  bool get hasNews => message != null;
}

/// Finishes, or lets go of, an order left behind by a previous run.
///
/// Runs once, from its own constructor, so whichever screen watches this
/// provider first starts it. It is watched by the gate wrapped around the root
/// route, which makes it a launch-time pass.
///
/// The outcomes follow the payment contract exactly:
///
///   * **paid** — show the success screen, discard the cart, drop the record;
///   * **404 with a stored triple** — the app died between the sheet and
///     confirm-payment. Re-send the triple (safe: the endpoint has a replay
///     guard and re-verifies the signature), then look again;
///   * **404 with the sheet recorded as open** — the app was killed while the
///     customer was in their bank or UPI app. The debit and the capture happen
///     whether or not this process lives to hear about it, so nothing is
///     asserted about the money: say it is being checked, **keep the record for
///     as long as that is true** (it is never dropped for age), and never invite
///     a second payment;
///   * **404 with no triple and the sheet provably never opened** — the payment
///     never happened and nothing was charged, but the order **does exist**:
///     both order reads filter `is_finished = 1`, so a 404 for an id the
///     checkout response handed us is "not finalised", not "not created". Say
///     exactly that, **keep the record** — it is the only handle on an order no
///     read endpoint can see — and leave the cart alone so they can simply order
///     again. The record is let go only once it is [staleAfter] old, and it says
///     so when it does;
///   * **finished but unpaid, or unreadable** — keep the record and route to
///     support. This is the one case where retrying anything makes it worse.
class PendingOrderRecoveryNotifier extends StateNotifier<PendingRecoveryState> {
  PendingOrderRecoveryNotifier(this._ref)
      : super(const PendingRecoveryState()) {
    unawaited(run());
  }

  final Ref _ref;

  /// A record that cannot be checked for this long is surfaced once and let go,
  /// rather than re-checked on every launch forever.
  static const Duration staleAfter = Duration(days: 3);

  bool _ran = false;

  /// Drops the news once it has been shown, so it is not shown twice.
  void acknowledge() {
    if (!mounted) return;
    state = PendingRecoveryState(phase: state.phase, orderId: state.orderId);
  }

  Future<void> run() async {
    if (_ran) return;
    _ran = true;
    try {
      await _reconcile();
    } on Object catch (e, s) {
      // This runs unawaited from the constructor, so anything escaping it is an
      // unhandled async error at launch. Nothing here has to succeed: the record
      // is left exactly where it was and the next launch tries again, which is
      // strictly better than losing the only handle on an unfinished order.
      ErrorLog.capture(e, stackTrace: s, context: 'checkout.recovery');
      if (!mounted) return;
      state = const PendingRecoveryState();
    }
  }

  Future<void> _reconcile() async {
    final store = _ref.read(pendingOrderStoreProvider);
    final record = store.read();
    if (record == null || record.stage == PendingOrderStage.settled) return;

    // The POST was never answered, so there is no id to look up — and nothing
    // this app can call will find the order if one was created. `GET /orders`
    // filters `is_finished = 1`, so an order left unpaid by a lost response is
    // invisible there *by construction*. Meanwhile the checkout endpoint runs no
    // transaction, so the order, its lines, its shipment, its address and the
    // coupon's `total_used` are all committed before the response the app never
    // received. An order existing is the *likely* case here, not the unlikely
    // one.
    //
    // This record is therefore the only trace of it anywhere on the device. It
    // used to be cleared right here, which threw away the app's one
    // duplicate-order guard in precisely the situation where a duplicate is most
    // likely — and told the customer to "check your orders before ordering
    // again", an instruction that cannot succeed.
    //
    // So: keep it, say only what is true, and let the customer out through
    // `startOver`, which does not ask them to certify the order is absent.
    if (!record.isIdentified) {
      if (DateTime.now().difference(record.createdAt) > staleAfter) {
        // Let go eventually, the same way the `notFinished` branch does, or an
        // interrupted checkout announces itself on every launch forever.
        // Announced on the way out, never dropped in silence.
        await store.clear();
        if (!mounted) return;
        state = const PendingRecoveryState(
          phase: PendingRecoveryPhase.dropped,
          message: 'We have stopped tracking a checkout that was interrupted a '
              'few days ago. If you were charged for an order you never '
              'received, please contact us.',
        );
        return;
      }
      state = const PendingRecoveryState(
        phase: PendingRecoveryPhase.needsSupport,
        message: 'Your last checkout was cut off before we heard back, so we do '
            'not know whether an order was created. Nothing was charged — '
            'payment never started. Please check with us before ordering the '
            'same basket again. Your basket is still here.',
      );
      return;
    }

    state = const PendingRecoveryState(phase: PendingRecoveryPhase.checking);
    final orderId = record.orderId!;

    var result = await lookUpPayment(_ref, orderId);

    // The crash-between-the-sheet-and-confirm-payment fix. Only ever attempted
    // when the triple is on disk, which means the sheet really did succeed.
    if (result == OrderPaymentLookup.notFinished && record.hasPaymentProof) {
      await _ref.read(checkoutRepositoryProvider).confirmPayment(
            orderId: orderId,
            razorpayPaymentId: record.razorpayPaymentId!,
            razorpayOrderId: record.razorpayOrderId!,
            razorpaySignature: record.razorpaySignature!,
          );
      if (!mounted) return;
      result = await lookUpPayment(_ref, orderId);
      if (!mounted) return;
    }

    switch (result) {
      case OrderPaymentLookup.paid:
        await store.clear();
        await _ref.read(activeCartNotifierProvider).forget();
        _ref.read(checkoutProvider.notifier).reset();
        if (!mounted) return;
        state = PendingRecoveryState(
          phase: PendingRecoveryPhase.paid,
          orderId: orderId,
          message: 'Your last order went through.',
        );

      case OrderPaymentLookup.notFinished:
        // *** The order EXISTS. ***
        //
        // This branch is only reached for a record that carries an order id,
        // and that id came from a 200 on the checkout POST. Both order reads
        // filter `is_finished = 1`, so their 404 says "not finalised" — never
        // "not created". Saying "it was not placed" here told the customer the
        // opposite of what `declineServerTotal` had told them minutes earlier,
        // and clearing the record threw away the only handle on an order no
        // read endpoint can find.
        //
        // So: keep the record, and say what is true — created, unpaid, nothing
        // charged, will not be dispatched.

        // ...unless the journal says the payment sheet was open when this app
        // last stopped, in which case NONE of that is known. The customer taps
        // Continue, picks UPI, PhonePe foregrounds, Android kills the
        // backgrounded merchant app: the bank debits, Razorpay captures, and no
        // callback ever reaches this process. `is_finished` stays 0 because
        // confirm-payment never went out, so this branch is exactly where such
        // an order lands — and it used to tell that customer, in these words,
        // that nothing was charged, then delete the only record of it three
        // days later.
        //
        // ⚠ TEMPORARY — see docs/TODO_CANCELLED_PAYMENT_FLOW.md. The same
        // interim abandonment `CheckoutFlowNotifier._rehydrated` applies: a
        // sheet that was open with NO payment triple is settled silently
        // rather than announced on every launch. Deliberately after the
        // lookup, so an order that somehow finalised is still caught by the
        // `paid` branch above.
        if (record.stage == PendingOrderStage.paymentOpened &&
            !record.hasPaymentProof) {
          await store.write(record.copyWith(stage: PendingOrderStage.settled));
          if (!mounted) return;
          state = const PendingRecoveryState();
          return;
        }

        // A stored triple has already been re-sent above; reaching here with one
        // means even that did not finalise it. Either way the honest answer is
        // that we do not know yet, and the record stays for as long as that is
        // true.
        if (record.paymentMayHaveHappened) {
          state = PendingRecoveryState(
            phase: PendingRecoveryPhase.needsSupport,
            // Left null for the same reason as the unpaid branch below: the
            // gate turns a non-null id into a "View" action on `/order/{id}`,
            // which reads the very endpoint that just 404'd.
            message: 'We are still checking the payment for order $orderId. It '
                'was interrupted before we heard back, so we do not yet know '
                'whether you were charged — please do not pay for it again. '
                'Your basket is still here, and support can look it up by that '
                'number.',
          );
          return;
        }

        if (DateTime.now().difference(record.createdAt) > staleAfter) {
          // Let go eventually, or an order nobody is ever going to pay for
          // announces itself on every launch forever. Announced on the way out,
          // never dropped in silence.
          await store.clear();
          if (!mounted) return;
          state = PendingRecoveryState(
            phase: PendingRecoveryPhase.dropped,
            message: 'Order $orderId was never paid for, so it has not been '
                'dispatched and we have stopped tracking it. Your basket is '
                'still here.',
          );
          return;
        }
        state = PendingRecoveryState(
          phase: PendingRecoveryPhase.unpaid,
          // `orderId` is deliberately left null even though it is known and
          // named in the sentence. The recovery gate turns a non-null id into a
          // "View" action on `/order/{id}`, and that route reads the same
          // `is_finished = 1` endpoint that just 404'd — so the button would be
          // a dead end. The number is what the customer needs; the link is not
          // one we can honour yet.
          message: 'Order $orderId was created but has not been paid for, so '
              'nothing was charged and it will not be dispatched. Your basket '
              'is still here.',
        );

      case OrderPaymentLookup.notPaid:
        state = PendingRecoveryState(
          phase: PendingRecoveryPhase.needsSupport,
          orderId: orderId,
          message: 'We are still verifying the payment for order $orderId. '
              'Please contact support rather than ordering it again.',
        );

      case OrderPaymentLookup.unreachable:
        if (DateTime.now().difference(record.createdAt) > staleAfter &&
            // Never let go of a record whose payment may have been taken, however
            // old it is. Dropping it is what turns "we could not check" into "it
            // is gone", and this is the only handle on an order that is
            // invisible to every read endpoint until it finalises. It announces
            // itself on each launch until it is resolved, which is the correct
            // amount of noise for money that may have left a customer's account.
            record.sheetNeverOpened) {
          await store.clear();
          if (!mounted) return;
          state = PendingRecoveryState(
            phase: PendingRecoveryPhase.dropped,
            orderId: orderId,
            message: 'We could not check order $orderId. Please look it up in '
                'your orders.',
          );
          return;
        }
        // Kept silently: a failed read says nothing, and the record is the only
        // handle on the order.
        state = PendingRecoveryState(
          phase: PendingRecoveryPhase.needsSupport,
          orderId: orderId,
        );
    }
  }
}

/// Launch-time reconciliation. Watched by the gate around the root route, so it
/// runs once per app start.
final pendingOrderRecoveryProvider =
    StateNotifierProvider<PendingOrderRecoveryNotifier, PendingRecoveryState>(
  PendingOrderRecoveryNotifier.new,
);

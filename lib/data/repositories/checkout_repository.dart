import 'package:dio/dio.dart' show Options;

import '../../core/errors/api_exception.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/validation/address_rules.dart';
import '../models/placed_order.dart';

/// The address the order ships to, in the shape the checkout body wants.
///
/// A value object rather than a loose `Map` because this is the payload that
/// decides whether an order can be dispatched, and because the server will not
/// check it: `mobileCheckout` sets `created_order_id` before storing the
/// address, which sends `OrderHelper::createOrderAddress` down its
/// `firstOrNew -> fill -> save` branch — it returns before it ever builds the
/// validation rules. Whatever fits the lenient `CheckoutRequest` rules is
/// persisted verbatim.
///
/// So [violations] is the only gate, and it delegates to
/// [CheckoutAddressRules] — the rules live in exactly one file and this class
/// deliberately restates none of them.
class CheckoutAddress {
  const CheckoutAddress({
    required this.name,
    required this.email,
    required this.phone,
    required this.address,
    required this.city,
    required this.state,
    required this.zipCode,
    this.landmark = '',
    this.district = '',
    this.otherCity = '',
    this.country = CheckoutAddressRules.shipsToCountry,
  });

  final String name;
  final String email;

  /// Ten digits, no `+91`. See [CheckoutAddressRules.phonePattern] — this is the
  /// number the courier dials.
  final String phone;

  /// The street line. Capped at 120 by the web rules even though the API says
  /// 500.
  final String address;

  final String city;
  final String state;
  final String zipCode;

  /// Carried through from the saved address so the order ships to the same
  /// place the address book describes.
  ///
  /// Empty for a manually-typed checkout address — the picker does not collect
  /// these three, and an empty string is simply not sent.
  final String landmark;
  final String district;

  /// The town, when [city] is the literal `"other"`. Without it, an other-city
  /// address reaches the order with "other" where the town should be.
  final String otherCity;

  /// The shop ships nowhere else, so this is a default rather than a parameter
  /// the UI has to collect.
  final String country;

  /// Every strict-web-rule this address breaks, keyed by [AddressField]. Empty
  /// means it is safe to check out with.
  Map<String, String> violations() => CheckoutAddressRules.validate(
        name: name,
        phone: phone,
        email: email,
        address: address,
        city: city,
        state: state,
        zipCode: zipCode,
        country: country,
      );

  bool get isValid => violations().isEmpty;

  /// The `address` object of the checkout body.
  ///
  /// The eight keys the guide documents, plus the three optional parts a saved
  /// address can carry — `landmark`, `district` and `other_city` — which the
  /// server persists onto the order address. They are **omitted when empty**
  /// rather than sent blank, so a manually-typed address does not overwrite
  /// anything with "".
  ///
  /// ⚠ `landmark` is read straight off the raw input with **no validation rule
  /// at all** — `OrderAddress::$fillable` includes it, so a value over the
  /// column width is a DB error and a 500 *after* the order row has been
  /// written. It is capped here at the same 120 the address endpoints enforce.
  ///
  /// Values are trimmed because the rules were checked against trimmed input;
  /// sending the untrimmed original would persist something never validated.
  /// [countryAsCode] sends `IN` instead of `India`.
  ///
  /// ## Why the billing address needs it and the shipping one does not
  ///
  /// The two are persisted by different code. The **shipping** address is never
  /// validated — `mobileCheckout` sets `created_order_id` before storing it, so
  /// `OrderHelper::createOrderAddress` takes its `firstOrNew -> fill -> save`
  /// branch and returns before it builds any rules. Whatever is sent is kept
  /// verbatim.
  ///
  /// The **billing** address goes through `storeOrderBillingAddress`, which
  /// re-validates it against the full `getCustomerAddressValidationRules()` and,
  /// on failure, does a bare `return` — HTTP 200, order created, billing
  /// address gone, nothing said. With "Load countries, states, cities from
  /// plugin location" on, those rules include:
  ///
  /// ```php
  /// $rules['state'] = ['required', new StateRule('country')];
  /// ```
  ///
  /// and `StateRule` resolves the country by **id or code**:
  ///
  /// ```php
  /// $query->whereHas('country', fn ($q) => $q
  ///     ->where('id', $countryId)->orWhere('code', $countryId));
  /// ```
  ///
  /// `India` is neither, so the lookup finds nothing, the state fails, and the
  /// address is dropped. Verified live: every order placed from this app has an
  /// all-null `billing_info`, while the eight web orders that do carry one were
  /// all placed before that setting was turned on.
  ///
  /// Nothing the customer reads changes: the server's own `full_address` for an
  /// order address omits the country entirely.
  Map<String, dynamic> toJson({bool countryAsCode = false}) => {
        AddressField.name: name.trim(),
        AddressField.email: email.trim(),
        AddressField.phone: phone.trim(),
        AddressField.address: address.trim(),
        AddressField.city: city.trim(),
        AddressField.state: state.trim(),
        AddressField.country: countryAsCode
            ? CheckoutAddressRules.shipsToCountryCode
            : country.trim(),
        AddressField.zipCode: zipCode.trim(),
        if (_capped(landmark).isNotEmpty)
          AddressField.landmark: _capped(landmark),
        if (_capped(district).isNotEmpty)
          AddressField.district: _capped(district),
        if (_capped(otherCity).isNotEmpty)
          AddressField.otherCity: _capped(otherCity),
      };

  /// Trimmed and cut to the 120 the address endpoints enforce.
  ///
  /// Checkout enforces nothing on these three, and the column is the same width
  /// either way — so the cap is the difference between a truncated landmark and
  /// a 500 on an order that has already been created.
  static String _capped(String value) {
    final v = value.trim();
    return v.length <= _optionalMax ? v : v.substring(0, _optionalMax);
  }

  static const int _optionalMax = 120;
}

/// What `POST /ecommerce/checkout/cart/{cart_id}` did.
///
/// A sealed result rather than a thrown exception, for one reason: **the third
/// case has to be unmissable**. This call is not idempotent, so a caller that
/// only knows "it worked" and "it failed" will retry a timeout and create a
/// second real order. [CheckoutOutcomeUnknown] is a state the compiler forces
/// every caller to acknowledge.
sealed class PlaceOrderOutcome {
  const PlaceOrderOutcome();
}

/// The server created the order and told us about it.
///
/// Persist [PlacedOrder.orderId] and [PlacedOrder.orderToken] before doing
/// anything else — until the order is finished it is invisible to `GET /orders`
/// and those two values are the only handle on it. Then branch on
/// [PlacedOrder.requiresPayment].
final class OrderPlaced extends PlaceOrderOutcome {
  const OrderPlaced(this.order);

  final PlacedOrder order;
}

/// The address failed the strict web rules and **no request was sent**.
///
/// The server would have accepted it (see [CheckoutAddress]) and produced an
/// order nobody could dispatch, so this is refused here instead.
final class CheckoutAddressRejected extends PlaceOrderOutcome {
  const CheckoutAddressRejected({
    required this.address,
    this.billingAddress = const {},
  });

  /// Delivery-address violations, keyed by [AddressField] — bare names, so a
  /// form can look one up per field and [CheckoutAddressRules.firstProblem]
  /// works on it.
  final Map<String, String> address;

  /// Billing-address violations, same keys.
  ///
  /// Worth refusing even though the server never 422s on them: when billing
  /// addresses are enabled the server re-validates against these same web rules
  /// and, on failure, does a bare `return` — the address is **silently
  /// discarded** under an HTTP 200 and the order carries no billing details.
  final Map<String, String> billingAddress;

  /// The same violations keyed the way the server keys them in its own 422
  /// (`address.name`, `billing_address.zip_code`), so a form can merge this
  /// with an [ApiException.fieldErrors] bag without translating.
  Map<String, String> get fieldErrors => {
        for (final e in address.entries) 'address.${e.key}': e.value,
        for (final e in billingAddress.entries)
          'billing_address.${e.key}': e.value,
      };

  /// One sentence for a snackbar, in [AddressField.all] order so it is stable.
  String? get firstMessage =>
      CheckoutAddressRules.firstProblem(address) ??
      CheckoutAddressRules.firstProblem(billingAddress);
}

/// The server answered and refused. No retry will change that answer.
///
/// Covers the whole documented set: 404 "Cart not found or empty", the 422
/// family (out of stock, min/max quantity, minimum order amount), a Laravel
/// validation 422, and 500 "Checkout failed: …" / "Razorpay payment gateway is
/// not configured.".
final class CheckoutRefused extends PlaceOrderOutcome {
  const CheckoutRefused(this.error);

  final ApiException error;

  /// True when the refusal is late enough to have left a real order behind.
  ///
  /// `mobileCheckout` runs no DB transaction — `DB::` never appears in the
  /// controller and `OrderHelper::processOrder` has none either — so a 5xx can
  /// arrive after the `ec_orders` INSERT, the histories row, the shipment, the
  /// addresses and the coupon's `total_used++`. "Razorpay payment gateway is
  /// not configured." is exactly that shape. Reconcile with `GET /orders`
  /// before offering "try again"; every 4xx here is raised before the first
  /// write, so nothing exists.
  bool get orderMayExist => (error.statusCode ?? 0) >= 500;

  /// The server's own sentence — it names the actual constraint ("Product X is
  /// out of stock!") and is what the customer needs to read.
  String get message => error.message;
}

/// No usable `shipping_option` was supplied, and **no request was sent**.
///
/// ## Why this is a refusal and not a fallback
///
/// Since the app moved to server-priced shipping, `shipping_option` is the
/// *only* thing that tells the server what delivery costs — `shipping_amount`
/// is no longer sent at all. So there is no such thing as "place the order and
/// let shipping sort itself out": every route that does not carry a usable
/// option key produces an order billed **0.00** for delivery, silently, with a
/// 200 and a receipt that looks entirely normal.
///
/// The two tempting fallbacks are both that failure in disguise:
///
///   * `shipping_method: "default"` — `HandleShippingFeeService.php:58` reads
///     `Arr::get($result, 'default')`, then `:68` does
///     `Arr::get($filtered, null)`, and `Arr::get` with a null key returns the
///     **whole array** (`Arr.php:486-488`). The result is one level too deep,
///     so `Arr::get($shippingMethod, 'price', 0)`
///     (`API/CheckoutController.php:446`) misses and falls through to its `0`
///     default. `default` is not "some shipping", it is a guaranteed 0.00.
///   * `"shiprocket_<courierCompanyId>"` — a plausible-looking key that is not
///     a key. `ShipRocketService.php:1889` builds the entry as
///     `'shiprocket_' . Arr::get($courier, 'id')` (`:1870`), and `id` is the
///     per-quote **rate id**, a different number from `courier_company_id`
///     on every row (live 2026-08-04: `courier_company_id: 400` carries
///     `id: 1016322646`). The lookup misses; same 0.00.
///
/// Both cost the shop the courier bill on a real, paid, dispatchable order.
/// Refusing before the POST costs a tap.
///
/// ## This should be unreachable
///
/// The checkout screen blocks its place-order button until a courier has
/// quoted, so a caller that reaches here has a bug — which is exactly why this
/// is a compiler-enforced case in a sealed hierarchy rather than a silent
/// degradation. Render [message], keep the basket, and do **not** retry with a
/// substituted key.
final class CheckoutShippingUnpriced extends PlaceOrderOutcome {
  const CheckoutShippingUnpriced({
    required this.shippingOptionKey,
    required this.error,
  });

  /// Exactly what the caller passed — null, blank, or a string that is not a
  /// `shiprocket_…` member key. Echoed back so the log names the real value.
  final String? shippingOptionKey;

  final ApiException error;

  /// One sentence for the customer. Never mentions the key.
  String get message => error.message;
}

/// The request left the device and no answer came back.
///
/// **An order may exist.** Do not re-POST: the server's dedupe key is a session
/// token and the `api` middleware group has no session, so the second call
/// creates a second order, a second Razorpay order and burns another coupon
/// use. Reconcile instead — poll `GET /orders` for a matching total, or ask the
/// customer to check their orders — and only offer checkout again once you know
/// nothing was created.
///
/// Also returned when a 200 came back with a body no order could be read from:
/// the order was created and the app simply cannot name it, which is the same
/// problem.
final class CheckoutOutcomeUnknown extends PlaceOrderOutcome {
  const CheckoutOutcomeUnknown(this.error);

  final ApiException error;
}

/// What `POST /ecommerce/checkout/confirm-payment` did.
///
/// Five outcomes, because the four the caller would guess are not enough: a
/// 200 can mean "not paid", and the replay-guard 422 is neither success nor a
/// plain error.
sealed class ConfirmPaymentOutcome {
  const ConfirmPaymentOutcome();
}

/// The signature verified and Razorpay reported the order **paid**.
///
/// Still worth confirming against `GET /orders/{id}` before rendering a
/// receipt: the server never checks that the payment belongs to the order it is
/// confirming (the only binding is `Order.user_id == you`), so this response is
/// evidence about a Razorpay order, not proof about this one.
final class PaymentConfirmed extends ConfirmPaymentOutcome {
  const PaymentConfirmed(this.order);

  final PlacedOrder order;
}

/// HTTP 200, `success: true` — and the money did not land.
///
/// The server computes `payment_status` as `razorpayOrder.status == 'paid' ?
/// completed : pending`, and finalises the order either way: stock is
/// decremented, an invoice is generated, the order is pushed to ShipRocket and
/// a real SMS goes out. So this is a *failed payment on a live order*, not a
/// retryable state. Never show a success screen; route to support with
/// [PlacedOrder.orderId].
final class PaymentNotReceived extends ConfirmPaymentOutcome {
  const PaymentNotReceived(this.order);

  final PlacedOrder order;
}

/// 422 "This order has already been processed." — the replay guard.
///
/// Distinct from every other failure because it is **not evidence either way**.
/// The guard runs *before* signature verification, so the server never looked
/// at the triple; all it says is that the order is already finished, which the
/// server sets unconditionally with no payment-status check.
///
/// The correct response is neither a success screen nor an error: read
/// `GET /orders/{orderId}` and gate on `payment_status.value == "completed"`.
/// It is also the expected answer to a legitimate retry of a request that did
/// go through, which is why retrying this endpoint is safe.
final class PaymentAlreadyProcessed extends ConfirmPaymentOutcome {
  const PaymentAlreadyProcessed({required this.orderId, required this.error});

  /// The order to reconcile, echoed back so the caller does not have to hold it.
  final int orderId;

  final ApiException error;
}

/// The server answered and rejected the confirmation.
///
/// 404 "Order not found or does not belong to you.", 422 "Payment verification
/// failed. Invalid signature.", a Laravel 422 on `order_id`, or a 500 from
/// Razorpay's `order.fetch` (an unknown or expired `razorpay_order_id`).
///
/// Also returned without a request when the SDK handed back an incomplete
/// triple — all three of its fields are nullable, and the server requires all
/// three, so posting a blank one only earns a 422.
final class PaymentConfirmationRejected extends ConfirmPaymentOutcome {
  const PaymentConfirmationRejected(this.error);

  final ApiException error;

  String get message => error.message;
}

/// No answer, after [CheckoutRepository.maxConfirmAttempts] tries.
///
/// The payment itself is unaffected — Razorpay already has the money — and this
/// endpoint is safe to call again, so this is a "come back to it" state, not a
/// failure. Journal the triple and re-send it later; if the order finished in
/// the meantime the retry lands on [PaymentAlreadyProcessed], which is handled.
final class PaymentConfirmationUnresolved extends ConfirmPaymentOutcome {
  const PaymentConfirmationUnresolved({
    required this.error,
    required this.attempts,
  });

  final ApiException error;

  /// How many times it was tried, for the log line.
  final int attempts;
}

/// Checkout and payment confirmation.
///
/// ## The two calls are not the same kind of call
///
/// `POST /checkout/cart/{id}` **creates real things** and cannot be repeated;
/// `POST /checkout/confirm-payment` is guarded by a replay check and can. That
/// asymmetry is the whole design of this class: [placeOrder] has no retry path
/// at all and returns [CheckoutOutcomeUnknown] when it cannot tell what
/// happened, while [confirmPayment] retries with backoff — but only when the
/// server never answered.
///
/// ## Error decoding
///
/// These endpoints do **not** use the `{error, data, message}` envelope the
/// rest of the app sees. They use two shapes, and neither key is guaranteed:
///
/// ```
/// {"success": false, "message": "Product X is out of stock!"}   // no `errors`
/// {"message": "…", "errors": {"address.name": ["…"]}}           // no `success`
/// {"success": false, "message": "Checkout failed: …", "errors": []}
/// ```
///
/// [ApiException.fromResponse] already reads all three correctly and needed no
/// change: it takes `message` first (so `success` never has to be present),
/// treats `errors` as optional, and — importantly — only harvests field errors
/// when `errors` is a **Map**, so the `errors: []` that a 500 sends is ignored
/// rather than parsed into a bogus bag. `kind` comes from the HTTP status, so
/// an absent `success` cannot make a 422 look like anything else.
///
/// Two gaps are closed here rather than there. `ApiClient` watches for
/// `error: true` on a 2xx, which these endpoints never send — so a 200 that
/// declares `success: false` is caught below. And "already processed" is a 422
/// like any other to a generic decoder, so it is recognised here and given its
/// own outcome.
class CheckoutRepository {
  /// [sleep] exists so the backoff in [confirmPayment] can be driven by a test
  /// without three real seconds of waiting.
  CheckoutRepository(this._api, {Future<void> Function(Duration)? sleep})
      : _sleep = sleep ?? _wait;

  final ApiClient _api;
  final Future<void> Function(Duration) _sleep;

  static Future<void> _wait(Duration d) => Future<void>.delayed(d);

  /// The only payment method this app may send.
  ///
  /// `cod` is accepted by the validator and then 500s on a `TypeError` *after*
  /// the order and a payment row marked COMPLETED are already committed —
  /// `OrderHelper::confirmPayment` type-hints an ACL `User` and is handed a
  /// `Customer`, and a `TypeError` is an `Error`, so the controller's
  /// `catch (\Exception)` misses it. COD is also disabled in admin. Razorpay
  /// only, deliberately.
  static const String paymentMethod = 'razorpay';

  /// `shipping_method` — the **group** key, and a literal, never a courier name.
  ///
  /// `HookServiceProvider.php:59` registers the Shiprocket rate table under
  /// exactly this string (`$result['shiprocket'] = $serviceabilityRates`), and
  /// `HandleShippingFeeService.php:58` finds it with
  /// `Arr::get($result, $method)`. Anything else — a display name like
  /// `"India Post - Speed Post Prepaid"`, or the old `"default"` — misses that
  /// lookup and prices the order at 0.00 (see [CheckoutShippingUnpriced]).
  ///
  /// Verified live 2026-08-04: every recent order on the account
  /// (`GET /ecommerce/orders`, ids 273-277) comes back with
  /// `shipping_method: {"value": "shiprocket", "label": "ShipRocket"}`, so the
  /// column stores this value happily — the older note here claiming the enum
  /// admitted only `default` and `''` was wrong.
  static const String shippingMethod = 'shiprocket';

  /// The prefix every member key of the [shippingMethod] group carries.
  ///
  /// Derived from [shippingMethod] rather than typed again, because
  /// `ShipRocketService.php:1889` builds the key as
  /// `'shiprocket_' . $rateId` — the group name and the prefix are the same
  /// string on the server and drifting them apart here would be undetectable.
  static const String shippingOptionPrefix = '${shippingMethod}_';

  /// Whether [key] can be sent as `shipping_option` at all.
  ///
  /// A cheap shape check, not a validity check: it catches null, blank and
  /// "somebody sent the courier name / the group key / `default`", all of which
  /// bill 0.00 on the server without any error. It **cannot** catch a
  /// well-formed key for a quote the server's own re-price does not contain —
  /// see [placeOrder] for why that is a reconciliation problem, not a
  /// validation one.
  ///
  /// The length test is what rejects a bare `"shiprocket_"` with no rate id
  /// after it, which `startsWith` alone would wave through.
  static bool isUsableShippingOptionKey(String? key) {
    final trimmed = key?.trim() ?? '';
    return trimmed.length > shippingOptionPrefix.length &&
        trimmed.startsWith(shippingOptionPrefix);
  }

  /// Attempts for [confirmPayment], including the first. Four costs at most
  /// ~2.8s of waiting and covers a handover between networks, which is the
  /// realistic failure on a phone at a checkout counter.
  static const int maxConfirmAttempts = 4;

  /// Doubles each attempt: 400ms, 800ms, 1.6s.
  static const Duration confirmBackoff = Duration(milliseconds: 400);

  /// How long [placeOrder] waits for an answer, overriding
  /// `AppConfig.receiveTimeout` (25s) for this one call.
  ///
  /// Longer than everything else in the app on purpose. Giving up early does
  /// **not** cancel the order — the server has already received the POST and
  /// creates the row regardless — it only converts a slow success into
  /// [CheckoutOutcomeUnknown], which costs the customer a reconciliation and
  /// costs the shop an order it cannot show them. The checkout controller does
  /// a synchronous Razorpay `order.create` plus a Shiprocket lookup inside the
  /// request, so 25s is genuinely reachable on a slow connection.
  static const Duration placeOrderTimeout = Duration(seconds: 45);

  /// Creates the order and, when there is money to collect, the Razorpay order.
  ///
  /// ## THIS CALL IS NOT IDEMPOTENT — A RETRY CREATES A SECOND REAL ORDER
  ///
  /// Not "may duplicate under a race": every POST creates a new `ec_orders`
  /// row, a new Razorpay order and another `total_used++` on the coupon. The
  /// server's own de-duplication is `Order::where('token', $token)`, where
  /// `$token` comes from `session('tracked_start_checkout')` — and the `api`
  /// middleware group has no `StartSession` (no `Set-Cookie` on any
  /// `/api/v1/ecommerce/*` response), so the token is a fresh
  /// `md5(Str::random(40))` on every request and that lookup never matches.
  /// The `ec_cart` row also survives checkout, so the same cart id can be
  /// checked out again and again.
  ///
  /// Auto-retry is therefore made structurally impossible rather than merely
  /// discouraged: this method does not share [confirmPayment]'s retry helper,
  /// and [ApiClient] installs no retry interceptor (if one is ever added, this
  /// path must be excluded). A transport failure is reported as
  /// [CheckoutOutcomeUnknown] — a state the caller must reconcile, never repeat.
  ///
  /// ## What is sent
  ///
  /// `address`, `payment_method`, `shipping_method`, `shipping_option` and
  /// `billing_address_same_as_shipping_address` on every request, plus the
  /// optional `notes` / `billing_address` / `with_tax_information` +
  /// `tax_information`. Four fields are deliberately never sent:
  ///
  ///   * **`shipping_amount`** — see below. This is the important one.
  ///   * `currency` — breaks the `X-CURRENCY` header (the middleware tests
  ///     `has('currency')`, which sees the body, then reads `query('currency')`,
  ///     which does not) and writes a currency onto the payment row that
  ///     disagrees with the Razorpay order.
  ///   * `payment_status` and `charge_id` — validated but never read; the
  ///     server derives both.
  ///
  /// ## Shipping is priced by the SERVER, from `shipping_option`
  ///
  /// The app sends the same pair the web checkout sends, and nothing else:
  ///
  /// ```json
  /// { "shipping_method": "shiprocket",
  ///   "shipping_option":  "shiprocket_1016322646" }
  /// ```
  ///
  /// `shipping_method` is the **group** key ([shippingMethod]); the option is a
  /// **member** of that group, keyed by Shiprocket's per-quote rate id. The web
  /// does exactly this — `shipping-methods.blade.php:19,23` renders a radio
  /// whose `value` is the group and whose `data-option` is the member,
  /// `checkout.js:190` copies `data-option` into the hidden `shipping_option`
  /// field, and `PublicCheckoutController.php:736-751` resolves it. The mobile
  /// route resolves it the same way: `API/CheckoutController.php:437-441` hands
  /// `$request->input('shipping_option')` to `HandleShippingFeeService::execute`
  /// and `:445-446` reads `Arr::get($shippingMethod, 'price', 0)` from what
  /// comes back — which is `'price' => $totalCost` from
  /// `ShipRocketService.php:1893`.
  ///
  /// The key itself is `'shiprocket_' . Arr::get($courier, 'id')`
  /// (`ShipRocketService.php:1870`, `:1889`) — the **rate id**, not
  /// `courier_company_id`. Do not build it here; take it from
  /// `shippingOptionKeyProvider`.
  ///
  /// ## Why `shipping_amount` is gone, not optional
  ///
  /// The server honours a client-supplied `shipping_amount` verbatim and with
  /// no ceiling — `CheckoutRequest.php:79` is `nullable|numeric|min:0`, and
  /// `API/CheckoutController.php:425` sets
  /// `$useClientShippingAmount = $request->has('shipping_amount')`, which
  /// `:445` then uses to skip the server's own pricing entirely. So while that
  /// field is present, a correct `shipping_option` changes **nothing**: the two
  /// edits only work as a pair, which is why the parameter was deleted rather
  /// than defaulted to null. (`has()` is true for a present-but-null key, so
  /// even `'shipping_amount': null` would have kept the client-trusted branch
  /// alive and forced shipping to 0.)
  ///
  /// The product owner has chosen not to rely on a client-trusted price. That
  /// decision is settled; this method has no way to express the old contract.
  ///
  /// ## THE CONSEQUENCE: the server re-quotes, so the price can differ
  ///
  /// The server does not price the option the app quoted. It rebuilds the whole
  /// rate table by calling Shiprocket again, from
  /// `EcommerceHelper::getOriginAddress()` (`EcommerceHelper.php:1102`), whose
  /// pickup postcode is `get_ecommerce_setting('store_zip_code')`
  /// (`:1114`) — **not** the app's `kDefaultPickupPinCode`. A rate id also
  /// identifies a *quote*, not a courier (live: "India Post - Speed Post
  /// Prepaid" was `1016312390` at 0.5 kg and `1016322646` at 10.2 kg). So the
  /// key this app sends can legitimately be absent from the table the server
  /// builds, and when it is, the miss is silent: `$shippingMethod` is null, the
  /// `'price'` lookup falls through to `0`, and the order is written charging
  /// **0.00** for delivery. That is an *under*charge, and it is a divergence
  /// exactly as much as an overcharge is.
  ///
  /// **The order is created before the app learns the server's figure.** So the
  /// caller must reconcile, in both directions, after this returns and *before*
  /// opening the Razorpay sheet: compare [PlacedOrder.totalAmount] against the
  /// total the button showed, and let the customer decline. Never open a sheet
  /// for a number the customer was not shown.
  ///
  /// ## [shippingOptionKey]
  ///
  /// `"shiprocket_<rateId>"`, from `shippingOptionKeyProvider` — the provider
  /// resolves it against the rate list that is live *now* rather than the
  /// snapshot the customer tapped. Required-and-nullable on purpose: a caller
  /// has to say something about shipping, and there is no defensible default.
  ///
  /// Null, blank, or not a `shiprocket_…` member key returns
  /// [CheckoutShippingUnpriced] and sends nothing. Read that class before
  /// reaching for a fallback — every fallback is a 0.00 order.
  ///
  /// Note a free-shipping coupon zeroes the charge server-side *after* the
  /// option is priced, so [PlacedOrder.shippingAmount] /
  /// [PlacedOrder.totalAmount] remain the only figures to display; never re-add
  /// the parts.
  ///
  /// [taxInformation] is only honoured when the shop has tax information
  /// enabled; when it is off the block is ignored, silently and successfully.
  Future<PlaceOrderOutcome> placeOrder({
    required String cartId,
    required CheckoutAddress address,
    required String? shippingOptionKey,
    String? notes,
    CheckoutAddress? billingAddress,
    Map<String, dynamic>? taxInformation,
  }) async {
    // A blank id would POST to a path that is not this route at all. That is a
    // caller bug rather than a server refusal, so — as in `CartRepository` — it
    // surfaces as a failed future, not as an outcome to render.
    if (cartId.trim().isEmpty) {
      throw ArgumentError.value(cartId, 'cartId', 'must be a real cart id');
    }

    // Checked BEFORE the address, and deliberately so. A missing option key is
    // not content to be corrected, it is a precondition of the request being
    // sendable at all — the same class of problem as a blank cart id. Ordering
    // it after the address check would let an unrelated typo in a house number
    // mask a bug that silently bills the shop for every courier it ever eats.
    if (!isUsableShippingOptionKey(shippingOptionKey)) {
      return CheckoutShippingUnpriced(
        shippingOptionKey: shippingOptionKey,
        error: ApiException.local(
          'Please choose a delivery option before placing your order.',
          developerDetail:
              'placeOrder refused for cart $cartId: shipping_option must be '
              '"$shippingOptionPrefix<rateId>" from shippingOptionKeyProvider, '
              'got ${shippingOptionKey == null ? 'null' : '"$shippingOptionKey"'}. '
              'Sending it anyway — or falling back to shipping_method '
              '"default" — writes a real order charging 0.00 for delivery.',
        ),
      );
    }

    final addressProblems = address.violations();
    final billingProblems =
        billingAddress?.violations() ?? const <String, String>{};
    if (addressProblems.isNotEmpty || billingProblems.isNotEmpty) {
      return CheckoutAddressRejected(
        address: addressProblems,
        billingAddress: billingProblems,
      );
    }

    final trimmedNotes = notes?.trim() ?? '';
    final body = <String, dynamic>{
      'address': address.toJson(),
      'payment_method': paymentMethod,
      // The group key and one of its members. Both, always — the guard above
      // is what makes `shipping_option` unconditional here, and there is no
      // branch of this method that sends `shipping_amount`.
      'shipping_method': shippingMethod,
      'shipping_option': shippingOptionKey!.trim(),
      if (trimmedNotes.isNotEmpty) 'notes': trimmedNotes,
      // ALWAYS sent, both ways round, and the string form the web posts.
      //
      // This is not decoration. `CheckoutRequest::rules()` reads:
      //
      // ```php
      // if (EcommerceHelper::isBillingAddressEnabled()) {
      //     $rules['billing_address_same_as_shipping_address'] =
      //         'nullable|' . Rule::in(['0', '1']);
      //     if (! $this->input('billing_address_same_as_shipping_address') || …) {
      //         $rules['billing_address'] = 'array';
      //         $rules = array_merge($rules,
      //             EcommerceHelper::getCustomerAddressValidationRules('billing_address.'));
      //     }
      // ```
      //
      // Omitting the flag makes `! $this->input(...)` true, which makes the
      // **whole billing address required**. So the day the shop enables
      // `billing_address_enabled`, every order from an app that did not send
      // this flag 422s with "The Name field is required" against a form that
      // has no billing name on it. Sending `"1"` is what keeps a
      // same-as-delivery order legal under either setting.
      //
      // The literal strings, not booleans: the rule is `Rule::in(['0', '1'])`.
      'billing_address_same_as_shipping_address': billingAddress == null
          ? '1'
          : '0',
      if (billingAddress != null)
        'billing_address': billingAddress.toJson(countryAsCode: true),
      if (taxInformation != null && taxInformation.isNotEmpty) ...{
        'with_tax_information': true,
        'tax_information': taxInformation,
      },
    };

    final path = ApiEndpoints.checkoutCart(cartId);
    try {
      final res = await _api.post(
        path,
        data: body,
        options: Options(
          sendTimeout: placeOrderTimeout,
          receiveTimeout: placeOrderTimeout,
        ),
      );

      // Unreachable as far as the audit of the controller goes — every failure
      // it knows about is non-2xx — but `success` is the only failure flag
      // these endpoints have, and reading an order out of a body that declared
      // failure would tell the customer about an order that does not exist.
      if (_declaresFailure(res.data)) {
        return CheckoutRefused(
          ApiException.fromResponse(res, requestDescription: 'POST $path'),
        );
      }

      final order = PlacedOrder.tryFrom(res.data);
      if (order == null) {
        // A 200 means the order exists; we simply cannot name it. That is the
        // reconcile-don't-repeat case, not a failure.
        return CheckoutOutcomeUnknown(
          ApiException.local(
            'Your order may have been placed. Please check your orders before '
            'trying again.',
            developerDetail:
                'POST $path returned 2xx with no data.order_id: ${res.data}',
          ),
        );
      }
      return OrderPlaced(order);
    } on ApiException catch (e) {
      return _serverAnswered(e)
          ? CheckoutRefused(e)
          : CheckoutOutcomeUnknown(e);
    }
  }

  /// Finalises a Razorpay payment against the order [orderId].
  ///
  /// Safe to call again — unlike [placeOrder] — because the server refuses a
  /// second confirmation with the replay guard, which arrives here as
  /// [PaymentAlreadyProcessed]. That is what makes the bounded retry below
  /// legitimate.
  ///
  /// **Retries transport failures only.** A 4xx or 5xx is an answer: the server
  /// received the request, ran the guard, may have verified the signature and
  /// may already have finalised the order. Repeating it cannot change the reply
  /// and would only delay telling the customer. So the discriminator is not
  /// "was this a 5xx" but "did the server answer at all" —
  /// [ApiException.statusCode] is null exactly when it did not. Note that
  /// deliberately excludes [ApiErrorKind.server], which
  /// [ApiErrorKindX.isRetryable] would otherwise wave through.
  ///
  /// [orderId] is the numeric shop order id from [PlacedOrder.orderId] — never
  /// [RazorpayHandoff.orderId], which is what `razorpayOrderId` wants.
  Future<ConfirmPaymentOutcome> confirmPayment({
    required int orderId,
    required String razorpayPaymentId,
    required String razorpayOrderId,
    required String razorpaySignature,
  }) async {
    // Comes straight from `PlacedOrder.orderId`, so anything else is a caller
    // bug — and confirming the wrong order is not a mistake worth making
    // politely.
    if (orderId <= 0) {
      throw ArgumentError.value(orderId, 'orderId', 'must be a real order id');
    }

    // The SDK's three fields are all nullable. An empty one is a local failure
    // to be recovered from, not something to send and have 422'd.
    if (razorpayPaymentId.trim().isEmpty ||
        razorpayOrderId.trim().isEmpty ||
        razorpaySignature.trim().isEmpty) {
      return PaymentConfirmationRejected(
        ApiException.local(
          "The payment couldn't be verified. Please contact support with your "
          'order number.',
          developerDetail: 'confirmPayment called for order $orderId with an '
              'incomplete Razorpay triple: '
              'payment_id="$razorpayPaymentId" order_id="$razorpayOrderId" '
              'signature length ${razorpaySignature.length}',
        ),
      );
    }

    final body = <String, dynamic>{
      'order_id': orderId,
      'razorpay_payment_id': razorpayPaymentId.trim(),
      'razorpay_order_id': razorpayOrderId.trim(),
      'razorpay_signature': razorpaySignature.trim(),
    };

    var attempt = 0;
    while (true) {
      attempt++;
      try {
        final res = await _api.post(ApiEndpoints.confirmPayment, data: body);

        if (_declaresFailure(res.data)) {
          return PaymentConfirmationRejected(
            ApiException.fromResponse(
              res,
              requestDescription: 'POST ${ApiEndpoints.confirmPayment}',
            ),
          );
        }

        final order = PlacedOrder.tryFrom(res.data);
        if (order == null) {
          // The confirmation was accepted; only the body is unreadable. The
          // order state has to come from GET /orders/{id} either way.
          return PaymentConfirmationUnresolved(
            error: ApiException.local(
              "The payment went through but the confirmation couldn't be read. "
              'Please check your orders.',
              developerDetail: 'POST ${ApiEndpoints.confirmPayment} returned '
                  '2xx with no data.order_id: ${res.data}',
            ),
            attempts: attempt,
          );
        }

        // HTTP 200 + success:true is not payment. Only `completed` is.
        return order.isPaymentCompleted
            ? PaymentConfirmed(order)
            : PaymentNotReceived(order);
      } on ApiException catch (e) {
        if (_isAlreadyProcessed(e)) {
          return PaymentAlreadyProcessed(orderId: orderId, error: e);
        }
        if (_serverAnswered(e)) return PaymentConfirmationRejected(e);
        if (!_worthRetrying(e) || attempt >= maxConfirmAttempts) {
          return PaymentConfirmationUnresolved(error: e, attempts: attempt);
        }
        await _sleep(confirmBackoff * (1 << (attempt - 1)));
      }
    }
  }

  /// The server sent a status line, so it received and answered the request.
  ///
  /// Null is the only reliable signal for "never got there": Dio reports an
  /// offline socket, a DNS miss and a timeout all with no response, and a
  /// cancelled or TLS-rejected request likewise carries no status.
  static bool _serverAnswered(ApiException e) => e.statusCode != null;

  /// Worth sending again, given the server never answered.
  ///
  /// A cancellation was deliberate and a certificate failure will fail
  /// identically next time, so neither is retried even though both leave the
  /// outcome unknown.
  static bool _worthRetrying(ApiException e) =>
      !_serverAnswered(e) &&
      (e.kind == ApiErrorKind.network ||
          e.kind == ApiErrorKind.timeout ||
          e.kind == ApiErrorKind.unknown);

  /// The replay guard, recognised by its sentence.
  ///
  /// A string match, because the backend gives it no code of its own: it is a
  /// plain 422 with `{"success": false, "message": "This order has already been
  /// processed."}` and no `errors` bag, indistinguishable by shape from
  /// "Payment verification failed. Invalid signature.". Matched on a substring
  /// of the server's own wording so a trailing full stop or a translated prefix
  /// does not break it; if the wording ever changes, the call degrades to
  /// [PaymentConfirmationRejected] rather than to a false success.
  static bool _isAlreadyProcessed(ApiException e) {
    if (e.statusCode != 422) return false;
    final message = e.serverMessage?.toLowerCase() ?? '';
    return message.contains('already been processed');
  }

  /// A 2xx whose body declares failure.
  ///
  /// [ApiClient] already turns `error: true` into a thrown exception, but that
  /// is the Botble envelope's flag and these two endpoints never send it —
  /// their flag is `success`, which nothing central inspects.
  static bool _declaresFailure(dynamic body) =>
      body is Map && body['success'] == false;
}

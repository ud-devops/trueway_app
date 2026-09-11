/// The payment seam.
///
/// Everything above this file — the checkout flow, its providers, its tests —
/// talks to [PaymentGateway] and to the [PaymentResult] union. Nothing else in
/// `lib/` may import `package:razorpay_flutter/...`; the only file that does is
/// `razorpay_gateway.dart` next door.
///
/// Two reasons, both practical:
///
///   * **Testability.** `razorpay_flutter` reaches a platform channel the
///     moment you call `open()`, so a checkout notifier that touches it
///     directly cannot be unit-tested at all. Against this interface a fake
///     that returns `PaymentSuccess(...)` or `PaymentCancelled()` is three
///     lines.
///   * **Swappability.** The gateway is a business decision (Razorpay today,
///     possibly a hosted page or a second provider later). Keeping the union
///     provider-neutral means that swap is one new class plus one line in
///     `core_providers.dart`.
///
/// The union is deliberately provider-neutral: it carries the three fields the
/// backend's `POST /ecommerce/checkout/confirm-payment` requires
/// (`razorpay_payment_id`, `razorpay_order_id`, `razorpay_signature`) and
/// nothing else provider-shaped.
library;

// ---------------------------------------------------------------------------
// Request
// ---------------------------------------------------------------------------

/// What the gateway needs to open a checkout sheet for one order.
///
/// Every money-bearing field here comes **verbatim** from the `data.razorpay`
/// block of `POST /api/v1/ecommerce/checkout/cart/{cart_id}`. In particular
/// [amountInPaise] is already minor units server-side — it is
/// `(int) round($order->amount * 100)` — so it must never be multiplied,
/// rounded, or re-derived from `data.total_amount` on the way here.
class PaymentRequest {
  const PaymentRequest({
    required this.keyId,
    required this.orderId,
    required this.amountInPaise,
    required this.currency,
    this.description,
    this.customerEmail,
    this.customerPhone,
    this.timeout = const Duration(minutes: 5),
  });

  /// `data.razorpay.razorpay_key_id` — the publishable merchant key
  /// (`rzp_...`). The server picks it; the app never holds a key of its own.
  final String keyId;

  /// `data.razorpay.razorpay_order_id` — the Razorpay order (`order_...`).
  ///
  /// Not the numeric `data.order_id`. Confirm-payment wants the numeric one in
  /// `order_id` and this one in `razorpay_order_id`; mixing them up is a 422.
  final String orderId;

  /// `data.razorpay.amount`, **already in paise**. Passed to the SDK untouched.
  ///
  /// Whole minor units, always. The guard that enforces that lives upstream, in
  /// `RazorpayHandoff.fromJson`, which reads a fractional `amount` as `0` rather
  /// than rounding `803.25` down to `803` — and a non-positive amount never
  /// reaches a `PaymentRequest`, because `PendingOrder.toPaymentRequest` refuses
  /// to build one. There used to be a second copy of that check here, on a
  /// `fromRazorpayBlock` factory nothing called; it was removed rather than left
  /// to rot beside a live path that did not use it.
  final int amountInPaise;

  /// `data.razorpay.currency`, e.g. `INR`.
  final String currency;

  /// Optional line shown under the merchant name on the sheet, e.g.
  /// `Order #1287`. Purely cosmetic — it is not sent to the backend.
  final String? description;

  /// Prefills the sheet's email field. From the shipping address.
  final String? customerEmail;

  /// Prefills the sheet's contact field. From the shipping address.
  ///
  /// Send the plain 10-digit number the app already validates against
  /// `^[6-9][0-9]{9}$`; Razorpay adds the country code itself.
  final String? customerPhone;

  /// How long the sheet may stay open before the SDK dismisses it.
  ///
  /// Razorpay takes whole seconds, so sub-second precision is discarded.
  final Duration timeout;

  @override
  String toString() => 'PaymentRequest(orderId: $orderId, '
      'amountInPaise: $amountInPaise, currency: $currency)';
}

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------

/// The outcome of one checkout sheet. Exhaustive: `switch` on it without a
/// default and the analyzer will tell you when a case is missing.
///
/// ```dart
/// final result = await gateway.pay(request);
/// switch (result) {
///   case PaymentSuccess(:final paymentId, :final orderId, :final signature):
///     // POST confirm-payment, then gate the success screen on
///     // GET /orders/{id} -> payment_status == 'completed'.
///   case PaymentCancelled():
///     // The order exists and is unpaid. Offer "retry payment" with the SAME
///     // PaymentRequest — running checkout again mints a second order.
///   case PaymentFailed(:final message):
///     // Same as cancelled, but show `message`.
/// }
/// ```
sealed class PaymentResult {
  const PaymentResult();
}

/// The SDK reported a completed payment and returned all three fields the
/// backend needs to verify it.
///
/// **This is not proof of payment.** It means the gateway's client-side
/// callback fired with a signed triple. Only
/// `GET /ecommerce/orders/{id} -> data.payment_status.value == 'completed'`
/// proves the money landed; confirm-payment can return HTTP 200 with
/// `payment_status: "pending"`, which means the payment failed.
///
/// All three fields are non-null and non-empty by construction. The SDK types
/// them nullable, and the gateway converts a partial success into a
/// [PaymentFailed] rather than let a half-filled triple reach the API, which
/// would only 422.
final class PaymentSuccess extends PaymentResult {
  const PaymentSuccess({
    required this.paymentId,
    required this.orderId,
    required this.signature,
  });

  /// `razorpay_payment_id` — `pay_...`.
  final String paymentId;

  /// `razorpay_order_id` — `order_...`. Guaranteed to equal the
  /// [PaymentRequest.orderId] the sheet was opened with; the gateway rejects a
  /// mismatch rather than hand back a triple for someone else's order.
  final String orderId;

  /// `razorpay_signature` — HMAC over `orderId|paymentId`.
  final String signature;

  @override
  String toString() => 'PaymentSuccess(paymentId: $paymentId, orderId: $orderId)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PaymentSuccess &&
          other.paymentId == paymentId &&
          other.orderId == orderId &&
          other.signature == signature;

  @override
  int get hashCode => Object.hash(paymentId, orderId, signature);
}

/// The customer dismissed the sheet without paying.
///
/// Distinguished from [PaymentFailed] only so the UI can stay quiet: there is
/// nothing to apologise for and no message worth showing. The order still
/// exists server-side, unpaid and invisible to `GET /orders`.
final class PaymentCancelled extends PaymentResult {
  const PaymentCancelled();

  @override
  String toString() => 'PaymentCancelled()';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PaymentCancelled;

  @override
  int get hashCode => (PaymentCancelled).hashCode;
}

/// The payment did not go through, for a reason worth telling the customer.
final class PaymentFailed extends PaymentResult {
  const PaymentFailed({required this.code, required this.message});

  /// Provider-specific. Useful in logs, useless for branching — do not compare
  /// it against literals in the UI. Values `<= 0` that this app raises itself
  /// are named in [PaymentFailureCodes]; anything else came from the provider.
  /// Null when the provider failed to supply one.
  final int? code;

  /// Human-readable and safe to show. Never empty: the gateway substitutes a
  /// generic sentence when the provider sends nothing usable.
  ///
  /// For provider-side failures this is Razorpay's own `error.description`
  /// ("Payment failed due to insufficient funds"), already unwrapped from the
  /// error envelope by the plugin's native side.
  final String message;

  @override
  String toString() => 'PaymentFailed(code: $code, message: $message)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PaymentFailed && other.code == code && other.message == message;

  @override
  int get hashCode => Object.hash(code, message);
}

/// [PaymentFailed.code] values raised by this app rather than by the provider.
///
/// Negative on purpose: every provider code is `>= 0`, so the two spaces cannot
/// collide.
abstract final class PaymentFailureCodes {
  /// The sheet reported success but omitted the payment id, order id or
  /// signature. Nothing can be confirmed; the order may or may not be paid, so
  /// reconcile against `GET /orders/{id}` before telling the customer anything.
  static const int incompleteSuccess = -1;

  /// The sheet returned a triple for a *different* Razorpay order than the one
  /// it was opened with — a stale response replayed after the app was killed
  /// mid-payment. Confirming it would attach someone else's payment to this
  /// order, so it is refused. Reconcile via `GET /orders/{id}`.
  static const int orderMismatch = -2;

  /// The customer chose an external wallet. Unreachable in normal operation —
  /// the app never enables one — but if it ever fires there is no triple to
  /// confirm with.
  static const int externalWalletUnsupported = -3;

  /// The SDK never called back at all: the native side threw, the plugin was
  /// not registered, or the sheet hung past its own timeout. The payment state
  /// is genuinely unknown; reconcile against `GET /orders/{id}`.
  static const int noResponse = -4;

  /// A second [PaymentGateway.pay] was attempted while a sheet was already
  /// open, or after the gateway was disposed. A caller bug, not a payment
  /// event: no sheet was shown.
  static const int notStarted = -5;
}

// ---------------------------------------------------------------------------
// Gateway
// ---------------------------------------------------------------------------

/// Opens a hosted payment sheet and reports what happened.
///
/// Implementations must:
///
///   * complete exactly once per [pay] call, even when the underlying SDK
///     fires more than once;
///   * never throw — every outcome, including "the SDK exploded", arrives as a
///     [PaymentResult];
///   * release native listeners before completing, so a second checkout in the
///     same app session cannot receive the first one's callbacks.
abstract class PaymentGateway {
  /// Shows the sheet for [request] and resolves once when it closes.
  ///
  /// Only one sheet at a time: calling this while another is open resolves
  /// immediately with [PaymentFailureCodes.notStarted] and leaves the open
  /// sheet alone.
  Future<PaymentResult> pay(PaymentRequest request);

  /// Tears down anything the gateway holds. Any sheet still open resolves with
  /// [PaymentFailureCodes.noResponse]. Safe to call more than once.
  void dispose();
}

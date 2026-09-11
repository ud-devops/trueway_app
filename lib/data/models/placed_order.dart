import '../../core/utils/json_utils.dart';
import 'server_cart.dart';

/// The Razorpay handoff block — `data.razorpay` on the checkout response.
///
/// **This object is optional and its absence is meaningful**, which is why it is
/// modelled separately and reached only through [PlacedOrder.razorpay] /
/// [PlacedOrder.requiresPayment]. The server emits it only on the
/// razorpay/pay_online branch; a zero-amount order, or an install where the
/// payment plugin is inactive, is finalised inside the checkout call itself and
/// comes back with no `razorpay` key at all (and no `is_finished` key either).
/// Launching the SDK in that case would charge for an order that is already
/// paid for, and calling confirm-payment would 422 on the replay guard.
class RazorpayHandoff {
  const RazorpayHandoff({
    required this.orderId,
    required this.keyId,
    required this.amountInPaise,
    required this.currency,
  });

  /// Razorpay's own order id, `order_…`.
  ///
  /// Not [PlacedOrder.orderId] and never interchangeable with it: this one goes
  /// to the SDK and back in `razorpay_order_id`, while confirm-payment's
  /// `order_id` field wants the numeric shop order id.
  final String orderId;

  /// The publishable key, `rzp_…`. Comes from the server so a key rotation in
  /// admin does not need an app release.
  final String keyId;

  /// **Already in paise.** The server computes it as
  /// `(int) round($order->amount * 100)` — the same expression it used to create
  /// the Razorpay order — so multiplying it again, or deriving it from
  /// [PlacedOrder.totalAmount], charges 100× or drifts by a rounding step. Pass
  /// it to the SDK untouched.
  ///
  /// `0` means the wire value was **not** whole minor units — see [_paise].
  /// Everything downstream treats a non-positive amount as "cannot open a
  /// sheet", which is the intended outcome.
  final int amountInPaise;

  /// `"INR"`. The application currency, uppercased, not anything the client sent
  /// — this endpoint ignores a `currency` in the request body.
  final String currency;

  factory RazorpayHandoff.fromJson(Map<String, dynamic> j) => RazorpayHandoff(
        orderId: asString(j['razorpay_order_id']),
        keyId: asString(j['razorpay_key_id']),
        amountInPaise: _paise(j['amount']),
        currency: asString(j['currency'], 'INR'),
      );

  /// `amount` as whole minor units, or `0` when it is anything else.
  ///
  /// Deliberately **not** [asInt]. `asInt` rounds — `803.25` becomes `803` — and
  /// this field is the number the customer's card is charged: rounding it turns
  /// a ₹803.25 order into a ₹8.03 one and nobody downstream can tell. A
  /// fractional "paise" value means the server's contract changed and the field
  /// is no longer minor units, so the only safe reading is "unusable".
  ///
  /// Accepts `80325` and `"80325"`; rejects `803.25`, `"803.25"`, `null` and
  /// anything non-numeric. This is the fractional-amount guard that
  /// `PaymentRequest.fromRazorpayBlock` used to provide before the live path
  /// stopped going through it; it now sits on the live path itself, at the one
  /// point the wire value enters the app.
  static int _paise(dynamic value) {
    if (value is int) return value;
    if (value is double) {
      return value == value.roundToDouble() ? value.toInt() : 0;
    }
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  static RazorpayHandoff? tryFrom(dynamic raw) => raw is Map
      ? RazorpayHandoff.fromJson(Map<String, dynamic>.from(raw))
      : null;
}

/// An order the server has really created, as returned by
/// `POST /ecommerce/checkout/cart/{cart_id}` and
/// `POST /ecommerce/checkout/confirm-payment`.
///
/// Both endpoints return the same `{success, message, data}` envelope with the
/// same `data` block, so they share one model. They differ only at the edges,
/// and every difference is a nullable field here rather than a second class:
///
///   * checkout adds [cartId] and [paymentId] and may add [razorpay];
///   * confirm-payment adds [chargeId] and drops those three;
///   * the zero-amount / payment-plugin-inactive branch of checkout omits
///     [isFinished] entirely and nulls [paymentStatus], [paymentStatusLabel],
///     [paymentMethod] and [paymentId].
///
/// **Nothing here is recomputed.** Money arrives as decimal *strings* on these
/// two endpoints (`ec_orders` money columns are `decimal(15,2)` and the model
/// does not cast them), and [totalAmount] is the exact figure the customer is
/// charged — the Razorpay paise amount is derived from it server-side. Show it;
/// do not re-add the parts.
///
/// **These figures are also the first news the app gets of what shipping cost.**
/// Since the app moved to server-priced shipping it sends a `shipping_option`
/// and no `shipping_amount`, so [shippingAmount] and [totalAmount] are the
/// server's answer, not an echo of the app's arithmetic — and the order already
/// exists by the time they arrive. The three fields the reconciliation step
/// needs are [shippingAmount], [totalAmount] and [amountInPaise]; [totalMatches]
/// is the comparison to use.
class PlacedOrder {
  const PlacedOrder({
    required this.orderId,
    required this.orderToken,
    this.code,
    required this.orderStatus,
    required this.orderStatusLabel,
    required this.subtotal,
    required this.taxAmount,
    required this.shippingAmount,
    required this.discountAmount,
    required this.paymentFee,
    required this.totalAmount,
    this.paymentStatus,
    this.paymentStatusLabel,
    this.paymentMethod,
    this.paymentId,
    this.cartId,
    this.chargeId,
    this.isFinished,
    this.createdAt,
    this.razorpay,
  });

  /// The numeric `ec_orders.id`.
  ///
  /// Persist this the instant checkout returns, together with [orderToken]:
  /// `GET /orders` and `GET /orders/{id}` both filter `is_finished = 1`, so an
  /// order awaiting payment 404s there and these two values are the only handle
  /// on it. This is also the id `confirm-payment` wants in `order_id`.
  final int orderId;

  /// 32-hex order token. Not used by any request the app makes, but it is the
  /// only other identifier that survives a crash before payment, so support can
  /// find the order with it.
  final String orderToken;

  /// The customer-facing order code — `SF10000315`.
  ///
  /// **Null today.** `API/CheckoutController` returns `order_id` and
  /// `order_token` and no code, from either `checkout/cart/{id}` or
  /// `checkout/confirm-payment`, and the order cannot be read from
  /// `GET /orders/{id}` until it is paid for (that route filters
  /// `is_finished = 1`). So between placing and paying, the app has no code to
  /// show and shows no identifier at all.
  ///
  /// It is parsed here so the moment the backend adds
  /// `'code' => \$order->code` to those payloads, the checkout screen starts
  /// printing the real code with no further change.
  ///
  /// **Never derive it.** `get_order_code()` is
  /// `store_order_prefix + (default_order_start_number + id) + store_order_suffix`
  /// — three admin-configurable settings. `'SF' + (10000000 + id)` matches
  /// today's data and would go silently wrong the day the merchant edits any
  /// of them.
  final String? code;

  /// [code] as it should be rendered — the same rule [Order.displayCode]
  /// applies.
  ///
  /// Two incompatible formats coexist on this shop: `SF10000277` on the newer
  /// orders and `#SF-10000016` on the older ones. The leading `#` is part of
  /// the stored value, not decoration, so a screen that prints `'#\$code'` — or
  /// one that prints the raw column — shows `##SF-…` on a quarter of the
  /// catalogue. Strip it once, here.
  String? get displayCode {
    final raw = code?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw.startsWith('#') ? raw.substring(1) : raw;
  }

  /// `"pending"` / `"processing"` — a plain string here, unlike
  /// `GET /orders/{id}`, which returns `{value, label}` for the same concept.
  final String orderStatus;
  final String orderStatusLabel;

  /// `"pending"` or `"completed"`, plain string, and **null on the branch that
  /// finalises the order inside checkout**.
  ///
  /// On the checkout response this is always the literal `"pending"` — the
  /// payment row is created pending and never refreshed — so it carries no
  /// information there. It only means something on confirm-payment; see
  /// [isPaymentCompleted].
  final String? paymentStatus;
  final String? paymentStatusLabel;

  /// Echo of the request, so always `"razorpay"` for this app. Null on the
  /// zero-amount branch.
  final String? paymentMethod;

  /// Sum of line prices, **excluding** tax. Tax is added on top by this backend,
  /// not included in the price.
  final CartMoney subtotal;
  final CartMoney taxAmount;

  /// What the order was actually billed for delivery — **the server's own
  /// figure, and the only delivery charge that may ever be displayed.**
  ///
  /// The app does **not** send `shipping_amount`. It sends
  /// `shipping_method: "shiprocket"` plus a `shipping_option` naming one
  /// Shiprocket rate id, and the server prices the order itself, by looking
  /// that option up in a rate table it rebuilds by calling Shiprocket again
  /// (`API/CheckoutController.php:437-446`). So this field is not an echo of
  /// anything the app chose; it is the answer to a question the app asked.
  ///
  /// **It can differ from the rate the app displayed, in both directions**, and
  /// none of the ways are errors the server reports:
  ///
  ///   * the re-quote's pickup postcode is `origin.zip_code`, i.e.
  ///     `get_ecommerce_setting('store_zip_code')`
  ///     (`EcommerceHelper.php:1102,1114`), falling back to the marketplace
  ///     store's own zip and then to `shiprocket_default_pickup_postcode`
  ///     (`ShipRocketService.php:1715-1740`). Reconstructing 18 real 2026
  ///     Shiprocket orders put that origin at **311001**, which is what
  ///     `kDefaultPickupPinCode` holds — 5 matched to the paisa and 9 more to a
  ///     rate-card revision. But the setting has no public route, so this is
  ///     evidence, not a guarantee; see `docs/VERIFIED_API_CONTRACT.md` §4.5;
  ///   * a Shiprocket rate id identifies a *quote*, not a courier, so the key
  ///     the app sent can simply be absent from the table the server built. The
  ///     lookup then misses in silence and this lands as **0.00** — an
  ///     undercharge on a real, dispatchable order;
  ///   * a free-shipping coupon zeroes it server-side after pricing;
  ///   * the server's price is `freight_charge + coverage_charges +
  ///     other_charges`, plus `cod_charges` on a COD order
  ///     (`ShipRocketService.php:1874-1894`) — a recomputation of the courier
  ///     row rather than its `rate` field. The two coincide only while coverage
  ///     and other charges are zero, which stops being true as the basket grows:
  ///     live on 2026-08-04, 311001→382415 at `declared_value` 314 every row had
  ///     `coverage_charges: 0`, and at 3108 every row had `49.00` — money `rate`
  ///     does not contain. The app still displays `rate`
  ///     (`shipping_quote.dart`), so it under-quotes high-value baskets by
  ///     exactly that amount; tracked in `docs/KNOWN_ISSUES.md`.
  ///
  /// That is why the checkout flow must reconcile this response against the
  /// total the customer was shown *before* opening the Razorpay sheet, and let
  /// them decline. See [totalMatches].
  ///
  /// Never re-added to anything: [totalAmount] already contains it.
  final CartMoney shippingAmount;

  final CartMoney discountAmount;
  final CartMoney paymentFee;

  /// The payable total, and the only total to display. `razorpay.amount` is this
  /// number in paise.
  final CartMoney totalAmount;

  /// The *provisional* pending payments row created at checkout.
  ///
  /// Do not persist or display it: confirm-payment inserts a **new** payment row
  /// (the provisional one has a null `charge_id`, so the lookup misses) and
  /// repoints the order at it, orphaning this id. Read payment state from
  /// `GET /orders/{id}` instead.
  final int? paymentId;

  /// Echo of the cart id that was checked out. Checkout only.
  ///
  /// Note the server does **not** delete that cart on the razorpay branch, so
  /// the same id would happily mint a second order — discard it locally once the
  /// order is settled.
  final String? cartId;

  /// The server-generated charge id, echoing `razorpay_payment_id`.
  /// Confirm-payment only.
  final String? chargeId;

  /// `null` means the key was **absent**, which is itself the signal for the
  /// already-finalised checkout branch.
  ///
  /// Never branch on this to decide whether to take payment — it is hardcoded
  /// `false` on the razorpay branch and missing on the branch where the order is
  /// already done. Use [requiresPayment]. And note the server sets it to true
  /// unconditionally at confirm time, with no payment-status check, so `true`
  /// means *finalised*, never *paid*.
  final bool? isFinished;

  final DateTime? createdAt;

  /// Null whenever there is nothing to collect. See [requiresPayment].
  final RazorpayHandoff? razorpay;

  /// The `payment_status` that means the money actually landed.
  ///
  /// The server sets it only when the Razorpay *order* object comes back with
  /// `status == "paid"`; every other Razorpay status yields `"pending"`.
  static const String paidPaymentStatus = 'completed';

  /// **The one question to ask a checkout response.**
  ///
  /// True: open the Razorpay SDK with [razorpay], then confirm-payment.
  /// False: the order is already finalised — skip the SDK *and* skip
  /// confirm-payment, and go straight to `GET /orders/{id}`.
  ///
  /// This exists because the alternative discriminators are all wrong:
  /// `is_finished` is absent on exactly the branch that needs detecting, and
  /// `payment_status` is the literal `"pending"` on the branch that does need
  /// paying.
  ///
  /// **Presence, not usability, on purpose.** A `razorpay` block that is present
  /// but malformed — blank `razorpay_order_id`, blank key, a non-integer
  /// `amount` (see [RazorpayHandoff._paise]) — still means the server put this
  /// order on the pay-online branch and money is due. Narrowing this getter to
  /// "…and the block is usable" would send exactly that order down the *false*
  /// branch, which clears the cart and shows a paid receipt for an order nobody
  /// paid for. The usability check therefore lives one step later, where the
  /// payment request is built (`PendingOrder.toPaymentRequest`): a block that
  /// cannot open a sheet stops there, with the order intact and the customer
  /// told to contact support. The SDK is never opened with a broken handoff.
  bool get requiresPayment => razorpay != null;

  /// The paise figure the Razorpay sheet will actually open at, or null when
  /// there is nothing to collect ([requiresPayment] is false).
  ///
  /// **Already in paise, and not derivable from [totalAmount].** The server
  /// computes it as `(int) round($order->amount * 100)` — the same expression
  /// it used to create the Razorpay order — so this is the authoritative
  /// integer, and `(totalAmount.amount * 100).round()` can differ by a step
  /// once a double has been through JSON. Reconciliation UI should *display*
  /// [totalAmount] (the server's own decimal string, exact) and *compare*
  /// against this only when it needs the number the card is charged.
  ///
  /// `0` is possible and means the wire value was not whole minor units — see
  /// [RazorpayHandoff.amountInPaise]. Treat non-positive as "cannot open a
  /// sheet", never as "free".
  int? get amountInPaise => razorpay?.amountInPaise;

  /// Whether [totalAmount] is the same money as [expected].
  ///
  /// **This is the reconciliation check**, and it exists so nobody writes
  /// `order.totalAmount.amount == shownTotal`. Both sides are doubles that have
  /// been through a decimal string, so `==` is a coin toss on any total with
  /// paise; the tolerance here is half a paise, which is exactly "these two
  /// round to the same billable figure".
  ///
  /// Call it with the total the customer was shown, before opening the payment
  /// sheet. False in **either** direction is a divergence worth stopping for:
  /// an undercharge is what a missed `shipping_option` looks like (the server
  /// prices delivery at 0.00 and says nothing), and it is as much a mismatch
  /// between the button and the bill as an overcharge is.
  bool totalMatches(double expected) =>
      (totalAmount.amount - expected).abs() < 0.005;

  /// True only when the server saw Razorpay report the order paid.
  ///
  /// `HTTP 200` and `success: true` on confirm-payment do **not** mean paid: the
  /// server finalises the order either way — stock decrement, invoice, SMS — and
  /// reports `payment_status: "pending"` when the money did not land. Branch on
  /// this, and confirm it against `GET /orders/{id}` before showing a receipt.
  bool get isPaymentCompleted => paymentStatus == paidPaymentStatus;

  factory PlacedOrder.fromJson(Map<String, dynamic> j) => PlacedOrder(
        orderId: asInt(j['order_id']),
        code: asStringOrNull(j['code']),
        orderToken: asString(j['order_token']),
        orderStatus: asString(j['order_status']),
        orderStatusLabel: asString(j['order_status_label']),
        paymentStatus: asStringOrNull(j['payment_status']),
        paymentStatusLabel: asStringOrNull(j['payment_status_label']),
        paymentMethod: asStringOrNull(j['payment_method']),
        subtotal: _money(j, 'subtotal'),
        taxAmount: _money(j, 'tax_amount'),
        shippingAmount: _money(j, 'shipping_amount'),
        discountAmount: _money(j, 'discount_amount'),
        paymentFee: _money(j, 'payment_fee'),
        totalAmount: _money(j, 'total_amount'),
        paymentId: j['payment_id'] == null ? null : asInt(j['payment_id']),
        cartId: asStringOrNull(j['cart_id']),
        chargeId: asStringOrNull(j['charge_id']),
        // containsKey, not a null check: absence is the signal, and the server
        // never sends this key as null.
        isFinished:
            j.containsKey('is_finished') ? asBool(j['is_finished']) : null,
        createdAt: DateTime.tryParse(asString(j['created_at'])),
        razorpay: RazorpayHandoff.tryFrom(j['razorpay']),
      );

  /// Parses an order out of either endpoint's body, or returns null.
  ///
  /// These two endpoints use `{"success": …, "message": …, "data": {…}}` — not
  /// the `{error, data, message}` envelope the rest of the app sees — so the
  /// envelope is unwrapped here rather than by `unwrapObject`. `order_id` is the
  /// discriminator: an error body has no `data` object at all, and a redirect
  /// that was followed into an HTML login page is not a Map.
  static PlacedOrder? tryFrom(dynamic body) {
    final source = body is Map && body['data'] is Map ? body['data'] : body;
    if (source is! Map) return null;
    final json = Map<String, dynamic>.from(source);
    if (json['order_id'] == null) return null;
    return PlacedOrder.fromJson(json);
  }

  /// Reads one of this endpoint's money fields into the app's one money type.
  ///
  /// [CartMoney] is deliberately reused: there is exactly one money convention
  /// in this app and a second one would be two places to get GST wrong. But the
  /// wire shape differs from the cart's, in two ways that matter:
  ///
  ///   * the amount arrives as a decimal **string** (`"803.25"`), because the
  ///     `ec_orders` columns are `decimal(15,2)` with no model cast;
  ///   * there are no `_formatted` twins, so the server ships no label.
  ///
  /// So the label is built here from the server's own decimal digits rather than
  /// from the parsed double. Grouping a string cannot round, which keeps
  /// `total_amount` displayable *verbatim* — it is the figure the customer's
  /// card is charged, down to the paise. The double stays what [CartMoney] says
  /// it is: for arithmetic and comparisons only.
  static CartMoney _money(Map<String, dynamic> j, String key) {
    final raw = j[key];
    return CartMoney(
      asDouble(raw),
      raw is String ? _labelFor(raw.trim()) : null,
    );
  }

  /// `decimal(15,2)` as the server writes it: optional sign, digits, optional
  /// fraction. Anything else (a number, a null, `"1.2e3"`) falls back to
  /// [CartMoney]'s own formatting of the double.
  static final RegExp _decimalString = RegExp(r'^-?\d+(\.\d+)?$');

  /// Renders `"1602.5"` as `"₹1,602.50"` using Indian digit grouping, without
  /// ever going through a double. Returns null when [value] is not a plain
  /// decimal, or carries more than two decimal places — rounding a third place
  /// is a job for `PriceUtils`, not for string surgery.
  static String? _labelFor(String value) {
    if (!_decimalString.hasMatch(value)) return null;

    final negative = value.startsWith('-');
    final unsigned = negative ? value.substring(1) : value;
    final dot = unsigned.indexOf('.');
    final whole = dot == -1 ? unsigned : unsigned.substring(0, dot);
    final fraction = dot == -1 ? '' : unsigned.substring(dot + 1);
    if (fraction.length > 2) return null;

    final paise = fraction.padRight(2, '0');
    return '${negative ? '-' : ''}₹${_groupIndian(whole)}.$paise';
  }

  /// Last three digits, then pairs: `1234567` -> `12,34,567`.
  static String _groupIndian(String digits) {
    if (digits.length <= 3) return digits;
    final head = digits.substring(0, digits.length - 3);
    final tail = digits.substring(digits.length - 3);
    final buffer = StringBuffer();
    for (var i = 0; i < head.length; i++) {
      if (i > 0 && (head.length - i).isEven) buffer.write(',');
      buffer.write(head[i]);
    }
    return '$buffer,$tail';
  }
}

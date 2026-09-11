/// The one file in `lib/` allowed to import `razorpay_flutter`.
///
/// Its whole job is turning a callback API into a Future without losing or
/// duplicating an outcome. Three properties of `razorpay_flutter` make that
/// less trivial than it sounds, and each is defended against below:
///
///  1. **It can deliver more than one event per checkout.** `Razorpay.on()`
///     calls a private `_resync()` on every registration — three listeners,
///     three `resync` round-trips — and each one can return the same stored
///     reply. Guarded by [_Checkout._settled].
///
///  2. **A `resync` reply can be *stale*.** The native delegate parks a result
///     in `pendingReply` when the Flutter result handle is already gone (the
///     process was killed mid-payment) and hands it to whoever registers a
///     listener next — which may be an entirely different checkout, for an
///     entirely different order. Guarded by comparing the returned
///     `razorpay_order_id` against the one the sheet was opened with.
///
///  3. **It can deliver *nothing*.** `Razorpay.open()` is `void ... async` and
///     awaits a platform channel; if that throws (plugin not registered, no
///     attached Activity) the error surfaces as an unhandled async error
///     *inside the plugin* and no event is ever emitted. Guarded by
///     [_Checkout._watchdog], without which `pay()` would hang forever and take
///     the checkout screen with it.
///
/// Listener hygiene: a fresh `Razorpay` instance per sheet, `clear()` on every
/// exit path. Reusing one instance across checkouts stacks listeners — the
/// second payment then completes the first one's Completer too.
library;

import 'dart:async';

import 'package:razorpay_flutter/razorpay_flutter.dart';

import 'payment_gateway.dart';

/// [PaymentGateway] backed by Razorpay Standard Checkout.
class RazorpayGateway implements PaymentGateway {
  /// [createRazorpay] exists for tests, which cannot let a real `Razorpay`
  /// touch the platform channel. Production callers use the default.
  RazorpayGateway({Razorpay Function()? createRazorpay})
      : _createRazorpay = createRazorpay ?? Razorpay.new;

  /// Shown as the heading on the sheet. Fixed, not configurable: it is the
  /// merchant identity, not a per-order value.
  static const String merchantName = 'Trueway Farms';

  /// How long after the sheet's own timeout we wait before declaring the SDK
  /// silent. Generous on purpose — a customer part-way through a bank OTP is
  /// not a failure, and Razorpay dismisses the sheet itself at
  /// [PaymentRequest.timeout].
  static const Duration watchdogGrace = Duration(minutes: 2);

  final Razorpay Function() _createRazorpay;

  _Checkout? _open;
  bool _disposed = false;

  @override
  Future<PaymentResult> pay(PaymentRequest request) {
    if (_disposed) {
      return Future.value(
        const PaymentFailed(
          code: PaymentFailureCodes.notStarted,
          message: 'The payment gateway is no longer available.',
        ),
      );
    }
    if (_open != null) {
      // Opening a second sheet would leave two Completers racing on one native
      // callback stream. Refuse, and leave the sheet that is already up alone.
      return Future.value(
        const PaymentFailed(
          code: PaymentFailureCodes.notStarted,
          message: 'A payment is already in progress.',
        ),
      );
    }

    final checkout = _Checkout(_createRazorpay(), request);
    _open = checkout;
    // Runs however the checkout ends, including a synchronous failure inside
    // start() (invalid options are emitted before Razorpay.open's first await).
    unawaited(
      checkout.result.whenComplete(() {
        if (identical(_open, checkout)) _open = null;
      }),
    );
    checkout.start();
    return checkout.result;
  }

  @override
  void dispose() {
    _disposed = true;
    _open?.abandon();
    _open = null;
  }
}

/// One sheet: one `Razorpay` instance, one [Completer], one outcome.
class _Checkout {
  _Checkout(this._razorpay, this._request);

  final Razorpay _razorpay;
  final PaymentRequest _request;
  final Completer<PaymentResult> _completer = Completer<PaymentResult>();

  Timer? _watchdog;
  bool _settled = false;

  Future<PaymentResult> get result => _completer.future;

  void start() {
    _razorpay
      ..on(Razorpay.EVENT_PAYMENT_SUCCESS, _onSuccess)
      ..on(Razorpay.EVENT_PAYMENT_ERROR, _onError)
      ..on(Razorpay.EVENT_EXTERNAL_WALLET, _onExternalWallet);

    // Registering a listener can itself deliver a stale reply synchronously,
    // so bail out if that already happened rather than open a second sheet.
    if (_settled) return;

    _watchdog = Timer(
      _request.timeout + RazorpayGateway.watchdogGrace,
      () => _settle(
        const PaymentFailed(
          code: PaymentFailureCodes.noResponse,
          message: 'The payment could not be completed. If money has left '
              'your account, do not pay again — check your orders first.',
        ),
      ),
    );

    try {
      _razorpay.open(_options());
    } catch (error) {
      // `open` is async so it should never throw into this frame. If a future
      // version does, a hung checkout screen is the worst possible outcome.
      _settle(
        PaymentFailed(
          code: PaymentFailureCodes.noResponse,
          message: 'The payment screen could not be opened. ($error)',
        ),
      );
    }
  }

  /// The options map. Every money-bearing value is copied straight from
  /// [PaymentRequest] — no scaling, no rounding, no re-derivation.
  Map<String, dynamic> _options() {
    final prefill = <String, dynamic>{};
    final email = _request.customerEmail?.trim();
    if (email != null && email.isNotEmpty) prefill['email'] = email;
    final contact = _request.customerPhone?.trim();
    if (contact != null && contact.isNotEmpty) prefill['contact'] = contact;

    final description = _request.description?.trim();

    return <String, dynamic>{
      'key': _request.keyId,
      'order_id': _request.orderId,
      // Already paise. Multiplying here would charge 100x.
      'amount': _request.amountInPaise,
      'currency': _request.currency,
      'name': RazorpayGateway.merchantName,
      if (description != null && description.isNotEmpty)
        'description': description,
      'timeout': _request.timeout.inSeconds,
      if (prefill.isNotEmpty) 'prefill': prefill,
    };
  }

  // -- callbacks ------------------------------------------------------------
  //
  // Typed as `dynamic` deliberately: `Razorpay.on` takes a bare `Function` and
  // invokes it dynamically, so a payload of an unexpected type would be a
  // runtime TypeError thrown inside the event emitter — i.e. an outcome lost
  // rather than reported.

  void _onSuccess(dynamic payload) {
    if (payload is! PaymentSuccessResponse) {
      _settle(_unexpectedPayload(payload));
      return;
    }

    final paymentId = payload.paymentId?.trim() ?? '';
    final orderId = payload.orderId?.trim() ?? '';
    final signature = payload.signature?.trim() ?? '';

    if (paymentId.isEmpty || orderId.isEmpty || signature.isEmpty) {
      // All three are nullable in the SDK and all three are `required` on the
      // backend. A partial triple can only 422, so do not send it — say the
      // state is unknown and let the caller reconcile against the order.
      _settle(
        const PaymentFailed(
          code: PaymentFailureCodes.incompleteSuccess,
          message: 'The payment could not be verified. If money has left your '
              'account, do not pay again — check your orders first.',
        ),
      );
      return;
    }

    if (orderId != _request.orderId) {
      // A reply for a different Razorpay order: the native side replayed a
      // result it had parked while the app was dead. Confirming it would bind
      // another order's payment to this one.
      _settle(
        const PaymentFailed(
          code: PaymentFailureCodes.orderMismatch,
          message: 'This payment belongs to a different order. Check your '
              'orders before paying again.',
        ),
      );
      return;
    }

    _settle(
      PaymentSuccess(
        paymentId: paymentId,
        orderId: orderId,
        signature: signature,
      ),
    );
  }

  void _onError(dynamic payload) {
    if (payload is! PaymentFailureResponse) {
      _settle(_unexpectedPayload(payload));
      return;
    }

    if (payload.code == Razorpay.PAYMENT_CANCELLED) {
      _settle(const PaymentCancelled());
      return;
    }

    // The plugin's native side already unwraps Razorpay's `error.description`
    // into `message`, so this is customer-readable as it stands. It falls back
    // to the raw body when that unwrap fails, hence the emptiness check.
    final message = payload.message?.trim() ?? '';
    _settle(
      PaymentFailed(
        code: payload.code,
        message: message.isEmpty ? 'The payment did not go through.' : message,
      ),
    );
  }

  void _onExternalWallet(dynamic payload) {
    final wallet =
        payload is ExternalWalletResponse ? payload.walletName?.trim() : null;
    // The app never lists external wallets, so this is defensive. It is a
    // terminal event — the sheet is gone and no triple follows it.
    _settle(
      PaymentFailed(
        code: PaymentFailureCodes.externalWalletUnsupported,
        message: wallet == null || wallet.isEmpty
            ? 'That payment method is not supported yet. Please pick another.'
            : '$wallet is not supported yet. Please pick another payment '
                'method.',
      ),
    );
  }

  PaymentFailed _unexpectedPayload(dynamic payload) => PaymentFailed(
        code: PaymentFailureCodes.noResponse,
        message: 'The payment result could not be read '
            '(${payload.runtimeType}). Check your orders before paying again.',
      );

  /// Called when the gateway is disposed with a sheet still open.
  void abandon() => _settle(
        const PaymentFailed(
          code: PaymentFailureCodes.noResponse,
          message: 'The payment was interrupted. Check your orders before '
              'paying again.',
        ),
      );

  /// The single completion point. Everything above funnels through here, so
  /// "complete once" and "always clear()" are each enforced in exactly one
  /// place.
  void _settle(PaymentResult outcome) {
    if (_settled) return;
    _settled = true;

    _watchdog?.cancel();
    _watchdog = null;

    // Safe to call from inside a callback: the emitter iterates a snapshot.
    // Skipping it leaks these three listeners into the next checkout.
    _razorpay.clear();

    _completer.complete(outcome);
  }
}

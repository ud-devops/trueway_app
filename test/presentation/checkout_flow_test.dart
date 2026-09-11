/// The place-order flow, driven through [CheckoutFlowNotifier] with every seam
/// faked — no platform channel, no socket.
///
/// What these pin is not "does it work" but the five ways this flow is allowed
/// to be wrong and must not be:
///
///   * the cart survives everything except an order proved paid;
///   * the pending-order journal survives everything except a settled order or
///     one that provably never existed;
///   * `HTTP 200 + payment_status: "pending"` never reaches a success screen;
///   * a failed payment offers the SAME razorpay order back, never a second
///     checkout;
///   * **the Razorpay sheet never opens at a total the customer was not shown.**
///     Shipping is priced by the server now, so its figure can differ in either
///     direction from the one on the button, and the order is created before the
///     app can find out.
///
/// ...and, since the crash-recovery round, the four that decide what a customer
/// whose phone died mid-payment is told:
///
///   * **a restart does not lose the order.** The flow starts from the journal,
///     so an unpaid order is still on screen and still payable, and the live
///     cart bill does not come back in its place;
///   * **the journal names the sheet BEFORE it opens**, so "killed during
///     payment" is distinguishable from "killed before payment";
///   * **nothing says "nothing was charged" unless the journal proves it.** The
///     order endpoints cannot supply that proof: both filter `is_finished = 1`,
///     so an unpaid order is simply absent from them;
///   * **a failure after the order exists is never shown as "it was not
///     placed"**, whatever fails.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/payments/payment_gateway.dart';
import 'package:trueway_farms/data/models/order.dart';
import 'package:trueway_farms/data/models/placed_order.dart';
import 'package:trueway_farms/data/repositories/checkout_repository.dart';
import 'package:trueway_farms/data/repositories/order_repository.dart';
import 'package:trueway_farms/presentation/providers/checkout_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';

const _address = CheckoutAddress(
  name: 'Suraj Ojha',
  email: 'suraj.ojha@uminber.in',
  phone: '9876543210',
  address: '306, Jahnavi Arcade',
  city: 'Ahmedabad',
  state: 'Gujarat',
  zipCode: '382415',
);

/// The total the app would have shown for [_placed]'s default order: goods
/// 943.95 plus the courier's 330.20. Every non-divergence test passes exactly
/// this as `shownTotal`, so the reconciliation is a no-op and the flow runs
/// straight through — which is what those tests are about.
const double _shownTotal = 1274.15;

/// The courier rate inside [_shownTotal]. Passed alongside it everywhere,
/// because a server shipping line of 0.00 can only be recognised as a *missing*
/// one against a quote that was not zero.
const double _shownShipping = 330.20;

/// [total] and [shipping] are the SERVER's figures. `razorpay.amount` is
/// derived from [total] the way the server derives it — `(int) round($amount *
/// 100)` — so a test that moves the total cannot accidentally leave the sheet
/// opening at the old one.
///
/// [razorpayPaise] overrides that derivation — the one thing the server is
/// trusted never to do, and which nothing checked until the sheet-amount
/// assertion.
PlacedOrder _placed({
  bool razorpay = true,
  String total = '1274.15',
  String shipping = '330.20',
  int? razorpayPaise,
}) =>
    PlacedOrder.tryFrom({
      'success': true,
      'data': {
        'order_id': 1287,
        'order_token': 'tok',
        'order_status': 'pending',
        'order_status_label': 'Pending',
        'payment_status': 'pending',
        'payment_status_label': 'Pending',
        'payment_method': 'razorpay',
        'subtotal': '899.00',
        'tax_amount': '44.95',
        'shipping_amount': shipping,
        'discount_amount': '0.00',
        'payment_fee': '0.00',
        'total_amount': total,
        'cart_id': 'cart-1',
        if (razorpay) 'is_finished': false,
        if (razorpay)
          'razorpay': {
            'razorpay_order_id': 'order_abc',
            'razorpay_key_id': 'rzp_test',
            'amount': razorpayPaise ?? (double.parse(total) * 100).round(),
            'currency': 'INR',
          },
      },
    })!;

PlacedOrder _confirmed() => PlacedOrder.tryFrom({
      'data': {
        'order_id': 1287,
        'order_token': 'tok',
        'order_status': 'processing',
        'order_status_label': 'Processing',
        'payment_status': 'completed',
        'payment_status_label': 'Completed',
        'subtotal': '899.00',
        'tax_amount': '44.95',
        'shipping_amount': '330.20',
        'discount_amount': '0.00',
        'payment_fee': '0.00',
        'total_amount': '1274.15',
        'is_finished': true,
      },
    })!;

class _FakeCheckout implements CheckoutRepository {
  _FakeCheckout({
    required this.place,
    required this.confirm,
    this.confirmThrows = false,
  });

  final PlaceOrderOutcome place;
  final ConfirmPaymentOutcome confirm;

  /// The repository documents that `confirmPayment` never throws. This is the
  /// "and if it did" case: it runs after the order exists, so whatever it does
  /// must not reach the customer as a checkout that failed.
  final bool confirmThrows;
  Map<String, dynamic>? lastBody;

  /// How many times the non-idempotent call was made. Every path through this
  /// flow must leave it at one — including the divergence branch, where the
  /// customer says yes to a *new* figure and it would be very easy to re-place
  /// the order rather than reopen the existing Razorpay one.
  int placeCalls = 0;

  @override
  Future<PlaceOrderOutcome> placeOrder({
    required String cartId,
    required CheckoutAddress address,
    required String? shippingOptionKey,
    String? notes,
    CheckoutAddress? billingAddress,
    Map<String, dynamic>? taxInformation,
  }) async {
    placeCalls++;
    lastBody = {'cart_id': cartId, 'shipping_option': shippingOptionKey};
    return place;
  }

  @override
  Future<ConfirmPaymentOutcome> confirmPayment({
    required int orderId,
    required String razorpayPaymentId,
    required String razorpayOrderId,
    required String razorpaySignature,
  }) async {
    if (confirmThrows) throw Exception('the platform channel died');
    return confirm;
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _FakeGateway implements PaymentGateway {
  _FakeGateway(this.result, {this.onPay});
  final PaymentResult result;

  /// Runs at the instant the sheet would be on screen — which is the only
  /// moment at which "what does the journal say right now?" is the question
  /// that matters.
  final void Function()? onPay;
  PaymentRequest? seen;

  @override
  Future<PaymentResult> pay(PaymentRequest request) async {
    seen = request;
    onPay?.call();
    return result;
  }

  @override
  void dispose() {}
}

/// A journal whose writes stop working part-way through a checkout.
///
/// Stands in for a full disk, a corrupt prefs file, or the platform channel
/// being torn down under a backgrounded app. The point is not which of those it
/// is: it is that the failure happens *after* the order exists, where the flow
/// used to let the exception escape and the screen painted it as a checkout
/// that failed.
class _FailingStore implements PendingOrderStore {
  _FailingStore(this._inner, {required this.writesBeforeFailing});

  final PendingOrderStore _inner;
  final int writesBeforeFailing;
  int writes = 0;

  @override
  PendingOrder? read() => _inner.read();

  @override
  Future<void> write(PendingOrder record) async {
    writes++;
    if (writes > writesBeforeFailing) {
      throw Exception('SharedPreferences: no space left on device');
    }
    await _inner.write(record);
  }

  @override
  Future<void> clear() => _inner.clear();

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

/// `GET /orders/{id}` for an order that has not been finalised.
///
/// Both order reads filter `is_finished = 1`, so an unpaid order — the thing a
/// declined payment leaves behind — 404s on every lookup the app can make. That
/// is emphatically **not** "the order does not exist"; the id came from a 200 on
/// the checkout POST.
class _MissingOrders implements OrderRepository {
  @override
  Future<Order> order(int id) async => throw const ApiException(
        'Order not found',
        kind: ApiErrorKind.notFound,
        statusCode: 404,
      );

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _FakeOrders implements OrderRepository {
  _FakeOrders(this.status);
  final String status;

  @override
  Future<Order> order(int id) async => Order.fromJson({
        'id': id,
        'code': 'SF10001287',
        'amount': '1274.15',
        'amount_formatted': '₹1,274.15',
        'payment_status': {'value': status, 'label': 'X'},
        'products': const [],
      });

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

Future<ProviderContainer> _container({
  required PlaceOrderOutcome place,
  ConfirmPaymentOutcome? confirm,
  bool confirmThrows = false,
  PaymentResult gateway = const PaymentSuccess(
    paymentId: 'pay_1',
    orderId: 'order_abc',
    signature: 'sig',
  ),
  void Function(ProviderContainer container)? onPay,
  String lookup = 'completed',
  /// The journal as a previous run left it on disk. This is what a *restart*
  /// is, as far as this file can see one: the process is new, the record is
  /// not.
  String? journal,
  int? failJournalAfterWrites,
  bool ordersMissing = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'server_cart_id_v1': 'cart-1',
    if (journal != null) PendingOrderStore.key: journal,
  });
  final prefs = await SharedPreferences.getInstance();
  late final ProviderContainer container;
  container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      if (failJournalAfterWrites != null)
        pendingOrderStoreProvider.overrideWith(
          (ref) => _FailingStore(
            PendingOrderStore(prefs),
            writesBeforeFailing: failJournalAfterWrites,
          ),
        ),
      checkoutRepositoryProvider.overrideWithValue(
        _FakeCheckout(
          place: place,
          confirm: confirm ?? PaymentConfirmed(_confirmed()),
          confirmThrows: confirmThrows,
        ),
      ),
      paymentGatewayProvider.overrideWithValue(
        _FakeGateway(gateway, onPay: () => onPay?.call(container)),
      ),
      orderRepositoryProvider.overrideWithValue(
        ordersMissing ? _MissingOrders() : _FakeOrders(lookup),
      ),
    ],
  );
  return container;
}

/// One journal record, as [PendingOrderStore] would find it after a restart.
///
/// [version] is written the way the store writes it, so a record from the build
/// *before* [PendingOrderStage.paymentOpened] existed can be produced verbatim
/// — the whole point being that its `created` cannot be read as proof the sheet
/// never opened.
String _journal({
  PendingOrderStage stage = PendingOrderStage.created,
  int? orderId = 1287,
  Duration age = Duration.zero,
  bool razorpay = true,
  bool triple = false,
  int version = PendingOrder.currentVersion,
}) {
  final json = PendingOrder(
    cartId: 'cart-1',
    stage: stage,
    createdAt: DateTime.now().subtract(age),
    orderId: orderId,
    orderToken: 'tok',
    totalAmount: '₹1,274.15',
    totalAmountValue: 1274.15,
    razorpayOrderId: razorpay ? 'order_abc' : null,
    razorpayKeyId: razorpay ? 'rzp_test' : null,
    amountPaise: razorpay ? 127415 : null,
    currency: razorpay ? 'INR' : null,
    razorpayPaymentId: triple ? 'pay_1' : null,
    razorpaySignature: triple ? 'sig' : null,
  ).toJson();
  if (version < PendingOrder.currentVersion) {
    // Exactly what v1 wrote: no version marker at all.
    json.remove('v');
  }
  return jsonEncode(json);
}

/// Nothing in [message] may claim the customer's money is safe.
void expectNoUnchargedClaim(String? message) {
  expect(message, isNotNull);
  expect(message!.toLowerCase(), isNot(contains('nothing has been charged')));
  expect(message.toLowerCase(), isNot(contains('nothing was charged')));
  expect(message.toLowerCase(), isNot(contains('has not been paid for')));
  expect(message.toLowerCase(), isNot(contains('was not placed')));
}

void main() {
  test('happy path settles, clears the journal and forgets the cart', () async {
    final c = await _container(place: OrderPlaced(_placed()));
    addTearDown(c.dispose);

    await c.read(checkoutFlowProvider.notifier).placeOrder(
          cartId: 'cart-1',
          address: _address,
          shippingOptionKey: 'shiprocket_1016322646',
          shownTotal: _shownTotal,
          shownShipping: _shownShipping,
        );

    final state = c.read(checkoutFlowProvider);
    expect(state.phase, CheckoutPhase.paid);
    expect(state.orderId, 1287);
    expect(state.serverTotal, '₹1,274.15');
    expect(c.read(pendingOrderStoreProvider).read(), isNull);
    expect(
      c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
      isNull,
    );
    final fake = c.read(checkoutRepositoryProvider) as _FakeCheckout;
    // The courier reaches the server as a member key, not as a price. Sending
    // `shipping_amount` instead is what the product decision removed.
    expect(fake.lastBody!['shipping_option'], 'shiprocket_1016322646');
    expect(fake.lastBody!.containsKey('shipping_amount'), isFalse);
  });

  test('no razorpay block skips the SDK and confirm-payment', () async {
    final c = await _container(place: OrderPlaced(_placed(razorpay: false)));
    addTearDown(c.dispose);

    await c.read(checkoutFlowProvider.notifier).placeOrder(
          cartId: 'cart-1',
          address: _address,
          shippingOptionKey: 'shiprocket_1016322646',
          shownTotal: _shownTotal,
          shownShipping: _shownShipping,
        );

    expect(c.read(checkoutFlowProvider).phase, CheckoutPhase.paid);
    final gateway = c.read(paymentGatewayProvider) as _FakeGateway;
    expect(gateway.seen, isNull);
  });

  // TEMPORARY behaviour — see docs/TODO_CANCELLED_PAYMENT_FLOW.md. A
  // dismissed sheet used to park the flow at `paymentIncomplete` with a
  // retry-same-order path; per the interim product decision it now abandons
  // the order (journal settled, one-shot `cancelledBackToCart` phase) and the
  // screen pops back to the cart, where the next checkout creates a fresh
  // order. The permanent version is specced in that file.
  test('a cancelled sheet abandons the order and heads back to the cart',
      () async {
    final c = await _container(
      place: OrderPlaced(_placed()),
      gateway: const PaymentCancelled(),
    );
    addTearDown(c.dispose);

    await c.read(checkoutFlowProvider.notifier).placeOrder(
          cartId: 'cart-1',
          address: _address,
          shippingOptionKey: 'shiprocket_1016322646',
          shownTotal: _shownTotal,
          shownShipping: _shownShipping,
        );

    final state = c.read(checkoutFlowProvider);
    expect(state.phase, CheckoutPhase.cancelledBackToCart);
    expect(state.isPaid, isFalse);
    // Not offered any more: the whole point is that the customer never sees
    // "retry" or "start a new order" on this path.
    expect(state.canRetryPayment, isFalse);
    expect(state.canStartOver, isFalse);

    // The journal is settled — `PaymentCancelled` is the SDK's own report
    // that no payment happened, so dropping the record cannot lose a paid
    // order. Settled means the recovery pass and rehydration both ignore it,
    // and the next checkout starts clean.
    final record = c.read(pendingOrderStoreProvider).read();
    expect(record!.stage, PendingOrderStage.settled);

    // The basket survives — it is what the next checkout will re-order.
    expect(
      c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
      'cart-1',
    );
  });

  test('after a cancelled sheet, a second checkout creates a fresh order',
      () async {
    final c = await _container(
      place: OrderPlaced(_placed()),
      gateway: const PaymentCancelled(),
    );
    addTearDown(c.dispose);
    final notifier = c.read(checkoutFlowProvider.notifier);

    await notifier.placeOrder(
      cartId: 'cart-1',
      address: _address,
      shippingOptionKey: 'shiprocket_1016322646',
      shownTotal: _shownTotal,
      shownShipping: _shownShipping,
    );
    expect(
      c.read(checkoutFlowProvider).phase,
      CheckoutPhase.cancelledBackToCart,
    );

    // The screen resets on its way out; a container test does it directly.
    notifier.reset();
    expect(c.read(checkoutFlowProvider).phase, CheckoutPhase.idle);

    // Second attempt goes back through the checkout POST — a genuinely new
    // order — rather than reopening the abandoned one's Razorpay sheet.
    await notifier.placeOrder(
      cartId: 'cart-1',
      address: _address,
      shippingOptionKey: 'shiprocket_1016322646',
      shownTotal: _shownTotal,
      shownShipping: _shownShipping,
    );
    final repo = c.read(checkoutRepositoryProvider) as _FakeCheckout;
    expect(repo.placeCalls, 2);
  });

  test('200 with payment_status pending never shows success', () async {
    final c = await _container(
      place: OrderPlaced(_placed()),
      confirm: PaymentNotReceived(_placed()),
    );
    addTearDown(c.dispose);

    await c.read(checkoutFlowProvider.notifier).placeOrder(
          cartId: 'cart-1',
          address: _address,
          shippingOptionKey: 'shiprocket_1016322646',
          shownTotal: _shownTotal,
          shownShipping: _shownShipping,
        );

    expect(c.read(checkoutFlowProvider).phase, CheckoutPhase.verifying);
    expect(c.read(pendingOrderStoreProvider).read(), isNotNull);
    expect(
      c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
      'cart-1',
    );
  });

  test('confirm-payment success is still proved against the order', () async {
    // The server never checks that the payment it verified belongs to the
    // order it is confirming, so its 200 is evidence, not proof. If the order
    // itself is not `completed`, no receipt.
    final c = await _container(
      place: OrderPlaced(_placed()),
      confirm: PaymentConfirmed(_confirmed()),
      lookup: 'pending',
    );
    addTearDown(c.dispose);

    await c.read(checkoutFlowProvider.notifier).placeOrder(
          cartId: 'cart-1',
          address: _address,
          shippingOptionKey: 'shiprocket_1016322646',
          shownTotal: _shownTotal,
          shownShipping: _shownShipping,
        );

    expect(c.read(checkoutFlowProvider).phase, CheckoutPhase.verifying);
    expect(
      c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
      'cart-1',
    );
  });

  test('already-processed is gated on GET /orders/{id}', () async {
    final c = await _container(
      place: OrderPlaced(_placed()),
      confirm: PaymentAlreadyProcessed(
        orderId: 1287,
        error: const ApiException('already', statusCode: 422),
      ),
      lookup: 'pending',
    );
    addTearDown(c.dispose);

    await c.read(checkoutFlowProvider.notifier).placeOrder(
          cartId: 'cart-1',
          address: _address,
          shippingOptionKey: 'shiprocket_1016322646',
          shownTotal: _shownTotal,
          shownShipping: _shownShipping,
        );

    expect(c.read(checkoutFlowProvider).phase, CheckoutPhase.verifying);
  });

  test('a transport failure is unknown, not a failure', () async {
    final c = await _container(
      place: const CheckoutOutcomeUnknown(ApiException('timed out')),
    );
    addTearDown(c.dispose);

    await c.read(checkoutFlowProvider.notifier).placeOrder(
          cartId: 'cart-1',
          address: _address,
          shippingOptionKey: 'shiprocket_1016322646',
          shownTotal: _shownTotal,
          shownShipping: _shownShipping,
        );

    final state = c.read(checkoutFlowProvider);
    expect(state.phase, CheckoutPhase.unresolved);
    expect(state.needsReconciliation, isTrue);
    expect(c.read(pendingOrderStoreProvider).read(), isNotNull);
  });

  test('a 4xx refusal drops the journal and keeps the cart', () async {
    final c = await _container(
      place: const CheckoutRefused(
        ApiException('Product 118 is out of stock!', statusCode: 422),
      ),
    );
    addTearDown(c.dispose);

    await c.read(checkoutFlowProvider.notifier).placeOrder(
          cartId: 'cart-1',
          address: _address,
          shippingOptionKey: 'shiprocket_1016322646',
          shownTotal: _shownTotal,
          shownShipping: _shownShipping,
        );

    final state = c.read(checkoutFlowProvider);
    expect(state.phase, CheckoutPhase.refused);
    expect(state.message, 'Product 118 is out of stock!');
    expect(c.read(pendingOrderStoreProvider).read(), isNull);
    expect(
      c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
      'cart-1',
    );
  });

  test('a bad address never reaches the wire', () async {
    final c = await _container(place: OrderPlaced(_placed()));
    addTearDown(c.dispose);

    await c.read(checkoutFlowProvider.notifier).placeOrder(
          cartId: 'cart-1',
          address: const CheckoutAddress(
            name: 'A',
            email: 'x',
            phone: '123',
            address: '',
            city: '',
            state: '',
            zipCode: '0',
          ),
          shippingOptionKey: 'shiprocket_1016322646',
          shownTotal: _shownTotal,
          shownShipping: _shownShipping,
        );

    final state = c.read(checkoutFlowProvider);
    expect(state.phase, CheckoutPhase.refused);
    expect(state.fieldErrors, isNotEmpty);
    expect((c.read(checkoutRepositoryProvider) as _FakeCheckout).lastBody, isNull);
    expect(c.read(pendingOrderStoreProvider).read(), isNull);
  });

  // -------------------------------------------------------------------------
  // The server's total is not the total on the button
  // -------------------------------------------------------------------------

  group('total divergence', () {
    /// The sheet was never opened, so nothing has been charged.
    void expectNothingCharged(ProviderContainer c) {
      expect((c.read(paymentGatewayProvider) as _FakeGateway).seen, isNull);
    }

    test('a higher server total stops short of the Razorpay sheet', () async {
      // The server re-quoted Shiprocket from its own store_zip_code and got a
      // dearer courier: 1274.15 shown, 1400.00 billed.
      final c = await _container(
        place: OrderPlaced(_placed(total: '1400.00', shipping: '456.05')),
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      final state = c.read(checkoutFlowProvider);
      expect(state.phase, CheckoutPhase.totalChanged);
      expect(state.needsDecision, isTrue);
      expect(state.isBusy, isFalse);
      expectNothingCharged(c);

      final d = state.divergence!;
      expect(d.shown, _shownTotal);
      expect(d.charged, 1400.00);
      expect(d.chargedDisplay, '₹1,400.00');
      expect(d.shippingDisplay, '₹456.05');
      expect(d.isOvercharge, isTrue);
      expect(d.isMaterial, isTrue);
      // Both figures reach the customer, in the server's own rendering.
      expect(state.message, contains('₹1,400.00'));
      expect(state.message, contains('₹1,274.15'));

      // The order still exists and is still findable.
      expect(c.read(pendingOrderStoreProvider).read()!.orderId, 1287);
      expect(
        c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-1',
      );
    });

    test('a LOWER server total is surfaced too, not pocketed', () async {
      // The `shipping_option` key missed the server's table, so the delivery
      // line landed at 0.00. The customer pays less and the parcel cannot be
      // dispatched — which is a divergence, not a discount.
      final c = await _container(
        place: OrderPlaced(_placed(total: '943.95', shipping: '0.00')),
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      final state = c.read(checkoutFlowProvider);
      expect(state.phase, CheckoutPhase.totalChanged);
      expectNothingCharged(c);

      final d = state.divergence!;
      expect(d.isUndercharge, isTrue);
      expect(d.isOvercharge, isFalse);
      expect(d.shipping, 0);
      expect(d.shippingDisplay, '₹0.00');
      expect(d.isShippingMissing, isTrue);
      // The wording must not read as good news, and it names the fault rather
      // than the arithmetic: no courier reached this order.
      expect(state.message, contains('No delivery charge reached this order'));
      expect(state.message, contains('cannot be dispatched'));
    });

    test('the ordinary case runs straight through', () async {
      // 1274.15 shown, 1274.15 billed — the case that must not put a sheet in
      // front of anybody.
      final c = await _container(place: OrderPlaced(_placed()));
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      expect(c.read(checkoutFlowProvider).phase, CheckoutPhase.paid);
      // The sheet opened without anybody being asked anything.
      expect(
        (c.read(paymentGatewayProvider) as _FakeGateway).seen,
        isNotNull,
      );
    });

    test('the tolerance is floating-point dust, not 99 paise', () async {
      // The band used to be ₹1, which waved through up to 99 paise MORE than
      // the button said, charged with nobody asked. Both sides of this
      // comparison are exact to the paise — `decimal(15,2)` server-side, a
      // server figure plus a server rate client-side — so the only thing the
      // band has to absorb is binary dust.
      expect(
        TotalDivergence.between(
          shown: _shownTotal + 0.4,
          shownShipping: _shownShipping,
          order: _placed(),
        ).isMaterial,
        isTrue,
        reason: '40 paise is real money and must be shown to the customer',
      );
      expect(
        TotalDivergence.between(
          shown: _shownTotal + 0.001,
          shownShipping: _shownShipping,
          order: _placed(),
        ).isMaterial,
        isFalse,
        reason: 'a tenth of a paise cannot be billed and is not a re-price',
      );

      // ...and the flow acts on it: 40 paise now stops short of the sheet.
      final c = await _container(place: OrderPlaced(_placed()));
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal - 0.4,
            shownShipping: _shownShipping,
          );

      expect(c.read(checkoutFlowProvider).phase, CheckoutPhase.totalChanged);
      expectNothingCharged(c);
    });

    test('a 0.00 server shipping line is surfaced even when the totals agree',
        () async {
      // The Shiprocket-outage shape. `HookServiceProvider.php:63-75` swallows
      // the exception, so the order is written with no courier and no shipping
      // charge. Here the goods happen to make up the difference, so the
      // arithmetic alone would wave it through — and the parcel would still be
      // undispatchable.
      final c = await _container(
        place: OrderPlaced(_placed(total: '1274.15', shipping: '0.00')),
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      final state = c.read(checkoutFlowProvider);
      expect(state.phase, CheckoutPhase.totalChanged);
      expectNothingCharged(c);

      final d = state.divergence!;
      expect(d.difference, 0, reason: 'the totals agree to the paise');
      expect(d.isShippingMissing, isTrue);
      expect(d.isMaterial, isTrue);
      // Specific, and not a bargain: it names both shipping figures.
      expect(state.message, contains('₹0.00'));
      expect(state.message, contains('₹330.20'));
      expect(state.message, contains('cannot be dispatched'));
    });

    test('a genuinely free delivery is NOT read as a missing courier',
        () async {
      // A coupon that grants free shipping quotes 0.00 on this side too. There
      // is no fault to report, so nothing must interrupt the customer.
      final c = await _container(
        place: OrderPlaced(_placed(total: '943.95', shipping: '0.00')),
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: 943.95,
            shownShipping: 0,
          );

      expect(c.read(checkoutFlowProvider).phase, CheckoutPhase.paid);
    });

    test('CONTINUE pays the SERVER amount and places no second order',
        () async {
      final c = await _container(
        place: OrderPlaced(_placed(total: '1400.00', shipping: '456.05')),
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );
      await c.read(checkoutFlowProvider.notifier).acceptServerTotal();

      final gateway = c.read(paymentGatewayProvider) as _FakeGateway;
      // 1400.00, not the 1274.15 on the button and not a figure this app
      // recomputed — `razorpay.amount` is the server's own total in paise.
      expect(gateway.seen!.amountInPaise, 140000);
      expect(gateway.seen!.orderId, 'order_abc');
      // The existing Razorpay order was reopened. A second checkout POST would
      // be a second order, a second Razorpay order and another coupon use.
      expect((c.read(checkoutRepositoryProvider) as _FakeCheckout).placeCalls, 1);
      expect(c.read(checkoutFlowProvider).phase, CheckoutPhase.paid);
    });

    test('CANCEL charges nothing and keeps the order, the record and the cart',
        () async {
      final c = await _container(
        place: OrderPlaced(_placed(total: '1400.00', shipping: '456.05')),
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );
      c.read(checkoutFlowProvider.notifier).declineServerTotal();

      final state = c.read(checkoutFlowProvider);
      expectNothingCharged(c);
      // Unpaid, and payable later against the SAME razorpay order.
      expect(state.phase, CheckoutPhase.paymentIncomplete);
      expect(state.canRetryPayment, isTrue);
      expect(state.isPaid, isFalse);
      // Nothing was charged — and the order was still created. Both halves of
      // that sentence have to be true and said.
      expect(state.message, contains('Nothing has been charged'));
      expect(state.message, contains('Order 1287 was created'));
      // The record is the only handle on an order `GET /orders` cannot see.
      expect(c.read(pendingOrderStoreProvider).read()!.orderId, 1287);
      expect(
        c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-1',
      );
      expect((c.read(checkoutRepositoryProvider) as _FakeCheckout).placeCalls, 1);
      // ...and the way out of it points at the app's own cancel flow rather
      // than at support, which the app does not need for this.
      expect(state.message, contains('My orders'));
      expect(state.message, isNot(contains('contact support')));
    });

    test('CANCEL is not a one-way door: start over returns to Place order',
        () async {
      // Refusing the server's total used to park the flow in
      // `paymentIncomplete` forever. Every control from there pays the order
      // that already exists, this provider outlives the screen, and nothing the
      // customer could reach called `reset` — so they could never place another
      // order at all.
      final c = await _container(
        place: OrderPlaced(_placed(total: '1400.00', shipping: '456.05')),
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );
      c.read(checkoutFlowProvider.notifier).declineServerTotal();
      expect(c.read(checkoutFlowProvider).canStartOver, isTrue);

      c.read(checkoutFlowProvider.notifier).startOver();

      final state = c.read(checkoutFlowProvider);
      expect(state.phase, CheckoutPhase.idle);
      expect(state.hasOrder, isFalse);
      expect(state.orderMayExist, isFalse);
      // The basket is theirs and they are about to use it.
      expect(
        c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-1',
      );
      // And the record survives, because it is still the only handle on order
      // 1287 — the launch pass is what eventually reports it.
      expect(c.read(pendingOrderStoreProvider).read()!.orderId, 1287);
      expectNothingCharged(c);
    });

    test('start over refuses from every phase where money may have moved',
        () async {
      final c = await _container(
        place: OrderPlaced(_placed()),
        confirm: PaymentNotReceived(_placed()),
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      // `verifying`: the money may already be gone. Starting again here could
      // pay for the same basket twice.
      expect(c.read(checkoutFlowProvider).phase, CheckoutPhase.verifying);
      expect(c.read(checkoutFlowProvider).canStartOver, isFalse);
      c.read(checkoutFlowProvider.notifier).startOver();
      expect(c.read(checkoutFlowProvider).phase, CheckoutPhase.verifying);
    });

    test('an order with nothing to pay is settled, not parked', () async {
      // The zero-amount / plugin-off branch. There is no sheet to withhold, so
      // holding the flow open would strand a finished order behind a question
      // about a payment that will never happen.
      final c = await _container(
        place: OrderPlaced(_placed(razorpay: false, total: '1400.00')),
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      expect(c.read(checkoutFlowProvider).phase, CheckoutPhase.paid);
    });

    test('no key at all is refused before the wire, not substituted', () async {
      final c = await _container(
        place: const CheckoutShippingUnpriced(
          shippingOptionKey: null,
          error: ApiException('We could not confirm the delivery charge.'),
        ),
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: null,
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      final state = c.read(checkoutFlowProvider);
      expect(state.phase, CheckoutPhase.refused);
      expect(state.message, 'We could not confirm the delivery charge.');
      // Nothing was created, so the journal entry written before the call is a
      // lie worth deleting — and the basket stays.
      expect(c.read(pendingOrderStoreProvider).read(), isNull);
      expect(
        c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-1',
      );
    });
  });

  test('recovery finishes a crashed order from the stored triple', () async {
    SharedPreferences.setMockInitialValues({
      'server_cart_id_v1': 'cart-1',
      'pending_order_v1': PendingOrder(
        cartId: 'cart-1',
        stage: PendingOrderStage.sdkSuccess,
        createdAt: DateTime.now(),
        orderId: 1287,
        orderToken: 'tok',
        razorpayOrderId: 'order_abc',
        razorpayPaymentId: 'pay_1',
        razorpaySignature: 'sig',
      ).encode(),
    });
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        checkoutRepositoryProvider.overrideWithValue(
          _FakeCheckout(
            place: OrderPlaced(_placed()),
            confirm: PaymentConfirmed(_confirmed()),
          ),
        ),
        paymentGatewayProvider.overrideWithValue(
          _FakeGateway(const PaymentCancelled()),
        ),
        orderRepositoryProvider.overrideWithValue(_FakeOrders('completed')),
      ],
    );
    addTearDown(c.dispose);

    c.read(pendingOrderRecoveryProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final state = c.read(pendingOrderRecoveryProvider);
    expect(state.phase, PendingRecoveryPhase.paid);
    expect(state.orderId, 1287);
    expect(c.read(pendingOrderStoreProvider).read(), isNull);
  });

  // -------------------------------------------------------------------------
  // The launch pass and the cancel path must tell the same story
  // -------------------------------------------------------------------------

  group('recovery of an order the customer declined to pay for', () {
    /// The record `declineServerTotal` leaves behind: order created, no SDK
    /// triple, [age] old.
    Future<ProviderContainer> declined({Duration age = Duration.zero}) async {
      SharedPreferences.setMockInitialValues({
        'server_cart_id_v1': 'cart-1',
        'pending_order_v1': PendingOrder(
          cartId: 'cart-1',
          stage: PendingOrderStage.created,
          createdAt: DateTime.now().subtract(age),
          orderId: 1287,
          orderToken: 'tok',
          razorpayOrderId: 'order_abc',
          razorpayKeyId: 'rzp_test',
          amountPaise: 140000,
        ).encode(),
      });
      final prefs = await SharedPreferences.getInstance();
      return ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          checkoutRepositoryProvider.overrideWithValue(
            _FakeCheckout(
              place: OrderPlaced(_placed()),
              confirm: PaymentConfirmed(_confirmed()),
            ),
          ),
          paymentGatewayProvider.overrideWithValue(
            _FakeGateway(const PaymentCancelled()),
          ),
          // 404 on both order reads — which for an id this app was GIVEN by the
          // checkout response means "not finalised", never "does not exist".
          orderRepositoryProvider.overrideWithValue(_MissingOrders()),
        ],
      );
    }

    Future<PendingRecoveryState> run(ProviderContainer c) async {
      c.read(pendingOrderRecoveryProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      return c.read(pendingOrderRecoveryProvider);
    }

    test('says the order exists and is unpaid, never "it was not placed"',
        () async {
      final c = await declined();
      addTearDown(c.dispose);

      final state = await run(c);

      expect(state.phase, PendingRecoveryPhase.unpaid);
      // The exact contradiction this fixes: checkout had just told this
      // customer "Order 1287 was created and is unpaid".
      expect(state.message, isNot(contains('was not placed')));
      expect(state.message, contains('1287'));
      expect(state.message, contains('has not been paid for'));
      expect(state.message, contains('will not be dispatched'));
      // The record is the ONLY handle on an order `GET /orders` filters out.
      expect(c.read(pendingOrderStoreProvider).read()!.orderId, 1287);
      // The basket is untouched either way.
      expect(
        c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-1',
      );
    });

    test('lets the record go once it is stale, and says so on the way out',
        () async {
      final c = await declined(
        age: PendingOrderRecoveryNotifier.staleAfter + const Duration(hours: 1),
      );
      addTearDown(c.dispose);

      final state = await run(c);

      expect(state.phase, PendingRecoveryPhase.dropped);
      expect(state.message, contains('1287'));
      expect(state.message, isNot(contains('was not placed')));
      expect(c.read(pendingOrderStoreProvider).read(), isNull);
      expect(
        c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-1',
      );
    });

    // -----------------------------------------------------------------------
    // The POST that was never answered — the duplicate-order case
    // -----------------------------------------------------------------------

    /// A record written just before `POST /checkout/cart/{id}` went out, whose
    /// response never came back. It has NO order id, and no endpoint this app
    /// can call will find the order if one was created: both order reads filter
    /// `is_finished = 1`. Meanwhile the checkout endpoint runs no transaction,
    /// so the order and its rows commit before the response is lost — an order
    /// existing is the likely case, not the unlikely one.
    Future<ProviderContainer> interrupted({Duration age = Duration.zero}) async {
      SharedPreferences.setMockInitialValues({
        'server_cart_id_v1': 'cart-1',
        'pending_order_v1': PendingOrder(
          cartId: 'cart-1',
          stage: PendingOrderStage.created,
          createdAt: DateTime.now().subtract(age),
        ).encode(),
      });
      final prefs = await SharedPreferences.getInstance();
      return ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          checkoutRepositoryProvider.overrideWithValue(
            _FakeCheckout(
              place: OrderPlaced(_placed()),
              confirm: PaymentConfirmed(_confirmed()),
            ),
          ),
          paymentGatewayProvider.overrideWithValue(
            _FakeGateway(const PaymentCancelled()),
          ),
          orderRepositoryProvider.overrideWithValue(_MissingOrders()),
        ],
      );
    }

    test('keeps an unidentified record — it is the only duplicate-order guard',
        () async {
      final c = await interrupted();
      addTearDown(c.dispose);

      final state = await run(c);

      // The record used to be CLEARED here, which threw away the app's only
      // trace of an order that very likely exists, in exactly the situation
      // where placing a duplicate is most likely.
      expect(c.read(pendingOrderStoreProvider).read(), isNotNull);
      expect(c.read(pendingOrderStoreProvider).read()!.isIdentified, isFalse);

      expect(state.phase, PendingRecoveryPhase.needsSupport);
      // It may not claim an order exists, and it may not claim one does not.
      expect(state.message, contains('do not know whether an order was created'));
      // Payment genuinely never started, so this much IS provable.
      expect(state.message, contains('Nothing was charged'));
      // And it must not send them somewhere that cannot answer the question:
      // My orders filters `is_finished = 1`, so it can only ever show nothing.
      expect(state.message, isNot(contains('check your orders')));

      expect(
        c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-1',
      );
    });

    test('lets an unidentified record go once it is stale', () async {
      final c = await interrupted(
        age: PendingOrderRecoveryNotifier.staleAfter + const Duration(hours: 1),
      );
      addTearDown(c.dispose);

      final state = await run(c);

      expect(state.phase, PendingRecoveryPhase.dropped);
      expect(c.read(pendingOrderStoreProvider).read(), isNull);
      // Announced on the way out, never dropped in silence.
      expect(state.message, isNotNull);
      expect(
        c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-1',
      );
    });

    test('an unanswered POST leaves a way out that does not certify absence',
        () async {
      final c = await interrupted();
      addTearDown(c.dispose);

      // The flow rehydrates straight into `unresolved`, which keeps Place order
      // off the screen.
      final flow = c.read(checkoutFlowProvider);
      expect(flow.phase, CheckoutPhase.unresolved);

      // Without this the customer is locked out of checkout until the journal
      // ages out. The screen's affordance used to be "I checked — it isn't
      // there", wired to reset() — asking them to certify something no screen
      // in this app can show them. `startOver` replaces it and says plainly
      // that a second order may result.
      expect(flow.canStartOver, isTrue);

      c.read(checkoutFlowProvider.notifier).startOver();
      expect(c.read(checkoutFlowProvider).phase, isNot(CheckoutPhase.unresolved));
      // The basket survives it.
      expect(
        c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-1',
      );
    });
  });

  // =========================================================================
  // R1 — the flow is rebuilt from the journal, not assumed blank
  // =========================================================================

  group('after a restart', () {
    /// A brand-new process reading a journal a previous one left behind.
    Future<ProviderContainer> restart(String journal) => _container(
          place: OrderPlaced(_placed()),
          journal: journal,
        );

    test('an unpaid order comes back payable, at the SERVER total', () async {
      // Order 288's shape: created, sheet dismissed, app force-quit. The
      // notifier used to come up empty, so the screen went back to a LIVE cart
      // bill and a LIVE Place order button — the unpaid order was unpayable
      // from the app, and the next tap made a second real one.
      final c = await restart(_journal());
      addTearDown(c.dispose);

      final state = c.read(checkoutFlowProvider);
      expect(state.phase, CheckoutPhase.paymentIncomplete);
      expect(state.hasOrder, isTrue);
      expect(state.orderId, 1287);
      // The order's own figure, not the basket's — the basket is no longer
      // what is being paid for.
      expect(state.serverTotal, '₹1,274.15');
      expect(state.canRetryPayment, isTrue);
      expect(state.message, contains('Order 1287'));
      // This claim IS provable here: the journal never left `created`, and
      // `created` is written before the sheet.
      expect(state.message, contains('Nothing has been charged'));

      // ...and it really is payable: the SAME razorpay order, at the server's
      // own amount, with no second checkout POST.
      await c.read(checkoutFlowProvider.notifier).retryPayment();
      final gateway = c.read(paymentGatewayProvider) as _FakeGateway;
      expect(gateway.seen!.orderId, 'order_abc');
      expect(gateway.seen!.amountInPaise, 127415);
      expect((c.read(checkoutRepositoryProvider) as _FakeCheckout).placeCalls, 0);
    });

    test('a rehydrated order cannot be replaced by a second one', () async {
      // The screen keeps Place order off in this state; this is the guard that
      // does not depend on the screen getting it right.
      final c = await restart(_journal());
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      expect((c.read(checkoutRepositoryProvider) as _FakeCheckout).placeCalls, 0);
      expect(c.read(checkoutFlowProvider).orderId, 1287);
      // The record still names the FIRST order, not a replacement.
      expect(c.read(pendingOrderStoreProvider).read()!.orderId, 1287);
    });

    test('a record with no order id keeps Place order off the screen',
        () async {
      // The POST was never answered. An order may exist and nothing can look it
      // up, so the one thing that must not happen is another checkout.
      final c = await restart(_journal(orderId: null, razorpay: false));
      addTearDown(c.dispose);

      final state = c.read(checkoutFlowProvider);
      expect(state.phase, CheckoutPhase.unresolved);
      expect(state.orderMayExist, isTrue);
      expect(state.needsReconciliation, isTrue);
      expect(state.message, contains('may have been placed'));
    });

    // TEMPORARY behaviour — see docs/TODO_CANCELLED_PAYMENT_FLOW.md. This
    // record (sheet open, no triple) used to rehydrate into a permanent
    // `verifying` park; the interim decision abandons it like a cancelled
    // sheet, so the customer lands on a clean checkout instead of a stuck
    // "we're checking" panel. The with-triple case below is unchanged — that
    // one can actually be finished.
    test('the sheet having been open with no triple is abandoned on restart',
        () async {
      final c = await restart(_journal(stage: PendingOrderStage.paymentOpened));
      addTearDown(c.dispose);

      final state = c.read(checkoutFlowProvider);
      expect(state.phase, CheckoutPhase.idle);
      expect(state.orderMayExist, isFalse);
      // The record is settled, not deleted: rehydration and the launch pass
      // both ignore it, and the next checkout overwrites it.
      expect(
        c.read(pendingOrderStoreProvider).read()!.stage,
        PendingOrderStage.settled,
      );
    });

    test('a stored triple is verifying, not payable', () async {
      final c = await restart(
        _journal(stage: PendingOrderStage.sdkSuccess, triple: true),
      );
      addTearDown(c.dispose);

      final state = c.read(checkoutFlowProvider);
      expect(state.phase, CheckoutPhase.verifying);
      expect(state.canRetryPayment, isFalse);
      expectNoUnchargedClaim(state.message);
    });

    test('a v1 `created` record is not trusted to prove the sheet never opened',
        () async {
      // Before `paymentOpened` existed, `created` covered the sheet too. A
      // record written by that build cannot tell the two apart, so it gets the
      // answer that is true either way rather than the comfortable one.
      final c = await restart(_journal(version: 1));
      addTearDown(c.dispose);

      final state = c.read(checkoutFlowProvider);
      expect(state.phase, CheckoutPhase.verifying);
      expect(state.canRetryPayment, isFalse);
      expectNoUnchargedClaim(state.message);
    });

    test('a settled record, and no record at all, leave the flow blank',
        () async {
      final settled = await restart(_journal(stage: PendingOrderStage.settled));
      addTearDown(settled.dispose);
      expect(settled.read(checkoutFlowProvider).phase, CheckoutPhase.idle);
      expect(settled.read(checkoutFlowProvider).hasOrder, isFalse);

      final blank = await _container(place: OrderPlaced(_placed()));
      addTearDown(blank.dispose);
      expect(blank.read(checkoutFlowProvider).phase, CheckoutPhase.idle);
    });
  });

  // =========================================================================
  // R2 — the journal names the sheet BEFORE it opens
  // =========================================================================

  group('the payment sheet is journalled before it opens', () {
    test('the stage is on disk at the moment the SDK is called', () async {
      PendingOrderStage? atSheet;
      final c = await _container(
        place: OrderPlaced(_placed()),
        onPay: (container) {
          atSheet = container.read(pendingOrderStoreProvider).read()?.stage;
        },
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      // Not `created`. That is the whole fix: a process killed here is now
      // distinguishable from one killed with the checkout POST in flight.
      expect(atSheet, PendingOrderStage.paymentOpened);
    });

    // TEMPORARY behaviour — see docs/TODO_CANCELLED_PAYMENT_FLOW.md. The
    // dismissed sheet used to walk the stage back to `created` (order kept,
    // retry offered); it now settles the record outright, because the interim
    // decision abandons the order and returns to the cart. What this test
    // still guards is the evidence rule: only `PaymentCancelled` — the SDK's
    // own report that no payment happened — may settle a record this way. A
    // kill after this point must read as "nothing pending", never "we do not
    // know".
    test('a dismissed sheet settles the journal record', () async {
      final c = await _container(
        place: OrderPlaced(_placed()),
        gateway: const PaymentCancelled(),
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      final record = c.read(pendingOrderStoreProvider).read()!;
      expect(record.stage, PendingOrderStage.settled);
      expect(c.read(checkoutFlowProvider).canRetryPayment, isFalse);
    });

    test('a named provider failure walks it back; an unknown one does not',
        () async {
      final declined = await _container(
        place: OrderPlaced(_placed()),
        gateway: const PaymentFailed(code: 2, message: 'Insufficient funds'),
      );
      addTearDown(declined.dispose);
      await declined.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );
      expect(
        declined.read(pendingOrderStoreProvider).read()!.stage,
        PendingOrderStage.created,
      );

      // "The SDK never answered" says nothing about the money, so the stage
      // stands and every later reader keeps saying so.
      final silent = await _container(
        place: OrderPlaced(_placed()),
        gateway: const PaymentFailed(
          code: PaymentFailureCodes.noResponse,
          message: 'no response',
        ),
      );
      addTearDown(silent.dispose);
      await silent.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );
      final record = silent.read(pendingOrderStoreProvider).read()!;
      expect(record.stage, PendingOrderStage.paymentOpened);
      expect(record.paymentMayHaveHappened, isTrue);
      expect(silent.read(checkoutFlowProvider).phase, CheckoutPhase.verifying);
    });
  });

  group('killed between the sheet opening and the callback', () {
    /// The launch pass over a record left at [PendingOrderStage.paymentOpened],
    /// with both order reads 404ing — which is what `is_finished = 1` does to an
    /// order whose confirm-payment never went out.
    Future<PendingRecoveryState> launch(ProviderContainer c) async {
      c.read(pendingOrderRecoveryProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      return c.read(pendingOrderRecoveryProvider);
    }

    // TEMPORARY behaviour — see docs/TODO_CANCELLED_PAYMENT_FLOW.md. This
    // used to announce "needsSupport" on every launch; the interim decision
    // settles the record silently. Deliberately AFTER the lookup, so the paid
    // case (the test further down) still finalises.
    test('a sheet that was open with no triple is settled silently', () async {
      final c = await _container(
        place: OrderPlaced(_placed()),
        journal: _journal(stage: PendingOrderStage.paymentOpened),
        ordersMissing: true,
      );
      addTearDown(c.dispose);

      final state = await launch(c);

      expect(state.phase, PendingRecoveryPhase.idle);
      expect(state.message, isNull);
      expect(
        c.read(pendingOrderStoreProvider).read()!.stage,
        PendingOrderStage.settled,
      );
      // The basket survives — it is what the next checkout re-orders.
      expect(
        c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-1',
      );
    });

    // TEMPORARY behaviour — the age makes no difference to the interim
    // abandonment: settled silently either way, never announced as "dropped".
    test('age makes no difference to the interim abandonment', () async {
      final c = await _container(
        place: OrderPlaced(_placed()),
        journal: _journal(
          stage: PendingOrderStage.paymentOpened,
          age: PendingOrderRecoveryNotifier.staleAfter +
              const Duration(days: 30),
        ),
        ordersMissing: true,
      );
      addTearDown(c.dispose);

      final state = await launch(c);

      expect(state.phase, PendingRecoveryPhase.idle);
      expect(
        c.read(pendingOrderStoreProvider).read()!.stage,
        PendingOrderStage.settled,
      );
    });

    test('an unreadable order does not expire the record either', () async {
      // `unreachable` for a record whose payment may have been taken: dropping
      // it is what turns "we could not check" into "it is gone".
      final c = await _container(
        place: OrderPlaced(_placed()),
        journal: _journal(
          stage: PendingOrderStage.paymentOpened,
          age: PendingOrderRecoveryNotifier.staleAfter +
              const Duration(days: 30),
        ),
        lookup: 'completed',
      );
      addTearDown(c.dispose);
      // `_FakeOrders` answers, so this exercises the *paid* path instead; the
      // record is cleared because the order is proved paid, which is the one
      // disposal that is always correct.
      final state = await launch(c);
      expect(state.phase, PendingRecoveryPhase.paid);
      expect(c.read(pendingOrderStoreProvider).read(), isNull);
    });

    test('a v1 created record is still checked, never written off', () async {
      // The build before `paymentOpened` cannot say the sheet did not open, so
      // the launch pass must not say it either.
      final c = await _container(
        place: OrderPlaced(_placed()),
        journal: _journal(version: 1),
        ordersMissing: true,
      );
      addTearDown(c.dispose);

      final state = await launch(c);

      expect(state.phase, PendingRecoveryPhase.needsSupport);
      expectNoUnchargedClaim(state.message);
      expect(c.read(pendingOrderStoreProvider).read(), isNotNull);
    });
  });

  // =========================================================================
  // R3 — a failure after the order exists is never "it was not placed"
  // =========================================================================

  group('a failure once the order exists', () {
    test('a journal write that fails after OrderPlaced never reads as a failed '
        'checkout', () async {
      final c = await _container(
        place: OrderPlaced(_placed()),
        // The record before the POST lands; the one carrying the order id does
        // not.
        failJournalAfterWrites: 1,
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      final state = c.read(checkoutFlowProvider);
      // NOT `refused`, which is the state that means "nothing exists, fix it
      // and try again" — the order exists and may need paying for.
      expect(state.phase, CheckoutPhase.verifying);
      expect(state.hasOrder, isTrue);
      expect(state.orderId, 1287);
      expect(state.needsReconciliation, isTrue);
      expect(state.message, contains('Order 1287'));
      expect(state.message, contains('was placed'));
      expect(state.message, isNot(contains('not placed')));
      // The basket stays: it is theirs, and the order may yet be abandoned.
      expect(
        c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-1',
      );
      expect((c.read(checkoutRepositoryProvider) as _FakeCheckout).placeCalls, 1);
    });

    test('a journal write that fails BEFORE the POST sends nothing at all',
        () async {
      // The safe direction. Posting without the journal behind it means a crash
      // during the POST loses the order outright, and no read endpoint can find
      // an unfinished one.
      final c = await _container(
        place: OrderPlaced(_placed()),
        failJournalAfterWrites: 0,
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      final state = c.read(checkoutFlowProvider);
      expect(state.phase, CheckoutPhase.refused);
      expect(state.hasOrder, isFalse);
      expect(state.message, contains('nothing has been sent'));
      expect((c.read(checkoutRepositoryProvider) as _FakeCheckout).placeCalls, 0);
      expect(
        (c.read(paymentGatewayProvider) as _FakeGateway).seen,
        isNull,
      );
    });

    test('anything thrown after the payment succeeds degrades to verifying',
        () async {
      // The triple is already on disk here, so money has almost certainly
      // moved. Whatever blew up, the customer must not be told the order failed.
      final c = await _container(
        place: OrderPlaced(_placed()),
        confirmThrows: true,
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      final state = c.read(checkoutFlowProvider);
      expect(state.phase, CheckoutPhase.verifying);
      expect(state.isPaid, isFalse);
      expect(state.message, isNot(contains('not placed')));
      // The record survives, with the triple on it, so the launch pass can
      // finish the order unattended.
      final record = c.read(pendingOrderStoreProvider).read()!;
      expect(record.razorpayPaymentId, 'pay_1');
      expect(record.hasPaymentProof, isTrue);
      expect(
        c.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-1',
      );
    });
  });

  // =========================================================================
  // R4 — the sheet opens at the total that was approved, or not at all
  // =========================================================================

  group('the sheet amount is the order total', () {
    test('a razorpay amount that is not the total keeps the sheet shut',
        () async {
      // The divergence sheet's Continue button names `total_amount`; the SDK is
      // opened at `razorpay.amount`. They are the same figure in two units
      // server-side, and nothing checked it. Here they are ₹274.15 apart.
      final c = await _container(
        place: OrderPlaced(_placed(razorpayPaise: 100000)),
      );
      addTearDown(c.dispose);

      await c.read(checkoutFlowProvider.notifier).placeOrder(
            cartId: 'cart-1',
            address: _address,
            shippingOptionKey: 'shiprocket_1016322646',
            shownTotal: _shownTotal,
            shownShipping: _shownShipping,
          );

      final state = c.read(checkoutFlowProvider);
      expect((c.read(paymentGatewayProvider) as _FakeGateway).seen, isNull);
      expect(state.phase, CheckoutPhase.verifying);
      expect(state.message, contains('could not confirm the amount'));
      expect(state.message, contains('order 1287'));
      // Provable here — the sheet never opened, and the journal says so.
      expect(state.message, contains('Nothing has been charged'));
      expect(c.read(pendingOrderStoreProvider).read()!.orderId, 1287);
    });

    test('the check is an assertion, not a guess', () {
      final base = PendingOrder(
        cartId: 'cart-1',
        stage: PendingOrderStage.created,
        createdAt: DateTime.now(),
        orderId: 1287,
      );
      expect(
        base.copyWith(totalAmountValue: 1274.15, amountPaise: 127415)
            .sheetAmountMatchesTotal,
        isTrue,
      );
      expect(
        base.copyWith(totalAmountValue: 1274.15, amountPaise: 127414)
            .sheetAmountMatchesTotal,
        isFalse,
        reason: 'one paise apart is still two different numbers',
      );
      // A record from before the numeric total was stored cannot be checked,
      // and "cannot check" is not "disagrees" — refusing would strand a payable
      // order over a field that was never written.
      expect(
        base.copyWith(amountPaise: 127415).sheetAmountMatchesTotal,
        isTrue,
      );
    });
  });

  // =========================================================================
  // The journal record itself
  // =========================================================================

  group('the journal record', () {
    test('round-trips the version and the numeric total', () {
      final record = PendingOrder(
        cartId: 'cart-1',
        stage: PendingOrderStage.paymentOpened,
        createdAt: DateTime.parse('2026-08-04T10:00:00.000Z'),
        orderId: 1287,
        totalAmount: '₹1,274.15',
        totalAmountValue: 1274.15,
        amountPaise: 127415,
      );
      final back = PendingOrder.tryDecode(record.encode())!;

      expect(back.stage, PendingOrderStage.paymentOpened);
      expect(back.version, PendingOrder.currentVersion);
      expect(back.totalAmountValue, 1274.15);
      expect(back.sheetNeverOpened, isFalse);
      expect(back.paymentMayHaveHappened, isTrue);
    });

    test('a blob with no version marker decodes as v1', () {
      final back = PendingOrder.tryDecode(_journal(version: 1))!;
      expect(back.version, 1);
      expect(back.stage, PendingOrderStage.created);
      // The point of the marker: v1's `created` proves nothing about the sheet.
      expect(back.sheetNeverOpened, isFalse);
      expect(back.paymentMayHaveHappened, isTrue);
    });

    test('this build\'s `created` DOES prove the sheet never opened', () {
      final back = PendingOrder.tryDecode(_journal())!;
      expect(back.version, PendingOrder.currentVersion);
      expect(back.sheetNeverOpened, isTrue);
      expect(back.paymentMayHaveHappened, isFalse);
    });

    test('a stage this build cannot read asserts nothing about the money', () {
      // Forward compatibility, and the direction it has to fail in. A stage
      // name from a newer build — or a truncated write — must not fall back to
      // `created`, because `created` is the one value that *licenses* the
      // sentence "nothing has been charged", and manufacturing it out of a
      // field this build could not read is the whole defect in miniature.
      final back = PendingOrder.tryDecode(
        jsonEncode({
          'cart_id': 'cart-1',
          'stage': 'somethingNewerBuildsDo',
          'v': PendingOrder.currentVersion + 1,
          'created_at': DateTime.now().toIso8601String(),
          'order_id': 1287,
        }),
      )!;
      expect(back.sheetNeverOpened, isFalse);
      expect(back.paymentMayHaveHappened, isTrue);
    });
  });
}

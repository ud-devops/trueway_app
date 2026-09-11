import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/presentation/widgets/bill_details.dart';
import 'package:trueway_farms/presentation/widgets/quantity_stepper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/payments/payment_gateway.dart';
import 'package:trueway_farms/data/models/address.dart';
import 'package:trueway_farms/data/models/placed_order.dart';
import 'package:trueway_farms/data/models/shipping_quote.dart';
import 'package:trueway_farms/data/models/tax_information.dart';
import 'package:trueway_farms/data/repositories/address_repository.dart';
import 'package:trueway_farms/data/repositories/checkout_repository.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/checkout_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/server_cart_provider.dart';
import 'package:trueway_farms/presentation/providers/shipping_provider.dart';
import 'package:trueway_farms/presentation/screens/checkout/checkout_screen.dart';
import 'package:trueway_farms/presentation/widgets/shipping_selector.dart';
import 'package:trueway_farms/presentation/widgets/state_views.dart';

import '../support/fake_cart_repository.dart';

/// Checkout: address in, live courier rates out, and a bill that quotes the
/// courier rather than the ₹0 the screen used to print.
///
/// Nothing here touches the network. The three seams are all overridden:
/// [shippingRatesFetcherProvider] (the only route to `LogisticsRepository`),
/// [cartRepositoryProvider] (which supplies the basket, its weights and its
/// totals) and [addressRepositoryProvider], so no `ApiClient` — and therefore
/// no socket — is ever constructed.
///
/// The cart seam used to be [catalogRepositoryProvider]: the local cart carried
/// no weight, so the parcel fetched one product detail per line to find out how
/// heavy the basket was. The server sends `total_weight`, `package_dimensions`
/// and `order_total` with the cart itself, so the whole catalogue round trip —
/// and the hand-ported `PackageDimensionCalculator` it fed — is gone.

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// Rows shaped like a captured `POST /logistics/check-serviceability` body:
/// `estimated_delivery_days` arrives as the String "3" and `cod` as the int 1.
///
/// [rateId] is the row's own `id` — a *different* number from
/// `courier_company_id`, and the one the `shipping_option` key is built from.
/// Pass null for a row that carried none, which is what makes a courier
/// unbookable.
CourierOption _courier({
  required int id,
  required String name,
  required num rate,
  required String days,
  String etd = '',
  int? rateId = 1016322646,
}) =>
    CourierOption.fromJson({
      'courier_company_id': id,
      if (rateId != null) 'id': rateId,
      'courier_name': name,
      'rate': rate,
      'freight_charge': rate,
      'cod_charges': 0,
      'cod': 1,
      'estimated_delivery_days': days,
      'etd': etd,
      'city': 'AHMEDABAD',
      'delivery_performance': 4.5,
    });

/// `findBestCourier` sorts by days then rate, so this is the row the web would
/// pick — and it is deliberately *not* the cheapest.
final _fastest = _courier(
  id: 196,
  name: 'DTDC Air 500gm',
  rate: 319.79,
  days: '3',
  etd: 'Aug 04, 2026',
  rateId: 1016322646,
);

final _cheapest = _courier(
  id: 55,
  name: 'DTDC Surface 2kg',
  rate: 190.11,
  days: '5',
  rateId: 1051772883,
);

/// Two lines of a real cart: a 5 kg wheat pack and a 1 kg jaggery pack.
///
/// `weightGrams` is per unit and comes from the server with the line, so a
/// fixture with 0 stands for a product the catalogue records no shipping weight
/// for — the case that makes a quote a floor rather than a final figure.
const _wheat = FakeCartLine(
  id: 118,
  name: 'Organic Sona Moti Wheat',
  quantity: 2,
  unitPrice: 1250,
  weightGrams: 5000,
  lengthCm: 20,
  wideCm: 15,
  heightCm: 8,
);

const _jaggery = FakeCartLine(
  id: 121,
  name: 'Organic Khand',
  quantity: 1,
  unitPrice: 300,
  weightGrams: 1000,
  lengthCm: 20,
  wideCm: 15,
  heightCm: 8,
);

/// Goods value: 1250*2 + 300 = 2800, plus the server's 5% on top.
///
/// `declared_value` is `order_total` — tax included — not the pre-tax subtotal.
/// The app used to send the subtotal because it treated catalogue prices as
/// GST-inclusive, which the backend does not.
const double _subtotal = 2800;
const double _orderTotal = _subtotal * 1.05;

/// The box the server's calculator picked for these two lines. Supplied rather
/// than derived: sourcing it from the server is the whole point, so a test that
/// recomputed it would be asserting against a rule the app no longer owns.
const _box = {
  'length': 21.0,
  'breadth': 16.0,
  'height': 17.0,
  'weight': 11.0,
};

final _address = Address.fromJson({
  'id': 16,
  'name': 'Suraj ojha',
  'is_default': 1,
  'phone': '8305317276',
  'email': 'suraj.ojha@uminber.in',
  'country': 'India',
  'state': 'Gujarat',
  'city': 'Ahmedabad',
  'address': '306, Jahnavi Arcade',
  'zip_code': '382415',
  'full_address': '306, Jahnavi Arcade, Ahmedabad, Gujarat, 382415',
});

/// A saved row with a perfectly good PIN code and **no state**.
///
/// Not a contrived fixture: `POST /ecommerce/addresses` marks `state` nullable,
/// so rows like this exist in real address books — and `CheckoutAddressRules`
/// requires it, because it drives shipping-rule matching server-side.
final _statelessAddress = Address.fromJson({
  'id': 17,
  'name': 'Suraj ojha',
  'phone': '8305317276',
  'email': 'suraj.ojha@uminber.in',
  'country': 'India',
  'state': '',
  'city': 'Ahmedabad',
  'address': '306, Jahnavi Arcade',
  'zip_code': '382415',
  'full_address': '306, Jahnavi Arcade, Ahmedabad, 382415',
});

/// The other real shape: `zip_code` is `nullable|max:20`, so PIN-less rows exist
/// too. This is the case the blocker used to name for *every* failure.
final _pinlessAddress = Address.fromJson({
  'id': 18,
  'name': 'Suraj ojha',
  'phone': '8305317276',
  'email': 'suraj.ojha@uminber.in',
  'country': 'India',
  'state': 'Gujarat',
  'city': 'Ahmedabad',
  'address': '306, Jahnavi Arcade',
  'zip_code': '',
  'full_address': '306, Jahnavi Arcade, Ahmedabad, Gujarat',
});

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeAddressRepository implements AddressRepository {
  _FakeAddressRepository({List<Address> rows = const []})
      : rows = List.of(rows);

  final List<Address> rows;

  @override
  Future<List<Address>> all() async => List.of(rows);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// The checkout POST, faked. Records what it was handed and answers with a
/// canned outcome — nothing here reaches a socket, and nothing creates an order.
class _FakeCheckout implements CheckoutRepository {
  _FakeCheckout({this.place});

  /// Null means "the default order", built lazily so a test can move the
  /// server's total without rebuilding the harness.
  final PlaceOrderOutcome? place;

  int placeCalls = 0;
  String? lastOptionKey;

  /// Null here means the screen asked for "same as delivery", which the
  /// repository turns into `billing_address_same_as_shipping_address: "1"`.
  CheckoutAddress? lastBillingAddress;

  Map<String, dynamic>? lastTaxInformation;

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
    lastOptionKey = shippingOptionKey;
    lastBillingAddress = billingAddress;
    lastTaxInformation = taxInformation;
    return place ?? OrderPlaced(_serverOrder());
  }

  @override
  Future<ConfirmPaymentOutcome> confirmPayment({
    required int orderId,
    required String razorpayPaymentId,
    required String razorpayOrderId,
    required String razorpaySignature,
  }) async =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

/// The order the server says it created. [total] and [shipping] are ITS
/// figures, which is the whole point: the app's job is to notice when they are
/// not the figures it printed on the button.
PlacedOrder _serverOrder({
  String total = '2,944.79',
  String shipping = '319.79',
}) {
  final clean = total.replaceAll(',', '');
  return PlacedOrder.tryFrom({
    'data': {
      'order_id': 1287,
      'order_token': 'tok',
      'order_status': 'pending',
      'order_status_label': 'Pending',
      'payment_status': 'pending',
      'payment_method': 'razorpay',
      'subtotal': '2500.00',
      'tax_amount': '125.00',
      'shipping_amount': shipping,
      'discount_amount': '0.00',
      'payment_fee': '0.00',
      'total_amount': clean,
      'cart_id': 'cart-test',
      'is_finished': false,
      'razorpay': {
        'razorpay_order_id': 'order_abc',
        'razorpay_key_id': 'rzp_test',
        'amount': (double.parse(clean) * 100).round(),
        'currency': 'INR',
      },
    },
  })!;
}

/// The Razorpay SDK. **Whether this was called at all is the assertion** in the
/// divergence tests: the sheet must not open until the customer has agreed to
/// the server's figure.
class _FakeGateway implements PaymentGateway {
  PaymentRequest? seen;

  @override
  Future<PaymentResult> pay(PaymentRequest request) async {
    seen = request;
    // Always cancelled, deliberately. A success would run on to `_settle` and
    // `context.pushReplacement('/order-success/…')`, which needs a GoRouter
    // this harness has no reason to build — and every assertion here is about
    // what the sheet was opened *with*, or whether it was opened at all.
    return const PaymentCancelled();
  }

  @override
  void dispose() {}
}

/// Stands in for the whole logistics repository.
class _Rates {
  _Rates({this.result, this.error, this.delay});

  final ShippingRates? result;
  final Object? error;
  final Duration? delay;

  final List<ShippingQuery> calls = [];

  Future<ShippingRates> call(ShippingQuery query) async {
    calls.add(query);
    if (delay != null) await Future<void>.delayed(delay!);
    if (error != null) throw error!;
    return result ?? ShippingRates.fromCouriers([_fastest, _cheapest]);
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// [unweighed] drops the recorded weight from those line ids, standing for
/// products the catalogue has no shipping weight for. When *every* line is
/// unweighed the server sends no `package_dimensions` either, which is how the
/// quote falls back to the default box and the 0.5 kg floor together.
Future<Widget> _screen({
  required _Rates rates,
  List<FakeCartLine> cart = const [],
  Set<int> unweighed = const {},
  bool signedIn = false,
  List<Address> book = const [],
  _FakeCheckout? checkout,
  _FakeGateway? gateway,
  // True mounts the screen PUSHED from a stub cart page, the way the real
  // cart reaches it — for the tests about popping back there.
  bool pushedFromCart = false,
}) async {
  // Only the cart id is persisted; the contents come from the repository.
  SharedPreferences.setMockInitialValues({
    if (cart.isNotEmpty) 'server_cart_id_v1': 'cart-test',
  });
  final prefs = await SharedPreferences.getInstance();

  final lines = [
    for (final line in cart)
      unweighed.contains(line.id)
          ? FakeCartLine(
              id: line.id,
              name: line.name,
              quantity: line.quantity,
              unitPrice: line.unitPrice,
            )
          : line,
  ];
  final anyWeighed = lines.any((l) => l.weightGrams > 0);

  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      cartRepositoryProvider.overrideWithValue(
        FakeCartRepository(
          lines: lines,
          packageDimensions: anyWeighed ? _box : null,
        ),
      ),
      addressRepositoryProvider.overrideWithValue(
        _FakeAddressRepository(rows: book),
      ),
      isAuthenticatedProvider.overrideWithValue(signedIn),
      shippingRatesFetcherProvider.overrideWithValue(rates.call),
      // Always overridden, even for the tests that never tap the button: a
      // real `CheckoutRepository` would construct an `ApiClient`, and the
      // point of this harness is that no socket exists.
      checkoutRepositoryProvider.overrideWithValue(
        checkout ?? _FakeCheckout(),
      ),
      paymentGatewayProvider.overrideWithValue(gateway ?? _FakeGateway()),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: pushedFromCart ? const _CartStub() : const CheckoutScreen(),
    ),
  );
}

/// Stands in for the cart screen: one button that pushes checkout, exactly the
/// way `cart_screen.dart` does (`context.push('/checkout')` — a pushed route
/// with the cart underneath). Being back on this widget IS the assertion that
/// checkout popped.
class _CartStub extends StatelessWidget {
  const _CartStub();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            key: const Key('stub-open-checkout'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const CheckoutScreen()),
            ),
            child: const Text('open checkout'),
          ),
        ),
      );
}

void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Fills the picker's manual form. [pin] drives the shipping quote.
///
/// Pass `settle: false` to stop before the in-flight rate request resolves —
/// the PIN is entered last, so that is exactly the "checking couriers" moment.
Future<void> _enterAddress(
  WidgetTester tester, {
  String pin = '382415',
  bool settle = true,
}) async {
  await tester.enterText(
    find.byKey(const Key('manual-address-name')),
    'Suraj ojha',
  );
  await tester.enterText(
    find.byKey(const Key('manual-address-phone')),
    '9876543210',
  );
  await tester.enterText(
    find.byKey(const Key('manual-address-street')),
    '306, Jahnavi Arcade',
  );
  await tester.enterText(
    find.byKey(const Key('manual-address-city')),
    'Ahmedabad',
  );
  await tester.enterText(
    find.byKey(const Key('manual-address-state')),
    'Gujarat',
  );
  await tester.enterText(find.byKey(const Key('manual-address-zip')), pin);
  if (!settle) {
    // One frame for the picker's post-frame callback, one for checkout's
    // rebuild that starts the request.
    await tester.pump();
    await tester.pump();
    return;
  }
  await tester.pumpAndSettle();
}

ElevatedButton _placeOrderButton(WidgetTester tester) =>
    tester.widget<ElevatedButton>(
      find.byKey(const Key('checkout-place-order')),
    );

String? _blockerText(WidgetTester tester) {
  final finder = find.byKey(const Key('checkout-blocker'));
  if (finder.evaluate().isEmpty) return null;
  return tester.widget<Text>(finder).data;
}

/// The scope the screen itself is reading, so a test can write to
/// [shippingChoiceProvider] exactly the way the cart does.
ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(CheckoutScreen)));

/// The query the cart pins its choice against.
///
/// Built the way the cart builds it — `checkoutParcelProvider` plus the delivery
/// pincode, exactly what `cartDeliveryChargeProvider` does — rather than written
/// out by hand, because the equality is the whole point. `ShippingChoice` only
/// applies to a query it compares *equal* to, so a cart choice reaching checkout
/// depends on both screens deriving the query from the same parcel. Reading the
/// parcel keeps that true when it gains a field.
ShippingQuery _cartQuery(WidgetTester tester, {String pin = '382415'}) =>
    _container(tester).read(checkoutParcelProvider).requireValue.toQuery(pin);

/// Simulates the cart: pins [option] for [query] before checkout is looked at.
void _chooseInCart(
  WidgetTester tester,
  ShippingQuery query,
  CourierOption option,
) =>
    _container(tester).read(shippingChoiceProvider.notifier).select(
          query,
          option,
        );

/// Taps a courier row the way a customer does.
///
/// **Every test that expects a total has to call this.** Nothing is preselected
/// any more: the screen quotes no delivery charge, prints no "To pay" and keeps
/// Place order disabled until a courier is tapped. That is the product decision,
/// not an accident of the fake — the web checkout behaves the same way.
Future<void> _pickCourier(
  WidgetTester tester, [
  String name = 'DTDC Air 500gm',
]) async {
  // Scrolled to first, not merely tapped. `tester.tap` only *warns* when the
  // hit lands on something else, so a courier row that has slipped under the
  // pinned action bar reads as a passing tap that selected nothing — and the
  // test then fails several assertions later with no clue why. The screen grows
  // (the billing block is the most recent reason); the helper has to keep up.
  await tester.ensureVisible(find.text(name).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).first);
  await tester.pumpAndSettle();
}

/// Taps the real button and lets the whole place-order sequence run.
Future<void> _tapPlaceOrder(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('checkout-place-order')));
  await tester.pumpAndSettle();
}

/// The divergence sheet's one-line statement of both figures.
String? _divergenceHeadline(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('checkout-divergence-headline')))
    .data;

CheckoutFlowState _flowState(WidgetTester tester) =>
    _container(tester).read(checkoutFlowProvider);

/// Every courier row currently on screen, sheet included.
Finder get _courierRadios => find.byType(Radio<int>);

Finder _summary() => find.byKey(const Key('checkout-shipping-summary'));

void main() {
  // -------------------------------------------------------------------------
  // Empty cart
  // -------------------------------------------------------------------------

  testWidgets('an empty cart gets an empty state, not an address form',
      (tester) async {
    final rates = _Rates();
    await tester.pumpWidget(await _screen(rates: rates));
    await tester.pumpAndSettle();

    expect(find.byType(EmptyView), findsOneWidget);
    expect(find.byKey(const Key('manual-address-zip')), findsNothing);
    // Nothing to weigh, so nothing was quoted.
    expect(rates.calls, isEmpty);
  });

  // -------------------------------------------------------------------------
  // Before an address exists
  // -------------------------------------------------------------------------

  testWidgets('no address: the order is blocked and no rate is requested',
      (tester) async {
    _useTallSurface(tester);
    final rates = _Rates();
    await tester.pumpWidget(await _screen(rates: rates, cart: [_wheat]));
    await tester.pumpAndSettle();

    expect(_placeOrderButton(tester).onPressed, isNull);
    // Names the rule that failed, in `AddressField.all` order — the form is
    // blank, so the first one is the name.
    expect(
      _blockerText(tester),
      'Add a complete delivery address to continue — Enter a name.',
    );
    // The bill admits it does not know rather than printing a number.
    expect(find.text('Add an address'), findsOneWidget);
    expect(rates.calls, isEmpty);
  });

  testWidgets('the bill never claims FREE delivery before a quote',
      (tester) async {
    _useTallSurface(tester);
    await tester.pumpWidget(await _screen(rates: _Rates(), cart: [_wheat]));
    await tester.pumpAndSettle();

    expect(find.text('FREE'), findsNothing);
    // "Subtotal", not "To pay" — the figure on screen is not the amount due.
    expect(find.text('Subtotal'), findsOneWidget);
    expect(find.text('To pay'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // The quote
  // -------------------------------------------------------------------------

  testWidgets('a valid PIN quotes the cart weight, not one unit',
      (tester) async {
    _useTallSurface(tester);
    final rates = _Rates();
    await tester.pumpWidget(
      await _screen(rates: rates, cart: [_wheat, _jaggery]),
    );
    await tester.pumpAndSettle();
    await _enterAddress(tester);

    expect(rates.calls, hasLength(1));
    final query = rates.calls.single;
    expect(query.pinCode, '382415');
    // 5 kg x 2 + 1 kg x 1 = 11 kg. Quoting the 0.5 kg floor here is what would
    // under-bill a heavy order.
    expect(query.weightKg, closeTo(11, 0.001));
    // `order_total`, not the pre-tax subtotal — the server adds GST on top.
    expect(query.declaredValue, closeTo(_orderTotal, 0.001));
    expect(query.declaredValue, isNot(closeTo(_subtotal, 0.001)));
    expect(query.cod, isFalse);
  });

  // The state the product decision creates, and the one that lasts longest: the
  // couriers are listed, none is chosen, and the screen refuses to invent a
  // delivery charge or a total for them.
  testWidgets('quotes no delivery charge until a courier is tapped',
      (tester) async {
    _useTallSurface(tester);
    await tester.pumpWidget(
      await _screen(rates: _Rates(), cart: [_wheat, _jaggery]),
    );
    await tester.pumpAndSettle();
    await _enterAddress(tester);

    // Both couriers are on offer...
    expect(find.text('DTDC Air 500gm'), findsWidgets);
    expect(find.text('DTDC Surface 2kg'), findsWidgets);
    // ...and neither is priced into the bill.
    expect(find.text('To pay'), findsNothing);
    expect(find.text('₹3,259.79'), findsNothing);
    expect(find.text('₹3,130.11'), findsNothing);
    // Free shipping and no-shipping-chosen are different things.
    final shipping = tester
        .widgetList<BillRow>(find.byType(BillRow))
        .firstWhere((row) => row.label == 'Shipping');
    expect(shipping.value, isNot('FREE'));
    expect(shipping.value, isNot('₹0.00'));
    expect(shipping.value, 'Choose an option above');
    // Nothing is ticked. A radio group with a filled dot is the app answering
    // for the customer, which is exactly what this round removed.
    expect(
      RadioGroup.maybeOf<int>(
        tester.element(find.byType(Radio<int>).first),
      )?.groupValue,
      isNull,
    );
    // The button carries no figure either — there is no total to claim.
    expect(find.text('Place order'), findsOneWidget);
    expect(find.textContaining('Place order  •'), findsNothing);

    expect(_placeOrderButton(tester).onPressed, isNull);
    // The blocker names the control that clears it, and that control is on
    // screen under exactly this caption — on this screen and on the cart.
    expect(_blockerText(tester), 'Choose a delivery option to continue.');
    expect(find.text('Choose a delivery option'), findsOneWidget);
  });

  testWidgets('the courier the customer taps becomes the delivery line and '
      'the total', (tester) async {
    _useTallSurface(tester);
    await tester.pumpWidget(
      await _screen(rates: _Rates(), cart: [_wheat, _jaggery]),
    );
    await tester.pumpAndSettle();
    await _enterAddress(tester);
    await _pickCourier(tester);

    // Delivery line and courier price, from the server's own components.
    expect(find.text('₹319.79'), findsWidgets);
    expect(find.text('FREE'), findsNothing);
    // 2940 + 319.79
    expect(find.text('To pay'), findsOneWidget);
    expect(find.text('₹3,259.79'), findsWidgets);
    expect(_placeOrderButton(tester).onPressed, isNotNull);
    expect(_blockerText(tester), isNull);
  });

  testWidgets('picking a different courier re-prices the bill', (tester) async {
    _useTallSurface(tester);
    await tester.pumpWidget(
      await _screen(rates: _Rates(), cart: [_wheat, _jaggery]),
    );
    await tester.pumpAndSettle();
    await _enterAddress(tester);

    await tester.tap(find.text('DTDC Surface 2kg'));
    await tester.pumpAndSettle();

    // 2940 + 190.11
    expect(find.text('₹3,130.11'), findsWidgets);
    expect(find.text('₹3,259.79'), findsNothing);
  });

  testWidgets('changing the PIN re-quotes and drops the pinned courier',
      (tester) async {
    _useTallSurface(tester);
    final rates = _Rates();
    await tester.pumpWidget(
      await _screen(rates: rates, cart: [_wheat, _jaggery]),
    );
    await tester.pumpAndSettle();
    await _enterAddress(tester);

    // Pin the slower, cheaper courier for this pincode.
    await tester.tap(find.text('DTDC Surface 2kg'));
    await tester.pumpAndSettle();
    expect(find.text('₹3,130.11'), findsWidgets);

    // Now ship somewhere else. `DTDC Surface 2kg at ₹190.11` was a quote for
    // *that* destination; carrying it over would bill a price nobody quoted.
    await tester.enterText(
      find.byKey(const Key('manual-address-zip')),
      '110001',
    );
    await tester.pumpAndSettle();

    expect(rates.calls, hasLength(2));
    expect(rates.calls.map((q) => q.pinCode), ['382415', '110001']);
    // The choice was made for the old destination, so it does not carry — and
    // nothing steps in for it. The customer chooses again for the new pincode.
    expect(find.text('₹3,130.11'), findsNothing);
    expect(find.text('₹3,259.79'), findsNothing);
    expect(find.text('To pay'), findsNothing);
    expect(_placeOrderButton(tester).onPressed, isNull);
    expect(_blockerText(tester), 'Choose a delivery option to continue.');
    expect(find.text('Delivering to 110001'), findsOneWidget);

    // ...and choosing again completes the bill at the new destination's price.
    await _pickCourier(tester);
    expect(find.text('₹3,259.79'), findsWidgets);
  });

  // -------------------------------------------------------------------------
  // Undeliverable
  // -------------------------------------------------------------------------

  testWidgets('an undeliverable PIN blocks the order', (tester) async {
    _useTallSurface(tester);
    final rates = _Rates(
      result: ShippingRates.unavailable(
        'No courier service available between 110055 and 999999',
      ),
    );
    await tester.pumpWidget(await _screen(rates: rates, cart: [_wheat]));
    await tester.pumpAndSettle();
    await _enterAddress(tester, pin: '999999');

    expect(_placeOrderButton(tester).onPressed, isNull);
    expect(
      _blockerText(tester),
      "We can't deliver to 999999. Choose a different address to continue.",
    );
    // The server's own sentence reaches the customer.
    expect(
      find.text('No courier service available between 110055 and 999999'),
      findsOneWidget,
    );
    // And the bill still refuses to name a delivery charge — as a refusal, not
    // as a nudge to pick from a list that has nothing in it.
    expect(find.text('To pay'), findsNothing);
    expect(find.text("We can't deliver here"), findsOneWidget);
    expect(find.text('Choose an option above'), findsNothing);
  });

  testWidgets('an empty courier list refuses the same way a 404 does',
      (tester) async {
    _useTallSurface(tester);
    // `success: true` with zero couriers — the endpoint's other way of saying
    // no. It must not read as an ordinary empty list.
    final rates = _Rates(result: ShippingRates.fromCouriers(const []));
    await tester.pumpWidget(await _screen(rates: rates, cart: [_wheat]));
    await tester.pumpAndSettle();
    await _enterAddress(tester, pin: '999999');

    expect(_placeOrderButton(tester).onPressed, isNull);
    expect(
      _blockerText(tester),
      "We can't deliver to 999999. Choose a different address to continue.",
    );
    expect(find.text("We can't deliver here"), findsOneWidget);
    expect(find.text('To pay'), findsNothing);
  });

  testWidgets('a rate failure blocks the order and offers a retry',
      (tester) async {
    _useTallSurface(tester);
    final rates = _Rates(error: const ApiException('Shiprocket unreachable'));
    await tester.pumpWidget(await _screen(rates: rates, cart: [_wheat]));
    await tester.pumpAndSettle();
    await _enterAddress(tester);

    expect(_placeOrderButton(tester).onPressed, isNull);
    expect(
      _blockerText(tester),
      'Shipping charges are unavailable right now — try again above.',
    );
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('the customer is told while couriers are being checked',
      (tester) async {
    _useTallSurface(tester);
    final rates = _Rates(delay: const Duration(milliseconds: 200));
    await tester.pumpWidget(await _screen(rates: rates, cart: [_wheat]));
    await tester.pumpAndSettle();
    await _enterAddress(tester, settle: false);

    expect(_blockerText(tester), 'Checking couriers for 382415…');
    expect(_placeOrderButton(tester).onPressed, isNull);
    // The bill row says the same thing, rather than telling the customer to
    // choose from a list that has not arrived.
    expect(find.text('Calculating…'), findsOneWidget);
    expect(find.text('Choose an option above'), findsNothing);

    await tester.pumpAndSettle();
  });

  testWidgets('a failed quote is not shown on the bill as a nudge to choose',
      (tester) async {
    _useTallSurface(tester);
    final rates = _Rates(error: const ApiException('Shiprocket unreachable'));
    await tester.pumpWidget(await _screen(rates: rates, cart: [_wheat]));
    await tester.pumpAndSettle();
    await _enterAddress(tester);

    expect(find.text('Unavailable — retry above'), findsOneWidget);
    expect(find.text('Choose an option above'), findsNothing);
    expect(find.text('FREE'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // Parcel weight
  // -------------------------------------------------------------------------

  testWidgets('a line with no recorded weight is disclosed, not hidden',
      (tester) async {
    _useTallSurface(tester);
    final rates = _Rates();
    await tester.pumpWidget(
      await _screen(
        rates: rates,
        cart: [_wheat, _jaggery],
        // Only the wheat has a pack weight on record.
        unweighed: const {121},
      ),
    );
    await tester.pumpAndSettle();
    await _enterAddress(tester);

    expect(rates.calls.single.weightKg, closeTo(10, 0.001));
    // The caveat rides on the bill's delivery line, so it appears once there is
    // a delivery charge to caveat.
    await _pickCourier(tester);
    expect(
      find.textContaining('no pack weight on record for 1 item'),
      findsOneWidget,
    );
  });

  testWidgets('an unweighed catalogue still lets the order through on a floor '
      'quote', (tester) async {
    _useTallSurface(tester);
    final rates = _Rates();
    await tester.pumpWidget(
      await _screen(rates: rates, cart: [_wheat], unweighed: const {118}),
    );
    await tester.pumpAndSettle();
    await _enterAddress(tester);

    // The web's own floor: `max($weight, 0.5)` in getServiceabilityRates().
    // A basket with no weight on record has no dimensions either, so the
    // default box and the floor arrive together.
    expect(rates.calls.single.weightKg, closeTo(0.5, 0.001));

    await _pickCourier(tester);
    expect(find.textContaining('no pack weight on record'), findsOneWidget);
    expect(_placeOrderButton(tester).onPressed, isNotNull);
  });

  // -------------------------------------------------------------------------
  // Signed in
  // -------------------------------------------------------------------------

  testWidgets('a saved address quotes immediately, with no typing',
      (tester) async {
    _useTallSurface(tester);
    final rates = _Rates();
    await tester.pumpWidget(
      await _screen(
        rates: rates,
        cart: [_wheat],
        signedIn: true,
        book: [_address],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Suraj ojha'), findsOneWidget);
    expect(rates.calls.single.pinCode, '382415');
    // The quote arrives without typing; the *choice* still has to be made.
    expect(find.text('₹319.79'), findsWidgets);
    expect(_placeOrderButton(tester).onPressed, isNull);

    await _pickCourier(tester);
    expect(_placeOrderButton(tester).onPressed, isNotNull);
  });

  // -------------------------------------------------------------------------
  // Section 2: confirm the cart's courier, do not ask again
  // -------------------------------------------------------------------------

  group('the chosen courier', () {
    testWidgets('is confirmed here, not offered a second time', (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(rates: _Rates(), cart: [_wheat, _jaggery]),
      );
      await tester.pumpAndSettle();

      // The cart's pick: the slower, cheaper courier — deliberately *not* the
      // one checkout would preselect on its own, so a screen that quietly
      // re-chose would show ₹3,259.79 here for an order the customer agreed to
      // at ₹3,130.11.
      _chooseInCart(tester, _cartQuery(tester), _cheapest);
      await _enterAddress(tester);

      expect(_summary(), findsOneWidget);
      expect(
        _courierRadios,
        findsNothing,
        reason: 'the choice was made on the cart; checkout confirms it',
      );
      // Name, delivery estimate and charge — the three things being confirmed.
      expect(find.text('DTDC Surface 2kg'), findsWidgets);
      expect(find.text('Delivery in 5 days'), findsOneWidget);
      expect(find.text('₹190.11'), findsWidgets);
      // One order, one total: 2940 + 190.11, the same figure the cart showed.
      expect(find.text('₹3,130.11'), findsWidgets);
      expect(find.text('₹3,259.79'), findsNothing);
      expect(_placeOrderButton(tester).onPressed, isNotNull);
    });

    testWidgets('can still be changed, from a sheet', (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(rates: _Rates(), cart: [_wheat, _jaggery]),
      );
      await tester.pumpAndSettle();
      _chooseInCart(tester, _cartQuery(tester), _cheapest);
      await _enterAddress(tester);

      await tester.tap(find.byKey(const Key('checkout-shipping-change')));
      await tester.pumpAndSettle();

      // The full list, in the sheet — the one place it still appears.
      expect(find.byType(ShippingSelector), findsOneWidget);
      expect(_courierRadios, findsNWidgets(2));

      await tester.tap(
        find.descendant(
          of: find.byType(ShippingSelector),
          matching: find.text('DTDC Air 500gm'),
        ),
      );
      await tester.pumpAndSettle();

      // Picking closes the sheet and the confirmation re-prices with it.
      expect(find.byType(ShippingSelector), findsNothing);
      expect(_summary(), findsOneWidget);
      expect(find.text('Delivery by 04 Aug'), findsOneWidget);
      expect(find.text('₹3,259.79'), findsWidgets);
      expect(find.text('₹3,130.11'), findsNothing);
    });

    testWidgets('falls back to the list when nothing was chosen',
        (tester) async {
      _useTallSurface(tester);
      // Straight to /checkout without visiting the cart.
      await tester.pumpWidget(
        await _screen(rates: _Rates(), cart: [_wheat, _jaggery]),
      );
      await tester.pumpAndSettle();
      await _enterAddress(tester);

      expect(_summary(), findsNothing);
      expect(
        _courierRadios,
        findsNWidgets(2),
        reason: 'checkout must never be a dead end with no courier',
      );

      // And choosing here is the same act as choosing on the cart: it settles
      // the question, so the block becomes the confirmation.
      await tester.tap(find.text('DTDC Surface 2kg'));
      await tester.pumpAndSettle();

      expect(_summary(), findsOneWidget);
      expect(_courierRadios, findsNothing);
      expect(find.text('₹3,130.11'), findsWidgets);
    });

    testWidgets('is not confirmed for an address it was never quoted for',
        (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(rates: _Rates(), cart: [_wheat, _jaggery]),
      );
      await tester.pumpAndSettle();

      // Chosen on the cart for Ahmedabad; checkout ships to Delhi.
      _chooseInCart(tester, _cartQuery(tester), _cheapest);
      await _enterAddress(tester, pin: '110001');

      expect(
        _summary(),
        findsNothing,
        reason: '₹190.11 was a quote for 382415, not for 110001',
      );
      expect(_courierRadios, findsNWidgets(2));
      expect(find.text('Delivering to 110001'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // The Items section — what "Buy now" made necessary
  // -------------------------------------------------------------------------

  group('the items section', () {
    // This screen used to list nothing at all. That was defensible while the
    // only way in was the basket, which the customer had just read; "Buy now"
    // now comes straight here from a product page, and a checkout that names
    // no products asks someone to pay for something it never showed them.
    testWidgets('names every line and prices it', (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(rates: _Rates(), cart: [_wheat, _jaggery]),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('checkout-items')), findsOneWidget);
      expect(find.text('Organic Sona Moti Wheat'), findsOneWidget);
      expect(find.text('Organic Khand'), findsOneWidget);
    });

    testWidgets('gives each line a counter showing its quantity',
        (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(rates: _Rates(), cart: [_wheat, _jaggery]),
      );
      await tester.pumpAndSettle();

      // The wheat line holds 2, the jaggery 1 — and the counter is the point
      // of the section: changing a quantity must not mean leaving a payment
      // flow the customer has already committed to.
      final wheat = find.byKey(const ValueKey('checkout-item-118'));
      final jaggery = find.byKey(const ValueKey('checkout-item-121'));
      expect(wheat, findsOneWidget);
      expect(jaggery, findsOneWidget);
      expect(
        find.descendant(of: wheat, matching: find.byType(QuantityStepper)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: jaggery, matching: find.byType(QuantityStepper)),
        findsOneWidget,
      );
    });

    testWidgets('+ raises the quantity without leaving the screen',
        (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(rates: _Rates(), cart: [_jaggery]),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(const ValueKey('checkout-item-121'));
      await tester.tap(
        find.descendant(of: row, matching: find.byIcon(Icons.add_rounded)),
      );
      await tester.pumpAndSettle();

      expect(find.text('2'), findsWidgets);
      expect(
        find.byKey(const Key('checkout-items')),
        findsOneWidget,
        reason: 'still on checkout',
      );
    });

    testWidgets('the last unit asks before it removes the line',
        (tester) async {
      // A removal here can empty the basket and end the checkout, which is not
      // something to do on a mis-tap of a 30dp button.
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(rates: _Rates(), cart: [_jaggery]),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(const ValueKey('checkout-item-121'));
      await tester.tap(
        find.descendant(of: row, matching: find.byIcon(Icons.remove_rounded)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Remove this item?'), findsOneWidget);

      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('checkout-item-121')), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Wording: "Shipping" is the charge, "Delivery" is the date
  // -------------------------------------------------------------------------

  group('wording', () {
    testWidgets('the section, the panel and the bill row all say Shipping',
        (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(rates: _Rates(), cart: [_wheat, _jaggery]),
      );
      await tester.pumpAndSettle();
      await _enterAddress(tester);

      expect(find.text('2. Shipping'), findsOneWidget);
      expect(find.text('2. Delivery'), findsNothing);
      expect(find.text('Shipping options'), findsOneWidget);
      expect(find.text('Delivery options'), findsNothing);
      // The bill's charge row.
      expect(find.text('Shipping'), findsOneWidget);
      expect(find.text('Delivery'), findsNothing);
      // The address is still delivered to somewhere.
      expect(find.text('1. Delivery address'), findsOneWidget);
    });

    testWidgets('but the estimate is still a delivery date', (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(rates: _Rates(), cart: [_wheat, _jaggery]),
      );
      await tester.pumpAndSettle();
      await _enterAddress(tester);

      expect(find.text('Delivery by 04 Aug'), findsWidgets);
      expect(find.textContaining('Shipping by'), findsNothing);
    });

    testWidgets('the pending row and the blocker say Shipping too',
        (tester) async {
      _useTallSurface(tester);
      final rates = _Rates(error: const ApiException('Shiprocket unreachable'));
      await tester.pumpWidget(await _screen(rates: rates, cart: [_wheat]));
      await tester.pumpAndSettle();
      await _enterAddress(tester);

      expect(
        _blockerText(tester),
        'Shipping charges are unavailable right now — try again above.',
      );
      expect(
        find.textContaining("Couldn't fetch shipping charges"),
        findsOneWidget,
      );
    });
  });

  // -------------------------------------------------------------------------
  // The blocker names the rule that actually failed
  // -------------------------------------------------------------------------

  group('the blocker sentence', () {
    testWidgets('names the broken rule on a saved address, not the PIN code',
        (tester) async {
      _useTallSurface(tester);
      // A real shape: `POST /ecommerce/addresses` leaves `state` nullable, so
      // state-less rows exist in real books. Its PIN is perfectly good — the
      // sentence used to blame it anyway, and sent the customer to fix
      // something that was not broken.
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_statelessAddress],
        ),
      );
      await tester.pumpAndSettle();

      expect(_placeOrderButton(tester).onPressed, isNull);
      expect(
        _blockerText(tester),
        'Enter the state — edit this address to continue.',
      );
      expect(_blockerText(tester), isNot(contains('PIN code')));
    });

    testWidgets('still names the PIN code when the PIN is what is wrong',
        (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_pinlessAddress],
        ),
      );
      await tester.pumpAndSettle();

      expect(_placeOrderButton(tester).onPressed, isNull);
      expect(
        _blockerText(tester),
        'Enter the 6-digit PIN code — edit this address to continue.',
      );
    });

    testWidgets('names the first missing field on a typed address',
        (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(await _screen(rates: _Rates(), cart: [_wheat]));
      await tester.pumpAndSettle();

      expect(
        _blockerText(tester),
        'Add a complete delivery address to continue — Enter a name.',
      );
    });
  });

  // -------------------------------------------------------------------------
  // What reaches the server, and what comes back
  // -------------------------------------------------------------------------

  group('the shipping option key', () {
    testWidgets('is the rate id, not the courier company id', (tester) async {
      _useTallSurface(tester);
      final checkout = _FakeCheckout();
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: checkout,
        ),
      );
      await tester.pumpAndSettle();
      // Nothing is preselected: the order cannot be placed until the
      // customer chooses who carries it.
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);

      // 1016322646 is the row's `id`. 196 is its `courier_company_id`, and
      // "shiprocket_196" is a key the server's table does not contain — it
      // would miss, and the order would be billed 0.00 for delivery.
      expect(checkout.lastOptionKey, 'shiprocket_1016322646');
      expect(checkout.lastOptionKey, isNot(contains('196')));
      expect(checkout.placeCalls, 1);
    });

    testWidgets('a courier with no rate id blocks the order', (tester) async {
      _useTallSurface(tester);
      final rates = _Rates(
        result: ShippingRates.fromCouriers([
          _courier(
            id: 196,
            name: 'DTDC Air 500gm',
            rate: 319.79,
            days: '3',
            rateId: null,
          ),
        ]),
      );
      final checkout = _FakeCheckout();
      await tester.pumpWidget(
        await _screen(
          rates: rates,
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: checkout,
        ),
      );
      await tester.pumpAndSettle();
      await _pickCourier(tester);

      // The price is quoted and shown — the row is a real offer — but there is
      // no key to send, and neither of the plausible substitutes is a key.
      expect(find.text('₹319.79'), findsWidgets);
      expect(_placeOrderButton(tester).onPressed, isNull);
      expect(
        _blockerText(tester),
        "This courier can't be booked right now — choose a different delivery "
        'option to continue.',
      );
      expect(checkout.placeCalls, 0);
    });
  });

  // -------------------------------------------------------------------------
  // The reconciliation
  // -------------------------------------------------------------------------

  group('the divergence sheet', () {
    testWidgets('opens when the server charges MORE, and holds the SDK back',
        (tester) async {
      _useTallSurface(tester);
      final gateway = _FakeGateway();
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          // Shown ₹2,944.79; the server re-quoted from its own store_zip_code
          // and billed ₹3,500.00.
          checkout: _FakeCheckout(
            place: OrderPlaced(
              _serverOrder(total: '3500.00', shipping: '875.00'),
            ),
          ),
          gateway: gateway,
        ),
      );
      await tester.pumpAndSettle();
      // Nothing is preselected, so there is no claim to make yet — the button
      // carries no figure until the customer chooses who carries the parcel.
      expect(find.textContaining('Place order  •'), findsNothing);

      await _pickCourier(tester);
      // The claim being made, on the button itself.
      expect(find.text('Place order  •  ₹2,944.79'), findsOneWidget);

      await _tapPlaceOrder(tester);

      expect(find.byKey(const Key('checkout-total-divergence')), findsOneWidget);
      // Both figures, plainly, and the server's shipping line beside them.
      expect(
        _divergenceHeadline(tester),
        'Your total is ₹3,500.00 — you were shown ₹2,944.79.',
      );
      expect(find.text('₹875.00'), findsWidgets);
      expect(find.text('+ ₹555.21'), findsOneWidget);
      // *** The whole point: no sheet, no charge, until they say so. ***
      expect(gateway.seen, isNull);
      expect(
        _flowState(tester).phase,
        CheckoutPhase.totalChanged,
      );
      // And "Place order" is gone, so a tap behind the sheet cannot make a
      // second order.
      expect(find.byKey(const Key('checkout-place-order')), findsNothing);
      expect(find.byKey(const Key('checkout-review-total')), findsOneWidget);
    });

    testWidgets('opens when the server charges LESS, and says why that is bad',
        (tester) async {
      _useTallSurface(tester);
      final gateway = _FakeGateway();
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          // The `shipping_option` lookup missed server-side: delivery landed at
          // 0.00 and the total is the goods alone.
          checkout: _FakeCheckout(
            place: OrderPlaced(_serverOrder(total: '2625.00', shipping: '0.00')),
          ),
          gateway: gateway,
        ),
      );
      await tester.pumpAndSettle();
      // Nothing is preselected: the order cannot be placed until the
      // customer chooses who carries it.
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);

      expect(find.byKey(const Key('checkout-total-divergence')), findsOneWidget);
      expect(
        _divergenceHeadline(tester),
        'Your total is ₹2,625.00 — you were shown ₹2,944.79.',
      );
      expect(find.text('− ₹319.79'), findsOneWidget);
      // An under-charge is not a silent win: the shipment has no courier on it,
      // and the panel says exactly that rather than "you are paying less".
      expect(
        find.byKey(const Key('checkout-divergence-no-courier')),
        findsOneWidget,
      );
      expect(find.text('No delivery charge on this order'), findsOneWidget);
      // Both delivery figures, side by side — ₹0.00 alone reads as good news.
      expect(find.text('Shipping quoted'), findsOneWidget);
      expect(find.text('₹0.00'), findsWidgets);
      expect(gateway.seen, isNull);
    });

    testWidgets('a Shiprocket outage is surfaced even when the total holds',
        (tester) async {
      // `HookServiceProvider.php:63-75` swallows the exception, so the order is
      // written with a 0.00 delivery line and no courier on it. Here the goods
      // happen to absorb the difference, so an arithmetic-only check would wave
      // it through and offer the customer a button to pay for a parcel nobody
      // can dispatch.
      _useTallSurface(tester);
      final gateway = _FakeGateway();
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: _FakeCheckout(
            place: OrderPlaced(_serverOrder(total: '2944.79', shipping: '0.00')),
          ),
          gateway: gateway,
        ),
      );
      await tester.pumpAndSettle();
      // Nothing is preselected: the order cannot be placed until the
      // customer chooses who carries it.
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);

      expect(find.byKey(const Key('checkout-total-divergence')), findsOneWidget);
      expect(
        find.byKey(const Key('checkout-divergence-no-courier')),
        findsOneWidget,
      );
      // The totals agree to the paise, so there is no More/Less line to draw
      // and "− ₹0.00" must not be drawn in its place.
      expect(find.text('More to pay'), findsNothing);
      expect(find.text('Less to pay'), findsNothing);
      expect(gateway.seen, isNull);
    });

    testWidgets('CANCEL charges nothing and keeps the cart and the record',
        (tester) async {
      _useTallSurface(tester);
      final gateway = _FakeGateway();
      final checkout = _FakeCheckout(
        place: OrderPlaced(_serverOrder(total: '3500.00', shipping: '875.00')),
      );
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: checkout,
          gateway: gateway,
        ),
      );
      await tester.pumpAndSettle();
      // Nothing is preselected: the order cannot be placed until the
      // customer chooses who carries it.
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);

      await tester.tap(find.byKey(const Key('checkout-divergence-cancel')));
      await tester.pumpAndSettle();

      final container = _container(tester);
      expect(find.byKey(const Key('checkout-total-divergence')), findsNothing);
      // Nothing was charged — the SDK was never opened.
      expect(gateway.seen, isNull);
      // ...and no second order was created on the way out.
      expect(checkout.placeCalls, 1);

      // The cart survives. It is the customer's basket, and the order they
      // declined to pay for is not a reason to take it away.
      expect(
        container.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-test',
      );
      // So does the pending record — between checkout and confirm-payment it is
      // the ONLY handle on the order, which `GET /orders` filters out.
      expect(container.read(pendingOrderStoreProvider).read()!.orderId, 1287);

      final state = container.read(checkoutFlowProvider);
      expect(state.phase, CheckoutPhase.paymentIncomplete);
      expect(state.isPaid, isFalse);
      // The message says both true things and neither false one.
      expect(
        find.textContaining('Nothing has been charged'),
        findsOneWidget,
      );
      expect(find.textContaining('Order 1287 was created'), findsOneWidget);
      // And the way forward is paying the SAME order, never placing another.
      expect(find.byKey(const Key('checkout-retry-payment')), findsOneWidget);
      expect(find.byKey(const Key('checkout-place-order')), findsNothing);
    });

    testWidgets('CONTINUE opens the SDK at the SERVER amount', (tester) async {
      _useTallSurface(tester);
      final gateway = _FakeGateway();
      final checkout = _FakeCheckout(
        place: OrderPlaced(_serverOrder(total: '3500.00', shipping: '875.00')),
      );
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: checkout,
          gateway: gateway,
        ),
      );
      await tester.pumpAndSettle();
      // Nothing is preselected: the order cannot be placed until the
      // customer chooses who carries it.
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);

      await tester.tap(find.byKey(const Key('checkout-divergence-continue')));
      await tester.pumpAndSettle();

      // 350000 paise = ₹3,500.00: the server's own figure, which is what
      // `razorpay.amount` already holds. Not the ₹2,944.79 on the button, and
      // not anything this app recomputed.
      expect(gateway.seen!.amountInPaise, 350000);
      expect(gateway.seen!.orderId, 'order_abc');
      // The existing Razorpay order was reopened, not a new one minted.
      expect(checkout.placeCalls, 1);
    });

    // The one panel in the app whose whole job is to be read carefully, on the
    // narrowest phone supported, at the accessibility text size. A black-and-
    // yellow overflow stripe across the figures would be the worst possible
    // place for one.
    testWidgets('lays out on a 320dp screen at the largest OS text scale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Not `MediaQuery(data: const MediaQueryData(...))` — that zeroes `size`
      // for everything below it, which is not what a large text scale does on a
      // device. Set before the first pump so the sheet is *laid out* at this
      // size rather than merely re-measured into it.
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: _FakeCheckout(
            place: OrderPlaced(
              _serverOrder(total: '3500.00', shipping: '875.00'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Nothing is preselected: the order cannot be placed until the
      // customer chooses who carries it.
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);

      // No overflow stripe anywhere — not on the sheet, and not on the bill
      // behind it, which is laid out at the same size and shares `_moneyRow`.
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('checkout-total-divergence')), findsOneWidget);
      expect(
        find.byKey(const Key('checkout-divergence-continue')),
        findsOneWidget,
      );

      // ...and every figure is fully inside the card that holds it, which is
      // the thing an overflow stripe would be hiding.
      final card = find.byKey(const Key('checkout-divergence-figures'));
      final bounds = tester.getRect(card);
      for (final figure in ['₹3,500.00', '₹875.00', '+ ₹555.21', '₹2,944.79']) {
        final text = find.descendant(of: card, matching: find.text(figure));
        expect(text, findsOneWidget, reason: '$figure is missing');
        expect(
          tester.getRect(text).right,
          lessThanOrEqualTo(bounds.right),
          reason: '$figure is striped off the right-hand edge',
        );
      }
    });

    testWidgets('leaves the SERVER figures on the bill, not the live cart',
        (tester) async {
      // The bug this pins: the screen kept rendering the bill it built from the
      // live cart and its own courier quote — a bold "To pay ₹2,944.79" — right
      // beside a button that pays the server's ₹3,500.00. Once the order
      // exists, the cart is not what is owed.
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: _FakeCheckout(
            place: OrderPlaced(_serverOrder(total: '3500.00', shipping: '875.00')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Nothing is preselected: the order cannot be placed until the
      // customer chooses who carries it.
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);
      await tester.tap(find.byKey(const Key('checkout-divergence-cancel')));
      await tester.pumpAndSettle();

      // *** The app's own total is nowhere on screen. ***
      expect(find.text('₹2,944.79'), findsNothing);
      expect(find.byKey(const Key('checkout-order-bill')), findsOneWidget);
      // The server's, in the server's own rendering, including its shipping
      // line — the one figure that actually moved.
      expect(find.text('₹3,500.00'), findsWidgets);
      expect(find.text('₹875.00'), findsOneWidget);
      expect(find.text('Order 1287'), findsOneWidget);

      // The three live sections are gone with it: an editable address, a
      // re-priceable courier and a cart-derived bill are all answers to
      // questions this order has already settled.
      expect(find.text('Bill details'), findsNothing);
      expect(find.text('Item total'), findsNothing);
      expect(find.text('1. Delivery address'), findsNothing);
      expect(find.text('2. Shipping'), findsNothing);
      expect(_summary(), findsNothing);
    });

    testWidgets('start over is offered, warns, and returns to Place order',
        (tester) async {
      // Declining the server's total used to be permanent: every control from
      // there pays the order that exists, and nothing the customer could reach
      // ever cleared the flow — so they could never place another order.
      _useTallSurface(tester);
      final checkout = _FakeCheckout(
        place: OrderPlaced(_serverOrder(total: '3500.00', shipping: '875.00')),
      );
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: checkout,
        ),
      );
      await tester.pumpAndSettle();
      // Nothing is preselected: the order cannot be placed until the
      // customer chooses who carries it.
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);
      await tester.tap(find.byKey(const Key('checkout-divergence-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('checkout-start-over')), findsOneWidget);
      await tester.tap(find.byKey(const Key('checkout-start-over')));
      await tester.pumpAndSettle();

      // It says what starting again leaves behind, because nothing in this app
      // can cancel the order that exists and the next checkout overwrites the
      // record that names it.
      expect(find.byKey(const Key('checkout-start-over-dialog')), findsOneWidget);
      expect(find.textContaining('Order 1287'), findsWidgets);
      expect(find.textContaining('second'), findsOneWidget);

      await tester.tap(find.byKey(const Key('checkout-start-over-confirm')));
      await tester.pumpAndSettle();

      // Back to a checkout that can be completed, with the basket intact and
      // still exactly one order placed.
      expect(find.byKey(const Key('checkout-place-order')), findsOneWidget);
      expect(find.byKey(const Key('checkout-order-bill')), findsNothing);
      expect(find.text('Place order  •  ₹2,944.79'), findsOneWidget);
      expect(checkout.placeCalls, 1);
      expect(
        _container(tester)
            .read(sharedPreferencesProvider)
            .getString('server_cart_id_v1'),
        'cart-test',
      );
      // The record is still the only handle on 1287 until another order
      // overwrites it — the launch pass is what reports it.
      expect(
        _container(tester).read(pendingOrderStoreProvider).read()!.orderId,
        1287,
      );
    });

    // The gap this closed: a customer who cancels payment, goes back to the
    // cart, adds another item, and returns to checkout sees this exact panel
    // — the same frozen order and total as before, with the new item nowhere
    // on screen and no explanation why. "Start a new order" was always the
    // way out, but nothing said so.
    testWidgets('an unpaid order explains that anything added since is not '
        'on it', (tester) async {
      _useTallSurface(tester);
      final checkout = _FakeCheckout(
        place: OrderPlaced(_serverOrder(total: '3500.00', shipping: '875.00')),
      );
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: checkout,
        ),
      );
      await tester.pumpAndSettle();
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);
      await tester.tap(find.byKey(const Key('checkout-divergence-cancel')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Added anything to your cart since'),
        findsOneWidget,
      );
      expect(find.textContaining('Start a new order'), findsWidgets);
    });

    testWidgets('an emptied basket cannot hide the order that exists',
        (tester) async {
      // The cart is deliberately preserved through a declined payment, so it
      // can also be emptied elsewhere and come back. The empty state used to
      // win, taking away the only button that can pay for the order.
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: _FakeCheckout(
            place: OrderPlaced(_serverOrder(total: '3500.00', shipping: '875.00')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Nothing is preselected: the order cannot be placed until the
      // customer chooses who carries it.
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);
      await tester.tap(find.byKey(const Key('checkout-divergence-cancel')));
      await tester.pumpAndSettle();

      // The customer empties it from the cart tab and comes back.
      await _container(tester).read(serverCartProvider.notifier).clear();
      await tester.pumpAndSettle();
      expect(_container(tester).read(serverCartProvider).isEmpty, isTrue);

      expect(find.byType(EmptyView), findsNothing);
      expect(find.byKey(const Key('checkout-order-bill')), findsOneWidget);
      expect(find.byKey(const Key('checkout-retry-payment')), findsOneWidget);
      expect(find.text('₹3,500.00'), findsWidgets);
    });

    testWidgets('never appears when the two totals agree', (tester) async {
      _useTallSurface(tester);
      final gateway = _FakeGateway();
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          // The ordinary case: the server priced the same option the app named.
          checkout: _FakeCheckout(place: OrderPlaced(_serverOrder())),
          gateway: gateway,
        ),
      );
      await tester.pumpAndSettle();
      // Nothing is preselected: the order cannot be placed until the
      // customer chooses who carries it.
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);

      expect(find.byKey(const Key('checkout-total-divergence')), findsNothing);
      // Straight to payment, with nobody asked anything.
      expect(gateway.seen!.amountInPaise, 294479);
    });
  });

  // -------------------------------------------------------------------------
  // A cancelled sheet goes back to the cart
  //
  // TEMPORARY behaviour — see docs/TODO_CANCELLED_PAYMENT_FLOW.md. The
  // dismissed sheet used to park this screen on the order panel with "Retry
  // payment" and "Start a new order"; the interim decision abandons the order
  // and returns the customer to the cart, where the next checkout creates a
  // fresh order.
  // -------------------------------------------------------------------------

  group('a cancelled sheet', () {
    testWidgets('pops back to the cart with the flow reset', (tester) async {
      _useTallSurface(tester);
      final checkout = _FakeCheckout(place: OrderPlaced(_serverOrder()));
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: checkout,
          // The default gateway answers PaymentCancelled, which is the event
          // under test.
          pushedFromCart: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stub-open-checkout')));
      await tester.pumpAndSettle();
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);
      await tester.pumpAndSettle();

      // Back on the cart — checkout popped itself. None of the old order
      // furniture survives anywhere.
      expect(find.byKey(const Key('stub-open-checkout')), findsOneWidget);
      expect(find.byType(CheckoutScreen), findsNothing);
      expect(find.byKey(const Key('checkout-order-bill')), findsNothing);
      expect(find.byKey(const Key('checkout-start-over')), findsNothing);
      expect(find.byKey(const Key('checkout-retry-payment')), findsNothing);

      // `_container` keys off CheckoutScreen, which has just popped — the
      // stub is inside the same ProviderScope, so read through it instead.
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('stub-open-checkout'))),
      );
      // Reset, so the next visit is a clean checkout, not the old order.
      expect(container.read(checkoutFlowProvider).phase, CheckoutPhase.idle);
      // The journal is settled — rehydration and the launch recovery pass
      // both ignore it, so the abandoned order cannot resurface anywhere.
      expect(
        container.read(pendingOrderStoreProvider).read()!.stage,
        PendingOrderStage.settled,
      );
      // The basket survives; it is what the next checkout re-orders.
      expect(
        container.read(sharedPreferencesProvider).getString('server_cart_id_v1'),
        'cart-test',
      );
    });

    testWidgets('checking out again creates a fresh order', (tester) async {
      _useTallSurface(tester);
      final checkout = _FakeCheckout(place: OrderPlaced(_serverOrder()));
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: checkout,
          pushedFromCart: true,
        ),
      );
      await tester.pumpAndSettle();

      // First attempt: sheet opens, customer dismisses, back on the cart.
      await tester.tap(find.byKey(const Key('stub-open-checkout')));
      await tester.pumpAndSettle();
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stub-open-checkout')), findsOneWidget);

      // Second attempt goes back through the checkout POST — a genuinely new
      // order — rather than resurrecting the abandoned one.
      await tester.tap(find.byKey(const Key('stub-open-checkout')));
      await tester.pumpAndSettle();
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);
      await tester.pumpAndSettle();

      expect(checkout.placeCalls, 2);
    });
  });

  // -------------------------------------------------------------------------
  // Billing address
  // -------------------------------------------------------------------------

  group('billing address', () {
    testWidgets('defaults to the delivery address, and says so', (tester) async {
      _useTallSurface(tester);
      final checkout = _FakeCheckout();
      await tester.pumpWidget(
        // Signed in with a saved row: `_placeOrder` sends a signed-out customer
        // to `/login` instead of the repository, and this harness has no router.
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: checkout,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Billing address same as delivery'), findsOneWidget);
      expect(_billingSwitch(tester).value, isTrue);
      // No second form until it is turned off.
      expect(find.byKey(const Key('checkout-billing-picker')), findsNothing);

      await _pickCourier(tester);
      await _tapPlaceOrder(tester);

      expect(checkout.placeCalls, 1);
      // Null is the *statement* "same as delivery" — the repository turns it
      // into `billing_address_same_as_shipping_address: "1"`, which is what
      // keeps the order legal once the shop enables billing addresses.
      expect(checkout.lastBillingAddress, isNull);
    });

    testWidgets('turning it off reveals a second picker and blocks the order',
        (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(rates: _Rates(), cart: [_wheat]),
      );
      await tester.pumpAndSettle();
      await _enterAddress(tester);
      await _pickCourier(tester);
      // Everything else is satisfied, so the only thing that can block now is
      // the billing address.
      expect(_placeOrderButton(tester).onPressed, isNotNull);

      await _setBillingSame(tester, false);

      expect(find.byKey(const Key('checkout-billing-picker')), findsOneWidget);
      expect(_placeOrderButton(tester).onPressed, isNull);
      expect(
        _blockerText(tester),
        'Complete the billing address, or switch it back to the delivery '
        'address.',
      );
    });

    testWidgets('a completed billing address reaches the repository',
        (tester) async {
      _useTallSurface(tester);
      final checkout = _FakeCheckout();
      final rates = _Rates();
      await tester.pumpWidget(
        await _screen(
          rates: rates,
          cart: [_wheat],
          signedIn: true,
          // Two rows, so the billing address can be a genuinely different one
          // rather than the delivery address under another name.
          book: [_address, _billingRow],
          checkout: checkout,
        ),
      );
      await tester.pumpAndSettle();
      await _pickCourier(tester);
      await _setBillingSame(tester, false);
      await _chooseBillingRow(tester, _billingRow.id);

      expect(_blockerText(tester), isNull);
      await _tapPlaceOrder(tester);

      final billing = checkout.lastBillingAddress;
      expect(billing, isNotNull);
      expect(billing!.name, 'Uminber Accounts');
      expect(billing.zipCode, '380015');
      // A billing address must not become a delivery address: the parcel still
      // goes where the customer said it goes, and the billing PIN never asks
      // for a courier.
      expect(rates.calls.map((q) => q.pinCode).toSet(), {'382415'});
    });

    testWidgets('switching back drops the chosen billing address',
        (tester) async {
      // Otherwise a later toggle resurrects a choice the customer has since
      // moved away from, and it goes out on the order unseen.
      _useTallSurface(tester);
      final checkout = _FakeCheckout();
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address, _billingRow],
          checkout: checkout,
        ),
      );
      await tester.pumpAndSettle();
      await _pickCourier(tester);

      await _setBillingSame(tester, false);
      await _chooseBillingRow(tester, _billingRow.id);
      await _setBillingSame(tester, true);
      await _setBillingSame(tester, false);
      await tester.pumpAndSettle();

      await _tapPlaceOrder(tester);

      // A fresh picker, so it re-derives from the address book — the default
      // row — rather than resurrecting the accounts address chosen before.
      expect(checkout.lastBillingAddress!.name, 'Suraj ojha');
      expect(checkout.lastBillingAddress!.zipCode, '382415');
    });
  });

  // -------------------------------------------------------------------------
  // Tax information
  // -------------------------------------------------------------------------

  group('GST invoice details', () {
    testWidgets('none by default, and no block is sent', (tester) async {
      _useTallSurface(tester);
      final checkout = _FakeCheckout();
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: checkout,
        ),
      );
      await tester.pumpAndSettle();
      await _pickCourier(tester);
      await _tapPlaceOrder(tester);

      expect(checkout.lastTaxInformation, isNull);
    });

    testWidgets('what the cart collected rides along with the order',
        (tester) async {
      // The regression this pins: the GSTIN used to sit in `CheckoutState` and
      // reach no request at all, so every order went out with no tax row.
      _useTallSurface(tester);
      final checkout = _FakeCheckout();
      await tester.pumpWidget(
        await _screen(
          rates: _Rates(),
          cart: [_wheat],
          signedIn: true,
          book: [_address],
          checkout: checkout,
        ),
      );
      await tester.pumpAndSettle();

      // Exactly what the cart's sheet does.
      final failure = _container(tester)
          .read(checkoutProvider.notifier)
          .setTaxInformation(_taxBlock);
      expect(failure, isNull);

      await _pickCourier(tester);
      await _tapPlaceOrder(tester);

      expect(checkout.lastTaxInformation, {
        'company_name': 'Uminber India Pvt Ltd',
        'company_address': '306, Jahnavi Arcade, Ahmedabad',
        'company_tax_code': '27AAPFU0939F1Z5',
        'company_email': 'billing@uminber.in',
      });
    });

    testWidgets('an incomplete block is refused by the notifier, not stored',
        (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _screen(rates: _Rates(), cart: [_wheat]),
      );
      await tester.pumpAndSettle();

      final notifier = _container(tester).read(checkoutProvider.notifier);
      final failure = notifier.setTaxInformation(
        TaxInformation(
          companyName: '',
          companyAddress: '',
          companyTaxCode: '27AAPFU0939F1Z5',
          companyEmail: '',
        ),
      );

      expect(failure, 'Enter the company name');
      expect(_container(tester).read(checkoutProvider).taxInformation, isNull);
    });
  });
}

final _taxBlock = TaxInformation(
  companyName: 'Uminber India Pvt Ltd',
  companyAddress: '306, Jahnavi Arcade, Ahmedabad',
  companyTaxCode: '27AAPFU0939F1Z5',
  companyEmail: 'billing@uminber.in',
);

Switch _billingSwitch(WidgetTester tester) =>
    tester.widget<Switch>(find.byKey(const Key('checkout-billing-same')));

Future<void> _setBillingSame(WidgetTester tester, bool same) async {
  if (_billingSwitch(tester).value == same) return;
  await tester.tap(find.byKey(const Key('checkout-billing-same')));
  await tester.pumpAndSettle();
}

/// A second saved row, so a billing address can differ from the delivery one in
/// name, street and PIN — a test that echoed the delivery address back would
/// otherwise pass while the screen dropped the selection.
final _billingRow = Address.fromJson({
  'id': 21,
  'name': 'Uminber Accounts',
  'is_default': 0,
  'phone': '9812345670',
  'email': 'billing@uminber.in',
  'country': 'India',
  'state': 'Gujarat',
  'city': 'Ahmedabad',
  'address': '12 Prahlad Nagar Road',
  'zip_code': '380015',
  'full_address': '12 Prahlad Nagar Road, Ahmedabad, Gujarat, 380015',
});

/// Picks a saved row in the **billing** picker, via its own Change sheet.
///
/// The Change button is scoped with [find.descendant] deliberately: both
/// pickers use the same widget keys, so an unscoped finder matches two once
/// billing is expanded and would open the delivery picker's sheet instead. The
/// sheet itself is modal, so the row inside it needs no scoping.
Future<void> _chooseBillingRow(WidgetTester tester, int id) async {
  final change = find.descendant(
    of: find.byKey(const Key('checkout-billing-picker')),
    matching: find.byKey(const Key('address-picker-change')),
  );
  await tester.ensureVisible(change);
  await tester.pumpAndSettle();
  await tester.tap(change);
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(ValueKey('address-option-$id')));
  await tester.pumpAndSettle();
}

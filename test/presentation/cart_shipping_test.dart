import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/presentation/widgets/bill_details.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/payments/payment_gateway.dart';
import 'package:trueway_farms/data/models/address.dart';
import 'package:trueway_farms/data/models/shipping_quote.dart';
import 'package:trueway_farms/data/repositories/address_repository.dart';
import 'package:trueway_farms/data/repositories/checkout_repository.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/shipping_provider.dart';
import 'package:trueway_farms/presentation/screens/cart/cart_screen.dart';
import 'package:trueway_farms/presentation/screens/checkout/checkout_screen.dart';

import '../support/fake_cart_repository.dart';

/// **The cart completes its own total, and checkout agrees with it.**
///
/// The product decision behind this file has two halves that pull against each
/// other, and both have to hold at once:
///
///   * **Nothing is preselected.** The app must not choose a courier for the
///     customer. It used to pick the fastest, which put Blue Dart Air at
///     ₹1,284.15 in a bill whose other option was Xpressbees Surface at ₹324.30
///     two days later.
///   * **The cart must still reach a final amount.** Customers complained that
///     the cart created "suspense" by ending in a subtotal. Removing the
///     preselection is exactly the change that would bring that back — so the
///     courier list lives *on the cart*, open, above the bill, and one tap
///     turns "Subtotal" into "To pay" without leaving the screen.
///
/// Everything here is asserted on the real [CartScreen] and the real
/// [CheckoutScreen], because both halves are claims about what a customer sees
/// on a whole screen: the bill, the button and the courier rows have to agree
/// with each other, and `delivery_location_test.dart` can only see the card.
///
/// Nothing touches the network. Every repository is a fake and
/// [shippingRatesFetcherProvider] is the single seam onto logistics, so no
/// `ApiClient` — and therefore no socket — is ever constructed.

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// Rows shaped like a captured `POST /logistics/check-serviceability` body:
/// `estimated_delivery_days` arrives as the String "3" and `cod` as the int 1.
CourierOption _courier({
  required int id,
  required String name,
  required num rate,
  required String days,
  String etd = '',
}) =>
    CourierOption.fromJson({
      'courier_company_id': id,
      'id': 1016322646 + id,
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

/// Fastest, and deliberately **not** cheapest — so a screen that quietly
/// re-chose for the customer would show a different figure from one that did
/// not.
final _fastest = _courier(
  id: 196,
  name: 'DTDC Air 500gm',
  rate: 319.79,
  days: '3',
  etd: 'Aug 04, 2026',
);

final _cheapest = _courier(
  id: 55,
  name: 'DTDC Surface 2kg',
  rate: 190.11,
  days: '5',
);

/// 1250 × 2 + 300 = 2800 at MRP; the server adds 5% on top, so `order_total` is
/// 2940 and every "To pay" below is that plus one courier's charge.
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

const _box = {
  'length': 21.0,
  'breadth': 16.0,
  'height': 17.0,
  'weight': 11.0,
};

/// The goods, as the server prices them. Nothing here is recomputed by the app.
const String _itemTotal = '₹2,800.00';
const String _gst = '₹140.00';

/// The GST row as it is rendered: **prefixed with a plus**.
///
/// This backend is tax-exclusive — `discounted_sub_total + discounted_tax =
/// order_total` — so the row is an addition, and the sign says so. Without it
/// the bill reads as though the tax were already inside the lines above and
/// then visibly fails to sum to the total.
const String _gstRow = '+ $_gst';
const String _goodsOnly = '₹2,940.00';

/// 2940 + 319.79, and 2940 + 190.11.
const String _payableFastest = '₹3,259.79';
const String _payableCheapest = '₹3,130.11';

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

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeAddressRepository implements AddressRepository {
  @override
  Future<List<Address>> all() async => [_address];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Never called. Present only so `checkoutFlowProvider` cannot construct a real
/// [CheckoutRepository] — which would build an `ApiClient` — while checkout is
/// on screen.
class _FakeCheckout implements CheckoutRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeGateway implements PaymentGateway {
  @override
  Future<PaymentResult> pay(PaymentRequest request) async =>
      const PaymentCancelled();

  @override
  void dispose() {}
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// One container for the whole test, so the cart and checkout are looked at by
/// the *same* app rather than by two isolated ones.
///
/// That is the point of the agreement tests: `shippingChoiceProvider` is what
/// carries the customer's pick from one screen to the other, and a fresh
/// `ProviderScope` per screen would quietly reset it and let both screens pass
/// while disagreeing in production.
Future<ProviderContainer> _container({
  List<FakeCartLine> cart = const [_wheat, _jaggery],
  List<CourierOption> couriers = const [],
}) async {
  SharedPreferences.setMockInitialValues({
    if (cart.isNotEmpty) 'server_cart_id_v1': 'cart-test',
  });
  final prefs = await SharedPreferences.getInstance();
  final rows = couriers.isEmpty ? [_fastest, _cheapest] : couriers;

  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      cartRepositoryProvider.overrideWithValue(
        FakeCartRepository(lines: cart, packageDimensions: _box),
      ),
      addressRepositoryProvider.overrideWithValue(_FakeAddressRepository()),
      isAuthenticatedProvider.overrideWithValue(true),
      shippingRatesFetcherProvider.overrideWithValue(
        (_) async => ShippingRates.fromCouriers(rows),
      ),
      checkoutRepositoryProvider.overrideWithValue(_FakeCheckout()),
      paymentGatewayProvider.overrideWithValue(_FakeGateway()),
    ],
  );
}

/// Both screens are long, and a `ListView` does not build what it cannot show —
/// so a short surface would make "the bill says Subtotal" pass by never
/// building the bill.
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _show(
  WidgetTester tester,
  ProviderContainer container,
  Widget screen,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.light, home: screen),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _showCart(WidgetTester tester, ProviderContainer container) =>
    _show(tester, container, const CartScreen(showBack: false));

Future<void> _showCheckout(WidgetTester tester, ProviderContainer container) =>
    _show(tester, container, const CheckoutScreen());

/// Taps a courier row the way a customer does. The compact cart tile leads with
/// the delivery date and carries the courier's name underneath, so the name is
/// the unambiguous handle on both screens.
Future<void> _pick(WidgetTester tester, [String name = 'DTDC Air 500gm']) async {
  await tester.tap(find.text(name).first);
  await tester.pumpAndSettle();
}

/// The group value the courier radios are actually sharing — the one thing that
/// says whether the app answered for the customer.
int? _groupValue(WidgetTester tester) => RadioGroup.maybeOf<int>(
      tester.element(find.byType(Radio<int>).first),
    )?.groupValue;

ElevatedButton _placeOrderButton(WidgetTester tester) =>
    tester.widget<ElevatedButton>(
      find.byKey(const Key('checkout-place-order')),
    );

String? _blockerText(WidgetTester tester) {
  final finder = find.byKey(const Key('checkout-blocker'));
  if (finder.evaluate().isEmpty) return null;
  return tester.widget<Text>(finder).data;
}

/// What the bill's Shipping row is actually showing.
///
/// Read off the row rather than searched for as loose text, so "there is no
/// ₹0.00 on this screen" cannot be satisfied by the row having scrolled away.
String _shippingValue(WidgetTester tester) => tester
    .widgetList<BillRow>(find.byType(BillRow))
    .firstWhere((row) => row.label == 'Shipping')
    .value;

void main() {
  // -------------------------------------------------------------------------
  // Before the tap
  // -------------------------------------------------------------------------

  group('the cart before a courier is chosen', () {
    testWidgets('lists the couriers, selects none of them', (tester) async {
      _useTallSurface(tester);
      final container = await _container();
      addTearDown(container.dispose);
      await _showCart(tester, container);

      // The list is *on the cart* and open — the customer never has to guess
      // that a decision is waiting for them behind a tap.
      expect(find.byType(Radio<int>), findsNWidgets(2));
      expect(find.text('DTDC Air 500gm'), findsOneWidget);
      expect(find.text('DTDC Surface 2kg'), findsOneWidget);

      // ...and not one of them is ticked.
      expect(_groupValue(tester), isNull);
      expect(find.byKey(const Key('cart-choose-delivery')), findsOneWidget);
      expect(find.text('Choose a delivery option'), findsOneWidget);
    });

    testWidgets('shows the goods total as a Subtotal, and asks for the rest',
        (tester) async {
      _useTallSurface(tester);
      final container = await _container();
      addTearDown(container.dispose);
      await _showCart(tester, container);

      // The bill is real and complete as far as it can be...
      expect(find.text('Item total'), findsOneWidget);
      expect(find.text(_itemTotal), findsOneWidget);
      expect(find.text('GST'), findsOneWidget);
      expect(find.text(_gstRow), findsOneWidget);
      // ...and stops short of claiming an amount due.
      expect(find.text('Subtotal'), findsOneWidget);
      expect(find.text('To pay'), findsNothing);
      expect(find.text(_goodsOnly), findsWidgets);

      // The Shipping row asks rather than answering, and the bar says what the
      // headline figure leaves out.
      expect(find.text('Shipping'), findsOneWidget);
      expect(find.text('Choose an option above'), findsOneWidget);
      expect(find.textContaining('excl. shipping'), findsOneWidget);
    });

    // The failure this whole slice exists to prevent. "No delivery option
    // chosen" is not "delivery is free", and it is not "delivery costs ₹0".
    testWidgets('never implies free delivery', (tester) async {
      _useTallSurface(tester);
      final container = await _container();
      addTearDown(container.dispose);
      await _showCart(tester, container);

      expect(find.text('FREE'), findsNothing);
      expect(_shippingValue(tester), isNot('₹0.00'));
      expect(_shippingValue(tester), isNot('FREE'));
      expect(find.textContaining('Free delivery'), findsNothing);
      // Nor a total that silently omits the courier.
      expect(find.text(_payableFastest), findsNothing);
      expect(find.text(_payableCheapest), findsNothing);
    });

    // A one-courier quote is still a decision: the tap is the customer
    // accepting a delivery charge, not resolving an ambiguity.
    testWidgets('a single courier is offered, not applied', (tester) async {
      _useTallSurface(tester);
      final container = await _container(couriers: [_fastest]);
      addTearDown(container.dispose);
      await _showCart(tester, container);

      expect(find.byType(Radio<int>), findsOneWidget);
      expect(_groupValue(tester), isNull);
      expect(find.text('Subtotal'), findsOneWidget);
      expect(find.text('To pay'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // The tap
  // -------------------------------------------------------------------------

  group('the cart once a courier is chosen', () {
    testWidgets('completes the bill on the spot: item total, GST, shipping, '
        'To pay', (tester) async {
      _useTallSurface(tester);
      final container = await _container();
      addTearDown(container.dispose);
      await _showCart(tester, container);
      await _pick(tester);

      expect(find.text('Item total'), findsOneWidget);
      expect(find.text(_itemTotal), findsOneWidget);
      expect(find.text('GST'), findsOneWidget);
      expect(find.text(_gstRow), findsOneWidget);
      // The courier's charge, on the bill's own Shipping row and on the
      // collapsed summary above it.
      expect(find.text('₹319.79'), findsWidgets);
      // ...and the amount due, named as such. This is the moment the "suspense"
      // complaint is answered, and it happens without leaving the cart.
      expect(find.text('To pay'), findsOneWidget);
      expect(find.text('Subtotal'), findsNothing);
      expect(find.text(_payableFastest), findsWidgets);
      expect(find.textContaining('excl. shipping'), findsNothing);
    });

    testWidgets('re-prices when a different courier is chosen', (tester) async {
      _useTallSurface(tester);
      final container = await _container();
      addTearDown(container.dispose);
      await _showCart(tester, container);

      await _pick(tester, 'DTDC Surface 2kg');
      expect(find.text(_payableCheapest), findsWidgets);
      expect(find.text(_payableFastest), findsNothing);

      // Reopen the collapsed block and change the answer.
      await tester.tap(find.text('Delivery in 5 days'));
      await tester.pumpAndSettle();
      await _pick(tester);

      expect(find.text(_payableFastest), findsWidgets);
      expect(find.text(_payableCheapest), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // One order, one figure
  // -------------------------------------------------------------------------

  group('the cart and checkout', () {
    testWidgets('show the same courier, the same charge and the same total',
        (tester) async {
      _useTallSurface(tester);
      final container = await _container();
      addTearDown(container.dispose);

      // Chosen on the cart — deliberately the *slower, cheaper* row, so a
      // checkout that re-chose on its own would show ₹3,259.79 for an order the
      // customer agreed to at ₹3,130.11.
      await _showCart(tester, container);
      await _pick(tester, 'DTDC Surface 2kg');

      expect(find.text('To pay'), findsOneWidget);
      expect(find.text(_payableCheapest), findsWidgets);
      expect(find.text('₹190.11'), findsWidgets);

      // Same app, same basket, same address — the customer just walked forward.
      await _showCheckout(tester, container);

      expect(find.text('DTDC Surface 2kg'), findsWidgets);
      expect(find.text('₹190.11'), findsWidgets);
      expect(find.text('To pay'), findsOneWidget);
      expect(find.text(_payableCheapest), findsWidgets);
      // Nothing the cart never showed.
      expect(find.text(_payableFastest), findsNothing);
      expect(find.text('₹319.79'), findsNothing);

      // And the decision carries as a decision: checkout confirms it rather
      // than asking again.
      expect(find.byKey(const Key('checkout-shipping-summary')), findsOneWidget);
      expect(find.byType(Radio<int>), findsNothing);
      expect(_placeOrderButton(tester).onPressed, isNotNull);
      expect(_blockerText(tester), isNull);
    });

    testWidgets('agree that nothing is chosen, and both say why',
        (tester) async {
      _useTallSurface(tester);
      final container = await _container();
      addTearDown(container.dispose);

      await _showCart(tester, container);
      expect(find.text('Subtotal'), findsOneWidget);
      expect(find.text('Choose an option above'), findsOneWidget);

      // Walking forward without answering does not conjure an answer.
      await _showCheckout(tester, container);

      expect(find.text('Subtotal'), findsOneWidget);
      expect(find.text('To pay'), findsNothing);
      expect(find.text('Choose an option above'), findsOneWidget);
      expect(find.text('FREE'), findsNothing);
      expect(_shippingValue(tester), isNot('₹0.00'));
      expect(_shippingValue(tester), isNot('FREE'));

      // The button is dead, and it says exactly which of the many possible
      // reasons this is — the one the customer can do something about.
      expect(_placeOrderButton(tester).onPressed, isNull);
      expect(_blockerText(tester), 'Choose a delivery option to continue.');
      // ...naming a caption that is genuinely on screen, not describing one.
      expect(find.text('Choose a delivery option'), findsOneWidget);
    });

    // The other direction. Checkout is reachable without ever seeing the cart,
    // so it has to be able to take the answer as well as confirm it.
    testWidgets('a pick made at checkout is the cart\'s pick too',
        (tester) async {
      _useTallSurface(tester);
      final container = await _container();
      addTearDown(container.dispose);

      await _showCheckout(tester, container);
      expect(_placeOrderButton(tester).onPressed, isNull);

      await _pick(tester);
      expect(_placeOrderButton(tester).onPressed, isNotNull);
      expect(find.text(_payableFastest), findsWidgets);

      await _showCart(tester, container);

      expect(find.text('To pay'), findsOneWidget);
      expect(find.text(_payableFastest), findsWidgets);
      expect(find.text('₹319.79'), findsWidgets);
      expect(find.text('Subtotal'), findsNothing);
    });
  });
}

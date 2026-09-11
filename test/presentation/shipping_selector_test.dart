import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/data/models/server_cart.dart';
import 'package:trueway_farms/data/models/shipping_quote.dart';
import 'package:trueway_farms/presentation/providers/shipping_provider.dart';
import 'package:trueway_farms/presentation/widgets/shipping_selector.dart';
import 'package:trueway_farms/presentation/widgets/skeletons.dart';

/// Shipping-option slice: the five states of the selector, the rule that
/// **nothing is preselected**, and the bill line that reads the result.
///
/// Nothing here touches the network. [shippingRatesFetcherProvider] is the one
/// seam between this slice and `LogisticsRepository`, and every test replaces
/// it, so no ApiClient — and therefore no socket — is ever constructed.

// ---------------------------------------------------------------------------
// Fixtures
//
// Rows built through CourierOption.fromJson from a captured
// POST /logistics/check-serviceability response (382415 -> 110001), with the
// upstream's own types: estimated_delivery_days is the String "3" and cod is
// the int 1/0.
//
// [rate] here names the *billed* figure the fixture should produce, and the
// components are laid out to sum to it — which is what the app now quotes.
// ---------------------------------------------------------------------------

CourierOption _courier({
  required int id,
  required String name,
  required num rate,
  required String days,
  String etd = '',
  int cod = 1,
  num codCharges = 0,
  num coverageCharges = 0,
  num otherCharges = 0,
  bool codQuoted = false,
}) =>
    CourierOption.fromJson(
      {
        'courier_company_id': id,
        'courier_name': name,
        'rate': rate,
        'freight_charge':
            rate - (codQuoted ? codCharges : 0) - coverageCharges - otherCharges,
        'coverage_charges': coverageCharges,
        'other_charges': otherCharges,
        'cod_charges': codCharges,
        'cod': cod,
        'estimated_delivery_days': days,
        'etd': etd,
        'city': 'DELHI',
        'delivery_performance': 5,
      },
      cod: codQuoted,
    );

final _dtdcAir = _courier(
  id: 196,
  name: 'DTDC Air 500gm',
  rate: 224.49,
  days: '3',
  etd: 'Aug 04, 2026',
);

final _dtdcSurface = _courier(
  id: 6,
  name: 'DTDC Surface',
  rate: 173.25,
  days: '4',
  etd: 'Aug 05, 2026',
);

/// The cheapest courier in the live list — and *not* the one the web picks,
/// because it is two days slower than the fastest.
final _indiaPost = _courier(
  id: 15123,
  name: 'India Post - Speed Post_2.0',
  rate: 106.2,
  days: '5',
  etd: 'Aug 06, 2026',
);

/// Prepaid-only in the live list: `cod: 0`.
final _indiaPostPrepaid = _courier(
  id: 400,
  name: 'India Post - Speed Post Prepaid',
  rate: 108.56,
  days: '5',
  etd: 'Aug 06, 2026',
  cod: 0,
);

/// Fastest *and* cheapest among the 3-day couriers, so this is what
/// `findBestCourier()` returns for the captured list.
final _blueDartSurface = _courier(
  id: 55,
  name: 'Blue Dart Surface',
  rate: 180.6,
  days: '3',
  etd: 'Aug 04, 2026',
);

final _blueDartAir = _courier(
  id: 1,
  name: 'Blue Dart Air',
  rate: 244.65,
  days: '3',
  etd: 'Aug 04, 2026',
);

/// Deliberately in the order the server sends: Shiprocket's own recommendation
/// ranking, which is neither by price nor by speed.
List<CourierOption> get _liveList => [
      _dtdcAir,
      _dtdcSurface,
      _indiaPost,
      _indiaPostPrepaid,
      _blueDartSurface,
      _blueDartAir,
    ];

const _query = ShippingQuery(
  pinCode: '110001',
  weightKg: 5,
  lengthCm: 30,
  breadthCm: 20,
  heightCm: 15,
  declaredValue: 1887.9,
);

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// A fetcher that records its calls, so a test can prove a retry re-fetches
/// rather than replaying a cached answer.
class _RecordingFetcher {
  _RecordingFetcher(this._answer);

  final Future<ShippingRates> Function(ShippingQuery) _answer;
  final List<ShippingQuery> calls = [];

  Future<ShippingRates> call(ShippingQuery query) {
    calls.add(query);
    return _answer(query);
  }
}

Widget _host(Widget child, {required ShippingRatesFetcher fetcher}) {
  return ProviderScope(
    overrides: [shippingRatesFetcherProvider.overrideWithValue(fetcher)],
    child: MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

ShippingRatesFetcher _ready(List<CourierOption> options) =>
    (_) async => ShippingRates.fromCouriers(options);

/// The group value the radios are actually sharing.
int? _groupValue(WidgetTester tester) => RadioGroup.maybeOf<int>(
      tester.element(find.byType(Radio<int>).first),
    )?.groupValue;

void main() {
  // ------------------------------------------------------------------
  // ShippingQuery — the unit conversion that decides whether the whole
  // quote is right.
  // ------------------------------------------------------------------
  group('ShippingQuery', () {
    test('takes DIMENSIONS from the package block but WEIGHT from total_weight',
        () {
      // The two weights are deliberately different here. They used to be the
      // same 15 in this fixture, so the test passed whichever field the code
      // read — it asserted a precedence it could not actually see.
      //
      //   total_weight 15000 g = 15.0 kg  — the GOODS
      //   package_dimensions.weight 16.4  — the PACKED CARTON
      //
      // The web quotes on the goods weight (`getShippingData()` sends
      // `total_weight`); the package block exists to drive the box lookup. On
      // this store they happen to be equal because no `shipping_boxes` row is
      // configured, so only a fixture like this one can hold the precedence.
      final cart = ServerCart.fromJson({
        'id': 'abc',
        'cart_items': <dynamic>[],
        'total_weight': 15000,
        'order_total': 1887.9,
        'package_dimensions': {
          'length': 30,
          'breadth': 20,
          'height': 15,
          'weight': 16.4,
        },
      });

      final q = ShippingQuery.fromCart(cart, pinCode: '110001');

      expect(q.weightKg, 15, reason: 'goods weight, not the carton');
      // Dimensions DO come from the package block — that is what it is for.
      expect(q.lengthCm, 30);
      expect(q.breadthCm, 20);
      expect(q.heightCm, 15);
      expect(q.declaredValue, 1887.9);
      expect(q.pickupPinCode, kDefaultPickupPinCode);
    });

    test('falls back to the package weight when the cart reports no total', () {
      final cart = ServerCart.fromJson({
        'id': 'abc',
        'cart_items': <dynamic>[],
        'order_total': 1887.9,
        'package_dimensions': {
          'length': 30,
          'breadth': 20,
          'height': 15,
          'weight': 16.4,
        },
      });

      // Already kilograms on this path — no grams conversion.
      expect(ShippingQuery.fromCart(cart, pinCode: '110001').weightKg, 16.4);
    });

    // The trap: the cart reports total_weight in grams and serviceability wants
    // kilograms. Forwarding 15000 quotes a 15-tonne parcel.
    test('converts the cart total_weight from grams when no package block', () {
      final cart = ServerCart.fromJson({
        'id': 'abc',
        'cart_items': <dynamic>[],
        'total_weight': 15000,
        'total_length': 30,
        'total_wide': 20,
        'total_height': 15,
        'order_total': 1887.9,
      });

      expect(ShippingQuery.fromCart(cart, pinCode: '110001').weightKg, 15);
    });

    // Shiprocket answers a zero weight with "Weight cannot be zero." — inside an
    // HTTP 200 — so an unweighed cart must be floored, not sent as-is.
    test('floors an unmeasured cart instead of quoting zero', () {
      final cart = ServerCart.fromJson({'id': 'abc', 'cart_items': <dynamic>[]});
      final q = ShippingQuery.fromCart(cart, pinCode: '110001');

      // The web's own numbers: `max($weight, 0.5)` in getServiceabilityRates()
      // and PackageDimensionCalculator's 10 x 15 x 20 `defaults()`. The 0.1 kg
      // 10 cm cube this used to assert belongs to `check-pincode`, a different
      // endpoint, and quoted every unmeasured basket below the website.
      expect(q.weightKg, 0.5);
      expect(q.lengthCm, 10);
      expect(q.breadthCm, 15);
      expect(q.heightCm, 20);
    });

    // ----------------------------------------------------------------
    // Where the parcel ships FROM — rung 2 of the server's own
    // ShipRocketService::getPickupPostcode() chain, read off the cart instead
    // of held as a constant.
    // ----------------------------------------------------------------

    /// A cart line carrying the store block every live line carries. Captured
    /// 2026-08-04 from `POST /ecommerce/cart` and `GET /ecommerce/cart/{id}`
    /// alike:
    ///
    ///   cart_options: {…, store: {id: 10, slug: "trueway-farms-1",
    ///                             name: "Trueway Farms", zip_code: "311001"}}
    ServerCart cartWithStore(String? zip, {String? secondZip}) =>
        ServerCart.fromJson({
          'id': 'abc',
          'order_total': 1887.9,
          'total_weight': 10200,
          'cart_items': {
            'row-1': {
              'id': 118,
              'name': 'Organic Sona Moti Wheat',
              'quantity': 2,
              'price': 899,
              'cart_options': {
                'sku': 'WHEAT-5KG',
                if (zip != null)
                  'store': {
                    'id': 10,
                    'slug': 'trueway-farms-1',
                    'name': 'Trueway Farms',
                    'zip_code': zip,
                  },
              },
            },
            if (secondZip != null)
              'row-2': {
                'id': 121,
                'name': 'Organic Khand',
                'quantity': 1,
                'price': 300,
                'cart_options': {
                  'store': {'id': 11, 'zip_code': secondZip},
                },
              },
          },
        });

    test('ships from the store on the cart lines, not from the constant', () {
      final cart = cartWithStore('311001');

      expect(cart.items.single.storeZipCode, '311001');
      expect(pickupPinCodeFromCart(cart), '311001');
      expect(
        ShippingQuery.fromCart(cart, pinCode: '382415').pickupPinCode,
        '311001',
      );
    });

    // The change that makes this worth doing: the app follows a store move
    // instead of quoting from a postcode nobody remembered to edit. Probed
    // live, the same parcel to 560001 quotes ₹247.80 apart from 110001 and
    // 311001, so a stale pickup postcode is a real mis-quote, not a detail.
    test('follows the store when its postcode changes', () {
      final moved = cartWithStore('560001');

      expect(pickupPinCodeFromCart(moved), '560001');
      expect(
        ShippingQuery.fromCart(moved, pinCode: '382415').pickupPinCode,
        '560001',
        reason: 'the quote must move with the warehouse',
      );
      expect(moved.items.single.storeZipCode, isNot(kDefaultPickupPinCode));
    });

    test('falls back to the constant when no line names a store', () {
      final noStore = cartWithStore(null);

      expect(noStore.items.single.storeZipCode, isNull);
      expect(pickupPinCodeFromCart(noStore), kDefaultPickupPinCode);
      expect(kDefaultPickupPinCode, '311001');
    });

    test('falls back for an empty cart', () {
      final empty = ServerCart.fromJson({'id': 'abc', 'cart_items': <dynamic>[]});
      expect(pickupPinCodeFromCart(empty), kDefaultPickupPinCode);
      expect(
        ShippingQuery.fromCart(empty, pinCode: '382415').pickupPinCode,
        kDefaultPickupPinCode,
      );
    });

    // Shiprocket answers a malformed pickup postcode with "Invalid Pickup
    // Pincode" inside an HTTP 200, which the repository raises as a
    // business-rule error — i.e. the customer would be told their address is
    // the problem. Bad shop data must not do that.
    test('ignores a store postcode that is not a pincode', () {
      for (final junk in ['', '   ', '31100', '0311001', 'BHILWARA']) {
        expect(
          pickupPinCodeFromCart(cartWithStore(junk)),
          kDefaultPickupPinCode,
          reason: '"$junk" is not a postcode worth sending',
        );
      }
    });

    // No single lane to quote, and picking one would be a guess that looks
    // right. Unreached on a single-store catalogue; here so that adding a
    // second store degrades to a documented constant.
    test('falls back when the basket spans two stores', () {
      expect(
        pickupPinCodeFromCart(cartWithStore('311001', secondZip: '560001')),
        kDefaultPickupPinCode,
      );
      // Agreeing lines are not a conflict.
      expect(
        pickupPinCodeFromCart(cartWithStore('560001', secondZip: '560001')),
        '560001',
      );
    });

    test('an explicit pickup postcode still overrides the cart', () {
      expect(
        ShippingQuery.fromCart(
          cartWithStore('311001'),
          pinCode: '382415',
          pickupPinCode: '110001',
        ).pickupPinCode,
        '110001',
      );
    });

    test('validates the pincode the way PinCodeDeliveryService does', () {
      const base = _query;
      expect(base.copyWith(pinCode: '110001').hasValidPinCode, isTrue);
      expect(base.copyWith(pinCode: '38241').hasValidPinCode, isFalse);
      expect(base.copyWith(pinCode: '0110001').hasValidPinCode, isFalse);
      expect(base.copyWith(pinCode: '011000').hasValidPinCode, isFalse);
      expect(base.copyWith(pinCode: 'abcdef').hasValidPinCode, isFalse);
    });

    // The quote is per shipment, so two baskets to one pincode are two
    // different cache entries — and a COD quote is a third.
    test('the whole parcel is the key, not just the pincode', () {
      expect(_query == _query.copyWith(), isTrue);
      expect(_query == _query.copyWith(cod: true), isFalse);
      expect(
        _query ==
            const ShippingQuery(
              pinCode: '110001',
              weightKg: 10,
              lengthCm: 30,
              breadthCm: 20,
              heightCm: 15,
              declaredValue: 1887.9,
            ),
        isFalse,
      );
    });
  });

  // ------------------------------------------------------------------
  // The rate list. It has an order; it does not have an answer.
  // ------------------------------------------------------------------
  group('ShippingRates', () {
    test('re-sorts the list out of the server recommendation order', () {
      final rates = ShippingRates.fromCouriers(_liveList);
      expect(rates.options.first, _blueDartSurface);
      expect(rates.options.last, _indiaPost.rate < _indiaPostPrepaid.rate
          ? _indiaPostPrepaid
          : _indiaPost,);
    });

    // Sorting is presentation. The head of the list used to be handed back as
    // `rates.best` and preselected, which is how a Rs 1,284.15 air courier ended
    // up in a bill next to a Rs 324.30 surface one two days later.
    test('offers no "best" — the head of the list is not a recommendation', () {
      final rates = ShippingRates.fromCouriers(_liveList);

      expect(rates.options.first, _blueDartSurface);
      expect(
        rates.options.first,
        isNot(_indiaPost),
        reason: 'the cheapest row is not the first one, so first-is-chosen '
            'would overcharge',
      );
      // The one affordance that survives, and it only reports arity.
      expect(rates.only, isNull, reason: 'six options is not one');
      expect(ShippingRates.fromCouriers([_indiaPost]).only, _indiaPost);
    });

    // PinCodeDeliveryService treats an empty courier array as "Delivery not
    // available for this pin code".
    test('an empty courier list is a refusal, not an empty list', () {
      final rates = ShippingRates.fromCouriers(const []);
      expect(rates.deliverable, isFalse);
      expect(rates.message, isNotNull);
      expect(rates.isEmpty, isTrue);
      expect(rates.only, isNull);
    });
  });

  group('CourierEta', () {
    test('leads with the date, and falls back to the day count', () {
      expect(_blueDartSurface.etaLabel, 'Delivery by 04 Aug');
      expect(
        _courier(id: 9, name: 'X', rate: 1, days: '4').etaLabel,
        'Delivery in 4 days',
      );
      expect(
        _courier(id: 9, name: 'X', rate: 1, days: '1').etaLabel,
        'Delivery in 1 day',
      );
    });

    // A missing estimated_delivery_days coerces to 0, which must not render as
    // "same day".
    test('says nothing rather than promising a delivery it was not given', () {
      expect(_courier(id: 9, name: 'X', rate: 1, days: '').etaLabel, isNull);
    });
  });

  // ------------------------------------------------------------------
  // Widget states.
  // ------------------------------------------------------------------
  group('ShippingSelector', () {
    testWidgets('idle until an address is chosen', (tester) async {
      var called = false;
      await tester.pumpWidget(_host(
        const ShippingSelector(),
        fetcher: (q) async {
          called = true;
          return ShippingRates.unavailable();
        },
      ),);

      expect(find.textContaining('Choose a delivery address'), findsOneWidget);
      expect(called, isFalse, reason: 'no pincode, no request');
    });

    testWidgets('stays idle for a half-typed pincode', (tester) async {
      var called = false;
      await tester.pumpWidget(_host(
        ShippingSelector(query: _query.copyWith(pinCode: '1100')),
        fetcher: (q) async {
          called = true;
          return ShippingRates.unavailable();
        },
      ),);

      expect(find.textContaining('Choose a delivery address'), findsOneWidget);
      expect(
        called,
        isFalse,
        reason: 'the endpoint 400s on a short pin; do not spend the request',
      );
    });

    testWidgets('shows a skeleton, not a bare spinner, while quoting',
        (tester) async {
      final never = Completer<ShippingRates>();
      await tester.pumpWidget(_host(
        const ShippingSelector(query: _query),
        fetcher: (_) => never.future,
      ),);
      await tester.pump();

      expect(find.byType(SkeletonBox), findsWidgets);
      expect(find.text('Checking couriers…'), findsOneWidget);
      // Loading and "we don't ship there" must never look alike.
      expect(find.textContaining("We can't deliver"), findsNothing);

      never.complete(ShippingRates.unavailable());
      await tester.pumpAndSettle();
    });

    testWidgets('lists every courier with its ETA, name and price',
        (tester) async {
      await tester.pumpWidget(_host(
        const ShippingSelector(query: _query),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      expect(find.byType(Radio<int>), findsNWidgets(_liveList.length));
      expect(find.text('Blue Dart Surface'), findsOneWidget);
      expect(find.text('India Post - Speed Post_2.0'), findsOneWidget);
      expect(find.textContaining('180.60'), findsWidgets);
      expect(find.textContaining('Delivering to 110001'), findsOneWidget);
    });

    // The date is what the customer is buying; the courier's name is secondary,
    // so the estimate leads the block and each row.
    testWidgets('leads with the delivery estimate', (tester) async {
      await tester.pumpWidget(_host(
        const ShippingSelector(query: _query),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      expect(find.text('Delivery by 04 Aug'), findsWidgets);
      expect(find.text('Delivery by 06 Aug'), findsWidgets);
    });

    // This build is Razorpay-only: the checkout body hardcodes
    // `payment_method: "razorpay"`, COD is disabled server-side, and its API
    // path 500s *after* the order has been committed. So a row saying "Prepaid
    // only — no cash on delivery" was telling the customer that the couriers
    // WITHOUT that note would take cash, which no courier here will.
    testWidgets('says nothing about cash on delivery, either way',
        (tester) async {
      await tester.pumpWidget(_host(
        const ShippingSelector(query: _query),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Prepaid only'),
        findsNothing,
        reason: 'implies the other rows offer COD, and none of them do',
      );
      expect(find.textContaining('cash on delivery'), findsNothing);
      expect(find.textContaining('cash-on-delivery'), findsNothing);
      // The rows are still there and still priced — only the COD line went.
      expect(find.byType(Radio<int>), findsNWidgets(_liveList.length));
      expect(find.text('India Post - Speed Post_2.0'), findsOneWidget);
    });

    // A COD quote's surcharge belongs in the price once, from
    // `freight + coverage + other + cod`. It is never rendered as a separate
    // line and never added twice.
    testWidgets('a COD row prices the surcharge in exactly once',
        (tester) async {
      final withCod = _courier(
        id: 55,
        name: 'Blue Dart Surface',
        rate: 331.65,
        days: '3',
        etd: 'Aug 04, 2026',
        codCharges: 55.65,
        codQuoted: true,
      );
      expect(withCod.freightCharge, closeTo(276, 0.0001));
      expect(withCod.billedPrice, closeTo(331.65, 0.0001));

      await tester.pumpWidget(_host(
        const ShippingSelector(query: _query),
        fetcher: _ready([withCod]),
      ),);
      await tester.pumpAndSettle();

      expect(find.textContaining('331.65'), findsWidgets);
      expect(find.textContaining('387.30'), findsNothing);
      expect(find.textContaining('276.00'), findsNothing);
      expect(find.textContaining('cash-on-delivery'), findsNothing);
    });

    // The row a customer sees is priced at the sum the server bills, not at
    // upstream's `rate` — Rs 49.00 apart once the basket clears the insurance
    // threshold.
    testWidgets('prices a row at the billed sum, not at `rate`',
        (tester) async {
      final insured = _courier(
        id: 25,
        name: 'Xpressbees Surface 5kg',
        rate: 321.06, // 272.06 freight + 49.00 coverage
        days: '5',
        etd: 'Aug 09, 2026',
        coverageCharges: 49,
      );
      expect(insured.freightCharge, closeTo(272.06, 0.0001));
      expect(insured.billedPrice, closeTo(321.06, 0.0001));

      await tester.pumpWidget(_host(
        const ShippingSelector(query: _query),
        fetcher: _ready([insured]),
      ),);
      await tester.pumpAndSettle();

      expect(find.textContaining('321.06'), findsWidgets);
      expect(
        find.textContaining('272.06'),
        findsNothing,
        reason: 'that is `rate`, and the order would be billed Rs 49 more',
      );
    });

    // The product decision this round implements: the app does not answer for
    // the customer. Previously this test asserted the opposite.
    testWidgets('preselects nothing — the radio group starts empty',
        (tester) async {
      final chosen = <CourierOption?>[];
      await tester.pumpWidget(_host(
        ShippingSelector(query: _query, onChanged: chosen.add),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      expect(find.byType(Radio<int>), findsNWidgets(_liveList.length));
      expect(_groupValue(tester), isNull);
      expect(
        chosen.where((c) => c != null),
        isEmpty,
        reason: 'nothing may be reported as chosen before a tap',
      );
    });

    // The panel asks, in the words the cart's prompt and checkout's blocker
    // both use — so "Choose a delivery option to continue" points at a caption
    // that is on screen rather than describing one.
    testWidgets('asks the question while nothing is chosen, then stops',
        (tester) async {
      await tester.pumpWidget(_host(
        const ShippingSelector(query: _query),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('checkout-choose-delivery')),
        findsOneWidget,
      );
      expect(find.text('Choose a delivery option'), findsOneWidget);

      await tester.tap(find.text('Blue Dart Surface'));
      await tester.pumpAndSettle();

      // Answered: the prompt gives way to the thing being bought.
      expect(find.byKey(const Key('checkout-choose-delivery')), findsNothing);
      expect(find.text('Choose a delivery option'), findsNothing);
      expect(find.text('Delivery by 04 Aug'), findsWidgets);
    });

    testWidgets('a tap makes the first selection and reports it',
        (tester) async {
      final chosen = <CourierOption?>[];
      await tester.pumpWidget(_host(
        ShippingSelector(query: _query, onChanged: chosen.add),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      expect(_groupValue(tester), isNull);

      await tester.tap(find.text('India Post - Speed Post_2.0'));
      await tester.pumpAndSettle();

      expect(chosen.last, _indiaPost);
      expect(_groupValue(tester), _indiaPost.courierCompanyId);
    });

    // Even a one-option list has to be tapped: the tap is the customer
    // accepting a delivery charge.
    testWidgets('does not preselect even when there is only one courier',
        (tester) async {
      await tester.pumpWidget(_host(
        const ShippingSelector(query: _query),
        fetcher: _ready([_blueDartSurface]),
      ),);
      await tester.pumpAndSettle();

      expect(find.byType(Radio<int>), findsOneWidget);
      expect(_groupValue(tester), isNull);
    });

    // ----------------------------------------------------------------
    // The state this feature exists for.
    // ----------------------------------------------------------------
    testWidgets('refuses an unserviceable pincode in as many words',
        (tester) async {
      await tester.pumpWidget(_host(
        ShippingSelector(query: _query.copyWith(pinCode: '999999')),
        fetcher: (_) async => ShippingRates.unavailable(
          'No courier service available between 382415 and 999999',
        ),
      ),);
      await tester.pumpAndSettle();

      expect(find.text("We can't deliver to 999999"), findsOneWidget);
      expect(
        find.textContaining('No courier service available'),
        findsOneWidget,
        reason: "the server's own explanation is shown verbatim",
      );
      expect(
        find.textContaining('cannot be placed'),
        findsOneWidget,
        reason: 'the customer must know the order cannot proceed',
      );
      expect(find.byType(Radio<int>), findsNothing);
      expect(find.byType(SkeletonBox), findsNothing);
    });

    testWidgets('an empty courier list refuses too', (tester) async {
      await tester.pumpWidget(_host(
        const ShippingSelector(query: _query),
        fetcher: (_) async => ShippingRates.fromCouriers(const []),
      ),);
      await tester.pumpAndSettle();

      expect(find.textContaining("We can't deliver"), findsOneWidget);
      expect(find.byType(Radio<int>), findsNothing);
    });

    test('no charge is quoted for an unserviceable pincode', () async {
      final container = ProviderContainer(
        overrides: [
          shippingRatesFetcherProvider.overrideWithValue(
            (_) async => ShippingRates.unavailable('nope'),
          ),
        ],
      );
      addTearDown(container.dispose);

      final sub = container.listen(shippingChargeProvider(_query), (_, __) {});
      addTearDown(sub.close);

      await container.read(courierOptionsProvider(_query).future);

      expect(container.read(shippingChargeProvider(_query)), isNull);
      expect(container.read(selectedShippingProvider(_query)), isNull);
      expect(container.read(shippingMethodProvider(_query)), isNull);
    });

    // The three money providers are null until a tap lands, and null here means
    // "no delivery option chosen" — never 0, never a guess. A cart that reads a
    // 0 prints "FREE" for a shipment nobody has paid for.
    test('quotes nothing at all until the customer picks', () async {
      final container = ProviderContainer(
        overrides: [
          shippingRatesFetcherProvider.overrideWithValue(_ready(_liveList)),
        ],
      );
      addTearDown(container.dispose);

      final sub = container.listen(shippingChargeProvider(_query), (_, __) {});
      addTearDown(sub.close);

      await container.read(courierOptionsProvider(_query).future);

      // The list has arrived and is deliverable...
      expect(container.read(courierOptionsProvider(_query)).value!.options,
          hasLength(6),);
      // ...and still nothing is quoted.
      expect(container.read(selectedShippingProvider(_query)), isNull);
      expect(container.read(shippingChargeProvider(_query)), isNull);
      expect(container.read(shippingMethodProvider(_query)), isNull);
      expect(container.read(shippingOptionKeyProvider(_query)), isNull);
    });

    test('the charge and method are the chosen courier, untouched', () async {
      final container = ProviderContainer(
        overrides: [
          shippingRatesFetcherProvider.overrideWithValue(_ready(_liveList)),
        ],
      );
      addTearDown(container.dispose);

      final sub = container.listen(shippingChargeProvider(_query), (_, __) {});
      addTearDown(sub.close);

      await container.read(courierOptionsProvider(_query).future);
      container
          .read(shippingChoiceProvider.notifier)
          .select(_query, _blueDartSurface);

      expect(container.read(shippingChargeProvider(_query)), 180.6);
      expect(container.read(shippingMethodProvider(_query)), 'Blue Dart Surface');
    });

    // The charge provider hands back the server's sum, so a coverage-charged
    // basket quotes Rs 49.00 above what `rate` would have said.
    test('the charge is the billed sum, not `rate`', () async {
      final insured = _courier(
        id: 25,
        name: 'Xpressbees Surface 5kg',
        rate: 321.06,
        days: '5',
        coverageCharges: 49,
      );
      final container = ProviderContainer(
        overrides: [
          shippingRatesFetcherProvider.overrideWithValue(_ready([insured])),
        ],
      );
      addTearDown(container.dispose);

      final sub = container.listen(shippingChargeProvider(_query), (_, __) {});
      addTearDown(sub.close);

      await container.read(courierOptionsProvider(_query).future);
      container.read(shippingChoiceProvider.notifier).select(_query, insured);

      expect(container.read(shippingChargeProvider(_query)), closeTo(321.06, 1e-9));
      expect(insured.freightCharge, closeTo(272.06, 1e-9));
    });

    // ----------------------------------------------------------------
    // Failure — distinct from a refusal, and retryable.
    // ----------------------------------------------------------------
    testWidgets('a failed quote offers a retry that re-fetches',
        (tester) async {
      var fail = true;
      final fetcher = _RecordingFetcher((_) async {
        if (fail) {
          throw const ApiException(
            'Service temporarily unavailable',
            kind: ApiErrorKind.server,
            statusCode: 500,
          );
        }
        return ShippingRates.fromCouriers(_liveList);
      });

      await tester.pumpWidget(_host(
        const ShippingSelector(query: _query),
        fetcher: fetcher.call,
      ),);
      await tester.pumpAndSettle();

      expect(
        find.textContaining("Couldn't fetch shipping charges"),
        findsOneWidget,
      );
      expect(find.textContaining('Service temporarily unavailable'),
          findsOneWidget,);
      expect(fetcher.calls, hasLength(1));

      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(fetcher.calls, hasLength(2));
      expect(find.text('Blue Dart Surface'), findsOneWidget);
    });
  });

  // ------------------------------------------------------------------
  // The bill line — what replaces checkout's hardcoded "FREE".
  // ------------------------------------------------------------------
  group('ShippingBillLine', () {
    testWidgets('shows the chosen courier and its charge', (tester) async {
      await tester.pumpWidget(_host(
        const Column(
          children: [
            ShippingSelector(query: _query),
            ShippingBillLine(query: _query),
          ],
        ),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      ProviderScope.containerOf(tester.element(find.byType(ShippingBillLine)))
          .read(shippingChoiceProvider.notifier)
          .select(_query, _blueDartSurface);
      await tester.pumpAndSettle();

      // "Shipping" is the charge; "Delivery" is the date.
      expect(find.text('Shipping'), findsOneWidget);
      expect(
        find.text('Blue Dart Surface'),
        findsNWidgets(2),
        reason: 'the bill and the selector must name the same courier',
      );
      expect(find.textContaining('180.60'), findsWidgets);
    });

    // The state that now lasts until the customer acts, so it is the one that
    // must never look like free shipping.
    testWidgets('prints a dash, not a zero, while nothing is chosen',
        (tester) async {
      await tester.pumpWidget(_host(
        const Column(
          children: [
            ShippingSelector(query: _query),
            ShippingBillLine(query: _query),
          ],
        ),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      expect(find.text('—'), findsOneWidget);
      expect(find.textContaining('0.00'), findsNothing);
      expect(find.textContaining('FREE'), findsNothing);
    });

    // A zero here would read as free shipping for an order nobody has quoted.
    testWidgets('admits when there is no quote instead of printing zero',
        (tester) async {
      await tester.pumpWidget(_host(
        const ShippingBillLine(),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      expect(find.text('—'), findsOneWidget);
      expect(find.textContaining('0.00'), findsNothing);
      expect(find.textContaining('FREE'), findsNothing);
    });
  });

  // ------------------------------------------------------------------
  // ShippingSection — checkout's block: confirm, don't re-ask.
  // ------------------------------------------------------------------
  group('ShippingSection', () {
    /// The smallest phone the app supports, at the largest OS text scale — the
    /// two accessibility settings that break a Row laid out for a comfortable
    /// screen. The confirmation carries a courier name, a destination and a
    /// price on the same row, so it is exactly the shape that overflows.
    Future<void> pumpSection(
      WidgetTester tester, {
      double width = 320,
      double textScale = 1.6,
    }) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              // Checkout's own horizontal padding, so the card gets the width
              // it really has.
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: ShippingSection(query: _query),
              ),
            ),
          ),
          fetcher: _ready(_liveList),
        ),
      );
      await tester.pumpAndSettle();
    }

    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(ShippingSection)));

    testWidgets('asks when nothing has been chosen for this query',
        (tester) async {
      await pumpSection(tester);

      // No standing choice: the full list, never a summary of nothing.
      expect(find.byKey(const Key('checkout-shipping-summary')), findsNothing);
      expect(find.byType(Radio<int>), findsNWidgets(6));
      expect(tester.takeException(), isNull);
    });

    testWidgets('confirms the cart\'s courier without re-offering the list',
        (tester) async {
      await pumpSection(tester);
      containerOf(tester)
          .read(shippingChoiceProvider.notifier)
          .select(_query, _indiaPost);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('checkout-shipping-summary')),
        findsOneWidget,
      );
      expect(find.byType(Radio<int>), findsNothing);
      expect(find.text('India Post - Speed Post_2.0'), findsOneWidget);
      expect(find.text('₹106.20'), findsOneWidget);
      expect(find.text('Delivery by 06 Aug'), findsOneWidget);
      // The date is a delivery; everything naming the charge is shipping.
      expect(find.text('Shipping'), findsOneWidget);
      expect(find.textContaining('Shipping by'), findsNothing);
      // 320dp at 1.6x is where a Row that should have been a Column reports a
      // RenderFlex overflow.
      expect(tester.takeException(), isNull);
    });

    testWidgets('re-asks when the pin was made for another destination',
        (tester) async {
      await pumpSection(tester);
      // Chosen for 110001; this section is quoting 560001.
      containerOf(tester)
          .read(shippingChoiceProvider.notifier)
          .select(_query.copyWith(pinCode: '560001'), _indiaPost);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('checkout-shipping-summary')), findsNothing);
      expect(find.byType(Radio<int>), findsNWidgets(6));
    });

    testWidgets('re-asks when the pinned courier has dropped out of the list',
        (tester) async {
      await pumpSection(tester);
      // A courier id that is not in `_liveList` at all — the rate it named
      // cannot be honoured, so confirming it would print a price nobody quoted.
      containerOf(tester).read(shippingChoiceProvider.notifier).select(
            _query,
            _courier(id: 99999, name: 'Gone Courier', rate: 1, days: '2'),
          );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('checkout-shipping-summary')), findsNothing);
      expect(find.text('Gone Courier'), findsNothing);
      expect(find.byType(Radio<int>), findsNWidgets(6));
    });

    testWidgets('refuses an undeliverable pincode rather than confirming',
        (tester) async {
      tester.view.physicalSize = const Size(400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _host(
          const ShippingSection(query: _query),
          fetcher: (_) async => ShippingRates.unavailable(
            'No courier service available between 311001 and 110001',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text("We can't deliver to 110001"), findsOneWidget);
      expect(find.byKey(const Key('checkout-shipping-summary')), findsNothing);
    });

    testWidgets('says what is missing before there is a query', (tester) async {
      await tester.pumpWidget(
        _host(const ShippingSection(), fetcher: _ready(_liveList)),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Choose a delivery address to see courier options and charges.',
        ),
        findsOneWidget,
      );
    });
  });

  group('ShippingChoiceSummary', () {
    testWidgets('recaps the estimate, courier and charge on one line',
        (tester) async {
      await tester.pumpWidget(_host(
        const Column(
          children: [
            ShippingSelector(query: _query),
            ShippingChoiceSummary(query: _query),
          ],
        ),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      ProviderScope.containerOf(
        tester.element(find.byType(ShippingChoiceSummary)),
      ).read(shippingChoiceProvider.notifier).select(_query, _blueDartSurface);
      await tester.pumpAndSettle();

      expect(
        find.text('Delivery by 04 Aug · Blue Dart Surface'),
        findsOneWidget,
      );
    });

    testWidgets('says so while the list is up but nothing is picked',
        (tester) async {
      await tester.pumpWidget(_host(
        const Column(
          children: [
            ShippingSelector(query: _query),
            ShippingChoiceSummary(query: _query),
          ],
        ),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      expect(find.text('No shipping option selected'), findsOneWidget);
    });

    testWidgets('says so when nothing is chosen', (tester) async {
      await tester.pumpWidget(_host(
        const ShippingChoiceSummary(),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      // "Shipping" for the method, "Delivery" for the date — the same rule the
      // panel title and the bill row follow. (The *prompt* is the one
      // deliberate exception: "Choose a delivery option" is a caption the cart
      // and the selector both render, and the blocker quotes it verbatim so it
      // names something on screen. This line is a recap, not a control.)
      expect(find.text('No shipping option selected'), findsOneWidget);
      expect(find.text('No delivery option selected'), findsNothing);
    });
  });

  // A stale courier must not survive an address change: the rate was quoted for
  // that parcel to that pincode.
  group('shippingChoiceProvider', () {
    test('a manual pick does not leak to another pincode', () async {
      final container = ProviderContainer(
        overrides: [
          shippingRatesFetcherProvider.overrideWithValue(_ready(_liveList)),
        ],
      );
      addTearDown(container.dispose);

      final other = _query.copyWith(pinCode: '382415');
      // Keep both alive so autoDispose does not drop them between reads.
      final subs = [
        container.listen(selectedShippingProvider(_query), (_, __) {}),
        container.listen(selectedShippingProvider(other), (_, __) {}),
      ];
      addTearDown(() {
        for (final s in subs) {
          s.close();
        }
      });

      await container.read(courierOptionsProvider(_query).future);
      await container.read(courierOptionsProvider(other).future);

      container.read(shippingChoiceProvider.notifier).select(_query, _indiaPost);

      expect(container.read(selectedShippingProvider(_query)), _indiaPost);
      expect(
        container.read(selectedShippingProvider(other)),
        isNull,
        reason: 'the other pincode has not been answered, and there is no '
            'default to fall back to any more',
      );
      expect(container.read(shippingChargeProvider(other)), isNull);
    });

    // A courier that has dropped out of the live list is not a selection: the
    // price it named cannot be honoured, so the question reopens rather than a
    // substitute being quoted.
    test('a pin that no longer resolves quotes nothing', () async {
      final container = ProviderContainer(
        overrides: [
          shippingRatesFetcherProvider.overrideWithValue(_ready(_liveList)),
        ],
      );
      addTearDown(container.dispose);

      final sub = container.listen(selectedShippingProvider(_query), (_, __) {});
      addTearDown(sub.close);

      await container.read(courierOptionsProvider(_query).future);
      container.read(shippingChoiceProvider.notifier).select(
            _query,
            _courier(id: 99999, name: 'Gone Courier', rate: 1, days: '2'),
          );

      expect(container.read(selectedShippingProvider(_query)), isNull);
      expect(container.read(shippingChargeProvider(_query)), isNull);
    });
  });
}

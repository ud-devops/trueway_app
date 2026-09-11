import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/data/models/server_cart.dart';
import 'package:trueway_farms/data/repositories/cart_repository.dart';
import 'package:trueway_farms/data/repositories/logistics_repository.dart';
import 'package:trueway_farms/presentation/providers/checkout_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/server_cart_provider.dart';
import 'package:trueway_farms/presentation/providers/shipping_provider.dart';

/// Parity of the **request**, not the answer.
///
/// `POST /logistics/check-serviceability` is a pass-through:
/// `DeliveryController::checkServiceability` casts the nine fields and forwards
/// them to Shiprocket untouched. Nothing on the server reconciles the app with
/// the website — so if the app and the web build different parameters, the same
/// basket to the same pincode is quoted two different prices, which is exactly
/// what the customer reported.
///
/// Every expectation below is pinned to a line of
/// `ShipRocketService::getServiceabilityRates()`:
///
/// ```php
/// 'pickup_postcode'   => getPickupPostcode()      // origin -> store -> setting
/// 'delivery_postcode' => address_to.zip_code
/// 'weight'            => max($grams / 1000, 0.5)
/// 'cod'               => isCodOrder() ? 1 : 0
/// 'qc_check'          => 0
/// 'declared_value'    => (int) order_total
/// 'length'/'breadth'/'height' => PackageDimensionCalculator::calculate($items)
/// ```
///
/// **What changed.** The last of those used to be a hand-port of
/// `PackageDimensionCalculator` into Dart, fed by one product-detail fetch per
/// cart line, and this file tested the port's arithmetic rule by rule. It is
/// gone: the server runs the real calculator — including the admin-managed
/// `shipping_boxes` table the port could never consult — and returns the answer
/// as `package_dimensions` on the cart itself. So these tests now assert the app
/// *forwards* the server's box faithfully rather than that it re-derives the
/// same one, which is the only claim still worth defending.
///
/// No network: [cartRepositoryProvider] is the single seam onto the cart and is
/// overridden in every test, so no `ApiClient` — and therefore no socket — is
/// ever constructed.

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// A cart in the shape `GET /ecommerce/cart/{id}` returns.
///
/// The defaults are a live response: two of SKU 118 (19 × 6 × 24 cm, 5100 g
/// each). The server's calculator turned that into
/// `{length: 20, breadth: 7, height: 49, weight: 10.2}` — sides take the max
/// plus a 1 cm buffer, height stacks — which is the figure the *website* quotes
/// on. The app's job is to send those four numbers on, unchanged.
Map<String, dynamic> cartJson({
  Object? packageDimensions = const {
    'length': 20,
    'breadth': 7,
    'height': 49,
    'weight': 10.2,
    'box_id': null,
    'box_name': null,
  },
  double totalWeight = 10200,
  double orderTotal = 1887.9,
  List<Map<String, dynamic>>? items,
}) =>
    {
      'id': 'cart-1',
      'count': 2,
      'total_weight': totalWeight,
      if (packageDimensions != null) 'package_dimensions': packageDimensions,
      'cart_items': items ??
          [
            {
              'id': 118,
              'row_id': 'abc',
              'name': 'Trueway Farms Organic Desi Khand',
              'quantity': 2,
              'price': 899,
              'weight': 5100,
              'length': 19,
              'wide': 6,
              'height': 24,
            },
          ],
      'raw_sub_total': 1798,
      'promotion_discount_amount': 0,
      'coupon_discount_amount': 0,
      'discounted_sub_total': 1798,
      'discounted_tax_amount': 89.9,
      'order_total': orderTotal,
    };

/// One line the catalogue records no shipping weight for.
Map<String, dynamic> get _unweighedLine => {
      'id': 900,
      'row_id': 'unweighed',
      'name': 'Unmeasured',
      'quantity': 1,
      'price': 100,
    };

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Serves one canned cart. `implements` + [noSuchMethod] so the mutation routes
/// this slice does not touch cannot be called by accident — they throw rather
/// than quietly returning null.
class _FakeCartRepo implements CartRepository {
  _FakeCartRepo(this.cart);

  final ServerCart cart;
  int fetches = 0;

  @override
  Future<ServerCart> fetch(String cartId) async {
    fetches++;
    return cart;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A container whose cart is [json], already read from the server.
Future<ProviderContainer> _host(Map<String, dynamic> json) async {
  // The id is the one thing the notifier persists; without it, it never reads.
  SharedPreferences.setMockInitialValues({'server_cart_id_v1': 'cart-1'});
  final prefs = await SharedPreferences.getInstance();

  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      cartRepositoryProvider
          .overrideWithValue(_FakeCartRepo(ServerCart.fromJson(json))),
    ],
  );
  addTearDown(container.dispose);

  // The notifier fetches from its constructor; the parcel stays pending until
  // that lands, so simply reading it is enough to start the load.
  container.read(serverCartProvider);

  // The parcel provider is autoDispose, and a bare `read` subscribes and lets
  // go in the same turn — which disposes it mid-load and fails the future. A
  // real screen holds a `watch` for as long as it is mounted; this is that.
  container.listen(checkoutParcelProvider, (_, __) {}, fireImmediately: true);
  return container;
}

Future<CheckoutParcel> _parcelFor(Map<String, dynamic> json) async {
  final container = await _host(json);
  return container.read(checkoutParcelProvider.future);
}

void main() {
  // -------------------------------------------------------------------------
  group('package dimensions', () {
    // The headline case. This basket, through the LIVE cart API, comes back as
    //   package_dimensions: {length: 20, breadth: 7, height: 49, weight: 10.2}
    // and those exact numbers must reach the courier.
    test('are forwarded from the cart, not recomputed', () async {
      final parcel = await _parcelFor(cartJson());

      expect(parcel.lengthCm, 20);
      expect(parcel.breadthCm, 7);
      expect(parcel.heightCm, 49);
    });

    // `PinCodeDeliveryService`'s 10 cm cube is a different service's fallback.
    // The app used to send it for EVERY basket. Probed live 2026-08-03 to
    // 560001 on a 0.5 kg parcel: 10x10x10 quoted Blue Dart Air ₹129.15 and
    // Delhivery Surface ₹73.36, where the web's 20x7x49 quoted ₹360.15 and
    // ₹205.36 — and dropped India Post from the list entirely. The app was not
    // just cheaper than the website, it offered couriers the website did not.
    test('never send the 10x10x10 cube', () async {
      final parcel = await _parcelFor(cartJson());
      expect(
        [parcel.lengthCm, parcel.breadthCm, parcel.heightCm],
        isNot([10, 10, 10]),
      );
    });

    // The logistics plugin can be off, or its calculator can throw — the
    // controller swallows that and omits the block. 10x15x20, the calculator's
    // own `defaults()`, is the honest stand-in; a cube is not.
    test('fall back to the calculator defaults when the block is absent',
        () async {
      final parcel = await _parcelFor(cartJson(packageDimensions: null));

      expect(parcel.lengthCm, kDefaultParcelLengthCm);
      expect(parcel.breadthCm, kDefaultParcelBreadthCm);
      expect(parcel.heightCm, kDefaultParcelHeightCm);
    });

    test('an empty cart still asks for a shippable box', () async {
      final parcel = await _parcelFor(cartJson(items: const [], totalWeight: 0));

      expect(parcel.lengthCm, kDefaultParcelLengthCm);
      expect(parcel.breadthCm, kDefaultParcelBreadthCm);
      expect(parcel.heightCm, kDefaultParcelHeightCm);
      expect(parcel.weightKg, LogisticsRepository.minServiceabilityWeightKg);
      expect(parcel.declaredValue, 0);
    });

    // The bail-out replaces the BOX, never the weight.
    //
    // `getServiceabilityRates()` takes `weight` from `$data['weight']` (the
    // cart's own gram total) and only `length`/`breadth`/`height` from the
    // calculator; `$packageDims['weight']` is never read for the rate. So an
    // unmeasured-but-heavy basket ships in the default box at its real weight.
    //
    // The app used to send 0.5 kg here. Probed live 2026-08-03, 10.2 kg to
    // 560001 in the 10x15x20 default box: 0.5 kg quoted Delhivery Surface
    // ₹139.36 / Blue Dart Air ₹244.65 across five couriers, while 10.2 kg
    // quoted India Post ₹1040.76 / ₹1038.40 and nothing else — ~₹900 under, on
    // a courier list the website does not offer.
    test('a boxless basket keeps its real weight, only the box defaults',
        () async {
      final parcel = await _parcelFor(
        cartJson(packageDimensions: null, totalWeight: 100000),
      );

      expect(parcel.weightKg, 100, reason: '100000 g, converted once');
      expect(parcel.weightKg, isNot(0.5), reason: 'the old under-quote');
      expect(parcel.lengthCm, kDefaultParcelLengthCm);
      expect(parcel.breadthCm, kDefaultParcelBreadthCm);
      expect(parcel.heightCm, kDefaultParcelHeightCm);
    });
  });

  // -------------------------------------------------------------------------
  group('weight', () {
    // `total_weight` is grams, `package_dimensions.weight` is kilograms. The
    // rate is quoted on the former; reading the latter and converting again
    // would quote a 10.2 kg order as 10 200 kg.
    test('comes from total_weight, converted exactly once', () async {
      final parcel = await _parcelFor(cartJson());

      expect(parcel.weightKg, 10.2);
      expect(parcel.weightKg, isNot(10200));
      expect(parcel.weightKg, isNot(0.0102));
    });

    // The bug: the app floored at 0.1 kg, copied from
    // DeliveryController::checkPinCode, which is a DIFFERENT endpoint. The web
    // floors serviceability at 0.5. Live to 560001, 10x10x10: India Post
    // ₹73.16 at 0.1 kg vs ₹96.76 at 0.5 kg — every light basket under-quoted.
    test('floors at the web 0.5 kg, not check-pincode 0.1 kg', () async {
      final parcel = await _parcelFor(cartJson(totalWeight: 40));

      expect(parcel.weightKg, LogisticsRepository.minServiceabilityWeightKg);
      expect(parcel.weightKg, 0.5);
      expect(parcel.weightKg, isNot(LogisticsRepository.minPinCodeWeightKg));
    });

    test('a weightless catalogue still yields a shippable parcel', () async {
      final parcel = await _parcelFor(cartJson(totalWeight: 0));
      expect(parcel.weightKg, LogisticsRepository.minServiceabilityWeightKg);
    });
  });

  // -------------------------------------------------------------------------
  group('unweighed lines', () {
    // A line the catalogue records no weight for contributes nothing to the
    // total, so a quote that includes it is a *floor*. Checkout says so rather
    // than presenting it as final.
    test('are counted, so checkout can call the quote a floor', () async {
      final parcel = await _parcelFor(cartJson(items: [
        {
          'id': 118,
          'row_id': 'abc',
          'name': 'Desi Khand',
          'quantity': 1,
          'price': 899,
          'weight': 5100,
        },
        _unweighedLine,
      ],),);

      expect(parcel.unweighedLines, 1);
      expect(parcel.isWeightKnown, isFalse);
      // …and the quote is still built from what IS known.
      expect(parcel.weightKg, 10.2);
      expect(parcel.lengthCm, 20);
    });

    test('a fully weighed basket is final', () async {
      final parcel = await _parcelFor(cartJson());

      expect(parcel.unweighedLines, 0);
      expect(parcel.isWeightKnown, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('pickup_postcode', () {
    /// A cart line with the store block a live line carries.
    List<Map<String, dynamic>> linesWithStore(String? zip) => [
          {
            'id': 118,
            'row_id': 'abc',
            'name': 'Trueway Farms Organic Desi Khand',
            'quantity': 2,
            'price': 899,
            'weight': 5100,
            'cart_options': {
              if (zip != null)
                'store': {
                  'id': 10,
                  'slug': 'trueway-farms-1',
                  'name': 'Trueway Farms',
                  'zip_code': zip,
                },
            },
          },
        ];

    // Rung 2 of getPickupPostcode() — the marketplace store on the basket's own
    // lines — read from `cart_items[*].cart_options.store.zip_code` rather than
    // held as a constant. Verified live 2026-08-04: every line of a real cart
    // carries `{id: 10, slug: "trueway-farms-1", zip_code: "311001"}`.
    //
    // What must not come back is the old value: the app hardcoded 110001, from
    // `setting('logistics_pickup_postcode', '110001')`, a setting the web
    // checkout never reads. Live to 560001 with the 10.2 kg parcel that was
    // worth ₹247.80 an order — 110001 quoted India Post ₹1288.56 where 311001
    // quotes ₹1040.76.
    test('is read from the store on the cart lines', () async {
      final parcel =
          await _parcelFor(cartJson(items: linesWithStore('311001')));

      expect(parcel.pickupPinCode, '311001');
      expect(parcel.toQuery('560001').pickupPinCode, '311001');
    });

    // The point of reading it: the app follows a store move rather than
    // quoting from a constant nobody remembered to edit.
    test('follows the store rather than the constant', () async {
      final parcel =
          await _parcelFor(cartJson(items: linesWithStore('560001')));

      expect(parcel.pickupPinCode, '560001');
      expect(parcel.pickupPinCode, isNot(kDefaultPickupPinCode));
    });

    test('falls back to the constant when the lines name no store', () async {
      // The default `cartJson()` line has no `cart_options` at all, which is
      // also the raw `content` line shape.
      final parcel = await _parcelFor(cartJson());

      expect(parcel.pickupPinCode, kDefaultPickupPinCode);
      expect(parcel.pickupPinCode, '311001');
      expect(
        await _parcelFor(cartJson(items: linesWithStore(null)))
            .then((p) => p.pickupPinCode),
        kDefaultPickupPinCode,
      );
    });
  });

  // -------------------------------------------------------------------------
  group('declared_value', () {
    // Now `order_total` rather than the app's own subtotal-minus-coupon. The
    // two differed because the app treated prices as GST-inclusive while the
    // server adds tax on top: 1798 where the server says 1887.90.
    test('is the server order total, not the app subtotal', () async {
      final parcel = await _parcelFor(cartJson());

      expect(parcel.declaredValue, 1887.9);
      expect(parcel.declaredValue, isNot(1798));
    });

    // `(int)` in PHP truncates. Sending a rounded int from here would put 810
    // on the wire where the web puts 809, so the raw figure travels and the
    // server's own cast is the only one.
    test('travels unrounded so the server cast truncates as PHP does',
        () async {
      final parcel = await _parcelFor(cartJson(orderTotal: 809.1));

      expect(parcel.declaredValue, closeTo(809.1, 0.0001));
      expect(parcel.declaredValue, isNot(809));
      expect(parcel.declaredValue.truncate(), 809);
    });
  });

  // -------------------------------------------------------------------------
  group('cod', () {
    // Not cosmetic: cod: 1 drops prepaid-only couriers and folds cod_charges
    // into each survivor's rate. Live to 560001 at 10.2 kg: prepaid offered
    // two India Post rows at ₹1040.76 / ₹1038.40, COD offered one at ₹1072.38.
    test('is part of the query, so switching payment re-quotes', () async {
      final parcel = await _parcelFor(cartJson());

      final prepaid = parcel.toQuery('560001');
      final cod = parcel.toQuery('560001', cod: true);

      expect(prepaid.cod, isFalse);
      expect(cod.cod, isTrue);
      // Different cache keys, or the second quote would serve the first's list.
      expect(prepaid == cod, isFalse);
      expect(prepaid.hashCode == cod.hashCode, isFalse);
    });

    test('everything else about the parcel is unchanged by cod', () async {
      final parcel = await _parcelFor(cartJson());
      final prepaid = parcel.toQuery('560001');
      final cod = parcel.toQuery('560001', cod: true);

      expect(cod.weightKg, prepaid.weightKg);
      expect(cod.lengthCm, prepaid.lengthCm);
      expect(cod.breadthCm, prepaid.breadthCm);
      expect(cod.heightCm, prepaid.heightCm);
      expect(cod.declaredValue, prepaid.declaredValue);
      expect(cod.pickupPinCode, prepaid.pickupPinCode);
    });
  });

  // -------------------------------------------------------------------------
  group('the whole request, end to end', () {
    // One test that reads like the PHP does, so a future edit to any single
    // field is caught against the web's own list rather than against itself.
    test('every parameter matches getServiceabilityRates()', () async {
      final parcel = await _parcelFor(cartJson());
      final q = parcel.toQuery('560001');

      expect(q.pickupPinCode, '311001'); // getPickupPostcode()
      expect(q.pinCode, '560001'); // address_to.zip_code
      expect(q.weightKg, 10.2); // max(10200 / 1000, 0.5)
      expect(q.cod, isFalse); // isCodOrder() ? 1 : 0
      expect(q.declaredValue, 1887.9); // (int) order_total
      expect(q.lengthCm, 20); // package_dimensions, server-computed
      expect(q.breadthCm, 7);
      expect(q.heightCm, 49);
      expect(q.hasValidPinCode, isTrue);
    });

    // The parcel is not knowable before the first cart read lands — holding the
    // provider in `loading` is what stops checkout asking the courier to price
    // an empty box while the real cart is still in flight.
    test('is pending until the cart has actually been read', () async {
      SharedPreferences.setMockInitialValues({'server_cart_id_v1': 'cart-1'});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          cartRepositoryProvider.overrideWithValue(
            _FakeCartRepo(ServerCart.fromJson(cartJson())),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(checkoutParcelProvider, (_, __) {}, fireImmediately: true);

      expect(container.read(checkoutParcelProvider).isLoading, isTrue);

      final parcel = await container.read(checkoutParcelProvider.future);
      expect(parcel.weightKg, 10.2);
    });
  });
}

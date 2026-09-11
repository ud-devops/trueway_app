import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/models/shipping_quote.dart';
import 'package:trueway_farms/data/repositories/logistics_repository.dart';

// ---------------------------------------------------------------------------
// Fixtures — captured live 2026-08-01, trimmed to the fields we parse plus the
// decoys that matter (`cost: ""`, `freight_charge`). Nothing here is invented.
// ---------------------------------------------------------------------------

/// `POST /logistics/check-pincode {"pin_code":"110001","product_id":118}` -> 200
const String _pincode200 =
    '{"status":"success","message":"Delivery available","deliverable":true,'
    '"pin_code":"110001","estimated_delivery_days":"2",'
    '"estimated_delivery_date":"03-08-2026","shipping_charge":321.51,'
    '"courier_name":"DTDC Surface 10kg","cod_available":1,"success":true}';

/// Same route, pin 123456 -> **422**. An ordinary answer delivered as an error
/// status, which is the whole reason `checkPincode` catches.
const String _pincode422 =
    '{"status":"error","message":"Unable to check delivery availability",'
    '"deliverable":false,"pin_code":"123456","success":false}';

/// `POST /logistics/check-serviceability` prepaid, 110001 -> 560001.
///
/// Server order is 276, 190.11, 212.8, 218.36, 266.65, 319.79, 344.25 with days
/// 5, 5, 5, 6, 6, 3, 3 — neither cheapest-first nor fastest-first.
const String _serviceabilityPrepaid =
    '{"success":true,"status":"success","message":"Serviceability check completed","data":{"currency":"INR","data":{"available_courier_companies":[{"courier_company_id":55,"courier_name":"Blue Dart Surface","rate":276,"cost":"","freight_charge":276,"cod":1,"cod_charges":0,"estimated_delivery_days":"5","etd":"Aug 06, 2026","city":"Bangalore","delivery_performance":4.1,"rating":4.8},{"courier_company_id":82,"courier_name":"DTDC Surface 2kg","rate":190.11,"cost":"","freight_charge":190.11,"cod":1,"cod_charges":0,"estimated_delivery_days":"5","etd":"Aug 06, 2026","city":"BANGALORE","delivery_performance":3.6,"rating":2.67},{"courier_company_id":15123,"courier_name":"India Post - Speed Post_2.0","rate":212.8,"cost":"","freight_charge":212.8,"cod":1,"cod_charges":0,"estimated_delivery_days":"5","etd":"Aug 06, 2026","city":"BANGALORE","delivery_performance":4.5,"rating":4.4},{"courier_company_id":43,"courier_name":"Delhivery Surface","rate":218.36,"cost":"","freight_charge":218.36,"cod":1,"cod_charges":0,"estimated_delivery_days":"6","etd":"Aug 07, 2026","city":"Bangalore","delivery_performance":4.2,"rating":4.2},{"courier_company_id":6,"courier_name":"DTDC Surface","rate":266.65,"cost":"","freight_charge":266.65999999999997,"cod":1,"cod_charges":0,"estimated_delivery_days":"6","etd":"Aug 07, 2026","city":"BANGALORE","delivery_performance":3.6,"rating":2.67},{"courier_company_id":196,"courier_name":"DTDC Air 500gm","rate":319.79,"cost":"","freight_charge":319.78,"cod":1,"cod_charges":0,"estimated_delivery_days":"3","etd":"Aug 04, 2026","city":"BANGALORE","delivery_performance":3.9,"rating":2.67},{"courier_company_id":1,"courier_name":"Blue Dart Air","rate":344.25,"cost":"","freight_charge":344.25,"cod":1,"cod_charges":0,"estimated_delivery_days":"3","etd":"Aug 04, 2026","city":"Bangalore","delivery_performance":4.6,"rating":4.33}],"recommended_courier_company_id":55,"recommended_by":{"id":6,"title":"Recommendation By Shiprocket"}},"status":200},"deliverable":true}';

/// The identical request with `cod: 1`. Every `rate` grew by exactly its
/// `cod_charges`; `freight_charge` did not move.
const String _serviceabilityCod =
    '{"success":true,"status":"success","message":"Serviceability check completed","data":{"currency":"INR","data":{"available_courier_companies":[{"courier_company_id":55,"courier_name":"Blue Dart Surface","rate":331.65,"cost":"","freight_charge":276,"cod":1,"cod_charges":55.65,"estimated_delivery_days":"5","etd":"Aug 06, 2026","city":"Bangalore","delivery_performance":4.1,"rating":4.8},{"courier_company_id":15123,"courier_name":"India Post - Speed Post_2.0","rate":222.25,"cost":"","freight_charge":212.8,"cod":1,"cod_charges":9.45,"estimated_delivery_days":"5","etd":"Aug 06, 2026","city":"BANGALORE","delivery_performance":4.5,"rating":4.4},{"courier_company_id":196,"courier_name":"DTDC Air 500gm","rate":378.59,"cost":"","freight_charge":319.78,"cod":1,"cod_charges":58.8,"estimated_delivery_days":"3","etd":"Aug 04, 2026","city":"BANGALORE","delivery_performance":3.9,"rating":2.67}],"recommended_courier_company_id":55,"recommended_by":{"id":6,"title":"Recommendation By Shiprocket"}},"status":200},"deliverable":true}';

// ---------------------------------------------------------------------------
// The coverage-charge step — captured live 2026-08-04, pickup 311001 ->
// delivery 382415, 5.0 kg, 20x7x49, qc_check 0.
//
// These three bodies are the same lane at three parameter settings and they are
// the whole reason `rate` cannot be the quoted price:
//
//   declared_value 2400, cod 0   coverage_charges 0    -> rate == the billed sum
//   declared_value 2500, cod 0   coverage_charges 49   -> rate is 49.00 short
//   declared_value 2500, cod 1   coverage_charges 49   -> rate is 49.00 short
//
// `declared_value` is the basket's own `order_total`, so the step is one every
// cart crosses on the way past ~Rs 2,500.
// ---------------------------------------------------------------------------

/// Below the insurance threshold: every `coverage_charges` is 0 and `rate`
/// happens to equal the sum the server bills.
const String _serviceabilityDv2400 =
    '{"success":true,"status":"success","message":"Serviceability check completed","data":{"currency":"INR","data":{"available_courier_companies":[{"courier_company_id":400,"id":1016317372,"courier_name":"India Post - Speed Post Prepaid","rate":391.76,"cost":"","freight_charge":391.76,"coverage_charges":0,"other_charges":0,"cod":0,"cod_charges":0,"estimated_delivery_days":"5","etd":"Aug 09, 2026","city":"AHMEDABAD","delivery_performance":4.5},{"courier_company_id":25,"id":1060647415,"courier_name":"Xpressbees Surface 5kg","rate":272.06,"cost":"","freight_charge":272.06,"coverage_charges":0,"other_charges":0,"cod":1,"cod_charges":0,"estimated_delivery_days":"5","etd":"Aug 09, 2026","city":"Ahmedabad","delivery_performance":4.5}]},"status":200},"deliverable":true}';

/// The identical request at `declared_value: 2500`. **Only `coverage_charges`
/// moved** — `rate` and `freight_charge` are byte-identical to the 2400 body.
const String _serviceabilityDv2500 =
    '{"success":true,"status":"success","message":"Serviceability check completed","data":{"currency":"INR","data":{"available_courier_companies":[{"courier_company_id":400,"id":1016317372,"courier_name":"India Post - Speed Post Prepaid","rate":391.76,"cost":"","freight_charge":391.76,"coverage_charges":49,"other_charges":0,"cod":0,"cod_charges":0,"estimated_delivery_days":"5","etd":"Aug 09, 2026","city":"AHMEDABAD","delivery_performance":4.5},{"courier_company_id":25,"id":1060647415,"courier_name":"Xpressbees Surface 5kg","rate":272.06,"cost":"","freight_charge":272.06,"coverage_charges":49,"other_charges":0,"cod":1,"cod_charges":0,"estimated_delivery_days":"5","etd":"Aug 09, 2026","city":"Ahmedabad","delivery_performance":4.5}]},"status":200},"deliverable":true}';

/// `declared_value: 2500` with `cod: 1`. Prepaid-only couriers have dropped out
/// and every survivor carries a `cod_charges` the server adds on top of
/// freight + coverage.
const String _serviceabilityDv2500Cod =
    '{"success":true,"status":"success","message":"Serviceability check completed","data":{"currency":"INR","data":{"available_courier_companies":[{"courier_company_id":25,"id":1060647415,"courier_name":"Xpressbees Surface 5kg","rate":341.31,"cost":"","freight_charge":272.06,"coverage_charges":49,"other_charges":0,"cod":1,"cod_charges":69.25,"estimated_delivery_days":"5","etd":"Aug 09, 2026","city":"Ahmedabad","delivery_performance":4.5},{"courier_company_id":15123,"id":1051767609,"courier_name":"India Post - Speed Post_2.0","rate":436.65,"cost":"","freight_charge":389.4,"coverage_charges":49,"other_charges":0,"cod":1,"cod_charges":47.25,"estimated_delivery_days":"5","etd":"Aug 09, 2026","city":"AHMEDABAD","delivery_performance":4.5}]},"status":200},"deliverable":true}';

/// Upstream refused — and it still arrives as **HTTP 200**. Shiprocket reports
/// its own status inside the body.
const String _serviceabilityNoCourier = '{"success":false,"status":"error",'
    '"message":"No courier service available between 110055 and 999999",'
    '"data":{"message":"No courier service available between 110055 and 999999",'
    '"status":404},"deliverable":false}';

/// `success: true` but nothing to choose from. Distinct from the branch above.
const String _serviceabilityEmpty =
    '{"success":true,"status":"success","message":"Serviceability check completed",'
    '"data":{"currency":"INR","data":{"available_courier_companies":[]}},'
    '"deliverable":false}';

/// `POST /logistics/batch-check-pincodes` -> 200. Failures live *inside*
/// `results`, keyed by pin, not omitted.
const String _batch200 =
    '{"success":true,"status":"success","message":"Batch check completed","results":{'
    '"110001":{"status":"success","message":"Delivery available","deliverable":true,'
    '"pin_code":"110001","estimated_delivery_days":"2","estimated_delivery_date":"03-08-2026",'
    '"shipping_charge":77.36,"courier_name":"Delhivery Surface","cod_available":1,"success":true},'
    '"560001":{"status":"success","message":"Delivery available","deliverable":true,'
    '"pin_code":"560001","estimated_delivery_days":"3","estimated_delivery_date":"04-08-2026",'
    '"shipping_charge":125.96,"courier_name":"DTDC Air 500gm","cod_available":1,"success":true},'
    '"123456":{"status":"error","message":"Unable to check delivery availability",'
    '"deliverable":false,"pin_code":"123456","success":false}}}';

// ---------------------------------------------------------------------------
// Fake transport — same pattern as home_repository_test.dart. No network.
// ---------------------------------------------------------------------------

class _Canned {
  const _Canned(this.statusCode, this.body);
  final int statusCode;

  /// Raw JSON text, so the fixtures stay byte-identical to the captures.
  final String body;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);

  final Map<String, _Canned> responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final canned = responses[options.path] ??
        const _Canned(404, '{"message":"no canned response"}');
    return ResponseBody.fromString(
      canned.body,
      canned.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<({LogisticsRepository repo, _FakeAdapter adapter})> _build(
  Map<String, _Canned> responses,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(responses);
  final dio = Dio()..httpClientAdapter = adapter;
  return (
    repo: LogisticsRepository(ApiClient(prefs: prefs, dio: dio)),
    adapter: adapter,
  );
}

const String _pincodePath = '/logistics/check-pincode';
const String _serviceabilityPath = '/logistics/check-serviceability';
const String _batchPath = '/logistics/batch-check-pincodes';

Map<String, dynamic> _sentBody(RequestOptions o) =>
    Map<String, dynamic>.from(o.data as Map);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  group('date parsing', () {
    test('estimated_delivery_date is dd-MM-yyyy, not ISO and not US', () {
      // 03-08-2026 is 3 August. Read as ISO it would be a FormatException; read
      // as MM-dd-yyyy it would be 8 March — a five-month error that would look
      // entirely plausible in the UI.
      final d = parseDdMmYyyy('03-08-2026');
      expect(d, DateTime(2026, 8, 3));
      expect(d!.month, 8);
      expect(d.day, 3);
    });

    test('parses a day past 12, where the ambiguity would have shown up', () {
      expect(parseDdMmYyyy('24-12-2026'), DateTime(2026, 12, 24));
    });

    test('returns null rather than rolling an impossible date forward', () {
      // DateTime(2026, 2, 31) silently becomes 3 March.
      expect(parseDdMmYyyy('31-02-2026'), isNull);
      expect(parseDdMmYyyy('00-08-2026'), isNull);
      expect(parseDdMmYyyy('03-13-2026'), isNull);
    });

    test('falls back to ISO if the admin changes date_format', () {
      expect(parseDdMmYyyy('2026-08-03'), DateTime(2026, 8, 3));
    });

    test('null/empty/garbage give null, never an exception', () {
      expect(parseDdMmYyyy(null), isNull);
      expect(parseDdMmYyyy(''), isNull);
      expect(parseDdMmYyyy('soon'), isNull);
    });

    test("parses Shiprocket's etd format", () {
      expect(parseEtd('Aug 04, 2026'), DateTime(2026, 8, 4));
      expect(parseEtd('Dec 31, 2026'), DateTime(2026, 12, 31));
      expect(parseEtd(''), isNull);
      expect(parseEtd('Xyz 04, 2026'), isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('ShippingQuote', () {
    test('coerces the string estimated_delivery_days and int cod_available',
        () {
      final q = ShippingQuote.fromJson(
        jsonDecode(_pincode200) as Map<String, dynamic>,
      );

      expect(q.deliverable, isTrue);
      expect(q.pinCode, '110001');
      expect(q.courierName, 'DTDC Surface 10kg');
      expect(q.shippingCharge, 321.51);
      // The API sends "2" as a String; an `as int` here would throw.
      expect(q.estimatedDeliveryDays, 2);
      expect(q.estimatedDeliveryDate, DateTime(2026, 8, 3));
      expect(q.estimatedDeliveryDateRaw, '03-08-2026');
      // 1, not true.
      expect(q.codAvailable, isTrue);
      expect(q.message, 'Delivery available');
      expect(q.hasCharge, isTrue);
    });

    test('keeps the raw date when it cannot be parsed', () {
      final q = ShippingQuote.fromJson(const {
        'deliverable': true,
        'pin_code': '110001',
        'estimated_delivery_date': 'next Tuesday',
      });
      expect(q.estimatedDeliveryDate, isNull);
      expect(q.estimatedDeliveryDateRaw, 'next Tuesday');
    });
  });

  // -------------------------------------------------------------------------
  group('checkPincode', () {
    test('parses the 200 and sends all three fields', () async {
      final t = await _build({_pincodePath: const _Canned(200, _pincode200)});

      final q = await t.repo.checkPincode(pinCode: '110001', productId: 118);

      expect(q.deliverable, isTrue);
      expect(q.shippingCharge, 321.51);

      final sent = _sentBody(t.adapter.requests.single);
      expect(sent['pin_code'], '110001');
      // product_id is REQUIRED — omitting it is a 400, not an empty quote.
      expect(sent['product_id'], 118);
      expect(sent['quantity'], 1);
    });

    test('turns the 422 into a not-deliverable quote, not a thrown error',
        () async {
      // The controller does `$statusCode = $success ? 200 : 422`, so "we can't
      // ship there" arrives as an HTTP error. Surfacing that as an exception
      // would show a retry button for an answer that will never change.
      final t = await _build({_pincodePath: const _Canned(422, _pincode422)});

      final q = await t.repo.checkPincode(pinCode: '123456', productId: 118);

      expect(q.deliverable, isFalse);
      expect(q.pinCode, '123456');
      expect(q.message, 'Unable to check delivery availability');
      expect(q.shippingCharge, 0);
      expect(q.estimatedDeliveryDate, isNull);
    });

    test('rethrows a 422 that is really a service outage', () async {
      // Same status code, completely different meaning: PinCodeDeliveryService
      // emits this when there is no Shiprocket token or the upstream call threw.
      // Reporting it as "not deliverable" would tell every customer in India
      // that the shop does not ship to them.
      final t = await _build({
        _pincodePath: const _Canned(
          422,
          '{"status":"error","message":"Service temporarily unavailable",'
          '"deliverable":false,"success":false}',
        ),
      });

      await expectLater(
        t.repo.checkPincode(pinCode: '110001', productId: 118),
        throwsA(isA<ApiException>()),
      );
    });

    test('rethrows a 400 — a missing product is a caller bug', () async {
      final t = await _build({
        _pincodePath: const _Canned(
          400,
          '{"success":false,"status":"error",'
          '"message":"Product information is required","deliverable":false}',
        ),
      });

      await expectLater(
        t.repo.checkPincode(pinCode: '110001', productId: 0),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            'Product information is required',
          ),
        ),
      );
    });

    test('rethrows a 404 for an unknown product', () async {
      final t = await _build({
        _pincodePath: const _Canned(
          404,
          '{"success":false,"status":"error","message":"Product not found",'
          '"deliverable":false}',
        ),
      });

      await expectLater(
        t.repo.checkPincode(pinCode: '110001', productId: 999999),
        throwsA(
          isA<ApiException>().having((e) => e.isNotFound, 'isNotFound', isTrue),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('serviceability', () {
    test('reads the doubly-nested data.data.available_courier_companies',
        () async {
      final t = await _build({
        _serviceabilityPath: const _Canned(200, _serviceabilityPrepaid),
      });

      final options = await t.repo.serviceability(
        pickupPostcode: '110001',
        deliveryPostcode: '560001',
        cod: false,
        weightKg: 1.5,
        lengthCm: 10,
        breadthCm: 10,
        heightCm: 10,
        declaredValue: 500,
      );

      expect(options, hasLength(7));
      expect(
        options.map((o) => o.courierCompanyId),
        containsAll(<int>[55, 82, 15123, 43, 6, 196, 1]),
      );
    });

    test('uses `rate` — `cost` is the empty string on every row', () async {
      final t = await _build({
        _serviceabilityPath: const _Canned(200, _serviceabilityPrepaid),
      });

      final options = await t.repo.serviceability(
        pickupPostcode: '110001',
        deliveryPostcode: '560001',
        cod: false,
        weightKg: 1.5,
        lengthCm: 10,
        breadthCm: 10,
        heightCm: 10,
        declaredValue: 500,
      );

      // Had the parser reached for `cost`, every rate would be 0 and the whole
      // order would ship free.
      expect(options.every((o) => o.rate > 0), isTrue);
      final blueDartAir = options.firstWhere((o) => o.courierCompanyId == 1);
      expect(blueDartAir.rate, 344.25);
      // `freight_charge` matches on this row and there are no coverage or other
      // charges, so the billed sum lands on the same number — which is exactly
      // the "rows where they agree" case.
      expect(blueDartAir.billedPrice, 344.25);
      expect(blueDartAir.billedPriceFormatted, contains('344.25'));
    });

    test('prepaid rows: rate == freight_charge, cod_charges zero', () async {
      final t = await _build({
        _serviceabilityPath: const _Canned(200, _serviceabilityPrepaid),
      });

      final options = await t.repo.serviceability(
        pickupPostcode: '110001',
        deliveryPostcode: '560001',
        cod: false,
        weightKg: 1.5,
        lengthCm: 10,
        breadthCm: 10,
        heightCm: 10,
        declaredValue: 500,
      );

      final blueDartSurface =
          options.firstWhere((o) => o.courierCompanyId == 55);
      expect(blueDartSurface.rate, 276);
      expect(blueDartSurface.freightCharge, 276);
      expect(blueDartSurface.codCharges, 0);
      expect(blueDartSurface.hasCodSurcharge, isFalse);
    });

    test('cod:1 rows already include cod_charges inside rate', () async {
      // The trap this guards: showing `rate` and then adding `cod_charges` as a
      // separate line double-charges the COD fee.
      final t = await _build({
        _serviceabilityPath: const _Canned(200, _serviceabilityCod),
      });

      final options = await t.repo.serviceability(
        pickupPostcode: '110001',
        deliveryPostcode: '560001',
        cod: true,
        weightKg: 1.5,
        lengthCm: 10,
        breadthCm: 10,
        heightCm: 10,
        declaredValue: 500,
      );

      final blueDartSurface =
          options.firstWhere((o) => o.courierCompanyId == 55);
      expect(blueDartSurface.freightCharge, 276);
      expect(blueDartSurface.codCharges, 55.65);
      expect(blueDartSurface.rate, 331.65);
      expect(
        blueDartSurface.rate,
        closeTo(
          blueDartSurface.freightCharge + blueDartSurface.codCharges,
          0.001,
        ),
      );
      expect(blueDartSurface.hasCodSurcharge, isTrue);

      expect(_sentBody(t.adapter.requests.single)['cod'], 1);
    });

    test('sends all nine required fields, cod/qc_check as ints', () async {
      final t = await _build({
        _serviceabilityPath: const _Canned(200, _serviceabilityPrepaid),
      });

      await t.repo.serviceability(
        pickupPostcode: '110001',
        deliveryPostcode: '560001',
        cod: false,
        weightKg: 1.5,
        lengthCm: 22.4,
        breadthCm: 10,
        heightCm: 10,
        declaredValue: 1499.5,
        qcCheck: true,
      );

      final sent = _sentBody(t.adapter.requests.single);
      // A 400 enumerates every one of these if it is missing.
      expect(
        sent.keys,
        containsAll(<String>[
          'pickup_postcode',
          'delivery_postcode',
          'cod',
          'weight',
          'length',
          'breadth',
          'height',
          'declared_value',
          'qc_check',
        ]),
      );
      expect(sent['cod'], 0);
      expect(sent['qc_check'], 1);
      // Nothing is rounded client-side. `DeliveryController` casts length,
      // breadth, height and declared_value with PHP's `(int)`, which
      // TRUNCATES — so rounding 22.4 to 22 here is harmless but rounding 22.5
      // to 23 would quote a box the web (which sends the raw figure straight
      // to Shiprocket) never asks for. Let the server's own cast be the only
      // one, and it lands where PHP lands.
      expect(sent['weight'], 1.5);
      expect(sent['length'], 22.4);
      expect(sent['breadth'], 10);
      expect(sent['height'], 10);
      expect(sent['declared_value'], 1499.5);
    });

    test('throws on the upstream failure that arrives as HTTP 200', () async {
      // Dio does not throw (200) and `declaresFailure` does not fire (no
      // `error: true`), so without the explicit success check this would look
      // like "no couriers found" and hide "Invalid Pickup Pincode" forever.
      final t = await _build({
        _serviceabilityPath: const _Canned(200, _serviceabilityNoCourier),
      });

      await expectLater(
        t.repo.serviceability(
          pickupPostcode: '110001',
          deliveryPostcode: '999999',
          cod: false,
          weightKg: 1.5,
          lengthCm: 10,
          breadthCm: 10,
          heightCm: 10,
          declaredValue: 500,
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            'No courier service available between 110055 and 999999',
          ),
        ),
      );
    });

    test('returns an empty list when the call succeeded with no couriers',
        () async {
      final t = await _build({
        _serviceabilityPath: const _Canned(200, _serviceabilityEmpty),
      });

      final options = await t.repo.serviceability(
        pickupPostcode: '110001',
        deliveryPostcode: '560001',
        cod: false,
        weightKg: 1.5,
        lengthCm: 10,
        breadthCm: 10,
        heightCm: 10,
        declaredValue: 500,
      );

      expect(options, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // The price the server actually bills.
  //
  //   ShipRocketService.php:1880-1886
  //     $baseShippingCost = $freightCharge + $coverageCharges;
  //     $totalCost        = $baseShippingCost + $otherCharges;
  //     if ($this->isCodOrder($originalData)) { $totalCost += $codCharges; }
  //   :1894  'price' => $totalCost
  //   API/CheckoutController.php:446  Arr::get($shippingMethod, 'price', 0)
  //   :462                            $orderAmount += (float) $shippingAmount;
  // -------------------------------------------------------------------------
  group('billedPrice — the sum, not `rate`', () {
    CourierOption row(String body, int id, {bool cod = false}) =>
        CourierOption.listFrom(jsonDecode(body), cod: cod)
            .firstWhere((o) => o.courierCompanyId == id);

    test('below the insurance threshold `rate` and the sum agree', () {
      final xpressbees = row(_serviceabilityDv2400, 25);

      expect(xpressbees.coverageCharges, 0);
      expect(xpressbees.otherCharges, 0);
      expect(xpressbees.freightCharge, 272.06);
      expect(xpressbees.rate, 272.06);
      expect(xpressbees.billedPrice, 272.06);
      expect(
        xpressbees.rateUnderQuotes,
        isFalse,
        reason: 'this is the row where the old code was accidentally right',
      );
    });

    // The bug, in one assertion. Same lane, same parcel, same courier, same
    // `rate` — a Rs 100 larger basket and the server bills Rs 49.00 more.
    test('at declared_value 2500 the sum is Rs 49.00 above `rate`', () {
      final below = row(_serviceabilityDv2400, 25);
      final above = row(_serviceabilityDv2500, 25);

      // `rate` cannot see the step at all: it is byte-identical either side.
      expect(above.rate, below.rate);
      expect(above.freightCharge, below.freightCharge);

      // The step lives entirely in coverage_charges, which `rate` omits.
      expect(above.coverageCharges, 49);
      expect(above.billedPrice, closeTo(321.06, 0.0001));
      expect(above.billedPrice - above.rate, closeTo(49, 0.0001));
      expect(above.billedPrice - below.billedPrice, closeTo(49, 0.0001));
      expect(above.rateUnderQuotes, isTrue);
    });

    test('every row of the same response steps by the same Rs 49.00', () {
      // coverage_charges is keyed off declared_value, not off the courier, so
      // it moves in lockstep across the whole list.
      final below = CourierOption.listFrom(jsonDecode(_serviceabilityDv2400));
      final above = CourierOption.listFrom(jsonDecode(_serviceabilityDv2500));

      expect(above.length, below.length);
      for (var i = 0; i < above.length; i++) {
        expect(above[i].courierCompanyId, below[i].courierCompanyId);
        expect(
          above[i].billedPrice - below[i].billedPrice,
          closeTo(49, 0.0001),
          reason: '${above[i].courierName} must step with the rest',
        );
      }
      // India Post: 391.76 freight + 49.00 coverage.
      expect(row(_serviceabilityDv2500, 400).billedPrice, closeTo(440.76, 1e-9));
    });

    test('a COD quote adds cod_charges on top of freight + coverage', () {
      final xpressbees = row(_serviceabilityDv2500Cod, 25, cod: true);

      expect(xpressbees.codQuoted, isTrue);
      expect(xpressbees.freightCharge, 272.06);
      expect(xpressbees.coverageCharges, 49);
      expect(xpressbees.codCharges, 69.25);
      expect(xpressbees.billedPrice, closeTo(390.31, 0.0001));

      // `rate` on a COD row is freight + cod_charges, so it is short by exactly
      // the coverage again — the same Rs 49.00 hole from the other direction.
      expect(xpressbees.rate, 341.31);
      expect(xpressbees.billedPrice - xpressbees.rate, closeTo(49, 0.0001));

      // Second courier, same arithmetic, different cod_charges: 389.40 + 49.00
      // + 47.25.
      expect(
        row(_serviceabilityDv2500Cod, 15123, cod: true).billedPrice,
        closeTo(485.65, 0.0001),
      );
    });

    // `isCodOrder($originalData)` is a property of the *request*. Parsing the
    // same COD body as if it were a prepaid quote must not bill the surcharge,
    // and this is why the flag rides on the row instead of being asked for at
    // each call site.
    test('cod_charges count only when the quote was a COD one', () {
      final asCod = row(_serviceabilityDv2500Cod, 25, cod: true);
      final asPrepaid = row(_serviceabilityDv2500Cod, 25);

      expect(asPrepaid.codQuoted, isFalse);
      expect(asPrepaid.codCharges, 69.25, reason: 'still parsed, just not billed');
      expect(asPrepaid.billedPrice, closeTo(321.06, 0.0001));
      expect(asCod.billedPrice - asPrepaid.billedPrice, closeTo(69.25, 0.0001));
    });

    test('other_charges is summed too — order 275 and 266 both carried one', () {
      // Zero on every lane captured in 2026, but historically real: order 275
      // recorded 802.12 = 741.32 freight + 11.80 other + 49.00 coverage, and
      // order 266 (COD) 326.31 = 272.06 + 5.90 other + 48.35 cod.
      final rows = CourierOption.listFrom({
        'data': {
          'data': {
            'available_courier_companies': [
              {
                'courier_company_id': 275,
                'courier_name': 'Order 275 shape',
                'rate': 741.32,
                'freight_charge': 741.32,
                'coverage_charges': 49,
                'other_charges': 11.80,
                'estimated_delivery_days': '3',
              },
            ],
          },
        },
      });

      expect(rows.single.billedPrice, closeTo(802.12, 0.0001));
      expect(rows.single.rate, 741.32);
    });

    test('the repository stamps the request cod flag onto every row', () async {
      final t = await _build({
        _serviceabilityPath: const _Canned(200, _serviceabilityDv2500Cod),
      });

      final options = await t.repo.serviceability(
        pickupPostcode: '311001',
        deliveryPostcode: '382415',
        cod: true,
        weightKg: 5,
        lengthCm: 20,
        breadthCm: 7,
        heightCm: 49,
        declaredValue: 2500,
      );

      expect(options.every((o) => o.codQuoted), isTrue);
      expect(
        options.firstWhere((o) => o.courierCompanyId == 25).billedPrice,
        closeTo(390.31, 0.0001),
      );
      expect(_sentBody(t.adapter.requests.single)['cod'], 1);
    });

    test('formatting shows the billed sum, never `rate`', () {
      final above = row(_serviceabilityDv2500, 25);
      expect(above.billedPriceFormatted, contains('321.06'));
      expect(above.billedPriceFormatted, isNot(contains('272.06')));
    });
  });

  // -------------------------------------------------------------------------
  group('sorting — display order only', () {
    List<CourierOption> parsed(String body) =>
        CourierOption.listFrom(jsonDecode(body));

    test('the server does NOT sort by price, so the client must', () {
      final serverOrder =
          parsed(_serviceabilityPrepaid).map((o) => o.rate).toList();
      final ascending = List<double>.of(serverOrder)..sort();

      expect(serverOrder.first, 276);
      expect(serverOrder, isNot(ascending));
      // Nor by speed: 5, 5, 5, 6, 6, 3, 3.
      expect(
        parsed(_serviceabilityPrepaid).map((o) => o.estimatedDeliveryDays),
        [5, 5, 5, 6, 6, 3, 3],
      );
    });

    // The helper this replaces was `CourierOption.best`, which preselected the
    // fastest courier for the customer. It is gone: sorting a list is not the
    // same act as answering for someone, and the rule it borrowed
    // (PinCodeDeliveryService::findBestCourier) belongs to the product page's
    // pincode widget, not to checkout — the web checkout preselects nothing.
    test('sortBest puts the fastest first, but that is order, not a choice',
        () {
      final sorted = CourierOption.sortBest(parsed(_serviceabilityPrepaid));

      // The 3-day rows are DTDC Air 500gm and Blue Dart Air; the cheaper of the
      // two leads.
      expect(sorted.first.courierName, 'DTDC Air 500gm');
      expect(sorted.first.estimatedDeliveryDays, 3);
      // ...and nothing anywhere turns that into a selection. There is no `best`
      // to call.
      expect(
        CourierOption.cheapest(sorted)!.courierCompanyId,
        isNot(sorted.first.courierCompanyId),
        reason: 'first-in-display-order is not the cheapest, so if anything '
            'ever preselects it the customer overpays silently',
      );
    });

    test('cheapest is a label, and is deliberately not the list head', () {
      final options = parsed(_serviceabilityPrepaid);
      final cheapest = CourierOption.cheapest(options);

      expect(cheapest!.courierName, 'DTDC Surface 2kg');
      expect(cheapest.rate, 190.11);
      expect(cheapest.estimatedDeliveryDays, 5);
    });

    test('sortBest orders by days then rate and does not mutate its input', () {
      final options = parsed(_serviceabilityPrepaid);
      final before = options.map((o) => o.courierCompanyId).toList();

      final sorted = CourierOption.sortBest(options);

      expect(sorted.map((o) => o.estimatedDeliveryDays), [3, 3, 5, 5, 5, 6, 6]);
      // Within each day group, rate ascending.
      expect(sorted.map((o) => o.rate).take(2), [319.79, 344.25]);
      expect(sorted.map((o) => o.rate).skip(2).take(3), [190.11, 212.8, 276]);
      expect(options.map((o) => o.courierCompanyId), before);
    });

    test('a row with no ETA sinks instead of winning', () {
      // asInt coerces a missing estimated_delivery_days to 0, which would sort
      // ahead of a genuine 3-day courier — PHP uses `?? 999` for the same reason.
      final rows = CourierOption.listFrom({
        'data': {
          'data': {
            'available_courier_companies': [
              {
                'courier_company_id': 900,
                'courier_name': 'Unknown ETA',
                'rate': 1,
                'freight_charge': 1,
              },
              {
                'courier_company_id': 196,
                'courier_name': 'DTDC Air 500gm',
                'rate': 319.79,
                'freight_charge': 319.79,
                'estimated_delivery_days': '3',
              },
            ],
          },
        },
      });

      expect(
        CourierOption.sortBest(rows).first.courierName,
        'DTDC Air 500gm',
        reason: 'the ETA-less row is cheaper and must still sort last',
      );
    });

    test('a row with no billable price is dropped, never quoted as free', () {
      // The drop test is on the *billed* sum, not on `rate`, because that is
      // the number the order is charged: an absent `freight_charge` coerces to
      // 0 here and through `(float) Arr::get($courier, 'freight_charge', 0)` on
      // the server alike, so a row summing to zero is a row the server would
      // bill 0.00 for. Left in the list it would sort to the front of its day
      // group and the bill would print "Delivery FREE" for a shipment the shop
      // still pays a courier to carry.
      //
      // Row 903 is the case `rate > 0` would have let through and this guard
      // catches: upstream's convenience total is present but not one of the
      // components the server sums.
      final rows = CourierOption.listFrom({
        'data': {
          'data': {
            'available_courier_companies': [
              {
                'courier_company_id': 901,
                'courier_name': 'Rate Missing',
                'cost': '',
                'estimated_delivery_days': '3',
              },
              {
                'courier_company_id': 902,
                'courier_name': 'Rate Empty String',
                'rate': '',
                'freight_charge': '',
                'estimated_delivery_days': '3',
              },
              {
                'courier_company_id': 903,
                'courier_name': 'Rate But No Components',
                'rate': 250,
                'estimated_delivery_days': '3',
              },
              {
                'courier_company_id': 196,
                'courier_name': 'DTDC Air 500gm',
                'rate': 319.79,
                'freight_charge': 319.79,
                'estimated_delivery_days': '3',
              },
            ],
          },
        },
      });

      expect(rows.map((o) => o.courierName), ['DTDC Air 500gm']);
      expect(CourierOption.cheapest(rows)!.billedPrice, 319.79);
    });

    test('cheapest of an empty list is null, not a crash', () {
      expect(CourierOption.cheapest(const []), isNull);
      expect(CourierOption.sortBest(const []), isEmpty);
    });

    test('listFrom survives the failure body that has no courier array', () {
      expect(
        CourierOption.listFrom(jsonDecode(_serviceabilityNoCourier)),
        isEmpty,
      );
      expect(CourierOption.listFrom(null), isEmpty);
      expect(CourierOption.listFrom(const {'data': null}), isEmpty);
      expect(
        CourierOption.listFrom(const {
          'data': {'data': 'nope'},
        }),
        isEmpty,
      );
    });
  });

  // -------------------------------------------------------------------------
  group('batchCheckPincodes', () {
    test('keys results by pin and keeps the failures', () async {
      final t = await _build({_batchPath: const _Canned(200, _batch200)});

      final results = await t.repo.batchCheckPincodes(
        pinCodes: ['110001', '560001', '123456'],
      );

      expect(results.keys, containsAll(<String>['110001', '560001', '123456']));
      expect(results['110001']!.deliverable, isTrue);
      expect(results['110001']!.shippingCharge, 77.36);
      expect(results['560001']!.courierName, 'DTDC Air 500gm');
      // Undeliverable pins are present, not missing — an absent key would look
      // identical to a dropped response.
      expect(results['123456']!.deliverable, isFalse);
      expect(
        results['123456']!.message,
        'Unable to check delivery availability',
      );
    });

    test('sends the package, because this route ignores product_id', () async {
      // batchCheckPinCodes reads only pin_codes/weight/length/breadth/height/
      // cod_enabled. Left at the defaults it quotes a 0.5 kg 10x10x10 parcel,
      // which is why an unparameterised batch call disagrees with check-pincode
      // for the same pin (110001: 77.36 vs 321.51, both live).
      final t = await _build({_batchPath: const _Canned(200, _batch200)});

      await t.repo.batchCheckPincodes(
        pinCodes: ['110001'],
        weightKg: 5.2,
        lengthCm: 30,
        breadthCm: 20,
        heightCm: 15,
        cod: true,
      );

      final sent = _sentBody(t.adapter.requests.single);
      expect(sent['pin_codes'], ['110001']);
      expect(sent['weight'], 5.2);
      expect(sent['length'], 30);
      expect(sent['cod_enabled'], true);
      expect(sent.containsKey('product_id'), isFalse);
    });

    test('deduplicates and trims pins', () async {
      final t = await _build({_batchPath: const _Canned(200, _batch200)});

      await t.repo
          .batchCheckPincodes(pinCodes: ['110001', ' 110001 ', '560001']);

      expect(
        _sentBody(t.adapter.requests.single)['pin_codes'],
        ['110001', '560001'],
      );
    });

    test('short-circuits an empty list instead of taking the 400', () async {
      final t = await _build({_batchPath: const _Canned(200, _batch200)});

      expect(await t.repo.batchCheckPincodes(pinCodes: const []), isEmpty);
      expect(
        await t.repo.batchCheckPincodes(pinCodes: const ['', '  ']),
        isEmpty,
      );
      expect(t.adapter.requests, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('weight conversion', () {
    test('kgFromGrams converts and floors nothing', () {
      // The cart reports total_weight in GRAMS; serviceability wants KG.
      expect(LogisticsRepository.kgFromGrams(1500), 1.5);
      expect(LogisticsRepository.kgFromGrams(500), 0.5);
      // Deliberately unfloored. The two routes floor at different values —
      // check-pincode at 0.1, serviceability at 0.5 — and baking one in is
      // exactly how serviceability came to be quoted at check-pincode's floor.
      expect(LogisticsRepository.kgFromGrams(50), 0.05);
      expect(LogisticsRepository.kgFromGrams(0), 0);
      expect(LogisticsRepository.kgFromGrams(-10), 0);
    });

    test('serviceabilityWeightKg applies the WEB floor, 0.5 not 0.1', () {
      // `max($rawWeight / 1000, 0.5)` in getServiceabilityRates(). Probed live
      // 2026-08-03 to 560001 with a 10x10x10 parcel: India Post quoted ₹73.16
      // at 0.1 kg and ₹96.76 at 0.5 kg, so the old 0.1 floor under-quoted every
      // light basket by ₹23.60 against the website.
      expect(LogisticsRepository.minServiceabilityWeightKg, 0.5);
      expect(LogisticsRepository.minPinCodeWeightKg, 0.1);

      expect(LogisticsRepository.serviceabilityWeightKg(10200), 10.2);
      expect(LogisticsRepository.serviceabilityWeightKg(500), 0.5);
      expect(LogisticsRepository.serviceabilityWeightKg(50), 0.5);
      expect(LogisticsRepository.serviceabilityWeightKg(0), 0.5);
    });

    test('atLeastServiceabilityWeight floors a figure already in kg', () {
      // The `package_dimensions.weight` path. Feeding kilograms through
      // serviceabilityWeightKg would quote a 10.2 kg order as 0.5 kg.
      expect(LogisticsRepository.atLeastServiceabilityWeight(10.2), 10.2);
      expect(LogisticsRepository.atLeastServiceabilityWeight(0.2), 0.5);
    });
  });
}

/// The `shipping_option` key, end to end.
///
/// ## What is being defended
///
/// The checkout POST the web makes — and the one this app now mirrors — carries
/// `"shipping_method": "shiprocket"` plus `"shipping_option": "shiprocket_<id>"`
/// and **no `shipping_amount`**. The server prices the order by looking that
/// option string up in a rate table it rebuilds for itself, keyed at
/// `ShipRocketService.php:1889`:
///
/// ```php
/// $rateId    = Arr::get($courier, 'id');   // :1870 -> 1016322646
/// $rateIdKey = 'shiprocket_' . $rateId;    // :1889 -> shiprocket_1016322646
/// ```
///
/// `courier_company_id` (400) is only a *field on the entry*, never part of the
/// key. Building `shiprocket_400` therefore does not fail loudly: the lookup
/// misses, the resolved method is null, `Arr::get($shippingMethod, 'price', 0)`
/// returns 0, and a real order is written charging **0.00** for delivery. These
/// tests exist because that failure is silent everywhere else.
///
/// ## The fixture is a real capture, not a hand-written shape
///
/// [_liveCapture] is the verbatim body of
/// `POST /api/v1/logistics/check-serviceability` against dev.truewayerp.com on
/// 2026-08-04, for a live cart of 2× SKU 118 — that cart's own
/// `package_dimensions` (`{length: 20, breadth: 7, height: 49, weight: 10.2}`),
/// pickup 311001, delivery 560001, prepaid. Every key Shiprocket sends is still
/// in it, including the many the model ignores, so a row that would parse only
/// because a fixture had been trimmed to fit cannot pass here.
///
/// Nothing in this file touches the network: the rows come out of that string,
/// and the provider group replaces [shippingRatesFetcherProvider].
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/shipping_quote.dart';
import 'package:trueway_farms/presentation/providers/shipping_provider.dart';

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

/// Captured live, 2026-08-04. Do not edit — its value is that it is untouched.
///
/// The two rows in it, and the trap on one line:
///
/// ```
/// courier_company_id: 400    id: 1016322646  India Post - Speed Post Prepaid  1040.76
/// courier_company_id: 15123  id: 1051772883  India Post - Speed Post_2.0      1038.40
/// ```
const String _liveCapture = r'''{"success":true,"status":"success","message":"Serviceability check completed","data":{"company_auto_shipment_insurance_setting":true,"covid_zones":{"delivery_zone":null,"pickup_zone":null},"currency":"INR","data":{"available_courier_companies":[{"Attempt_Speed":5,"NDR_Reattempt":5,"RAD_Pendency":4,"RTO w/o_Attempt":4,"SLA_Adherence":4,"SLA_Breach":3,"air_max_weight":"35.00","api_edd":0,"assured_amount":0,"base_courier_id":null,"base_weight":"","blocked":0,"call_before_delivery":"Available","charge_weight":10.2,"city":"BANGALORE","cod":0,"cod_charges":0,"cod_multiplier":0,"cost":"","courier_company_id":400,"courier_name":"India Post - Speed Post Prepaid","courier_type":"0","coverage_charges":0,"cutoff_time":"10:00","delivery_boy_contact":"Not Available","delivery_performance":4.5,"description":"","edd":"","edd_fallback":{"PTS":"default","SPT":"default","STD":"default"},"entry_tax":0,"estimated_delivery_days":"4","etd":"Aug 08, 2026","etd_hours":103,"fallback_rating":1,"format_id":1,"freight_charge":1040.76,"id":1016322646,"is_custom_rate":0,"is_hyperlocal":false,"is_international":0,"is_rto_address_available":true,"is_surface":false,"local_region":0,"message":"Alert! Weight limit exceeding threshold.","metro":1,"min_weight":0.05,"mode":1,"new_edd":0,"odablock":false,"other_charges":0,"others":"{\"auto_pickup\":1,\"cancel_real_time\":true,\"is_cancel_courier\":1,\"is_custom_courier\":1,\"is_manual_courier\":1,\"is_manual_prefecth_courier\":0,\"is_notify_cancel_courier\":1,\"prefetch_awb\":1}","pickup_availability":"1","pickup_performance":4.4,"pickup_priority":"","pickup_supress_hours":0,"pod_available":"On Request","postcode":"560001","qc_courier":0,"rank":"","rate":1040.76,"rating":4.17,"realtime_tracking":"Real Time","region":2,"rto_charges":0.01,"rto_performance":4.4,"seconds_left_for_pickup":943,"secure_shipment_disabled":false,"ship_type":1,"state":"KARNATAKA","suppress_date":"Aug 04, 2026","suppress_text":"","suppression_dates":{"action_on":"2026-06-19 16:06:22","blocked_fm":"","blocked_lm":""},"surface_max_weight":"0.00","surge":[{"charge":2.36,"cod_surge":0,"rule_id":563,"type":"seller_surge"}],"tracking_performance":4.5,"volumetric_max_weight":35,"weight_cases":4.2,"whatsapp_charges":5,"zone":"z_d"},{"air_max_weight":"35.00","api_edd":0,"assured_amount":0,"base_courier_id":null,"base_weight":"","blocked":0,"call_before_delivery":"Available","charge_weight":10.2,"city":"BANGALORE","cod":1,"cod_charges":0,"cod_multiplier":0,"cost":"","courier_company_id":15123,"courier_name":"India Post - Speed Post_2.0","courier_type":"0","coverage_charges":0,"cutoff_time":"10:00","delivery_boy_contact":"Not Available","delivery_performance":4.5,"description":"","edd":"","edd_fallback":{"PTS":"default","SPT":"default","STD":"default"},"entry_tax":0,"estimated_delivery_days":"4","etd":"Aug 08, 2026","etd_hours":103,"freight_charge":1038.4,"id":1051772883,"is_custom_rate":0,"is_hyperlocal":false,"is_international":0,"is_rto_address_available":true,"is_surface":false,"local_region":0,"message":"Alert! Weight limit exceeding threshold.","metro":1,"min_weight":0.05,"mode":1,"new_edd":0,"odablock":false,"other_charges":0,"others":"{\"auto_pickup\":1,\"cancel_real_time\":true,\"cloned_from_courier_id\":400,\"courier_logo_url\":\"https://s3-ap-south-1.amazonaws.com/kr-shipmultichannel-mum/courier_logo/15123.png\",\"enterprise\":0,\"is_cancel_courier\":1,\"is_custom_courier\":1,\"is_manual_courier\":1,\"is_manual_prefecth_courier\":0,\"is_notify_cancel_courier\":1,\"is_quick\":0,\"pass_through\":0,\"prefetch_awb\":1,\"source_platform\":\"IRIS\"}","pickup_availability":"1","pickup_performance":4.4,"pickup_priority":"","pickup_supress_hours":0,"pod_available":"On Request","postcode":"560001","qc_courier":0,"rank":"","rate":1038.4,"rating":4.4,"realtime_tracking":"Real Time","region":2,"rto_charges":0.01,"rto_performance":4.4,"seconds_left_for_pickup":943,"secure_shipment_disabled":false,"ship_type":1,"state":"KARNATAKA","suppress_date":"Aug 04, 2026","suppress_text":"","suppression_dates":{"action_on":"2026-07-24 15:17:51","blocked_fm":"","blocked_lm":""},"surface_max_weight":"0.00","tracking_performance":4.5,"volumetric_max_weight":35,"weight_cases":4.2,"whatsapp_charges":5,"zone":"z_d"}],"child_courier_id":null,"is_recommendation_enabled":1,"is_rocketExpress_shipment":0,"promise_recommended_courier_company_id":null,"recommendation_advance_rule":0,"recommendation_level":"rating","recommended_by":{"id":6,"title":"Recommendation By Shiprocket"},"recommended_courier_company_id":400,"shiprocket_recommended_courier_id":400},"dg_courier":0,"eligible_for_insurance":0,"insurace_opted_at_order_creation":false,"is_allow_templatized_pricing":true,"is_latlong":0,"is_old_zone_opted":false,"is_zone_from_mongo":true,"label_generate_type":2,"on_new_zone":0,"seller_address":[],"status":200,"timestamp":"2026-08-04T09:44:16+05:30","user_insurance_manadatory":false},"deliverable":true}''';

/// The rate ids in the capture, against the courier company ids they are *not*.
const String _prepaidRateId = '1016322646';
const int _prepaidCourierCompanyId = 400;
const String _speedPost20RateId = '1051772883';
const int _speedPost20CourierCompanyId = 15123;

Map<String, dynamic> get _decodedCapture =>
    jsonDecode(_liveCapture) as Map<String, dynamic>;

/// The decoded rows themselves, not copies — a test that removes a key from one
/// must change what [CourierOption.listFrom] then sees in `body`.
List<Map<String, dynamic>> _rawRows(Map<String, dynamic> body) =>
    (((body['data'] as Map)['data'] as Map)['available_courier_companies']
            as List)
        .cast<Map<String, dynamic>>();

List<CourierOption> get _capturedOptions =>
    CourierOption.listFrom(_decodedCapture);

CourierOption _rowFor(int courierCompanyId) =>
    _capturedOptions.firstWhere((o) => o.courierCompanyId == courierCompanyId);

// ---------------------------------------------------------------------------
// Provider harness
// ---------------------------------------------------------------------------

/// The parcel the capture was actually taken for.
const _query = ShippingQuery(
  pinCode: '560001',
  pickupPinCode: '311001',
  weightKg: 10.2,
  lengthCm: 20,
  breadthCm: 7,
  heightCm: 49,
  declaredValue: 1887.9,
);

/// A different parcel, to prove a choice made for one cannot key another.
const _otherQuery = ShippingQuery(
  pinCode: '110001',
  pickupPinCode: '311001',
  weightKg: 0.5,
  lengthCm: 10,
  breadthCm: 15,
  heightCm: 20,
  declaredValue: 500,
);

ProviderContainer _container(ShippingRatesFetcher fetcher) {
  final container = ProviderContainer(
    overrides: [shippingRatesFetcherProvider.overrideWithValue(fetcher)],
  );
  addTearDown(container.dispose);
  return container;
}

/// Reads the key once the quote has actually landed.
///
/// The subscription is what keeps the autoDispose family alive across the
/// await: without it the provider is torn down the instant the future
/// completes, and the read that follows starts a fresh, still-loading fetch.
Future<String?> _keyFor(ProviderContainer container, ShippingQuery query) async {
  final sub = container.listen(courierOptionsProvider(query), (_, __) {});
  addTearDown(sub.close);
  await container.read(courierOptionsProvider(query).future);
  return container.read(shippingOptionKeyProvider(query));
}

void main() {
  // ------------------------------------------------------------------
  // Parsing the real rows
  // ------------------------------------------------------------------
  group('CourierOption.rateId — from the live capture', () {
    test('the two ids on a real row are different numbers', () {
      final row = _rowFor(_prepaidCourierCompanyId);

      // Were these ever the same field, this whole file would be pointless and
      // the bug it guards unreachable. They are not.
      expect(row.courierCompanyId, _prepaidCourierCompanyId);
      expect(row.rateId, _prepaidRateId);
      expect(row.rateId, isNot(row.courierCompanyId.toString()));
    });

    test('shippingOptionKey is shiprocket_<rate id>', () {
      expect(
        _rowFor(_prepaidCourierCompanyId).shippingOptionKey,
        'shiprocket_$_prepaidRateId',
      );
      expect(
        _rowFor(_speedPost20CourierCompanyId).shippingOptionKey,
        'shiprocket_$_speedPost20RateId',
      );
    });

    test('shippingOptionKey is never built from courier_company_id', () {
      for (final row in _capturedOptions) {
        expect(
          row.shippingOptionKey,
          isNot('shiprocket_${row.courierCompanyId}'),
          reason: 'shiprocket_${row.courierCompanyId} is not a key the server '
              'has; the lookup would miss and the order would ship for 0.00',
        );
      }
    });

    test('every captured row carries a key, and they are distinct', () {
      final keys = _capturedOptions.map((o) => o.shippingOptionKey).toList();

      expect(_capturedOptions, hasLength(2));
      expect(keys, everyElement(isNotNull));
      expect(_capturedOptions.every((o) => o.hasShippingOptionKey), isTrue);
      expect(keys.toSet(), hasLength(keys.length));
    });

    test('the rest of the row still parses from the untrimmed capture', () {
      final row = _rowFor(_prepaidCourierCompanyId);

      // Guards against a fixture that only "works" because it was reduced to
      // the fields under test.
      expect(row.courierName, 'India Post - Speed Post Prepaid');
      expect(row.rate, 1040.76);
      expect(row.estimatedDeliveryDays, 4);
      expect(row.etd, 'Aug 08, 2026');
      expect(row.etdDate, DateTime(2026, 8, 8));
      expect(row.codAvailable, isFalse);
    });
  });

  // ------------------------------------------------------------------
  // Rows the contract does not promise
  // ------------------------------------------------------------------
  group('CourierOption.rateId — when `id` is missing or unusable', () {
    /// The captured row with its `id` removed or replaced, so everything else
    /// about it stays real.
    CourierOption rowWithId(Object? id, {bool remove = false}) {
      final raw = Map<String, dynamic>.from(_rawRows(_decodedCapture).first);
      if (remove) {
        raw.remove('id');
      } else {
        raw['id'] = id;
      }
      return CourierOption.fromJson(raw);
    }

    test('a row with no id yields no key instead of crashing', () {
      final row = rowWithId(null, remove: true);

      expect(row.rateId, isNull);
      expect(row.shippingOptionKey, isNull);
      expect(row.hasShippingOptionKey, isFalse);
      // ...and it is still a real, priced offer.
      expect(row.rate, 1040.76);
      expect(row.courierCompanyId, _prepaidCourierCompanyId);
    });

    test('a keyless row is still offered to the customer', () {
      final body = _decodedCapture;
      _rawRows(body).first.remove('id');

      final options = CourierOption.listFrom(body);

      // Dropping it would silently shrink the list over a field the customer
      // cannot see. Checkout gates on hasShippingOptionKey instead.
      expect(options, hasLength(2));
      expect(options.where((o) => !o.hasShippingOptionKey), hasLength(1));
    });

    test('a string id is preserved verbatim — PHP concatenates, never casts',
        () {
      expect(
        rowWithId('1016322646').shippingOptionKey,
        'shiprocket_$_prepaidRateId',
      );
      expect(rowWithId('  1016322646  ').rateId, _prepaidRateId);
    });

    test('an integral double id renders without a decimal point', () {
      // 1016322646.0 must not become "shiprocket_1016322646.0".
      expect(
        rowWithId(1016322646.0).shippingOptionKey,
        'shiprocket_$_prepaidRateId',
      );
    });

    test('a type that cannot be an id yields no key rather than a wrong one',
        () {
      for (final hostile in <Object>[
        true,
        <String, dynamic>{'id': 1},
        <int>[1],
        1016322646.5,
        double.nan,
        double.infinity,
      ]) {
        expect(
          rowWithId(hostile).shippingOptionKey,
          isNull,
          reason: 'a plausible-looking wrong key is worse than none: it misses '
              'server-side and bills 0.00 with no error anywhere',
        );
      }
      expect(rowWithId('').rateId, isNull);
      expect(rowWithId('   ').rateId, isNull);
    });
  });

  // ------------------------------------------------------------------
  // Reaching checkout
  // ------------------------------------------------------------------
  group('shippingOptionKeyProvider', () {
    test('is null before the quote lands', () {
      final container = _container((_) async => throw StateError('unused'));

      expect(container.read(shippingOptionKeyProvider(_query)), isNull);
    });

    // Nothing is preselected any more, so a landed quote is still not a key.
    // This used to assert the opposite — that the list's own head became the
    // key — which is how an order could carry a courier nobody chose.
    test('is still null once the quote lands, until somebody picks', () async {
      final container =
          _container((_) async => ShippingRates.fromCouriers(_capturedOptions));

      expect(await _keyFor(container, _query), isNull);
      // The rows are there and both are bookable; none of them is in effect.
      expect(
        container.read(courierOptionsProvider(_query)).value!.options,
        hasLength(2),
      );
      expect(container.read(selectedShippingProvider(_query)), isNull);
    });

    test('follows the courier the customer picked by hand', () async {
      final container =
          _container((_) async => ShippingRates.fromCouriers(_capturedOptions));
      await _keyFor(container, _query);

      container
          .read(shippingChoiceProvider.notifier)
          .select(_query, _rowFor(_prepaidCourierCompanyId));

      expect(
        container.read(shippingOptionKeyProvider(_query)),
        'shiprocket_$_prepaidRateId',
      );
    });

    test('re-resolves a stale rate id against the list that is live now',
        () async {
      final container =
          _container((_) async => ShippingRates.fromCouriers(_capturedOptions));
      await _keyFor(container, _query);

      // The same courier, quoted earlier under a rate id since reissued. A rate
      // id identifies a quote, not a courier, so the pin resolves by
      // courier_company_id and the key comes off the fresh row.
      final stale = CourierOption.fromJson({
        'courier_company_id': _prepaidCourierCompanyId,
        'id': 900000001,
        'courier_name': 'India Post - Speed Post Prepaid',
        'rate': 999.99,
        'estimated_delivery_days': '4',
      });
      expect(stale.shippingOptionKey, 'shiprocket_900000001');

      container.read(shippingChoiceProvider.notifier).select(_query, stale);

      expect(
        container.read(shippingOptionKeyProvider(_query)),
        'shiprocket_$_prepaidRateId',
      );
    });

    test('a choice made for one parcel does not key another', () async {
      final container =
          _container((_) async => ShippingRates.fromCouriers(_capturedOptions));
      await _keyFor(container, _query);
      container
          .read(shippingChoiceProvider.notifier)
          .select(_query, _rowFor(_prepaidCourierCompanyId));

      // Different parcel, different quote: the stored pick must not carry over
      // — and there is no default waiting behind it, so the other parcel has no
      // key at all until it is answered in its own right.
      expect(await _keyFor(container, _otherQuery), isNull);
      // The pick still keys the parcel it was made for.
      expect(
        container.read(shippingOptionKeyProvider(_query)),
        'shiprocket_$_prepaidRateId',
      );
    });

    test('is null when nothing delivers there', () async {
      final container = _container(
        (_) async => ShippingRates.unavailable('No courier service available'),
      );

      expect(await _keyFor(container, _query), isNull);
    });

    test('travels with the choice the app stores', () {
      final choice = ShippingChoice(
        query: _query,
        option: _rowFor(_prepaidCourierCompanyId),
      );

      expect(choice.shippingOptionKey, 'shiprocket_$_prepaidRateId');
    });
  });
}

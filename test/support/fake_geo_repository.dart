import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/repositories/geo_repository.dart';
import 'package:trueway_farms/presentation/widgets/geo_picker_field.dart';

/// The state and city lists, without a network.
///
/// Extends the real [GeoRepository] through its `offline` constructor rather
/// than reimplementing the interface, so a method added to the repository is a
/// compile error here instead of a silently unfaked call.
///
/// The rows are the live ones, trimmed: `GET /ecommerce/states` really does
/// answer `{"id":11,"name":"Gujarat"}`, and `GET /ecommerce/cities?state=11`
/// really does end with the String-id `{"id":"other","name":"Other"}` sentinel.
class FakeGeoRepository extends GeoRepository {
  FakeGeoRepository({
    this.statesResult = defaultStates,
    Map<String, List<GeoOption>>? citiesResult,
    this.failCities = false,
  })  : citiesResult = citiesResult ?? defaultCities,
        super.offline();

  final List<GeoOption> statesResult;
  final Map<String, List<GeoOption>> citiesResult;

  /// Makes [cities] answer empty, which is how the real repository reports a
  /// failed lookup — it never throws.
  final bool failCities;

  /// Every call, for asserting that a list is fetched once and then cached.
  final List<String> calls = [];

  static const List<GeoOption> defaultStates = [
    GeoOption(id: '11', name: 'Gujarat'),
    GeoOption(id: '20', name: 'Madhya Pradesh'),
    GeoOption(id: '9', name: 'Delhi'),
  ];

  /// Keyed by state id. Each list ends with the "Other" sentinel, exactly as
  /// the endpoint does.
  static const Map<String, List<GeoOption>> defaultCities = {
    '11': [
      GeoOption(id: '574', name: 'Ahmedabad'),
      GeoOption(id: '600', name: 'Vadodara'),
      GeoOption(id: GeoOption.otherId, name: 'Other'),
    ],
    '20': [
      GeoOption(id: '900', name: 'Gwalior'),
      GeoOption(id: '901', name: 'Indore'),
      GeoOption(id: GeoOption.otherId, name: 'Other'),
    ],
    // Both of 110001's districts exist as city rows here, exactly as they do
    // live (ids 504 and 512).
    '9': [
      GeoOption(id: '504', name: 'Central Delhi'),
      GeoOption(id: '512', name: 'New Delhi'),
      GeoOption(id: GeoOption.otherId, name: 'Other'),
    ],
  };

  @override
  Future<List<GeoOption>> states() async {
    calls.add('states');
    return statesResult;
  }

  @override
  Future<List<GeoOption>> cities(String stateId) async {
    calls.add('cities:$stateId');
    if (failCities) return const [];
    return citiesResult[stateId.trim()] ?? const [];
  }
}

/// Opens a [GeoPickerField] and taps one row of the sheet.
///
/// `pumpAndSettle` twice on purpose: the first settles the load and the sheet's
/// entrance animation, the second the sheet's dismissal after the tap.
Future<void> pickGeo(
  WidgetTester tester, {
  required Key field,
  required String option,
}) async {
  await tester.tap(find.byKey(field));
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

import 'package:trueway_farms/data/repositories/pincode_repository.dart';

/// PIN lookups without touching India Post.
///
/// Extends the real repository through its `offline` constructor rather than
/// reimplementing it, so a method added there is a compile error here instead
/// of a silently unfaked call.
///
/// **Every harness that mounts the address form must override the provider with
/// this.** The real repository calls a third-party host, and a test suite that
/// reaches the public internet is slow, flaky, and rude.
///
/// The three fixtures are the live answers, captured 2026-08-12:
///
/// | PIN | state | districts |
/// |---|---|---|
/// | 474010 | Madhya Pradesh | Gwalior |
/// | 382415 | Gujarat | Ahmedabad (block spelt "Ahmadabad City") |
/// | 110001 | Delhi | **Central Delhi and New Delhi** |
class FakePincodeRepository extends PincodeRepository {
  FakePincodeRepository({Map<String, PincodeLocation?>? answers})
      : answers = answers ?? defaultAnswers,
        super.offline();

  /// Keyed by PIN. A key mapped to null, or absent entirely, is "no answer" —
  /// which is what an unknown PIN and a failed lookup both produce.
  final Map<String, PincodeLocation?> answers;

  /// Every PIN asked about, for asserting that a lookup did or did not run.
  final List<String> lookups = [];

  static const PincodeLocation gwalior = PincodeLocation(
    pinCode: '474010',
    stateName: 'Madhya Pradesh',
    districts: [
      PincodeDistrict(
        name: 'Gwalior',
        // "Gird" is a real block that matches no city row — the reason the
        // district name is tried first.
        localities: ['Gwalior', 'Gird', 'Jigsoli'],
      ),
    ],
  );

  static const PincodeLocation ahmedabad = PincodeLocation(
    pinCode: '382415',
    stateName: 'Gujarat',
    districts: [
      PincodeDistrict(
        name: 'Ahmedabad',
        // India Post's spelling, which does NOT match the store's "Ahmedabad".
        localities: ['Ahmadabad City', 'Odhav'],
      ),
    ],
  );

  /// The ambiguous one: one PIN, two districts.
  static const PincodeLocation delhi = PincodeLocation(
    pinCode: '110001',
    stateName: 'Delhi',
    districts: [
      PincodeDistrict(name: 'Central Delhi', localities: ['New Delhi']),
      PincodeDistrict(name: 'New Delhi', localities: ['New Delhi']),
    ],
  );

  /// A PIN in a state the store does not stock, so the name matches nothing.
  static const PincodeLocation unknownState = PincodeLocation(
    pinCode: '744101',
    stateName: 'Nowhereland',
    districts: [PincodeDistrict(name: 'Nowhere')],
  );

  static const Map<String, PincodeLocation?> defaultAnswers = {
    '474010': gwalior,
    '382415': ahmedabad,
    '110001': delhi,
    '744101': unknownState,
  };

  @override
  Future<PincodeLocation?> lookup(String pin) async {
    final token = pin.trim();
    lookups.add(token);
    return answers[token];
  }
}

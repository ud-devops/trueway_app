import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// One district a PIN code covers, with the place names inside it.
class PincodeDistrict {
  const PincodeDistrict({required this.name, this.localities = const []});

  /// As India Post spells it — "Gwalior", "Central Delhi".
  ///
  /// This is also what gets posted as `district`, which is free text on the
  /// server, so no id mapping is involved.
  final String name;

  /// Block and post-office names inside this district, in the order received.
  ///
  /// Only used as fallback candidates when matching a city — see
  /// [PincodeLocation.cityCandidates].
  final List<String> localities;

  @override
  bool operator ==(Object other) =>
      other is PincodeDistrict &&
      other.name == name &&
      other.localities.length == localities.length &&
      other.localities.every(localities.contains);

  @override
  int get hashCode => Object.hash(name, localities.length);

  @override
  String toString() => 'PincodeDistrict($name)';
}

/// Where a PIN code is, as India Post describes it.
class PincodeLocation {
  const PincodeLocation({
    required this.pinCode,
    required this.stateName,
    required this.districts,
  });

  final String pinCode;

  /// "Madhya Pradesh", "Gujarat", "Delhi" — the standard names, which is why
  /// they match the store's own `states` table on a normalised comparison.
  final String stateName;

  /// Usually one. **Not always**: 110001 spans "Central Delhi" and
  /// "New Delhi", which is the whole reason the form offers a district picker
  /// rather than filling one in silently.
  final List<PincodeDistrict> districts;

  /// The district to fill in when there is no ambiguity.
  PincodeDistrict? get soleDistrict =>
      districts.length == 1 ? districts.first : null;

  /// Names to try, in order, when looking for a matching row of the store's
  /// city list.
  ///
  /// The district name first, because that is what actually matches: probed
  /// against the live lists, `District` resolved for all three test PINs
  /// (Gwalior → 1579, Ahmedabad → 574, Central Delhi → 504) while `Block` did
  /// not ("Gird", "Ahmadabad City" — no such city rows). Blocks and post-office
  /// names follow as long shots; "New Delhi" is a block that does match.
  List<String> cityCandidates({String? district}) {
    final wanted = district?.trim().toLowerCase();
    final chosen = [
      for (final d in districts)
        if (wanted == null || d.name.trim().toLowerCase() == wanted) d,
    ];
    return [
      for (final d in chosen) d.name,
      for (final d in chosen) ...d.localities,
    ];
  }
}

/// PIN code -> state, district, and candidate city names.
///
/// ## Why this is not the backend
///
/// The store has no PIN lookup. `POST /logistics/check-pincode` sounds like one
/// and is not — it answers with a courier and a shipping charge and no location
/// at all — and `/ecommerce/districts` does not exist in any spelling. So the
/// only way to fill a form from a PIN today is India Post's own public service.
///
/// ## What it is used for, and what it is not
///
/// **Convenience only.** Nothing here decides anything: the values it produces
/// are matched against the store's own `states`/`cities` lists and dropped when
/// they do not match, and the customer can overrule every field afterwards. It
/// never touches price, tax, stock or shipping — those come from the server and
/// are not this class's business.
///
/// ## The contract, verified live 2026-08-12
///
///   * `GET https://api.postalpincode.in/pincode/474010`
///   * No key, no auth, no rate limit documented. Plain HTTPS GET.
///   * The body is an **ARRAY with one element**, not an object.
///   * Success: `Status: "Success"`, `PostOffice: [ {Name, Block, District,
///     State, Country, Division, Region, …}, … ]` — 8 rows for 474010, 2 for
///     382415, 21 for 110001.
///   * Unknown PIN: `Status: "Error"`, `Message: "No records found"`,
///     `PostOffice: null`. **HTTP 200 either way**, so the status field is the
///     only failure signal.
///   * Spelling is India Post's, not Botble's: 382415 reports `Block:
///     "Ahmadabad City"` where the store's city row is "Ahmedabad". Match on
///     `District` first and treat everything else as a guess.
///
/// ## Failure is always soft
///
/// Nothing here throws. A timeout, an unknown PIN, a shape that is not what is
/// documented above — all of them are `null`, and the form simply does not
/// autofill. A third-party lookup being down must never block someone from
/// typing their own address.
class PincodeRepository {
  PincodeRepository({Dio? dio, String baseUrl = defaultBaseUrl})
      : _enabled = true,
        _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = baseUrl
      ..connectTimeout = timeout
      ..receiveTimeout = timeout
      ..followRedirects = false
      ..maxRedirects = 0
      ..validateStatus = ((int? s) => s != null && s < 400);
    _dio.options.headers['Accept'] = 'application/json';
    // A third-party host. It must never see the customer's session or the
    // store's API key.
    _dio.options.headers.remove('Authorization');
    _dio.options.headers.remove('X-API-KEY');
  }

  /// A repository that never looks anything up. For widget tests, and the
  /// correct degraded mode rather than a stub — a failed lookup is also null.
  PincodeRepository.offline()
      : _dio = Dio(),
        _enabled = false;

  final Dio _dio;
  final bool _enabled;

  static const String defaultBaseUrl = 'https://api.postalpincode.in';

  /// Short on purpose. This is a convenience: a slow answer is worth abandoning,
  /// and the customer is already typing the next field.
  static const Duration timeout = Duration(seconds: 6);

  /// An Indian PIN is exactly six digits and never starts with 0.
  static final RegExp _pinPattern = RegExp(r'^[1-9][0-9]{5}$');

  /// Answers, keyed by PIN. `null` is cached too — an unknown PIN stays
  /// unknown, and re-asking on every keystroke that revisits it is waste.
  final Map<String, PincodeLocation?> _cache = {};
  final Map<String, Future<PincodeLocation?>> _inflight = {};

  /// Where [pin] is, or null.
  ///
  /// Null means "no answer" for every reason there is: not a PIN, offline, the
  /// service is down, the PIN is unknown, or the body was not the documented
  /// shape. Callers do not need to tell those apart — none of them changes what
  /// the form should do.
  Future<PincodeLocation?> lookup(String pin) {
    final token = pin.trim();
    if (!_enabled || !_pinPattern.hasMatch(token)) {
      return Future<PincodeLocation?>.value();
    }
    if (_cache.containsKey(token)) {
      return Future<PincodeLocation?>.value(_cache[token]);
    }
    final pending = _inflight[token];
    if (pending != null) return pending;

    Future<PincodeLocation?> run() async {
      PincodeLocation? result;
      try {
        final res = await _dio.get<dynamic>('/pincode/$token');
        result = _parse(token, res.data);
      } catch (_) {
        // Deliberately indistinguishable from "unknown PIN".
        result = null;
      }
      _cache[token] = result;
      return result;
    }

    final future = run();
    _inflight[token] = future;
    unawaited(future.whenComplete(() => _inflight.remove(token)));
    return future;
  }

  /// Drops the memory cache. PIN data is effectively static, so this exists for
  /// tests rather than for a refresh affordance.
  void clearCache() {
    _cache.clear();
    _inflight.clear();
  }

  /// `[{Status, Message, PostOffice: [...]}]` -> a location, or null.
  ///
  /// Returns null for every shape that is not that, including the documented
  /// `Status: "Error"` body, which arrives with HTTP 200.
  static PincodeLocation? _parse(String pin, dynamic body) {
    dynamic decoded = body;
    if (decoded is String) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return null;
      }
    }
    // The body is an array with one element. A bare object is accepted too
    // rather than refused — it costs one line and the service is not ours.
    if (decoded is List) decoded = decoded.isEmpty ? null : decoded.first;
    if (decoded is! Map) return null;
    if ('${decoded['Status']}'.toLowerCase() != 'success') return null;

    final offices = decoded['PostOffice'];
    if (offices is! List || offices.isEmpty) return null;

    final first = offices.first;
    final stateName = first is Map ? _string(first['State']) : '';
    if (stateName.isEmpty) return null;

    // Districts in the order received, de-duplicated, each collecting the
    // blocks and office names beneath it.
    final order = <String>[];
    final localities = <String, List<String>>{};
    for (final row in offices) {
      if (row is! Map) continue;
      final district = _string(row['District']);
      if (district.isEmpty) continue;
      if (!localities.containsKey(district)) {
        order.add(district);
        localities[district] = [];
      }
      for (final key in const ['Block', 'Name']) {
        final value = _string(row[key]);
        if (value.isNotEmpty && !localities[district]!.contains(value)) {
          localities[district]!.add(value);
        }
      }
    }
    if (order.isEmpty) return null;

    return PincodeLocation(
      pinCode: pin,
      stateName: stateName,
      districts: [
        for (final name in order)
          PincodeDistrict(name: name, localities: localities[name]!),
      ],
    );
  }

  static String _string(dynamic value) =>
      value == null ? '' : '$value'.trim();
}

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_response.dart';
import '../../core/utils/json_utils.dart';

/// One row of a state or city list.
///
/// [id] is a **String** rather than an int on purpose: the cities list ends
/// with `{"id": "other", "name": "Other"}`, and that sentinel is a real option
/// — it is how a customer whose town is not in the table names it. Typing the
/// id as an int would either crash on that row or force it to be dropped, and
/// dropping it removes the only escape hatch the contract offers.
class GeoOption {
  const GeoOption({required this.id, required this.name});

  /// What gets posted as `state` / `city`. For every real row this is a bare
  /// integer as a string ("11", "574"); for the sentinel it is [otherId].
  final String id;

  /// What the customer reads.
  final String name;

  /// The literal `city` value that means "not in this list".
  ///
  /// Posting it **requires** `other_city` — the server answers 422 "The other
  /// city field is required when city is other." without it.
  static const String otherId = 'other';

  bool get isOther => id == otherId;

  static GeoOption? fromJson(Map<String, dynamic> j) {
    final id = asString(j['id']).trim();
    final name = asString(j['name']).trim();
    // A row with no id or no label cannot be selected or displayed. `id: 0` is
    // not expected from these routes (the old web ones opened with a
    // "Select state…" placeholder) but is refused rather than trusted.
    if (id.isEmpty || id == '0' || name.isEmpty) return null;
    return GeoOption(id: id, name: name);
  }

  @override
  bool operator ==(Object other) =>
      other is GeoOption && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'GeoOption($id, $name)';
}

/// The state and city lists that back the address form's pickers.
///
/// ## Why the app cannot just let people type
///
/// `state` is validated with `exists` on both POST and PUT — verified live:
/// `state: "Gujarat"` is rejected with *"The selected state is invalid."*, and
/// only a bare `states.id` is accepted. So the picker is not a convenience, it
/// is the only way to save an address at all.
///
/// `city` is the opposite: **nothing** validates it. `city: "999999"` is stored
/// and then rendered back as `city_name: "999999"`, and a city id belonging to
/// a different state is accepted too. This class is therefore the only thing
/// standing between a typo and an order the courier cannot deliver, which is
/// why [cities] is always fetched for the selected state rather than filtered
/// from a national list.
///
/// ## Caching
///
/// These are admin-edited reference tables that change essentially never, and
/// there is no ETag to lean on, so the cache is ours: a long TTL in memory,
/// mirrored to disk, with concurrent callers joining one request. 36 states is
/// ~1.1 KB; the largest state's cities are ~18 KB.
///
/// ## Failure
///
/// [states] and [cities] return an **empty list** on any failure rather than
/// throwing. The form turns that into a "could not load" state with a retry;
/// nothing here is allowed to take down the screen that asked.
class GeoRepository {
  GeoRepository({
    ApiClient? client,
    SharedPreferences? prefs,
    String countryCode = defaultCountryCode,
    DateTime Function()? clock,
  })  : _client = client,
        _prefs = prefs,
        _countryCode = countryCode,
        _now = clock ?? DateTime.now;

  /// A resolver that never touches the network: every list comes back empty.
  ///
  /// For widget tests, and the correct degraded mode rather than a stub — an
  /// unreachable lookup renders the same way.
  GeoRepository.offline()
      : _client = null,
        _prefs = null,
        _countryCode = defaultCountryCode,
        _now = DateTime.now;

  final ApiClient? _client;
  final SharedPreferences? _prefs;
  final String _countryCode;
  final DateTime Function() _now;

  /// The store ships in one country and the endpoint ignores this anyway
  /// (`?country=IN` and no parameter return the same 36 rows). Sent so that
  /// adding a second country cannot silently widen the picker.
  static const String defaultCountryCode = 'IN';

  static const Duration successTtl = Duration(days: 30);

  /// A failure is cached briefly too, so a form that retries in a loop cannot
  /// hammer a route that is down.
  static const Duration failureTtl = Duration(minutes: 5);

  /// Cap on persisted per-state city lists. The states index is never evicted.
  static const int maxCachedCityLists = 8;

  static const String cacheKey = 'geo_lists_cache_v2';

  final Map<String, _GeoEntry> _memory = {};
  final Map<String, Future<List<GeoOption>>> _inflight = {};

  /// Every state, in the server's order. Empty when the lookup failed.
  Future<List<GeoOption>> states() => _load(
        'states:$_countryCode',
        ApiEndpoints.states,
        {ApiEndpoints.geoCountryParam: _countryCode},
      );

  /// The cities of one state, including the trailing "Other" sentinel.
  ///
  /// [stateId] must be a bare `states.id`. An empty or non-numeric one short
  /// circuits to an empty list rather than asking the server to filter on
  /// nonsense.
  Future<List<GeoOption>> cities(String stateId) {
    final id = stateId.trim();
    if (id.isEmpty || !isLookupId(id)) {
      return Future<List<GeoOption>>.value(const []);
    }
    return _load(
      'cities:$id',
      ApiEndpoints.cities,
      {ApiEndpoints.geoStateParam: id},
    );
  }

  /// The option whose [GeoOption.id] is [id], or null.
  ///
  /// For seeding a picker from a stored token. Matching is on the id and never
  /// on the name: the name is what the customer reads, the id is what the row
  /// holds.
  static GeoOption? find(List<GeoOption> options, String? id) {
    final token = id?.trim() ?? '';
    if (token.isEmpty) return null;
    for (final option in options) {
      if (option.id == token) return option;
    }
    return null;
  }

  /// Whether [value] is a bare foreign key rather than a name.
  ///
  /// The same test the backend applies (`LocationTrait` branches on
  /// `is_numeric`). Not a length or range check: state ids run 1-36 and city
  /// ids into the thousands, and both grow.
  static bool isLookupId(String value) => _bareInteger.hasMatch(value.trim());

  static final RegExp _bareInteger = RegExp(r'^\d+$');

  /// Drops both the in-memory and the persisted copy. There is no server-side
  /// "reference data changed" signal, so this has to be manual.
  Future<void> clearCache() async {
    _memory.clear();
    _inflight.clear();
    try {
      await _prefs?.remove(cacheKey);
    } catch (_) {
      // A failed cache eviction is not worth surfacing.
    }
  }

  // ---------------------------------------------------------------------------
  // Cache
  // ---------------------------------------------------------------------------

  /// Memory -> disk -> network, with concurrent callers sharing one request.
  Future<List<GeoOption>> _load(
    String key,
    String path,
    Map<String, dynamic> query,
  ) {
    final cached = _memory[key] ?? _readDisk(key);
    if (cached != null && !_expired(cached)) {
      _memory[key] = cached;
      return Future<List<GeoOption>>.value(cached.options);
    }

    final pending = _inflight[key];
    if (pending != null) return pending;

    Future<List<GeoOption>> run() async {
      try {
        final options = await _fetch(path, query);
        // An empty list is the failure signal — it must not be cached for 30
        // days and must not be written to disk.
        final entry = _GeoEntry(
          options,
          _now().millisecondsSinceEpoch,
          ok: options.isNotEmpty,
        );
        _memory[key] = entry;
        if (entry.ok) await _writeDisk(key, entry);
        return options;
      } catch (_) {
        _memory[key] = _GeoEntry(
          const [],
          _now().millisecondsSinceEpoch,
          ok: false,
        );
        return const <GeoOption>[];
      }
    }

    // Assigned before `whenComplete` is registered, so a fetch that completes
    // in the same microtask cannot leave a stale entry behind.
    final future = run();
    _inflight[key] = future;
    unawaited(future.whenComplete(() => _inflight.remove(key)));
    return future;
  }

  bool _expired(_GeoEntry entry) {
    final ttl = entry.ok ? successTtl : failureTtl;
    return _now().millisecondsSinceEpoch - entry.at > ttl.inMilliseconds;
  }

  _GeoEntry? _readDisk(String key) {
    final prefs = _prefs;
    if (prefs == null) return null;
    try {
      final raw = prefs.getString(cacheKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final slot = decoded[key];
      if (slot is! Map) return null;
      final stored = slot['options'];
      if (stored is! List) return null;
      final options = <GeoOption>[];
      for (final row in stored) {
        if (row is! Map) continue;
        final option = GeoOption.fromJson(Map<String, dynamic>.from(row));
        if (option != null) options.add(option);
      }
      if (options.isEmpty) return null;
      return _GeoEntry(options, asInt(slot['at']), ok: true);
    } catch (_) {
      // A corrupt blob is simply a cache miss.
      return null;
    }
  }

  Future<void> _writeDisk(String key, _GeoEntry entry) async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final blob = <String, dynamic>{};
      final raw = prefs.getString(cacheKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (v is Map) blob['$k'] = v;
          });
        }
      }
      blob[key] = {
        'at': entry.at,
        'options': [
          for (final option in entry.options)
            {'id': option.id, 'name': option.name},
        ],
      };
      _evict(blob);
      await prefs.setString(cacheKey, jsonEncode(blob));
    } catch (_) {
      // Persisting is an optimisation; the memory cache already holds the list.
    }
  }

  /// Keeps the states index and the [maxCachedCityLists] most recent city
  /// lists, so a customer who edits addresses across many states cannot grow
  /// the blob without bound.
  static void _evict(Map<String, dynamic> blob) {
    final cityKeys = blob.keys.where((k) => k.startsWith('cities:')).toList()
      ..sort((a, b) {
        final aAt = asInt((blob[a] as Map)['at']);
        final bAt = asInt((blob[b] as Map)['at']);
        return bAt.compareTo(aAt);
      });
    for (final key in cityKeys.skip(maxCachedCityLists)) {
      blob.remove(key);
    }
  }

  // ---------------------------------------------------------------------------
  // Transport
  // ---------------------------------------------------------------------------

  Future<List<GeoOption>> _fetch(
    String path,
    Map<String, dynamic> query,
  ) async {
    final client = _client;
    if (client == null) return const [];
    final res = await client.get(path, query: query);
    // `{error, data:[{id, name}, …], message}`. `unwrapList` yields nothing for
    // any other shape, which `_load` reads as a failure.
    return unwrapList<GeoOption?>(res.data, GeoOption.fromJson)
        .whereType<GeoOption>()
        .toList();
  }
}

class _GeoEntry {
  const _GeoEntry(this.options, this.at, {required this.ok});

  final List<GeoOption> options;

  /// Epoch millis, so it survives a JSON round trip to disk.
  final int at;

  /// False for "the lookup did not answer with anything usable" — cached only
  /// briefly, and never persisted.
  final bool ok;
}

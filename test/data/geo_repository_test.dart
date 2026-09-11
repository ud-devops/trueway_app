import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/repositories/geo_repository.dart';

/// The state and city lists that back the address form's pickers.
///
/// These moved off two anonymous `/ajax/…` **web** routes on the site origin
/// and onto `/ecommerce/states` and `/ecommerce/cities`, which are ordinary
/// `/api/v1` endpoints. That deleted a whole class of hazard — a separate Dio,
/// a 302 to the storefront when `Accept` was wrong, two different envelopes,
/// `country_id`/`state_id` parameter names, and a `{"id":0,"name":"Select…"}`
/// placeholder row — so the tests that guarded those are gone with them.
///
/// What survives is what still bites: the String-id `"other"` sentinel, the
/// cache, and the rule that a failure is an **empty list** and never a throw.

/// `GET /ecommerce/states?country=IN`, captured live and trimmed.
const String _statesBody = '''
{"error":false,"data":[{"id":1,"name":"Andaman and Nicobar Islands"},{"id":11,"name":"Gujarat"},{"id":20,"name":"Madhya Pradesh"}],"message":null}
''';

/// `GET /ecommerce/cities?state=11`, trimmed — note the trailing sentinel whose
/// `id` is the **String** "other".
const String _gujaratCitiesBody = '''
{"error":false,"data":[{"id":571,"name":"Abrama"},{"id":574,"name":"Ahmedabad"},{"id":"other","name":"Other"}],"message":null}
''';

const String _mpCitiesBody = '''
{"error":false,"data":[{"id":1350,"name":"Gwalior"},{"id":"other","name":"Other"}],"message":null}
''';

const String _emptyBody = '{"error":false,"data":[],"message":null}';

// ---------------------------------------------------------------------------
// Fake transport
// ---------------------------------------------------------------------------

class _Canned {
  const _Canned(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responder);

  final FutureOr<_Canned> Function(RequestOptions) responder;

  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final canned = await responder(options);
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

/// Answers the two real routes and 404s anything else, so a wrong path is a
/// visible failure rather than a silent one.
_Canned _liveLike(RequestOptions options) {
  final path = options.path;
  final query = options.uri.queryParameters;
  if (path == '/ecommerce/states') return const _Canned(200, _statesBody);
  if (path == '/ecommerce/cities') {
    return switch (query['state']) {
      '11' => const _Canned(200, _gujaratCitiesBody),
      '20' => const _Canned(200, _mpCitiesBody),
      _ => const _Canned(200, _emptyBody),
    };
  }
  return const _Canned(404, '{}');
}

Future<(GeoRepository, _FakeAdapter, SharedPreferences)> _geo({
  FutureOr<_Canned> Function(RequestOptions)? responder,
  Map<String, Object> initialPrefs = const {},
  bool withPrefs = true,
  DateTime Function()? clock,
}) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(responder ?? _liveLike);
  final client = ApiClient(prefs: prefs, dio: Dio()..httpClientAdapter = adapter);
  return (
    GeoRepository(
      client: client,
      prefs: withPrefs ? prefs : null,
      clock: clock,
    ),
    adapter,
    prefs,
  );
}

List<String> _names(List<GeoOption> options) =>
    [for (final o in options) o.name];

void main() {
  group('the lists', () {
    test('states come back in the server order', () async {
      final (geo, _, _) = await _geo();

      expect(
        _names(await geo.states()),
        ['Andaman and Nicobar Islands', 'Gujarat', 'Madhya Pradesh'],
      );
    });

    test('a state carries the id that must be posted, not the name', () async {
      final (geo, _, _) = await _geo();
      final gujarat = (await geo.states()).firstWhere((s) => s.name == 'Gujarat');

      // `state` is `exists`-validated server-side: posting "Gujarat" answers
      // 422 "The selected state is invalid." Only this value can be saved.
      expect(gujarat.id, '11');
    });

    test('cities are filtered by the state asked for', () async {
      final (geo, adapter, _) = await _geo();

      expect(_names(await geo.cities('20')), ['Gwalior', 'Other']);
      expect(adapter.requests.single.uri.queryParameters['state'], '20');
    });

    test('the request carries the country and the state parameters', () async {
      final (geo, adapter, _) = await _geo();
      await geo.states();
      await geo.cities('11');

      expect(adapter.requests[0].path, '/ecommerce/states');
      expect(adapter.requests[0].uri.queryParameters['country'], 'IN');
      expect(adapter.requests[1].path, '/ecommerce/cities');
      expect(adapter.requests[1].uri.queryParameters['state'], '11');
    });
  });

  group('the "Other" sentinel', () {
    // The old web route had this too, and the old repository **dropped** it as
    // noise. It is not noise: it is the only way a customer whose town is
    // missing from the table can name it, and posting `city: "other"` then
    // requires `other_city`.
    test('survives, String id and all', () async {
      final (geo, _, _) = await _geo();
      final other = (await geo.cities('11')).last;

      expect(other.id, 'other');
      expect(other.isOther, isTrue);
      expect(GeoOption.otherId, 'other');
    });

    test('is the only non-numeric row', () async {
      final (geo, _, _) = await _geo();
      final cities = await geo.cities('11');

      expect(
        cities.where((c) => !GeoRepository.isLookupId(c.id)).toList(),
        [const GeoOption(id: 'other', name: 'Other')],
      );
    });
  });

  group('a bad row is refused rather than shown', () {
    test('a row with no name is dropped', () async {
      final (geo, _, _) = await _geo(
        responder: (_) => const _Canned(
          200,
          '{"data":[{"id":11,"name":""},{"id":20,"name":"Madhya Pradesh"}]}',
        ),
      );

      expect(_names(await geo.states()), ['Madhya Pradesh']);
    });

    // The old web routes opened with `{"id":0,"name":"Select state…"}`. These
    // do not, but a UI placeholder is not a state either way.
    test('an id of 0 is dropped', () async {
      final (geo, _, _) = await _geo(
        responder: (_) => const _Canned(
          200,
          '{"data":[{"id":0,"name":"Select state..."},{"id":11,"name":"Gujarat"}]}',
        ),
      );

      expect(_names(await geo.states()), ['Gujarat']);
    });
  });

  group('failure is an empty list, never a throw', () {
    test('a transport error', () async {
      final (geo, _, _) = await _geo(
        responder: (_) => throw StateError('offline'),
      );

      expect(await geo.states(), isEmpty);
    });

    test('a 500', () async {
      final (geo, _, _) = await _geo(
        responder: (_) => const _Canned(500, '{"message":"Server Error"}'),
      );

      expect(await geo.states(), isEmpty);
    });

    test('HTML in a 200', () async {
      final (geo, _, _) = await _geo(
        responder: (_) => const _Canned(200, '<!doctype html><html></html>'),
      );

      expect(await geo.states(), isEmpty);
    });

    test('an error:true envelope', () async {
      final (geo, _, _) = await _geo(
        responder: (_) => const _Canned(
          200,
          '{"error":true,"data":null,"message":"Nope"}',
        ),
      );

      expect(await geo.states(), isEmpty);
    });

    test('a state id the server does not know', () async {
      final (geo, _, _) = await _geo();

      expect(await geo.cities('999999'), isEmpty);
    });

    // Asking the server to filter on nonsense returns the whole table on some
    // Botble routes. Not asking at all is cheaper and cannot be misread.
    test('a non-numeric state id never reaches the network', () async {
      final (geo, adapter, _) = await _geo();

      expect(await geo.cities('Gujarat'), isEmpty);
      expect(await geo.cities(''), isEmpty);
      expect(adapter.requests, isEmpty);
    });
  });

  group('the offline repository', () {
    test('answers empty without a client', () async {
      final geo = GeoRepository.offline();

      expect(await geo.states(), isEmpty);
      expect(await geo.cities('11'), isEmpty);
    });
  });

  group('the cache', () {
    test('a repeated read is answered from memory', () async {
      final (geo, adapter, _) = await _geo();

      await geo.states();
      await geo.states();
      await geo.states();

      expect(adapter.requests, hasLength(1));
    });

    test('each state gets its own city list', () async {
      final (geo, adapter, _) = await _geo();

      await geo.cities('11');
      await geo.cities('20');
      await geo.cities('11');

      expect(adapter.requests, hasLength(2));
    });

    test('concurrent callers share one in-flight request', () async {
      final completer = Completer<_Canned>();
      final (geo, adapter, _) = await _geo(responder: (_) => completer.future);

      final a = geo.states();
      final b = geo.states();
      final c = geo.states();
      completer.complete(const _Canned(200, _statesBody));

      expect(_names(await a), hasLength(3));
      expect(await b, await a);
      expect(await c, await a);
      expect(adapter.requests, hasLength(1));
    });

    test('a failure is not retried immediately', () async {
      final (geo, adapter, _) = await _geo(
        responder: (_) => const _Canned(500, '{}'),
      );

      await geo.states();
      await geo.states();

      // Six pickers opened in a row must not become six requests to a route
      // that is down.
      expect(adapter.requests, hasLength(1));
    });

    test('a failure IS retried once its short TTL has passed', () async {
      var now = DateTime(2026, 8, 12, 10);
      var fail = true;
      final (geo, adapter, _) = await _geo(
        clock: () => now,
        responder: (_) =>
            fail ? const _Canned(500, '{}') : const _Canned(200, _statesBody),
      );

      expect(await geo.states(), isEmpty);
      now = now.add(GeoRepository.failureTtl + const Duration(seconds: 1));
      fail = false;

      expect(_names(await geo.states()), contains('Gujarat'));
      expect(adapter.requests, hasLength(2));
    });

    test('a success survives past the failure TTL', () async {
      var now = DateTime(2026, 8, 12, 10);
      final (geo, adapter, _) = await _geo(clock: () => now);

      await geo.states();
      now = now.add(GeoRepository.failureTtl * 2);
      await geo.states();

      expect(adapter.requests, hasLength(1));
    });

    test('a success is refetched once the long TTL has passed', () async {
      var now = DateTime(2026, 8, 12, 10);
      final (geo, adapter, _) = await _geo(clock: () => now);

      await geo.states();
      now = now.add(GeoRepository.successTtl + const Duration(minutes: 1));
      await geo.states();

      expect(adapter.requests, hasLength(2));
    });

    test('clearCache forces the next read back onto the network', () async {
      final (geo, adapter, _) = await _geo();

      await geo.states();
      await geo.clearCache();
      await geo.states();

      expect(adapter.requests, hasLength(2));
    });
  });

  group('the disk cache survives a new instance', () {
    test('a second repository answers without a request', () async {
      final (first, _, prefs) = await _geo();
      await first.states();
      await first.cities('11');

      final adapter = _FakeAdapter(_liveLike);
      final second = GeoRepository(
        client: ApiClient(
          prefs: prefs,
          dio: Dio()..httpClientAdapter = adapter,
        ),
        prefs: prefs,
      );

      expect(_names(await second.states()), contains('Gujarat'));
      expect(_names(await second.cities('11')), contains('Ahmedabad'));
      expect(adapter.requests, isEmpty);
    });

    // The sentinel is what a customer with an unlisted town needs, and a cache
    // that quietly dropped it would remove the escape hatch on the second run
    // only — the worst possible shape for a bug.
    test('the "Other" sentinel round-trips through disk', () async {
      final (first, _, prefs) = await _geo();
      await first.cities('11');

      final adapter = _FakeAdapter(_liveLike);
      final second = GeoRepository(
        client: ApiClient(
          prefs: prefs,
          dio: Dio()..httpClientAdapter = adapter,
        ),
        prefs: prefs,
      );

      expect((await second.cities('11')).last.isOther, isTrue);
      expect(adapter.requests, isEmpty);
    });

    test('a failure is never persisted', () async {
      final (geo, _, prefs) = await _geo(
        responder: (_) => const _Canned(500, '{}'),
      );
      await geo.states();

      expect(prefs.getString(GeoRepository.cacheKey), isNull);
    });

    test('a corrupt blob is a cache miss, not a crash', () async {
      final (geo, adapter, _) = await _geo(
        initialPrefs: {GeoRepository.cacheKey: 'not json at all'},
      );

      expect(_names(await geo.states()), contains('Gujarat'));
      expect(adapter.requests, hasLength(1));
    });

    test('city lists are evicted so the blob cannot grow forever', () async {
      final (geo, _, prefs) = await _geo(
        responder: (_) => const _Canned(200, _gujaratCitiesBody),
      );

      for (var id = 1; id <= GeoRepository.maxCachedCityLists + 4; id++) {
        await geo.cities('$id');
      }

      final blob = jsonDecode(prefs.getString(GeoRepository.cacheKey)!) as Map;
      final cityKeys = blob.keys.where((k) => '$k'.startsWith('cities:'));
      expect(cityKeys, hasLength(GeoRepository.maxCachedCityLists));
    });

    test('works with no SharedPreferences at all', () async {
      final (geo, adapter, _) = await _geo(withPrefs: false);

      expect(_names(await geo.states()), contains('Gujarat'));
      // Still cached in memory, just not persisted.
      await geo.states();
      expect(adapter.requests, hasLength(1));
    });
  });

  group('find', () {
    test('matches on the id, never on the name', () async {
      final (geo, _, _) = await _geo();
      final states = await geo.states();

      expect(GeoRepository.find(states, '11')?.name, 'Gujarat');
      expect(GeoRepository.find(states, ' 11 ')?.name, 'Gujarat');
      expect(GeoRepository.find(states, 'Gujarat'), isNull);
      expect(GeoRepository.find(states, null), isNull);
      expect(GeoRepository.find(states, ''), isNull);
    });
  });

  group('isLookupId', () {
    test('matches bare integers only', () {
      expect(GeoRepository.isLookupId('11'), isTrue);
      expect(GeoRepository.isLookupId(' 574 '), isTrue);
      expect(GeoRepository.isLookupId('other'), isFalse);
      expect(GeoRepository.isLookupId('Sector 12'), isFalse);
      expect(GeoRepository.isLookupId(''), isFalse);
      expect(GeoRepository.isLookupId('11a'), isFalse);
    });
  });
}

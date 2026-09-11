import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/repositories/pincode_repository.dart';

/// PIN code -> state, district, candidate city names, from India Post.
///
/// The store has no lookup of its own: `POST /logistics/check-pincode` answers
/// with a courier and a shipping charge and no location at all, and
/// `/ecommerce/districts` is a 404 in every spelling. So this is a third-party
/// service, and the rule for third-party services is that **nothing here may
/// throw and nothing here may decide anything** — it fills a form in, and every
/// value it produces is matched against the store's own lists before use.

/// `GET /pincode/474010`, captured live and trimmed from 8 offices to 3.
///
/// Note the envelope: an **array with one element**, not an object.
const String _gwalior = '''
[{"Message":"Number of pincode(s) found:3","Status":"Success","PostOffice":[
{"Name":"Jigsoli","Block":"Gwalior","District":"Gwalior","State":"Madhya Pradesh","Country":"India"},
{"Name":"Kuleth","Block":"Gwalior","District":"Gwalior","State":"Madhya Pradesh","Country":"India"},
{"Name":"Laxmiganj  Mandi","Block":"Gird","District":"Gwalior","State":"Madhya Pradesh","Country":"India"}]}]
''';

/// `GET /pincode/382415`. India Post spells the block "Ahmadabad City" where
/// the store's city row is "Ahmedabad" — the reason the district is the first
/// candidate and the block only a long shot.
const String _ahmedabad = '''
[{"Message":"Number of pincode(s) found:2","Status":"Success","PostOffice":[
{"Name":"Odhav","Block":"Ahmadabad City","District":"Ahmedabad","State":"Gujarat","Country":"India"},
{"Name":"Odhav Industrial Estate","Block":"Ahmadabad City","District":"Ahmedabad","State":"Gujarat","Country":"India"}]}]
''';

/// `GET /pincode/110001` — **two** districts under one PIN.
const String _delhi = '''
[{"Message":"Number of pincode(s) found:3","Status":"Success","PostOffice":[
{"Name":"Baroda House","Block":"New Delhi","District":"Central Delhi","State":"Delhi","Country":"India"},
{"Name":"Bengali Market","Block":"New Delhi","District":"Central Delhi","State":"Delhi","Country":"India"},
{"Name":"Connaught Place","Block":"New Delhi","District":"New Delhi","State":"Delhi","Country":"India"}]}]
''';

/// An unknown PIN. **HTTP 200**, so the `Status` field is the only signal.
const String _notFound = '''
[{"Message":"No records found","Status":"Error","PostOffice":null}]
''';

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

_Canned _liveLike(RequestOptions options) => switch (options.path) {
      '/pincode/474010' => const _Canned(200, _gwalior),
      '/pincode/382415' => const _Canned(200, _ahmedabad),
      '/pincode/110001' => const _Canned(200, _delhi),
      _ => const _Canned(200, _notFound),
    };

(PincodeRepository, _FakeAdapter) _repo([
  FutureOr<_Canned> Function(RequestOptions)? responder,
]) {
  final adapter = _FakeAdapter(responder ?? _liveLike);
  return (
    PincodeRepository(dio: Dio()..httpClientAdapter = adapter),
    adapter,
  );
}

void main() {
  group('a known PIN', () {
    test('yields the state and the district', () async {
      final (repo, _) = _repo();
      final place = (await repo.lookup('474010'))!;

      expect(place.pinCode, '474010');
      expect(place.stateName, 'Madhya Pradesh');
      expect(place.districts.map((d) => d.name), ['Gwalior']);
      expect(place.soleDistrict?.name, 'Gwalior');
    });

    test('is asked for on the documented path', () async {
      final (repo, adapter) = _repo();
      await repo.lookup('474010');

      expect(adapter.requests.single.path, '/pincode/474010');
      expect(adapter.requests.single.method, 'GET');
    });

    // A third-party host must never see the store's key or the customer's
    // session.
    test('carries no credentials', () async {
      final (repo, adapter) = _repo();
      await repo.lookup('474010');

      final headers = adapter.requests.single.headers;
      expect(headers.containsKey('Authorization'), isFalse);
      expect(headers.containsKey('X-API-KEY'), isFalse);
    });

    test('trims whitespace before asking', () async {
      final (repo, adapter) = _repo();

      expect((await repo.lookup(' 474010 '))?.stateName, 'Madhya Pradesh');
      expect(adapter.requests.single.path, '/pincode/474010');
    });
  });

  group('city candidates', () {
    // Probed against the live lists: `District` resolved for all three test
    // PINs while `Block` did not. Ordering the district first is what makes the
    // Ahmedabad case work at all.
    test('put the district first', () async {
      final (repo, _) = _repo();
      final place = (await repo.lookup('382415'))!;

      expect(place.cityCandidates().first, 'Ahmedabad');
      expect(place.cityCandidates(), contains('Ahmadabad City'));
    });

    test('include the blocks and office names as fallbacks', () async {
      final (repo, _) = _repo();
      final place = (await repo.lookup('474010'))!;

      expect(
        place.cityCandidates(),
        containsAll(['Gwalior', 'Gird', 'Jigsoli', 'Kuleth']),
      );
    });

    test('are de-duplicated', () async {
      final (repo, _) = _repo();
      final candidates = (await repo.lookup('382415'))!.cityCandidates();

      expect(candidates.length, candidates.toSet().length);
    });

    // Once a district is chosen, the other district's localities are not
    // candidates — they are a different place.
    test('narrow to one district when one is named', () async {
      final (repo, _) = _repo();
      final place = (await repo.lookup('110001'))!;

      expect(place.cityCandidates(district: 'New Delhi').first, 'New Delhi');
      expect(
        place.cityCandidates(district: 'Central Delhi').first,
        'Central Delhi',
      );
    });

    test('an unknown district name narrows to nothing', () async {
      final (repo, _) = _repo();
      final place = (await repo.lookup('110001'))!;

      expect(place.cityCandidates(district: 'Nowhere'), isEmpty);
    });
  });

  group('more than one district', () {
    // 110001 is the case that makes a district *picker* necessary. Filling one
    // in silently would be a coin flip printed on a shipping label.
    test('are all kept, in the order received', () async {
      final (repo, _) = _repo();
      final place = (await repo.lookup('110001'))!;

      expect(
        place.districts.map((d) => d.name),
        ['Central Delhi', 'New Delhi'],
      );
      expect(place.soleDistrict, isNull);
    });
  });

  group('no answer', () {
    Future<void> expectNull(
      FutureOr<_Canned> Function(RequestOptions)? responder,
      String pin,
    ) async {
      final (repo, _) = _repo(responder);
      expect(await repo.lookup(pin), isNull);
    }

    // The documented not-found body, which arrives with HTTP 200.
    test('an unknown PIN', () => expectNull(null, '999998'));

    test('a transport error', () async {
      await expectNull((_) => throw StateError('offline'), '474010');
    });

    test('a 500', () async {
      await expectNull((_) => const _Canned(500, 'boom'), '474010');
    });

    test('HTML instead of JSON', () async {
      await expectNull((_) => const _Canned(200, '<html></html>'), '474010');
    });

    test('an empty PostOffice array', () async {
      await expectNull(
        (_) => const _Canned(200, '[{"Status":"Success","PostOffice":[]}]'),
        '474010',
      );
    });

    test('rows with no district', () async {
      await expectNull(
        (_) => const _Canned(
          200,
          '[{"Status":"Success","PostOffice":[{"State":"Gujarat"}]}]',
        ),
        '474010',
      );
    });

    test('rows with no state', () async {
      await expectNull(
        (_) => const _Canned(
          200,
          '[{"Status":"Success","PostOffice":[{"District":"Gwalior"}]}]',
        ),
        '474010',
      );
    });

    group('and no request at all for', () {
      Future<void> expectNoRequest(String pin) async {
        final (repo, adapter) = _repo();

        expect(await repo.lookup(pin), isNull);
        expect(adapter.requests, isEmpty);
      }

      test('too few digits', () => expectNoRequest('4740'));
      test('too many digits', () => expectNoRequest('4740101'));
      test('a leading zero', () => expectNoRequest('047401'));
      test('letters', () => expectNoRequest('47401a'));
      test('nothing', () => expectNoRequest(''));
    });

    test('the offline repository never asks', () async {
      final repo = PincodeRepository.offline();

      expect(await repo.lookup('474010'), isNull);
    });
  });

  group('the cache', () {
    test('a repeated lookup is answered from memory', () async {
      final (repo, adapter) = _repo();

      await repo.lookup('474010');
      await repo.lookup('474010');
      await repo.lookup('474010');

      expect(adapter.requests, hasLength(1));
    });

    // Editing a PIN back and forth is ordinary. Re-asking about a PIN already
    // known to be unknown is waste.
    test('a miss is cached too', () async {
      final (repo, adapter) = _repo();

      expect(await repo.lookup('999998'), isNull);
      expect(await repo.lookup('999998'), isNull);
      expect(adapter.requests, hasLength(1));
    });

    test('concurrent callers share one request', () async {
      final completer = Completer<_Canned>();
      final (repo, adapter) = _repo((_) => completer.future);

      final a = repo.lookup('474010');
      final b = repo.lookup('474010');
      completer.complete(const _Canned(200, _gwalior));

      expect((await a)?.stateName, 'Madhya Pradesh');
      expect((await b)?.stateName, 'Madhya Pradesh');
      expect(adapter.requests, hasLength(1));
    });

    test('clearCache forces the next lookup back onto the network', () async {
      final (repo, adapter) = _repo();

      await repo.lookup('474010');
      repo.clearCache();
      await repo.lookup('474010');

      expect(adapter.requests, hasLength(2));
    });
  });
}

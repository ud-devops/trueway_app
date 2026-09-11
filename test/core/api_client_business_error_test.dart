import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';

/// This backend splits failures across two channels, and only one of them is
/// visible to Dio:
///
///   HTTP 422 -> {"message":"The selected product id is invalid.", "errors":{...}}
///   HTTP 200 -> {"error":true,"data":null,"message":"Maximum quantity is 93!"}
///
/// Both bodies below are copied verbatim from live probes against
/// dev.truewayerp.com. The 200 case is the dangerous one: Dio resolves it
/// normally, so before ApiClient checked the envelope an out-of-stock add
/// looked exactly like a successful one.
class _Canned {
  const _Canned(this.statusCode, this.body);
  final int statusCode;
  final Object body;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);

  final Map<String, _Canned> responses;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final canned = responses[options.path] ??
        const _Canned(404, {'message': 'no canned response'});
    return ResponseBody.fromString(
      jsonEncode(canned.body),
      canned.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<ApiClient> _client(Map<String, _Canned> responses) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final dio = Dio()..httpClientAdapter = _FakeAdapter(responses);
  return ApiClient(prefs: prefs, dio: dio);
}

void main() {
  group('HTTP 200 carrying error:true', () {
    test('throws instead of resolving as success', () async {
      final api = await _client({
        '/ecommerce/cart': const _Canned(200, {
          'error': true,
          'data': null,
          'message': 'Maximum quantity is 93!',
        }),
      });

      await expectLater(
        api.post('/ecommerce/cart', data: {'product_id': 118, 'qty': 99999}),
        throwsA(isA<ApiException>()),
      );
    });

    test("shows the server's own sentence verbatim", () async {
      final api = await _client({
        '/ecommerce/cart': const _Canned(200, {
          'error': true,
          'data': null,
          'message': 'Maximum quantity is 93!',
        }),
      });

      try {
        await api.post('/ecommerce/cart', data: {'product_id': 118, 'qty': 99999});
        fail('expected an ApiException');
      } on ApiException catch (e) {
        // The number in that sentence is the actual remaining stock — it is the
        // single most useful thing we can tell the customer, so it must survive
        // unparaphrased.
        expect(e.message, 'Maximum quantity is 93!');
        expect(e.serverMessage, 'Maximum quantity is 93!');
        expect(e.isServerAuthored, isTrue);
        expect(e.kind, ApiErrorKind.businessRule);
        expect(e.statusCode, 200);
      }
    });

    test('is not retryable — the constraint will not change on a retry', () async {
      final api = await _client({
        '/ecommerce/cart': const _Canned(200, {
          'error': true,
          'data': null,
          'message': 'Product is out of stock!',
        }),
      });

      try {
        await api.post('/ecommerce/cart', data: {'product_id': 118, 'qty': 1});
        fail('expected an ApiException');
      } on ApiException catch (e) {
        expect(e.isRetryable, isFalse);
      }
    });
  });

  group('responses that must still succeed', () {
    test('error:false is a success envelope, not a failure', () async {
      final api = await _client({
        '/ecommerce/products': const _Canned(200, {
          'error': false,
          'data': [
            {'id': 118},
          ],
          'message': null,
        }),
      });

      final res = await api.get('/ecommerce/products');
      expect(res.statusCode, 200);
      expect((res.data as Map)['data'], isA<List<dynamic>>());
    });

    // POST /ecommerce/cart returns a bare object with no envelope at all.
    // Absence of an `error` key must never be read as failure.
    test('a bare object with no error key passes through', () async {
      final api = await _client({
        '/ecommerce/cart': const _Canned(200, {
          'id': '719c661a-6c80-423e-bac4-c0a97388756c',
          'count': 1,
          'cart_items': <String, dynamic>{},
        }),
      });

      final res = await api.post('/ecommerce/cart', data: {'product_id': 118, 'qty': 1});
      expect((res.data as Map)['id'], '719c661a-6c80-423e-bac4-c0a97388756c');
    });

    test('a list body passes through', () async {
      final api = await _client({
        '/ecommerce/countries': const _Canned(200, [
          {'name': 'India', 'code': 'IN'},
        ]),
      });

      final res = await api.get('/ecommerce/countries');
      expect(res.data, isA<List<dynamic>>());
    });
  });

  group('the 422 channel is unchanged', () {
    test('validation failures still map to validation, not businessRule', () async {
      final api = await _client({
        '/ecommerce/cart': const _Canned(422, {
          'message': 'The selected product id is invalid.',
          'errors': {
            'product_id': ['The selected product id is invalid.'],
          },
        }),
      });

      try {
        await api.post('/ecommerce/cart', data: {'product_id': 999999, 'qty': 1});
        fail('expected an ApiException');
      } on ApiException catch (e) {
        expect(e.kind, ApiErrorKind.validation);
        expect(e.statusCode, 422);
        expect(e.firstFieldError, 'The selected product id is invalid.');
      }
    });
  });

  group('declaresFailure', () {
    test('only a literal true counts', () {
      expect(ApiException.declaresFailure({'error': true}), isTrue);
      expect(ApiException.declaresFailure({'error': false}), isFalse);
      expect(ApiException.declaresFailure({'id': 'abc'}), isFalse);
      expect(ApiException.declaresFailure(null), isFalse);
      expect(ApiException.declaresFailure(<dynamic>[]), isFalse);
      expect(ApiException.declaresFailure('error'), isFalse);
    });

    // On the 401 branch this API sets `error` to the STRING "Unauthorized"
    // rather than a bool. That body only ever arrives with a 401, where Dio
    // throws first — but the predicate must not treat a truthy string as a
    // failure flag regardless, or any future 2xx carrying a string `error`
    // field would be misread.
    test('the string "Unauthorized" is not treated as the failure flag', () {
      expect(
        ApiException.declaresFailure({
          'message': 'Invalid or missing API key. Please provide a valid X-API-KEY header.',
          'error': 'Unauthorized',
        }),
        isFalse,
      );
    });
  });
}

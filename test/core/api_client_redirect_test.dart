import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';

/// Redirects, which this API uses to say "unauthorized" without saying it.
///
/// Verified live against dev.truewayerp.com on the day this was written:
///
/// ```
/// GET /api/v1/ecommerce/orders   (dead bearer, X-API-KEY, NO Accept)
///   -> 302 Found, Location: https://dev.truewayerp.com/login
/// GET /api/v1/ecommerce/orders   (dead bearer, X-API-KEY, Accept: application/json)
///   -> 401
/// GET /api/v1/ecommerce/products/          (Accept: application/json)
///   -> 301 Moved Permanently, Location: .../ecommerce/products
/// ```
///
/// Dio defaults to `followRedirects: true` / `maxRedirects: 5`, and `dart:io`
/// rewrites a 302 on a POST into a GET of the target. Left alone, the first case
/// resolves as a **200 carrying the storefront's login HTML**, which every
/// parser in this app reads as a malformed success — and the third shows the
/// `Accept` header is not, on its own, a defence.
///
/// So `ApiClient` never follows one. These tests pin that at the wire: what the
/// adapter is told, what survives a caller-supplied `Options`, and what the
/// customer is told when it happens.

// ---------------------------------------------------------------------------
// Transport fake
// ---------------------------------------------------------------------------

/// The body Laravel actually returns with a redirect — an HTML shim, not JSON.
const _redirectHtml = '<!DOCTYPE html>\n<html>\n<head>'
    '<meta http-equiv="refresh" content="0;url=\'https://dev.truewayerp.com/login\'" />'
    '</head><body>Redirecting to '
    '<a href="https://dev.truewayerp.com/login">https://dev.truewayerp.com/login</a>.'
    '</body></html>';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this.statusCode = 302, this.location = '/login'});

  final int statusCode;
  final String? location;

  /// Every request as it reached the adapter — i.e. after `Options.compose`
  /// merged the caller's options into the base ones, and after the request
  /// interceptor ran. This is the only place the truth about a header lives.
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (statusCode >= 300 && statusCode < 400) {
      return ResponseBody.fromString(
        _redirectHtml,
        statusCode,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
          if (location != null) 'location': [location!],
        },
      );
    }
    return ResponseBody.fromString(
      '{"error":false,"data":[],"message":null}',
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

typedef _Host = ({ApiClient api, _FakeAdapter adapter});

Future<_Host> _host({
  int statusCode = 302,
  String? location = '/login',
  String? token,
}) async {
  SharedPreferences.setMockInitialValues({
    if (token != null) 'auth_token': token,
  });
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(statusCode: statusCode, location: location);
  final api = ApiClient(
    prefs: prefs,
    dio: Dio()..httpClientAdapter = adapter,
  );
  return (api: api, adapter: adapter);
}

Future<ApiException> _capture(Future<void> Function() call) async {
  try {
    await call();
  } on ApiException catch (e) {
    return e;
  }
  fail('expected an ApiException');
}

void main() {
  // -------------------------------------------------------------------------
  group('the adapter is told not to follow', () {
    test('every request carries followRedirects: false, maxRedirects: 0',
        () async {
      final h = await _host(statusCode: 200);

      await h.api.get('/ecommerce/products');
      await h.api.post('/ecommerce/cart', data: {'product_id': 118});
      await h.api.put('/ecommerce/cart/c1', data: {'qty': 2});
      await h.api.delete('/ecommerce/cart/c1');

      expect(h.adapter.requests, hasLength(4));
      for (final request in h.adapter.requests) {
        expect(request.followRedirects, isFalse, reason: request.path);
        expect(request.maxRedirects, 0, reason: request.path);
      }
    });

    // `Options.compose` takes the caller's `followRedirects` before the base
    // one, so without the request interceptor a single call could re-open the
    // hole for itself. Not following redirects is a property of this API.
    test('a caller-supplied Options cannot turn following back on', () async {
      final h = await _host(statusCode: 200);

      await h.api.post(
        '/ecommerce/cart',
        data: {'product_id': 118},
        options: Options(followRedirects: true, maxRedirects: 5),
      );

      expect(h.adapter.requests.single.followRedirects, isFalse);
      expect(h.adapter.requests.single.maxRedirects, 0);
    });
  });

  // -------------------------------------------------------------------------
  group('Accept: application/json survives', () {
    // dio-5.11.0 `Options.compose`:
    //   final headers = caseInsensitiveKeyMap(baseOpt.headers);
    //   if (this.headers != null) headers.addAll(this.headers!);
    // i.e. the base headers are the floor and the caller's are layered on top —
    // so Accept is not dropped by passing an Options. Pinned here because the
    // whole 302-instead-of-401 behaviour hangs off that one header.
    test('a caller-supplied Options does not drop it', () async {
      final h = await _host(statusCode: 200);

      await h.api.post(
        '/ecommerce/checkout/cart/c1',
        data: {'x': 1},
        options: Options(
          sendTimeout: const Duration(seconds: 90),
          receiveTimeout: const Duration(seconds: 90),
        ),
      );

      final request = h.adapter.requests.single;
      expect(request.headers['Accept'], 'application/json');
      expect(request.receiveTimeout, const Duration(seconds: 90));
    });

    test('a caller-supplied Options with its own headers does not drop it',
        () async {
      final h = await _host(statusCode: 200);

      await h.api.post(
        '/ecommerce/orders/returns/upload',
        data: {'x': 1},
        options: Options(headers: {'X-Trace': 'abc'}),
      );

      final request = h.adapter.requests.single;
      expect(request.headers['Accept'], 'application/json');
      expect(request.headers['X-Trace'], 'abc');
      expect(request.headers['X-API-KEY'], isNotNull);
    });

    // `OrderRepository.uploadReturnMedia` and `ReviewRepository.create` both
    // post one of these. FormData sets a multipart Content-Type; it must not
    // cost the request its Accept.
    test('a FormData body does not drop it', () async {
      final h = await _host(statusCode: 200);

      await h.api.post(
        '/ecommerce/orders/returns/upload',
        data: FormData.fromMap({'type': 'image'}),
      );

      final request = h.adapter.requests.single;
      expect(request.headers['Accept'], 'application/json');
      expect(
        request.headers[Headers.contentTypeHeader].toString(),
        contains('multipart/form-data'),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('an unfollowed redirect', () {
    test('is an error, never a 200 carrying the login page', () async {
      final h = await _host();

      final error = await _capture(() => h.api.get('/ecommerce/orders'));

      expect(error.statusCode, 302);
      expect(error.kind, ApiErrorKind.unauthorized);
    });

    test('asks the customer to sign in rather than showing them HTML', () async {
      final h = await _host();

      final error = await _capture(() => h.api.get('/ecommerce/orders'));

      // The body is a `<!DOCTYPE html>` shim. `isDeveloperFacing` catches it, so
      // what the customer reads is the kind's own heading.
      expect(error.message, 'Please sign in again');
      expect(error.message, isNot(contains('<')));
      expect(error.serverMessage, isNull);
    });

    // Retrying walks into the same redirect. `unknown` would have been
    // retryable, which is why the 3xx branch is mapped explicitly.
    test('is not retryable', () async {
      final h = await _host();

      final error = await _capture(() => h.api.get('/ecommerce/orders'));

      expect(error.isRetryable, isFalse);
      expect(error.isUnauthorized, isTrue);
    });

    test('keeps the Location header for the log', () async {
      final h = await _host(location: 'https://dev.truewayerp.com/login');

      final error = await _capture(() => h.api.get('/ecommerce/orders'));

      expect(
        error.developerDetail,
        contains('redirect not followed -> https://dev.truewayerp.com/login'),
      );
    });

    // POST is the dangerous verb: `dart:io` turns a 302 on a POST into a GET of
    // the target, so a followed redirect would answer "did the order go
    // through?" with the login page, HTTP 200.
    test('a POST is refused exactly like a GET', () async {
      final h = await _host();

      final error = await _capture(
        () => h.api.post('/ecommerce/cart', data: {'product_id': 118}),
      );

      expect(error.kind, ApiErrorKind.unauthorized);
      expect(h.adapter.requests.single.method, 'POST');
    });

    // Laravel canonicalises a trailing slash with a 301 whether or not the
    // request negotiated JSON, so the Accept header alone would not have closed
    // this. Verified live: GET /api/v1/ecommerce/products/ -> 301.
    test('a 301 is refused too, Accept header or not', () async {
      final h = await _host(
        statusCode: 301,
        location: '/api/v1/ecommerce/products',
      );

      final error = await _capture(() => h.api.get('/ecommerce/products/'));

      expect(h.adapter.requests.single.headers['Accept'], 'application/json');
      expect(error.statusCode, 301);
      expect(error.kind, ApiErrorKind.unauthorized);
    });
  });

  // -------------------------------------------------------------------------
  group('onUnauthorized', () {
    test('fires when the redirected request carried a token', () async {
      final h = await _host(token: '42|livetoken');
      var signedOut = 0;
      h.api.onUnauthorized = () => signedOut++;

      await _capture(() => h.api.get('/ecommerce/orders'));

      expect(signedOut, 1, reason: 'a dead session must end, not loop');
    });

    // The API key alone can trigger a redirect and there is no session to end;
    // signing out someone who was never signed in only loses their state. Same
    // rule the 401 branch already applies.
    test('does not fire for an anonymous request', () async {
      final h = await _host();
      var signedOut = 0;
      h.api.onUnauthorized = () => signedOut++;

      await _capture(() => h.api.get('/ecommerce/products'));

      expect(signedOut, 0);
    });

    test('still fires for the plain 401 it also answers with', () async {
      SharedPreferences.setMockInitialValues({'auth_token': '42|livetoken'});
      final prefs = await SharedPreferences.getInstance();
      final api = ApiClient(
        prefs: prefs,
        dio: Dio()..httpClientAdapter = _FakeAdapter(statusCode: 401),
      );
      var signedOut = 0;
      api.onUnauthorized = () => signedOut++;

      await _capture(() => api.get('/ecommerce/orders'));

      expect(signedOut, 1);
    });
  });

  // -------------------------------------------------------------------------
  group('nothing else changed', () {
    test('a 2xx still resolves', () async {
      final h = await _host(statusCode: 200);

      final res = await h.api.get('/ecommerce/products');

      expect(res.statusCode, 200);
      expect((res.data as Map)['error'], isFalse);
    });

    test('a 4xx still throws with its own kind', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = ApiClient(
        prefs: prefs,
        dio: Dio()..httpClientAdapter = _FakeAdapter(statusCode: 404),
      );

      final error = await _capture(() => api.get('/ecommerce/products/9999'));

      expect(error.kind, ApiErrorKind.notFound);
      expect(error.statusCode, 404);
    });

    test('a 5xx still throws with its own kind', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = ApiClient(
        prefs: prefs,
        dio: Dio()..httpClientAdapter = _FakeAdapter(statusCode: 500),
      );

      final error = await _capture(() => api.get('/ecommerce/products'));

      expect(error.kind, ApiErrorKind.server);
      expect(error.isRetryable, isTrue);
    });
  });
}

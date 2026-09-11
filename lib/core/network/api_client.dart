import 'dart:developer' as dev;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../errors/api_exception.dart';
import '../errors/error_presenter.dart';

/// Thin Dio wrapper: injects the API key + bearer token, normalizes errors,
/// and exposes typed helpers. All datasources go through this.
class ApiClient {
  /// [prefs] is the instance already resolved in `main()`. It is required so
  /// the auth token can be read synchronously on the request path — this used
  /// to `await SharedPreferences.getInstance()` on *every* request.
  ApiClient({required SharedPreferences prefs, Dio? dio})
      : _prefs = prefs,
        _dio = dio ?? Dio() {
    _dio
      ..options.baseUrl = AppConfig.apiBase
      ..options.connectTimeout = AppConfig.connectTimeout
      ..options.receiveTimeout = AppConfig.receiveTimeout
      ..options.headers['Accept'] = 'application/json'
      // ---- redirects are never followed. See [_redirectFailure]. ----------
      //
      // Dio ships `followRedirects: true` / `maxRedirects: 5`
      // (dio-5.11.0 `_RequestConfig`), and `dart:io` turns a 302 on a POST into
      // a GET of the target. On this backend that silently swaps an API error
      // for the storefront's login page:
      //
      //   GET /api/v1/ecommerce/orders, dead bearer, no Accept
      //     -> 302 Found, Location: https://dev.truewayerp.com/login
      //   the same request with Accept: application/json
      //     -> 401 {"error":"Unauthorized", ...}
      //
      // Followed, that 302 resolves as a **200 carrying HTML**, which every
      // parser in this app reads as a malformed success. And the Accept header
      // is not a complete defence — Laravel's trailing-slash canonicalisation
      // redirects regardless of it (verified: GET /ecommerce/products/ ->
      // 301 -> /ecommerce/products, Accept or no Accept).
      //
      // `validateStatus` accepts the 3xx so the response comes back as a
      // response rather than a bare transport error; [_wrap] is what refuses
      // it, with the Location header attached for the log.
      ..options.followRedirects = false
      ..options.maxRedirects = 0
      ..options.validateStatus = ((int? s) => s != null && s < 400);

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers[AppConfig.apiKeyHeader] = AppConfig.apiKey;

          // `Options.compose` merges the base headers *under* a caller-supplied
          // `Options.headers` (dio-5.11.0: `caseInsensitiveKeyMap(baseOpt
          // .headers)` then `addAll(this.headers!)`), so `Accept` already
          // survives `ApiClient.post(options: …)` and a `FormData` body — which
          // only sets `Content-Type`. This re-asserts it anyway, because the
          // one header whose absence turns a 401 into a login page is not worth
          // leaving to a caller's care. `headers` is case-insensitive, so an
          // `accept:` the caller set deliberately still wins.
          options.headers.putIfAbsent('Accept', () => 'application/json');

          // Same reasoning, and a stronger reason: `compose` takes the caller's
          // `followRedirects` first, so an `Options(followRedirects: true)`
          // would re-open the hole for that one call. Not following redirects
          // is a property of this API, not a per-call preference.
          options
            ..followRedirects = false
            ..maxRedirects = 0;

          final token = _prefs.getString(_tokenKey);
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (e, handler) {
          // A 401 on a request we *did* send a token with means the Sanctum
          // token was revoked or expired. Note the API key is also enforced and
          // also 401s — so only react when a token was actually attached,
          // otherwise a misconfigured key would look like a logout.
          //
          // A 3xx normally reaches [_wrap] as a response rather than an error,
          // but a caller that supplies its own `validateStatus` would land it
          // here instead, so the same rule is applied to both.
          if (_signalsSignIn(e.response?.statusCode) &&
              _sentToken(e.requestOptions)) {
            onUnauthorized?.call();
          }
          handler.next(e);
        },
      ),
    );

    if (kDebugMode) {
      _dio.interceptors.add(
        LogInterceptor(
          requestBody: true,
          responseBody: false,
          logPrint: (o) => dev.log(o.toString(), name: 'api'),
        ),
      );
    }
  }

  final Dio _dio;
  final SharedPreferences _prefs;
  static const _tokenKey = 'auth_token';

  /// Invoked when an authenticated request is rejected with a 401 — or with a
  /// redirect, which this backend answers with instead whenever the request did
  /// not negotiate JSON. See [_redirectFailure].
  ///
  /// Never invoked for an anonymous request: there is no session to end, and
  /// the API key alone can produce either answer.
  ///
  /// Set by `AuthNotifier` so a revoked token signs the user out everywhere.
  /// It is a mutable field rather than a constructor argument to avoid a
  /// provider cycle (auth depends on the client, not the other way round).
  void Function()? onUnauthorized;

  String? get token => _prefs.getString(_tokenKey);
  bool get isAuthenticated => (token ?? '').isNotEmpty;

  Future<void> saveToken(String token) => _prefs.setString(_tokenKey, token);

  Future<void> clearToken() => _prefs.remove(_tokenKey);

  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
    Options? options,
  }) =>
      _wrap(() => _dio.get(path, queryParameters: query, options: options));

  /// [options] exists for the one call that must not inherit the app-wide
  /// timeouts: `POST /checkout/cart/{id}` is not idempotent, so giving up on it
  /// early does not fail the request — it only makes the outcome *unknown*,
  /// which costs the customer a reconciliation. See
  /// `CheckoutRepository.placeOrder`.
  Future<Response<dynamic>> post(
    String path, {
    Object? data,
    Map<String, dynamic>? query,
    Options? options,
  }) =>
      _wrap(
        () => _dio.post(
          path,
          data: data,
          queryParameters: query,
          options: options,
        ),
      );

  /// GETs a **binary** body — a PDF, not JSON.
  ///
  /// Everything this needs is already true of the shared client: `Accept:
  /// application/json` (which is what makes a dead token answer 401 instead of
  /// redirecting to an HTML login page), redirects refused, and 3xx surfaced by
  /// [_wrap] rather than parsed. Only three things differ.
  ///
  /// 1. `ResponseType.bytes`, so no interceptor tries to JSON-decode a PDF.
  ///    [ApiException.declaresFailure] is a no-op on a byte list, so the
  ///    business-error check in [_wrap] cannot misfire on binary either.
  /// 2. A far longer receive timeout. `/invoice/download` re-renders the PDF
  ///    through dompdf on **every** request — there is no cache — and the
  ///    backend team measured ~10 s on a cold render. The app-wide timeout
  ///    would abort that and report a network failure for a working endpoint.
  /// 3. The response, not just its body, so the caller can read
  ///    `Content-Disposition` for the server's own filename.
  Future<Response<dynamic>> getBytes(
    String path, {
    Map<String, dynamic>? query,
    Duration receiveTimeout = const Duration(seconds: 60),
  }) =>
      get(
        path,
        query: query,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: receiveTimeout,
        ),
      );

  Future<Response<dynamic>> put(String path, {Object? data}) =>
      _wrap(() => _dio.put(path, data: data));

  Future<Response<dynamic>> delete(String path, {Object? data}) =>
      _wrap(() => _dio.delete(path, data: data));

  /// Single choke point for every HTTP call: normalizes the failure and logs it
  /// once, with the request already attached. Callers therefore never need to
  /// log API errors themselves — doing so would double up.
  ///
  /// Three distinct failure channels are collapsed here:
  ///
  /// 1. 4xx / 5xx — Dio throws, handled below.
  /// 2. **3xx** — redirects are not followed (see the constructor), and
  ///    `validateStatus` lets them resolve, so an unfollowed 302 to the
  ///    storefront login page arrives here as a response whose body is HTML.
  ///    Refused rather than handed to a parser that would read it as success.
  /// 3. **2xx carrying `{"error": true}`** — this backend reports rules it
  ///    evaluated and rejected (out of stock, over max quantity) as HTTP 200.
  ///    Dio treats that as success, so without the explicit check every caller
  ///    would have to remember to inspect the envelope, and the one that forgot
  ///    would silently tell a customer their out-of-stock item was added.
  ///    Catching it here means repositories can keep treating a returned
  ///    response as "it worked".
  Future<Response<dynamic>> _wrap(Future<Response<dynamic>> Function() call) async {
    try {
      final res = await call();
      final redirect = _redirectFailure(res);
      if (redirect != null) throw redirect;
      if (ApiException.declaresFailure(res.data)) {
        final error = ApiException.fromBusinessError(
          res,
          requestDescription:
              '${res.requestOptions.method} ${res.requestOptions.uri}',
        );
        ErrorLog.capture(
          error,
          context: '${res.requestOptions.method} ${res.requestOptions.path}',
        );
        throw error;
      }
      return res;
    } on DioException catch (e, s) {
      final error = ApiException.fromDio(e);
      ErrorLog.capture(
        error,
        stackTrace: s,
        context: '${e.requestOptions.method} ${e.requestOptions.path}',
      );
      throw error;
    }
  }

  /// The error for an unfollowed redirect, or null when [res] is not one.
  ///
  /// A 3xx from this API is an authentication failure wearing a different
  /// number: the request that should have been answered `401 {"error":
  /// "Unauthorized"}` is answered `302 Location: /login` whenever the JSON
  /// content negotiation does not land. So it maps to
  /// [ApiErrorKind.unauthorized] — same heading, same "please sign in again",
  /// and [onUnauthorized] fires so a dead token is cleared instead of the
  /// customer looping through a screen that will not load.
  ///
  /// [onUnauthorized] is deliberately *not* fired for an anonymous request. The
  /// API key alone can trigger a redirect, and there is no session to end;
  /// signing out a user who was never signed in only loses their state. Same
  /// rule the 401 branch of the error interceptor already applies.
  ApiException? _redirectFailure(Response<dynamic> res) {
    if (!_signalsSignIn(res.statusCode)) return null;

    final location = res.headers.value('location');
    final error = ApiException.fromResponse(
      res,
      transportMessage: 'redirect not followed'
          '${location == null ? '' : ' -> $location'}',
      requestDescription:
          '${res.requestOptions.method} ${res.requestOptions.uri}',
    );
    ErrorLog.capture(
      error,
      context: '${res.requestOptions.method} ${res.requestOptions.path}',
    );
    if (_sentToken(res.requestOptions)) onUnauthorized?.call();
    return error;
  }

  /// Statuses that mean "this session cannot read the API": a 401, and any
  /// redirect — which on this backend is the un-negotiated form of the same
  /// answer.
  static bool _signalsSignIn(int? status) =>
      status == 401 || (status != null && status >= 300 && status < 400);

  /// Whether the request actually carried a bearer token, i.e. whether there is
  /// a session for [onUnauthorized] to end.
  static bool _sentToken(RequestOptions options) =>
      options.headers.containsKey('Authorization');
}

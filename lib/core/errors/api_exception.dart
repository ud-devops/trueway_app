import 'dart:convert';

import 'package:dio/dio.dart';

/// What went wrong, at a level the UI can branch on without string matching.
enum ApiErrorKind {
  /// No usable connection — DNS, offline, connection refused.
  network,
  timeout,
  cancelled,
  badCertificate,

  /// 401 — missing/expired/revoked token, or a rejected API key.
  ///
  /// Also **any 3xx**. This backend answers an unauthenticated API request with
  /// `302 Location: /login` rather than a 401 whenever the JSON content
  /// negotiation does not land — verified live: `GET /ecommerce/orders` with a
  /// dead bearer token returns 302 without an `Accept` header and 401 with one.
  /// `ApiClient` never follows a redirect, so that 302 surfaces here, and
  /// "please sign in again" is exactly what it means.
  unauthorized,

  /// 403.
  forbidden,
  notFound,

  /// 422 / 400, usually with a Laravel `errors` bag.
  validation,

  /// 429.
  rateLimited,

  /// 5xx.
  server,

  /// The request succeeded at the HTTP level but the server refused the
  /// operation in the body.
  ///
  /// This backend splits its failures across two channels: input it cannot
  /// parse gets a 422, but a rule it evaluated and rejected gets **HTTP 200**
  /// with `{"error": true, "message": "..."}`. Verified live:
  ///
  /// ```
  /// POST /ecommerce/cart {"product_id":118,"qty":99999}
  ///   -> HTTP 200 {"error":true,"data":null,"message":"Maximum quantity is 93!"}
  /// POST /ecommerce/cart {"product_id":999999,"qty":1}
  ///   -> HTTP 422 {"message":"The selected product id is invalid.", ...}
  /// ```
  ///
  /// Dio only throws on a non-2xx, so without an explicit check the first case
  /// reads as success and the app tells the customer an out-of-stock item was
  /// added to their cart.
  businessRule,

  unknown,
}

extension ApiErrorKindX on ApiErrorKind {
  /// Short heading for the error view. Deliberately generic — the specific
  /// explanation comes from the server whenever it gave us one.
  String get title => switch (this) {
        ApiErrorKind.network => 'No internet connection',
        ApiErrorKind.timeout => 'This is taking too long',
        ApiErrorKind.cancelled => 'Request cancelled',
        ApiErrorKind.badCertificate => 'Secure connection failed',
        ApiErrorKind.unauthorized => 'Please sign in again',
        ApiErrorKind.forbidden => "You don't have access to this",
        ApiErrorKind.notFound => 'Not found',
        ApiErrorKind.validation => 'Please check the details',
        ApiErrorKind.rateLimited => 'Too many attempts',
        ApiErrorKind.server => 'The server had a problem',
        // Never actually shown: a business-rule refusal always carries the
        // server's own sentence ("Maximum quantity is 93!"), which is exactly
        // what the customer needs to read. This is only the fallback if the
        // server ever omits its message.
        ApiErrorKind.businessRule => "That didn't work",
        ApiErrorKind.unknown => 'Something went wrong',
      };

  /// Whether retrying the same request could plausibly succeed.
  bool get isRetryable => switch (this) {
        ApiErrorKind.network ||
        ApiErrorKind.timeout ||
        ApiErrorKind.server ||
        ApiErrorKind.rateLimited ||
        ApiErrorKind.unknown =>
          true,
        _ => false,
      };
}

/// Normalized error surfaced to the UI layer.
///
/// ## Policy
///
/// The backend writes good, specific messages — "Invalid or expired OTP. Please
/// try again.", "Maximum quantity is 5!", "Product X is out of stock!". Those
/// are shown to the user **verbatim**. The app must not paraphrase them, or it
/// drifts out of sync with server behaviour and hides the real cause.
///
/// The only text we substitute is what a user cannot act on: HTML error pages,
/// stack traces, SQL errors, transport jargon. Even then the original is never
/// discarded — it moves to [developerDetail] so it still reaches logs and the
/// debug overlay.
///
/// So: [message] is what to show, [serverMessage] is what the server said, and
/// [developerDetail] is everything needed to debug it.
class ApiException implements Exception {
  const ApiException(
    this.message, {
    this.kind = ApiErrorKind.unknown,
    this.statusCode,
    this.fieldErrors,
    this.serverMessage,
    this.developerDetail,
    this.reason,
  });

  /// User-facing text. Equals [serverMessage] whenever the server's wording is
  /// fit to display; otherwise a readable stand-in.
  final String message;

  /// Exactly what the server said, unmodified. Null when the failure never
  /// reached the server (offline, timeout) or the body carried no message.
  final String? serverMessage;

  final ApiErrorKind kind;
  final int? statusCode;

  /// Laravel's `errors` bag: field name -> messages. Shown verbatim.
  final Map<String, List<String>>? fieldErrors;

  /// Technical context for logs and the debug-only details panel. Never shown
  /// to users in release builds.
  final String? developerDetail;

  /// A stable machine-readable code the server attaches to a *business* refusal,
  /// alongside the human sentence — `already_reviewed`, `purchase_required`,
  /// `review_delay`.
  ///
  /// Branch on this, never on [message]: the message is translated and its
  /// wording is free to change. Null on ordinary validation failures, which
  /// carry field errors instead.
  ///
  /// Introduced by the review endpoints; other controllers may adopt it, which
  /// is why it lives here rather than in a review-specific exception.
  final String? reason;

  bool get isUnauthorized => kind == ApiErrorKind.unauthorized;
  bool get isNotFound => kind == ApiErrorKind.notFound;
  bool get isValidation => kind == ApiErrorKind.validation;
  bool get isNetwork =>
      kind == ApiErrorKind.network || kind == ApiErrorKind.timeout;
  bool get isRetryable => kind.isRetryable;

  /// True when [message] is the server's own wording rather than ours.
  bool get isServerAuthored => serverMessage != null && serverMessage == message;

  /// Every field-level message, flattened, in a stable order.
  List<String> get allFieldErrors => [
        if (fieldErrors != null)
          for (final entry in fieldErrors!.entries) ...entry.value,
      ];

  /// First field-level validation message, if any.
  String? get firstFieldError =>
      allFieldErrors.isEmpty ? null : allFieldErrors.first;

  // ---- construction -----------------------------------------------------

  factory ApiException.fromDio(DioException e) {
    final where = _describeRequest(e.requestOptions);

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return ApiException(
          'The server took too long to respond. Please try again.',
          kind: ApiErrorKind.timeout,
          developerDetail: '${e.type.name} · $where\n${e.message ?? ''}',
        );
      case DioExceptionType.connectionError:
        return ApiException(
          'No internet connection. Check your network and try again.',
          kind: ApiErrorKind.network,
          developerDetail: '${e.type.name} · $where\n${e.message ?? ''}',
        );
      case DioExceptionType.badCertificate:
        return ApiException(
          "Couldn't establish a secure connection.",
          kind: ApiErrorKind.badCertificate,
          developerDetail: where,
        );
      case DioExceptionType.cancel:
        return ApiException(
          'Request cancelled.',
          kind: ApiErrorKind.cancelled,
          developerDetail: where,
        );
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        return ApiException.fromResponse(
          e.response,
          transportMessage: e.message,
          requestDescription: where,
        );
    }
  }

  factory ApiException.fromResponse(
    Response<dynamic>? res, {
    String? transportMessage,
    String? requestDescription,
  }) {
    final status = res?.statusCode;
    final body = res?.data;
    final kind = _kindForStatus(status);

    final serverMessage = _extractServerMessage(body);
    final fieldErrors = _extractFieldErrors(body);

    // Prefer the server's own words, then a field-level message, then a
    // kind-appropriate sentence. Dio's transport text is developer-facing and
    // is deliberately never used as display text.
    final displayable = _displayable(serverMessage);
    final firstField = _firstFieldMessage(fieldErrors);
    final message = displayable ?? _displayable(firstField) ?? kind.title;

    return ApiException(
      message,
      kind: kind,
      statusCode: status,
      fieldErrors: fieldErrors,
      serverMessage: serverMessage,
      reason: _extractReason(body),
      developerDetail: _buildDeveloperDetail(
        status: status,
        request: requestDescription,
        transportMessage: transportMessage,
        rawServerMessage: serverMessage,
        suppressed: serverMessage != null && displayable == null,
        body: body,
      ),
    );
  }

  /// A 2xx response whose body declares the operation failed.
  ///
  /// See [ApiErrorKind.businessRule]. The server's sentence is the whole point
  /// here — it names the actual constraint ("Maximum quantity is 93!") — so it
  /// is shown verbatim whenever it is fit to display.
  factory ApiException.fromBusinessError(
    Response<dynamic> res, {
    String? requestDescription,
  }) {
    final body = res.data;
    final serverMessage = _extractServerMessage(body);
    final fieldErrors = _extractFieldErrors(body);
    final displayable = _displayable(serverMessage);

    return ApiException(
      displayable ??
          _displayable(_firstFieldMessage(fieldErrors)) ??
          ApiErrorKind.businessRule.title,
      kind: ApiErrorKind.businessRule,
      statusCode: res.statusCode,
      fieldErrors: fieldErrors,
      serverMessage: serverMessage,
      reason: _extractReason(body),
      developerDetail: _buildDeveloperDetail(
        status: res.statusCode,
        request: requestDescription,
        transportMessage: 'body declared error:true on a ${res.statusCode}',
        rawServerMessage: serverMessage,
        suppressed: serverMessage != null && displayable == null,
        body: body,
      ),
    );
  }

  /// Whether a successful-looking response body is actually a refusal.
  ///
  /// Only `error: true` counts. The key also appears as `error: false` on
  /// success, and — on the 401 branch only — as the *string* `"Unauthorized"`,
  /// which never reaches here because Dio throws on a 401 first.
  static bool declaresFailure(dynamic body) =>
      body is Map && body['error'] == true;

  /// For failures that never involved Dio — a malformed payload, a missing
  /// token, a contract the server broke.
  factory ApiException.local(String message, {String? developerDetail}) =>
      ApiException(
        message,
        kind: ApiErrorKind.unknown,
        developerDetail: developerDetail,
      );

  // ---- helpers ----------------------------------------------------------

  static ApiErrorKind _kindForStatus(int? status) => switch (status) {
        null => ApiErrorKind.unknown,
        401 => ApiErrorKind.unauthorized,
        403 => ApiErrorKind.forbidden,
        404 => ApiErrorKind.notFound,
        422 || 400 => ApiErrorKind.validation,
        429 => ApiErrorKind.rateLimited,
        // Any redirect. `ApiClient` refuses to follow one, and on this backend
        // a redirect is the un-negotiated form of a 401 — see
        // [ApiErrorKind.unauthorized]. Mapped before the 5xx guard so a 3xx can
        // never fall through to `unknown`, which is retryable and would send
        // the app round the same redirect again.
        _ when status >= 300 && status < 400 => ApiErrorKind.unauthorized,
        _ when status >= 500 => ApiErrorKind.server,
        _ => ApiErrorKind.unknown,
      };

  /// Pulls the message out of either envelope the backend uses:
  ///   `{ "error": true, "message": "..." }`         (Botble)
  ///   `{ "message": "...", "errors": { ... } }`     (Laravel validation)
  /// Top-level `reason`, when the body is an object carrying one.
  static String? _extractReason(dynamic body) {
    if (body is! Map) return null;
    final raw = body['reason'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _extractServerMessage(dynamic body) {
    if (body is! Map) return null;
    for (final key in const ['message', 'error', 'msg']) {
      final value = body[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  static Map<String, List<String>>? _extractFieldErrors(dynamic body) {
    if (body is! Map || body['errors'] is! Map) return null;
    final raw = body['errors'] as Map;
    if (raw.isEmpty) return null;
    return raw.map(
      (k, v) => MapEntry(
        k.toString(),
        v is List ? v.map((e) => e.toString()).toList() : [v.toString()],
      ),
    );
  }

  static String? _firstFieldMessage(Map<String, List<String>>? errors) {
    if (errors == null) return null;
    for (final messages in errors.values) {
      if (messages.isNotEmpty) return messages.first;
    }
    return null;
  }

  /// Returns [text] when it is fit to show a user, else null.
  static String? _displayable(String? text) {
    final value = text?.trim();
    if (value == null || value.isEmpty) return null;
    return isDeveloperFacing(value) ? null : value;
  }

  /// Heuristic for text that would confuse or alarm a user.
  ///
  /// This is the single gate deciding "show the server's message" vs
  /// "substitute", so it is a named, tested predicate rather than inline
  /// conditions. Intentionally permissive: anything reading like a sentence
  /// gets through, because being too strict hides genuinely useful backend
  /// messages — which is the failure mode this whole class exists to prevent.
  static bool isDeveloperFacing(String text) {
    final value = text.trim();
    if (value.isEmpty) return true;

    final lower = value.toLowerCase();

    // An HTML error page rather than JSON.
    if (lower.startsWith('<!doctype') ||
        lower.startsWith('<html') ||
        lower.contains('<body')) {
      return true;
    }

    // Stack traces, framework dumps, driver errors.
    const markers = [
      'stack trace',
      'sqlstate',
      '#0 ',
      'exception:',
      'errorexception',
      'fatal error',
      'call to a member function',
      'undefined index',
      'undefined variable',
      'undefined method',
      'syntax error',
      'nullpointer',
      'traceback',
      'no query results for model',
    ];
    if (markers.any(lower.contains)) return true;

    // Source paths leak internals: /var/www/..., C:\..., Foo.php:42, main.dart:9
    if (RegExp(r'(/var/www|/home/\w+/|[A-Za-z]:\\|\.php[:(]|\.dart:\d)')
        .hasMatch(value)) {
      return true;
    }

    // Dio's own transport wording — accurate, but useless to a user.
    if (lower.startsWith('http status error') ||
        lower.contains('dioexception') ||
        lower.contains('socketexception') ||
        lower.contains('handshakeexception')) {
      return true;
    }

    // A wall of text is a dump, not a message.
    if (value.length > 300) return true;

    return false;
  }

  static String _describeRequest(RequestOptions o) => '${o.method} ${o.uri}';

  static String _buildDeveloperDetail({
    required int? status,
    required String? request,
    required String? transportMessage,
    required String? rawServerMessage,
    required bool suppressed,
    required dynamic body,
  }) {
    final lines = <String>[
      if (request != null) request,
      if (status != null) 'HTTP $status',
      if (transportMessage != null && transportMessage.isNotEmpty)
        'transport: $transportMessage',
      if (suppressed && rawServerMessage != null)
        'server message (hidden from UI as developer-facing):\n$rawServerMessage',
      if (body != null) 'body: ${_previewBody(body)}',
    ];
    return lines.join('\n');
  }

  static String _previewBody(dynamic body) {
    String text;
    try {
      text = body is String ? body : jsonEncode(body);
    } catch (_) {
      text = body.toString();
    }
    const limit = 800;
    return text.length <= limit ? text : '${text.substring(0, limit)}…';
  }

  @override
  String toString() {
    final buffer = StringBuffer('ApiException(${kind.name}');
    if (statusCode != null) buffer.write(' $statusCode');
    buffer.write('): $message');
    final detail = developerDetail;
    if (detail != null && detail.isNotEmpty) buffer.write('\n$detail');
    return buffer.toString();
  }
}

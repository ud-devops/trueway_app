import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';

import 'api_exception.dart';

/// Turns *any* thrown object into something presentable.
///
/// Riverpod's `AsyncValue.error` hands back `Object`, and screens used to
/// render it with `'$e'` — which printed `ApiException(422): ...` to the user.
/// Everything goes through here instead, so a non-[ApiException] can never leak
/// its `toString()` into the UI.
class ErrorPresenter {
  const ErrorPresenter._();

  /// Normalizes [error] to an [ApiException].
  static ApiException resolve(Object? error) {
    if (error is ApiException) return error;
    if (error == null) {
      return const ApiException(
        'Something went wrong.',
        developerDetail: 'null error object',
      );
    }
    // An unexpected exception type: its toString() is developer output, so it
    // is preserved for logs but never shown.
    return ApiException(
      ApiErrorKind.unknown.title,
      developerDetail: '${error.runtimeType}: $error',
    );
  }

  /// Heading for the error view.
  ///
  /// When the server authored the message we skip a separate heading — showing
  /// "Something went wrong" above "Invalid or expired OTP" adds noise and
  /// buries the useful line.
  static String? title(Object? error) {
    final e = resolve(error);
    return e.isServerAuthored ? null : e.kind.title;
  }

  /// The line to show the user.
  static String message(Object? error) => resolve(error).message;

  /// Technical detail — debug builds only. Null in release.
  static String? developerDetail(Object? error) {
    if (kReleaseMode) return null;
    final detail = resolve(error).developerDetail;
    return (detail == null || detail.isEmpty) ? null : detail;
  }
}

/// Central place errors are recorded.
///
/// Today this writes to the Dart developer log. It is the single seam where a
/// crash reporter (Crashlytics/Sentry) gets wired in — see the note in
/// KNOWN_ISSUES about the app having no crash reporting.
class ErrorLog {
  const ErrorLog._();

  /// Records a handled failure. [context] should say what was being attempted,
  /// e.g. `'catalog.products'` or `'auth.verifyOtp'`.
  static void capture(
    Object error, {
    StackTrace? stackTrace,
    String? context,
    bool fatal = false,
  }) {
    final e = ErrorPresenter.resolve(error);
    final buffer = StringBuffer()
      ..writeln('[${context ?? 'app'}] ${e.kind.name}'
          '${e.statusCode != null ? ' ${e.statusCode}' : ''}')
      ..writeln('message: ${e.message}');

    if (e.serverMessage != null && e.serverMessage != e.message) {
      buffer.writeln('server: ${e.serverMessage}');
    }
    for (final entry in (e.fieldErrors ?? const <String, List<String>>{}).entries) {
      buffer.writeln('field ${entry.key}: ${entry.value.join(', ')}');
    }
    if (e.developerDetail != null && e.developerDetail!.isNotEmpty) {
      buffer.writeln(e.developerDetail);
    }

    dev.log(
      buffer.toString(),
      name: fatal ? 'error!' : 'error',
      error: error,
      stackTrace: stackTrace,
      level: fatal ? 1000 : 900,
    );
  }
}

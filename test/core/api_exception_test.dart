import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/errors/error_presenter.dart';

Response<dynamic> _res(int status, dynamic body) => Response<dynamic>(
      requestOptions: RequestOptions(path: '/otp/send', method: 'POST'),
      statusCode: status,
      data: body,
    );

DioException _dio(DioExceptionType type, {Response<dynamic>? response}) =>
    DioException(
      requestOptions: RequestOptions(path: '/ecommerce/products', method: 'GET'),
      type: type,
      response: response,
      message: 'transport detail',
    );

void main() {
  group('server messages are shown verbatim', () {
    // The backend writes good, specific copy. Paraphrasing it on the client
    // hides the real cause and drifts out of sync with server behaviour.
    test('Botble envelope: {error, message}', () {
      final e = ApiException.fromResponse(_res(422, {
        'error': true,
        'data': null,
        'message': 'Phone number not found!',
      }),);
      expect(e.message, 'Phone number not found!');
      expect(e.serverMessage, 'Phone number not found!');
      expect(e.isServerAuthored, isTrue);
      expect(e.kind, ApiErrorKind.validation);
    });

    test('Laravel validation envelope: {message, errors}', () {
      final e = ApiException.fromResponse(_res(422, {
        'message': 'Customer ID is required. (and 2 more errors)',
        'errors': {
          'customer_id': ['Customer ID is required.'],
          'phone': ['Phone number is required.'],
          'otp': ['OTP must be exactly 6 digits.'],
        },
      }),);
      expect(e.message, 'Customer ID is required. (and 2 more errors)');
      expect(e.allFieldErrors, [
        'Customer ID is required.',
        'Phone number is required.',
        'OTP must be exactly 6 digits.',
      ]);
      expect(e.firstFieldError, 'Customer ID is required.');
    });

    test('an "error" string key is honoured too', () {
      final e = ApiException.fromResponse(_res(400, {'error': 'Cart is empty'}));
      expect(e.message, 'Cart is empty');
    });

    test('falls back to a field message when there is no top-level message', () {
      final e = ApiException.fromResponse(_res(422, {
        'errors': {
          'qty': ['Maximum quantity is 5!'],
        },
      }),);
      expect(e.message, 'Maximum quantity is 5!');
    });

    test('business messages survive on a 500', () {
      final e = ApiException.fromResponse(
        _res(500, {'message': 'Failed to send OTP. Please try again.'}),
      );
      expect(e.message, 'Failed to send OTP. Please try again.');
      expect(e.kind, ApiErrorKind.server);
    });
  });

  group('developer-facing text is replaced, never shown', () {
    void expectSuppressed(dynamic body, {required String because}) {
      final e = ApiException.fromResponse(_res(500, body));
      expect(e.message, isNot(contains(because)),
          reason: 'raw text leaked into the user-facing message',);
      expect(e.isServerAuthored, isFalse);
      // The original must still reach logs.
      expect(e.developerDetail, contains(because));
    }

    test('HTML error page', () {
      expectSuppressed(
        {'message': '<!DOCTYPE html><html><body>500 Server Error</body></html>'},
        because: '<!DOCTYPE',
      );
    });

    test('PHP stack trace', () {
      expectSuppressed(
        {'message': 'Fatal error: Call to a member function id() on null'},
        because: 'Call to a member function',
      );
    });

    test('SQL driver error', () {
      expectSuppressed(
        {'message': 'SQLSTATE[42S22]: Column not found: 1054 Unknown column'},
        because: 'SQLSTATE',
      );
    });

    test('file paths', () {
      expectSuppressed(
        {'message': 'Error in /var/www/html/app/Http/Controller.php:88'},
        because: '/var/www',
      );
    });

    test('a very long dump', () {
      final long = 'x' * 400;
      final e = ApiException.fromResponse(_res(500, {'message': long}));
      expect(e.message, ApiErrorKind.server.title);
      expect(e.developerDetail, contains(long));
    });

    test('replacement text is the kind title', () {
      final e = ApiException.fromResponse(
        _res(500, {'message': 'SQLSTATE[HY000] general error'}),
      );
      expect(e.message, 'The server had a problem');
    });
  });

  group('isDeveloperFacing', () {
    test('lets normal sentences through', () {
      const fine = [
        'Phone number not found!',
        'Invalid or expired OTP. Please try again.',
        'Maximum quantity is 5!',
        'Product Organic Wheat is out of stock!',
        'Applied coupon "FRESH10" successfully!',
        'Minimum order quantity is 2, you need to buy more 1 to place an order!',
      ];
      for (final m in fine) {
        expect(ApiException.isDeveloperFacing(m), isFalse, reason: m);
      }
    });

    test('catches technical output', () {
      const bad = [
        '<!DOCTYPE html>',
        'SQLSTATE[42S22]',
        '#0 /app/foo.php(12)',
        'Fatal error: something',
        'Undefined index: name',
        'DioException [bad response]',
        'SocketException: Failed host lookup',
        'HTTP status error [500]',
        'No query results for model [App\\Models\\Order]',
        '',
      ];
      for (final m in bad) {
        expect(ApiException.isDeveloperFacing(m), isTrue, reason: m);
      }
    });
  });

  group('kind classification', () {
    test('maps status codes', () {
      ApiErrorKind kindOf(int s) =>
          ApiException.fromResponse(_res(s, const {})).kind;
      expect(kindOf(401), ApiErrorKind.unauthorized);
      expect(kindOf(403), ApiErrorKind.forbidden);
      expect(kindOf(404), ApiErrorKind.notFound);
      expect(kindOf(422), ApiErrorKind.validation);
      expect(kindOf(400), ApiErrorKind.validation);
      expect(kindOf(429), ApiErrorKind.rateLimited);
      expect(kindOf(500), ApiErrorKind.server);
      expect(kindOf(503), ApiErrorKind.server);
    });

    // ApiClient never follows a redirect, so a 3xx reaches the UI. On this
    // backend it is a 401 that failed content negotiation — verified live:
    // GET /ecommerce/orders with a dead bearer answers 302 -> /login without an
    // Accept header and 401 with one. Anything else here would be wrong twice
    // over: `unknown` is retryable, and retrying walks into the same redirect.
    test('a redirect is an unauthorized, not an unknown', () {
      for (final status in [300, 301, 302, 303, 307, 308, 399]) {
        final e = ApiException.fromResponse(_res(status, const {}));
        expect(e.kind, ApiErrorKind.unauthorized, reason: '$status');
        expect(e.isUnauthorized, isTrue, reason: '$status');
        expect(e.isRetryable, isFalse, reason: '$status');
      }
    });

    test('exposes convenience flags', () {
      expect(ApiException.fromResponse(_res(401, const {})).isUnauthorized, isTrue);
      expect(ApiException.fromResponse(_res(404, const {})).isNotFound, isTrue);
      expect(ApiException.fromResponse(_res(422, const {})).isValidation, isTrue);
    });

    test('only some kinds are worth retrying', () {
      expect(ApiErrorKind.network.isRetryable, isTrue);
      expect(ApiErrorKind.timeout.isRetryable, isTrue);
      expect(ApiErrorKind.server.isRetryable, isTrue);
      expect(ApiErrorKind.validation.isRetryable, isFalse);
      expect(ApiErrorKind.unauthorized.isRetryable, isFalse);
      expect(ApiErrorKind.notFound.isRetryable, isFalse);
    });
  });

  group('transport failures', () {
    test('connection error becomes a network kind', () {
      final e = ApiException.fromDio(_dio(DioExceptionType.connectionError));
      expect(e.kind, ApiErrorKind.network);
      expect(e.isNetwork, isTrue);
      expect(e.message, contains('No internet connection'));
      // Dio's own wording is kept for developers only.
      expect(e.serverMessage, isNull);
      expect(e.developerDetail, contains('transport detail'));
    });

    test('timeouts become a timeout kind', () {
      for (final t in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        expect(ApiException.fromDio(_dio(t)).kind, ApiErrorKind.timeout);
      }
    });

    test('a bad response still yields the server message', () {
      final e = ApiException.fromDio(_dio(
        DioExceptionType.badResponse,
        response: _res(422, {'message': 'Invalid or expired OTP.'}),
      ),);
      expect(e.message, 'Invalid or expired OTP.');
      expect(e.statusCode, 422);
    });

    test('developer detail records the request', () {
      final e = ApiException.fromDio(_dio(DioExceptionType.connectionError));
      expect(e.developerDetail, contains('GET'));
      expect(e.developerDetail, contains('/ecommerce/products'));
    });
  });

  group('ErrorPresenter', () {
    test('passes ApiException through', () {
      const e = ApiException('boom');
      expect(identical(ErrorPresenter.resolve(e), e), isTrue);
    });

    test('never leaks a foreign exception toString to the user', () {
      final resolved = ErrorPresenter.resolve(FormatException('Unexpected token <'));
      expect(resolved.message, 'Something went wrong');
      expect(resolved.message, isNot(contains('Unexpected token')));
      expect(resolved.developerDetail, contains('Unexpected token'));
    });

    test('handles null', () {
      expect(ErrorPresenter.resolve(null).message, isNotEmpty);
    });

    test('omits the heading when the server authored the message', () {
      final server = ApiException.fromResponse(
        _res(422, {'message': 'Phone number not found!'}),
      );
      expect(ErrorPresenter.title(server), isNull);
      expect(ErrorPresenter.message(server), 'Phone number not found!');
    });

    test('adds a heading when the message is ours', () {
      final e = ApiException.fromDio(_dio(DioExceptionType.connectionError));
      expect(ErrorPresenter.title(e), 'No internet connection');
    });
  });

  group('the cart quantity-limit refusal', () {
    // The live shape as of 2026-08-11, after the backend added the check to
    // `PUT /cart/{id}`. Note `error` carries the MESSAGE, not `true`, and there
    // is no `message` key — a third envelope for this API.
    const body = {
      'error': 'Sorry, you can only order a maximum of 3 units of Trueway '
          'Farms Organic Finger Millet (ragi) 1.85 Kg at a time. Please '
          'adjust the quantity and try again.',
    };

    test('shows the server sentence verbatim', () {
      final e = ApiException.fromResponse(_res(422, body));

      expect(e.message, startsWith('Sorry, you can only order a maximum of 3'));
      expect(e.message, contains('adjust the quantity'));
    });

    test('names the cap, not the stock level', () {
      // The whole reason this was reported: the old wording said "Maximum
      // quantity is 85558!" — the stock — for a product capped at 3.
      final e = ApiException.fromResponse(_res(422, body));

      expect(e.message, contains('maximum of 3 units'));
      expect(e.message, isNot(contains('85558')));
    });
  });
}

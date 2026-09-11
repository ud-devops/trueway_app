import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/repositories/auth_repository.dart';

/// Canned response for one request.
class _Canned {
  const _Canned(this.statusCode, this.body);
  final int statusCode;
  final Object body;
}

/// Minimal Dio adapter that replays canned responses keyed by path, and records
/// what was sent. Avoids a mocking dependency.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);

  final Map<String, _Canned> responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
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

Future<({AuthRepository repo, ApiClient api, _FakeAdapter adapter})> _build(
  Map<String, _Canned> responses,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(responses);
  final dio = Dio()..httpClientAdapter = adapter;
  final api = ApiClient(prefs: prefs, dio: dio);
  return (repo: AuthRepository(api), api: api, adapter: adapter);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sendOtp', () {
    test('parses the live success envelope', () async {
      final t = await _build({
        '/otp/send': const _Canned(200, {
          'error': false,
          'data': {
            'message': 'OTP sent successfully to your mobile number',
            'phone': '98******10',
            'customer_id': 42,
            'expires_in': 300,
          },
          'message': 'OTP sent successfully',
        }),
      });

      final challenge = await t.repo.sendOtp('9876543210');

      expect(challenge.customerId, 42);
      expect(challenge.maskedPhone, '98******10');
      expect(challenge.rawPhone, '9876543210');
      expect(challenge.expiresIn, 300);
      expect(t.adapter.requests.single.data, {'phone': '9876543210'});
    });

    // Verified live: POST /otp/send with an unregistered number returns
    // {"error":true,"data":null,"message":"Phone number not found!"} at 422.
    test('maps "Phone number not found!" to OtpUnknownPhoneException', () async {
      final t = await _build({
        '/otp/send': const _Canned(422, {
          'error': true,
          'data': null,
          'message': 'Phone number not found!',
        }),
      });

      expect(
        () => t.repo.sendOtp('0000000000'),
        throwsA(isA<OtpUnknownPhoneException>()),
      );
    });

    test('maps the OTP-disabled setting to its own exception', () async {
      final t = await _build({
        '/otp/send': const _Canned(422, {
          'error': true,
          'message': 'OTP login is not enabled. Please use regular login.',
        }),
      });

      expect(
        () => t.repo.sendOtp('9876543210'),
        throwsA(isA<OtpLoginDisabledException>()),
      );
    });

    // Laravel validation uses a different envelope: {message, errors{...}}.
    test('surfaces field validation errors', () async {
      final t = await _build({
        '/otp/send': const _Canned(422, {
          'message': 'Phone number is required.',
          'errors': {
            'phone': ['Phone number is required.'],
          },
        }),
      });

      await expectLater(
        t.repo.sendOtp(''),
        throwsA(
          isA<ApiException>()
              .having((e) => e.message, 'message', 'Phone number is required.')
              .having((e) => e.firstFieldError, 'firstFieldError',
                  'Phone number is required.',),
        ),
      );
    });
  });

  group('verifyOtp', () {
    test('returns the session and persists the token', () async {
      final t = await _build({
        '/otp/verify': const _Canned(200, {
          'error': false,
          'data': {
            'token': '1|aF5s7p3xxx',
            'customer': {
              'id': 42,
              'name': 'Asha K',
              'email': 'asha@example.com',
              'phone': '9876543210',
            },
          },
          'message': 'Login successful!',
        }),
      });

      expect(t.api.isAuthenticated, isFalse);

      final session = await t.repo.verifyOtp(
        customerId: 42,
        phone: '9876543210',
        otp: '123456',
      );

      expect(session.token, '1|aF5s7p3xxx');
      expect(session.customer.name, 'Asha K');
      // Persisted, so the next request is authenticated.
      expect(t.api.isAuthenticated, isTrue);
      expect(t.api.token, '1|aF5s7p3xxx');

      expect(t.adapter.requests.single.data, {
        'customer_id': 42,
        'phone': '9876543210',
        'otp': '123456',
      });
    });

    test('rejects a success response with no token', () async {
      final t = await _build({
        '/otp/verify': const _Canned(200, {
          'error': false,
          'data': {'customer': {'id': 1}},
        }),
      });

      await expectLater(
        t.repo.verifyOtp(customerId: 1, phone: '9', otp: '123456'),
        throwsA(isA<ApiException>()),
      );
      expect(t.api.isAuthenticated, isFalse);
    });

    test('does not persist a token on a bad OTP', () async {
      final t = await _build({
        '/otp/verify': const _Canned(422, {
          'error': true,
          'message': 'Invalid or expired OTP. Please try again.',
        }),
      });

      await expectLater(
        t.repo.verifyOtp(customerId: 42, phone: '9876543210', otp: '000000'),
        throwsA(isA<ApiException>()),
      );
      expect(t.api.isAuthenticated, isFalse);
    });
  });

  group('resendOtp', () {
    // /otp/resend echoes only {message, expires_in} — customer_id and the
    // masked phone must be carried over or verify becomes impossible.
    test('preserves customerId and phone across the resend', () async {
      final t = await _build({
        '/otp/resend': const _Canned(200, {
          'error': false,
          'data': {
            'message': 'New OTP has been sent to your mobile number',
            'expires_in': 300,
          },
        }),
      });

      final challenge =
          await t.repo.resendOtp(customerId: 42, phone: '9876543210');

      expect(challenge.customerId, 42);
      expect(challenge.rawPhone, '9876543210');
      expect(challenge.expiresIn, 300);
      expect(challenge.maskedPhone, '98******10');
    });
  });

  group('session', () {
    test('logout clears the stored token', () async {
      final t = await _build({});
      await t.api.saveToken('1|abc');
      expect(t.api.isAuthenticated, isTrue);

      await t.repo.logout();
      expect(t.api.isAuthenticated, isFalse);
    });

    test('validateSession is false without a token', () async {
      final t = await _build({});
      expect(await t.repo.validateSession(), isFalse);
    });

    test('validateSession is false when the token is rejected', () async {
      final t = await _build({
        '/ecommerce/orders': const _Canned(401, {'message': 'Unauthenticated.'}),
      });
      await t.api.saveToken('1|revoked');
      expect(await t.repo.validateSession(), isFalse);
    });

    test('validateSession keeps the session on a server error', () async {
      // A 500 is not proof the token is bad — signing the user out here would
      // log everyone out during an outage.
      final t = await _build({
        '/ecommerce/orders': const _Canned(500, {'message': 'Server error'}),
      });
      await t.api.saveToken('1|good');
      expect(await t.repo.validateSession(), isTrue);
    });

    test('validateSession is true when the token is accepted', () async {
      final t = await _build({
        '/ecommerce/orders': const _Canned(200, {'data': <dynamic>[]}),
      });
      await t.api.saveToken('1|good');
      expect(await t.repo.validateSession(), isTrue);
    });
  });

  group('401 hook', () {
    test('fires only when a token was actually sent', () async {
      final t = await _build({
        '/ecommerce/orders': const _Canned(401, {'message': 'Unauthenticated.'}),
      });

      var fired = 0;
      t.api.onUnauthorized = () => fired++;

      // No token -> a 401 means the API key is wrong, not a revoked session.
      await t.api.get('/ecommerce/orders').catchError((_) => Response(
            requestOptions: RequestOptions(path: '/'),
          ),);
      expect(fired, 0);

      await t.api.saveToken('1|revoked');
      await t.api.get('/ecommerce/orders').catchError((_) => Response(
            requestOptions: RequestOptions(path: '/'),
          ),);
      expect(fired, 1);
    });
  });

  test('maskPhone matches the server format', () {
    expect(AuthRepository.maskPhone('9876543210'), '98******10');
    expect(AuthRepository.maskPhone('1234'), '1234');
  });

  // ---- email + password (botble/api package) -----------------------------

  group('loginWithPassword', () {
    // /login returns ONLY a token, so the customer must come from /me.
    test('saves the token then loads the profile from /me', () async {
      final t = await _build({
        '/login': const _Canned(200, {
          'error': false,
          'data': {'token': '2|pwToken'},
        }),
        '/me': const _Canned(200, {
          'error': false,
          'data': {
            'id': 9,
            'name': 'Asha K',
            'email': 'asha@example.com',
            'phone': '9876543210',
          },
        }),
      });

      final session = await t.repo.loginWithPassword(
        email: 'asha@example.com',
        password: 'secret123',
      );

      expect(session.token, '2|pwToken');
      expect(session.customer.id, 9);
      expect(session.customer.name, 'Asha K');
      expect(t.api.token, '2|pwToken');

      // The token must be saved before /me, or that call would be anonymous.
      expect(t.adapter.requests.map((r) => r.path), ['/login', '/me']);
      expect(
        t.adapter.requests.last.headers['Authorization'],
        'Bearer 2|pwToken',
      );
    });

    test('surfaces "Email or password is not correct!" verbatim', () async {
      final t = await _build({
        '/login': const _Canned(422, {
          'error': true,
          'message': 'Email or password is not correct!',
        }),
      });

      await expectLater(
        t.repo.loginWithPassword(email: 'a@b.co', password: 'wrong'),
        throwsA(isA<ApiException>().having(
          (e) => e.message,
          'message',
          'Email or password is not correct!',
        ),),
      );
      expect(t.api.isAuthenticated, isFalse);
    });

    test('surfaces the unverified-email rejection', () async {
      // Unlike OTP login, /login enforces confirmed_at.
      final t = await _build({
        '/login': const _Canned(422, {
          'error': true,
          'message':
              'Your email address is not verified. Please check your email and verify your account before logging in.',
        }),
      });

      await expectLater(
        t.repo.loginWithPassword(email: 'a@b.co', password: 'secret123'),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', contains('not verified')),),
      );
    });

    test('does not leave a half-signed-in session when /me fails', () async {
      final t = await _build({
        '/login': const _Canned(200, {
          'error': false,
          'data': {'token': '2|pwToken'},
        }),
        '/me': const _Canned(500, {'message': 'Server error'}),
      });

      await expectLater(
        t.repo.loginWithPassword(email: 'a@b.co', password: 'secret123'),
        throwsA(isA<ApiException>()),
      );
      // Token rolled back — otherwise the app would look signed in with no
      // customer to show.
      expect(t.api.isAuthenticated, isFalse);
    });

    test('rejects a success response with no token', () async {
      final t = await _build({
        '/login': const _Canned(200, {'error': false, 'data': {}}),
      });
      await expectLater(
        t.repo.loginWithPassword(email: 'a@b.co', password: 'x'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('register', () {
    test('sends the exact fields RegisterRequest expects', () async {
      final t = await _build({
        '/register': const _Canned(200, {
          'error': false,
          'message': 'Registered successfully!',
        }),
      });

      await t.repo.register(
        name: 'Asha K',
        email: 'asha@example.com',
        password: 'secret123',
        phone: '9876543210',
      );

      final sent = t.adapter.requests.single.data as Map;
      expect(sent['name'], 'Asha K');
      expect(sent['email'], 'asha@example.com');
      expect(sent['phone'], '9876543210');
      // The rule is `confirmed`, so this field must be present and match or
      // the server rejects the request.
      expect(sent['password'], 'secret123');
      expect(sent['password_confirmation'], 'secret123');
    });

    test('surfaces the duplicate-email validation error', () async {
      final t = await _build({
        '/register': const _Canned(422, {
          'message': 'The email has already been taken.',
          'errors': {
            'email': ['The email has already been taken.'],
          },
        }),
      });

      await expectLater(
        t.repo.register(
          name: 'A',
          email: 'taken@example.com',
          password: 'secret123',
          phone: '9876543210',
        ),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', 'The email has already been taken.')
            .having((e) => e.isValidation, 'isValidation', isTrue),),
      );
    });
  });

  group('isEmailTaken', () {
    test('reads the exists flag', () async {
      final t = await _build({
        '/email/check': const _Canned(200, {
          'error': false,
          'data': {'exists': true},
        }),
      });
      expect(await t.repo.isEmailTaken('a@b.co'), isTrue);
    });

    test('never blocks registration when the check itself fails', () async {
      final t = await _build({
        '/email/check': const _Canned(500, {'message': 'boom'}),
      });
      expect(await t.repo.isEmailTaken('a@b.co'), isFalse);
    });
  });

  group('logout', () {
    test('revokes server-side then clears locally', () async {
      final t = await _build({
        '/logout': const _Canned(200, {'error': false}),
      });
      await t.api.saveToken('1|abc');

      await t.repo.logout();

      expect(t.adapter.requests.single.path, '/logout');
      expect(t.api.isAuthenticated, isFalse);
    });

    test('still signs out locally when the server call fails', () async {
      // Tapping "sign out" must always work, even offline.
      final t = await _build({
        '/logout': const _Canned(500, {'message': 'boom'}),
      });
      await t.api.saveToken('1|abc');

      await t.repo.logout();
      expect(t.api.isAuthenticated, isFalse);
    });

    test('skips the network call when there is no token', () async {
      final t = await _build({});
      await t.repo.logout();
      expect(t.adapter.requests, isEmpty);
    });
  });

  group('fetchProfile', () {
    test('parses the /me payload', () async {
      final t = await _build({
        '/me': const _Canned(200, {
          'error': false,
          'data': {
            'id': 3,
            'name': 'Ravi',
            'email': 'ravi@example.com',
            'phone': '9000000002',
            'avatar': 'https://x/y.png',
          },
        }),
      });
      final c = await t.repo.fetchProfile();
      expect(c.id, 3);
      expect(c.name, 'Ravi');
      expect(c.avatar, 'https://x/y.png');
    });

    test('throws when the body is empty', () async {
      final t = await _build({'/me': const _Canned(200, {'error': false})});
      await expectLater(t.repo.fetchProfile(), throwsA(isA<ApiException>()));
    });
  });
}

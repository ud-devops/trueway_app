import '../../core/errors/api_exception.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_response.dart';
import '../../core/utils/json_utils.dart';
import '../models/customer.dart';

/// OTP authentication against the `uminber` plugin.
///
/// Flow (see `platform/plugins/uminber/src/Http/Controllers/API/OtpController`):
///   1. `POST /otp/send`   { phone }                        -> customer_id + masked phone
///   2. `POST /otp/verify` { customer_id, phone, otp }       -> Sanctum token + customer
///   3. `POST /otp/resend` { customer_id, phone }            -> new OTP
///
/// The OTP is valid for 5 minutes and sending a new one invalidates the
/// previous unused ones.
///
/// IMPORTANT: the backend has no mobile registration endpoint. `send` only
/// succeeds for a phone that already belongs to a customer; anything else comes
/// back 422 "Phone number not found!". [OtpUnknownPhoneException] exists so the
/// UI can tell that apart from a generic failure.
class AuthRepository {
  AuthRepository(this._api);

  final ApiClient _api;

  /// Server text for a phone that has no customer record.
  static const _unknownPhoneMessage = 'phone number not found';

  /// Server text when OTP login is switched off in admin
  /// (`setting('fast2sms_otp_login')`).
  static const _otpDisabledMessage = 'otp login is not enabled';

  Future<OtpChallenge> sendOtp(String phone) async {
    try {
      final res = await _api.post(
        ApiEndpoints.sendOtp,
        data: {'phone': phone},
      );
      return _challengeFrom(res.data, phone);
    } on ApiException catch (e) {
      throw _mapOtpError(e);
    }
  }

  Future<OtpChallenge> resendOtp({
    required int customerId,
    required String phone,
  }) async {
    try {
      final res = await _api.post(
        ApiEndpoints.resendOtp,
        data: {'customer_id': customerId, 'phone': phone},
      );
      // `resend` echoes only { message, expires_in } — it does not repeat
      // customer_id or the masked phone, so carry those over from the caller.
      final data = _dataOf(res.data);
      return OtpChallenge(
        customerId: customerId,
        maskedPhone: maskPhone(phone),
        rawPhone: phone,
        expiresIn: (data['expires_in'] is num)
            ? (data['expires_in'] as num).toInt()
            : 300,
      );
    } on ApiException catch (e) {
      throw _mapOtpError(e);
    }
  }

  /// Verifies the OTP and returns the Sanctum token + customer.
  ///
  /// The token is persisted here so every subsequent request is authenticated;
  /// callers do not need to save it themselves.
  Future<AuthSession> verifyOtp({
    required int customerId,
    required String phone,
    required String otp,
  }) async {
    final res = await _api.post(
      ApiEndpoints.verifyOtp,
      data: {'customer_id': customerId, 'phone': phone, 'otp': otp},
    );
    final session = AuthSession.fromJson(_dataOf(res.data));
    if (session.token.isEmpty) {
      throw const ApiException('Login failed — no access token was returned.');
    }
    await _api.saveToken(session.token);
    return session;
  }

  // ---- Email + password --------------------------------------------------

  /// `POST /login` — returns a token only, so the customer is fetched from
  /// `/me` afterwards. The token is saved first because `/me` needs it.
  ///
  /// The server rejects unverified accounts here (422), unlike OTP login which
  /// does not check `confirmed_at`.
  Future<AuthSession> loginWithPassword({
    required String email,
    required String password,
  }) async {
    final res = await _api.post(
      ApiEndpoints.login,
      data: {'email': email, 'password': password},
    );

    final token = asString(_dataOf(res.data)['token']);
    if (token.isEmpty) {
      throw ApiException.local(
        'Login failed — no access token was returned.',
        developerDetail: 'POST ${ApiEndpoints.login} returned no data.token',
      );
    }
    await _api.saveToken(token);

    try {
      return AuthSession(token: token, customer: await fetchProfile());
    } on ApiException {
      // The token is valid but the profile call failed. Don't strand the user
      // in a half-signed-in state.
      await _api.clearToken();
      rethrow;
    }
  }

  /// `GET /me` — the authenticated customer.
  ///
  /// Validated on `id` rather than emptiness: when the envelope has no `data`
  /// key, [_dataOf] falls back to the whole body, so a malformed response like
  /// `{"error": false}` would otherwise yield a customer with id 0 and an
  /// empty name instead of failing.
  Future<Customer> fetchProfile() async {
    final res = await _api.get(ApiEndpoints.profile);
    final data = _dataOf(res.data);
    final customer = Customer.fromJson(data);
    if (customer.id <= 0) {
      throw ApiException.local(
        "Couldn't load your profile.",
        developerDetail:
            'GET ${ApiEndpoints.profile} returned no usable customer: $data',
      );
    }
    return customer;
  }

  /// `POST /register`.
  ///
  /// Returns nothing useful — the endpoint responds with a message, not a
  /// token — so the caller must authenticate separately afterwards.
  ///
  /// [phone] is optional to the backend but effectively required here: OTP
  /// login resolves customers by phone, so a customer registered without one
  /// can never use the phone flow.
  Future<void> register({
    required String name,
    required String email,
    required String password,
    required String phone,
  }) async {
    await _api.post(
      ApiEndpoints.register,
      data: {
        'name': name,
        'email': email,
        'password': password,
        // The rule is `confirmed`, so this field must be present and match.
        'password_confirmation': password,
        'phone': phone,
      },
    );
  }

  /// `POST /email/check` — whether an email already has an account.
  ///
  /// Lets the register form fail early instead of after a full submit.
  Future<bool> isEmailTaken(String email) async {
    try {
      final res = await _api.post(
        ApiEndpoints.checkEmail,
        data: {'email': email},
      );
      return _dataOf(res.data)['exists'] == true;
    } on ApiException {
      // Availability checking is a convenience; never block registration on
      // it — the server enforces uniqueness on submit anyway.
      return false;
    }
  }

  /// `POST /password/forgot` — emails a reset link.
  Future<void> sendPasswordReset(String email) =>
      _api.post(ApiEndpoints.forgotPassword, data: {'email': email});

  // ---- Session -----------------------------------------------------------

  /// Signs out.
  ///
  /// `GET /logout` revokes **every** token for the customer server-side, so a
  /// lost device can't keep using an old one. The local token is cleared even
  /// if that call fails — a user tapping "sign out" must always end up signed
  /// out locally.
  Future<void> logout() async {
    try {
      if (_api.isAuthenticated) await _api.get(ApiEndpoints.logout);
    } on ApiException {
      // Already logged by ApiClient; local sign-out proceeds regardless.
    } finally {
      await _api.clearToken();
    }
  }

  /// Confirms a restored token is still accepted by the server.
  ///
  /// Sanctum tokens do not expire by default, but they can be revoked
  /// server-side; a stale token would otherwise 401 on the first real action.
  Future<bool> validateSession() async {
    if (!_api.isAuthenticated) return false;
    try {
      await _api.get(ApiEndpoints.orders, query: {'per_page': 1});
      return true;
    } on ApiException catch (e) {
      if (e.isUnauthorized) return false;
      // Network/server trouble is not proof the token is bad — keep the
      // session and let the next real request decide.
      return true;
    }
  }

  // ---- helpers ----------------------------------------------------------

  /// Botble wraps successful payloads as `{ error: false, data: {...} }`.
  Map<String, dynamic> _dataOf(dynamic body) => unwrapObject<Map<String, dynamic>>(
        body,
        (json) => json,
      ) ??
      const {};

  OtpChallenge _challengeFrom(dynamic body, String phone) {
    final data = _dataOf(body);
    if (data.isEmpty) {
      throw const ApiException('Unexpected response while sending the OTP.');
    }
    return OtpChallenge.fromJson(data, rawPhone: phone);
  }

  /// Re-tags two OTP failures the UI must handle differently, without altering
  /// the server's wording or losing any diagnostic context.
  ApiException _mapOtpError(ApiException e) {
    final message = e.message.toLowerCase();
    if (message.contains(_unknownPhoneMessage)) {
      return OtpUnknownPhoneException.from(e);
    }
    if (message.contains(_otpDisabledMessage)) {
      return OtpLoginDisabledException.from(e);
    }
    return e;
  }

  /// Local fallback mask matching the server's format (`98******10`).
  static String maskPhone(String phone) {
    if (phone.length <= 4) return phone;
    return phone.substring(0, 2) +
        '*' * (phone.length - 4) +
        phone.substring(phone.length - 2);
  }
}

/// The phone number has no customer account.
///
/// There is no mobile registration endpoint, so the app cannot recover from
/// this on its own — the customer must be created on the website or in admin.
class OtpUnknownPhoneException extends ApiException {
  const OtpUnknownPhoneException(
    super.message, {
    super.kind,
    super.statusCode,
    super.fieldErrors,
    super.serverMessage,
    super.developerDetail,
  });

  /// Re-tags [e] without changing its message or dropping context.
  factory OtpUnknownPhoneException.from(ApiException e) =>
      OtpUnknownPhoneException(
        e.message,
        kind: e.kind,
        statusCode: e.statusCode,
        fieldErrors: e.fieldErrors,
        serverMessage: e.serverMessage,
        developerDetail: e.developerDetail,
      );
}

/// OTP login is disabled in the backend settings
/// (`setting('fast2sms_otp_login')`).
class OtpLoginDisabledException extends ApiException {
  const OtpLoginDisabledException(
    super.message, {
    super.kind,
    super.statusCode,
    super.fieldErrors,
    super.serverMessage,
    super.developerDetail,
  });

  factory OtpLoginDisabledException.from(ApiException e) =>
      OtpLoginDisabledException(
        e.message,
        kind: e.kind,
        statusCode: e.statusCode,
        fieldErrors: e.fieldErrors,
        serverMessage: e.serverMessage,
        developerDetail: e.developerDetail,
      );
}

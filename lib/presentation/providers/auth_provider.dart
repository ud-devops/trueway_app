import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/errors/error_presenter.dart';
import '../../data/models/customer.dart';
import '../../data/repositories/auth_repository.dart';
import 'core_providers.dart';

enum AuthStatus {
  /// Startup — a persisted session may still be restored. Screens should not
  /// show a signed-out state yet or the UI flickers on every cold start.
  unknown,
  signedOut,

  /// An OTP has been sent and is awaiting entry.
  otpPending,
  authenticated,
}

class AuthState {
  const AuthState({
    this.status = AuthStatus.unknown,
    this.challenge,
    this.customer,
    this.busy = false,
    this.error,
    this.notice,
    this.unknownPhone = false,
    this.registeredPendingSignIn = false,
  });

  final AuthStatus status;

  /// Present while [status] is [AuthStatus.otpPending]; carries the
  /// `customer_id` that `/otp/verify` requires.
  final OtpChallenge? challenge;

  final Customer? customer;

  /// A request is in flight — disable the submit buttons.
  final bool busy;

  /// Last failure, for display. Cleared on the next action.
  final String? error;

  /// Transient success message (e.g. "OTP resent").
  final String? notice;

  /// True when the failure was specifically "this phone has no account".
  ///
  /// Tracked as a flag rather than re-matching the message text in the UI, so
  /// the login screen can offer to register that number instead of leaving the
  /// customer stuck retrying.
  final bool unknownPhone;

  /// The account was created but the follow-up sign-in failed — most often
  /// because email verification is enabled server-side. The user must not be
  /// told to "try registering again"; the account already exists.
  final bool registeredPendingSignIn;

  bool get isAuthenticated => status == AuthStatus.authenticated;
  bool get isResolving => status == AuthStatus.unknown;

  AuthState copyWith({
    AuthStatus? status,
    OtpChallenge? challenge,
    Customer? customer,
    bool? busy,
    String? error,
    String? notice,
    bool? unknownPhone,
    bool? registeredPendingSignIn,
    bool clearError = false,
    bool clearNotice = false,
    bool clearChallenge = false,
    bool clearCustomer = false,
  }) =>
      AuthState(
        status: status ?? this.status,
        challenge: clearChallenge ? null : (challenge ?? this.challenge),
        customer: clearCustomer ? null : (customer ?? this.customer),
        busy: busy ?? this.busy,
        error: clearError ? null : (error ?? this.error),
        notice: clearNotice ? null : (notice ?? this.notice),
        unknownPhone: clearError ? false : (unknownPhone ?? this.unknownPhone),
        registeredPendingSignIn:
            registeredPendingSignIn ?? this.registeredPendingSignIn,
      );
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._repo, this._ref) : super(const AuthState()) {
    // Wire the client's 401 hook here rather than in the provider graph: the
    // client must not depend on auth, or the providers would form a cycle.
    _ref.read(apiClientProvider).onUnauthorized = onUnauthorized;
    _restore();
  }

  final AuthRepository _repo;
  final Ref _ref;

  static const _customerKey = 'auth_customer_v1';

  /// Restores a persisted session, then confirms the token is still valid.
  ///
  /// The customer is cached locally so a cold start can render a name
  /// immediately; `GET /me` exists ([AuthRepository.fetchProfile]) but gating
  /// the first frame on a round-trip would flash a signed-out header.
  Future<void> _restore() async {
    final prefs = _ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(_customerKey);
    final api = _ref.read(apiClientProvider);

    if (raw == null || !api.isAuthenticated) {
      // A cached customer without a token (or vice versa) is a broken pair.
      await _clearPersisted();
      state = const AuthState(status: AuthStatus.signedOut);
      return;
    }

    Customer? cached;
    try {
      cached = Customer.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e, s) {
      ErrorLog.capture(e, stackTrace: s, context: 'auth.restoreCachedCustomer');
      cached = null;
    }

    if (cached == null) {
      await _clearPersisted();
      state = const AuthState(status: AuthStatus.signedOut);
      return;
    }

    // Show the session immediately, then verify in the background so a cold
    // start is not gated on a network round-trip.
    state = AuthState(status: AuthStatus.authenticated, customer: cached);

    final stillValid = await _repo.validateSession();
    if (!stillValid && mounted) {
      await _clearPersisted();
      state = const AuthState(status: AuthStatus.signedOut);
    }
  }

  // ---- Email + password --------------------------------------------------

  /// Returns true when the credentials were accepted and the session is live.
  Future<bool> loginWithPassword({
    required String email,
    required String password,
  }) async {
    state = state.copyWith(busy: true, clearError: true, clearNotice: true);
    try {
      final session = await _repo.loginWithPassword(
        email: email,
        password: password,
      );
      await _persist(session.customer);
      state = AuthState(
        status: AuthStatus.authenticated,
        customer: session.customer,
      );
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
      return false;
    }
  }

  /// Registers, then signs the new customer in with the same credentials.
  ///
  /// `/register` returns no token, so authentication is always a second step.
  /// Password login is used rather than OTP so the customer isn't made to wait
  /// for an SMS immediately after typing their details.
  ///
  /// Returns true only when both steps succeeded.
  Future<bool> register({
    required String name,
    required String email,
    required String password,
    required String phone,
  }) async {
    state = state.copyWith(busy: true, clearError: true, clearNotice: true);
    try {
      await _repo.register(
        name: name,
        email: email,
        password: password,
        phone: phone,
      );
    } on ApiException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
      return false;
    }

    // The account exists now; only sign-in can fail from here. If email
    // verification is enabled the server rejects login with an explanatory
    // 422 — surface that rather than a generic failure, and make clear the
    // account was created.
    final signedIn = await loginWithPassword(email: email, password: password);
    if (!signedIn) {
      state = state.copyWith(
        registeredPendingSignIn: true,
        error: state.error ?? 'Account created, but sign-in failed.',
      );
    }
    return signedIn;
  }

  // ---- Phone + OTP -------------------------------------------------------

  Future<void> sendOtp(String phone) async {
    state = state.copyWith(busy: true, clearError: true, clearNotice: true);
    try {
      final challenge = await _repo.sendOtp(phone);
      state = state.copyWith(
        status: AuthStatus.otpPending,
        challenge: challenge,
        busy: false,
      );
    } on OtpUnknownPhoneException catch (e) {
      // Already logged by ApiClient — just surface it.
      state = state.copyWith(busy: false, error: e.message, unknownPhone: true);
    } on ApiException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
    }
  }

  Future<void> resendOtp() async {
    final challenge = state.challenge;
    if (challenge == null || state.busy) return;

    state = state.copyWith(busy: true, clearError: true, clearNotice: true);
    try {
      final refreshed = await _repo.resendOtp(
        customerId: challenge.customerId,
        phone: challenge.rawPhone,
      );
      state = state.copyWith(
        challenge: refreshed,
        busy: false,
        notice: 'A new OTP has been sent.',
      );
    } on ApiException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
    }
  }

  /// Returns true when the OTP was accepted and the session is live.
  Future<bool> verifyOtp(String otp) async {
    final challenge = state.challenge;
    if (challenge == null) return false;

    state = state.copyWith(busy: true, clearError: true, clearNotice: true);
    try {
      final session = await _repo.verifyOtp(
        customerId: challenge.customerId,
        phone: challenge.rawPhone,
        otp: otp,
      );
      await _persist(session.customer);
      state = AuthState(
        status: AuthStatus.authenticated,
        customer: session.customer,
      );
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(busy: false, error: e.message);
      return false;
    }
  }

  /// Back to the phone-entry step, discarding the pending challenge.
  void changeNumber() => state = const AuthState(status: AuthStatus.signedOut);

  // ---- Profile -----------------------------------------------------------

  /// Replaces the cached customer after a profile write.
  ///
  /// The signed-in customer is read from here by every screen that greets the
  /// user, so a save that only updated the profile screen's own fields would
  /// leave a stale name in the account header until the next cold start.
  ///
  /// Ignored while signed out: a write cannot outlive the session that made it,
  /// and re-persisting here would resurrect a customer [logout] just cleared.
  Future<void> adoptCustomer(Customer customer) async {
    if (state.status != AuthStatus.authenticated) return;
    await _persist(customer);
    if (!mounted) return;
    state = state.copyWith(customer: customer);
  }

  /// Re-reads `GET /me` and adopts the result.
  ///
  /// Needed because the login payloads are narrower than the profile: OTP
  /// verify returns only `{id, name, email, phone, avatar}`, so `dob` is absent
  /// from a freshly signed-in session until this runs.
  ///
  /// Returns null on failure — the caller keeps showing the cached customer
  /// rather than emptying the screen over a refresh that did not have to
  /// succeed.
  Future<Customer?> refreshProfile() async {
    if (state.status != AuthStatus.authenticated) return null;
    try {
      final customer = await _repo.fetchProfile();
      await adoptCustomer(customer);
      return customer;
    } on ApiException {
      // Already logged by ApiClient; a 401 has separately triggered
      // [onUnauthorized], which owns the sign-out.
      return null;
    }
  }

  Future<void> logout() async {
    await _repo.logout();
    await _clearPersisted();
    state = const AuthState(status: AuthStatus.signedOut);
  }

  /// Called when any request comes back 401 — the token was revoked or expired.
  Future<void> onUnauthorized() async {
    if (state.status == AuthStatus.signedOut) return;
    await _repo.logout();
    await _clearPersisted();
    state = const AuthState(
      status: AuthStatus.signedOut,
      error: 'Your session has expired. Please sign in again.',
    );
  }

  void clearMessages() =>
      state = state.copyWith(clearError: true, clearNotice: true);

  Future<void> _persist(Customer customer) => _ref
      .read(sharedPreferencesProvider)
      .setString(_customerKey, jsonEncode(customer.toJson()));

  Future<void> _clearPersisted() async {
    await _ref.read(sharedPreferencesProvider).remove(_customerKey);
    await _repo.logout();
  }
}

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(apiClientProvider)),
);

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(ref.watch(authRepositoryProvider), ref),
);

/// Convenience for widgets that only care whether someone is signed in.
final isAuthenticatedProvider =
    Provider<bool>((ref) => ref.watch(authProvider).isAuthenticated);

/// The signed-in customer, or null.
final currentCustomerProvider =
    Provider<Customer?>((ref) => ref.watch(authProvider).customer);

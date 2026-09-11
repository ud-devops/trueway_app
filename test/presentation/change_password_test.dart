import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/data/models/customer.dart';
import 'package:trueway_farms/data/repositories/auth_repository.dart';
import 'package:trueway_farms/data/repositories/profile_repository.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/profile_provider.dart';
import 'package:trueway_farms/presentation/screens/profile/change_password_screen.dart';

/// `PUT /update/password`.
///
/// The rule set is thin — both values `min:6|max:60` — but two things about it
/// are easy to get wrong and are pinned here: the endpoint takes no
/// `password_confirmation`, so a mistyped new password would become one nobody
/// knows; and a wrong current password answers **403**, which must not be
/// mistaken for the 401 that ends a session.

const _customer = Customer(
  id: 7,
  name: 'Asha Kumari',
  email: 'asha@example.com',
  phone: '9000000001',
);

class _FakeAuthRepository implements AuthRepository {
  final List<String> resetsSentTo = [];

  @override
  Future<bool> validateSession() async => true;

  @override
  Future<Customer> fetchProfile() async => _customer;

  @override
  Future<void> sendPasswordReset(String email) async => resetsSentTo.add(email);

  @override
  Future<void> logout() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeProfileRepository implements ProfileRepository {
  _FakeProfileRepository({this.failure});

  /// What `PUT /update/password` throws, if anything.
  final ApiException? failure;

  final List<(String, String)> changes = [];

  @override
  Future<void> updatePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final f = failure;
    if (f != null) throw f;
    changes.add((currentPassword, newPassword));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<({_FakeProfileRepository profile, _FakeAuthRepository auth})> _pump(
  WidgetTester tester, {
  ApiException? failure,
  String? email = 'asha@example.com',
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues({
    'auth_token': 'placeholder-not-a-real-token',
    // Constructed rather than copied from [_customer]: `copyWith(email: null)`
    // means "leave it alone", so it could not express "has no address".
    'auth_customer_v1': jsonEncode(
      Customer(
        id: _customer.id,
        name: _customer.name,
        email: email,
        phone: _customer.phone,
      ).toJson(),
    ),
  });
  final prefs = await SharedPreferences.getInstance();

  final auth = _FakeAuthRepository();
  final profile = _FakeProfileRepository(failure: failure);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        authRepositoryProvider.overrideWithValue(auth),
        profileRepositoryProvider.overrideWithValue(profile),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        // Pushed rather than shown as home: the screen pops itself on success,
        // which needs somewhere to land.
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ChangePasswordScreen(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  return (profile: profile, auth: auth);
}

Future<void> _fill(
  WidgetTester tester, {
  required String current,
  required String next,
  String? confirm,
}) async {
  await tester.enterText(find.byKey(const Key('password-current')), current);
  await tester.enterText(find.byKey(const Key('password-new')), next);
  await tester.enterText(
    find.byKey(const Key('password-confirm')),
    confirm ?? next,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sends the current and new password', (tester) async {
    final t = await _pump(tester);

    await _fill(tester, current: 'old-secret', next: 'new-secret');
    await tester.tap(find.byKey(const Key('password-submit')));
    await tester.pumpAndSettle();

    expect(t.profile.changes, [('old-secret', 'new-secret')]);
  });

  testWidgets('returns to the previous screen on success', (tester) async {
    await _pump(tester);

    await _fill(tester, current: 'old-secret', next: 'new-secret');
    await tester.tap(find.byKey(const Key('password-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Change password'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  // The endpoint takes no `password_confirmation`, so this check exists only
  // here — without it a typo becomes a password nobody knows.
  testWidgets('a mismatched confirmation blocks the request', (tester) async {
    final t = await _pump(tester);

    await _fill(
      tester,
      current: 'old-secret',
      next: 'new-secret',
      confirm: 'new-secrft',
    );
    await tester.tap(find.byKey(const Key('password-submit')));
    await tester.pumpAndSettle();

    expect(find.text("The passwords don't match."), findsOneWidget);
    expect(t.profile.changes, isEmpty);
  });

  testWidgets('a too-short password blocks the request', (tester) async {
    final t = await _pump(tester);

    await _fill(tester, current: 'old-secret', next: 'short');
    await tester.tap(find.byKey(const Key('password-submit')));
    await tester.pumpAndSettle();

    expect(find.text('At least 6 characters.'), findsOneWidget);
    expect(t.profile.changes, isEmpty);
  });

  // 403, not 401. The customer stays on the screen with their session intact
  // and can try again.
  testWidgets('a wrong current password reports and stays put', (tester) async {
    await _pump(
      tester,
      failure: const ApiException(
        'Current password is not valid!',
        kind: ApiErrorKind.forbidden,
        statusCode: 403,
      ),
    );

    // Long enough to clear the local `min:6` check — the point is the server's
    // rejection, not ours.
    await _fill(tester, current: 'wrong-one', next: 'new-secret');
    await tester.tap(find.byKey(const Key('password-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Current password is not valid!'), findsOneWidget);
    expect(find.byKey(const Key('password-submit')), findsOneWidget,
        reason: 'still on the screen',);
  });

  // A customer who has only ever signed in with an OTP may not have a password
  // to supply, and the endpoint offers no way to set one without the old value.
  group('the reset escape hatch', () {
    testWidgets('emails a reset link', (tester) async {
      final t = await _pump(tester);

      await tester.tap(find.text("I don't know my current password"));
      await tester.pumpAndSettle();

      expect(t.auth.resetsSentTo, ['asha@example.com']);
    });

    testWidgets('is hidden when there is no address to send to',
        (tester) async {
      await _pump(tester, email: null);

      expect(find.text("I don't know my current password"), findsNothing);
    });
  });
}

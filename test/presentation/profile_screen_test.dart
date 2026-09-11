import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/data/models/customer.dart';
import 'package:trueway_farms/data/repositories/auth_repository.dart';
import 'package:trueway_farms/data/repositories/profile_repository.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/profile_provider.dart';
import 'package:trueway_farms/presentation/screens/profile/profile_screen.dart';

/// The profile screen is where `PUT /me` is actually reachable from.
///
/// These tests exist because "the repository has a method for it" has twice
/// been mistaken for "the app does it" in this project. Everything below drives
/// the real widget and asserts on what reached the repository.

const _cached = Customer(
  id: 7,
  name: 'Asha Kumari',
  email: 'asha@example.com',
  phone: '9000000001',
);

/// `GET /me` returns more than the OTP login payload — notably `dob`.
final _fromServer = _cached.copyWith(dob: DateTime(1990, 2, 9));

class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository({required this.profile, this.fails = false});

  /// What `GET /me` answers with.
  final Customer profile;

  /// Makes the background refresh fail, which must leave the cached customer
  /// on screen. An [ApiException] because that is the only thing the real
  /// repository throws — [AuthNotifier.refreshProfile] catches nothing else.
  final bool fails;

  int fetchCount = 0;

  @override
  Future<bool> validateSession() async => true;

  @override
  Future<Customer> fetchProfile() async {
    fetchCount++;
    if (fails) throw const ApiException('offline');
    return profile;
  }

  @override
  Future<void> logout() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeProfileRepository implements ProfileRepository {
  _FakeProfileRepository({this.result});

  /// What the server "stored". Defaults to echoing the request back.
  final Customer? result;

  final List<Map<String, Object?>> updates = [];
  final List<String> avatars = [];

  @override
  Future<Customer> updateProfile({
    required String name,
    String? email,
    String? phone,
    DateTime? dob,
  }) async {
    updates.add({
      'name': name,
      if (email != null) 'email': email,
      if (phone != null) 'phone': phone,
      if (dob != null) 'dob': Customer.apiDob(dob),
    });
    return result ??
        _cached.copyWith(name: name, email: email, phone: phone, dob: dob);
  }

  @override
  Future<String?> updateAvatar(String filePath) async {
    avatars.add(filePath);
    return 'https://cdn.example.com/users/new.jpg';
  }

  @override
  Future<void> updatePassword({
    required String currentPassword,
    required String newPassword,
  }) async {}
}

Future<({_FakeProfileRepository profile, _FakeAuthRepository auth})> _pump(
  WidgetTester tester, {
  bool signedIn = true,
  Customer? cachedCustomer,
  Customer? serverProfile,
  bool refreshFails = false,
  Customer? saveResult,
}) async {
  final cached = cachedCustomer ?? _cached;
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues(
    signedIn
        ? {
            'auth_token': 'placeholder-not-a-real-token',
            'auth_customer_v1': jsonEncode(cached.toJson()),
          }
        : <String, Object>{},
  );
  final prefs = await SharedPreferences.getInstance();

  // Defaults to the cached customer: a refresh that changes nothing is the
  // ordinary case, and it keeps every other test from depending on one.
  final auth = _FakeAuthRepository(
    profile: serverProfile ?? cached,
    fails: refreshFails,
  );
  final profile = _FakeProfileRepository(result: saveResult);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        authRepositoryProvider.overrideWithValue(auth),
        profileRepositoryProvider.overrideWithValue(profile),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light,
        routerConfig: GoRouter(
          initialLocation: '/profile',
          routes: [
            GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
            for (final path in const ['/login', '/profile/password'])
              GoRoute(
                path: path,
                builder: (_, __) =>
                    Scaffold(body: Center(child: Text('at $path'))),
              ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (profile: profile, auth: auth);
}

String _textIn(WidgetTester tester, Key key) {
  final field = find.descendant(
    of: find.byKey(key),
    matching: find.byType(TextField),
  );
  return tester.widget<TextField>(field).controller!.text;
}

void main() {
  testWidgets('seeds the form from the signed-in customer', (tester) async {
    await _pump(tester);

    expect(_textIn(tester, const Key('profile-name')), 'Asha Kumari');
    expect(find.text('asha@example.com'), findsOneWidget);
    expect(find.text('+91 9000000001'), findsOneWidget);
  });

  // Both are identity. The email is the password-reset channel, and the phone
  // is what OTP sign-in resolves — with no `unique` rule on `PUT /me` and an
  // `->first()` lookup in `OtpController::send`, a typo into someone else's
  // number would cost this customer their sign-in.
  group('email and phone are read-only', () {
    testWidgets('neither renders an input', (tester) async {
      await _pump(tester);

      for (final key in const [Key('profile-email'), Key('profile-phone')]) {
        expect(
          find.descendant(of: find.byKey(key), matching: find.byType(TextField)),
          findsNothing,
          reason: '$key must not be editable',
        );
      }
    });

    testWidgets('and a save never sends them', (tester) async {
      final t = await _pump(tester);

      await tester.tap(find.byKey(const Key('profile-save')));
      await tester.pumpAndSettle();

      final body = t.profile.updates.single;
      expect(body.containsKey('email'), isFalse);
      expect(body.containsKey('phone'), isFalse);
    });
  });

  // The user's report: picking the 28th saved and displayed the 27th. Cause was
  // in the model (see customer_test.dart); this is the screen-level guard that
  // the day the customer picked is the day they get back.
  testWidgets('shows the birthday the store meant, not a day early',
      (tester) async {
    // What an India-configured Botble sends for 28 Aug 2026: midnight IST,
    // serialised in UTC by `Carbon::jsonSerialize()`.
    final indiaEncoded = Customer.fromJson({
      'id': 7,
      'name': 'Asha Kumari',
      'email': 'asha@example.com',
      'phone': '9000000001',
      'dob': '2026-08-27T18:30:00.000000Z',
    });

    await _pump(tester, serverProfile: indiaEncoded);

    expect(find.text('28-08-2026'), findsOneWidget);
    expect(find.text('27-08-2026'), findsNothing);
  });

  // The login payloads are narrower than /me: OTP verify carries no dob, so
  // without this refresh a customer who has one sees an empty birthday.
  testWidgets('pulls dob in from the background /me refresh', (tester) async {
    expect(_cached.dob, isNull, reason: 'the premise');

    final t = await _pump(tester, serverProfile: _fromServer);

    expect(t.auth.fetchCount, 1);
    expect(find.text('09-02-1990'), findsOneWidget);
  });

  // A refresh that lands while the customer is typing must not take the text
  // back off them.
  testWidgets('a late refresh does not overwrite what was typed',
      (tester) async {
    await _pump(tester, serverProfile: _fromServer);

    await tester.enterText(find.byKey(const Key('profile-name')), 'Asha K');
    await tester.pumpAndSettle();

    expect(_textIn(tester, const Key('profile-name')), 'Asha K');
  });

  // The controller drops `email`/`phone` keys it was not sent; a null would be
  // written straight to the column instead.
  testWidgets('saving an untouched form sends only the name', (tester) async {
    final t = await _pump(tester);

    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();

    expect(t.profile.updates, [
      {'name': 'Asha Kumari'},
    ]);
  });

  testWidgets('sends a changed name', (tester) async {
    final t = await _pump(tester);

    await tester.enterText(find.byKey(const Key('profile-name')), 'Asha K');
    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();

    expect(t.profile.updates, [
      {'name': 'Asha K'},
    ]);
  });

  // `date_format:d-m-Y` — ISO is a 422, and one that arrives as a single
  // concatenated string with no field mapping.
  testWidgets('sends a picked birthday as dd-MM-yyyy', (tester) async {
    final t = await _pump(tester);

    await tester.tap(find.byKey(const Key('profile-dob')));
    await tester.pumpAndSettle();
    // The picker opens on 25 years ago; accepting it is enough to prove the
    // value reaches the request in the server's format.
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();

    expect(
      t.profile.updates.single['dob'],
      matches(RegExp(r'^\d{2}-\d{2}-\d{4}$')),
    );
  });

  // Nothing changed, so there is nothing to send — and a null `dob` would be
  // pointless traffic the controller ignores anyway.
  testWidgets('an untouched birthday is not resent', (tester) async {
    final t = await _pump(tester, serverProfile: _fromServer);

    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();

    expect(t.profile.updates.single.containsKey('dob'), isFalse);
  });

  // The controller validates fields `ec_customers` has no column for and drops
  // them on `fill()`. Offering them would show an edit that never persists.
  testWidgets('offers no gender or bio input', (tester) async {
    await _pump(tester);

    for (final label in const ['Gender', 'About you', 'Bio', 'First name']) {
      expect(find.text(label), findsNothing, reason: '$label does not persist');
    }
  });

  // The form shows the server's copy after a save, not what was typed — a
  // field the server ignored has to snap back.
  testWidgets('adopts the server copy after saving', (tester) async {
    await _pump(
      tester,
      saveResult: _cached.copyWith(name: 'Asha Kumari'),
    );

    await tester.enterText(find.byKey(const Key('profile-name')), 'ASHA!!');
    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();

    expect(_textIn(tester, const Key('profile-name')), 'Asha Kumari');
  });

  testWidgets('a failed background refresh keeps the cached customer',
      (tester) async {
    await _pump(tester, refreshFails: true);

    expect(_textIn(tester, const Key('profile-name')), 'Asha Kumari');
    expect(find.text('Not set'), findsOneWidget, reason: 'no dob was learned');
  });

  testWidgets('signed out, prompts to sign in instead of showing a form',
      (tester) async {
    await _pump(tester, signedIn: false);

    expect(find.text('Sign in to see your profile'), findsOneWidget);
    expect(find.byKey(const Key('profile-save')), findsNothing);

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('at /login'), findsOneWidget);
  });

  // It lives on the Account menu instead — covered in account_screen_test.dart.
  testWidgets('does not duplicate the change-password entry', (tester) async {
    await _pump(tester);

    expect(find.text('Change password'), findsNothing);
  });

  group('the profile photo', () {
    // A real URL leaves CachedNetworkImage's placeholder spinning under the
    // test binding, so these pump by hand rather than settling.
    //
    // The URL is thumbnail-shaped because that is what the API returns:
    // `avatar_url` is `RvMedia::getImageUrl($avatar, 'thumb')`.
    const withPhoto = Customer(
      id: 7,
      name: 'Asha Kumari',
      email: 'asha@example.com',
      phone: '9000000001',
      avatar: 'https://cdn.example.com/users/asha-150x150.jpg',
    );

    Future<void> openViewer(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('profile-avatar-view')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('tapping it opens the photo full screen', (tester) async {
      await _pump(tester, cachedCustomer: withPhoto);
      await openViewer(tester);

      expect(find.byKey(const Key('avatar-viewer-close')), findsOneWidget);
      expect(find.byKey(const Key('avatar-viewer-image')), findsOneWidget);
    });

    // The 150×150 thumbnail is unreadable full screen. The original sits at the
    // same path with the size suffix removed.
    testWidgets('loads the original, not the 150px thumbnail', (tester) async {
      await _pump(tester, cachedCustomer: withPhoto);
      await openViewer(tester);

      final image = tester.widget<CachedNetworkImage>(
        find.byKey(const Key('avatar-viewer-image')),
      );
      expect(image.imageUrl, 'https://cdn.example.com/users/asha.jpg');
    });

    // Deriving the original is a path transform, not a promise — a file really
    // named `…-150x150.jpg` would resolve to nothing.
    //
    // The error branch is asserted by invoking the builder rather than by
    // letting a request fail: the test binding leaves image requests pending
    // forever, so the error widget never actually renders.
    testWidgets('falls back to the thumbnail when the original is missing',
        (tester) async {
      await _pump(tester, cachedCustomer: withPhoto);
      await openViewer(tester);

      final finder = find.byKey(const Key('avatar-viewer-image'));
      final built = tester.widget<CachedNetworkImage>(finder).errorWidget!(
        tester.element(finder),
        'https://cdn.example.com/users/asha.jpg',
        'not found',
      );

      expect(
        (built as CachedNetworkImage).imageUrl,
        withPhoto.avatar,
        reason: 'the thumbnail is the one URL the API vouches for',
      );
    });

    // Under *loose* constraints the image lays out at its own pixel size, which
    // is what left a 150px square in the middle of a black screen. Tight
    // constraints are what let `BoxFit.contain` scale it up to the viewport.
    //
    // The constraints are asserted rather than the rendered size: nothing
    // resolves under the test binding, so the placeholder — not the photo —
    // is what has a size, and measuring it would pass either way.
    testWidgets('gets tight constraints so it can scale up', (tester) async {
      await _pump(tester, cachedCustomer: withPhoto);
      await openViewer(tester);

      final box = tester.renderObject<RenderBox>(
        find.byKey(const Key('avatar-viewer-image')),
      );
      expect(box.constraints.isTight, isTrue);
    });

    testWidgets('the viewer closes again', (tester) async {
      await _pump(tester, cachedCustomer: withPhoto);

      await tester.tap(find.byKey(const Key('profile-avatar-view')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('avatar-viewer-close')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byKey(const Key('avatar-viewer-close')), findsNothing);
      expect(find.byKey(const Key('profile-save')), findsOneWidget);
    });

    // Nothing to look at when the circle is drawn from initials, so the tap
    // does the useful thing instead of opening an empty viewer.
    testWidgets('with no photo, tapping it offers to add one', (tester) async {
      await _pump(tester);
      expect(_cached.hasAvatar, isFalse, reason: 'the premise');

      await tester.tap(find.byKey(const Key('profile-avatar-view')));
      await tester.pumpAndSettle();

      expect(find.text('Take a photo'), findsOneWidget);
      expect(find.byKey(const Key('avatar-viewer-close')), findsNothing);
    });

    testWidgets('the camera badge opens the picker', (tester) async {
      await _pump(tester);

      await tester.tap(find.byKey(const Key('profile-avatar-pick')));
      await tester.pumpAndSettle();

      expect(find.text('Take a photo'), findsOneWidget);
      expect(find.text('Choose from gallery'), findsOneWidget);
    });

    testWidgets('the picker sheet has a drag handle', (tester) async {
      await _pump(tester);

      await tester.tap(find.byKey(const Key('profile-avatar-pick')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<BottomSheet>(find.byType(BottomSheet)).showDragHandle,
        isTrue,
      );
    });
  });
}

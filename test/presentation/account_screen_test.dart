import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/config/app_config.dart';
import 'package:trueway_farms/core/design_system/app_icons.dart';
import 'package:trueway_farms/core/design_system/app_colors.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/presentation/widgets/surfaces.dart';
import 'package:trueway_farms/core/design_system/theme_context.dart';
import 'package:trueway_farms/core/utils/external_link.dart';
import 'package:trueway_farms/data/models/customer.dart';
import 'package:trueway_farms/data/repositories/auth_repository.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/screens/profile/account_screen.dart';

/// Where the Account screen's cards actually take you.
///
/// The screen used to be one flat, boxed list of chevron rows — every
/// destination read the same regardless of how often anyone actually used it.
/// It is now a dashboard: three quick-action cards for Orders/Wishlist/Address,
/// then two labelled sections ("MY ACCOUNT", "OTHER INFORMATION") of individual
/// cards. Nothing that was reachable before was dropped; this file is the proof
/// — every destination the old menu offered still has a tap target here, under
/// its new key.
///
/// This screen used to route through a `guarded(context, String? route)` whose
/// null branch showed "Coming soon." for the wishlist and saved-addresses
/// tiles. Both screens have existed for a while and both call sites pass a real
/// path, so that branch was dead — and a dead "Coming soon" is the shape of the
/// unreachable-screen bug this project has shipped before. The parameter is now
/// a non-nullable String, so a call site that forgot its route is a compile
/// error rather than a snackbar; these tests cover the other half, that each
/// card lands on the screen it names.

/// A destination that says which route was reached.
///
/// The real screens are not built here on purpose: this is a test about
/// routing, and pulling AddressBookScreen in would drag its repository, its
/// provider graph and its network reads along with it.
GoRouter _router() => GoRouter(
      initialLocation: '/account',
      routes: [
        GoRoute(
          path: '/account',
          builder: (_, __) => const AccountScreen(),
        ),
        for (final path in const [
          '/login',
          '/orders',
          '/addresses',
          '/wishlist',
          '/profile',
          '/profile/password',
          '/returns',
          '/reviews',
          '/notifications',
        ])
          GoRoute(
            path: path,
            builder: (_, __) => Scaffold(body: Center(child: Text('at $path'))),
          ),
        // The in-app browser, rendering its whole location rather than just
        // the path: the help-page cards carry the shop URL and the header
        // title in the query, and both are what those tests are about.
        GoRoute(
          path: '/web',
          builder: (_, state) =>
              Scaffold(body: Center(child: Text(state.uri.toString()))),
        ),
      ],
    );

/// Stands in for the real repository so restoring a session makes no request.
class _FakeAuthRepository implements AuthRepository {
  @override
  Future<bool> validateSession() async => true;

  /// Reached on the signed-out path too: a missing token makes [AuthNotifier]
  /// clear whatever else was persisted, which goes through the repository.
  @override
  Future<void> logout() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Builds the Account tab with auth resolved one way or the other.
///
/// [AuthNotifier] restores its session from SharedPreferences in its
/// constructor, so the state is seeded there rather than by overriding the
/// notifier — a token and a cached customer together mean "signed in", and
/// neither alone does. The token is a fixed placeholder; nothing here talks to
/// a server.
Future<void> _pumpAccount(
  WidgetTester tester, {
  required bool signedIn,
  String customerName = 'Suraj ojha',
  _RecordingLauncher? launcher,
  /// Tall by default so the whole menu is laid out — an off-screen sliver is
  /// never built, and half these tests tap rows near the bottom. Override it
  /// for anything about scrolling, which a 2400px surface makes impossible.
  Size surface = const Size(800, 2400),
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues(
    signedIn
        ? {
            'auth_token': 'placeholder-not-a-real-token',
            'auth_customer_v1': jsonEncode(
              Customer(
                id: 1,
                name: customerName,
                email: 'suraj.ojha@uminber.in',
                phone: '8305317276',
              ).toJson(),
            ),
          }
        : <String, Object>{},
  );
  final prefs = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        authRepositoryProvider.overrideWithValue(_FakeAuthRepository()),
        // The real one has no implementation under a widget test, and the
        // help-page cards hand their URL to it.
        if (launcher != null)
          externalLauncherProvider.overrideWithValue(launcher.call),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light,
        routerConfig: _router(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _row(String key) => find.byKey(Key(key));

void main() {
  group('the header', () {
    // The screen used to open straight onto the tiles, on the argument that
    // the name is one tap away under "My profile". That reads as a menu rather
    // than an account — and it is also the fastest way to notice you are
    // signed into the wrong one, which is why every account tab opens this way.
    testWidgets('signed in, it names the account', (tester) async {
      await _pumpAccount(tester, signedIn: true);

      expect(find.byKey(const Key('account-profile-header')), findsOneWidget);
      expect(find.text('Suraj ojha'), findsOneWidget);
      expect(find.text('8305317276'), findsOneWidget);
      expect(find.text('Account'), findsOneWidget, reason: 'the AppBar');
    });

    // Nothing to name yet, and nothing invented: a placeholder glyph and the
    // generic title, with the sign-in invite below doing the real work.
    testWidgets('signed out, it says nothing it does not know', (tester) async {
      await _pumpAccount(tester, signedIn: false);

      expect(find.byKey(const Key('account-profile-header')), findsOneWidget);
      expect(find.text('Your account'), findsOneWidget);
      expect(find.text('Suraj ojha'), findsNothing);
      expect(find.byKey(const Key('account-header')), findsOneWidget,
          reason: 'the sign-in invite',);
    });

    testWidgets('but the profile is still one tap away', (tester) async {
      // The header used to be the shortcut, so removing it would be a real
      // loss if the row below did not already go to the same place.
      await _pumpAccount(tester, signedIn: true);

      await tester.tap(_row('account-my-profile'));
      await tester.pumpAndSettle();

      expect(find.text('at /profile'), findsOneWidget);
    });

    testWidgets('signed out, invites sign-in but is not tappable',
        (tester) async {
      // The one case the header survives: there is no profile to link to yet,
      // so the line is an invitation rather than a shortcut — and tapping it
      // must still lead nowhere, because the way in is the "Sign in" row.
      await _pumpAccount(tester, signedIn: false);

      expect(find.text('Sign in to track your orders'), findsOneWidget);

      await tester.tap(_row('account-header'));
      await tester.pumpAndSettle();

      expect(find.text('at /profile'), findsNothing);
      expect(find.text('at /login'), findsNothing);
    });
  });

  group('signing out', () {
    // It used to sit between "Share the app" and the help pages: a customer
    // scrolling for the FAQ passed the one row that ends their session, and it
    // was the same shape and colour as everything around it. Both halves of
    // that are fixed here — where it is, and what it looks like.
    testWidgets('is the last row in the menu', (tester) async {
      await _pumpAccount(tester, signedIn: true);

      final logout = tester.getTopLeft(_row('account-auth-action')).dy;

      for (final path in const [
        'about-us',
        'contact',
        'shipping-delivery',
        'cancelation-return',
        'faq',
      ]) {
        final help = _row('account-page-$path');
        expect(help, findsOneWidget, reason: '$path is on the screen');
        expect(
          tester.getTopLeft(help).dy,
          lessThan(logout),
          reason: '$path should come before sign out',
        );
      }
    });

    testWidgets('is red, and drops the chevron', (tester) async {
      await _pumpAccount(tester, signedIn: true);

      final label = tester.widget<Text>(
        find.descendant(
          of: _row('account-auth-action'),
          matching: find.text('Log out'),
        ),
      );
      expect(label.style?.color, AppColors.error);

      // Every other row's chevron promises "this slides a screen in". This one
      // does not slide a screen in.
      expect(
        find.descendant(
          of: _row('account-auth-action'),
          matching: find.byIcon(AppIcons.caretRight),
        ),
        findsNothing,
      );
    });

    testWidgets('but signing in is not painted as destructive',
        (tester) async {
      // Same row, same key, opposite meaning — nothing is lost by tapping it,
      // so nothing about it should say otherwise.
      await _pumpAccount(tester, signedIn: false);

      final label = tester.widget<Text>(
        find.descendant(
          of: _row('account-auth-action'),
          matching: find.text('Sign in'),
        ),
      );
      expect(label.style?.color, isNot(AppColors.error));
      expect(
        find.descendant(
          of: _row('account-auth-action'),
          matching: find.byIcon(AppIcons.caretRight),
        ),
        findsOneWidget,
      );
    });
  });

  group('the quick-action cards', () {
    testWidgets('signed in, Orders opens the order history', (tester) async {
      await _pumpAccount(tester, signedIn: true);

      await tester.tap(_row('account-quick-orders'));
      await tester.pumpAndSettle();

      expect(find.text('at /orders'), findsOneWidget);
    });

    testWidgets('signed in, Address opens the address book', (tester) async {
      await _pumpAccount(tester, signedIn: true);

      await tester.tap(_row('account-quick-address'));
      await tester.pumpAndSettle();

      expect(find.text('at /addresses'), findsOneWidget);
      // The branch that used to eat this tap.
      expect(find.text('Coming soon.'), findsNothing);
    });

    testWidgets('signed out, Orders and Address go to sign-in', (tester) async {
      await _pumpAccount(tester, signedIn: false);

      await tester.tap(_row('account-quick-orders'));
      await tester.pumpAndSettle();
      expect(find.text('at /orders'), findsNothing);
      expect(find.text('at /login'), findsOneWidget);
    });

    // The wishlist API is anonymous, so this card is deliberately not gated —
    // requiring a sign-in would gate a feature the backend does not.
    testWidgets('signed out, Wishlist still opens the wishlist', (tester) async {
      await _pumpAccount(tester, signedIn: false);

      await tester.tap(_row('account-quick-wishlist'));
      await tester.pumpAndSettle();

      expect(find.text('at /wishlist'), findsOneWidget);
    });
  });

  group('MY ACCOUNT', () {
    testWidgets('signed in, My profile opens the profile screen', (tester) async {
      await _pumpAccount(tester, signedIn: true);

      await tester.tap(_row('account-my-profile'));
      await tester.pumpAndSettle();

      expect(find.text('at /profile'), findsOneWidget);
    });

    testWidgets('signed in, My returns opens the returns list', (tester) async {
      await _pumpAccount(tester, signedIn: true);

      await tester.tap(_row('account-my-returns'));
      await tester.pumpAndSettle();

      expect(find.text('at /returns'), findsOneWidget);
    });

    testWidgets('signed in, My reviews opens the reviews list', (tester) async {
      await _pumpAccount(tester, signedIn: true);

      await tester.tap(_row('account-my-reviews'));
      await tester.pumpAndSettle();

      expect(find.text('at /reviews'), findsOneWidget);
    });

    testWidgets('signed in, Change password opens the password screen',
        (tester) async {
      await _pumpAccount(tester, signedIn: true);

      await tester.tap(_row('account-change-password'));
      await tester.pumpAndSettle();

      expect(find.text('at /profile/password'), findsOneWidget);
    });

    testWidgets('signed out, every row in this section goes to sign-in',
        (tester) async {
      await _pumpAccount(tester, signedIn: false);

      for (final key in const [
        'account-my-profile',
        'account-my-returns',
        'account-my-reviews',
        'account-change-password',
      ]) {
        await _pumpAccount(tester, signedIn: false);
        await tester.tap(_row(key));
        await tester.pumpAndSettle();
        expect(find.text('at /login'), findsOneWidget, reason: key);
        expect(find.text('Coming soon.'), findsNothing, reason: key);
      }
    });
  });

  group('OTHER INFORMATION', () {
    // `/notifications` needs a bearer token, but the screen itself handles a
    // signed-out visit (a sign-in prompt) — the same convention the home
    // screen's bell icon already follows — so this card is not gated.
    testWidgets('Notifications opens even signed out', (tester) async {
      await _pumpAccount(tester, signedIn: false);

      await tester.tap(_row('account-notifications'));
      await tester.pumpAndSettle();

      expect(find.text('at /notifications'), findsOneWidget);
    });

    testWidgets('signed in, the row reads "Log out" and asks for confirmation',
        (tester) async {
      await _pumpAccount(tester, signedIn: true);

      expect(find.text('Log out'), findsOneWidget);
      expect(find.text('Sign in'), findsNothing);

      await tester.tap(_row('account-auth-action'));
      await tester.pumpAndSettle();

      expect(find.text('Sign out?'), findsOneWidget);
    });

    testWidgets('confirming signs out and returns to the header prompt',
        (tester) async {
      await _pumpAccount(tester, signedIn: true);

      await tester.tap(_row('account-auth-action'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(find.text('Sign in to track your orders'), findsOneWidget);
    });

    testWidgets('cancelling leaves the session alone', (tester) async {
      await _pumpAccount(tester, signedIn: true);

      await tester.tap(_row('account-auth-action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Log out'), findsOneWidget);
    });

    testWidgets('signed out, the row reads "Sign in" and opens it directly',
        (tester) async {
      await _pumpAccount(tester, signedIn: false);

      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Log out'), findsNothing);

      await tester.tap(_row('account-auth-action'));
      await tester.pumpAndSettle();

      expect(find.text('at /login'), findsOneWidget);
    });

    testWidgets('Share the app opens the platform share sheet without crashing',
        (tester) async {
      await _pumpAccount(tester, signedIn: true);

      await tester.tap(_row('account-share'));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('no card on this screen announces itself as unbuilt',
      (tester) async {
    await _pumpAccount(tester, signedIn: true);

    // Every card is a real destination. If one is ever added that is not, it
    // must not ship as a card that does nothing.
    expect(find.textContaining('Coming soon'), findsNothing);
    for (final label in const [
      'Orders',
      'Wishlist',
      'Address',
      'My profile',
      'My returns',
      'My reviews',
      'Change password',
      'Notifications',
      'Share the app',
      'Log out',
      'About us',
      'Contact us',
      'Shipping & delivery',
      'Cancellation & returns',
      'FAQ',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  // Two groups, split where the customer would split them: what belongs to
  // this account, and what belongs to the shop. The old "MY ACCOUNT" heading
  // is gone — everything above the second group is the account.
  testWidgets('the section labels are on screen', (tester) async {
    await _pumpAccount(tester, signedIn: true);

    // Sentence case: these are headings inside their cards, not system
    // labels floating above them, and 11px caps with tracking is the one
    // thing on the screen that cannot be skimmed.
    expect(find.text('Your information'), findsOneWidget);
    expect(find.text('Other information'), findsOneWidget);
    expect(find.text('MY ACCOUNT'), findsNothing);
    expect(find.text('YOUR INFORMATION'), findsNothing);
  });

  // Each heading belongs to the card it names. Floating in the gap between two
  // cards it belonged to neither, and read as closing the one above.
  testWidgets('each label sits inside its own card', (tester) async {
    await _pumpAccount(tester, signedIn: true);

    for (final label in ['Your information', 'Other information']) {
      expect(
        find.ancestor(of: find.text(label), matching: find.byType(AppCard)),
        findsWidgets,
        reason: label,
      );
    }

    // And the rows it names are in that same card.
    expect(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('Your information'),
              matching: find.byType(AppCard),
            )
            .first,
        matching: find.byKey(const Key('account-my-profile')),
      ),
      findsOneWidget,
    );
  });

  group('row height', _rowHeightTests);

  group('the shop\'s help pages', () {
    /// Every card, and the path each one opens.
    const pages = {
      'About us': 'about-us',
      'Contact us': 'contact',
      'Shipping & delivery': 'shipping-delivery',
      // The shop's own spelling — one L. Verified live: the two-L path 404s.
      'Cancellation & returns': 'cancelation-return',
      'FAQ': 'faq',
    };

    testWidgets('each hands its page to the device browser', (tester) async {
      // Chrome, not the in-app WebView: these are ordinary web pages, and the
      // customer gets an address bar, their own bookmarks and a share sheet.
      for (final entry in pages.entries) {
        final launcher = _RecordingLauncher();
        await _pumpAccount(tester, signedIn: false, launcher: launcher);

        await tester.tap(find.byKey(Key('account-page-${entry.value}')));
        await tester.pumpAndSettle();

        expect(launcher.opened, hasLength(1), reason: entry.key);
        expect(
          launcher.opened.single.toString(),
          '${AppConfig.origin}/${entry.value}',
          reason: entry.key,
        );
        // Nothing was pushed — the app stayed where it was.
        expect(find.textContaining('/web'), findsNothing, reason: entry.key);
      }
    });

    testWidgets('the URL follows the build\'s backend, not a literal',
        (tester) async {
      // A production build must not send customers to the dev server. The
      // origin is a compile-time `--dart-define`, so the path is what is
      // stored and the origin is prefixed at tap time.
      final launcher = _RecordingLauncher();
      await _pumpAccount(tester, signedIn: false, launcher: launcher);

      await tester.tap(find.byKey(const Key('account-page-about-us')));
      await tester.pumpAndSettle();

      expect(launcher.opened.single.origin, Uri.parse(AppConfig.origin).origin);
    });

    testWidgets('they are public — no sign-in wall', (tester) async {
      // These are CMS pages, not customer data. Gating them would gate
      // something the shop does not gate.
      final launcher = _RecordingLauncher();
      await _pumpAccount(tester, signedIn: false, launcher: launcher);

      await tester.tap(find.byKey(const Key('account-page-faq')));
      await tester.pumpAndSettle();

      expect(find.textContaining('/login'), findsNothing);
      expect(launcher.opened, hasLength(1));
    });

    group('when nothing external can take it', () {
      testWidgets('the in-app browser catches it', (tester) async {
        // A device with no browser, or a platform with no url_launcher. The
        // page has to stay reachable — which viewer shows it matters less.
        final launcher = _RecordingLauncher(succeeds: false);
        await _pumpAccount(tester, signedIn: false, launcher: launcher);

        await tester.tap(find.byKey(const Key('account-page-about-us')));
        await tester.pumpAndSettle();

        expect(launcher.opened, hasLength(1), reason: 'it tried first');
        expect(
          find.textContaining(Uri.encodeComponent('/about-us')),
          findsOneWidget,
        );
      });

      testWidgets('a title with an ampersand survives the query string',
          (tester) async {
        // "Shipping & delivery" unencoded would end the `title` parameter at
        // the ampersand, so the in-app header would read "Shipping ".
        await _pumpAccount(
          tester,
          signedIn: false,
          launcher: _RecordingLauncher(succeeds: false),
        );

        await tester.tap(
          find.byKey(const Key('account-page-shipping-delivery')),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining(Uri.encodeComponent('Shipping & delivery')),
          findsOneWidget,
        );
      });
    });
  });
    // The same gradient the home tab wears, so the two do not open one green and
    // one grey. It is painted behind the list rather than around the header: a
    // wash that scrolls with the content reads as a coloured box sliding up the
    // screen.
    testWidgets('the header wears the brand wash', (tester) async {
      await _pumpAccount(tester, signedIn: true);

      final washes = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where((d) => (d.decoration as BoxDecoration).gradient != null);
      expect(washes, isNotEmpty);

      // The palette's own token, so dark mode gets its near-black green rather
      // than a light smear.
      final ctx = tester.element(find.byType(AccountScreen));
      expect(
        (washes.first.decoration as BoxDecoration).gradient,
        ctx.colors.headerWash,
      );
    });
    // At rest the customer's own name is the title; "Account" a centimetre above
    // it says the same thing twice, and a solid bar there cuts the wash in half.
    // Once the header scrolls away the bar has to become a real one — opaque, so
    // the list does not run visibly underneath it.
    group('the app bar', () {
      testWidgets('is bare at rest', (tester) async {
        await _pumpAccount(tester, signedIn: true);

        final bar = tester.widget<AppBar>(find.byType(AppBar));
        expect(bar.backgroundColor, Colors.transparent);
        final title = tester.widget<AnimatedOpacity>(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byType(AnimatedOpacity),
          ),
        );
        expect(title.opacity, 0);
      });

      testWidgets('takes over once the header is gone', (tester) async {
        // A phone, not the harness's 2400px surface: at that height the whole
        // menu fits, there is nothing to scroll, and the bar would correctly
        // stay bare.
        await _pumpAccount(
          tester,
          signedIn: true,
          surface: const Size(400, 800),
        );

        // The controller, not a drag: a list whose content barely exceeds the
        // viewport absorbs the gesture as overscroll and never moves.
        tester.widget<ListView>(find.byType(ListView)).controller!.jumpTo(200);
        await tester.pumpAndSettle();

        final bar = tester.widget<AppBar>(find.byType(AppBar));
        expect(bar.backgroundColor, isNot(Colors.transparent));
        final title = tester.widget<AnimatedOpacity>(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byType(AnimatedOpacity),
          ),
        );
        expect(title.opacity, 1);
      });
    });
}

/// How tall the menu-row cards are.
///
/// The old list was airy enough that reaching FAQ meant scrolling past
/// everything else, so the rows were tightened once already. The floor is the
/// point of this group: 48dp is the minimum touch target in both Material and
/// the iOS HIG, and these cards are the only way into half the app — so
/// switching from `ListTile`s to `AppCard`s must never turn into a smaller
/// target.
void _rowHeightTests() {
  testWidgets('a menu card never drops below the 48dp tap target',
      (tester) async {
    await _pumpAccount(tester, signedIn: true);

    for (final key in const [
      'account-my-profile',
      'account-my-returns',
      'account-my-reviews',
      'account-change-password',
      'account-notifications',
      'account-share',
      'account-auth-action',
      'account-page-about-us',
      'account-page-faq',
    ]) {
      final height = tester.getSize(_row(key)).height;
      expect(height, greaterThanOrEqualTo(48.0), reason: key);
    }
  });

  testWidgets('the rows in one section are all the same height',
      (tester) async {
    // A card where one row is taller than its neighbours reads as a mistake.
    await _pumpAccount(tester, signedIn: true);

    final heights = <double>{
      for (final key in const [
        'account-my-profile',
        'account-my-returns',
        'account-my-reviews',
        'account-change-password',
      ])
        tester.getSize(_row(key)).height,
    };

    expect(heights, hasLength(1));
  });

  testWidgets('the three quick-action cards are all the same size',
      (tester) async {
    await _pumpAccount(tester, signedIn: true);

    final sizes = <Size>{
      for (final key in const [
        'account-quick-orders',
        'account-quick-wishlist',
        'account-quick-address',
      ])
        tester.getSize(_row(key)),
    };

    expect(sizes, hasLength(1));
  });
}

/// Stands in for the device browser.
///
/// The real launcher has no implementation under a widget test, so the seam is
/// [externalLauncherProvider] rather than a platform channel — and it lets a
/// test assert the exact URL handed over, which is the part worth pinning.
class _RecordingLauncher {
  _RecordingLauncher({this.succeeds = true});

  /// False stands for a device with no browser at all.
  final bool succeeds;

  final List<Uri> opened = [];

  Future<bool> call(Uri url) async {
    opened.add(url);
    return succeeds;
  }
}

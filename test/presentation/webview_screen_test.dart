/// The in-app browser the Account menu's help pages open into.
///
/// ## The bug this file exists for
///
/// [WebViewScreen] read `context.colors.surface` inside `initState()`.
/// `context.colors` is `Theme.of(context)`, which is
/// `dependOnInheritedWidgetOfExactType<_InheritedTheme>()`, and Flutter throws
/// for that before `initState` completes:
///
/// > dependOnInheritedWidgetOfExactType<_InheritedTheme>() … was called before
/// > _WebViewScreenState.initState() completed.
///
/// So every row that used this screen — About us, Contact us, Shipping &
/// delivery, Cancellation & returns, FAQ — opened onto a full-screen red error
/// page. It shipped with no test at all; this is that test.
///
/// ## Why there is no WebView here
///
/// `webview_flutter` registers no `WebViewPlatform.instance` under a widget
/// test, and constructing a controller then **asserts** — the same situation as
/// a desktop or web build. That is exactly the path this file drives: the
/// screen has to survive it and say something, and a screen that throws on open
/// fails `takeException()` below whatever the reason. Which is what makes these
/// a real guard rather than a formality.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/presentation/screens/common/webview_screen.dart';

Future<void> _open(
  WidgetTester tester, {
  required String url,
  String? title,
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AppTheme.light,
      home: WebViewScreen(url: url, title: title),
    ),
  );
  await tester.pump();
}

const _page = 'https://dev.truewayerp.com/about-us';

void main() {
  testWidgets('opening it does not throw', (tester) async {
    // The regression, in one line: this used to be an exception escaping
    // initState, and the customer saw Flutter's red page.
    await _open(tester, url: _page, title: 'About us');

    expect(tester.takeException(), isNull);
    expect(find.byType(WebViewScreen), findsOneWidget);
  });

  testWidgets('it keeps its title even when the page cannot be shown',
      (tester) async {
    // The header is how the customer knows which page they asked for, and it
    // is the one thing that works regardless of the WebView.
    await _open(tester, url: _page, title: 'Shipping & delivery');

    expect(find.text('Shipping & delivery'), findsOneWidget);
  });

  testWidgets('an untitled page falls back to the shop name', (tester) async {
    await _open(tester, url: _page);
    expect(find.text('Trueway Farms'), findsOneWidget);
  });

  testWidgets('a device with no WebView says so instead of showing blank',
      (tester) async {
    await _open(tester, url: _page, title: 'FAQ');

    expect(find.byKey(const Key('webview-error')), findsOneWidget);
    expect(find.text('Page unavailable'), findsOneWidget);
    // No Retry: there is no controller to retry with, and a button that cannot
    // work is worse than no button.
    expect(find.byKey(const Key('webview-retry')), findsNothing);
  });

  group('a link that could never load', () {
    testWidgets('is refused before a controller is built', (tester) async {
      // `Uri.parse` throws on a malformed string, and a non-http scheme loads
      // nothing — leaving a blank page under a spinner that never stops.
      for (final bad in ['', '   ', 'not a url', 'tel:+919876543210']) {
        await _open(tester, url: bad, title: 'Contact us');

        expect(tester.takeException(), isNull, reason: bad);
        expect(
          find.text('This link could not be opened.'),
          findsOneWidget,
          reason: bad,
        );
      }
    });

    testWidgets('a real https link is not refused for the same reason',
        (tester) async {
      // The control: the message above must be about the *link*, not about
      // every failure this screen can have.
      await _open(tester, url: _page, title: 'About us');

      expect(find.text('This link could not be opened.'), findsNothing);
      expect(find.text('Page unavailable'), findsOneWidget);
    });
  });

  testWidgets('it survives a theme change', (tester) async {
    // The backdrop moved to didChangeDependencies, which runs again whenever
    // the theme does — so this is the path that would break if it were ever
    // moved back into initState.
    await _open(tester, url: _page, title: 'About us');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const WebViewScreen(url: _page, title: 'About us'),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('About us'), findsOneWidget);
  });
}

/// The home ad banners: all of them, tappable, and placed after New arrivals.
///
/// Fixtures are the live `GET /api/v1/ads` payload — five published banners,
/// `order` 2/4/7/8/9, two of which carry an empty `link`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/ad_model.dart';
import 'package:trueway_farms/presentation/widgets/ad_carousel.dart';

AdBanner _ad({
  String key = 'ILSFJVYFGCPZ',
  String name = 'Make your Breakfast',
  String link = '/products',
  int order = 2,
}) =>
    AdBanner.fromJson({
      'key': key,
      'name': name,
      // Empty: a real URL leaves CachedNetworkImage spinning under the test
      // binding, and none of these tests are about the artwork.
      'image': '',
      'mobile_image': '',
      'link': link,
      'order': order,
      'open_in_new_tab': true,
      'subtitle': 'Make your Breakfast Healthy and Easy',
      'button_text': 'Shop now',
    });

/// The five live banners, in the order the repository sorts them into.
List<AdBanner> _liveFive() => [
      _ad(order: 2),
      _ad(key: '8UWSMHJSH3UP', name: 'Up to 60% off', link: '', order: 4),
      _ad(key: 'IZ6WU8KUALYJ', name: 'Everyday Fresh & Clean', order: 7),
      _ad(key: 'IZ6WU8KUALYK', name: 'The best Organic Products', order: 8),
      _ad(key: 'IZ6WU8KUALYL', name: 'Everyday Fresh', link: '', order: 9),
    ];

/// Destination screens render what they were given, so a test asserts on the
/// tree rather than on a side effect recorded during `build`.
///
/// Note there is deliberately no `addTearDown(router.dispose)`: disposing the
/// router while the tree still holds it hangs the run rather than failing it.
Future<void> _pump(WidgetTester tester, List<AdBanner> ads) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp.router(
      theme: AppTheme.light,
      routerConfig: GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => Scaffold(body: AdCarousel(ads: ads)),
          ),
          GoRoute(
            path: '/products',
            builder: (_, __) =>
                const Scaffold(body: Center(child: Text('native products'))),
          ),
          GoRoute(
            path: '/web',
            builder: (_, state) => Scaffold(
              body: Center(
                child: Text('web:${state.uri.queryParameters['url']}'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders every published banner, not just the first',
      (tester) async {
    await _pump(tester, _liveFive());

    // The endpoint returns five and this rendered `list.first`, so four
    // published banners were fetched, sorted and discarded on every home load.
    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.childrenDelegate.estimatedChildCount, 5);
  });

  testWidgets('shows a dot per banner', (tester) async {
    await _pump(tester, _liveFive());

    expect(find.byType(AnimatedContainer), findsNWidgets(5));
  });

  testWidgets('a single banner gets no dots', (tester) async {
    await _pump(tester, [_ad()]);

    expect(find.byType(AnimatedContainer), findsNothing);
  });

  testWidgets('an app route opens the real screen, not a web view',
      (tester) async {
    await _pump(tester, [_ad(link: '/products')]);

    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    expect(find.text('native products'), findsOneWidget);
  });

  testWidgets('a page with no app screen opens in the web view',
      (tester) async {
    // `/shop-by-solution?tags=15` is live on a slider right now and there is no
    // such screen in the app. go_router throws on an unknown route, so anything
    // not named natively has to go to the web view.
    await _pump(tester, [_ad(link: '/shop-by-solution?tags=15')]);

    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    expect(find.textContaining('shop-by-solution'), findsOneWidget);
    expect(find.textContaining('tags=15'), findsOneWidget);
  });

  testWidgets('a relative link is resolved against the configured origin',
      (tester) async {
    // Not against a hardcoded host: a build pointed at a local backend must not
    // send the customer to the dev site.
    await _pump(tester, [_ad(link: '/promo')]);

    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    expect(find.textContaining('http'), findsOneWidget);
    expect(find.textContaining('/promo'), findsOneWidget);
  });

  testWidgets('a banner with no link is not tappable', (tester) async {
    // Two of the five live banners carry `link: ""`. An InkWell with a null
    // callback draws no ripple, so it does not offer a tap it cannot honour.
    await _pump(tester, [_ad(link: '')]);

    final inkWell = tester.widget<InkWell>(find.byType(InkWell).first);
    expect(inkWell.onTap, isNull);

    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    // Still on the carousel; nothing was pushed.
    expect(find.byType(PageView), findsOneWidget);
  });

  testWidgets('an empty list draws nothing at all', (tester) async {
    await _pump(tester, const []);

    expect(find.byType(PageView), findsNothing);
  });
}

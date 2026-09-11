/// The home slider: what the CMS sends, and how it is laid out.
///
/// The fixtures are the **live** `GET /api/v1/simple-sliders` payload for
/// `home-slider-1`, copied verbatim — including the ten tabs the CMS editor
/// leaves after a `<br>`, which is the thing worth pinning.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:trueway_farms/core/design_system/app_colors.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/slider_model.dart';
import 'package:trueway_farms/presentation/widgets/app_network_image.dart';
import 'package:trueway_farms/presentation/widgets/home_slider_carousel.dart';

SliderItem _item({
  String title = 'Fresh Vegetables',
  String description = '',
  String image = '',
  String link = '',
}) =>
    SliderItem.fromJson({
      'id': 2,
      'title': title,
      'description': description,
      // Empty on purpose: a real URL leaves CachedNetworkImage spinning under
      // the test binding, and none of these tests are about the photograph.
      'image': image,
      'link': link,
      'order': 1,
    });

void main() {
  group('SliderItem text', () {
    test('strips the tabs the CMS leaves after a <br>', () {
      // Verbatim from the live payload. `replaceAll('<br>', '\\n').trim()` left
      // all ten tabs on the second line, because trim() only touches the ends
      // of the whole string.
      final item = _item(
        title: 'Fresh Vegetables<br>\t\t\t\t\t\t\t\t\t\tBig discount',
      );

      expect(item.plainTitle, 'Fresh Vegetables\nBig discount');
      expect(item.plainTitle, isNot(contains('\t')));
    });

    test('handles the second live slide, whose <br> is followed by a space', () {
      final item = _item(title: 'Don’t miss amazing<br> grocery deals');

      expect(item.plainTitle, 'Don’t miss amazing\ngrocery deals');
    });

    test('drops the blank line a trailing <br> would otherwise render', () {
      // A blank row inside a 2-line clamp costs one of the two lines, so the
      // real second line would be dropped instead.
      expect(_item(title: 'Big discount<br>').plainTitle, 'Big discount');
      expect(_item(title: '<br>Big discount').plainTitle, 'Big discount');
    });

    test('collapses runs of whitespace inside a line', () {
      expect(
        _item(title: 'Fresh    Vegetables').plainTitle,
        'Fresh Vegetables',
      );
    });

    test('leaves clean copy exactly as written', () {
      final item = _item(
        title: 'Fresh Vegetables',
        description: 'Save up to 50% off on your first order',
      );

      expect(item.plainTitle, 'Fresh Vegetables');
      expect(
        item.plainDescription,
        'Save up to 50% off on your first order',
      );
    });

    test('an empty field stays empty rather than becoming a blank line', () {
      // The widget keys its "should I render this" checks off these, so an
      // empty description must not turn into a one-character string.
      expect(_item(description: '').plainDescription, isEmpty);
      expect(_item(title: '<br>').plainTitle, isEmpty);
    });
  });

  group('HomeSliderCarousel layout', () {
    /// One item only: with two the widget starts a 4-second `Timer.periodic`,
    /// which never lets `pumpAndSettle` return.
    Future<void> pump(WidgetTester tester, SliderItem item) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: HomeSliderCarousel(items: [item])),
        ),
      );
      await tester.pump();
    }

    testWidgets('centres both lines of copy', (tester) async {
      await pump(
        tester,
        _item(
          title: 'Don’t miss amazing<br> grocery deals',
          description: 'Sign up for the daily newsletter',
        ),
      );

      // The shop's slider artwork puts its subject at both edges and leaves the
      // middle clear for words, so the copy belongs in the centre. Left-aligned
      // text sat on top of the artwork instead.
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.textAlign, TextAlign.center);
      }
    });

    testWidgets('renders the title with its tabs removed', (tester) async {
      await pump(
        tester,
        _item(title: 'Fresh Vegetables<br>\t\t\t\t\t\t\t\t\t\tBig discount'),
      );

      expect(find.text('Fresh Vegetables\nBig discount'), findsOneWidget);
    });

    testWidgets('renders no description row when the CMS sent none',
        (tester) async {
      await pump(tester, _item(title: 'Fresh Vegetables'));

      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('a single slide shows no page dots', (tester) async {
      await pump(tester, _item());

      // Dots for a one-page carousel are a control that cannot do anything.
      expect(find.byType(AnimatedContainer), findsNothing);
    });

    testWidgets('draws dark copy on the artwork, with no scrim', (tester) async {
      await pump(
        tester,
        _item(title: 'Fresh Vegetables', description: 'Save up to 50% off'),
      );

      // The assets are light cream studio shots. White-on-a-dark-wash is the
      // treatment for a dark photograph; here it only muddied a picture that
      // needed nothing. The website draws #253D4E straight onto the same image.
      final title = tester.widget<Text>(find.text('Fresh Vegetables'));
      expect(title.style?.color, AppColors.onSliderInk);

      final desc = tester.widget<Text>(find.text('Save up to 50% off'));
      expect(desc.style?.color, AppColors.onSliderMuted);
    });

    testWidgets('the copy stays dark in dark mode — the image does not change',
        (tester) async {
      // The trap this exists to catch: routing slider copy through
      // `context.colors.ink` reads correctly in light mode and turns the text
      // near-white in dark mode, where it then sits invisible on a cream
      // photograph. The image is served by the CMS and has no idea what theme
      // the app is in, so the ink on it must not either.
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: HomeSliderCarousel(items: [_item(title: 'Fresh Vegetables')]),
          ),
        ),
      );
      await tester.pump();

      final title = tester.widget<Text>(find.text('Fresh Vegetables'));
      expect(title.style?.color, AppColors.onSliderInk);
    });
  });

  // The CMS lets the admin upload three crops per slide. Only `image` comes
  // back as a URL; the other two are raw column values, which is the trap.
  group('SliderItem artwork', () {
    // Verbatim from the live payload for `home-slider-1`, item 19.
    SliderItem live() => SliderItem.fromJson({
          'id': 19,
          'title': '',
          'description': '',
          'image': 'https://dev.truewayerp.com/storage/./web1.webp',
          'link': '',
          'order': 0,
          'tablet_image': './tab1.webp',
          'mobile_image': './mobile1.webp',
        });

    test('resolves the raw paths against the storage disk', () {
      final item = live();
      // `resolveImage` would have produced `https://…/./tab1.webp`, which 404s:
      // the `/storage` segment the server baked into `image` is missing from
      // its siblings. Both of these were confirmed 200 image/webp live.
      expect(item.tabletImage, 'https://dev.truewayerp.com/storage/tab1.webp');
      expect(item.mobileImage, 'https://dev.truewayerp.com/storage/mobile1.webp');
    });

    test('picks the crop that fits the slide box, not the device', () {
      final item = live();
      // The slide is a fixed 2.13 box everywhere; the tablet cut is 2.19 and
      // the mobile one is 1.14 — the latter loses ~half its height to
      // `BoxFit.cover` in that box, which is what sliced the artwork.
      expect(item.imageFor(411), item.tabletImage, reason: 'phone');
      expect(item.imageFor(800), item.tabletImage, reason: 'tablet');
      // Only a genuinely wide layout gets the 3.53 banner.
      expect(item.imageFor(1440), item.image, reason: 'desktop');
    });

    test('falls back to the desktop artwork when nothing was uploaded', () {
      // Slider "test1" is exactly this: both variants null.
      final item = SliderItem.fromJson({
        'id': 18,
        'title': 'peas',
        'description': 'test',
        'image': 'https://dev.truewayerp.com/storage/sliders/slider12-2-min.png',
        'link': '',
        'order': 0,
        'tablet_image': null,
        'mobile_image': null,
      });
      expect(item.tabletImage, isNull);
      expect(item.mobileImage, isNull);
      for (final width in const [411.0, 800.0, 1440.0]) {
        expect(item.imageFor(width), item.image, reason: '$width');
      }
    });

    test('a slide with only a mobile upload still renders', () {
      final item = SliderItem.fromJson({
        'id': 1,
        'title': '',
        'description': '',
        'image': 'https://dev.truewayerp.com/storage/./10.webp',
        'link': '',
        'order': 2,
        'tablet_image': './11.webp',
        'mobile_image': '',
      });
      expect(item.mobileImage, isNull, reason: 'blank is not an upload');
      expect(item.imageFor(411), 'https://dev.truewayerp.com/storage/11.webp');
    });

    test('a path that already names the disk does not gain a second copy', () {
      final item = SliderItem.fromJson({
        'id': 1,
        'title': '',
        'description': '',
        'image': '',
        'link': '',
        'order': 0,
        'tablet_image': 'storage/sliders/a.webp',
        'mobile_image': 'https://cdn.example.test/b.webp',
      });
      expect(item.tabletImage,
          'https://dev.truewayerp.com/storage/sliders/a.webp',);
      // An absolute URL is left exactly as the admin pasted it.
      expect(item.mobileImage, 'https://cdn.example.test/b.webp');
    });
  });

  // =========================================================================
  // Tapping a slide
  //
  // Two of the three live slides carry `link: ""`, and the third points at
  // `…/products/trueway-farms-organic-finger-millet-ragi-185-kg-125`. That
  // third one is the case worth getting right: the website's product URL is
  // plural and this app's route is singular, so before the mapping it opened a
  // *web page* of a product the app has a real screen for.
  // =========================================================================

  group('tapping a slide', () {
    testWidgets('a product link opens the app\'s product screen', (tester) async {
      final host = _TapHost(
        items: [_item(title: 'Millet', link: '$_liveOrigin/products/$_liveSlug')],
      );
      await host.pump(tester);

      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      // Not `/web`. The real screen, with add-to-cart, variants and reviews.
      expect(host.visited, ['/product/$_liveSlug']);
    });

    testWidgets('a page with no app screen opens the web view', (tester) async {
      // Live on a slider today; go_router would throw if this were pushed.
      final host = _TapHost(
        items: [_item(title: '', link: '$_liveOrigin/shop-by-solution?tags=15')],
      );
      await host.pump(tester);

      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      expect(host.visited.single, startsWith('/web?url='));
      expect(
        host.visited.single,
        contains(Uri.encodeComponent('shop-by-solution?tags=15')),
      );
    });

    testWidgets('a relative link is resolved before it is opened',
        (tester) async {
      // `/products` is what the CMS emits. Unresolved it is not something a
      // browser could open either.
      final host = _TapHost(items: [_item(link: '/products')]);
      await host.pump(tester);

      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      expect(host.visited, ['/products']);
    });

    testWidgets('a slide with no link is not a button', (tester) async {
      // The old GestureDetector always had an onTap and did nothing inside it,
      // so a slide that goes nowhere still swallowed the tap and drew no
      // ripple to explain itself.
      final host = _TapHost(items: [_item(link: '')]);
      await host.pump(tester);

      final inkWell = tester.widget<InkWell>(find.byType(InkWell).first);
      expect(inkWell.onTap, isNull);

      await tester.tap(find.byType(InkWell).first, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(host.visited, isEmpty);
    });

    testWidgets('only the linked slide announces itself as a button',
        (tester) async {
      final host = _TapHost(
        items: [
          _item(title: 'Linked', link: '/products'),
          _item(title: 'Plain', link: ''),
        ],
      );
      await host.pump(tester);

      final buttons = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .where((s) => s.properties.button ?? false)
          .length;
      expect(buttons, 1);
    });
  });
  // The banner's height used to be a hard 172dp, which does not match any of
  // the three uploads — desktop 1905x540 (3.53), tablet 768x350 (2.19), phone
  // 400x350 (1.14) — so `cover` cropped whatever did not fit. It is now the
  // tablet cut's own ratio, which is the one the app is served.
  group('HomeSliderCarousel sizing', () {
    testWidgets('sizes the box to the artwork rather than a fixed height',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: HomeSliderCarousel(items: [_item()])),
        ),
      );
      await tester.pump();

      // The height follows ONE SLIDE's width, not the viewport's: each page is
      // 92% of the screen minus its 6dp gutters. Sizing off the full width made
      // the box taller than the artwork, and the picture overflowed its card.
      const slideWidth = (400 * 0.92) - 12;
      final box = tester.getSize(find.byType(PageView));
      expect(box.width, closeTo(400, 0.001));
      expect(box.height, closeTo(slideWidth / (768 / 350), 0.5));
    });

    testWidgets('fills the slide, so the rounded corners clip the picture',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: HomeSliderCarousel(
              items: [_item(image: 'https://example.test/banner.webp')],
            ),
          ),
        ),
      );
      await tester.pump();

      // `cover` is only safe because the box is cut to the artwork's own
      // ratio — the two agree, so nothing is cropped and no ground shows at
      // the edges. `contain` left a hairline there and the radius read ragged.
      final art = tester.widget<AppNetworkImage>(find.byType(AppNetworkImage));
      expect(art.fit, BoxFit.cover);
    });
  });
}

const _liveOrigin = 'https://dev.truewayerp.com';
const _liveSlug = 'trueway-farms-organic-finger-millet-ragi-185-kg-125';

/// Hosts the carousel under a router that records where a tap went.
///
/// The real destinations are not built: this is a test about routing, and
/// pulling the product screen in would drag its repositories and network reads
/// along with it.
class _TapHost {
  _TapHost({required this.items});

  final List<SliderItem> items;
  final List<String> visited = [];

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => Scaffold(body: HomeSliderCarousel(items: items)),
        ),
        for (final path in const ['/products', '/product/:slug', '/web'])
          GoRoute(
            path: path,
            builder: (_, state) {
              visited.add(state.uri.toString());
              return const Scaffold(body: Center(child: Text('went')));
            },
          ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    );
    await tester.pump();
  }
}

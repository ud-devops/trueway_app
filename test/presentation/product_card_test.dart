import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/presentation/widgets/product_carousel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_icons.dart';
import 'package:trueway_farms/core/utils/responsive.dart';
import 'package:trueway_farms/data/models/product_model.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/widgets/product_card.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';

import '../support/fake_cart_repository.dart';
import '../support/fake_catalog_repository.dart';
import 'package:trueway_farms/presentation/widgets/app_network_image.dart';

import '../support/fake_home_repository.dart';

Product _product(Map<String, dynamic> overrides) => Product.fromJson({
      'id': 1,
      'slug': 'organic-sona-moti-wheat',
      'name': 'Trueway Farms Organic Sona Moti Wheat (sonamoti gehu)',
      'price': 921.501,
      'original_price': 1296.75,
      'weight': 5000,
      'quantity': 100,
      'is_out_of_stock': false,
      'stock_status_label': 'In stock',
      ...overrides,
    });

/// Renders the card at the same tile size the product grids produce, so a
/// layout that overflows in the app overflows here too.
Future<void> _pumpCard(
  WidgetTester tester,
  Product product, {
  double screenWidth = 411,
  double textScale = 1,
  FakeCatalogRepository? catalog,
  bool signedIn = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();

  final columns = Responsive.productColumns(screenWidth);
  final gutter = Responsive.gutter(screenWidth);
  final tileWidth =
      (screenWidth - (gutter * 2) - (14 * (columns - 1))) / columns;
  final tileHeight = tileWidth / Responsive.productAspect(screenWidth);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        // The card's ADD button writes to the *server* cart now, so the
        // repository is the seam a widget test has to close.
        cartRepositoryProvider.overrideWithValue(FakeCartRepository()),
        // ADD also asks whether the product has packs to choose from, because
        // the listing payload cannot say. Defaults to a simple product here.
        catalogRepositoryProvider.overrideWithValue(
          catalog ?? FakeCatalogRepository(product: product),
        ),
        isAuthenticatedProvider.overrideWithValue(signedIn),
        // And which products are variable at all, which a listing row
        // cannot say. Empty here: these tiles are simple products.
        homeRepositoryProvider.overrideWithValue(FakeHomeRepository()),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: tileWidth,
                height: tileHeight,
                child: ProductCard(product: product),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Renders the card at an explicit tile size.
Future<void> _pumpCardAt(
  WidgetTester tester,
  Product product, {
  required double width,
  required double height,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        // The card's ADD button writes to the *server* cart now, so the
        // repository is the seam a widget test has to close.
        cartRepositoryProvider.overrideWithValue(FakeCartRepository()),
        // ADD also asks whether the product has packs to choose from, because
        // the listing payload cannot say. Defaults to a simple product here.
        catalogRepositoryProvider
            .overrideWithValue(FakeCatalogRepository(product: product)),
        // And which products are variable at all, which a listing row
        // cannot say. Empty here: these tiles are simple products.
        homeRepositoryProvider.overrideWithValue(FakeHomeRepository()),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: ProductCard(product: product),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  _railGeometry();
  group('layout', () {
    // The card grew a pack row, unit price and rating line; if the grid ratio
    // and the content ever disagree again, this fails with a RenderFlex
    // overflow instead of shipping a clipped card.
    testWidgets('fits its grid tile on a phone', (tester) async {
      await _pumpCard(tester, _product({}));
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits on a tablet-width tile', (tester) async {
      await _pumpCard(tester, _product({}), screenWidth: 800);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits with a long name and every badge showing',
        (tester) async {
      await _pumpCard(
        tester,
        _product({
          'name': 'Trueway Farms An Organic Land Nature To Natural Sona Moti '
              'Wheat Sugar Free Whole Grain 15 kg Family Pack',
          'reviews_avg': 4.5,
          'reviews_count': 1234,
          'stock_status_label': 'On backorder',
          'product_options': [
            {'id': 1, 'name': 'Size'},
            {'id': 2, 'name': 'Grind'},
          ],
        }),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits with no weight, rating or discount', (tester) async {
      await _pumpCard(
        tester,
        _product({'weight': 0, 'original_price': 921.501}),
      );
      expect(tester.takeException(), isNull);
    });
  });

  // Two four-figure amounts do not fit across a phone tile. They used to share
  // one Row as two Flexibles, which kept them on a single line by ellipsizing
  // the digits — ₹1,199.10 rendered as "₹1,19…". A truncated price is quietly
  // wrong rather than obviously missing, so the pair now wraps instead.
  group('price and MRP', () {
    /// Where the two amounts landed. Rects, because "did it wrap" is a question
    /// about geometry — and `didExceedMaxLines` cannot answer it.
    ({Rect price, Rect mrp}) amounts(WidgetTester tester) => (
          price: tester.getRect(find.text('₹921.50')),
          mrp: tester.getRect(find.text('₹1,296.75')),
        );

    testWidgets('share a line when they fit', (tester) async {
      await _pumpCard(tester, _product({}), screenWidth: 800);

      final rects = amounts(tester);
      expect(
        rects.mrp.top,
        lessThan(rects.price.bottom),
        reason: 'a wide tile has room for both',
      );
      expect(rects.mrp.left, greaterThan(rects.price.left));
    });

    testWidgets('stack when they do not', (tester) async {
      // Three columns on a phone: ~120dp per tile, and these are the store's
      // real figures.
      await _pumpCard(
        tester,
        _product({'price': 1199.10, 'original_price': 1599.75}),
      );

      final rects = (
        price: tester.getRect(find.text('₹1,199.10')),
        mrp: tester.getRect(find.text('₹1,599.75')),
      );
      expect(
        rects.mrp.top,
        greaterThanOrEqualTo(rects.price.bottom),
        reason: 'the MRP belongs on its own line rather than being cut',
      );
    });

    // The point of wrapping: the digits survive. An ellipsized price would
    // render narrower than the text it claims to be.
    testWidgets('are never truncated on a narrow tile', (tester) async {
      await _pumpCard(
        tester,
        _product({'price': 1199.10, 'original_price': 1599.75}),
      );

      for (final text in const ['₹1,199.10', '₹1,599.75']) {
        final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: '$text is being ellipsized instead of wrapping',
        );
      }
    });

    testWidgets('stacking still does not overflow the tile', (tester) async {
      await _pumpCard(
        tester,
        _product({
          'price': 1199.10,
          'original_price': 1599.75,
          'name': 'Trueway Farms An Organic Land Nature To Natural Sona Moti '
              'Wheat Sugar Free Whole Grain 15 kg Family Pack',
        }),
      );
      expect(tester.takeException(), isNull);
    });
  });

  /// Height of the photo box.
  double photoHeight(WidgetTester tester) =>
      tester.getSize(find.byType(AppNetworkImage).first).height;

  // The photo used to be an [Expanded], so it absorbed whatever the text below
  // did not use: a one-line title gave a visibly bigger image than a two-line
  // one, and a row of tiles read as ragged even though every tile was the same
  // height. The fix is a fixed aspect ratio for the photo and a fixed line cap
  // for the name.
  group('uniform tiles', () {
    const short = 'Wheat';
    const long = 'Trueway Farms An Organic Land Nature To Natural Sona Moti '
        'Wheat Sugar Free Whole Grain 15 kg Family Pack';

    testWidgets('the photo is the same size whatever the title length',
        (tester) async {
      await _pumpCard(tester, _product({'name': short}));
      final withShortName = photoHeight(tester);

      await _pumpCard(tester, _product({'name': long}));
      final withLongName = photoHeight(tester);

      expect(withShortName, greaterThan(0), reason: 'the premise');
      expect(withLongName, closeTo(withShortName, 0.5));
    });

    testWidgets('the photo is the same size with and without a discount',
        (tester) async {
      await _pumpCard(tester, _product({}));
      final discounted = photoHeight(tester);

      await _pumpCard(tester, _product({'original_price': 921.501}));
      final fullPrice = photoHeight(tester);

      expect(fullPrice, closeTo(discounted, 0.5));
    });

    // The unit price line is absent on a product with no recorded weight. Its
    // height is reserved anyway, or that card's photo would grow by a line.
    testWidgets('the photo is the same size with and without a unit price',
        (tester) async {
      await _pumpCard(tester, _product({}));
      final withUnitPrice = photoHeight(tester);

      await _pumpCard(tester, _product({'weight': 0}));
      expect(find.textContaining('/kg'), findsNothing, reason: 'the premise');

      expect(photoHeight(tester), closeTo(withUnitPrice, 0.5));
    });

    // Most of the catalogue is unrated, so this is the difference that would
    // show up most often in a real grid.
    testWidgets('the photo is the same size rated or not', (tester) async {
      await _pumpCard(
        tester,
        _product({'reviews_avg': 4.5, 'reviews_count': 12}),
      );
      final rated = photoHeight(tester);
      expect(find.byIcon(AppIcons.star), findsWidgets, reason: 'the premise');

      await _pumpCard(tester, _product({'reviews_avg': null}));
      expect(find.byIcon(AppIcons.star), findsNothing, reason: 'the premise');

      expect(photoHeight(tester), closeTo(rated, 0.5));
    });

    // Larger type has to come out of the photo — the tile cannot grow, and the
    // alternative is the 41dp overflow a fixed photo ratio produced here.
    testWidgets('accessibility text shrinks the photo rather than overflowing',
        (tester) async {
      await _pumpCard(tester, _product({}));
      final atDefault = photoHeight(tester);

      await _pumpCard(tester, _product({}), textScale: 2);

      expect(tester.takeException(), isNull);
      expect(photoHeight(tester), lessThan(atDefault));
      expect(photoHeight(tester), greaterThan(0));
    });

    // The same number of lines on every card is what keeps the block below the
    // photo a constant height. Three of them, so these long titles are cut a
    // word or two from the end rather than halfway through.
    testWidgets('the name is capped at three lines', (tester) async {
      await _pumpCard(tester, _product({'name': short}));
      final oneLine = tester.getSize(find.text(short)).height;

      await _pumpCard(tester, _product({'name': long}));
      final capped = tester.getSize(find.text(long)).height;

      expect(capped, closeTo(oneLine * 3, oneLine * 0.3));
      expect(
        tester.renderObject<RenderParagraph>(find.text(long)).didExceedMaxLines,
        isTrue,
        reason: 'a long title should be cut, not allowed to push the layout',
      );
    });

    // The case that broke it before: a price and MRP that wrap to two lines
    // used to steal the difference from the photo. The photo must not move —
    // the extra line goes downward into the tile's slack instead.
    testWidgets('a wrapped price does not shorten the photo', (tester) async {
      await _pumpCard(tester, _product({}));
      final oneLinePrice = photoHeight(tester);

      await _pumpCard(
        tester,
        _product({'price': 1199.10, 'original_price': 1599.75}),
      );

      expect(
        find.text('₹1,599.75'),
        findsOneWidget,
        reason: 'the premise — this pair wraps at this width',
      );
      expect(tester.takeException(), isNull);
      expect(photoHeight(tester), closeTo(oneLinePrice, 0.5));
    });
  });

  group('content', () {
    testWidgets('shows pack size, unit price and discount', (tester) async {
      await _pumpCard(tester, _product({}));

      expect(find.text('5 kg'), findsOneWidget);
      expect(find.textContaining('/kg'), findsOneWidget);
      expect(find.text('29% OFF'), findsOneWidget);
      expect(find.text('ADD'), findsOneWidget);
    });

    testWidgets('omits the pack pill when no weight is recorded',
        (tester) async {
      await _pumpCard(tester, _product({'weight': 0}));
      expect(find.textContaining(' kg'), findsNothing);
      expect(find.textContaining('/kg'), findsNothing);
    });

    testWidgets('hides the discount flag at full price', (tester) async {
      await _pumpCard(tester, _product({'original_price': 921.501}));
      expect(find.textContaining('% OFF'), findsNothing);
    });

    // Stars plus the count, under the name — not a numeric chip floating on
    // the photo, which covered the product and read as part of the packaging.
    testWidgets('shows the rating as stars under the name', (tester) async {
      await _pumpCard(
        tester,
        _product({'reviews_avg': 4.5, 'reviews_count': 12}),
      );

      expect(find.byIcon(AppIcons.star), findsNWidgets(4));
      expect(find.byIcon(AppIcons.starHalf), findsOneWidget,
          reason: '4.5 is four whole stars and a half',);
      // Bare count, no parentheses.
      expect(find.text('12'), findsOneWidget);
      expect(find.text('(12)'), findsNothing);
      // The old chip printed the average as a number. It no longer does.
      expect(find.text('4.5'), findsNothing);
    });

    testWidgets('a whole rating draws no half star', (tester) async {
      await _pumpCard(
        tester,
        _product({'reviews_avg': 4, 'reviews_count': 12}),
      );

      expect(find.byIcon(AppIcons.star), findsNWidgets(5));
      expect(find.byIcon(AppIcons.starHalf), findsNothing);
    });

    // Below the name, so it cannot sit over the product.
    testWidgets('the stars are not on the photo', (tester) async {
      await _pumpCard(
        tester,
        _product({'reviews_avg': 4.5, 'reviews_count': 12}),
      );

      final photo = tester.getRect(find.byType(AppNetworkImage).first);
      final stars = tester.getRect(find.byIcon(AppIcons.star).first);
      expect(stars.top, greaterThan(photo.bottom));
    });

    testWidgets('a five-figure count is grouped', (tester) async {
      await _pumpCard(
        tester,
        _product({'reviews_avg': 4.5, 'reviews_count': 89799}),
      );

      expect(find.text('89,799'), findsOneWidget);
    });

    testWidgets('draws no stars when unrated', (tester) async {
      await _pumpCard(tester, _product({'reviews_avg': null}));

      expect(find.byIcon(AppIcons.star), findsNothing);
      expect(find.text('0.0'), findsNothing);
    });

    testWidgets('omits the review count when there are none', (tester) async {
      await _pumpCard(
        tester,
        _product({'reviews_avg': 5, 'reviews_count': 0}),
      );

      expect(find.byIcon(AppIcons.star), findsNWidgets(5));
      expect(find.text('0'), findsNothing);
    });

    // Stock notes used to sit under the product name; that line is gone.
    testWidgets('no longer prints stock notes under the name', (tester) async {
      await _pumpCard(tester, _product({'stock_status_label': 'On backorder'}));
      expect(find.text('On backorder'), findsNothing);
      expect(find.text('In stock'), findsNothing);
    });

    testWidgets('replaces ADD with a sold-out state', (tester) async {
      await _pumpCard(tester, _product({'is_out_of_stock': true}));
      expect(find.text('ADD'), findsNothing);
      // The slot now carries the back-in-stock offer rather than a struck-out
      // circle; the wording lives on the image overlay, which has room for it.
      expect(find.byKey(const Key('notify-me-card')), findsOneWidget);
      expect(find.text('Out of stock'), findsOneWidget);
    });

    // The tile *does* print an options count now — but it must come from the
    // variation scan, never from `product_options`. That field is a different
    // feature entirely (add-on options, like a gift message), it is empty on
    // every live product, and reading it would label simple products with an
    // options count they do not have.
    testWidgets('never reads product_options as a variant count',
        (tester) async {
      await _pumpCard(
        tester,
        _product({
          'product_options': [
            {'id': 1, 'name': 'Size'},
            {'id': 2, 'name': 'Grind'},
          ],
        }),
      );
      expect(find.text('2 options'), findsNothing);
      expect(find.text('ADD'), findsOneWidget);
    });
  });

  // A cart write is serialised across the whole app, so `busy` is true on every
  // tile while any one of them is being added to. It must not *look* that way:
  // the struck-out circle means out of stock, and painting it on every tile
  // made the entire grid read as unavailable for the length of one request.
  group('while a cart write is in flight', () {
    /// Two tiles in one scope, so one can be added to while the other is
    /// watched.
    Future<FakeCartRepository> pumpPair(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final cart = FakeCartRepository()..gate = Completer<void>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            cartRepositoryProvider.overrideWithValue(cart),
            catalogRepositoryProvider.overrideWithValue(
              FakeCatalogRepository(product: _product({})),
            ),
            homeRepositoryProvider.overrideWithValue(FakeHomeRepository()),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: Row(
                children: [
                  // 160 x 320 is the shape the real grids produce
                  // (Responsive.homeProductAspect). The old 260 was an aspect
                  // no screen in the app asks for, so it overflowed once the
                  // photo stopped absorbing the tile's slack.
                  SizedBox(
                    width: 160,
                    height: 160 / 0.50,
                    child: ProductCard(product: _product({})),
                  ),
                  SizedBox(
                    width: 160,
                    height: 160 / 0.50,
                    child: ProductCard(product: _product({'id': 2})),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return cart;
    }

    testWidgets('no tile shows the sold-out symbol', (tester) async {
      final cart = await pumpPair(tester);

      await tester.tap(find.text('ADD').first);
      await tester.pump();

      expect(find.byIcon(Icons.block_rounded), findsNothing);

      cart.gate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('the tile being added to shows a spinner', (tester) async {
      final cart = await pumpPair(tester);

      await tester.tap(find.text('ADD').first);
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // …and the other tile still offers its ordinary button.
      expect(find.text('ADD'), findsOneWidget);

      cart.gate!.complete();
      await tester.pumpAndSettle();
    });

    // Out of stock replaces the button entirely — which is the point: the
    // symbol must never stand in for "a cart write is in flight".
    testWidgets('a sold-out product still loses its ADD', (tester) async {
      await _pumpCard(tester, _product({'is_out_of_stock': true}));
      expect(find.text('ADD'), findsNothing);
      expect(find.byKey(const Key('notify-me-card')), findsOneWidget);
    });
  });

  group('cart', () {
    testWidgets('ADD swaps to a stepper showing the quantity', (tester) async {
      await _pumpCard(tester, _product({}));

      await tester.tap(find.text('ADD'));
      // ADD first asks whether the product has packs to choose from — the
      // listing cannot say — so the stepper lands a frame later than it used to.
      await tester.pumpAndSettle();

      expect(find.text('ADD'), findsNothing);
      expect(find.text('1'), findsOneWidget);
    });
  });

  group('pack pill', () {
    // Regression: the pill was Flexible beside a Spacer, and a Spacer is an
    // Expanded(flex: 1) — so the two split the free space and the pill got
    // roughly half of what it should. "15.2 kg" rendered as "1…" and shorter
    // labels collapsed to an empty box.
    //
    // These assert on the pill's *rendered width* rather than
    // `didExceedMaxLines`. The default test font draws every glyph as a full em
    // square, so text measures far wider here than in Poppins and an
    // ellipsis-based check reports truncation even for a correct layout.
    // Width is the metric the bug actually moved: ~25dp when squeezed against
    // ~66dp when laid out properly.

    /// Width the pack label is actually given on screen.
    double labelWidth(WidgetTester tester, String text) =>
        tester.getSize(find.text(text)).width;

    testWidgets('gets its full share of the row, not half', (tester) async {
      await _pumpCard(tester, _product({'weight': 15200}));

      expect(find.text('15.2 kg'), findsOneWidget);
      expect(
        labelWidth(tester, '15.2 kg'),
        greaterThan(55),
        reason: 'a competing flex child squeezed this to ~25dp',
      );
    });

    testWidgets('short labels get the same treatment', (tester) async {
      await _pumpCard(tester, _product({'weight': 5100}));
      expect(find.text('5.1 kg'), findsOneWidget);
      expect(labelWidth(tester, '5.1 kg'), greaterThan(55));
    });

    // Wider tiles give enough room that even the oversized test font fits, so
    // here the stricter ellipsis check is meaningful.
    testWidgets('is not ellipsized when the tile has room', (tester) async {
      await _pumpCard(tester, _product({'weight': 15200}), screenWidth: 800);

      final paragraph =
          tester.renderObject<RenderParagraph>(find.text('15.2 kg'));
      expect(paragraph.didExceedMaxLines, isFalse);
    });

    testWidgets('still lays out with no pack size', (tester) async {
      await _pumpCard(tester, _product({'weight': 0}));
      expect(tester.takeException(), isNull);
      expect(find.text('ADD'), findsOneWidget);
    });
  });

  // The category browse screen gives the grid only `screen - 88dp rail`, so its
  // tiles are much narrower than the full-width grids. This is where the card
  // was overlapping and overflowing.
  group('narrow browse-grid tile', () {
    // Derived rather than hardcoded, so it tracks Responsive instead of
    // drifting the next time the aspect ratio moves. This is the geometry
    // CategoryBrowseScreen produces: a 384dp phone minus its 88dp rail, two
    // columns, 8dp of padding and spacing.
    const content = 384.0 - 88.0;
    final columns = Responsive.productColumns(content);
    final narrowWidth = (content - 16 - (8 * (columns - 1))) / columns;
    final narrowHeight = narrowWidth / Responsive.productAspect(content);

    testWidgets('lays out without overflowing', (tester) async {
      await _pumpCardAt(
        tester,
        _product({}),
        width: narrowWidth,
        height: narrowHeight,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives the worst case at this width', (tester) async {
      await _pumpCardAt(
        tester,
        _product({
          'weight': 15200,
          'name': 'Trueway Farms An Organic Land Nature To Natural Sona Moti '
              'Wheat Sugar Free Whole Grain Family Pack',
          'reviews_avg': 4.5,
          'reviews_count': 12345,
        }),
        width: narrowWidth,
        height: narrowHeight,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('still shows the pack size and ADD together', (tester) async {
      await _pumpCardAt(
        tester,
        _product({'weight': 15200}),
        width: narrowWidth,
        height: narrowHeight,
      );

      expect(find.text('ADD'), findsOneWidget);
      // A floor, not a legibility measure: the test font draws every glyph as a
      // full em square, so text measures far wider here than in Poppins. The
      // bug this guards crushed the label to ~25dp.
      expect(
        tester.getSize(find.text('15.2 kg')).width,
        greaterThan(32),
        reason: 'the pack label must not be crushed by the ADD button',
      );
    });
  });

  // Home now shows three tiles across a phone, which is the narrowest the card
  // is ever asked to render.
  group('three-column home tile', () {
    const screen = 384.0;
    final columns = Responsive.homeProductColumns(screen);
    final tileWidth = (screen - 32 - (14 * (columns - 1))) / columns;
    final tileHeight = tileWidth / Responsive.homeProductAspect(screen);

    testWidgets('is three across on a phone', (tester) async {
      expect(columns, 3);
    });

    // The photo is an [Expanded], so the tile's aspect ratio is the only thing
    // that decides how big it gets — and everything below it costs a fixed
    // number of text lines whatever the tile's width. At the old 0.50 that left
    // a 108dp-wide tile a 75dp photo, which read as a squat strip across a tall
    // card. Asserted as a shape rather than a number so it survives a change of
    // screen size.
    testWidgets('gives the photo a roughly square box', (tester) async {
      await _pumpCardAt(
        tester,
        _product({}),
        width: tileWidth,
        height: tileHeight,
      );

      final photo = tester.getSize(find.byType(AppNetworkImage).first);
      expect(
        photo.height,
        greaterThan(photo.width * 0.9),
        reason: 'the image box is squat again',
      );
    });

    testWidgets('lays out without overflowing', (tester) async {
      await _pumpCardAt(
        tester,
        _product({}),
        width: tileWidth,
        height: tileHeight,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives the worst case at this width', (tester) async {
      await _pumpCardAt(
        tester,
        _product({
          'weight': 15200,
          'name': 'Trueway Farms An Organic Land Nature To Natural Sona Moti '
              'Wheat Sugar Free Whole Grain Family Pack',
          'reviews_avg': 4.5,
          'reviews_count': 12345,
          'product_options': [
            {'id': 1, 'name': 'Size'},
            {'id': 2, 'name': 'Grind'},
          ],
        }),
        width: tileWidth,
        height: tileHeight,
      );
      expect(tester.takeException(), isNull);
    });

    // Pack size and button share one line, as in the reference design — the
    // card's smaller type scale is what makes that fit at this width.
    testWidgets('keeps the pack size and ADD on one line', (tester) async {
      await _pumpCardAt(
        tester,
        _product({'weight': 15200}),
        width: tileWidth,
        height: tileHeight,
      );

      expect(find.text('ADD'), findsOneWidget);
      expect(find.text('15.2 kg'), findsOneWidget);

      final pack = tester.getRect(find.text('15.2 kg'));
      final add = tester.getRect(find.text('ADD'));
      expect(
        pack.top,
        lessThan(add.bottom),
        reason: 'they share a row, so their vertical extents overlap',
      );
      expect(
        pack.right,
        lessThanOrEqualTo(add.left),
        reason: 'pack size on the left, button on the right',
      );
    });

    // The compact button still carries the whole stepper.
    testWidgets('keeps the full minus / count / plus stepper', (tester) async {
      await _pumpCardAt(
        tester,
        _product({}),
        width: tileWidth,
        height: tileHeight,
      );

      await tester.tap(find.text('ADD'));
      // ADD first asks whether the product has packs to choose from — the
      // listing cannot say — so the stepper lands a frame later than it used to.
      await tester.pumpAndSettle();

      expect(find.text('1'), findsOneWidget);
      expect(find.byIcon(AppIcons.minus), findsOneWidget);
      expect(find.byIcon(AppIcons.plus), findsOneWidget);
    });

    testWidgets('out of stock still renders', (tester) async {
      await _pumpCardAt(
        tester,
        _product({'is_out_of_stock': true}),
        width: tileWidth,
        height: tileHeight,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Out of stock'), findsOneWidget);
    });

    testWidgets('the stepper fits once the item is in the cart',
        (tester) async {
      await _pumpCardAt(
        tester,
        _product({}),
        width: tileWidth,
        height: tileHeight,
      );

      await tester.tap(find.text('ADD'));
      // ADD first asks whether the product has packs to choose from — the
      // listing cannot say — so the stepper lands a frame later than it used to.
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('1'), findsOneWidget);
    });
  });

  // `POST /ecommerce/products/{id}/notify-me`, offered in the slot ADD would
  // have taken. The controller filters `is_variation:false`, so the id sent is
  // always the parent product's.
  group('out of stock', () {
    Product soldOut() => _product({
          'is_out_of_stock': true,
          'stock_status_label': 'Out of stock',
        });

    Finder notify() => find.byKey(const Key('notify-me-card'));

    String tooltip(WidgetTester tester) =>
        tester
            .widget<Tooltip>(
              find.ancestor(of: notify(), matching: find.byType(Tooltip)),
            )
            .message!;

    testWidgets('replaces ADD instead of covering the photo', (tester) async {
      await _pumpCard(tester, soldOut(), signedIn: true);
      await tester.pump();

      expect(find.text('Out of stock'), findsOneWidget);
      expect(notify(), findsOneWidget);
      // The dead struck-out circle is gone from a tile that has something to
      // offer.
      expect(find.byIcon(Icons.block_rounded), findsNothing);
      // And the control sits in the button row, not over the image.
      expect(
        find.ancestor(of: notify(), matching: find.byType(AppNetworkImage)),
        findsNothing,
      );
    });

    testWidgets('costs no request until it is tapped', (tester) async {
      final catalog = FakeCatalogRepository(product: soldOut());
      await _pumpCard(tester, soldOut(), catalog: catalog, signedIn: true);
      await tester.pumpAndSettle();

      // A grid of sold-out tiles must not status-check every one of them.
      expect(catalog.notifyRequests, isEmpty);

      await tester.tap(notify());
      await tester.pumpAndSettle();

      expect(catalog.notifyRequests, [1]);
    });

    testWidgets('reports the server sentence and settles into it',
        (tester) async {
      final catalog = FakeCatalogRepository(product: soldOut());
      await _pumpCard(tester, soldOut(), catalog: catalog, signedIn: true);
      await tester.pumpAndSettle();

      await tester.tap(notify());
      await tester.pumpAndSettle();

      expect(
        find.text('We will notify you when this product is back in stock.'),
        findsOneWidget,
      );
      // Scoped to the control: the confirmation snack draws its own tick.
      expect(
        find.descendant(
          of: notify(),
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsOneWidget,
      );
      expect(tooltip(tester), contains("We'll email you"));
    });

    testWidgets('a refusal is shown and the offer stays', (tester) async {
      final catalog = FakeCatalogRepository(product: soldOut())
        // The account has no email on file — the notification *is* an email,
        // so the server refuses and names the cause. HTTP 200 with
        // `error:true`, hence a result rather than a throw.
        ..notifyResult = (
          subscribed: false,
          message: 'Your account does not have a valid email address.',
        );
      await _pumpCard(tester, soldOut(), catalog: catalog, signedIn: true);
      await tester.pumpAndSettle();

      await tester.tap(notify());
      await tester.pumpAndSettle();

      expect(
        find.text('Your account does not have a valid email address.'),
        findsOneWidget,
      );
      // Never painted as success.
      expect(
        find.descendant(
          of: notify(),
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsNothing,
      );
      expect(tooltip(tester), 'Notify me when back in stock');
    });

    testWidgets('signed out it offers sign-in rather than a doomed request',
        (tester) async {
      final catalog = FakeCatalogRepository(product: soldOut());
      await _pumpCard(tester, soldOut(), catalog: catalog);
      await tester.pumpAndSettle();

      // The endpoint is `auth:sanctum`; anonymously it can only fail.
      expect(tooltip(tester), 'Sign in to get notified');
      expect(catalog.notifyRequests, isEmpty);
    });
  });
}

/// The rail's tiles are sized so the photo comes out square.
///
/// They used to borrow [Responsive.homeProductAspect], which is tuned for the
/// three-across home grid. That number does give a square photo *there* — but
/// the block under the photo is a fixed number of text lines whatever the
/// tile's width, so the same ratio on the rail's wider tiles produced a photo
/// half again as tall as it was wide, and a rail that ate most of the screen.
void _railGeometry() {
  group('carousel tile geometry', () {
    testWidgets('the photo is square at every phone width', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (c) {
            ctx = c;
            return const SizedBox.shrink();
          },),
        ),
      );

      for (final screen in const [320.0, 360.0, 390.0, 412.0, 640.0]) {
        final cardWidth = CarouselMetrics.cardWidth(screen);
        final cardHeight = CarouselMetrics.cardHeight(ctx, screen);

        // Everything the tile spends below the photo. Derived the same way the
        // card derives it, so this cannot silently disagree with the widget.
        final belowPhoto = cardHeight - cardWidth;

        expect(
          productTileHeightForPhoto(ctx, cardWidth),
          cardHeight,
          reason: 'at ${screen}dp the rail asks for a square photo',
        );
        expect(belowPhoto, greaterThan(0), reason: 'at ${screen}dp');
      }
    });

    testWidgets('a taller photo costs exactly its own extra height',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (c) {
            ctx = c;
            return const SizedBox.shrink();
          },),
        ),
      );

      expect(
        productTileHeightForPhoto(ctx, 200) -
            productTileHeightForPhoto(ctx, 100),
        closeTo(100, 0.001),
      );
    });
  });
}

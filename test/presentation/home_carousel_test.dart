import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/core/network/api_response.dart';
import 'package:trueway_farms/data/repositories/catalog_repository.dart';
import 'package:trueway_farms/data/models/ad_model.dart';
import 'package:trueway_farms/data/models/app_notification.dart';
import 'package:trueway_farms/data/models/category_model.dart';
import 'package:trueway_farms/data/models/home_sections.dart';
import 'package:trueway_farms/data/models/product_model.dart';
import 'package:trueway_farms/data/models/slider_model.dart';
import 'package:trueway_farms/data/repositories/home_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/home_providers.dart';
import 'package:trueway_farms/presentation/providers/notification_provider.dart';
import 'package:trueway_farms/presentation/screens/home/home_screen.dart';
import 'package:trueway_farms/presentation/widgets/product_card.dart';
import 'package:trueway_farms/presentation/widgets/product_carousel.dart';
import 'package:trueway_farms/presentation/widgets/state_views.dart';

import '../support/fake_home_repository.dart';

/// Home merchandising carousels — the four rails fed by ONE call to
/// `/top-products-group`.
///
/// The behaviours worth locking down, in order of how easy they are to
/// regress:
///   * ONE request feeds all four rails. A per-carousel provider would look
///     identical on screen and quadruple the traffic, so it is asserted on the
///     repository call count rather than on pixels.
///   * A failed call must NOT look like an empty catalogue. That is the whole
///     reason `InlineErrorStrip` is here instead of `SizedBox.shrink()`.
///   * An individually empty section is normal (`top_selling` needs paid orders
///     in the last 30 days, `top_rated` needs reviews) and must render nothing
///     at all rather than an empty titled rail.
///
/// No test here touches the network: `homeRepositoryProvider` is overridden
/// with [_FakeHomeRepository], and every other home provider is stubbed.

// =============================================================================
// Fixtures
// =============================================================================

/// A carousel item in the shape the endpoint actually sends.
///
/// Verified against the captured payload: every `/top-products-group` item is
/// serialized by `AvailableProductResource`, the same resource
/// `/ecommerce/products` uses — the two produce a set-identical 28-key object.
/// The keys below are that exact set, which is why [Product.fromJson] is the
/// right parser and no home-specific product model exists.
Map<String, dynamic> _rawItem(int id, {Object? reviewsAvg = '4.5000'}) => {
      'id': id,
      'slug': 'carousel-product-$id',
      'name': 'Organic Carousel Product $id',
      'sku': 'SKU-$id',
      'price': 899.0,
      'price_formatted': '₹899.00',
      'original_price': 999.0,
      'original_price_formatted': '₹999.00',
      'quantity': 12,
      'is_out_of_stock': false,
      'stock_status_label': 'In stock',
      'stock_status_html': '<span>In stock</span>',
      // Nullable in the live payload — products 119 and 120 in the captured
      // `/top-products-group` response have no reviews and come back with
      // `reviews_avg: null`, so this has to be overridable, not a constant.
      'reviews_avg': reviewsAvg,
      'reviews_count': reviewsAvg == null ? 0 : 6,
      'weight': 1000,
      'height': 0,
      // `wide`, not `width` — the live resource has no `width` key at all.
      'wide': 0,
      'length': 0,
      'description': 'Stone ground, single origin.',
      'content': '<p>Stone ground, single origin.</p>',
      'image_url': '',
      'images': <String>[],
      'images_thumb': <String>[],
      'image_with_sizes': <String, dynamic>{},
      'videos': <dynamic>[],
      'store': <String, dynamic>{},
      'product_options': <dynamic>[],
      'product_conditions': <dynamic>[],
    };

List<Product> _products(int count, {int from = 0}) =>
    List.generate(count, (i) => Product.fromJson(_rawItem(from + i)));

/// All four rails populated.
HomeSections _fullSections() => HomeSections(
      topSelling: _products(3, from: 100),
      trending: _products(3, from: 200),
      recentlyAdded: _products(3, from: 300),
      topRated: _products(3, from: 400),
    );

const _networkFailure = ApiException(
  'No internet connection. Check your network and try again.',
  kind: ApiErrorKind.network,
);

// =============================================================================
// Fake repository
// =============================================================================

/// Stands in for [HomeRepository] without a socket in sight.
///
/// [calls] is the point of the whole exercise: the four rails must cost exactly
/// one `sections()` invocation.
class _FakeHomeRepository extends HomeRepository {
  _FakeHomeRepository(super.api, {required this.responses});

  /// One entry per expected call, consumed in order; the last entry is reused
  /// once exhausted, so a retry test simply supplies [failure, success].
  final List<FutureOr<HomeSections> Function()> responses;

  int calls = 0;
  int? lastLimit;

  @override
  Future<HomeSections> sections({int limit = HomeRepository.defaultSectionLimit}) async {
    lastLimit = limit;
    final builder = responses[calls < responses.length ? calls : responses.length - 1];
    calls++;
    return builder();
  }
}

/// Counts the category listing the feed switches to when a tab is picked.
class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository(super.api);

  int categoryPageCalls = 0;

  @override
  Future<PaginatedResponse<Product>> productsByCategory(
    int categoryId, {
    int page = 1,
    int perPage = 20,
    String? sort,
    List<int> attributeIds = const [],
    List<int> tagIds = const [],
    List<int> brandIds = const [],
    List<String> ratings = const [],
    List<String> discounts = const [],
    List<int> collectionIds = const [],
    double? minPrice,
    double? maxPrice,
    bool inStockOnly = false,
  }) async {
    categoryPageCalls++;
    return PaginatedResponse(
      items: _products(2, from: 700),
      meta: PaginationMeta.single(2),
    );
  }
}

// =============================================================================
// Harness
// =============================================================================

/// The default test surface is 800×600, and the feed is a [CustomScrollView] —
/// a rail below the viewport's cache extent is never built, so `findsNWidgets`
/// would fail for a layout reason rather than a wiring one. A tall surface puts
/// all four rails on screen at once, which is what lets these assertions be
/// about the wiring. The width is a real phone width so the card metrics stay
/// representative.
const Size _phoneTall = Size(411, 3000);

/// Pumps [child] with everything the home feed reads, with every network-backed
/// provider stubbed. Only `homeSectionsProvider` is left live — it is the thing
/// under test, and it resolves through the returned [_FakeHomeRepository].
Future<_FakeHomeRepository> _pumpHome(
  WidgetTester tester, {
  required List<FutureOr<HomeSections> Function()> responses,
  Widget child = const HomeScreen(),
  Size size = _phoneTall,
  List<Category> categories = const [],
  List<Override> extra = const [],
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final repo = _FakeHomeRepository(ApiClient(prefs: prefs), responses: responses);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        homeRepositoryProvider.overrideWithValue(repo),
        // The rest of the feed is not under test; stubbed so nothing dials out
        // and so the carousels are the only thing that can move.
        slidersProvider.overrideWith((ref) async => const <HomeSlider>[]),
        adsProvider.overrideWith((ref) async => const <AdBanner>[]),
        categoriesProvider.overrideWith((ref) async => categories),
        featuredProductsProvider.overrideWith((ref) async => const <Product>[]),
        notificationStatsProvider
            .overrideWith((ref) async => const NotificationStats()),
        ...extra,
      ],
      child: MaterialApp(theme: AppTheme.light, home: child),
    ),
  );
  return repo;
}

void main() {
  // ===========================================================================
  // ProductCarousel — the widget on its own
  // ===========================================================================
  group('ProductCarousel', () {
    Future<void> pumpCarousel(WidgetTester tester, Widget child) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            // Tiles ask which products are variable; stubbed empty.
            homeRepositoryProvider.overrideWithValue(FakeHomeRepository()),
          ],
          child: MediaQuery(
            data: const MediaQueryData(size: Size(411, 890)),
            child: MaterialApp(
              theme: AppTheme.light,
              home: Scaffold(body: child),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('renders a header and one card per product', (tester) async {
      await pumpCarousel(
        tester,
        ProductCarousel(
          title: 'Best sellers',
          subtitle: 'What shoppers buy most',
          products: _products(3),
        ),
      );

      expect(find.text('Best sellers'), findsOneWidget);
      expect(find.text('What shoppers buy most'), findsOneWidget);
      // Exactly one card per product: `findsWidgets` would pass on a rail that
      // silently dropped two of the three.
      expect(find.byType(ProductCard), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('scrolls horizontally without overflowing', (tester) async {
      await pumpCarousel(
        tester,
        ProductCarousel(title: 'Trending now', products: _products(8)),
      );

      await tester.drag(find.byType(ListView), const Offset(-600, 0));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    // A rail with nothing in it must occupy no space at all — an empty titled
    // header reads as "this collection is broken".
    testWidgets('collapses to nothing when the list is empty', (tester) async {
      await pumpCarousel(
        tester,
        const ProductCarousel(title: 'Top rated', products: []),
      );

      expect(find.text('Top rated'), findsNothing);
      expect(find.byType(ProductCard), findsNothing);
    });

    // The skeleton lives in a SliverToBoxAdapter on home, which imposes no
    // height limit; a rail that measured itself from its parent would throw
    // "Vertical viewport was given unbounded height" during load.
    testWidgets('skeleton survives an unbounded height constraint', (tester) async {
      await pumpCarousel(
        tester,
        CustomScrollView(
          slivers: const [
            SliverToBoxAdapter(child: ProductCarouselSkeleton()),
          ],
        ),
      );

      expect(tester.takeException(), isNull);
    });

    test('every section kind has an icon and a subtitle', () {
      for (final kind in HomeSectionKind.values) {
        expect(subtitleForSectionKind(kind), isNotEmpty);
        expect(iconForSectionKind(kind), isNotNull);
        expect(kind.title, isNotEmpty);
      }
    });

    // No subtitle may assert a window, a count or a period the payload does
    // not carry — "Popular this week" is a claim about backend behaviour the
    // app has never verified.
    //
    // `now` and `right now` are in the list because the first version of this
    // guard omitted them and the trending subtitle read "Popular with shoppers
    // right now" — a live-popularity claim about a section the app has no
    // definition for, which in the captured payload is simply every product in
    // the catalogue in ascending id order.
    test('no subtitle invents a time window', () {
      for (final kind in HomeSectionKind.values) {
        expect(
          subtitleForSectionKind(kind).toLowerCase(),
          isNot(
            matches(r'\b(today|now|this week|this month|hour|24|latest|live)\b'),
          ),
          reason: '${kind.name} claims a window the endpoint never states',
        );
      }
    });

    testWidgets('the skeleton header grows with the text scale', (tester) async {
      Future<double> headerAt(double scale) async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            // Tiles ask which products are variable; stubbed empty.
            homeRepositoryProvider.overrideWithValue(FakeHomeRepository()),
          ],
            child: MaterialApp(
              theme: AppTheme.light,
              builder: (ctx, child) => MediaQuery(
                data: MediaQuery.of(ctx)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const Scaffold(
                body: SingleChildScrollView(child: ProductCarouselSkeleton()),
              ),
            ),
          ),
        );
        await tester.pump();
        return tester.getSize(find.byType(ProductCarouselSkeleton)).height;
      }

      final small = await headerAt(1);
      final large = await headerAt(2);

      // The card geometry is width-derived and identical at both scales, so any
      // growth here is the header. It used to be three fixed-pixel boxes: the
      // placeholder stayed 62dp tall while the real SectionHeader grew to 189dp
      // at 2x, and the feed lurched when the rails landed.
      expect(large, greaterThan(small),
          reason: 'the placeholder header ignores the user text size',);
    });
  });

  // ===========================================================================
  // Duplicate rows — a live-payload fact, not a hypothetical
  // ===========================================================================
  group('dedupeProducts', () {
    test('keeps the first occurrence and the server ordering', () {
      // `top_selling` in the captured `/top-products-group` response is
      // literally [118, 118, 119].
      final rail = [
        Product.fromJson(_rawItem(118)),
        Product.fromJson(_rawItem(118)),
        Product.fromJson(_rawItem(119)),
      ];

      expect(dedupeProducts(rail).map((p) => p.id), [118, 119]);
    });

    test('leaves a clean rail untouched', () {
      final rail = _products(3, from: 10);
      expect(dedupeProducts(rail).map((p) => p.id), [10, 11, 12]);
    });

    test('an all-duplicate rail collapses to one card, not to empty', () {
      final rail = [
        Product.fromJson(_rawItem(7)),
        Product.fromJson(_rawItem(7)),
      ];
      expect(dedupeProducts(rail), hasLength(1));
    });
  });

  // ===========================================================================
  // The carousel item shape
  // ===========================================================================
  group('carousel payload', () {
    // Guards the claim the whole slice rests on: carousel items carry the full
    // `/ecommerce/products` product shape, so ProductCard needs no special
    // casing. If the backend ever trims the resource for this endpoint, the
    // price and rating below are what break first.
    test('parses with Product.fromJson, prices and rating intact', () {
      final section = HomeSections.fromJson({
        'error': false,
        'message': null,
        'data': {
          'top_selling': [_rawItem(1)],
          'trending': <dynamic>[],
          'recently_added': <dynamic>[],
          'top_rated': <dynamic>[],
        },
      });

      expect(section.topSelling, hasLength(1));
      final p = section.topSelling.single;
      expect(p.id, 1);
      expect(p.name, 'Organic Carousel Product 1');
      // Server-formatted money survives — nothing is recomputed client side.
      expect(p.priceFormatted, '₹899.00');
      expect(p.price, 899.0);
      expect(p.hasDiscount, isTrue);
      expect(p.inStock, isTrue);
      // Only the non-empty rail is offered for display.
      expect(section.sections, hasLength(1));
      expect(section.sections.single.kind, HomeSectionKind.topSelling);
    });
  });

  // ===========================================================================
  // Home screen wiring
  // ===========================================================================
  group('HomeScreen sections', () {
    testWidgets('shows carousel skeletons while the call is in flight',
        (tester) async {
      final never = Completer<HomeSections>();
      await _pumpHome(tester, responses: [() => never.future]);
      await tester.pump();

      expect(find.byType(ProductCarouselSkeleton), findsWidgets);
      expect(find.byType(InlineErrorStrip), findsNothing);
      expect(tester.takeException(), isNull);

      never.complete(HomeSections.empty);
      await tester.pumpAndSettle();
    });

    testWidgets('renders all four rails from ONE repository call',
        (tester) async {
      final repo = await _pumpHome(tester, responses: [_fullSections]);
      await tester.pumpAndSettle();

      // The entire point of `/top-products-group`: four merchandising rows for
      // a single round trip. A per-carousel provider would make this 4.
      expect(repo.calls, 1);
      expect(find.byType(ProductCarousel), findsNWidgets(4));
      for (final kind in HomeSectionKind.values) {
        expect(find.text(kind.title), findsOneWidget);
      }
      expect(find.byType(InlineErrorStrip), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('asks for more than the endpoint default, inside its cap',
        (tester) async {
      final repo = await _pumpHome(tester, responses: [_fullSections]);
      await tester.pumpAndSettle();

      // `limit=1` is a live 500 and the server hard-caps at 20; four cards is
      // too thin to scroll.
      expect(repo.lastLimit, kHomeSectionLimit);
      expect(kHomeSectionLimit, greaterThan(HomeRepository.minSectionLimit));
      expect(kHomeSectionLimit, lessThanOrEqualTo(HomeRepository.maxSectionLimit));
    });

    // The distinction the slice exists for.
    testWidgets('a failed call shows an error strip, not silence',
        (tester) async {
      await _pumpHome(tester, responses: [() => throw _networkFailure]);
      await tester.pumpAndSettle();

      expect(find.byType(InlineErrorStrip), findsOneWidget);
      expect(find.textContaining('featured collections'), findsOneWidget);
      expect(find.byType(ProductCarousel), findsNothing);
      // The rest of the feed keeps working around the hole.
      expect(find.text('Fresh picks'), findsOneWidget);
    });

    testWidgets('retry refetches and replaces the strip with the rails',
        (tester) async {
      final repo = await _pumpHome(
        tester,
        responses: [() => throw _networkFailure, _fullSections],
      );
      await tester.pumpAndSettle();

      expect(find.byType(InlineErrorStrip), findsOneWidget);
      expect(repo.calls, 1);

      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();

      expect(repo.calls, 2);
      expect(find.byType(InlineErrorStrip), findsNothing);
      expect(find.byType(ProductCarousel), findsNWidgets(4));
    });

    // Not an error: `top_selling` is computed from the last 30 days of paid
    // orders and `top_rated` needs reviews, so a quiet month legitimately
    // empties rails. They must vanish rather than render titled voids.
    testWidgets('empty sections are dropped, not rendered as empty rails',
        (tester) async {
      await _pumpHome(
        tester,
        responses: [
          () => HomeSections(
                topSelling: const [],
                trending: _products(3, from: 200),
                recentlyAdded: const [],
                topRated: _products(3, from: 400),
              ),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.byType(ProductCarousel), findsNWidgets(2));
      expect(find.text(HomeSectionKind.trending.title), findsOneWidget);
      expect(find.text(HomeSectionKind.topRated.title), findsOneWidget);
      expect(find.text(HomeSectionKind.topSelling.title), findsNothing);
      expect(find.text(HomeSectionKind.recentlyAdded.title), findsNothing);
      expect(find.byType(InlineErrorStrip), findsNothing);
    });

    // The shape of the real response, not a tidied fixture: the live
    // `top_selling` repeats product 118. Rendering it verbatim puts the same
    // card on screen twice.
    testWidgets('a rail that repeats a product renders it once', (tester) async {
      await _pumpHome(
        tester,
        responses: [
          () => HomeSections(
                topSelling: [
                  Product.fromJson(_rawItem(118)),
                  Product.fromJson(_rawItem(118)),
                  Product.fromJson(_rawItem(119)),
                ],
                trending: const [],
                recentlyAdded: const [],
                topRated: const [],
              ),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.byType(ProductCarousel), findsOneWidget);
      expect(find.byType(ProductCard), findsNWidgets(2));
      expect(find.text('Organic Carousel Product 118'), findsOneWidget);
    });

    // Larger accessibility text must not paint overflow stripes across the
    // feed. The rails size themselves from the *width*, so nothing about them
    // reacts to the text scale unless it is asserted.
    testWidgets('rails survive 2x accessibility text', (tester) async {
      await tester.binding.setSurfaceSize(_phoneTall);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = _FakeHomeRepository(
        ApiClient(prefs: prefs),
        responses: [_fullSections],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            homeRepositoryProvider.overrideWithValue(repo),
            slidersProvider.overrideWith((ref) async => const <HomeSlider>[]),
            adsProvider.overrideWith((ref) async => const <AdBanner>[]),
            categoriesProvider.overrideWith((ref) async => const <Category>[]),
            featuredProductsProvider
                .overrideWith((ref) async => const <Product>[]),
            notificationStatsProvider
                .overrideWith((ref) async => const NotificationStats()),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(ctx)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const HomeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ProductCarousel), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    });

    testWidgets('all four empty renders no rails and no error', (tester) async {
      await _pumpHome(tester, responses: [() => HomeSections.empty]);
      await tester.pumpAndSettle();

      expect(find.byType(ProductCarousel), findsNothing);
      expect(find.byType(ProductCarouselSkeleton), findsNothing);
      expect(find.byType(InlineErrorStrip), findsNothing);
      // The feed still stands on its own.
      expect(find.text('Fresh picks'), findsOneWidget);
    });

    // Pull-to-refresh has to invalidate the sections too, or the one thing the
    // user is most likely to be refreshing for — new arrivals — is the one
    // thing that never updates.
    //
    // A phone-sized surface here, unlike the rest of the group: RefreshIndicator
    // only fires once the overscroll passes 25% of its container's height, so on
    // the 3000dp surface the gesture would have to be 750dp long.
    // Not every failure can be retried — a 404 on both the prefixed and the
    // legacy `/top-products-group` path is a deployment fact, not a blip. What
    // must never happen is the failure rendering as *nothing*, which is how a
    // dead endpoint gets mistaken for an empty catalogue.
    testWidgets('a non-retryable failure is still admitted, not hidden',
        (tester) async {
      await _pumpHome(tester, responses: [
        () => throw const ApiException(
              'Not found',
              kind: ApiErrorKind.notFound,
              statusCode: 404,
            ),
      ],);
      await tester.pumpAndSettle();

      expect(find.byType(InlineErrorStrip), findsOneWidget);
      expect(find.textContaining('featured collections'), findsOneWidget);
      expect(find.byType(ProductCarousel), findsNothing);
      // And it does not offer an action that cannot work.
      expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
    });

    // Two of the four products in the live payload have no reviews at all, so
    // `reviews_avg` arrives as null. The fixture used to hardcode a rating,
    // which meant nothing here ever exercised the unrated path.
    testWidgets('a rail of unrated products renders without a rating chip',
        (tester) async {
      await _pumpHome(
        tester,
        responses: [
          () => HomeSections(
                topSelling: [
                  Product.fromJson(_rawItem(119, reviewsAvg: null)),
                  Product.fromJson(_rawItem(120, reviewsAvg: null)),
                ],
                trending: const [],
                recentlyAdded: const [],
                topRated: const [],
              ),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.byType(ProductCard), findsNWidgets(2));
      // No invented "0.0 ★" on a product nobody has rated.
      expect(find.textContaining('0.0'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pull-to-refresh refetches the sections', (tester) async {
      final repo = await _pumpHome(
        tester,
        responses: [_fullSections],
        size: const Size(411, 890),
      );
      await tester.pumpAndSettle();
      expect(repo.calls, 1);

      await tester.fling(find.byType(CustomScrollView), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();

      expect(repo.calls, 2);
      // Still populated afterwards — a refresh must not blank the rails.
      expect(find.byType(ProductCarousel), findsWidgets);
      expect(find.byType(InlineErrorStrip), findsNothing);
    });

    // Picking a category replaces the entire feed with a plain grid — the
    // rails, the sliders and Fresh picks are not built at all. The refresh
    // gesture therefore has to refetch the *grid*; refreshing the rails instead
    // spun the indicator, fired five requests for content that is not on
    // screen, and left the one list the user was looking at untouched.
    testWidgets('pull-to-refresh inside a category refreshes the grid, '
        'not the off-screen rails', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final catalog = _FakeCatalogRepository(ApiClient(prefs: prefs));

      final repo = await _pumpHome(
        tester,
        responses: [_fullSections],
        size: const Size(411, 890),
        categories: const [
          Category(id: 17, name: 'Wheat', slug: 'wheat', parentId: 0),
        ],
        extra: [catalogRepositoryProvider.overrideWithValue(catalog)],
      );
      await tester.pumpAndSettle();
      expect(repo.calls, 1);

      await tester.tap(find.widgetWithText(InkWell, 'Wheat'));
      await tester.pumpAndSettle();
      expect(catalog.categoryPageCalls, 1);
      expect(find.byType(ProductCarousel), findsNothing);

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();

      // The grid on screen was refetched…
      expect(catalog.categoryPageCalls, 2);
      // …and the rails, which are not built at all here, were not.
      expect(repo.calls, 1);
    });
  });
}

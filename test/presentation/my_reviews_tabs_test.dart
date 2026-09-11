import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/network/api_response.dart';
import 'package:trueway_farms/data/models/review.dart';
import 'package:trueway_farms/data/repositories/review_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:go_router/go_router.dart';
import 'package:trueway_farms/presentation/screens/product/my_reviews_screen.dart';

/// The "To review" tab.
///
/// It shipped rendering **nothing** while its own tab label said "(1)": the
/// theme's OutlinedButton carries `minimumSize: Size.fromHeight(54)`, and
/// `Size.fromHeight` is `Size(double.infinity, 54)`. A Row gives a non-flex
/// child an unbounded width, so that minimum resolved to an *infinite* width —
/// an invalid constraint. Layout threw, and the whole tab painted blank while
/// the count above it, computed from the same data, was right.
///
/// A count that disagrees with an empty list is the shape of this bug, so both
/// are asserted together below.

class _FakeReviewRepository implements ReviewRepository {
  _FakeReviewRepository({this.pending = const [], this.mine = const []});

  final List<ReviewableProduct> pending;
  final List<Review> mine;

  @override
  Future<List<ReviewableProduct>> productsToReview({int limit = 12}) async =>
      pending;

  @override
  Future<PaginatedResponse<Review>> myReviews({
    int page = 1,
    int perPage = 10,
  }) async =>
      PaginatedResponse(items: mine, meta: PaginationMeta.single(mine.length));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'FakeReviewRepository does not implement ${invocation.memberName}',
      );
}

/// The row the live endpoint produces.
const _waiting = ReviewableProduct(
  id: 118,
  name: 'Trueway Farms Organic Desi Khand Brown (khandsari)',
  slug: 'trueway-farms-organic-desi-khand-brown-khandsari',
  image: '',
  orderId: 285,
);

/// One of the customer's own reviews, with a photo and a long comment — the
/// two things the list row cannot show.
final _mine = Review.fromJson({
  'id': 1016,
  'star': 5,
  'user_name': 'Suraj',
  'comment': 'Lorem Ipsum is simply dummy text of the printing and '
      'typesetting industry, and it runs well past the three lines the list '
      'row clamps it to.',
  'created_at': '4 weeks ago',
  'status': 'published',
  'status_text': 'Published',
  'images': [
    {'thumbnail': '', 'full_url': ''},
  ],
  'product': {
    'id': 111,
    'name': 'Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu)',
    'slug': 'sona-moti-wheat',
  },
});

Future<void> _pump(
  WidgetTester tester, {
  List<ReviewableProduct> pending = const [_waiting],
  List<Review> mine = const [],
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        reviewRepositoryProvider.overrideWithValue(
          _FakeReviewRepository(pending: pending, mine: mine),
        ),
      ],
      // Routed, so "did it navigate to the product page" is answerable.
      child: MaterialApp.router(
        theme: AppTheme.light,
        routerConfig: GoRouter(
          initialLocation: '/reviews',
          routes: [
            GoRoute(
              path: '/reviews',
              builder: (_, __) => const MyReviewsScreen(),
            ),
            GoRoute(
              path: '/product/:slug',
              builder: (_, state) => Scaffold(
                body: Center(
                  child: Text('at product ${state.pathParameters['slug']}'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lays out without throwing', (tester) async {
    await _pump(tester);

    expect(
      tester.takeException(),
      isNull,
      reason: 'an invalid constraint here blanks the whole tab',
    );
  });

  // The bug's exact signature: the label counted one thing, the body showed
  // none. Asserted together so the two can never drift apart again.
  testWidgets('a counted product is actually on screen', (tester) async {
    await _pump(tester);

    expect(find.text('To review (1)'), findsOneWidget);
    expect(find.textContaining('Desi Khand'), findsOneWidget);
    expect(find.byKey(const Key('review-now-118')), findsOneWidget);
    expect(find.textContaining('Nothing waiting'), findsNothing);
  });

  // The row used to print "Order #285". `GET /reviews/reviewable` sends
  // `order_id` and no code, and a bare numeric id is not an identifier this
  // shop shows its customers — every other screen gives them an `SF…` code.
  testWidgets('does not print the internal order id', (tester) async {
    await _pump(tester);

    expect(find.textContaining('Order #'), findsNothing);
    // The product name is what makes the row recognisable.
    expect(find.textContaining('Desi Khand'), findsOneWidget);
  });

  testWidgets('an empty list says so instead of rendering nothing',
      (tester) async {
    await _pump(tester, pending: const []);

    expect(find.text('To review (0)'), findsOneWidget);
    expect(find.textContaining('Nothing waiting'), findsOneWidget);
  });

  // Tapping a row used to route to the **product page**, which lost the thing
  // that was tapped: the row clamps the comment to three lines and shows no
  // photos at all, so there was no way to read your own review back.
  group('opening your own review', () {
    Future<void> openIt(WidgetTester tester) async {
      await tester.tap(find.text('Reviewed (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('my-review-1016')));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the review, not the product page', (tester) async {
      await _pump(tester, mine: [_mine]);
      await openIt(tester);

      expect(
        find.textContaining('at product'),
        findsNothing,
        reason: 'the tap must not navigate away',
      );
      expect(
        find.byKey(const Key('my-review-open-product')),
        findsOneWidget,
        reason: 'the sheet is what opened',
      );
      // Two copies: the row behind the sheet still holds its clamped one.
      expect(find.textContaining('past the three lines'), findsWidgets);
    });

    // The row clamps to three lines; the sheet is where the rest of it is.
    testWidgets('the comment is not clamped in the sheet', (tester) async {
      await _pump(tester, mine: [_mine]);
      await openIt(tester);

      final paragraphs = tester
          .widgetList<Text>(find.textContaining('past the three lines'))
          .toList();
      expect(
        paragraphs.any((t) => t.maxLines == null),
        isTrue,
        reason: 'one of them must render in full',
      );
    });

    testWidgets('the product is still one tap away', (tester) async {
      await _pump(tester, mine: [_mine]);
      await openIt(tester);

      await tester.tap(find.byKey(const Key('my-review-open-product')));
      await tester.pumpAndSettle();

      expect(find.text('at product sona-moti-wheat'), findsOneWidget);
    });

    testWidgets('names the product it is about', (tester) async {
      await _pump(tester, mine: [_mine]);
      await openIt(tester);

      expect(find.textContaining('Sona Moti Wheat'), findsWidgets);
    });
  });

  // Several rows is where an unbounded-width child would fail hardest.
  testWidgets('several waiting products all render', (tester) async {
    await _pump(
      tester,
      pending: const [
        _waiting,
        ReviewableProduct(id: 111, name: 'Sona Moti Wheat', slug: 'wheat'),
      ],
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('review-now-118')), findsOneWidget);
    expect(find.byKey(const Key('review-now-111')), findsOneWidget);
  });
}

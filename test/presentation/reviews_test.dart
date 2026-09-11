import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/data/models/review.dart';
import 'package:trueway_farms/data/repositories/review_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/review_provider.dart';
import 'package:trueway_farms/presentation/screens/product/product_detail_screen.dart';
import 'package:trueway_farms/presentation/widgets/app_network_image.dart';
import 'package:trueway_farms/presentation/widgets/media_viewer.dart';
import 'package:trueway_farms/presentation/widgets/review_tile.dart';
import 'package:trueway_farms/presentation/widgets/state_views.dart';

/// Reviews slice: the provider's paging walk, the tile's avatar/media
/// decisions, and the product-page section's four states.
///
/// Nothing here touches the network — [_FakeReviewRepository] stands in for the
/// real one through `reviewRepositoryProvider`.

// ---------------------------------------------------------------------------
// Fixtures. Shaped exactly like a captured
// GET /ecommerce/products/{slug}/reviews row.
// ---------------------------------------------------------------------------

/// A base64 `data:` avatar, the case the tile must NOT decode. Truncated: the
/// point is the scheme, and the tile is never allowed to look past it.
const _inlineAvatar = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAYABgAAD';

Map<String, dynamic> _reviewJson(
  int id, {
  String name = 'Suraj ojha',
  String? avatar = _inlineAvatar,
  int star = 5,
  String comment = 'Great product, arrived fresh.',
  bool media = false,
  /// How many photos the strip carries. The captured feed has a review with 6
  /// photos and 2 videos, so an overflowing strip is the real case.
  int imageCount = 1,
  bool purchased = true,
}) =>
    {
      'id': id,
      'user_name': name,
      'user_avatar': avatar,
      'created_at_tz': '2026-07-16T16:25:29+05:30',
      'created_at': '2 weeks ago',
      'comment': comment,
      'star': star,
      'status': 'published',
      'status_text': 'Published',
      'images': media
          ? [
              for (var n = 0; n < imageCount; n++)
                {
                  'thumbnail': 'https://example.test/a$n-150x150.jpg',
                  'full_url': 'https://example.test/a$n.jpg',
                },
            ]
          : <dynamic>[],
      'videos': media
          ? [
              // thumbnail IS the mp4 — the server maps both keys through the
              // same getImageUrl call.
              {
                'thumbnail': 'https://example.test/clip.mp4',
                'full_url': 'https://example.test/clip.mp4',
              },
            ]
          : <dynamic>[],
      if (purchased) 'ordered_at_tz': '2025-12-10T17:28:52+05:30',
      if (purchased) 'ordered_at': '✅ Purchased 7 months ago',
    };

Review _review(
  int id, {
  String? avatar = _inlineAvatar,
  bool media = false,
  int imageCount = 1,
  String comment = 'Great product, arrived fresh.',
}) =>
    Review.fromJson(
      _reviewJson(
        id,
        avatar: avatar,
        media: media,
        imageCount: imageCount,
        comment: comment,
      ),
    );

/// A comment the length of a real one. Every review captured on products 111
/// and 118 is 582-633 characters; a four-line clamp hides most of it.
const _longComment =
    'Lorem Ipsum is simply dummy text of the printing and typesetting industry. '
    "Lorem Ipsum has been the industry's standard dummy text ever since 1966, "
    'when designers at Letraset and James Mosley, the librarian of the St Bride '
    'Printing Library in London, revived it for use on dry-transfer sheets. It '
    'has survived not only five centuries, but also the leap into electronic '
    'typesetting, remaining essentially unchanged. It was popularised in the '
    '1960s with the release of Letraset sheets containing Lorem Ipsum passages, '
    'and more recently with desktop publishing software like Aldus PageMaker '
    'including versions of Lorem Ipsum. THE_TAIL_END_OF_THE_REVIEW';

ProductReviewPage _page(
  List<Review> reviews, {
  required int perPage,
  int page = 1,
  int? total,
  Review? userReview,
}) =>
    ProductReviewPage(
      reviews: reviews,
      hasReviewed: userReview != null,
      userReview: userReview,
      isLastPage: reviews.length < perPage ||
          (total != null && page * perPage >= total),
      message: total == null ? null : '$total review(s) for "Desi Khand"',
    );

// ---------------------------------------------------------------------------
// Fake repository
// ---------------------------------------------------------------------------

/// Implements the repository interface rather than subclassing it, so no
/// ApiClient (and therefore no Dio, no socket) is ever constructed.
class _FakeReviewRepository implements ReviewRepository {
  _FakeReviewRepository({
    this.pages = const {},
    this.error,
    this.delay,
    this.userReview,
    this.total,
    this.failOnPage,
    this.rawError,
  });

  /// page number -> the reviews that page returns.
  final Map<int, List<Review>> pages;
  final ApiException? error;
  final Duration? delay;
  final Review? userReview;
  final int? total;

  /// Fail only this page, so the *paging* failure path can be exercised
  /// without losing the pages already on screen.
  final int? failOnPage;

  /// A throw that is deliberately NOT an ApiException — what a contract change
  /// that trips the model parser looks like from the notifier's side.
  final Object? rawError;

  final List<int> requestedPages = [];

  @override
  Future<ProductReviewPage> productReviews(
    String slug, {
    int page = 1,
    int perPage = ReviewRepository.defaultPerPage,
    int? star,
  }) async {
    requestedPages.add(page);
    if (delay != null) await Future<void>.delayed(delay!);
    if (rawError != null) throw rawError!;
    if (error != null) throw error!;
    if (failOnPage == page) throw ApiException.local('Page $page failed');
    return _page(
      pages[page] ?? const [],
      perPage: perPage,
      page: page,
      total: total,
      userReview: page == 1 ? userReview : null,
    );
  }

  @override
  Future<ProductReviewPage> allProductReviews(
    String slug, {
    int perPage = ReviewRepository.defaultPerPage,
    int? star,
  }) =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

Future<Widget> _wrap(
  Widget child, {
  required _FakeReviewRepository repo,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      reviewRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    ),
  );
}

/// Scrolls the sheet's list to its end and lets the resulting load settle.
Future<void> _scrollListToBottom(WidgetTester tester) async {
  final controller =
      tester.widget<ListView>(find.byType(ListView)).controller!;
  controller.jumpTo(controller.position.maxScrollExtent);
  await tester.pumpAndSettle();
}

void main() {
  const slug = 'desi-khand';

  // -------------------------------------------------------------------------
  // Section states
  // -------------------------------------------------------------------------

  testWidgets('section shows skeletons while the first page is in flight',
      (tester) async {
    final repo = _FakeReviewRepository(
      pages: {1: [_review(1)]},
      delay: const Duration(milliseconds: 50),
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pump();

    expect(find.byType(ReviewTileSkeleton), findsWidgets);
    expect(find.byType(ReviewTile), findsNothing);

    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(ReviewTileSkeleton), findsNothing);
    expect(find.byType(ReviewTile), findsOneWidget);
  });

  testWidgets('section shows a retryable inline error and recovers',
      (tester) async {
    // First mount fails; the retry gets a repository that succeeds.
    final failing = _FakeReviewRepository(
      error: ApiException.local('Network unreachable'),
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: failing),
    );
    await tester.pumpAndSettle();

    expect(find.byType(InlineErrorStrip), findsOneWidget);
    expect(find.textContaining('Network unreachable'), findsOneWidget);

    // Retry is wired: tapping it re-issues the request.
    expect(failing.requestedPages, [1]);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(failing.requestedPages, [1, 1]);
    // Still failing, so the strip stays rather than silently vanishing.
    expect(find.byType(InlineErrorStrip), findsOneWidget);
  });

  testWidgets('section shows an empty state when the product has no reviews',
      (tester) async {
    final repo = _FakeReviewRepository(pages: const {});
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EmptyView), findsOneWidget);
    expect(find.text('No reviews yet'), findsOneWidget);
    expect(find.byType(ReviewTile), findsNothing);
  });

  testWidgets('section previews three reviews and offers "See all"',
      (tester) async {
    final repo = _FakeReviewRepository(
      pages: {1: [for (var i = 1; i <= 10; i++) _review(i)]},
      total: 24,
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(ReviewTile),
      findsNWidgets(ProductReviewsSection.previewCount),
    );
    // The count comes from the server's scraped total, not from what loaded,
    // and it is labelled so it cannot be misread as the catalogue's
    // `reviews_count` shown higher up the page.
    expect(find.text('24 reviews'), findsOneWidget);
    expect(find.text('See all reviews'), findsOneWidget);
  });

  testWidgets('no count is claimed when the server gave no total',
      (tester) async {
    // 10 rows on page 1, per_page 10, and no `message` to scrape — so more
    // reviews may well exist and the app has no idea how many.
    final repo = _FakeReviewRepository(
      pages: {1: [for (var i = 1; i <= 10; i++) _review(i)]},
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();

    // Printing "10" here would state a total the app does not have.
    expect(find.text('10'), findsNothing);
    expect(find.text('10 reviews'), findsNothing);

    await tester.tap(find.text('See all reviews'));
    await tester.pumpAndSettle();
    expect(find.text('10 reviews'), findsNothing);
    expect(find.text('Ratings & reviews'), findsWidgets);
  });

  testWidgets('the pinned own review counts towards the loaded total',
      (tester) async {
    final mine = _review(5);
    final repo = _FakeReviewRepository(
      pages: {1: [_review(4), mine]},
      userReview: mine,
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();

    // Two distinct reviews, one of them the caller's: two tiles, and the
    // "loaded" floor must be 2 rather than the 1 left in `reviews`.
    expect(find.byType(ReviewTile), findsNWidgets(2));
    expect(find.byType(EmptyView), findsNothing);
  });

  testWidgets('a product whose only review is the caller\'s is not "empty"',
      (tester) async {
    final mine = _review(5);
    final repo = _FakeReviewRepository(
      pages: {1: [mine]},
      userReview: mine,
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(find.text('No reviews yet'), findsNothing);
    expect(find.byType(ReviewTile), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
  });

  testWidgets('no "See all" when every review already fits in the preview',
      (tester) async {
    final repo = _FakeReviewRepository(
      pages: {
        1: [_review(1), _review(2)],
      },
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ReviewTile), findsNWidgets(2));
    expect(find.text('See all reviews'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // "See all" sheet + paging
  // -------------------------------------------------------------------------

  testWidgets('"See all" opens the sheet and pages to the end', (tester) async {
    final repo = _FakeReviewRepository(
      pages: {
        1: [for (var i = 1; i <= 10; i++) _review(i)],
        2: [for (var i = 11; i <= 13; i++) _review(i)],
      },
      total: 13,
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('See all reviews'));
    await tester.pumpAndSettle();

    // Scoped to the sheet's list: the section behind it now carries the same
    // labelled count in its header.
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('13 reviews'),
      ),
      findsOneWidget,
    );
    expect(repo.requestedPages, [1]);

    // Scrolling to the bottom pulls page 2. There is no pagination metadata to
    // drive this — the walk ends when a short page comes back.
    //
    // Driven through the sheet's own ScrollController rather than a synthetic
    // drag: inside a DraggableScrollableSheet the drag gesture is arbitrated
    // between resizing the sheet and scrolling its list, and the test binding
    // gives it all to the resize. jumpTo still dispatches the
    // ScrollUpdateNotification the section listens for.
    await _scrollListToBottom(tester);
    expect(repo.requestedPages, [1, 2]);

    // Page 2 was short, so hasMore is now false and further scrolling must not
    // request page 3.
    await _scrollListToBottom(tester);
    expect(repo.requestedPages, [1, 2]);
  });

  testWidgets('a failed page keeps the loaded ones and offers a retry',
      (tester) async {
    final repo = _FakeReviewRepository(
      pages: {
        1: [for (var i = 1; i <= 10; i++) _review(i)],
        2: [for (var i = 11; i <= 13; i++) _review(i)],
      },
      failOnPage: 2,
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('See all reviews'));
    await tester.pumpAndSettle();

    await _scrollListToBottom(tester);

    // Page 2 failed: the strip admits it, and page 1 is still on screen rather
    // than being wiped back to a full-screen error.
    expect(find.byType(InlineErrorStrip), findsOneWidget);
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.byType(ReviewTile), findsWidgets);

    // And it must not spin on the failure — one attempt, not a loop.
    expect(repo.requestedPages, [1, 2]);
    await _scrollListToBottom(tester);
    expect(repo.requestedPages, [1, 2]);
  });

  testWidgets('a parse failure lands on the error state, not endless skeletons',
      (tester) async {
    // Not an ApiException — this is what a contract change that trips
    // Review.fromJson throws. It used to escape the notifier entirely and pin
    // `loading: true`, so the section showed skeletons forever.
    final repo = _FakeReviewRepository(
      rawError: TypeError(),
      pages: {1: [_review(1)]},
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ReviewTileSkeleton), findsNothing);
    expect(find.byType(InlineErrorStrip), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('scrolling a row\'s media strip does not fetch another page',
      (tester) async {
    final repo = _FakeReviewRepository(
      pages: {
        // 12 photos + 1 video at 72px each = 936px in a ~768px viewport: the
        // strip scrolls (so it raises notifications) but its whole extent is
        // ~168px, well inside the 300px "near the bottom" trigger. That is
        // exactly the shape of the real thing — the captured feed's biggest row
        // is 6 photos + 2 videos.
        1: [
          for (var i = 1; i <= 10; i++)
            _review(i, avatar: null, media: true, imageCount: 12),
        ],
        2: [for (var i = 11; i <= 20; i++) _review(i, avatar: null)],
      },
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Ten media-bearing rows push the button past the 600px test viewport.
    await tester.ensureVisible(find.text('See all reviews'));
    await tester.pump();
    await tester.tap(find.text('See all reviews'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The inner horizontal media list bubbles its ScrollNotifications up to the
    // sheet's listener. Its extent is tiny, so "near the bottom" is always true
    // — only depth 0 may drive paging.
    //
    // Scoped inside the sheet: the section is still mounted behind the modal
    // barrier, and a finder that reaches it drags nothing.
    final media = find
        .descendant(
          of: find.byType(DraggableScrollableSheet),
          matching: find.byType(ListView),
        )
        .at(1);
    expect(tester.widget<ListView>(media).scrollDirection, Axis.horizontal);

    double mediaPixels() => tester
        .state<ScrollableState>(
          find.descendant(of: media, matching: find.byType(Scrollable)),
        )
        .position
        .pixels;

    await tester.drag(media, const Offset(-60, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The drag really did scroll that strip — so the notification was raised
    // and the listener saw it, and still declined to page.
    expect(mediaPixels(), greaterThan(0.0));
    expect(repo.requestedPages, [1]);
  });

  testWidgets('the sheet surfaces a full error view with retry',
      (tester) async {
    final repo = _FakeReviewRepository(
      error: ApiException.local('Server exploded'),
    );
    await tester.pumpWidget(
      await _wrap(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showReviewsSheet(context, slug),
            child: const Text('open'),
          ),
        ),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.textContaining('Server exploded'), findsOneWidget);

    expect(repo.requestedPages, [1]);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(repo.requestedPages, [1, 1]);
  });

  // -------------------------------------------------------------------------
  // Tile behaviour — the performance decision and the API's traps
  // -------------------------------------------------------------------------

  testWidgets('an inline base64 avatar is drawn as initials, never decoded',
      (tester) async {
    final repo = _FakeReviewRepository(pages: {1: [_review(1)]});
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();

    // "Suraj ojha" -> SO. If the data: URI had been handed to an image widget
    // this would be absent (and several KB would be base64-decoded per row).
    expect(find.text('SO'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a real http avatar is loaded as an image', (tester) async {
    final repo = _FakeReviewRepository(
      pages: {1: [_review(1, avatar: 'https://example.test/avatar.png')]},
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    // Not pumpAndSettle: the network-image placeholder spins forever under a
    // test binding, which never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('SO'), findsNothing);
    expect(find.byType(ReviewAvatar), findsOneWidget);
  });

  testWidgets('created_at prose and the pre-rendered purchase line render as-is',
      (tester) async {
    final repo = _FakeReviewRepository(pages: {1: [_review(1)]});
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 weeks ago'), findsOneWidget);
    // Verbatim, emoji included — the app must not add its own badge on top.
    expect(find.text('✅ Purchased 7 months ago'), findsOneWidget);
  });

  testWidgets('a video thumbnail is never put in an Image widget',
      (tester) async {
    final repo = _FakeReviewRepository(
      pages: {1: [_review(1, avatar: null, media: true)]},
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    // The review image's placeholder spinner never settles under a test
    // binding, so pump a fixed amount instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The clip gets a drawn play glyph...
    expect(find.byIcon(Icons.play_circle_fill_rounded), findsOneWidget);
    // ...and its URL reaches no image widget, which is the actual invariant:
    // `videos[].thumbnail` is the .mp4 itself, so binding it would download
    // the whole clip and then fail to decode it.
    expect(
      find.byWidgetPredicate(
        (w) => w is AppNetworkImage && w.url.endsWith('.mp4'),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a review video opens a player, and photos page across to it',
      (tester) async {
    final repo = _FakeReviewRepository(
      pages: {1: [_review(1, avatar: null, media: true, imageCount: 2)]},
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The video tile used to be deliberately inert. It is now a control.
    await tester.tap(find.byIcon(Icons.play_circle_fill_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(VideoPlayerView), findsOneWidget);
    // Two photos + one clip in one pager, so the count reads 3.
    expect(find.text('3 / 3'), findsOneWidget);
  });

  testWidgets('ReviewStars fills exactly the rated number of stars',
      (tester) async {
    final repo = _FakeReviewRepository(pages: const {});
    await tester.pumpWidget(
      await _wrap(const ReviewStars(star: 3), repo: repo),
    );
    await tester.pump();

    expect(find.byIcon(Icons.star_rounded), findsNWidgets(3));
    expect(find.byIcon(Icons.star_outline_rounded), findsNWidgets(2));
  });

  // -------------------------------------------------------------------------
  // Model / provider edge cases the API forces on us
  // -------------------------------------------------------------------------

  test('the caller\'s own review is pinned, not duplicated', () async {
    final mine = _review(5);
    final container = ProviderContainer(
      overrides: [
        reviewRepositoryProvider.overrideWithValue(
          _FakeReviewRepository(
            // id 5 appears in the page body AND as user_review.
            pages: {1: [_review(4), mine, _review(6)]},
            userReview: mine,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    // Keep the autoDispose family alive for the duration of the test.
    final sub = container.listen(productReviewsProvider(slug), (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    final state = container.read(productReviewsProvider(slug));
    expect(state.userReview?.id, 5);
    expect(state.reviews.map((r) => r.id), [4, 6]);
  });

  testWidgets('leaving the page mid-request does not blow up the response',
      (tester) async {
    // autoDispose + a slow feed: backing out before page 1 lands used to hit
    // `state =` on a disposed StateNotifier, which throws into an unawaited
    // future where nothing catches it.
    final repo = _FakeReviewRepository(
      pages: {1: [_review(1)]},
      delay: const Duration(milliseconds: 100),
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pump();

    // Tear the section down while the request is still in flight.
    await tester.pumpWidget(
      await _wrap(const SizedBox.shrink(), repo: repo),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(repo.requestedPages, [1]);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------------
  // Long comments — the clamp must not swallow the review
  // -------------------------------------------------------------------------

  testWidgets('a clamped comment can still be read in full', (tester) async {
    // The captured feed's reviews are ~600 characters; the product-page tile
    // clamps to four lines. A product with one or two reviews never offers
    // "See all reviews", so without an expander the rest of the text was
    // unreachable from anywhere in the app.
    final repo = _FakeReviewRepository(
      pages: {
        1: [_review(1, comment: _longComment)],
      },
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();

    // No escape hatch to the sheet on a single-review product...
    expect(find.text('See all reviews'), findsNothing);
    // ...so the tile itself has to offer one.
    expect(find.text('Read more'), findsOneWidget);

    final clamped = tester.widget<Text>(find.text(_longComment));
    expect(clamped.maxLines, ReviewComment.maxLines);
    expect(clamped.overflow, TextOverflow.ellipsis);

    await tester.tap(find.text('Read more'));
    await tester.pumpAndSettle();

    final expanded = tester.widget<Text>(find.text(_longComment));
    expect(expanded.maxLines, isNull);
    expect(expanded.overflow, isNot(TextOverflow.ellipsis));
    expect(find.text('Show less'), findsOneWidget);
  });

  testWidgets('a short comment gets no "Read more"', (tester) async {
    final repo = _FakeReviewRepository(pages: {1: [_review(1)]});
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(find.text('Great product, arrived fresh.'), findsOneWidget);
    expect(find.text('Read more'), findsNothing);
  });

  testWidgets('the sheet renders comments unclamped', (tester) async {
    final repo = _FakeReviewRepository(
      pages: {
        1: [for (var i = 1; i <= 10; i++) _review(i, comment: _longComment)],
      },
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('See all reviews'));
    await tester.tap(find.text('See all reviews'));
    await tester.pumpAndSettle();

    final inSheet = find.descendant(
      of: find.byType(DraggableScrollableSheet),
      matching: find.text(_longComment),
    );
    expect(tester.widget<Text>(inSheet.first).maxLines, isNull);
  });

  // -------------------------------------------------------------------------
  // Paging is bounded
  // -------------------------------------------------------------------------

  testWidgets('a server that ignores page= does not page forever',
      (tester) async {
    // Every request answers with the same full page, so `isLastPage` is never
    // true and the short-page inference — the only signal this endpoint gives —
    // never fires. Left unbounded this issued a request per scroll that added
    // no rows at all.
    final same = [for (var i = 1; i <= 10; i++) _review(i)];
    final repo = _FakeReviewRepository(
      pages: {for (var p = 1; p <= 40; p++) p: same},
    );
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('See all reviews'));
    await tester.pumpAndSettle();

    await _scrollListToBottom(tester);
    expect(repo.requestedPages, [1, 2]);

    // Page 2 brought nothing new, so the walk is over: scrolling again must not
    // ask for page 3.
    await _scrollListToBottom(tester);
    expect(repo.requestedPages, [1, 2]);
    expect(find.byType(ReviewTile), findsWidgets);
  });

  test('the walk stops at the page cap even if rows keep arriving', () async {
    var id = 0;
    final container = ProviderContainer(
      overrides: [
        reviewRepositoryProvider.overrideWithValue(
          // Fresh ids every page and never a short one: nothing but the cap can
          // end this.
          _FakeReviewRepository(
            pages: {
              for (var p = 1; p <= 60; p++)
                p: [for (var i = 0; i < 10; i++) _review(++id)],
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(productReviewsProvider(slug), (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    final notifier = container.read(productReviewsProvider(slug).notifier);
    for (var i = 0; i < 40; i++) {
      await notifier.loadMore();
    }

    final state = container.read(productReviewsProvider(slug));
    expect(state.page, ProductReviewsNotifier.maxPages);
    expect(state.hasMore, isFalse);
  });

  // -------------------------------------------------------------------------
  // Counts
  // -------------------------------------------------------------------------

  testWidgets('a zero total is not printed next to the empty state',
      (tester) async {
    // Product 119 answers `"0 review(s) for ..."`, so the total is exact and
    // zero. Printing it left "Ratings & reviews  0 reviews" sitting on top of a
    // panel that already says "No reviews yet".
    final repo = _FakeReviewRepository(pages: const {}, total: 0);
    await tester.pumpWidget(
      await _wrap(const ProductReviewsSection(slug: slug), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(find.text('No reviews yet'), findsOneWidget);
    expect(find.text('0 reviews'), findsNothing);
  });

  test('an unknown total falls back to the loaded count, never zero', () {
    final page = ProductReviewPage.fromJson(
      {
        'data': {
          'reviews': [_reviewJson(1), _reviewJson(2)],
          'has_reviewed': false,
          'user_review': null,
        },
        // No message -> no total to scrape.
      },
      perPage: 10,
    );
    expect(page.total, isNull);
    expect(page.reviews.length, 2);
  });

  test('the total is scraped out of the server message sentence', () {
    final page = ProductReviewPage.fromJson(
      {
        'message': '2 review(s) for "Trueway Farms Organic Desi Khand"',
        'data': {
          'reviews': [_reviewJson(1), _reviewJson(2)],
          'has_reviewed': false,
          'user_review': null,
        },
      },
      perPage: 10,
    );
    expect(page.total, 2);
    expect(page.isLastPage, isTrue);
  });
}

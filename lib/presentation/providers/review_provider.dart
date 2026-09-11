import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/errors/error_presenter.dart';
import '../../data/models/review.dart';
import '../../data/repositories/review_repository.dart';
import 'core_providers.dart';

/// One product's review feed, paged.
///
/// `GET /ecommerce/products/{slug}/reviews` publishes **no pagination
/// metadata** — no `meta`, no `last_page`, no page count — so [hasMore] cannot
/// be computed up front. [ProductReviewPage.isLastPage] infers it from a short
/// page (and closes the exact-multiple case with the total scraped out of the
/// server's `message` sentence), and this state just carries that inference
/// forward. Paging therefore walks until a short page comes back.
class ProductReviewsState {
  const ProductReviewsState({
    this.reviews = const [],
    this.loading = true,
    this.loadingMore = false,
    this.hasMore = false,
    this.page = 1,
    this.total,
    this.hasReviewed = false,
    this.userReview,
    this.error,
    this.loadMoreError,
    this.eligibility = ReviewEligibility.unknown,
    this.settings = ReviewSettings.fallback,
    this.summary = ReviewSummary.empty,
  });

  final List<Review> reviews;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final int page;

  /// Exact count for the current filter, or null when it could not be read.
  ///
  /// The API never returns a total as a field; the only place it appears is
  /// embedded in the localized `message` sentence, which
  /// [ProductReviewPage.total] scrapes. **Null means "unknown", never zero** —
  /// the UI must fall back to `reviews.length` rather than claiming 0 reviews.
  final int? total;

  /// Whether the *signed-in* caller already reviewed this product. Always false
  /// anonymously — it is a property of the caller, not of the product.
  final bool hasReviewed;

  /// The caller's own review, when [hasReviewed]. Already de-duplicated out of
  /// [reviews] by the notifier, so pinning it to the top cannot double it up.
  final Review? userReview;

  /// First-page failure — the list has nothing to show. Kept as the thrown
  /// object so `AppErrorView` / `InlineErrorStrip` can use the server message,
  /// the field errors and the error kind.
  final ApiException? error;

  /// A *paging* failure. Deliberately separate from [error]: losing page 3 must
  /// not wipe the two pages already on screen.
  final ApiException? loadMoreError;

  /// Whether this customer may write a review, and why not. The entry point is
  /// gated on it, so nobody writes a review only to be refused on submit.
  final ReviewEligibility eligibility;

  /// Upload limits from the store's admin settings, not app constants.
  final ReviewSettings settings;

  /// Rating bars and the media strip. [ReviewSummary.count] is the review
  /// count — the length of [reviews] is one page of it.
  final ReviewSummary summary;

  bool get isEmpty => !loading && error == null && reviews.isEmpty;

  /// Whether [total] is the server's own figure rather than a guess.
  ///
  /// Since 2026-08-12 it always is — `reviews_pagination.total` carries it. The
  /// flag stays because the guarantee is the server's, not the app's: before
  /// that block existed the only number available was [loadedCount], a *lower
  /// bound* that would have rendered page 1 of a 40-review product as "10
  /// reviews". Show no count rather than a wrong one.
  bool get hasExactTotal => total != null;

  /// The count to print beside the heading.
  ///
  /// [ReviewSummary.count] is approved reviews for the product; [total] is the
  /// current page-set's filter total, which differs when a star filter is on.
  /// Prefer the summary and fall back, and never use `reviews.length`.
  int? get displayTotal => summary.count > 0 ? summary.count : total;

  /// How many reviews are actually on screen: the body list plus the pinned
  /// own review, which the notifier removed from [reviews] so it cannot appear
  /// twice. Counting `reviews.length` alone under-reports by one for a signed-in
  /// customer who has reviewed this product.
  int get loadedCount => reviews.length + (userReview == null ? 0 : 1);

  /// The exact total when the server gave one, otherwise the floor implied by
  /// what has been paged in. Guard every use with [hasExactTotal] before
  /// presenting it to a customer as a count.
  int get displayCount => total ?? loadedCount;

  ProductReviewsState copyWith({
    List<Review>? reviews,
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    int? page,
    int? total,
    bool? hasReviewed,
    Review? userReview,
    ApiException? error,
    ApiException? loadMoreError,
    ReviewEligibility? eligibility,
    ReviewSettings? settings,
    ReviewSummary? summary,
    bool clearLoadMoreError = false,
  }) =>
      ProductReviewsState(
        reviews: reviews ?? this.reviews,
        loading: loading ?? this.loading,
        loadingMore: loadingMore ?? this.loadingMore,
        hasMore: hasMore ?? this.hasMore,
        page: page ?? this.page,
        total: total ?? this.total,
        hasReviewed: hasReviewed ?? this.hasReviewed,
        userReview: userReview ?? this.userReview,
        error: error ?? this.error,
        loadMoreError:
            clearLoadMoreError ? null : (loadMoreError ?? this.loadMoreError),
        eligibility: eligibility ?? this.eligibility,
        settings: settings ?? this.settings,
        summary: summary ?? this.summary,
      );
}

class ProductReviewsNotifier extends StateNotifier<ProductReviewsState> {
  ProductReviewsNotifier(this._ref, this.slug)
      : super(const ProductReviewsState()) {
    load();
  }

  final Ref _ref;
  final String slug;

  /// Matches [ReviewRepository.defaultPerPage] on purpose: `isLastPage`
  /// compares the returned row count against the size we *asked* for, so a
  /// mismatch between this and what the repository sends would end the walk on
  /// the first page.
  static const int perPage = ReviewRepository.defaultPerPage;

  /// Hard stop on the walk, mirroring [ReviewRepository.maxPages].
  ///
  /// The only signal that the feed has ended is a short page, so a server that
  /// ignores `page` — or one whose OFFSET paging resets — keeps answering with a
  /// full page forever and [hasMore] never flips. Every scroll to the foot of
  /// the sheet then fires another request that adds nothing (measured: 31
  /// requests, 10 rows, `hasMore: true`). 20 pages is 200 reviews, far past any
  /// real product.
  static const int maxPages = ReviewRepository.maxPages;

  ReviewRepository get _repo => _ref.read(reviewRepositoryProvider);

  Future<void> load() async {
    state = const ProductReviewsState(loading: true);
    try {
      final page = await _repo.productReviews(slug, page: 1, perPage: perPage);
      // This provider is autoDispose and the request is slow — every row can
      // carry a multi-KB inline avatar — so backing out of the product page
      // mid-flight is ordinary. Assigning `state` on a disposed StateNotifier
      // throws, and the throw lands in an unawaited future where nothing
      // handles it.
      if (!mounted) return;
      state = ProductReviewsState(
        reviews: _withoutUserReview(page.reviews, page.userReview),
        loading: false,
        hasMore: !page.isLastPage,
        page: 1,
        total: page.total,
        hasReviewed: page.hasReviewed,
        userReview: page.userReview,
        // Properties of the caller and the store, not of the page — so they are
        // taken from page 1 only and left alone as the walk continues.
        eligibility: page.eligibility,
        settings: page.settings,
        summary: page.summary,
      );
    } on ApiException catch (e) {
      // Already logged by ApiClient — just surface it.
      if (!mounted) return;
      state = ProductReviewsState(loading: false, error: e);
    } catch (e, s) {
      if (!mounted) return;
      // Anything that is *not* an ApiException — a contract change that trips
      // the model parser, a cast failure inside Review.fromJson — used to
      // escape this method entirely, leaving `loading: true` set forever. The
      // section then showed skeletons with no error and no retry: a failure
      // rendered as "still loading". Land it on the error state instead.
      state = ProductReviewsState(loading: false, error: _wrap(e, s, 'load'));
    }
  }

  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    state = state.copyWith(loadingMore: true, clearLoadMoreError: true);
    final next = state.page + 1;
    try {
      final page =
          await _repo.productReviews(slug, page: next, perPage: perPage);
      if (!mounted) return;
      final merged = _merge(state.reviews, page.reviews, state.userReview);
      // A page that came back non-empty and yet contributed no new id is the
      // server handing us the same rows again — with pure OFFSET paging that
      // can only mean `page` was not honoured, so the next request would repeat
      // it. Stop instead of looping. See [maxPages].
      final madeNoProgress =
          page.reviews.isNotEmpty && merged.length == state.reviews.length;
      state = state.copyWith(
        reviews: merged,
        loadingMore: false,
        hasMore: !page.isLastPage && !madeNoProgress && next < maxPages,
        page: next,
        // `total` only reaches us inside `message`, which every page repeats —
        // take the newest reading rather than pinning page 1's.
        total: page.total,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      state = state.copyWith(loadingMore: false, loadMoreError: e);
    } catch (e, s) {
      if (!mounted) return;
      // Same reasoning as `load`: an unexpected throw must not leave
      // `loadingMore: true` pinned, which would show a spinner at the foot of
      // the list for the rest of the session and block every later page.
      state = state.copyWith(
        loadingMore: false,
        loadMoreError: _wrap(e, s, 'loadMore'),
      );
    }
  }

  /// Normalizes a non-[ApiException] throw into one, logging it on the way so
  /// the failure is still recorded even though it never reached [ApiClient].
  ApiException _wrap(Object e, StackTrace s, String where) {
    ErrorLog.capture(e, stackTrace: s, context: 'reviews.$where($slug)');
    return ApiException.local(
      "Couldn't read the reviews for this product.",
      developerDetail: 'reviews.$where slug=$slug\n$e\n$s',
    );
  }

  Future<void> refresh() => load();

  /// `user_review` is fetched independently of the page (the server looks it up
  /// with `Review::getUserReview()`), so it may *also* appear inside `reviews`
  /// depending on which page it falls on. The UI pins it to the top, so drop it
  /// from the body to avoid showing the same review twice.
  static List<Review> _withoutUserReview(List<Review> rows, Review? mine) =>
      mine == null ? rows : [for (final r in rows) if (r.id != mine.id) r];

  /// Appends a page, dropping ids already held.
  ///
  /// The endpoint offers no stable sort key and no cursor — `page=N` is a plain
  /// OFFSET over a query ordered by creation time, so a review posted between
  /// two requests shifts every later row and can repeat one across the seam. A
  /// duplicate id in a `ListView` is a visible double entry, and would be a
  /// duplicate `Key` the moment the list is keyed.
  static List<Review> _merge(
    List<Review> existing,
    List<Review> incoming,
    Review? mine,
  ) {
    final seen = {for (final r in existing) r.id, if (mine != null) mine.id};
    return [
      ...existing,
      for (final r in incoming)
        if (seen.add(r.id)) r,
    ];
  }
}

/// Reviews for one product, keyed by slug.
///
/// autoDispose: the feed is only interesting while a product page (or its
/// "all reviews" sheet, which reads this same instance) is on screen, and the
/// rows are heavy — every one can carry a multi-KB inline avatar.
final productReviewsProvider = StateNotifierProvider.autoDispose
    .family<ProductReviewsNotifier, ProductReviewsState, String>(
  (ref, slug) => ProductReviewsNotifier(ref, slug),
);

// ===========================================================================
// The customer's own reviews
// ===========================================================================

class MyReviewsState {
  const MyReviewsState({
    this.items = const [],
    this.loading = true,
    this.refreshing = false,
    this.loadingMore = false,
    this.error,
    this.page = 1,
    this.hasMore = false,
    this.deleting = const {},
  });

  final List<Review> items;
  final bool loading;
  final bool refreshing;
  final bool loadingMore;
  final ApiException? error;
  final int page;
  final bool hasMore;

  /// Review ids currently being deleted, so each row can spin on its own
  /// rather than the whole list freezing.
  final Set<int> deleting;

  bool get isEmpty => items.isEmpty;

  MyReviewsState copyWith({
    List<Review>? items,
    bool? loading,
    bool? refreshing,
    bool? loadingMore,
    ApiException? error,
    int? page,
    bool? hasMore,
    Set<int>? deleting,
    bool clearError = false,
  }) =>
      MyReviewsState(
        items: items ?? this.items,
        loading: loading ?? this.loading,
        refreshing: refreshing ?? this.refreshing,
        loadingMore: loadingMore ?? this.loadingMore,
        error: clearError ? null : (error ?? this.error),
        page: page ?? this.page,
        hasMore: hasMore ?? this.hasMore,
        deleting: deleting ?? this.deleting,
      );
}

class MyReviewsNotifier extends StateNotifier<MyReviewsState> {
  MyReviewsNotifier(this._ref) : super(const MyReviewsState()) {
    load();
  }

  final Ref _ref;

  ReviewRepository get _repo => _ref.read(reviewRepositoryProvider);

  static const int _perPage = 10;

  Future<void> load() => _read(background: false);

  Future<void> refresh() => _read(background: true);

  Future<void> _read({required bool background}) async {
    if (!mounted) return;
    state = state.copyWith(
      loading: !background,
      refreshing: background,
      clearError: true,
    );
    try {
      final res = await _repo.myReviews(page: 1, perPage: _perPage);
      if (!mounted) return;
      state = MyReviewsState(
        items: res.items,
        loading: false,
        page: 1,
        hasMore: res.hasMore,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      state = state.copyWith(loading: false, refreshing: false, error: e);
    }
  }

  Future<void> loadMore() async {
    if (state.loadingMore || !state.hasMore) return;
    state = state.copyWith(loadingMore: true);
    try {
      final next = state.page + 1;
      final res = await _repo.myReviews(page: next, perPage: _perPage);
      if (!mounted) return;
      state = state.copyWith(
        items: [...state.items, ...res.items],
        loadingMore: false,
        page: next,
        hasMore: res.hasMore,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      state = state.copyWith(loadingMore: false, error: e);
    }
  }

  /// Deletes one review.
  ///
  /// The row is removed only after the server confirms — an optimistic removal
  /// that then failed would leave the customer believing a review is gone while
  /// it is still public on the product page.
  ///
  /// Returns the server's message on refusal, null on success.
  Future<String?> delete(int id) async {
    if (state.deleting.contains(id)) return null;
    state = state.copyWith(deleting: {...state.deleting, id});

    try {
      await _repo.delete(id);
      if (!mounted) return null;
      state = state.copyWith(
        items: [...state.items]..removeWhere((r) => r.id == id),
        deleting: {...state.deleting}..remove(id),
      );
      // Deleting frees the product to be reviewed again, so it belongs back in
      // the "To review" tab.
      _ref.invalidate(reviewableProductsProvider);
      return null;
    } on ApiException catch (e) {
      if (mounted) {
        state = state.copyWith(deleting: {...state.deleting}..remove(id));
      }
      return e.message;
    }
  }
}

final myReviewsProvider =
    StateNotifierProvider.autoDispose<MyReviewsNotifier, MyReviewsState>(
  MyReviewsNotifier.new,
);

// ===========================================================================
// Awaiting the customer's review
// ===========================================================================

/// Products from completed orders that have no review yet.
///
/// One call. `GET /ecommerce/reviews/products-to-review` is the website's own
/// "Waiting for your review" query, and the server has already excluded
/// anything still inside the post-delivery waiting period — so every row here
/// can be reviewed right now.
///
/// This replaced a three-stage derivation that existed only because no endpoint
/// answered the question: read every review the customer had written, read
/// their completed orders, then fetch each order's **detail** because a list
/// row carries no product ids. That was N+2 requests, capped at ten orders, so
/// the answer was simply wrong for anyone with a longer history.
final reviewableProductsProvider =
    FutureProvider.autoDispose<List<ReviewableProduct>>((ref) async {
  return ref.watch(reviewRepositoryProvider).productsToReview();
});

// ===========================================================================
// Writing a review
// ===========================================================================

/// The gate and the upload limits for one product's review form.
///
/// `GET products/{slug}/review-eligibility` answers both in one call, which is
/// what lets the form be built without first pulling the review list. Never
/// throws — the repository degrades to "let them try" with the fallback limits,
/// because a form that refuses to open is worse than one the server refuses on
/// submit.
final reviewGateProvider = FutureProvider.autoDispose
    .family<({ReviewEligibility eligibility, ReviewSettings settings}), String>(
  (ref, slug) => ref.watch(reviewRepositoryProvider).reviewGate(slug),
);

class ReviewSubmitState {
  const ReviewSubmitState({this.busy = false, this.error});

  final bool busy;
  final ApiException? error;
}

class ReviewSubmitNotifier extends StateNotifier<ReviewSubmitState> {
  ReviewSubmitNotifier(this._ref) : super(const ReviewSubmitState());

  final Ref _ref;

  /// Posts a review.
  ///
  /// Unlike a return, media goes **with** this request: `ReviewController`
  /// reads uploads from `$request->file()`, so the repository switches to a
  /// multipart body when there are files and stays on JSON when there are not.
  /// There is no separate upload endpoint to call first.
  ///
  /// Returns true on success. On failure [state.error] carries the server's
  /// wording, which matters here — the validator rejects HTML tags and Cyrillic
  /// in the comment, and those refusals are not guessable from a status code.
  Future<bool> submit({
    required int productId,
    required int star,
    required String comment,
    String? productSlug,
    List<String> imagePaths = const [],
    List<String> videoPaths = const [],
  }) async {
    if (state.busy) return false;
    state = const ReviewSubmitState(busy: true);

    try {
      await _ref.read(reviewRepositoryProvider).create(
            productId: productId,
            star: star,
            comment: comment,
            imagePaths: imagePaths,
            videoPaths: videoPaths,
          );
      if (mounted) state = const ReviewSubmitState();

      _ref.invalidate(myReviewsProvider);
      // The product just reviewed must leave the "To review" tab, or it sits
      // there inviting a second review the server would refuse.
      _ref.invalidate(reviewableProductsProvider);
      // The product's own feed shows the new review once it is approved —
      // reviews land as `pending`, so this refresh may legitimately show
      // nothing new yet.
      if (productSlug != null && productSlug.isNotEmpty) {
        _ref.invalidate(productReviewsProvider(productSlug));
      }
      return true;
    } on ApiException catch (e) {
      if (mounted) state = ReviewSubmitState(error: e);
      return false;
    }
  }
}

final reviewSubmitProvider =
    StateNotifierProvider.autoDispose<ReviewSubmitNotifier, ReviewSubmitState>(
  ReviewSubmitNotifier.new,
);

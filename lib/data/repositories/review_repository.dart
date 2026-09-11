import 'package:dio/dio.dart';

import '../../core/errors/api_exception.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_response.dart';
import '../../core/utils/json_utils.dart';
import '../models/review.dart';

/// Product reviews: the public per-product feed, the signed-in customer's own
/// reviews, and create/delete.
///
/// All calls go through [ApiClient], which already turns both failure channels
/// (non-2xx, and HTTP 200 carrying `error:true`) into an ApiException — so a
/// returned value here always means the call succeeded.
class ReviewRepository {
  ReviewRepository(this._api);

  final ApiClient _api;

  /// Default page size. Mirrors the server's own `per_page` default of 10, so
  /// omitting the parameter and passing it explicitly agree — [ProductReviewPage.isLastPage]
  /// compares against the size we asked for and would misfire otherwise.
  static const int defaultPerPage = 10;

  /// Safety stop for [allProductReviews]. Without a `total` from the server the
  /// loop's only exit is a short page, so a backend that ignored `page` would
  /// otherwise spin forever.
  static const int maxPages = 20;

  /// Upper bound on `per_page`. The server applies none — `paginate($perPage)`
  /// takes the value straight from the query string — so a large value is a
  /// self-inflicted download of every review plus one ~4 KB base64 avatar each.
  static const int maxPerPage = 100;

  /// `per_page` reaches Laravel's `paginate()` unguarded, and a non-positive
  /// value is an HTTP 500 (`per_page=-1` -> `{"message":"Server Error"}`,
  /// captured). Zero is worse than an error: `reviews.length < 0` is never true,
  /// so [allProductReviews] would issue [maxPages] requests and still not stop.
  /// Clamp rather than hand the server something it cannot answer.
  ///
  /// Clamped, not asserted: an assert would crash debug builds on exactly the
  /// input the clamp exists to survive, and would leave debug and release
  /// disagreeing about what the app does.
  static int _safePerPage(int perPage) {
    if (perPage < 1) return defaultPerPage;
    return perPage > maxPerPage ? maxPerPage : perPage;
  }

  /// `star` is read with `$request->integer('star')` and gated on `if ($star)`,
  /// so **0 means "no filter"** — passing it would silently return every review
  /// while the caller believed it had filtered. Anything outside 1..5 matches
  /// nothing. Drop both instead of sending a request whose result would be
  /// misread.
  static int? _safeStar(int? star) =>
      (star != null && star >= 1 && star <= 5) ? star : null;

  /// Public. `star` filters to an exact rating (1-5); there is no way to ask
  /// the API for the per-star histogram — it does not exist on any endpoint.
  Future<ProductReviewPage> productReviews(
    String slug, {
    int page = 1,
    int perPage = defaultPerPage,
    int? star,
  }) async {
    final safePerPage = _safePerPage(perPage);
    final safePage = page < 1 ? 1 : page;
    final res = await _api.get(
      ApiEndpoints.productReviews(slug),
      query: {
        'page': safePage,
        'per_page': safePerPage,
        if (_safeStar(star) case final s?) 'star': s,
      },
    );
    return ProductReviewPage.fromJson(
      _envelope(res.data, 'GET ${ApiEndpoints.productReviews(slug)}'),
      perPage: safePerPage,
      page: safePage,
    );
  }

  /// Rejects anything that is not the envelope this endpoint documents.
  ///
  /// Coercing an unrecognised body to `{}` would parse as "this product has no
  /// reviews, and that is the last page" — a silent, plausible-looking lie. Two
  /// real bodies land here:
  ///
  ///  * `{"message":"...","error":"Unauthorized"}` (captured: request without
  ///    `X-API-KEY`). `error` is the **string** `"Unauthorized"`, not `true`, so
  ///    `ApiException.declaresFailure` — which only matches `error == true` —
  ///    lets it through untouched.
  ///  * an HTML error page or any non-JSON body, which arrives as a `String`.
  static Map<String, dynamic> _envelope(dynamic body, String where) {
    if (body is! Map) {
      throw ApiException.local(
        'The server sent an unexpected response.',
        developerDetail: '$where returned ${body.runtimeType}, expected a JSON '
            'object.\nbody: $body',
      );
    }
    final error = body['error'];
    if (error is String && error.trim().isNotEmpty) {
      throw ApiException.local(
        // The sibling `message` is the useful sentence ("Invalid or missing API
        // key..."); `error` is the machine word.
        asStringOrNull(body['message']) ?? error,
        developerDetail: '$where returned error: "$error"\nbody: $body',
      );
    }
    final data = body['data'];
    if (data is! Map) {
      throw ApiException.local(
        'The server sent an unexpected response.',
        developerDetail: '$where returned data as ${data.runtimeType}; the '
            'reviews envelope is always an object holding {reviews, '
            'has_reviewed, user_review}.\nbody: $body',
      );
    }
    return Map<String, dynamic>.from(body);
  }

  /// Every review for a product, walked page by page.
  ///
  /// Exists because the endpoint publishes **no pagination metadata at all** —
  /// no meta, total or last_page — so nothing can compute a page count up
  /// front. It stops on the first short page (verified: page 2 of a 2-review
  /// product returns `reviews: []`) or at [maxPages].
  ///
  /// The first page's envelope is kept for `has_reviewed` / `user_review`,
  /// which are properties of the *caller*, not of the page.
  ///
  /// The result's [ProductReviewPage.isLastPage] is **false** when the walk hit
  /// [maxPages] before the real end. It used to be hardcoded true, which turned
  /// a truncated prefix into a confident "these are all the reviews" — the
  /// caller had no way to know 200 of 340 reviews came back. Compare
  /// `reviews.length` with `total` to see how much was left behind.
  Future<ProductReviewPage> allProductReviews(
    String slug, {
    int perPage = defaultPerPage,
    int? star,
  }) async {
    final collected = <Review>[];
    ProductReviewPage? first;
    var reachedEnd = false;

    for (var page = 1; page <= maxPages; page++) {
      final result = await productReviews(
        slug,
        page: page,
        perPage: perPage,
        star: star,
      );
      first ??= result;
      collected.addAll(result.reviews);
      if (result.isLastPage) {
        reachedEnd = true;
        break;
      }
    }

    return ProductReviewPage(
      reviews: collected,
      hasReviewed: first?.hasReviewed ?? false,
      userReview: first?.userReview,
      isLastPage: reachedEnd,
      message: first?.message,
      // Properties of the caller and the store, identical on every page, so
      // page 1's copy is the whole answer. Dropping them here would quietly
      // reset the gate to "unknown" and the limits to the fallback.
      eligibility: first?.eligibility ?? ReviewEligibility.unknown,
      settings: first?.settings ?? ReviewSettings.fallback,
      summary: first?.summary ?? ReviewSummary.empty,
      pagination: first?.pagination ?? ReviewsPagination.none,
    );
  }

  /// The signed-in customer's own reviews, newest first.
  ///
  /// Unlike the public route this one *is* a real Laravel paginator, in the
  /// hybrid envelope `{data, links, meta, error, message}` — so it has usable
  /// `meta.last_page` and [PaginatedResponse.hasMore] works.
  ///
  /// Each row carries an extra `product` object the public route omits.
  Future<PaginatedResponse<Review>> myReviews({
    int page = 1,
    int perPage = defaultPerPage,
  }) async {
    final res = await _api.get(
      ApiEndpoints.reviews,
      query: {
        'page': page < 1 ? 1 : page,
        'per_page': _safePerPage(perPage),
      },
    );
    final body = res.data;
    // `PaginatedResponse.fromJson` casts `json['data'] as List?`, which is a
    // TypeError — not an ApiException — the moment `data` is anything else.
    // Only take that path once the shape is confirmed; otherwise fall back to
    // the tolerant unwrap so a contract change degrades to an empty list
    // instead of crashing the calling widget's future.
    if (body is Map<String, dynamic> && body['data'] is List) {
      return PaginatedResponse.fromJson(body, Review.fromJson);
    }
    final items = unwrapList(body, Review.fromJson);
    return PaginatedResponse(
      items: items,
      meta: PaginationMeta.single(items.length),
    );
  }

  /// Post a review. Authenticated.
  ///
  /// Contract, from `API\ReviewRequest` and confirmed by the 422 on an empty
  /// body (`product_id`, `star`, `comment` all "field is required"):
  ///   product_id  required, must exist
  ///   star        required, numeric 1-5
  ///   comment     required, max 5000, rejected if it contains HTML tags or
  ///               Cyrillic characters (spam filter) — both surface as a 422 on
  ///               `comment`, so pasted rich text will be refused.
  ///   images[]    optional, jpg/jpeg/png
  ///   videos[]    optional, mp4/mov only, max 2, ≤10 MB and ≤30 s each
  ///
  /// [productId] is the *parent* product id even when a variation was bought —
  /// the eligibility check joins variations back to their configurable parent.
  ///
  /// Eligibility failures ("You have reviewed this product already!", "Please
  /// purchase the product for a review!") come back as **422 with the message
  /// under `errors.product_id`**, not as the 200+`error:true` shape used
  /// elsewhere, so they land as ApiErrorKind.validation.
  Future<Review?> create({
    required int productId,
    required int star,
    required String comment,
    List<String> imagePaths = const [],
    List<String> videoPaths = const [],
  }) async {
    final hasFiles = imagePaths.isNotEmpty || videoPaths.isNotEmpty;

    // Laravel reads uploads from `$request->file()`, which only exists on a
    // multipart body — a JSON array of paths is silently dropped. Stay on JSON
    // when there is nothing to upload so the common case avoids the encoding.
    final Object body;
    if (hasFiles) {
      // `MultipartFile.fromFile` stats the path and throws a raw
      // FileSystemException if it is gone — an image_picker temp file that the
      // OS reclaimed, or a shared URI the app lost access to. Every other exit
      // from this repository is an ApiException, so letting that escape breaks
      // `on ApiException` handlers and surfaces as an unhandled error.
      try {
        body = FormData.fromMap({
          'product_id': productId,
          'star': star,
          'comment': comment,
          // Repeated `images[]` keys, not an indexed map. PHP folds `images[]`
          // into `$_FILES['images']` as an array, which is what the controller
          // reads (`$request->hasFile('images')`) and what `array|max:N`
          // expects.
          'images[]': [
            for (final path in imagePaths) await MultipartFile.fromFile(path),
          ],
          'videos[]': [
            for (final path in videoPaths) await MultipartFile.fromFile(path),
          ],
        });
      } on Object catch (e) {
        throw ApiException.local(
          "One of the attachments couldn't be read. Please pick it again.",
          developerDetail: 'MultipartFile.fromFile failed.\n'
              'images: $imagePaths\nvideos: $videoPaths\n$e',
        );
      }
    } else {
      body = {
        'product_id': productId,
        'star': star,
        'comment': comment,
      };
    }

    final res = await _api.post(ApiEndpoints.reviews, data: body);
    return unwrapObject(res.data, Review.fromJson);
  }

  /// Delete one of the caller's own reviews.
  ///
  /// Deleting someone else's is refused server-side with a 403 carrying "You do
  /// not have permission to delete this review."; an unknown id is a 404.
  Future<void> delete(int id) async {
    await _api.delete(ApiEndpoints.review(id));
  }

  /// `GET /ecommerce/products/{slug}/review-eligibility`.
  ///
  /// The gate on its own, for deciding whether to offer the form without
  /// pulling the review list — a product card, an order line, a deep link
  /// straight into the form.
  ///
  /// Public, but the answer depends on the caller: [ApiClient] attaches the
  /// bearer to every request, and without it the server sees a guest and always
  /// answers `login_required`.
  ///
  /// Never throws for the caller's benefit: a failure here must not stop a
  /// product page rendering, so it degrades to
  /// [ReviewEligibility.unknown] — "let them try" — and the server refuses on
  /// submit if it must.
  /// Returns the gate **and** the upload limits: the endpoint carries
  /// `review_settings` too, precisely so a form can be built from one call.
  Future<({ReviewEligibility eligibility, ReviewSettings settings})> reviewGate(
    String slug,
  ) async {
    try {
      final res = await _api.get(ApiEndpoints.reviewEligibility(slug));
      final data = unwrapObject<Map<String, dynamic>>(res.data, (j) => j);
      if (data == null) {
        return (
          eligibility: ReviewEligibility.unknown,
          settings: ReviewSettings.fallback,
        );
      }
      return (
        eligibility: ReviewEligibility.fromJson(data),
        settings: data['review_settings'] is Map
            ? ReviewSettings.fromJson(
                Map<String, dynamic>.from(data['review_settings'] as Map),
              )
            : ReviewSettings.fallback,
      );
    } on ApiException {
      // Already logged by ApiClient.
      return (
        eligibility: ReviewEligibility.unknown,
        settings: ReviewSettings.fallback,
      );
    }
  }

  /// `GET /ecommerce/reviews/products-to-review` — the "waiting for your
  /// review" list. Authenticated.
  ///
  /// The server has already dropped anything still inside the post-delivery
  /// waiting period, so every row can be reviewed right now and the caller does
  /// not have to check each one.
  ///
  /// This replaced a three-stage client derivation: read the customer's reviews
  /// at `per_page=100`, read their completed orders, then fetch each order's
  /// detail to learn its product ids — capped at ten orders, so the answer was
  /// wrong for anyone with a longer history.
  Future<List<ReviewableProduct>> productsToReview({int limit = 12}) async {
    final res = await _api.get(
      ApiEndpoints.productsToReview,
      query: {'limit': limit},
    );
    return unwrapList(res.data, ReviewableProduct.fromJson);
  }
}

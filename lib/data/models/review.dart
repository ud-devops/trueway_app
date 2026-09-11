import '../../core/utils/json_utils.dart';

/// Which array a [ReviewMedia] came out of.
enum ReviewMediaKind { image, video }

/// One media item on a review.
///
/// Images get a real 150x150 derivative in [thumbnail]. Videos do **not**: the
/// server maps both keys to the same `RvMedia::getImageUrl($video)` call, so a
/// video's `thumbnail` is the `.mp4` URL itself. Feeding it to an Image widget
/// downloads the whole clip and then fails to decode — check [isVideo] first.
class ReviewMedia {
  const ReviewMedia({
    required this.thumbnail,
    required this.fullUrl,
    required this.kind,
  });

  final String thumbnail;
  final String fullUrl;

  /// Whichever of `images` / `videos` this entry was listed under.
  ///
  /// This is the authoritative signal, not the file extension. `ec_reviews.
  /// videos` is a raw JSON column — the API's `mimes:mp4,mov` rule only guards
  /// rows created through `POST /ecommerce/reviews`, so admin-uploaded or
  /// migrated rows can carry `.m4v`, `.avi`, `.3gp`, or a URL with no extension
  /// at all. Sniffing the URL would call those images and hand an
  /// undecodable blob to an Image widget.
  final ReviewMediaKind kind;

  /// True when [thumbnail] is not a still image. See the class doc.
  ///
  /// [kind] decides it; the extension check only *adds* detections, so a video
  /// that somehow lands in `images` is still caught.
  bool get isVideo => kind == ReviewMediaKind.video || _hasVideoExtension;

  bool get _hasVideoExtension {
    final path = Uri.tryParse(thumbnail)?.path.toLowerCase() ?? '';
    return path.endsWith('.mp4') ||
        path.endsWith('.mov') ||
        path.endsWith('.m4v') ||
        path.endsWith('.webm');
  }

  /// Parses one entry, or null when the row carries no usable URL.
  ///
  /// `ReviewResource` maps **every** element of the raw `images`/`videos` JSON
  /// column through `RvMedia::getImageUrl()`, which returns `$default` (null)
  /// for an empty stored path — so a review whose column holds a null or `""`
  /// element serializes as `{"thumbnail": null, "full_url": null}`. Keeping
  /// that produces a gallery tile bound to `''`, which throws inside
  /// `Image.network`. Drop it instead.
  static ReviewMedia? tryParse(Map<String, dynamic> j, ReviewMediaKind kind) {
    final full = asStringOrNull(j['full_url'] ?? j['url']);
    final thumb = asStringOrNull(j['thumbnail']);
    if (full == null && thumb == null) return null;
    return ReviewMedia(
      // Fall back to the full URL rather than an empty string: a missing
      // derivative should still render, just heavier.
      thumbnail: thumb ?? full!,
      fullUrl: full ?? thumb!,
      kind: kind,
    );
  }

  static List<ReviewMedia> parseList(dynamic raw, ReviewMediaKind kind) => [
        for (final entry in asMapList(raw))
          if (tryParse(entry, kind) case final media?) media,
      ];
}

/// The product a review was left on. Only present on `GET /ecommerce/reviews`
/// (the customer's own list) — the public per-product route omits it, because
/// the caller already knows the product.
class ReviewProduct {
  const ReviewProduct({
    required this.id,
    required this.name,
    required this.slug,
    this.image,
    this.url,
  });

  final int id;
  final String name;
  final String slug;
  final String? image;
  final String? url;

  factory ReviewProduct.fromJson(Map<String, dynamic> j) => ReviewProduct(
        id: asInt(j['id']),
        name: asString(j['name']),
        slug: asString(j['slug']),
        image: asStringOrNull(j['image']),
        url: asStringOrNull(j['url']),
      );
}

class Review {
  const Review({
    required this.id,
    required this.userName,
    required this.avatar,
    required this.createdAt,
    required this.createdAtRelative,
    required this.comment,
    required this.star,
    required this.status,
    required this.statusLabel,
    required this.images,
    required this.videos,
    this.orderedAt,
    this.orderedAtLabel,
    this.product,
    this.reply,
    this.isApproved = true,
  });

  final int id;
  final String userName;

  /// Raw `user_avatar`. **Do not bind this straight into a list item** — see
  /// [isInlineAvatar] / [avatarUrl].
  final String? avatar;

  /// Real timestamp, parsed from `created_at_tz`.
  ///
  /// The sibling `created_at` is human-relative prose ("2 weeks ago") produced
  /// by Carbon's diffForHumans, is localized server-side, and cannot be parsed
  /// back into a date. Sorting or bucketing must use this field.
  final DateTime? createdAt;

  /// Server-rendered "2 weeks ago". Display-only; kept because it is already
  /// localized and matches the website's wording.
  final String createdAtRelative;

  final String comment;

  /// 1..5. Arrives as a number, but the column is validated `numeric` (not
  /// `integer`) so a stringified value is within contract.
  final int star;

  /// `pending` | `published`. Machine value; use [statusLabel] for display.
  final String status;
  final String statusLabel;

  final List<ReviewMedia> images;
  final List<ReviewMedia> videos;

  /// When the reviewer's order was placed. Null when the review is not linked
  /// to an order (reviews predating the purchase requirement, or seeded data).
  final DateTime? orderedAt;

  /// Pre-rendered by the server **with a leading emoji**: "✅ Purchased 7 months
  /// ago". It is not a plain date and not a boolean — the emoji is baked into
  /// the translation string, so do not add your own verified-purchase badge on
  /// top of it. Use [isVerifiedPurchase] to decide whether to show it at all.
  final String? orderedAtLabel;

  final ReviewProduct? product;

  /// The store's answer, shown under the review in a tinted box.
  final ReviewReply? reply;

  /// False only on the caller's **own** review, while it waits for moderation.
  ///
  /// Nobody else is ever shown an unapproved review — the API stopped returning
  /// them publicly on 2026-08-12 — so this is a "yours, not live yet" marker
  /// rather than a general status.
  final bool isApproved;

  bool get isPublished => status == 'published';
  bool get isPending => status == 'pending';

  /// The server only emits `ordered_at*` when it found a matching order, so its
  /// presence *is* the verified-purchase signal. There is no boolean flag.
  bool get isVerifiedPurchase => orderedAt != null || orderedAtLabel != null;

  bool get hasMedia => images.isNotEmpty || videos.isNotEmpty;

  /// Whether `user_avatar` is an inline `data:` URI rather than a URL.
  ///
  /// Whenever a reviewer has no uploaded avatar the backend generates an
  /// initials image and embeds it in the JSON as base64 — roughly 3.9 KB per
  /// review, measured at 45–69% of the whole response body. Worse, it is
  /// re-encoded on every request: the same review came back at 2927, 3259, 3835
  /// and 4003 bytes across identical calls, so the bytes are not stable and
  /// nothing downstream (HTTP cache, image cache keyed on the URI) can reuse
  /// them.
  ///
  /// A scrolling review list should therefore branch on this and draw initials
  /// locally instead of base64-decoding a multi-KB payload per row.
  bool get isInlineAvatar => avatar != null && avatar!.startsWith('data:');

  /// The avatar only when it is a cacheable network URL. Null for the inline
  /// case, so `avatarUrl == null` is the "render initials yourself" branch.
  String? get avatarUrl => isInlineAvatar ? null : avatar;

  /// Uppercase initials for the local-avatar fallback.
  ///
  /// `user_name` is free text a customer typed, so it can start with an emoji
  /// or any other astral-plane character. Taking `substring(0, 1)` there splits
  /// the surrogate pair and yields an unpaired half that renders as tofu — the
  /// first *rune* is taken instead.
  String get initials {
    final parts = userName.trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first._firstRune();
    return '${parts.first._firstRune()}${parts.last._firstRune()}';
  }

  factory Review.fromJson(Map<String, dynamic> j) {
    // `status` is a bare string here ("pending") — unlike order/return status,
    // which are {value,label} objects. Accept both so a backend that
    // regularizes this later does not break the app.
    final rawStatus = j['status'];
    final statusValue =
        rawStatus is Map ? asString(rawStatus['value']) : asString(rawStatus);
    final statusLabel = rawStatus is Map && rawStatus['label'] != null
        ? asString(rawStatus['label'])
        : asStringOrNull(j['status_text']) ?? statusValue;

    return Review(
      id: asInt(j['id']),
      userName: asString(j['user_name']),
      avatar: asStringOrNull(j['user_avatar']),
      createdAt: _parseTz(j['created_at_tz']),
      createdAtRelative: asString(j['created_at']),
      comment: asString(j['comment']),
      star: asInt(j['star']).clamp(0, 5),
      status: statusValue,
      statusLabel: statusLabel,
      images: ReviewMedia.parseList(j['images'], ReviewMediaKind.image),
      videos: ReviewMedia.parseList(j['videos'], ReviewMediaKind.video),
      orderedAt: _parseTz(j['ordered_at_tz']),
      orderedAtLabel: asStringOrNull(j['ordered_at']),
      product: j['product'] is Map
          ? ReviewProduct.fromJson(
              Map<String, dynamic>.from(j['product'] as Map),
            )
          : null,
      reply: j['reply'] is Map
          ? ReviewReply.fromJson(Map<String, dynamic>.from(j['reply'] as Map))
          : null,
      // Absent on older payloads and on other people's reviews, both of which
      // mean "live".
      isApproved: j['is_approved'] == null ? true : asBool(j['is_approved']),
    );
  }

  /// `*_tz` fields are ISO8601 with a real offset ("2026-07-16T16:25:29+05:30").
  /// Parsed to local time so relative-time widgets agree with the device clock.
  ///
  /// Shared with the review-adjacent types below — [ReviewReply],
  /// [ReviewEligibility], [ReviewableProduct] — which all carry the same
  /// timestamp shape and should not each grow their own copy.
  static DateTime? parseTz(dynamic v) => _parseTz(v);

  static DateTime? _parseTz(dynamic v) {
    final raw = asStringOrNull(v);
    if (raw == null) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }
}

extension on String {
  String _firstRune() {
    if (isEmpty) return '?';
    return String.fromCharCode(runes.first).toUpperCase();
  }
}

/// One page of `GET /ecommerce/products/{slug}/reviews`.
///
/// The endpoint's `data` is an **object**, not a list and not a Laravel
/// paginator: `{reviews: [...], has_reviewed: bool, user_review: null|Review}`.
/// There is no `meta`, no `last_page`, and no star-count breakdown anywhere in
/// the API. The paginator's `total` does escape, but only as prose inside
/// `message` — see [total] — so [isLastPage] leans on a short page first and
/// uses that number only to close the exact-multiple case.
class ProductReviewPage {
  const ProductReviewPage({
    required this.reviews,
    required this.hasReviewed,
    required this.isLastPage,
    this.userReview,
    this.message,
    this.eligibility = ReviewEligibility.unknown,
    this.settings = ReviewSettings.fallback,
    this.summary = ReviewSummary.empty,
    this.pagination = ReviewsPagination.none,
  });

  final List<Review> reviews;

  /// Whether the *authenticated* caller already reviewed this product. Always
  /// false for anonymous requests — it is not a product-level flag.
  final bool hasReviewed;

  /// The caller's own review, when [hasReviewed].
  ///
  /// A full review object, fetched independently of the page — the server looks
  /// it up with `Review::getUserReview()`, so it may or may not also appear in
  /// [reviews] depending on which page it falls on. De-duplicate by id if you
  /// pin it to the top.
  final Review? userReview;

  /// Whether nothing follows this page.
  ///
  /// Mostly inferred: the envelope carries no `last_page`, and a page past the
  /// end just returns `reviews: []` (verified — page=2 of a 2-review product).
  /// A page shorter than the requested per_page therefore ends the walk.
  /// [total], when it could be read, closes the remaining hole: a *full* page
  /// that already covers the total is also the last one.
  ///
  /// Set to false by `ReviewRepository.allProductReviews` when it stopped at its
  /// page cap rather than at the real end — the collected list is a prefix, not
  /// the whole set.
  ///
  /// Read from [pagination] since the server started sending it (2026-08-12).
  /// It used to be inferred from a short page plus a total scraped out of an
  /// English sentence, which could not tell "last page" from "exactly a full
  /// page and no more".
  final bool isLastPage;

  /// Whether this customer may write a review, and why not. Gate the entry
  /// point on it rather than letting them write one and be refused on submit.
  final ReviewEligibility eligibility;

  /// Upload limits, from admin settings rather than app constants.
  final ReviewSettings settings;

  /// Rating bars and the media strip. **[ReviewSummary.count] is the review
  /// count** — the length of [reviews] is one page of it.
  final ReviewSummary summary;

  final ReviewsPagination pagination;

  /// The server's sentence, e.g. `2 review(s) for "Organic Desi Khand"`. It is
  /// the only place a total appears. Kept raw for [total] and for debugging.
  final String? message;

  bool get isEmpty => reviews.isEmpty;

  /// Total for the current filter, scraped from [message].
  ///
  /// The number is `$reviews->total()` off the server's paginator (see
  /// `ProductController::reviews`), so it is exact and it *does* respect the
  /// `star` filter — but it only reaches us embedded in a translatable
  /// sentence, so it is null whenever the wording stops matching. Treat a null
  /// as "unknown", never as zero, and keep paging until [isLastPage].
  int? get total =>
      pagination.total > 0 ? pagination.total : _totalFrom(message);

  static int? _totalFrom(String? message) {
    // Anchored, and the digits must be followed by whitespace. Both English
    // templates put :total first (`:total review(s) for ":product"`); a
    // translation that leads with the product cannot false-positive because
    // :product is always quoted, so the string would start with `"`.
    final m = RegExp(r'^\s*(\d+)\s').firstMatch(message ?? '');
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  factory ProductReviewPage.fromJson(
    Map<String, dynamic> body, {
    required int perPage,
    int page = 1,
  }) {
    final data = asMap(body['data']);
    final userReview = data['user_review'];
    final reviews = asMapList(data['reviews']).map(Review.fromJson).toList();
    final message = asStringOrNull(body['message']);
    final total = _totalFrom(message);

    final safePerPage = perPage < 1 ? 1 : perPage;
    final safePage = page < 1 ? 1 : page;

    final paginationJson = data['reviews_pagination'];
    final pagination = paginationJson is Map
        ? ReviewsPagination.fromJson(Map<String, dynamic>.from(paginationJson))
        : null;

    return ProductReviewPage(
      reviews: reviews,
      // Sent as a real bool today; asBool also covers 0/1 and "true".
      hasReviewed: asBool(data['has_reviewed']),
      userReview: userReview is Map
          ? Review.fromJson(Map<String, dynamic>.from(userReview))
          : null,
      // The block wins when it is there. The inference behind it is kept only
      // for a deployment that predates it — the two disagree on a page that
      // exactly fills its size, and the server is the one that is right.
      isLastPage: pagination != null
          ? !pagination.hasMore
          : reviews.length < safePerPage ||
              (total != null && safePage * safePerPage >= total),
      message: message,
      eligibility: data['review_eligibility'] is Map
          ? ReviewEligibility.fromJson(
              Map<String, dynamic>.from(data['review_eligibility'] as Map),
            )
          : ReviewEligibility.unknown,
      settings: data['review_settings'] is Map
          ? ReviewSettings.fromJson(
              Map<String, dynamic>.from(data['review_settings'] as Map),
            )
          : ReviewSettings.fallback,
      summary: data['review_summary'] is Map
          ? ReviewSummary.fromJson(
              Map<String, dynamic>.from(data['review_summary'] as Map),
            )
          : ReviewSummary.empty,
      pagination: pagination ?? ReviewsPagination.none,
    );
  }
}

/// The store's reply to a review.
///
/// [avatar] arrives as a `data:` URI when the replying staff member has no
/// photo — the server generates an initials image and inlines it. Bind it
/// through `AppNetworkImage`, which decodes those; a loader that only
/// understands http shows a placeholder on most replies.
class ReviewReply {
  const ReviewReply({
    required this.id,
    required this.message,
    required this.userName,
    this.avatar,
    this.createdAt,
    this.createdAtRelative = '',
  });

  final int id;
  final String message;
  final String userName;
  final String? avatar;
  final DateTime? createdAt;
  final String createdAtRelative;

  /// Same rule as [Review.avatarUrl]: an inline `data:` payload is not a URL to
  /// load, it is a generated initials image. Drawing initials locally is
  /// cheaper and looks the same — see the reasoning on [Review.isInlineAvatar].
  String? get avatarUrl =>
      (avatar?.startsWith('data:') ?? true) ? null : avatar;

  String get initials {
    final parts = userName.trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) return '?';
    final first = String.fromCharCode(parts.first.runes.first).toUpperCase();
    if (parts.length == 1) return first;
    return '$first${String.fromCharCode(parts.last.runes.first).toUpperCase()}';
  }

  factory ReviewReply.fromJson(Map<String, dynamic> j) => ReviewReply(
        id: asInt(j['id']),
        message: asString(j['message']),
        userName: asString(j['user_name']),
        avatar: asStringOrNull(j['user_avatar']),
        createdAt: Review.parseTz(j['created_at_tz']),
        createdAtRelative: asString(j['created_at']),
      );
}

/// Whether this customer may review this product, decided by the server.
///
/// The app used to let anyone open the form and only learn the answer from the
/// 422 that came back after they had written it. The same [reason] codes come
/// back from `POST /reviews`, so one handler covers the gate and the failure.
class ReviewEligibility {
  const ReviewEligibility({
    required this.canReview,
    this.reason,
    this.message,
    this.availableAt,
  });

  final bool canReview;

  /// A stable code — `login_required`, `already_reviewed`, `purchase_required`,
  /// `review_delay`, `review_disabled`, `upload_failed`. Branch on this; the
  /// [message] beside it is translated and may change wording.
  final String? reason;

  final String? message;

  /// Only on `review_delay`: when the post-delivery waiting period lifts.
  final DateTime? availableAt;

  /// Nothing known yet. Defaults to "let them try": the server refuses on
  /// submit anyway, and a silently hidden button is worse than a refused one.
  static const ReviewEligibility unknown = ReviewEligibility(canReview: true);

  bool get isLoginRequired => reason == 'login_required';
  bool get isAlreadyReviewed => reason == 'already_reviewed';

  /// Nothing the customer can do here, so the entry point is hidden entirely
  /// rather than shown disabled.
  bool get isHopeless =>
      reason == 'purchase_required' || reason == 'review_disabled';

  factory ReviewEligibility.fromJson(Map<String, dynamic> j) =>
      ReviewEligibility(
        canReview: asBool(j['can_review']),
        reason: asStringOrNull(j['reason']),
        message: asStringOrNull(j['message']),
        availableAt: Review.parseTz(j['available_at']),
      );
}

/// Upload limits, from the store's admin settings.
///
/// Hardcoding these meant an admin change silently desynchronised the picker
/// from the server, and uploads started failing with no useful message.
class ReviewSettings {
  const ReviewSettings({
    required this.maxImages,
    required this.maxImageBytes,
    required this.imageExtensions,
    required this.maxVideos,
    required this.maxVideoBytes,
    required this.maxVideoSeconds,
    required this.videoExtensions,
    required this.needsApproval,
  });

  final int maxImages;
  final int maxImageBytes;
  final List<String> imageExtensions;
  final int maxVideos;
  final int maxVideoBytes;
  final int maxVideoSeconds;
  final List<String> videoExtensions;

  /// When true the submit flow must say the review is awaiting approval rather
  /// than implying it is live.
  final bool needsApproval;

  /// What the store reported on 2026-08-12. Used only until the real settings
  /// arrive, so a picker opened during the fetch is never unbounded.
  static const ReviewSettings fallback = ReviewSettings(
    maxImages: 6,
    maxImageBytes: 2048 * 1024,
    imageExtensions: ['jpg', 'jpeg', 'png'],
    maxVideos: 2,
    maxVideoBytes: 10240 * 1024,
    maxVideoSeconds: 30,
    videoExtensions: ['mp4', 'mov'],
    needsApproval: true,
  );

  factory ReviewSettings.fromJson(Map<String, dynamic> j) => ReviewSettings(
        maxImages: asInt(j['max_file_number'], fallback.maxImages),
        // `max_file_size_kb` is the precise one; the MB field is rounded.
        maxImageBytes:
            asInt(j['max_file_size_kb'], fallback.maxImageBytes ~/ 1024) * 1024,
        imageExtensions:
            _extensions(j['accepted_image_types'], fallback.imageExtensions),
        maxVideos: asInt(j['max_video_number'], fallback.maxVideos),
        maxVideoBytes:
            asInt(j['max_video_size_kb'], fallback.maxVideoBytes ~/ 1024) *
                1024,
        maxVideoSeconds:
            asInt(j['max_video_duration'], fallback.maxVideoSeconds),
        videoExtensions:
            _extensions(j['accepted_video_types'], fallback.videoExtensions),
        needsApproval: asBool(j['need_to_be_approved'], true),
      );

  static List<String> _extensions(dynamic raw, List<String> fallback) {
    final list = asStringList(raw)
        .map((e) => e.trim().toLowerCase().replaceAll('.', ''))
        .where((e) => e.isNotEmpty)
        .toList();
    return list.isEmpty ? fallback : list;
  }
}

/// One bar of the rating breakdown.
///
/// ⚠ `count` in the payload is **not a count**. On 2026-08-12 the server sent
/// `{"star": 5, "count": 100, "percent": 100}` for a product with exactly one
/// review, on every product probed — the field carries the percentage. It is
/// not parsed, and no per-star tally is shown, rather than telling a customer
/// there are 100 reviews when there is one.
class StarBar {
  const StarBar({required this.star, required this.percent});

  final int star;
  final double percent;

  double get fraction => (percent / 100).clamp(0, 1).toDouble();

  factory StarBar.fromJson(Map<String, dynamic> j) => StarBar(
        star: asInt(j['star']).clamp(1, 5),
        percent: asDouble(j['percent']).clamp(0, 100).toDouble(),
      );
}

/// Ratings breakdown and the media strip, across a product's approved reviews.
class ReviewSummary {
  const ReviewSummary({
    required this.average,
    required this.count,
    required this.bars,
    required this.images,
    required this.videos,
  });

  final double average;

  /// Approved reviews only. **Use this for a count badge**, never the length of
  /// the returned page — the page is paginated, and since moderation started
  /// being honoured it also excludes other people's pending reviews.
  final int count;

  /// Five entries, 5★ down to 1★.
  final List<StarBar> bars;

  final List<ReviewMedia> images;
  final List<ReviewMedia> videos;

  static const ReviewSummary empty = ReviewSummary(
    average: 0,
    count: 0,
    bars: [],
    images: [],
    videos: [],
  );

  bool get hasMedia => images.isNotEmpty || videos.isNotEmpty;

  factory ReviewSummary.fromJson(Map<String, dynamic> j) => ReviewSummary(
        average: asDouble(j['reviews_avg']),
        count: asInt(j['reviews_count']),
        bars: asMapList(j['star_distribution']).map(StarBar.fromJson).toList(),
        images: ReviewMedia.parseList(j['images'], ReviewMediaKind.image),
        videos: ReviewMedia.parseList(j['videos'], ReviewMediaKind.video),
      );
}

/// Page state for the nested `reviews` array.
///
/// The array sits inside `data`, so Laravel's top-level paginator envelope is
/// not there and this block carries the page state instead. It replaced a
/// heuristic that inferred the end from a short page plus a total parsed out of
/// an English sentence.
class ReviewsPagination {
  const ReviewsPagination({
    required this.currentPage,
    required this.lastPage,
    required this.perPage,
    required this.total,
    required this.hasMore,
  });

  final int currentPage;
  final int lastPage;
  final int perPage;
  final int total;
  final bool hasMore;

  static const ReviewsPagination none = ReviewsPagination(
    currentPage: 1,
    lastPage: 1,
    perPage: 0,
    total: 0,
    hasMore: false,
  );

  factory ReviewsPagination.fromJson(Map<String, dynamic> j) =>
      ReviewsPagination(
        currentPage: asInt(j['current_page'], 1),
        lastPage: asInt(j['last_page'], 1),
        perPage: asInt(j['per_page']),
        total: asInt(j['total']),
        hasMore: asBool(j['has_more']),
      );
}

/// A product the customer bought and has not reviewed yet.
///
/// From `GET /ecommerce/reviews/products-to-review`. Anything still inside the
/// post-delivery waiting period is filtered out server-side, so every row here
/// can be reviewed right now — which is what lets the tab render without a
/// per-row eligibility check.
class ReviewableProduct {
  const ReviewableProduct({
    required this.id,
    required this.name,
    required this.slug,
    this.image,
    this.orderId,
    this.orderCompletedAt,
  });

  final int id;

  /// Taken from the order line where available, so a product renamed since
  /// purchase still reads as the customer bought it.
  final String name;

  final String slug;
  final String? image;
  final int? orderId;
  final DateTime? orderCompletedAt;

  factory ReviewableProduct.fromJson(Map<String, dynamic> j) =>
      ReviewableProduct(
        id: asInt(j['id']),
        name: asString(j['name']),
        slug: asString(j['slug']),
        image: asStringOrNull(j['image']),
        orderId: asInt(j['order_id']) == 0 ? null : asInt(j['order_id']),
        orderCompletedAt: Review.parseTz(j['order_completed_at']),
      );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/review.dart';

/// The reworked review contract, from live captures on 2026-08-12.
///
/// The endpoint now personalises its answer, honours moderation, and carries
/// four blocks that used to be guessed at or scraped: `review_eligibility`,
/// `review_settings`, `review_summary` and `reviews_pagination`.

/// A page envelope with whichever blocks a test cares about.
Map<String, dynamic> _envelope({
  List<Map<String, dynamic>> reviews = const [],
  Map<String, dynamic>? pagination,
  Map<String, dynamic>? eligibility,
  Map<String, dynamic>? settings,
  Map<String, dynamic>? summary,
  bool hasReviewed = false,
  Map<String, dynamic>? userReview,
  String? message,
}) =>
    {
      'error': false,
      'data': {
        'reviews': reviews,
        'has_reviewed': hasReviewed,
        'user_review': userReview,
        if (pagination != null) 'reviews_pagination': pagination,
        if (eligibility != null) 'review_eligibility': eligibility,
        if (settings != null) 'review_settings': settings,
        if (summary != null) 'review_summary': summary,
      },
      'message': message,
    };

/// The settings block exactly as the store sends it.
const _liveSettings = {
  'max_file_number': 6,
  'max_file_size_mb': 2,
  'max_file_size_kb': 2048,
  'accepted_image_types': ['jpg', 'jpeg', 'png'],
  'max_video_number': 2,
  'max_video_size_mb': 10,
  'max_video_size_kb': 10240,
  'max_video_duration': 30,
  'accepted_video_types': ['mp4', 'mov'],
  'need_to_be_approved': true,
};

void main() {
  group('reviews_pagination', () {
    // The old code inferred the end from a short page plus a total scraped out
    // of an English sentence. That could not tell "last page" from "exactly a
    // full page and nothing behind it".
    test('a full page with more behind it is not the last', () {
      final page = ProductReviewPage.fromJson(
        _envelope(
          reviews: List.generate(10, (i) => {'id': i, 'star': 5}),
          pagination: {
            'current_page': 1,
            'last_page': 3,
            'per_page': 10,
            'total': 24,
            'has_more': true,
          },
        ),
        perPage: 10,
      );

      expect(page.isLastPage, isFalse);
      expect(page.total, 24);
    });

    test('the server ends the walk, not the row count', () {
      final page = ProductReviewPage.fromJson(
        _envelope(
          reviews: List.generate(10, (i) => {'id': i, 'star': 5}),
          pagination: {
            'current_page': 3,
            'last_page': 3,
            'per_page': 10,
            'total': 30,
            'has_more': false,
          },
        ),
        perPage: 10,
      );

      expect(
        page.isLastPage,
        isTrue,
        reason: 'a full page can still be the last one',
      );
    });

    // Kept so a deployment that predates the block still pages correctly.
    test('falls back to the old inference when the block is absent', () {
      final page = ProductReviewPage.fromJson(
        _envelope(
          reviews: [
            {'id': 1, 'star': 5},
          ],
          message: '1 review(s) for "Wheat"',
        ),
        perPage: 10,
      );

      expect(page.isLastPage, isTrue);
      expect(page.total, 1, reason: 'scraped out of the sentence');
    });
  });

  group('review_eligibility', () {
    test('reads the gate and its reason', () {
      final page = ProductReviewPage.fromJson(
        _envelope(
          eligibility: {
            'can_review': false,
            'reason': 'purchase_required',
            'message': 'Please purchase the product for a review!',
          },
        ),
        perPage: 10,
      );

      expect(page.eligibility.canReview, isFalse);
      expect(page.eligibility.reason, 'purchase_required');
      expect(page.eligibility.isHopeless, isTrue);
      expect(page.eligibility.message, contains('purchase'));
    });

    // Only `review_delay` carries it, and it drives a countdown.
    test('parses available_at on a delay', () {
      final page = ProductReviewPage.fromJson(
        _envelope(
          eligibility: {
            'can_review': false,
            'reason': 'review_delay',
            'message': 'You can review this from 20 Aug.',
            'available_at': '2026-08-20T10:00:00+05:30',
          },
        ),
        perPage: 10,
      );

      expect(page.eligibility.availableAt?.year, 2026);
      expect(page.eligibility.isHopeless, isFalse, reason: 'it lifts');
    });

    // A missing block must not hide the button: the server refuses on submit
    // anyway, and a silently absent entry point is worse than a refused one.
    test('defaults to letting them try', () {
      final page = ProductReviewPage.fromJson(_envelope(), perPage: 10);

      expect(page.eligibility.canReview, isTrue);
      expect(page.eligibility.reason, isNull);
    });

    test('login_required and already_reviewed are distinguishable', () {
      ReviewEligibility of(String reason) => ReviewEligibility.fromJson(
            {'can_review': false, 'reason': reason},
          );

      expect(of('login_required').isLoginRequired, isTrue);
      expect(of('login_required').isHopeless, isFalse,
          reason: 'signing in is an action they can take',);
      expect(of('already_reviewed').isAlreadyReviewed, isTrue);
      expect(of('review_disabled').isHopeless, isTrue);
    });
  });

  group('review_settings', () {
    test('reads the store limits', () {
      final page = ProductReviewPage.fromJson(
        _envelope(settings: _liveSettings),
        perPage: 10,
      );
      final s = page.settings;

      expect(s.maxImages, 6);
      expect(s.maxVideos, 2);
      expect(s.maxVideoSeconds, 30);
      expect(s.imageExtensions, ['jpg', 'jpeg', 'png']);
      expect(s.videoExtensions, ['mp4', 'mov']);
      expect(s.needsApproval, isTrue);
    });

    // The KB field is the precise one — MB is rounded, and 2 MB vs 2048 KB
    // happens to agree here only by luck.
    test('sizes come from the KB fields', () {
      final page = ProductReviewPage.fromJson(
        _envelope(
          settings: {..._liveSettings, 'max_file_size_kb': 1500},
        ),
        perPage: 10,
      );

      expect(page.settings.maxImageBytes, 1500 * 1024);
    });

    test('falls back rather than leaving a picker unbounded', () {
      final page = ProductReviewPage.fromJson(_envelope(), perPage: 10);

      expect(page.settings.maxImages, ReviewSettings.fallback.maxImages);
      expect(page.settings.needsApproval, isTrue);
    });

    test('an empty type list falls back instead of accepting nothing', () {
      final page = ProductReviewPage.fromJson(
        _envelope(
          settings: {..._liveSettings, 'accepted_image_types': <String>[]},
        ),
        perPage: 10,
      );

      expect(page.settings.imageExtensions, isNotEmpty);
    });
  });

  group('review_summary', () {
    final summary = {
      'reviews_avg': 5,
      'reviews_count': 1,
      'star_distribution': [
        {'star': 5, 'count': 100, 'percent': 100},
        {'star': 4, 'count': 0, 'percent': 0},
        {'star': 3, 'count': 0, 'percent': 0},
        {'star': 2, 'count': 0, 'percent': 0},
        {'star': 1, 'count': 0, 'percent': 0},
      ],
      'images': [
        {'thumbnail': 'https://x/4-150x150.jpg', 'full_url': 'https://x/4.jpg'},
      ],
      'videos': <Map<String, dynamic>>[],
    };

    test('reads the average, the count and five bars', () {
      final page =
          ProductReviewPage.fromJson(_envelope(summary: summary), perPage: 10);

      expect(page.summary.average, 5);
      expect(page.summary.count, 1);
      expect(page.summary.bars, hasLength(5));
      expect(page.summary.bars.first.star, 5);
      expect(page.summary.bars.first.fraction, 1);
      expect(page.summary.hasMedia, isTrue);
    });

    // ⚠ The payload's `count` is 100 for a product with one review — on every
    // product probed. The field carries the percentage, so it is not parsed and
    // no per-star tally is shown. This pins that it stays unparsed: rendering
    // it would tell a customer there are 100 reviews when there is one.
    test('the untrustworthy per-star count is not exposed', () {
      final page =
          ProductReviewPage.fromJson(_envelope(summary: summary), perPage: 10);

      expect(page.summary.count, 1, reason: 'the real total');
      expect(
        page.summary.bars.first.percent,
        100,
        reason: 'percent is the only trustworthy field on a bar',
      );
    });

    // The count badge must come from here, not from the page length.
    test('the summary count survives a short page', () {
      final page = ProductReviewPage.fromJson(
        _envelope(
          reviews: [
            {'id': 1, 'star': 5},
          ],
          summary: {...summary, 'reviews_count': 24},
        ),
        perPage: 10,
      );

      expect(page.reviews, hasLength(1));
      expect(page.summary.count, 24);
    });
  });

  group('reply and moderation', () {
    test('reads the store reply', () {
      final page = ProductReviewPage.fromJson(
        _envelope(
          reviews: [
            {
              'id': 1016,
              'star': 5,
              'user_name': 'vikram',
              'reply': {
                'id': 2,
                'message': 'this demo reply',
                'user_name': 'Trueway Farms',
                'user_avatar': 'data:image/jpeg;base64,/9j/4AAQ',
                'created_at': '2 months ago',
              },
            },
          ],
        ),
        perPage: 10,
      );

      final reply = page.reviews.single.reply!;
      expect(reply.message, 'this demo reply');
      expect(reply.userName, 'Trueway Farms');
      // Same rule as the reviewer's avatar: an inline payload is a generated
      // initials image, not a URL worth loading.
      expect(reply.avatarUrl, isNull);
      expect(reply.initials, 'TF');
    });

    test('a review without a reply has none', () {
      final page = ProductReviewPage.fromJson(
        _envelope(
          reviews: [
            {'id': 1, 'star': 5},
          ],
        ),
        perPage: 10,
      );

      expect(page.reviews.single.reply, isNull);
    });

    // Only ever false on the caller's own review — pending reviews stopped
    // being returned publicly on 2026-08-12.
    test('is_approved false marks the caller own pending review', () {
      final page = ProductReviewPage.fromJson(
        _envelope(
          reviews: [
            {'id': 1, 'star': 5, 'is_approved': false},
          ],
        ),
        perPage: 10,
      );

      expect(page.reviews.single.isApproved, isFalse);
    });

    // Absent on other people's reviews and on older payloads; both mean live.
    test('a missing is_approved means approved', () {
      final page = ProductReviewPage.fromJson(
        _envelope(
          reviews: [
            {'id': 1, 'star': 5},
          ],
        ),
        perPage: 10,
      );

      expect(page.reviews.single.isApproved, isTrue);
    });
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/models/review.dart';
import 'package:trueway_farms/data/repositories/review_repository.dart';

/// Captured verbatim from
/// `GET /ecommerce/products/trueway-farms-organic-desi-khand-brown-khandsari/reviews`
/// (api-probe/reviews.json), with only the two base64 avatars truncated — the
/// real ones are ~3.9 KB each and the prefix is all the parser looks at.
const _productReviewsJson = r'''
{
  "error": false,
  "data": {
    "reviews": [
      {
        "id": 1019,
        "user_name": "Suraj ojha",
        "user_avatar": "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBk=",
        "created_at_tz": "2026-07-16T16:25:29+05:30",
        "created_at": "2 weeks ago",
        "comment": "Lorem Ipsum is simply dummy text of the printing and typesetting industry.",
        "star": 5,
        "status": "pending",
        "status_text": "Pending",
        "images": [
          {
            "thumbnail": "https://dev.truewayerp.com/storage/reviews/817voulgejl-sl1500-1-150x150.jpg",
            "full_url": "https://dev.truewayerp.com/storage/reviews/817voulgejl-sl1500-1.jpg"
          }
        ],
        "videos": [
          {
            "thumbnail": "https://dev.truewayerp.com/storage/reviews/win-20260120-18-02-15-pro-12.mp4",
            "full_url": "https://dev.truewayerp.com/storage/reviews/win-20260120-18-02-15-pro-12.mp4"
          }
        ],
        "ordered_at_tz": "2025-12-10T17:28:52+05:30",
        "ordered_at": "✅ Purchased 7 months ago"
      },
      {
        "id": 1016,
        "user_name": "vikram kumar mishra",
        "user_avatar": "https://dev.truewayerp.com/storage/demo/download-2-150x150.jpeg",
        "created_at_tz": "2026-06-10T18:37:57+05:30",
        "created_at": "1 month ago",
        "comment": "Lorem Ipsum is simply dummy text of the printing and typesetting industry.",
        "star": 5,
        "status": "published",
        "status_text": "Published",
        "images": [
          {
            "thumbnail": "https://dev.truewayerp.com/storage/reviews/4-150x150.jpg",
            "full_url": "https://dev.truewayerp.com/storage/reviews/4.jpg"
          },
          {
            "thumbnail": "https://dev.truewayerp.com/storage/reviews/3-150x150.jpg",
            "full_url": "https://dev.truewayerp.com/storage/reviews/3.jpg"
          }
        ],
        "videos": [
          {
            "thumbnail": "https://dev.truewayerp.com/storage/reviews/demo.mp4",
            "full_url": "https://dev.truewayerp.com/storage/reviews/demo.mp4"
          },
          {
            "thumbnail": "https://dev.truewayerp.com/storage/reviews/demo-1.mp4",
            "full_url": "https://dev.truewayerp.com/storage/reviews/demo-1.mp4"
          }
        ],
        "ordered_at_tz": "2026-02-18T17:48:54+05:30",
        "ordered_at": "✅ Purchased 5 months ago"
      }
    ],
    "has_reviewed": false,
    "user_review": null
  },
  "message": "2 review(s) for \"Trueway Farms Organic Desi Khand Brown (khandsari)\""
}
''';

/// api-probe/reviews_prod119.json — a product nobody has reviewed. Note `data`
/// is still an object; only `reviews` is empty.
const _emptyReviewsJson = r'''
{
  "error": false,
  "data": {
    "reviews": [],
    "has_reviewed": false,
    "user_review": null
  },
  "message": "0 review(s) for \"Trueway Farms - An Organic Land -nature To Natural Sona Moti Wheat (sonamoti Gehu)\""
}
''';

/// api-probe/reviews_prod118_page2.json — page 2 of a 2-review product. The
/// server does NOT 404 or report last_page; it just returns an empty list.
const _pastLastPageJson = r'''
{
  "error": false,
  "data": {
    "reviews": [],
    "has_reviewed": false,
    "user_review": null
  },
  "message": "2 review(s) for \"Trueway Farms Organic Desi Khand Brown (khandsari)\""
}
''';

/// api-probe/reviews_prod118_star5.json — the `star` filter changes only the
/// wording of `message`; no histogram is ever returned.
const _starFilteredMessage =
    '2 review(s) "5 star" for "Trueway Farms Organic Desi Khand Brown (khandsari)"';

/// api-probe/auth_reviews_mine.json — `GET /ecommerce/reviews`. Hybrid envelope:
/// paginator keys plus `error`/`message`. Rows carry an extra `product`.
const _myReviewsJson = r'''
{
  "data": [
    {
      "id": 1019,
      "user_name": "Suraj ojha",
      "user_avatar": "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAYABgAAD/2wBDAAg=",
      "created_at_tz": "2026-07-16T16:25:29+05:30",
      "created_at": "2 weeks ago",
      "comment": "Lorem Ipsum is simply dummy text.",
      "star": 5,
      "status": "pending",
      "status_text": "Pending",
      "images": [],
      "videos": [],
      "ordered_at_tz": "2025-12-10T17:28:52+05:30",
      "ordered_at": "✅ Purchased 7 months ago",
      "product": {
        "id": 118,
        "name": "Trueway Farms Organic Desi Khand Brown (khandsari)",
        "slug": "trueway-farms-organic-desi-khand-brown-khandsari",
        "image": "https://dev.truewayerp.com/storage/products/whole-wheat/81xa52v7tol-sx679-150x150.jpg",
        "url": "https://dev.truewayerp.com/products/trueway-farms-organic-desi-khand-brown-khandsari"
      }
    }
  ],
  "links": {
    "first": "https://dev.truewayerp.com/api/v1/ecommerce/reviews?page=1",
    "last": "https://dev.truewayerp.com/api/v1/ecommerce/reviews?page=1",
    "prev": null,
    "next": null
  },
  "meta": {
    "current_page": 1,
    "from": 1,
    "last_page": 1,
    "path": "https://dev.truewayerp.com/api/v1/ecommerce/reviews",
    "per_page": 10,
    "to": 2,
    "total": 2
  },
  "error": false,
  "message": null
}
''';

/// Captured verbatim from a request sent without `X-API-KEY`
/// (api-probe/err_reviews_noapikey.json). `error` is the **string**
/// "Unauthorized", not a bool — `ApiException.declaresFailure` only matches
/// `error == true`, so this body is not caught by ApiClient.
const _noApiKeyJson =
    '{"message":"Invalid or missing API key. Please provide a valid X-API-KEY '
    'header.","error":"Unauthorized"}';

/// api-probe/err_reviews_badslug.json — no `data`, no `error`, empty message.
const _emptyMessageJson = '{"message":""}';

Map<String, dynamic> _decode(String source) =>
    jsonDecode(source) as Map<String, dynamic>;

// ===========================================================================
// Repository harness. No socket is ever opened: the Dio HttpClientAdapter is
// replaced wholesale, so an un-canned path yields a local 500 rather than a
// real request.
// ===========================================================================

class _Canned {
  const _Canned(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);

  /// Keyed by `METHOD /path`; a queue so the same path can answer differently
  /// on successive pages.
  final Map<String, List<_Canned>> responses;
  final List<RequestOptions> requests = [];

  List<String> get calls => [for (final r in requests) '${r.method} ${r.uri}'];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final queue = responses['${options.method} ${options.path}'];
    final canned = (queue == null || queue.isEmpty)
        ? const _Canned(500, '{"message":"no canned response"}')
        : (queue.length == 1 ? queue.first : queue.removeAt(0));
    return ResponseBody.fromString(
      canned.body,
      canned.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

typedef _Harness = ({ReviewRepository repo, _FakeAdapter adapter});

Future<_Harness> _build(Map<String, List<_Canned>> responses) async {
  SharedPreferences.setMockInitialValues(const {'auth_token': 'test-token'});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(responses);
  return (
    repo: ReviewRepository(
      ApiClient(prefs: prefs, dio: Dio()..httpClientAdapter = adapter),
    ),
    adapter: adapter,
  );
}

const _slug = 'trueway-farms-organic-desi-khand-brown-khandsari';
const _productPath = '/ecommerce/products/$_slug/reviews';
const _mine = '/ecommerce/reviews';

_Canned _ok(String body) => _Canned(200, body);

/// One page holding [count] identical reviews, with [total] in the message.
String _pageOf(int count, int total) => jsonEncode({
      'error': false,
      'data': {
        'reviews': [
          for (var i = 0; i < count; i++)
            {'id': 1000 + i, 'user_name': 'x', 'star': 5, 'status': 'published'},
        ],
        'has_reviewed': false,
        'user_review': null,
      },
      'message': '$total review(s) for "Khand"',
    });

Future<Object?> _errorFrom(Future<Object?> future) =>
    future.then<Object?>((_) => null, onError: (Object e) => e);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProductReviewPage.fromJson — real capture', () {
    late ProductReviewPage page;

    setUp(() {
      page = ProductReviewPage.fromJson(
        _decode(_productReviewsJson),
        perPage: 10,
      );
    });

    test('unwraps the object-shaped `data` (not a list, not a paginator)', () {
      expect(page.reviews, hasLength(2));
      expect(page.hasReviewed, isFalse);
      expect(page.userReview, isNull);
      expect(page.reviews.first.id, 1019);
    });

    test('uses created_at_tz for the timestamp and keeps the prose separate',
        () {
      final r = page.reviews.first;
      expect(
        r.createdAt,
        DateTime.parse('2026-07-16T16:25:29+05:30').toLocal(),
      );
      // The human string must never be fed to a date parser.
      expect(r.createdAtRelative, '2 weeks ago');
      expect(DateTime.tryParse(r.createdAtRelative), isNull);
    });

    test('ordered_at is a pre-rendered emoji label, not a date', () {
      final r = page.reviews.first;
      expect(r.orderedAtLabel, '✅ Purchased 7 months ago');
      expect(
        r.orderedAt,
        DateTime.parse('2025-12-10T17:28:52+05:30').toLocal(),
      );
      expect(r.isVerifiedPurchase, isTrue);
    });

    test('status is a bare string here, with its label in status_text', () {
      expect(page.reviews[0].status, 'pending');
      expect(page.reviews[0].statusLabel, 'Pending');
      expect(page.reviews[0].isPending, isTrue);
      expect(page.reviews[1].status, 'published');
      expect(page.reviews[1].isPublished, isTrue);
    });

    test('video thumbnails are the mp4 itself and are flagged as such', () {
      final video = page.reviews.first.videos.single;
      expect(video.thumbnail, endsWith('.mp4'));
      expect(video.thumbnail, video.fullUrl);
      expect(video.isVideo, isTrue);
      expect(page.reviews.first.images.single.isVideo, isFalse);
    });

    test('separates inline base64 avatars from cacheable URLs', () {
      final inline = page.reviews[0];
      expect(inline.isInlineAvatar, isTrue);
      // The whole point: the UI must be able to skip this without inspecting
      // the raw string itself.
      expect(inline.avatarUrl, isNull);
      expect(inline.initials, 'SO');

      final hosted = page.reviews[1];
      expect(hosted.isInlineAvatar, isFalse);
      expect(hosted.avatarUrl, startsWith('https://'));
    });

    test('scrapes the only total the API exposes, out of prose', () {
      expect(page.total, 2);
    });

    test('a full page with more behind it is not assumed to be the last', () {
      // per_page 2, and the server says there are 9 in total.
      final body = _decode(_productReviewsJson)
        ..['message'] = '9 review(s) for "Khand"';
      expect(
        ProductReviewPage.fromJson(body, perPage: 2, page: 1).isLastPage,
        isFalse,
      );
      // Page 5 of 5 (2 per page, 9 total) still comes back full-length here,
      // but the total says it is the end.
      expect(
        ProductReviewPage.fromJson(body, perPage: 2, page: 5).isLastPage,
        isTrue,
      );
    });

    test('a short page ends the walk even without a usable total', () {
      final body = _decode(_productReviewsJson)..['message'] = 'Avis';
      expect(ProductReviewPage.fromJson(body, perPage: 10).isLastPage, isTrue);
      expect(ProductReviewPage.fromJson(body, perPage: 2).isLastPage, isFalse);
    });

    test('a full last page is recognised from the total, not guessed at', () {
      // The exact-multiple case the short-page heuristic alone cannot see:
      // 2 reviews, per_page 2. Without the total this reports "maybe more".
      final page = ProductReviewPage.fromJson(
        _decode(_productReviewsJson),
        perPage: 2,
        page: 1,
      );
      expect(page.total, 2);
      expect(page.isLastPage, isTrue);
    });

    test('video entries are flagged by which array they came from', () {
      final r = page.reviews.first;
      expect(r.videos.single.kind, ReviewMediaKind.video);
      expect(r.images.single.kind, ReviewMediaKind.image);
    });
  });

  group('ReviewMedia — kind beats the file extension', () {
    test('a video with an unrecognised extension is still a video', () {
      // `ec_reviews.videos` is a raw JSON column; only rows created through the
      // API pass `mimes:mp4,mov`. An admin-uploaded .avi must not be handed to
      // an Image widget just because the URL does not end in .mp4.
      final r = Review.fromJson({
        'id': 1,
        'videos': [
          {
            'thumbnail': 'https://x/storage/reviews/clip.avi',
            'full_url': 'https://x/storage/reviews/clip.avi',
          },
        ],
      });
      expect(r.videos.single.isVideo, isTrue);
      expect(r.videos.single.kind, ReviewMediaKind.video);
    });

    test('a video with no extension at all is still a video', () {
      final r = Review.fromJson({
        'id': 1,
        'videos': [
          {'thumbnail': 'https://cdn/x/abc123', 'full_url': 'https://cdn/x/abc'},
        ],
      });
      expect(r.videos.single.isVideo, isTrue);
    });

    test('an mp4 that leaked into images is caught by the extension too', () {
      final r = Review.fromJson({
        'id': 1,
        'images': [
          {'thumbnail': 'https://x/a.mp4', 'full_url': 'https://x/a.mp4'},
        ],
      });
      expect(r.images.single.isVideo, isTrue);
      expect(r.images.single.kind, ReviewMediaKind.image);
    });

    test('query strings do not defeat the extension check', () {
      final r = Review.fromJson({
        'id': 1,
        'images': [
          {'thumbnail': 'https://x/a.mp4?v=2', 'full_url': 'https://x/a.mp4'},
        ],
      });
      expect(r.images.single.isVideo, isTrue);
    });

    test('a media row with no usable url is dropped, not emitted empty', () {
      // RvMedia::getImageUrl() returns its $default (null) for an empty stored
      // path, and ReviewResource maps *every* element of the raw JSON column —
      // so a null/"" element serializes as {thumbnail: null, full_url: null}.
      // Keeping it produces a gallery tile bound to '', which throws inside
      // Image.network.
      final r = Review.fromJson({
        'id': 1,
        'images': [
          {'thumbnail': null, 'full_url': null},
          {'thumbnail': '', 'full_url': ''},
          {'thumbnail': 'https://x/ok-150x150.jpg', 'full_url': 'https://x/ok.jpg'},
        ],
      });
      expect(r.images, hasLength(1));
      expect(r.images.single.fullUrl, 'https://x/ok.jpg');
      expect(r.hasMedia, isTrue);
    });

    test('a review whose media is entirely unusable has no media', () {
      final r = Review.fromJson({
        'id': 1,
        'images': [
          {'thumbnail': null, 'full_url': null},
        ],
        'videos': [
          {'thumbnail': null, 'full_url': null},
        ],
      });
      expect(r.images, isEmpty);
      expect(r.videos, isEmpty);
      expect(r.hasMedia, isFalse);
    });
  });

  group('ProductReviewPage — empty and past-the-end shapes', () {
    test('a product with no reviews still returns the object envelope', () {
      final page =
          ProductReviewPage.fromJson(_decode(_emptyReviewsJson), perPage: 10);
      expect(page.reviews, isEmpty);
      expect(page.isEmpty, isTrue);
      expect(page.isLastPage, isTrue);
      expect(page.total, 0);
      expect(page.hasReviewed, isFalse);
    });

    test('page past the end is an empty list, not an error', () {
      final page =
          ProductReviewPage.fromJson(_decode(_pastLastPageJson), perPage: 10);
      expect(page.reviews, isEmpty);
      expect(page.isLastPage, isTrue);
      // The message still reports the full total, which is why paging cannot
      // rely on it to know it is done.
      expect(page.total, 2);
    });

    test('star-filtered message wording still yields the total', () {
      final body = _decode(_pastLastPageJson)
        ..['message'] = _starFilteredMessage;
      expect(ProductReviewPage.fromJson(body, perPage: 10).total, 2);
    });

    test('total is null rather than wrong when the wording changes', () {
      final body = _decode(_pastLastPageJson)
        ..['message'] = 'Avis pour "Khand"';
      expect(ProductReviewPage.fromJson(body, perPage: 10).total, isNull);
    });

    test('a body missing `data` entirely does not throw', () {
      final page = ProductReviewPage.fromJson(
        {'error': false, 'message': null},
        perPage: 10,
      );
      expect(page.reviews, isEmpty);
      expect(page.hasReviewed, isFalse);
      expect(page.userReview, isNull);
      expect(page.total, isNull);
    });
  });

  group('Review.fromJson — nullable and absent fields', () {
    test('every optional field absent', () {
      final r = Review.fromJson({'id': 7});
      expect(r.id, 7);
      expect(r.userName, '');
      expect(r.avatar, isNull);
      expect(r.isInlineAvatar, isFalse);
      expect(r.avatarUrl, isNull);
      expect(r.initials, '?');
      expect(r.createdAt, isNull);
      expect(r.createdAtRelative, '');
      expect(r.star, 0);
      expect(r.status, '');
      expect(r.statusLabel, '');
      expect(r.images, isEmpty);
      expect(r.videos, isEmpty);
      expect(r.hasMedia, isFalse);
      expect(r.product, isNull);
    });

    test('a review with no linked order is not a verified purchase', () {
      final r = Review.fromJson({
        'id': 7,
        'ordered_at_tz': null,
        'ordered_at': null,
      });
      expect(r.orderedAt, isNull);
      expect(r.orderedAtLabel, isNull);
      expect(r.isVerifiedPurchase, isFalse);
    });

    test('empty media arrays are not confused with missing ones', () {
      final r = Review.fromJson({'id': 7, 'images': [], 'videos': []});
      expect(r.images, isEmpty);
      expect(r.videos, isEmpty);
      expect(r.hasMedia, isFalse);
    });

    test('media entries missing a thumbnail fall back to the full url', () {
      final r = Review.fromJson({
        'id': 7,
        'images': [
          {'full_url': 'https://x/a.jpg'},
        ],
      });
      expect(r.images.single.thumbnail, 'https://x/a.jpg');
      expect(r.images.single.fullUrl, 'https://x/a.jpg');
    });

    test('non-map junk inside images is dropped, not crashed on', () {
      final r = Review.fromJson({
        'id': 7,
        'images': ['plain-string.jpg', null],
      });
      expect(r.images, isEmpty);
    });
  });

  group('Review.fromJson — type instability', () {
    test('numeric fields arriving as strings', () {
      // `star` is validated `numeric`, not `integer`, so a string is in
      // contract; ids have arrived stringified on other endpoints.
      final r = Review.fromJson({'id': '1019', 'star': '4'});
      expect(r.id, 1019);
      expect(r.star, 4);
    });

    test('an out-of-range star is clamped rather than surfaced', () {
      expect(Review.fromJson({'id': 1, 'star': 9}).star, 5);
      expect(Review.fromJson({'id': 1, 'star': -2}).star, 0);
    });

    test('status as the {value,label} object other endpoints use', () {
      final r = Review.fromJson({
        'id': 1,
        'status': {'value': 'published', 'label': 'Published'},
      });
      expect(r.status, 'published');
      expect(r.statusLabel, 'Published');
      expect(r.isPublished, isTrue);
    });

    test('status object without a label falls back to status_text', () {
      final r = Review.fromJson({
        'id': 1,
        'status': {'value': 'pending'},
        'status_text': 'Awaiting approval',
      });
      expect(r.statusLabel, 'Awaiting approval');
    });

    test('status string with no status_text still yields a label', () {
      final r = Review.fromJson({'id': 1, 'status': 'pending'});
      expect(r.statusLabel, 'pending');
    });

    test('has_reviewed as 1/0 and as "true"', () {
      ProductReviewPage build(Object? flag) => ProductReviewPage.fromJson(
            {
              'data': {
                'reviews': [],
                'has_reviewed': flag,
                'user_review': null,
              },
            },
            perPage: 10,
          );
      expect(build(1).hasReviewed, isTrue);
      expect(build(0).hasReviewed, isFalse);
      expect(build('true').hasReviewed, isTrue);
      expect(build(null).hasReviewed, isFalse);
    });

    test('user_review is a full review object when the caller has reviewed',
        () {
      final body = _decode(_productReviewsJson);
      final data = body['data'] as Map<String, dynamic>;
      data['has_reviewed'] = true;
      data['user_review'] = (data['reviews'] as List).first;

      final page = ProductReviewPage.fromJson(body, perPage: 10);
      expect(page.hasReviewed, isTrue);
      expect(page.userReview!.id, 1019);
      // It is duplicated inside `reviews`, so pinning it needs a de-dupe.
      expect(page.reviews.map((r) => r.id), contains(page.userReview!.id));
    });

    test('an inline avatar of any media type is detected', () {
      for (final uri in const [
        'data:image/jpeg;base64,/9j/4AAQ',
        'data:image/png;base64,iVBORw0K',
        'data:image/svg+xml;base64,PHN2Zw==',
      ]) {
        expect(
          Review.fromJson({'id': 1, 'user_avatar': uri}).isInlineAvatar,
          isTrue,
        );
      }
      expect(
        Review.fromJson({'id': 1, 'user_avatar': ''}).isInlineAvatar,
        isFalse,
        reason: 'asStringOrNull maps "" to null',
      );
    });

    test('single-word and blank names still produce initials', () {
      expect(Review.fromJson({'id': 1, 'user_name': 'vikram'}).initials, 'V');
      expect(
        Review.fromJson({'id': 1, 'user_name': '  vikram  kumar  mishra '})
            .initials,
        'VM',
      );
      expect(Review.fromJson({'id': 1, 'user_name': '   '}).initials, '?');
    });

    test('an astral first character is not sliced in half', () {
      // user_name is free text. substring(0, 1) on an emoji returns an unpaired
      // surrogate, which renders as tofu in the fallback avatar.
      final r = Review.fromJson({'id': 1, 'user_name': '😀 kumar'});
      expect(r.initials.runes, hasLength(2));
      expect(r.initials, '😀K');
      final solo = Review.fromJson({'id': 1, 'user_name': '😀'});
      expect(solo.initials, '😀');
      expect(solo.initials.runes, hasLength(1));
      // Devanagari (BMP) must survive untouched too.
      expect(Review.fromJson({'id': 1, 'user_name': 'सूरज ओझा'}).initials, 'सओ');
    });
  });

  group('my reviews list (hybrid envelope)', () {
    test('rows carry the product the public route omits', () {
      final body = _decode(_myReviewsJson);
      final rows = (body['data'] as List)
          .map((e) => Review.fromJson(e as Map<String, dynamic>))
          .toList();

      expect(rows, hasLength(1));
      expect(rows.single.product!.id, 118);
      expect(
        rows.single.product!.slug,
        'trueway-farms-organic-desi-khand-brown-khandsari',
      );
      expect(rows.single.product!.image, isNotNull);
      // Hybrid: paginator keys AND the {error, message} envelope keys.
      expect(body['error'], false);
      expect(body['message'], isNull);
      expect((body['meta'] as Map)['last_page'], 1);
    });

    test('a row whose product relation was not loaded parses fine', () {
      final row = _decode(_myReviewsJson)['data'] as List;
      final json = Map<String, dynamic>.from(row.first as Map)
        ..remove('product');
      expect(Review.fromJson(json).product, isNull);
    });

    test('a product object with nothing but an id', () {
      final r = Review.fromJson({
        'id': 1,
        'product': {'id': 118},
      });
      expect(r.product!.id, 118);
      expect(r.product!.name, '');
      expect(r.product!.image, isNull);
    });
  });

  // =========================================================================
  group('ReviewRepository.productReviews', () {
    test('sends page/per_page and parses the real capture', () async {
      final h = await _build({
        'GET $_productPath': [_ok(_productReviewsJson)],
      });
      final page = await h.repo.productReviews(_slug);

      expect(page.reviews, hasLength(2));
      expect(page.total, 2);
      expect(page.isLastPage, isTrue);
      expect(h.adapter.calls.single, contains('page=1'));
      expect(h.adapter.calls.single, contains('per_page=10'));
      expect(h.adapter.calls.single, isNot(contains('star=')));
    });

    test('star=0 is dropped — the server reads it as "no filter"', () async {
      // `$request->integer('star')` + `if ($star)`: sending 0 returns every
      // review, so a caller filtering on 0 would silently get the unfiltered
      // list back and believe it was filtered.
      final h = await _build({
        'GET $_productPath': [_ok(_emptyReviewsJson)],
      });
      await h.repo.productReviews(_slug, star: 0);
      expect(h.adapter.calls.single, isNot(contains('star=')));
    });

    test('an out-of-range star is dropped rather than sent', () async {
      final h = await _build({
        'GET $_productPath': [_ok(_emptyReviewsJson)],
      });
      await h.repo.productReviews(_slug, star: 9);
      expect(h.adapter.calls.single, isNot(contains('star=')));
    });

    test('a valid star is forwarded', () async {
      final h = await _build({
        'GET $_productPath': [_ok(_emptyReviewsJson)],
      });
      await h.repo.productReviews(_slug, star: 5);
      expect(h.adapter.calls.single, contains('star=5'));
    });

    test('per_page is never sent non-positive (the server 500s on -1)', () async {
      // api-probe/err_reviews_perpage_neg1.json -> {"message":"Server Error"}.
      for (final bad in const [0, -1]) {
        final h = await _build({
          'GET $_productPath': [_ok(_emptyReviewsJson)],
        });
        await h.repo.productReviews(_slug, perPage: bad);
        expect(h.adapter.calls.single, contains('per_page=10'));
      }
    });

    test('per_page is capped', () async {
      final h = await _build({
        'GET $_productPath': [_ok(_emptyReviewsJson)],
      });
      await h.repo.productReviews(_slug, perPage: 5000);
      expect(
        h.adapter.calls.single,
        contains('per_page=${ReviewRepository.maxPerPage}'),
      );
    });

    test('the string-typed `error` branch throws instead of reading as empty',
        () async {
      // 200 + {"error":"Unauthorized"} slips past ApiClient, whose check is
      // `error == true`. Coercing it to {} would render "no reviews yet".
      final h = await _build({
        'GET $_productPath': [_ok(_noApiKeyJson)],
      });
      final e = await _errorFrom(h.repo.productReviews(_slug));
      expect(e, isA<ApiException>());
      expect(
        (e! as ApiException).message,
        startsWith('Invalid or missing API key'),
      );
    });

    test('a body with no `data` throws instead of reading as empty', () async {
      final h = await _build({
        'GET $_productPath': [_ok(_emptyMessageJson)],
      });
      expect(await _errorFrom(h.repo.productReviews(_slug)), isA<ApiException>());
    });

    test('a non-JSON body throws instead of reading as empty', () async {
      final h = await _build({
        'GET $_productPath': [_ok('"just a string"')],
      });
      expect(await _errorFrom(h.repo.productReviews(_slug)), isA<ApiException>());
    });

    test('data arriving as an array (the empty-collection shape) throws',
        () async {
      final h = await _build({
        'GET $_productPath': [_ok('{"error":false,"data":[],"message":null}')],
      });
      expect(await _errorFrom(h.repo.productReviews(_slug)), isA<ApiException>());
    });
  });

  // =========================================================================
  group('ReviewRepository.allProductReviews', () {
    test('walks until a short page and stops', () async {
      final h = await _build({
        'GET $_productPath': [
          _ok(_pageOf(2, 3)),
          _ok(_pageOf(1, 3)),
        ],
      });
      final page = await h.repo.allProductReviews(_slug, perPage: 2);

      expect(page.reviews, hasLength(3));
      expect(page.isLastPage, isTrue);
      expect(h.adapter.calls, hasLength(2));
      expect(h.adapter.calls[1], contains('page=2'));
    });

    test('stops on the exact-multiple last page without an extra request',
        () async {
      // 4 reviews, per_page 2: page 2 is full, and only `total` reveals it is
      // the last one.
      final h = await _build({
        'GET $_productPath': [
          _ok(_pageOf(2, 4)),
          _ok(_pageOf(2, 4)),
          _ok(_pageOf(0, 4)),
        ],
      });
      final page = await h.repo.allProductReviews(_slug, perPage: 2);

      expect(page.reviews, hasLength(4));
      expect(page.isLastPage, isTrue);
      expect(h.adapter.calls, hasLength(2));
    });

    test('a truncated walk reports isLastPage false, not a confident true',
        () async {
      // Every page comes back full and the total is far beyond the cap. The old
      // code hardcoded isLastPage: true, so the caller could not tell that
      // maxPages * perPage of N reviews were all it got.
      final h = await _build({
        'GET $_productPath': [_ok(_pageOf(2, 9999))],
      });
      final page = await h.repo.allProductReviews(_slug, perPage: 2);

      expect(h.adapter.calls, hasLength(ReviewRepository.maxPages));
      expect(page.reviews, hasLength(ReviewRepository.maxPages * 2));
      expect(page.isLastPage, isFalse);
      // And the shortfall is measurable against the server's own total.
      expect(page.total, 9999);
      expect(page.reviews.length, lessThan(page.total!));
    });

    test('a zero per_page cannot spin the loop', () async {
      // `reviews.length < 0` is never true, so an unclamped 0 meant maxPages
      // requests for a single-page product.
      final h = await _build({
        'GET $_productPath': [_ok(_pageOf(2, 2))],
      });
      final page = await h.repo.allProductReviews(_slug, perPage: 0);
      expect(h.adapter.calls, hasLength(1));
      expect(page.isLastPage, isTrue);
    });

    test('keeps page 1 has_reviewed / user_review', () async {
      final h = await _build({
        'GET $_productPath': [_ok(_productReviewsJson)],
      });
      final page = await h.repo.allProductReviews(_slug);
      expect(page.hasReviewed, isFalse);
      expect(page.message, startsWith('2 review(s)'));
    });
  });

  // =========================================================================
  group('ReviewRepository.myReviews', () {
    test('parses the hybrid envelope through PaginatedResponse', () async {
      final h = await _build({
        'GET $_mine': [_ok(_myReviewsJson)],
      });
      final res = await h.repo.myReviews();

      expect(res.items, hasLength(1));
      expect(res.items.single.product!.id, 118);
      expect(res.meta.total, 2);
      expect(res.meta.lastPage, 1);
      expect(res.hasMore, isFalse);
      expect(res.links!.next, isNull);
    });

    test('a non-list `data` degrades to empty instead of a TypeError', () async {
      // PaginatedResponse.fromJson does `json['data'] as List?`.
      final h = await _build({
        'GET $_mine': [_ok('{"data":{"reviews":[]},"error":false}')],
      });
      final res = await h.repo.myReviews();
      expect(res.items, isEmpty);
      expect(res.meta.total, 0);
    });

    test('a business refusal still throws through ApiClient', () async {
      final h = await _build({
        'GET $_mine': [_ok('{"error":true,"data":null,"message":"Unauthenticated."}')],
      });
      final e = await _errorFrom(h.repo.myReviews());
      expect(e, isA<ApiException>());
      expect((e! as ApiException).message, 'Unauthenticated.');
    });
  });

  // =========================================================================
  group('ReviewRepository.create / delete', () {
    test('no attachments -> a plain JSON body', () async {
      final h = await _build({
        'POST $_mine': [
          _ok('{"error":false,"data":{"id":9,"star":5,"status":"pending"},'
              '"message":"Added review successfully!"}'),
        ],
      });
      final review = await h.repo.create(
        productId: 118,
        star: 5,
        comment: 'Good',
      );

      expect(review!.id, 9);
      expect(review.isPending, isTrue);
      final sent = h.adapter.requests.single.data;
      expect(sent, isA<Map<String, dynamic>>());
      expect((sent! as Map)['product_id'], 118);
    });

    test('an unreadable attachment surfaces as ApiException, not FileSystemException',
        () async {
      // image_picker temp files get reclaimed; MultipartFile.fromFile throws a
      // raw FileSystemException that would escape `on ApiException` handlers.
      final h = await _build({'POST $_mine': [_ok('{"error":false,"data":{}}')]});
      final e = await _errorFrom(
        h.repo.create(
          productId: 118,
          star: 5,
          comment: 'Good',
          imagePaths: const ['/definitely/not/here-9f2c1.jpg'],
        ),
      );

      expect(e, isA<ApiException>());
      // Nothing was ever sent.
      expect(h.adapter.calls, isEmpty);
    });

    test('a 422 on the eligibility rule keeps the server wording', () async {
      final h = await _build({
        'POST $_mine': [
          _Canned(
            422,
            '{"message":"You have reviewed this product already!","errors":'
            '{"product_id":["You have reviewed this product already!"]}}',
          ),
        ],
      });
      final e = await _errorFrom(
        h.repo.create(productId: 118, star: 5, comment: 'x'),
      );

      expect(e, isA<ApiException>());
      final api = e! as ApiException;
      expect(api.kind, ApiErrorKind.validation);
      expect(api.message, 'You have reviewed this product already!');
      expect(api.fieldErrors!['product_id'], isNotEmpty);
    });

    test('delete hits the id route and succeeds silently', () async {
      final h = await _build({
        'DELETE $_mine/1019': [
          _ok('{"error":false,"data":null,"message":"Deleted review '
              'successfully!"}'),
        ],
      });
      await h.repo.delete(1019);
      expect(h.adapter.calls.single, contains('/ecommerce/reviews/1019'));
    });

    test("delete of someone else's review throws either way the 403 is emitted",
        () async {
      // Botble's setError()->setCode(403) may emit HTTP 403 or HTTP 200 with
      // error:true. Both must throw; only the kind differs.
      const body = '{"error":true,"data":null,"message":"You do not have '
          'permission to delete this review."}';
      for (final canned in const [_Canned(403, body), _Canned(200, body)]) {
        final h = await _build({
          'DELETE $_mine/1016': [canned],
        });
        final e = await _errorFrom(h.repo.delete(1016));
        expect(e, isA<ApiException>());
        expect(
          (e! as ApiException).message,
          'You do not have permission to delete this review.',
        );
      }
    });
  });
}

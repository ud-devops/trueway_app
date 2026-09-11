import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/models/review.dart';
import 'package:trueway_farms/data/repositories/review_repository.dart';
import 'package:trueway_farms/presentation/widgets/app_network_image.dart';
import 'package:trueway_farms/presentation/widgets/evidence_picker.dart';

/// Pieces the review rework leans on: the standalone eligibility call, the
/// reason code on a 422, settings-driven upload limits, and an image loader
/// that understands the `data:` URIs the API sends for generated avatars.

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.body, {this.status = 200});

  final Object body;
  final int status;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<({ReviewRepository repo, _FakeAdapter adapter})> _build(
  Object body, {
  int status = 200,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(body, status: status);
  final dio = Dio()..httpClientAdapter = adapter;
  return (
    repo: ReviewRepository(ApiClient(prefs: prefs, dio: dio)),
    adapter: adapter,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reviewGate', () {
    // One call gives the gate *and* the limits, which is what lets the form be
    // built without first pulling the whole review list.
    test('returns the gate and the settings together', () async {
      final t = await _build({
        'error': false,
        'data': {
          'can_review': false,
          'reason': 'login_required',
          'message': 'Please login to write review!',
          'review_settings': {
            'max_file_number': 4,
            'max_file_size_kb': 1024,
            'accepted_image_types': ['jpg'],
            'max_video_number': 1,
            'max_video_size_kb': 5120,
            'max_video_duration': 15,
            'accepted_video_types': ['mp4'],
            'need_to_be_approved': false,
          },
        },
      });

      final gate = await t.repo.reviewGate('wheat');

      expect(gate.eligibility.isLoginRequired, isTrue);
      expect(gate.settings.maxImages, 4);
      expect(gate.settings.maxVideoSeconds, 15);
      expect(gate.settings.needsApproval, isFalse);
      expect(
        t.adapter.requests.single.path,
        '/ecommerce/products/wheat/review-eligibility',
      );
    });

    // A product page must not fail to render because a gate lookup did.
    test('a failure degrades to letting them try', () async {
      final t = await _build({'message': 'boom'}, status: 500);

      final gate = await t.repo.reviewGate('wheat');

      expect(gate.eligibility.canReview, isTrue);
      expect(gate.settings.maxImages, ReviewSettings.fallback.maxImages);
    });
  });

  // Rule failures and business blocks used to come back in two different
  // shapes. Both are 422 now; only the business one carries a `reason`, and
  // branching on the translated sentence was never safe.
  group('the reason code on a 422', () {
    test('a business block exposes its code', () async {
      final t = await _build(
        {
          'message': 'Please purchase the product for a review!',
          'reason': 'purchase_required',
          'errors': {
            'product_id': ['Please purchase the product for a review!'],
          },
        },
        status: 422,
      );

      await expectLater(
        t.repo.create(productId: 1, star: 5, comment: 'x'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.reason, 'reason', 'purchase_required')
              .having((e) => e.message, 'message', contains('purchase')),
        ),
      );
    });

    test('a validation failure carries fields and no code', () async {
      final t = await _build(
        {
          'message': 'The star must not be greater than 5. (and 1 more error)',
          'errors': {
            'star': ['The star must not be greater than 5.'],
            'comment': ['The comment field is required.'],
          },
        },
        status: 422,
      );

      await expectLater(
        t.repo.create(productId: 1, star: 9, comment: ''),
        throwsA(
          isA<ApiException>().having((e) => e.reason, 'reason', isNull).having(
                (e) => e.fieldErrors?.keys,
                'fields',
                containsAll(['star', 'comment']),
              ),
        ),
      );
    });
  });

  group('upload limits follow the store', () {
    test('are built from the settings, not constants', () {
      const settings = ReviewSettings(
        maxImages: 3,
        maxImageBytes: 1024 * 1024,
        imageExtensions: ['jpg'],
        maxVideos: 1,
        maxVideoBytes: 5120 * 1024,
        maxVideoSeconds: 15,
        videoExtensions: ['mp4'],
        needsApproval: false,
      );

      final limits = EvidenceLimits.fromReviewSettings(settings);

      expect(limits.maxImages, 3);
      expect(limits.maxVideos, 1);
      expect(limits.imageExtensions, ['jpg']);
      expect(limits.maxImageBytes, 1024 * 1024);
      expect(limits.videoNote, contains('15'));
    });
  });

  // The API inlines a generated initials avatar as `data:image/jpeg;base64,…`.
  // CachedNetworkImage hands its url to Dio, which needs a host, so a loader
  // that only understands http renders the fallback leaf on those.
  group('AppNetworkImage and data: URIs', () {
    // A 1x1 transparent GIF — small, and a real decodable image.
    const gif = 'data:image/gif;base64,'
        'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

    testWidgets('decodes one instead of trying to fetch it', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppNetworkImage(url: gif, width: 40, height: 40),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a malformed payload falls back rather than throwing',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppNetworkImage(
              url: 'data:image/jpeg;base64,not-valid-base64!!',
              width: 40,
              height: 40,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}

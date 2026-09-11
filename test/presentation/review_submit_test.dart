import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_response.dart';
import 'package:trueway_farms/data/models/review.dart';
import 'package:trueway_farms/data/repositories/review_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/review_provider.dart';
import 'package:trueway_farms/presentation/widgets/evidence_picker.dart';

/// Writing, listing and deleting reviews.
///
/// Reviews differ from returns in one structural way worth keeping straight:
/// `ReviewController` reads uploads from `$request->file()`, so media travels
/// **with** the create call as multipart. There is no upload-first step and no
/// separate media endpoint — the opposite of `POST /order-returns`.

class _FakeReviewRepo implements ReviewRepository {
  final List<String> calls = [];

  int? productId;
  int? star;
  String? comment;
  List<String> images = const [];
  List<String> videos = const [];

  List<Review> mine = const [];
  ApiException? createError;
  ApiException? deleteError;

  @override
  Future<Review?> create({
    required int productId,
    required int star,
    required String comment,
    List<String> imagePaths = const [],
    List<String> videoPaths = const [],
  }) async {
    calls.add('create($productId, $star star, ${imagePaths.length} images)');
    if (createError != null) throw createError!;
    this.productId = productId;
    this.star = star;
    this.comment = comment;
    images = imagePaths;
    videos = videoPaths;
    return Review.fromJson({'id': 9, 'star': star, 'comment': comment});
  }

  @override
  Future<void> delete(int id) async {
    calls.add('delete($id)');
    if (deleteError != null) throw deleteError!;
    mine = [...mine]..removeWhere((r) => r.id == id);
  }

  @override
  Future<PaginatedResponse<Review>> myReviews({
    int page = 1,
    int perPage = 10,
  }) async {
    calls.add('myReviews($page)');
    return PaginatedResponse<Review>(
      items: mine,
      meta: PaginationMeta(
        currentPage: page,
        lastPage: 1,
        perPage: perPage,
        total: mine.length,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'unexpected ${invocation.memberName}',
      );
}

({ProviderContainer container, _FakeReviewRepo repo}) _host({
  List<Review> mine = const [],
  bool watchMyReviews = false,
}) {
  final repo = _FakeReviewRepo()..mine = mine;
  final container = ProviderContainer(
    overrides: [reviewRepositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);

  // `myReviewsProvider` is autoDispose: a bare `read` subscribes and lets go in
  // the same turn, so the notifier is torn down before its first load lands. A
  // real screen holds a `watch` while it is mounted; this is that.
  if (watchMyReviews) {
    container.listen(myReviewsProvider, (_, __) {}, fireImmediately: true);
  }
  return (container: container, repo: repo);
}

Review _review(int id, {String status = 'published'}) => Review.fromJson({
      'id': id,
      'star': 5,
      'comment': 'Good product',
      'status': status,
    });

Future<void> _settle(ProviderContainer c) async {
  for (var i = 0; i < 50; i++) {
    if (!c.read(myReviewsProvider).loading) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('reviews never loaded');
}

void main() {
  // -------------------------------------------------------------------------
  group('submit', () {
    test('sends media with the create call, not through an upload step',
        () async {
      final h = _host();

      await h.container.read(reviewSubmitProvider.notifier).submit(
            productId: 118,
            star: 5,
            comment: 'Lovely wheat, well packed.',
            imagePaths: const ['/tmp/a.jpg'],
          );

      // One create carrying the file. A return would have been
      // upload-then-submit; there is no upload call here at all.
      expect(
        h.repo.calls.where((c) => c.startsWith('create')),
        ['create(118, 5 star, 1 images)'],
      );
      expect(h.repo.calls.any((c) => c.startsWith('upload')), isFalse);
      expect(h.repo.images, ['/tmp/a.jpg']);
    });

    test('carries the rating and comment through unchanged', () async {
      final h = _host();

      await h.container.read(reviewSubmitProvider.notifier).submit(
            productId: 118,
            star: 4,
            comment: 'Good, would buy again.',
          );

      expect(h.repo.productId, 118);
      expect(h.repo.star, 4);
      expect(h.repo.comment, 'Good, would buy again.');
    });

    test('reports failure with the server wording', () async {
      final h = _host();
      // The validator blocks HTML tags outright; the message is not guessable
      // from a status code.
      h.repo.createError = const ApiException(
        'The comment format is invalid.',
      );

      final ok = await h.container.read(reviewSubmitProvider.notifier).submit(
            productId: 118,
            star: 5,
            comment: 'I paid <10 for this> pack',
          );

      expect(ok, isFalse);
      expect(
        h.container.read(reviewSubmitProvider).error?.message,
        'The comment format is invalid.',
      );
    });

    test('a second submit is dropped while one is in flight', () async {
      final h = _host();
      final notifier = h.container.read(reviewSubmitProvider.notifier);

      await Future.wait([
        notifier.submit(productId: 118, star: 5, comment: 'One'),
        notifier.submit(productId: 118, star: 5, comment: 'Two'),
      ]);

      expect(h.repo.calls.where((c) => c.startsWith('create')), hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  group('my reviews', () {
    test('loads on creation', () async {
      final h = _host(mine: [_review(1), _review(2)], watchMyReviews: true);
      await _settle(h.container);

      expect(h.container.read(myReviewsProvider).items, hasLength(2));
    });

    // The row is removed only once the server confirms. Removing it optimistically
    // and then failing would tell the customer a review is gone while it is
    // still public on the product page.
    test('delete removes the row only after the server confirms', () async {
      final h = _host(mine: [_review(1), _review(2)], watchMyReviews: true);
      await _settle(h.container);

      final failure =
          await h.container.read(myReviewsProvider.notifier).delete(1);

      expect(failure, isNull);
      expect(
        h.container.read(myReviewsProvider).items.map((r) => r.id),
        [2],
      );
    });

    test('a refused delete keeps the row and returns the message', () async {
      final h = _host(mine: [_review(1)], watchMyReviews: true);
      await _settle(h.container);
      h.repo.deleteError = const ApiException('You cannot delete this review');

      final failure =
          await h.container.read(myReviewsProvider.notifier).delete(1);

      expect(failure, 'You cannot delete this review');
      expect(h.container.read(myReviewsProvider).items, hasLength(1));
      // And the row is no longer marked busy, so its spinner clears.
      expect(h.container.read(myReviewsProvider).deleting, isEmpty);
    });

    test('a second delete of the same row is dropped', () async {
      final h = _host(mine: [_review(1)], watchMyReviews: true);
      await _settle(h.container);
      final notifier = h.container.read(myReviewsProvider.notifier);

      await Future.wait([notifier.delete(1), notifier.delete(1)]);

      expect(h.repo.calls.where((c) => c == 'delete(1)'), hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  group('review upload limits', () {
    // Reviews and returns are validated by different rules, and quoting the
    // wrong ones sends a customer to resize a photo that was never too big.
    test('are stricter than the return ones', () {
      expect(EvidenceLimits.reviews.maxImages, 6);
      expect(EvidenceLimits.reviews.maxVideos, 2);
      expect(EvidenceLimits.reviews.maxImageBytes, 2 * 1024 * 1024);
      expect(EvidenceLimits.reviews.maxVideoBytes, 10240 * 1024);

      // Photo counts now match: returns were tightened from the server's
      // `max:10` to 6, the same allowance a review gets. The size caps are
      // still where the two differ.
      expect(
        EvidenceLimits.reviews.maxImages,
        EvidenceLimits.returns.maxImages,
      );
      expect(
        EvidenceLimits.reviews.maxVideos,
        lessThan(EvidenceLimits.returns.maxVideos),
      );
      expect(
        EvidenceLimits.reviews.maxImageBytes,
        lessThan(EvidenceLimits.returns.maxImageBytes),
      );
    });

    // `mimes:jpg,jpeg,png` on reviews vs `jpg,jpeg,png,webp` on returns.
    test('do not accept webp, unlike returns', () {
      expect(EvidenceLimits.reviews.imageExtensions, isNot(contains('webp')));
      expect(EvidenceLimits.returns.imageExtensions, contains('webp'));
    });

    // `mimes:mp4,mov` plus MaxVideoDurationRule(30).
    test('accept only mp4 and mov, and warn about the duration', () {
      expect(EvidenceLimits.reviews.videoExtensions, ['mp4', 'mov']);
      expect(EvidenceLimits.reviews.videoNote, contains('30 seconds'));
      // Returns have no duration rule, so no note to show.
      expect(EvidenceLimits.returns.videoNote, isNull);
    });

    test('render human labels for the messages', () {
      expect(EvidenceLimits.reviews.maxImageLabel, '2 MB');
      expect(EvidenceLimits.returns.maxImageLabel, '5 MB');
    });
  });
}

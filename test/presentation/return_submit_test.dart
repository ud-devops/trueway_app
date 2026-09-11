import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_response.dart';
import 'package:trueway_farms/data/models/order_return.dart';
import 'package:trueway_farms/data/repositories/order_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/return_provider.dart';

/// Submitting a return, and the two-step dance the endpoint forces.
///
/// `POST /order-returns` reads `media_images` with `$request->input()`, which
/// never contains uploaded files — anything attached there is **silently
/// discarded**, and the caller gets a success response with no media. Files
/// must go through `/order-returns/upload-media` first, and the resulting URL
/// strings are what the submit call carries.

class _FakeOrderRepo implements OrderRepository {
  final List<String> calls = [];

  /// URLs the upload endpoint answers with, in call order.
  List<List<String>> uploadResults = const [
    ['https://x/img1.jpg'],
    ['https://x/vid1.mp4'],
  ];
  int _uploadCall = 0;

  ReturnDraft? submitted;
  ReturnResubmitDraft? resubmitted;
  int? resubmittedId;

  ApiException? uploadError;
  ApiException? submitError;

  @override
  Future<List<String>> uploadReturnMedia({
    required List<String> filePaths,
    bool isVideo = false,
  }) async {
    calls.add('upload(${isVideo ? 'video' : 'image'}, ${filePaths.length})');
    if (uploadError != null) throw uploadError!;
    final result = _uploadCall < uploadResults.length
        ? uploadResults[_uploadCall]
        : const <String>[];
    _uploadCall++;
    return result;
  }

  @override
  Future<OrderReturn> submitReturn(ReturnDraft draft) async {
    calls.add('submit(order ${draft.orderId})');
    if (submitError != null) throw submitError!;
    submitted = draft;
    return OrderReturn.fromJson({'id': 17, 'order_id': draft.orderId});
  }

  @override
  Future<OrderReturn> resubmitReturn(int id, ReturnResubmitDraft draft) async {
    calls.add('resubmit($id)');
    if (submitError != null) throw submitError!;
    resubmittedId = id;
    resubmitted = draft;
    return OrderReturn.fromJson({'id': id, 'order_id': 5});
  }

  @override
  Future<PaginatedResponse<OrderReturn>> returns({
    int page = 1,
    int perPage = 10,
  }) async =>
      PaginatedResponse<OrderReturn>(
        items: const [],
        meta: const PaginationMeta(
          currentPage: 1,
          lastPage: 1,
          perPage: 10,
          total: 0,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'unexpected ${invocation.memberName}',
      );
}

({ProviderContainer container, _FakeOrderRepo repo}) _host() {
  final repo = _FakeOrderRepo();
  final container = ProviderContainer(
    overrides: [orderRepositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  return (container: container, repo: repo);
}

const _item = ReturnItemDraft(
  orderItemId: 501,
  quantity: 1,
  reason: ReturnReasons.damaged,
);

void main() {
  // -------------------------------------------------------------------------
  group('submit', () {
    test('uploads media before submitting, never with it', () async {
      final h = _host();

      await h.container.read(returnSubmitProvider.notifier).submit(
            orderId: 123,
            comment: 'x' * 60,
            items: const [_item],
            imagePaths: const ['/tmp/a.jpg'],
            videoPaths: const ['/tmp/b.mp4'],
          );

      expect(h.repo.calls, [
        'upload(image, 1)',
        'upload(video, 1)',
        'submit(order 123)',
      ]);
    });

    // The endpoint takes one `type` per call, so images and videos cannot share
    // a request.
    test('sends images and videos as separate uploads', () async {
      final h = _host();

      await h.container.read(returnSubmitProvider.notifier).submit(
            orderId: 123,
            comment: 'x' * 60,
            items: const [_item],
            imagePaths: const ['/tmp/a.jpg', '/tmp/b.jpg'],
            videoPaths: const ['/tmp/c.mp4'],
          );

      expect(h.repo.calls.where((c) => c.startsWith('upload')), [
        'upload(image, 2)',
        'upload(video, 1)',
      ]);
    });

    test('the draft carries the uploaded URLs, not the file paths', () async {
      final h = _host();

      await h.container.read(returnSubmitProvider.notifier).submit(
            orderId: 123,
            comment: 'x' * 60,
            items: const [_item],
            imagePaths: const ['/tmp/a.jpg'],
            videoPaths: const ['/tmp/b.mp4'],
          );

      expect(h.repo.submitted!.images, ['https://x/img1.jpg']);
      expect(h.repo.submitted!.videos, ['https://x/vid1.mp4']);
      expect(h.repo.submitted!.images, isNot(contains('/tmp/a.jpg')));
    });

    test('skips the upload calls entirely when nothing is attached', () async {
      final h = _host();

      await h.container.read(returnSubmitProvider.notifier).submit(
            orderId: 123,
            comment: 'x' * 60,
            items: const [_item],
          );

      expect(h.repo.calls, ['submit(order 123)']);
    });

    test('returns the new id on success', () async {
      final h = _host();

      final id = await h.container.read(returnSubmitProvider.notifier).submit(
            orderId: 123,
            comment: 'x' * 60,
            items: const [_item],
          );

      expect(id, 17);
      expect(h.container.read(returnSubmitProvider).busy, isFalse);
    });

    // A refusal arrives as HTTP 200 with `error: true` — "You cannot return
    // this order" — which ApiClient has already turned into an exception.
    test('a refusal yields null and keeps the server wording', () async {
      final h = _host();
      h.repo.submitError = const ApiException('You cannot return this order');

      final id = await h.container.read(returnSubmitProvider.notifier).submit(
            orderId: 123,
            comment: 'x' * 60,
            items: const [_item],
          );

      expect(id, isNull);
      expect(
        h.container.read(returnSubmitProvider).error?.message,
        'You cannot return this order',
      );
    });

    // Nothing is submitted when the evidence never made it — a request whose
    // photos silently vanished is worse than one the customer retries.
    test('a failed upload stops before the submit', () async {
      final h = _host();
      h.repo.uploadError = const ApiException('File too large');

      final id = await h.container.read(returnSubmitProvider.notifier).submit(
            orderId: 123,
            comment: 'x' * 60,
            items: const [_item],
            imagePaths: const ['/tmp/huge.jpg'],
          );

      expect(id, isNull);
      expect(h.repo.calls, ['upload(image, 1)']);
      expect(h.repo.submitted, isNull);
    });

    test('a second submit is dropped while one is in flight', () async {
      final h = _host();
      final notifier = h.container.read(returnSubmitProvider.notifier);

      final first = notifier.submit(
        orderId: 123,
        comment: 'x' * 60,
        items: const [_item],
      );
      final second = notifier.submit(
        orderId: 123,
        comment: 'x' * 60,
        items: const [_item],
      );
      await Future.wait([first, second]);

      expect(h.repo.calls.where((c) => c.startsWith('submit')), hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  group('resubmit', () {
    // The controller reads `return_item_id` from **inside** each object and
    // ignores the array key. Keying by index leaves it null and every per-item
    // update is silently discarded.
    test('identifies items by return_item_id inside the object', () async {
      final h = _host();

      await h.container.read(returnSubmitProvider.notifier).resubmit(
        returnId: 17,
        comment: 'y' * 60,
        items: const [
          ReturnResubmitItemDraft(
            returnItemId: 91,
            reason: ReturnReasons.damaged,
          ),
        ],
      );

      final json = h.repo.resubmitted!.toJson();
      final items = json['return_items'] as List;
      expect(items.single, containsPair('return_item_id', 91));
      // And the reason is repeated even though the server already stored one.
      expect(items.single, containsPair('reason', ReturnReasons.damaged));
    });

    test('uploads first here too', () async {
      final h = _host();

      await h.container.read(returnSubmitProvider.notifier).resubmit(
            returnId: 17,
            comment: 'y' * 60,
            imagePaths: const ['/tmp/clearer.jpg'],
          );

      expect(h.repo.calls, ['upload(image, 1)', 'resubmit(17)']);
      expect(h.repo.resubmitted!.images, ['https://x/img1.jpg']);
    });

    test('reports failure without throwing', () async {
      final h = _host();
      h.repo.submitError = const ApiException(
        'Cannot resubmit. Maximum attempts reached or status does not allow '
        'resubmission.',
      );

      final ok = await h.container
          .read(returnSubmitProvider.notifier)
          .resubmit(returnId: 17, comment: 'y' * 60);

      expect(ok, isFalse);
      expect(
        h.container.read(returnSubmitProvider).error?.message,
        startsWith('Cannot resubmit.'),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('reason labels', () {
    // `return_reasons[].label` is an empty string for every row — the enum is
    // constructed with an argument its final constructor does not accept, so
    // the value is discarded. The app supplies the wording.
    test('are the app\'s, because the server sends none', () {
      expect(returnReasonLabel(ReturnReasons.damaged), 'Damaged product');
      expect(returnReasonLabel(ReturnReasons.incorrectItem), 'Incorrect item');
      expect(returnReasonLabel(ReturnReasons.notAsDescribed),
          'Not as described',);
    });

    // An admin can add a reason the app has never heard of; it should read as
    // words rather than a raw slug.
    test('an unknown token is humanised, not shown raw', () {
      expect(returnReasonLabel('wrong_size'), 'Wrong size');
    });

    test('an empty token yields an empty label', () {
      expect(returnReasonLabel(null), '');
      expect(returnReasonLabel(''), '');
    });
  });
}

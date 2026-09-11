import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../data/models/order.dart';
import '../../data/models/order_return.dart';
import '../../data/repositories/order_repository.dart';
import 'core_providers.dart';
import 'order_provider.dart';

/// Order returns: eligibility, the customer's requests, and the two writes.
///
/// The whole feature is gated on an admin setting; when it is off **every**
/// return route answers 404, so nothing here treats a 404 as a bug.

// ===========================================================================
// Eligibility — call before showing the form
// ===========================================================================

/// Returnable items and the allowed reasons for one order.
///
/// Refusals arrive as **HTTP 200 with `error: true`** and put the explanation
/// in `data.reason` — *"Order must be in completed status to be eligible for
/// return."*, *"A return request has already been submitted for this order."*
/// `ApiClient` turns that into an [ApiException], so the screen renders the
/// error state and [returnRefusalReason] digs the sentence back out.
///
/// Gate the entry point on `Order.canBeReturned` so a customer only lands here
/// when the server has already said yes; this call is the confirmation, not the
/// gate.
final returnEligibilityProvider =
    FutureProvider.autoDispose.family<ReturnEligibility, int>((ref, orderId) {
  return ref.watch(orderRepositoryProvider).returnEligibility(orderId);
});

/// The server's own sentence explaining why a return was refused, or null.
String? returnRefusalReason(Object error) {
  if (error is! ApiException) return null;
  return OrderRepository.eligibilityHint(error);
}

// ===========================================================================
// The customer's returns
// ===========================================================================

class ReturnListState {
  const ReturnListState({
    this.items = const [],
    this.loading = true,
    this.refreshing = false,
    this.loadingMore = false,
    this.error,
    this.page = 1,
    this.hasMore = false,
  });

  final List<OrderReturn> items;
  final bool loading;
  final bool refreshing;
  final bool loadingMore;
  final ApiException? error;
  final int page;
  final bool hasMore;

  bool get isEmpty => items.isEmpty;

  ReturnListState copyWith({
    List<OrderReturn>? items,
    bool? loading,
    bool? refreshing,
    bool? loadingMore,
    ApiException? error,
    int? page,
    bool? hasMore,
    bool clearError = false,
  }) =>
      ReturnListState(
        items: items ?? this.items,
        loading: loading ?? this.loading,
        refreshing: refreshing ?? this.refreshing,
        loadingMore: loadingMore ?? this.loadingMore,
        error: clearError ? null : (error ?? this.error),
        page: page ?? this.page,
        hasMore: hasMore ?? this.hasMore,
      );
}

class ReturnsNotifier extends StateNotifier<ReturnListState> {
  ReturnsNotifier(this._repo) : super(const ReturnListState()) {
    load();
  }

  final OrderRepository _repo;

  static const int _perPage = 10;

  Future<void> load() => _read(background: false);

  /// Pull-to-refresh. A background read, so a settled list is never replaced by
  /// skeletons mid-pull.
  Future<void> refresh() => _read(background: true);

  Future<void> _read({required bool background}) async {
    if (!mounted) return;
    state = state.copyWith(
      loading: !background,
      refreshing: background,
      clearError: true,
    );
    try {
      final res = await _repo.returns(page: 1, perPage: _perPage);
      if (!mounted) return;
      state = ReturnListState(
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

  /// Next page. A failure here leaves the pages already loaded on screen —
  /// losing them because page 3 failed would be worse than the missing page.
  Future<void> loadMore() async {
    if (state.loadingMore || !state.hasMore) return;
    state = state.copyWith(loadingMore: true);
    try {
      final next = state.page + 1;
      final res = await _repo.returns(page: next, perPage: _perPage);
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
}

final returnsProvider =
    StateNotifierProvider.autoDispose<ReturnsNotifier, ReturnListState>(
  (ref) => ReturnsNotifier(ref.watch(orderRepositoryProvider)),
);

/// One return in full.
///
/// Always re-read after a submit or resubmit: the **submit response carries no
/// relations** — `items`, `latest_history` and `admin_feedback` are absent
/// keys, not nulls — so parsing it for detail yields a half-empty screen.
final returnDetailProvider =
    FutureProvider.autoDispose.family<OrderReturn, int>((ref, id) {
  return ref.watch(orderRepositoryProvider).orderReturn(id);
});

// ===========================================================================
// Writes
// ===========================================================================

/// What a submit or resubmit is doing right now, for the button.
enum ReturnSubmitPhase { idle, uploading, submitting }

class ReturnSubmitState {
  const ReturnSubmitState({this.phase = ReturnSubmitPhase.idle, this.error});

  final ReturnSubmitPhase phase;
  final ApiException? error;

  bool get busy => phase != ReturnSubmitPhase.idle;

  /// Uploads run before the submit and are the slow half — several photos over
  /// a phone connection — so the button says which stage it is in rather than
  /// spinning anonymously for both.
  String get label => switch (phase) {
        ReturnSubmitPhase.uploading => 'Uploading photos…',
        ReturnSubmitPhase.submitting => 'Submitting…',
        ReturnSubmitPhase.idle => 'Submit request',
      };
}

class ReturnSubmitNotifier extends StateNotifier<ReturnSubmitState> {
  ReturnSubmitNotifier(this._ref) : super(const ReturnSubmitState());

  final Ref _ref;

  OrderRepository get _repo => _ref.read(orderRepositoryProvider);

  /// Uploads evidence, then submits the request.
  ///
  /// The two steps are **not** optional-together: `POST /order-returns` reads
  /// `media_images` with `$request->input()`, which never contains uploaded
  /// files, so anything attached to the submit call is silently discarded. Files
  /// have to become URLs first, and those URLs are what the draft carries.
  ///
  /// Returns the new return's id, or null when the write failed — [state.error]
  /// then holds the server's wording.
  Future<int?> submit({
    required int orderId,
    required String comment,
    required List<ReturnItemDraft> items,
    List<String> imagePaths = const [],
    List<String> videoPaths = const [],
  }) async {
    if (state.busy) return null;
    state = const ReturnSubmitState(phase: ReturnSubmitPhase.uploading);

    try {
      final media = await _upload(imagePaths, videoPaths);

      state = const ReturnSubmitState(phase: ReturnSubmitPhase.submitting);
      final created = await _repo.submitReturn(
        ReturnDraft(
          orderId: orderId,
          customerComment: comment,
          items: items,
          images: media.images,
          videos: media.videos,
        ),
      );

      if (mounted) state = const ReturnSubmitState();
      _invalidate(orderId: orderId);
      return created.id;
    } on ApiException catch (e) {
      if (mounted) state = ReturnSubmitState(error: e);
      return null;
    }
  }

  /// Resubmits after the admin asked for more.
  ///
  /// Items are identified by [ReturnResubmitItemDraft.returnItemId] — the
  /// **return item's** id from the detail response, not the order-product id —
  /// and every listed item must repeat its reason even though it already has
  /// one.
  Future<bool> resubmit({
    required int returnId,
    required String comment,
    List<ReturnResubmitItemDraft> items = const [],
    List<String> imagePaths = const [],
    List<String> videoPaths = const [],
  }) async {
    if (state.busy) return false;
    state = const ReturnSubmitState(phase: ReturnSubmitPhase.uploading);

    try {
      final media = await _upload(imagePaths, videoPaths);

      state = const ReturnSubmitState(phase: ReturnSubmitPhase.submitting);
      await _repo.resubmitReturn(
        returnId,
        ReturnResubmitDraft(
          customerComment: comment,
          items: items,
          images: media.images,
          videos: media.videos,
        ),
      );

      if (mounted) state = const ReturnSubmitState();
      _ref.invalidate(returnDetailProvider(returnId));
      _ref.invalidate(returnsProvider);
      return true;
    } on ApiException catch (e) {
      if (mounted) state = ReturnSubmitState(error: e);
      return false;
    }
  }

  /// Images and videos go in **separate calls** — the endpoint takes one `type`
  /// per request — and each is capped at ten files.
  Future<({List<String> images, List<String> videos})> _upload(
    List<String> imagePaths,
    List<String> videoPaths,
  ) async {
    final images = imagePaths.isEmpty
        ? const <String>[]
        : await _repo.uploadReturnMedia(filePaths: imagePaths);
    final videos = videoPaths.isEmpty
        ? const <String>[]
        : await _repo.uploadReturnMedia(filePaths: videoPaths, isVideo: true);
    return (images: images, videos: videos);
  }

  /// A submitted return changes what the order can still do, so the order and
  /// its eligibility are re-read alongside the returns list.
  void _invalidate({required int orderId}) {
    _ref.invalidate(returnsProvider);
    _ref.invalidate(returnEligibilityProvider(orderId));
    _ref.invalidate(orderDetailProvider(orderId));
  }

  void clearError() {
    if (state.error != null) state = const ReturnSubmitState();
  }
}

final returnSubmitProvider =
    StateNotifierProvider.autoDispose<ReturnSubmitNotifier, ReturnSubmitState>(
  ReturnSubmitNotifier.new,
);

/// Display labels for the reason tokens.
///
/// `return_reasons[].label` is **an empty string for every row** — the enum is
/// built with an argument its `final` constructor does not accept, so the value
/// is discarded server-side. The wording below is the server's own, so the app
/// and the admin panel name the same thing the same way.
const Map<String, String> returnReasonLabels = {
  ReturnReasons.damaged: 'Damaged product',
  ReturnReasons.defective: 'Defective',
  ReturnReasons.incorrectItem: 'Incorrect item',
  ReturnReasons.notAsDescribed: 'Not as described',
  ReturnReasons.other: 'Other',
};

/// A reason's label, falling back to the humanised token so an admin-added
/// reason still reads as words rather than a slug.
String returnReasonLabel(String? value) {
  if (value == null || value.isEmpty) return '';
  return returnReasonLabels[value] ?? StatusValue.humanize(value);
}

/// Every return the customer has, indexed by the order it belongs to.
///
/// ## Why this exists, and why it costs one request
///
/// Nothing on the order side knows about returns. `GET /orders/{id}` carries no
/// `returns` key and no per-line returned quantity — only `can_be_returned` —
/// and `GET /orders/{id}/returns` is not a listing at all: it is the
/// *eligibility* route (`getReturnOrder`), which answers "You cannot return
/// this order".
///
/// The returns side, though, has everything: `GET /order-returns` returns each
/// request with its `order_id`, its status, **and its full `items`**, each
/// carrying `order_product_id` and `qty`. `order_product_id` is the same id the
/// order's own `products[].id` uses — verified live on order 314, whose lines
/// are 452-456 and whose return names `order_product_id: 452`.
///
/// So one call answers both screens, and no backend change is needed.
///
/// `per_page` is the maximum rather than a page: the join has to be complete or
/// a line would render as un-returned because its return was on page two. The
/// busiest account has 11 returns.
final orderReturnsByOrderProvider =
    FutureProvider.autoDispose<Map<int, List<OrderReturn>>>((ref) async {
  final page = await ref.watch(orderRepositoryProvider).returns(perPage: 100);
  final byOrder = <int, List<OrderReturn>>{};
  for (final row in page.items) {
    if (row.orderId <= 0) continue;
    byOrder.putIfAbsent(row.orderId, () => []).add(row);
  }
  return byOrder;
});

/// The returns against one order, or an empty list while they are loading or
/// unreadable.
///
/// Deliberately degrades to "none" rather than surfacing an error: a returns
/// read that failed must not put an error over an order that is otherwise fine.
/// The worst case is a line that does not yet say it was returned.
final returnsForOrderProvider =
    Provider.autoDispose.family<List<OrderReturn>, int>((ref, orderId) {
  final all = ref.watch(orderReturnsByOrderProvider).valueOrNull;
  return all?[orderId] ?? const [];
});

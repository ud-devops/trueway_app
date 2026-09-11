import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../data/models/app_notification.dart';
import '../../data/repositories/notification_repository.dart';
import 'auth_provider.dart';
import 'core_providers.dart';

final notificationRepositoryProvider = Provider<NotificationRepository>(
  (ref) => NotificationRepository(ref.watch(apiClientProvider)),
);

/// Unread count behind the bell badge on Home.
///
/// Watches [authProvider] so it re-runs on sign-in and sign-out, and returns
/// empty stats while signed out rather than firing a request that can only
/// 401 — the endpoints are all `auth:sanctum`.
final notificationStatsProvider = FutureProvider<NotificationStats>((ref) async {
  if (!ref.watch(isAuthenticatedProvider)) return const NotificationStats();
  return ref.watch(notificationRepositoryProvider).stats();
});

/// Paged notification list state.
///
/// Mirrors `ProductListState`: a real loading flag, a real error object (not a
/// string) and a server-supplied [hasMore]. [unreadCount] comes from
/// `data.unread_count` on the same response, so the badge never needs a second
/// round trip.
class NotificationListState {
  const NotificationListState({
    this.items = const [],
    this.loading = true,
    this.loadingMore = false,
    this.hasMore = false,
    this.page = 1,
    this.unreadCount = 0,
    this.busy = false,
    this.error,
  });

  final List<AppNotification> items;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final int page;
  final int unreadCount;

  /// A mark-read / mark-all-read round trip is in flight.
  final bool busy;

  /// The failure itself, not a flattened string.
  final ApiException? error;

  bool get isEmpty => !loading && error == null && items.isEmpty;

  NotificationListState copyWith({
    List<AppNotification>? items,
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    int? page,
    int? unreadCount,
    bool? busy,
    ApiException? error,
    bool clearError = false,
  }) =>
      NotificationListState(
        items: items ?? this.items,
        loading: loading ?? this.loading,
        loadingMore: loadingMore ?? this.loadingMore,
        hasMore: hasMore ?? this.hasMore,
        page: page ?? this.page,
        unreadCount: unreadCount ?? this.unreadCount,
        busy: busy ?? this.busy,
        error: clearError ? null : (error ?? this.error),
      );
}

class NotificationsNotifier extends StateNotifier<NotificationListState> {
  NotificationsNotifier(this._ref) : super(const NotificationListState()) {
    load();
  }

  final Ref _ref;
  static const _perPage = 20;

  NotificationRepository get _repo => _ref.read(notificationRepositoryProvider);

  bool get _signedIn => _ref.read(isAuthenticatedProvider);

  Future<void> load() async {
    if (!_signedIn) {
      state = const NotificationListState(loading: false);
      return;
    }
    state = const NotificationListState(loading: true);
    try {
      final res = await _repo.list(page: 1, perPage: _perPage);
      if (!mounted) return;
      state = NotificationListState(
        items: res.items,
        loading: false,
        hasMore: res.hasMore,
        page: res.currentPage,
        unreadCount: res.unreadCount,
      );
    } on ApiException catch (e) {
      // Already logged by ApiClient — just surface it.
      if (!mounted) return;
      state = NotificationListState(loading: false, error: e);
    }
  }

  Future<void> loadMore() async {
    if (state.loadingMore || state.loading || !state.hasMore) return;
    // Clearing here is what lets the inline retry re-render the spinner instead
    // of leaving the failed strip in place while the request is in flight.
    state = state.copyWith(loadingMore: true, clearError: true);
    try {
      final next = state.page + 1;
      final res = await _repo.list(page: next, perPage: _perPage);
      if (!mounted) return;
      // Append only rows we do not already hold. A server that clamps an
      // out-of-range page (or repeats page 1) would otherwise duplicate rows
      // for ever, because `has_more` stays true and every further scroll fires
      // another request. If a page adds nothing new there is nothing more to
      // page to, whatever the flag says.
      final seen = {for (final n in state.items) n.id};
      final fresh = res.items.where((n) => seen.add(n.id)).toList();
      state = state.copyWith(
        items: [...state.items, ...fresh],
        loadingMore: false,
        hasMore: fresh.isEmpty ? false : res.hasMore,
        page: res.currentPage,
        unreadCount: res.unreadCount,
        clearError: true,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      state = state.copyWith(loadingMore: false, error: e);
    }
  }

  Future<void> refresh() => load();

  /// Marks one recipient row read.
  ///
  /// The row is flipped locally on success rather than by refetching, so the
  /// list does not jump under the customer's finger while they are tapping
  /// through. Rethrows so the caller can decide whether to complain.
  Future<void> markRead(int id) async {
    final index = state.items.indexWhere((n) => n.id == id);
    if (index < 0 || state.items[index].isRead) return;

    state = state.copyWith(busy: true);
    try {
      await _repo.markRead(id);
      if (!mounted) return;
      final items = [...state.items];
      items[index] = items[index].copyWith(isRead: true);
      state = state.copyWith(
        items: items,
        busy: false,
        unreadCount: state.unreadCount > 0 ? state.unreadCount - 1 : 0,
      );
      _ref.invalidate(notificationStatsProvider);
    } on ApiException {
      if (mounted) state = state.copyWith(busy: false);
      rethrow;
    }
  }

  /// Records an open: `clicked_at` on the server, and read as a side effect.
  ///
  /// This is what a tap should call. `POST /{id}/clicked` cascades to
  /// `markAsRead()` server-side, so it costs one round trip where
  /// [markRead] + a separate click would cost two — and without it the store's
  /// `clicked` counter never leaves zero.
  ///
  /// A row that is already clicked is left alone: the server has the fact, and
  /// re-posting it would spend a request to change nothing.
  Future<void> markClicked(int id) async {
    final index = state.items.indexWhere((n) => n.id == id);
    if (index < 0 || state.items[index].isClicked) return;
    final wasUnread = !state.items[index].isRead;

    state = state.copyWith(busy: true);
    try {
      await _repo.markClicked(id);
      if (!mounted) return;
      final items = [...state.items];
      items[index] = items[index].copyWith(isRead: true, isClicked: true);
      state = state.copyWith(
        items: items,
        busy: false,
        // Only a row that was actually unread moves the badge. A re-opened
        // row is already counted as read.
        unreadCount: wasUnread && state.unreadCount > 0
            ? state.unreadCount - 1
            : state.unreadCount,
      );
      _ref.invalidate(notificationStatsProvider);
    } on ApiException {
      if (mounted) state = state.copyWith(busy: false);
      rethrow;
    }
  }

  /// Removes one recipient row, permanently.
  ///
  /// The row is dropped locally only **after** the server confirms — this API
  /// answers 404 for a row that belongs to someone else exactly as it does for
  /// one that never existed, and a list that had already removed the row would
  /// present that refusal as a success.
  ///
  /// There is no undo anywhere in this API: nothing re-creates a recipient row.
  Future<void> delete(int id) async {
    final index = state.items.indexWhere((n) => n.id == id);
    if (index < 0) return;
    final wasUnread = !state.items[index].isRead;

    state = state.copyWith(busy: true);
    try {
      await _repo.delete(id);
      if (!mounted) return;
      state = state.copyWith(
        items: [...state.items]..removeAt(index),
        busy: false,
        unreadCount: wasUnread && state.unreadCount > 0
            ? state.unreadCount - 1
            : state.unreadCount,
        // `total` shrinks too, so the home bell has to re-read.
      );
      _ref.invalidate(notificationStatsProvider);
    } on ApiException {
      if (mounted) state = state.copyWith(busy: false);
      rethrow;
    }
  }

  /// Returns the server's `marked_count`. Rethrows on failure.
  Future<int> markAllRead() async {
    state = state.copyWith(busy: true);
    try {
      final count = await _repo.markAllRead();
      if (!mounted) return count;
      if (count <= 0) {
        // The server flipped nothing — the live endpoint really does answer
        // `{"marked_count": 0}`. Painting every row read and zeroing the badge
        // off the back of a request that changed no rows would be a lie, so
        // reconcile with the server instead of asserting an outcome it did not
        // report.
        state = state.copyWith(busy: false);
        await load();
        // The home bell is fed by /stats, so it has to re-read whatever the
        // reconcile just revealed too.
        _ref.invalidate(notificationStatsProvider);
        return count;
      }
      state = state.copyWith(
        items: [for (final n in state.items) n.copyWith(isRead: true)],
        unreadCount: 0,
        busy: false,
      );
      _ref.invalidate(notificationStatsProvider);
      return count;
    } on ApiException {
      if (mounted) state = state.copyWith(busy: false);
      rethrow;
    }
  }
}

/// The notification list. Auto-disposed: the screen is not the app's home, and
/// a stale page would otherwise survive a sign-out.
final notificationsProvider = StateNotifierProvider.autoDispose<
    NotificationsNotifier, NotificationListState>((ref) {
  // Rebuilt whenever the session flips. The notifier fetches once, in its
  // constructor, and skips the fetch while signed out — so one created during
  // the signed-out render (the customer taps "Sign in" from this very screen
  // and comes back) would otherwise keep its never-fetched empty state and
  // report a full inbox as "Nothing new".
  ref.watch(isAuthenticatedProvider);
  return NotificationsNotifier(ref);
});

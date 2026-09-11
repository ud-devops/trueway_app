import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/utils/date_range.dart';
import '../../data/models/order.dart';
import '../../data/repositories/order_repository.dart';
import 'auth_provider.dart';
import 'core_providers.dart';

/// Auth status, as the orders screens read it.
///
/// A derived [Provider] rather than a direct `ref.watch(authProvider).status`
/// in the widget: [AuthNotifier] restores a session in its constructor, which
/// means any widget test that so much as builds [authProvider] drags in
/// SharedPreferences, an [ApiClient] and the real [AuthRepository]. Reading the
/// status through this one-line derivation lets a test override the *status*
/// and nothing else.
final ordersAuthStatusProvider =
    Provider<AuthStatus>((ref) => ref.watch(authProvider).status);

// ===========================================================================
// Order history — paged
// ===========================================================================

/// What the app believes the customer's order history contains.
///
/// Mirrors `ProductListState`, with one addition: [refreshing], because this
/// list is pull-to-refreshable and a refresh must not swap the rows the
/// customer is reading for skeletons.
class OrderListState {
  const OrderListState({
    this.orders = const [],
    this.loading = true,
    this.loadingMore = false,
    this.refreshing = false,
    this.hasMore = false,
    this.page = 1,
    this.total = 0,
    this.error,
    this.pagingFailed = false,
  });

  /// Newest first, as the server returns them. Never re-sorted locally.
  ///
  /// These are **list rows**: no line items, no discount, no capability flags.
  /// See [Order.hasLineItems].
  final List<Order> orders;

  /// A first read with nothing on screen behind it.
  final bool loading;

  /// The next page is in flight.
  final bool loadingMore;

  /// A re-read behind rows that are already on screen.
  final bool refreshing;

  final bool hasMore;

  /// Highest page successfully loaded.
  final int page;

  /// `meta.total` — the account's whole history, not what is loaded.
  final int total;

  /// The failure itself, not a flattened string, so [AppErrorView] can show the
  /// server's message and branch on the kind.
  final ApiException? error;

  /// True when [error] came from [OrdersNotifier.loadMore] — the *next* page
  /// failed and the rows on screen are complete as far as they go. False when
  /// it came from a refresh, where the rows are stale rather than partial.
  ///
  /// The footer needs the difference: it used to label every failure
  /// "Couldn't load more orders" and retry it with [OrdersNotifier.loadMore],
  /// so a failed pull-to-refresh was reported as a paging failure and its
  /// "Retry" appended page 2 to the very rows the customer had asked to have
  /// replaced.
  final bool pagingFailed;

  bool get isEmpty => !loading && error == null && orders.isEmpty;

  OrderListState copyWith({
    List<Order>? orders,
    bool? loading,
    bool? loadingMore,
    bool? refreshing,
    bool? hasMore,
    int? page,
    int? total,
    ApiException? error,
    bool clearError = false,
    bool pagingFailed = false,
  }) =>
      OrderListState(
        orders: orders ?? this.orders,
        loading: loading ?? this.loading,
        loadingMore: loadingMore ?? this.loadingMore,
        refreshing: refreshing ?? this.refreshing,
        hasMore: hasMore ?? this.hasMore,
        page: page ?? this.page,
        total: total ?? this.total,
        error: clearError ? null : (error ?? this.error),
        // Tied to [error]: a state with no error cannot have failed to page.
        pagingFailed: clearError ? false : pagingFailed,
      );
}

/// Pages `GET /ecommerce/orders`.
///
/// The list is built **only** from list rows. Fetching
/// [OrderRepository.order] per row to fill in line items would be 90 requests
/// on this account — the row already carries `products_count` and
/// `product_images`, which is everything a summary needs.
class OrdersNotifier extends StateNotifier<OrderListState> {
  OrdersNotifier(this._repo, {this.filter = const OrderFilter()})
      : super(const OrderListState()) {
    load();
  }

  /// Everything the customer has narrowed the list by.
  final OrderFilter filter;

  final OrderRepository _repo;

  /// One page. Ten is the controller's own default and keeps each response
  /// small; the screen pages as the customer scrolls.
  static const int _perPage = 10;

  Future<void> load() => _read(background: false);

  /// Pull-to-refresh. Always a background read — including on the empty state,
  /// which is itself pull-to-refreshable — so a settled answer is never
  /// replaced by skeletons mid-pull.
  Future<void> refresh() => _read(background: true);

  Future<void> _read({required bool background}) async {
    if (!mounted) return;
    state = state.copyWith(
      loading: !background,
      refreshing: background,
      clearError: true,
    );
    try {
      final res = await _repo.orders(
        page: 1,
        perPage: _perPage,
        status: filter.status,
        paymentStatus: filter.paymentStatus,
        dateRange: filter.date.range,
        query: filter.query,
      );
      if (!mounted) return;
      state = OrderListState(
        orders: res.items,
        loading: false,
        hasMore: res.hasMore,
        page: 1,
        total: res.meta.total,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      // Already logged by ApiClient. On a refresh the rows stay: a read that
      // timed out must not blank a list the customer is looking at.
      state = state.copyWith(
        loading: false,
        refreshing: false,
        orders: background ? state.orders : const [],
        error: e,
        // A refresh, not a page: the rows are stale, not partial.
        pagingFailed: false,
      );
    }
  }

  /// Appends the next page. Silently does nothing when there is none, or when
  /// one is already in flight — the scroll listener fires on every frame of a
  /// fling.
  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    state = state.copyWith(loadingMore: true, clearError: true);
    final next = state.page + 1;
    try {
      final res = await _repo.orders(
        page: next,
        perPage: _perPage,
        status: filter.status,
        paymentStatus: filter.paymentStatus,
        dateRange: filter.date.range,
        query: filter.query,
      );
      if (!mounted) return;
      state = state.copyWith(
        orders: [...state.orders, ...res.items],
        loadingMore: false,
        hasMore: res.hasMore,
        page: next,
        total: res.meta.total,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      // The pages already loaded are kept; the screen shows the failure under
      // them so the customer can retry the *next* page. Automatic paging stops
      // until they do — see `_onScroll` in orders_screen.dart.
      state = state.copyWith(loadingMore: false, error: e, pagingFailed: true);
    }
  }
}

/// The customer's order history.
///
/// autoDispose so signing out cannot leave one account's orders on screen for
/// the next: the notifier is rebuilt — and re-reads — the next time a screen
/// asks for it.
final ordersProvider =
    StateNotifierProvider.autoDispose<OrdersNotifier, OrderListState>(
  (ref) => OrdersNotifier(
    ref.watch(orderRepositoryProvider),
    filter: ref.watch(orderFilterProvider),
  ),
);

/// One of the buckets the filter sheet offers.
///
/// Two of these are **payment** statuses, not order statuses, and the split is
/// real rather than cosmetic: live, the 10 refunded orders are `processing` (8)
/// and `completed` (2), so "Refunded" cannot be expressed as an order status at
/// all. `?status=` and `?payment_status=` are separate parameters and both work
/// server-side — verified: `status=completed` -> 27, `payment_status=refunded`
/// -> 10, and the two combined narrow correctly.
enum OrderBucket {
  all('All orders', null, null),
  pending('Pending', OrderStatuses.pending, null),
  processing('Processing', OrderStatuses.processing, null),
  completed('Completed', OrderStatuses.completed, null),
  canceled('Cancelled', OrderStatuses.canceled, null),
  refunded('Refunded', null, 'refunded');

  const OrderBucket(this.label, this.status, this.paymentStatus);

  /// What the chip says. "Cancelled" with two Ls for the customer; the token
  /// sent to the server keeps the American spelling the column stores.
  final String label;

  /// `?status=`, or null when this bucket is not an order status.
  final String? status;

  /// `?payment_status=`, or null.
  final String? paymentStatus;
}

/// Everything the orders screen has narrowed the list by.
///
/// Held as one object rather than three providers so a rebuild happens once per
/// change: `ordersProvider` watches this, and the notifier re-reads in its
/// constructor, so three separate providers would mean up to three reads for
/// one "Apply".
/// The years the order filter offers, newest first.
///
/// Built from the customer's own first order rather than a constant, so a
/// customer who joined this year is offered one year instead of a column of
/// empty ones. [kOrdersFirstYear] is the fallback for the two cases the read
/// cannot answer: a request that failed, and a history the app has not managed
/// to reach.
///
/// An empty list is a real answer — a customer with no orders at all — and the
/// sheet hides the whole Period section for it rather than offering a year that
/// can only return nothing.
final orderFilterYearsProvider = FutureProvider<List<int>>((ref) async {
  final first = await ref.watch(orderRepositoryProvider).firstOrderYear();
  if (first == null) return const [];
  return orderFilterYears(firstYear: first);
});

class OrderFilter {
  const OrderFilter({
    this.query = '',
    this.bucket = OrderBucket.all,
    this.date = OrderDateFilter.all,
  });

  /// Free text. **Client-side** — `GET /orders` has no search parameter:
  /// `search`, `keyword`, `code` and `q` were all tried live and all four
  /// returned the full history, unfiltered and un-rejected.
  final String query;

  final OrderBucket bucket;
  final OrderDateFilter date;

  String? get status => bucket.status;
  String? get paymentStatus => bucket.paymentStatus;

  /// How many things the customer has narrowed by, for the button's badge.
  /// The query is not counted — it has its own visible box.
  int get activeCount =>
      (bucket == OrderBucket.all ? 0 : 1) + (date.isActive ? 1 : 0);

  bool get isFiltered => activeCount > 0 || query.trim().isNotEmpty;

  OrderFilter copyWith({
    String? query,
    OrderBucket? bucket,
    OrderDateFilter? date,
  }) =>
      OrderFilter(
        query: query ?? this.query,
        bucket: bucket ?? this.bucket,
        date: date ?? this.date,
      );

  /// Keeps the search box, clears the sheet. "Reset" is about the filters the
  /// sheet owns; wiping text the customer can see would be the sheet reaching
  /// outside itself.
  OrderFilter get withoutFilters => OrderFilter(query: query);

  @override
  bool operator ==(Object other) =>
      other is OrderFilter &&
      other.query == query &&
      other.bucket == bucket &&
      other.date == date;

  @override
  int get hashCode => Object.hash(query, bucket, date);
}

/// Which span of the history the orders screen is showing.
///
/// Deliberately **not** autoDispose, unlike [ordersProvider]: the customer's
/// choice should survive opening an order and coming back, and autoDispose
/// would drop it on that ordinary navigation.
///
/// Watched by [ordersProvider], so setting it rebuilds the notifier and the
/// notifier re-reads in its constructor. There is no "apply" step and no way
/// for the chips and the list to disagree.
///
/// Signing out resets it here rather than from [AuthNotifier]: orders already
/// depend on auth, and reaching the other way would be a cycle. One account's
/// "This month" must not greet the next one.
final orderFilterProvider = StateProvider<OrderFilter>((ref) {
  ref.listen<AuthStatus>(ordersAuthStatusProvider, (_, next) {
    if (next != AuthStatus.authenticated) {
      ref.controller.state = const OrderFilter();
    }
  });
  return const OrderFilter();
});

// ===========================================================================
// Order detail
// ===========================================================================

/// Full order by id — line items, addresses, the discount and the four
/// capability flags, none of which exist on a list row.
///
/// Keyed by id and autoDispose: opening an order should re-read it (its status
/// may have moved on since the list was fetched), and closing it should not
/// pin 90 orders in memory.
final orderDetailProvider =
    FutureProvider.autoDispose.family<Order, int>((ref, id) async {
  // keepAlive is deliberately NOT set: after a cancel the screen invalidates
  // this and wants a genuine re-read.
  return ref.watch(orderRepositoryProvider).order(id);
});

/// A customer-visible cancellation reason.
///
/// The allowed set lives in `ec_order_reasons` and there is no endpoint that
/// exposes it, so the app ships the shop's current list. A token the server has
/// since retired comes back as a 422 naming `cancellation_reason`, which the
/// screen surfaces verbatim rather than swallowing.
typedef CancellationReason = ({String value, String label});

/// The shop's customer-visible tokens, in the order the website offers them.
///
/// ## Four tokens were removed from this list, and why
///
/// `2026_07_11_000000_remove_unused_cancellation_reasons` **deletes** five rows
/// from `ec_order_reasons` — `out-of-stock`, `payment-issues`,
/// `not-as-described`, `customer-requested`, `unforeseen-circumstances`. Their
/// enum constants survive so historical orders still render a label, which is
/// why they look valid in the source; they are not. `CancelOrderRequest`
/// validates against the **table**, so four of the options this list used to
/// offer failed with a 422 the moment the customer picked them.
///
/// ## Why `technical-issues` is not here either
///
/// The seed migration (`2026_07_10…rebuild_ec_order_reasons_table`) creates
/// **six** customer-selectable rows, including `technical-issues`. The backend
/// team's integration guide reports **five** verified live on this install —
/// the table is admin-editable at runtime, so a row can be retired without a
/// migration. The two disagree, and only one of the two answers is safe:
/// offering a retired token is a dead option that always 422s, while omitting a
/// live one merely sends that customer to "Another reason". So this ships the
/// verified five. If the backend confirms `technical-issues` is active, add it
/// back — [followUps].
const List<CancellationReason> orderCancellationReasons = [
  (value: 'change-mind', label: 'I changed my mind'),
  (value: 'found-better-price', label: 'I found a better price elsewhere'),
  (value: 'shipping-delays', label: 'Shipping is taking too long'),
  (value: 'incorrect-address', label: 'I entered the wrong address'),
  (value: 'other', label: 'Another reason'),
];

/// The one reason token that requires a written description (min 3 chars).
const String otherCancellationReason = 'other';

/// Writes against a single order: cancel and confirm-delivery.
///
/// State is just "is a write in flight", which is what the buttons need. The
/// result of the write is delivered by rethrowing — the screen owns the
/// snackbar and the server's sentence is the whole message.
class OrderActionsNotifier extends StateNotifier<bool> {
  OrderActionsNotifier(this._ref, this.orderId) : super(false);

  final Ref _ref;
  final int orderId;

  /// Cancels the order, then re-reads it and the history list.
  ///
  /// Returns false when a write was already in flight and nothing was sent —
  /// the caller must not report a cancellation it never asked for. Rethrows the
  /// [ApiException] on refusal ("You cannot cancel this order"), which the
  /// server answers with HTTP 200 + `error: true`.
  Future<bool> cancel({required String reason, String? description}) async {
    if (state) return false;
    state = true;
    try {
      await _ref.read(orderRepositoryProvider).cancelOrder(
            orderId,
            reason: reason,
            description: description,
          );
      _invalidate();
      return true;
    } finally {
      if (mounted) state = false;
    }
  }

  /// Marks a delivered order as received.
  ///
  /// Same contract as [cancel]: false means nothing was sent.
  Future<bool> confirmDelivery() async {
    if (state) return false;
    state = true;
    try {
      await _ref.read(orderRepositoryProvider).confirmDelivery(orderId);
      _invalidate();
      return true;
    } finally {
      if (mounted) state = false;
    }
  }

  /// Both writes change the order's status, and the list row renders that
  /// status — so the list is re-read too, or the customer goes back to a row
  /// that still says "Processing" for an order they just cancelled.
  void _invalidate() {
    _ref.invalidate(orderDetailProvider(orderId));
    _ref.invalidate(ordersProvider);
  }
}

final orderActionsProvider =
    StateNotifierProvider.autoDispose.family<OrderActionsNotifier, bool, int>(
  (ref, id) => OrderActionsNotifier(ref, id),
);


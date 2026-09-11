import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../data/models/order.dart';
import '../../../data/models/order_return.dart';
import '../../providers/auth_provider.dart';
import '../../providers/order_provider.dart';
import '../../providers/return_provider.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/order_filter_sheet.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/state_views.dart';
import '../../widgets/surfaces.dart';
import 'order_detail_screen.dart';

/// Orders tab — the customer's order history.
///
/// Every row here comes from `GET /ecommerce/orders`, which returns a *summary*
/// shape: a code, a status, a total, a product count and up to a handful of
/// thumbnails. It carries no line items and no discount, so this screen never
/// asks for them — opening an order is what fetches the detail. Doing it per
/// row would be 90 requests on the test account.
class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key, this.showBack = false});

  final bool showBack;

  static const _icon = Icons.receipt_long_rounded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(ordersAuthStatusProvider);

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        automaticallyImplyLeading: showBack,
        title: const Text('My Orders'),
      ),
      body: switch (status) {
        // Startup: a persisted session may still be restored. Showing the
        // signed-out state here would flash "Sign in" on every cold start.
        AuthStatus.unknown => const _OrderListSkeleton(),
        AuthStatus.authenticated => const Column(
            children: [
              // Outside the list rather than a header inside it: when the span
              // matches nothing, the list is replaced by an empty state, and a
              // filter bar that went with it would leave no way back.
              _OrderSearchBar(),
              Expanded(child: _OrderHistory()),
            ],
          ),
        _ => EmptyView(
            icon: _icon,
            title: 'Sign in to see your orders',
            subtitle: 'Verify your mobile number to track orders\n'
                'and view your history.',
            action: SizedBox(
              width: 220,
              child: ElevatedButton(
                onPressed: () => context.push('/login'),
                child: const Text('Sign in'),
              ),
            ),
          ),
      },
    );
  }
}

/// Search the history, and narrow it.
///
/// ## What this replaced
///
/// A row of six date chips that scrolled sideways, took a permanent line of the
/// screen, and could only ever express dates. Status has six buckets of its
/// own, so the honest version of that row was twelve chips — which is a control
/// strip taller than the first order card.
///
/// A box and a button instead: the box is what customers reach for (they are
/// looking for *one* order, usually by its code), and the button holds as many
/// filters as the shop ever grows, saying how many are on.
///
/// ## The two halves are filtered in different places
///
/// **Status** is the server's — `?status=` and `?payment_status=` both work
/// (`status=completed` -> 27, `payment_status=refunded` -> 10).
///
/// **Search and dates** are not. `GET /orders` accepts neither: `search`,
/// `keyword`, `code`, `q`, and seven date-parameter spellings were all tried
/// live and every one returned the account's whole history, unfiltered and
/// un-rejected. So those two make the repository read everything and filter it
/// — affordable at 94 rows, and the argument for
/// `docs/BACKEND_PATCH_order_date_filter.md`.
class _OrderSearchBar extends ConsumerStatefulWidget {
  const _OrderSearchBar();

  @override
  ConsumerState<_OrderSearchBar> createState() => _OrderSearchBarState();
}

class _OrderSearchBarState extends ConsumerState<_OrderSearchBar> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(orderFilterProvider).query;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _setQuery(String value) {
    final filter = ref.read(orderFilterProvider);
    if (value.trim() == filter.query.trim()) return;
    ref.read(orderFilterProvider.notifier).state =
        filter.copyWith(query: value.trim());
  }

  Future<void> _openFilters() async {
    final current = ref.read(orderFilterProvider);
    final next = await showOrderFilterSheet(context, current: current);
    if (next == null || !mounted) return;
    ref.read(orderFilterProvider.notifier).state = next;
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(orderFilterProvider);
    final state = ref.watch(ordersProvider);

    // A customer who has never ordered is not helped by a search box over an
    // empty state. Once anything is narrowed the bar always stays — it is the
    // only way back out of a filter that matched nothing.
    final nothingToFilter = !filter.isFiltered &&
        state.orders.isEmpty &&
        !state.loading &&
        state.error == null;
    if (nothingToFilter) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('order-search-field'),
                  controller: _search,
                  onChanged: _setQuery,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search by order number',
                    prefixIcon:
                        Icon(Icons.search_rounded, color: context.colors.muted),
                    suffixIcon: filter.query.isEmpty
                        ? null
                        : IconButton(
                            key: const Key('order-search-clear'),
                            icon: const Icon(Icons.close_rounded),
                            tooltip: 'Clear search',
                            onPressed: () {
                              _search.clear();
                              _setQuery('');
                            },
                          ),
                  ),
                ),
              ),
              AppSpacing.hXs,
              _FilterButton(
                count: filter.activeCount,
                onTap: _openFilters,
              ),
            ],
          ),
          if (filter.isFiltered) ...[
            const SizedBox(height: 6),
            Text(
              // Says what is on screen, not what the account holds. The
              // repository returns a `total` for exactly what it matched.
              state.loading
                  ? 'Filtering…'
                  : '${state.total} order${state.total == 1 ? '' : 's'}'
                      '${filter.bucket == OrderBucket.all ? '' : ' · ${filter.bucket.label}'}'
                      '${filter.date.isActive ? ' · ${filter.date.label}' : ''}',
              key: const Key('order-filter-summary'),
              style: context.text.caption,
            ),
          ],
        ],
      ),
    );
  }
}

/// The filter button, wearing how many filters are on.
///
/// The badge is the whole point: a funnel icon alone cannot say whether the
/// list in front of the customer is the whole history or a slice of it, and a
/// short list with a silent filter reads as lost orders.
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final on = count > 0;

    return Material(
      color: on ? context.colors.primarySoft : context.colors.surface,
      borderRadius: AppRadius.rMd,
      child: InkWell(
        key: const Key('order-filter-button'),
        onTap: onTap,
        borderRadius: AppRadius.rMd,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: AppRadius.rMd,
            border: Border.all(
              color: on ? AppColors.primary : context.colors.line,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.tune_rounded,
                size: 20,
                color: on ? context.colors.primaryDark : context.colors.muted,
              ),
              if (on) ...[
                const SizedBox(width: 6),
                Text(
                  '$count',
                  key: const Key('order-filter-count'),
                  style: context.text.bodySm
                      .copyWith(color: context.colors.primaryDark),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Pushes the detail screen for one order.
void openOrderDetail(BuildContext context, int orderId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OrderDetailScreen(orderId: orderId),
      ),
    );

class _OrderHistory extends ConsumerStatefulWidget {
  const _OrderHistory();

  @override
  ConsumerState<_OrderHistory> createState() => _OrderHistoryState();
}

class _OrderHistoryState extends ConsumerState<_OrderHistory> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// Fires on every frame of a fling; the notifier drops the repeats.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    // A read that already failed stops the automatic paging. Without this the
    // listener re-fires the request that just failed on every frame of a bounce
    // at the bottom of the list — a dead endpoint gets hammered, and the error
    // strip flickers away and back as each attempt clears and re-sets it. The
    // strip's own Retry is the way out.
    if (ref.read(ordersProvider).error != null) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 320) {
      ref.read(ordersProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ordersProvider);
    final notifier = ref.read(ordersProvider.notifier);

    if (state.loading && state.orders.isEmpty) {
      return const _OrderListSkeleton();
    }

    if (state.error != null && state.orders.isEmpty) {
      return AppErrorView(error: state.error, onRetry: notifier.load);
    }

    if (state.orders.isEmpty) {
      // "No orders yet" over an active filter would be a false statement about
      // the account — the customer may have eighty orders, none of them
      // cancelled, or none in August. The way out is offered right here rather
      // than left to the bar above, which the empty state has pushed off the
      // top of a short screen.
      final filter = ref.watch(orderFilterProvider);
      final filtered = filter.isFiltered;

      return RefreshIndicator(
        onRefresh: notifier.refresh,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: EmptyView(
                icon: OrdersScreen._icon,
                title: filtered ? 'No orders match' : 'No orders yet',
                subtitle: filtered
                    ? 'Nothing here fits what you searched for.\n'
                        'Try a wider filter.'
                    : 'Anything you order will show up here,\n'
                        'with its status and a way to track it.',
                action: SizedBox(
                  width: 220,
                  child: filtered
                      ? OutlinedButton(
                          key: const Key('order-filter-clear'),
                          // Clears the search box too, unlike the sheet's
                          // Reset: this button says "show all orders", so it
                          // has to actually show all of them.
                          onPressed: () => ref
                              .read(orderFilterProvider.notifier)
                              .state = const OrderFilter(),
                          child: const Text('Show all orders'),
                        )
                      : ElevatedButton(
                          onPressed: () => context.push('/products'),
                          child: const Text('Start shopping'),
                        ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: notifier.refresh,
      child: ListView.separated(
        // Keyed because the filter bar above is a ListView too, and a bare
        // `find.byType(ListView)` in a test is then ambiguous — it would drag
        // whichever one it found first.
        key: const Key('orders-list'),
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        // +1 for the footer: the page-load spinner, the "that's everything"
        // line, or the failure of the *next* page.
        itemCount: state.orders.length + 1,
        separatorBuilder: (_, __) => AppSpacing.vSm,
        itemBuilder: (_, i) {
          if (i == state.orders.length) return _footer(state, notifier);
          final order = state.orders[i];
          return OrderSummaryCard(
            key: ValueKey('order-${order.id}'),
            order: order,
            onTap: () => openOrderDetail(context, order.id),
          );
        },
      ),
    );
  }

  Widget _footer(OrderListState state, OrdersNotifier notifier) {
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(
          child: SizedBox(
            height: 22,
            width: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          ),
        ),
      );
    }
    // A read that failed is admitted rather than looking like the end of the
    // history: without this the list simply stops, and 80 orders are invisible
    // with no explanation. Which read failed decides both the wording and the
    // retry — offering "load more" after a failed pull-to-refresh would append
    // page 2 to the stale rows the customer asked to have replaced.
    if (state.error != null) {
      return state.pagingFailed
          ? InlineErrorStrip(
              error: state.error,
              label: 'more orders',
              onRetry: notifier.loadMore,
            )
          : InlineErrorStrip(
              error: state.error,
              label: 'the latest orders',
              onRetry: notifier.refresh,
            );
    }
    if (state.hasMore) return const SizedBox(height: AppSpacing.xl);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Center(
        child: Text(
          state.total > 0
              ? 'All ${state.total} orders shown'
              : 'That is everything',
          style: context.text.caption,
        ),
      ),
    );
  }
}

/// One row of the history.
///
/// Built entirely from the list shape — see [Order.hasLineItems]. The
/// thumbnails come from `product_images`, which is empty on the rows whose
/// products were hard-deleted, so the strip degrades to a count.
class OrderSummaryCard extends ConsumerWidget {
  const OrderSummaryCard({super.key, required this.order, this.onTap});

  final Order order;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final images = order.productImages.take(4).toList();
    // Nothing on the order side knows about returns — `GET /orders/{id}` has
    // no `returns` key and no per-line returned quantity. The returns list
    // does: every row carries its `order_id`. One request, indexed once, read
    // by every card. See [orderReturnsByOrderProvider].
    // A copy, never `..removeWhere` on the watched list: that list is the one
    // held inside `orderReturnsByOrderProvider`'s map, so mutating it here
    // would delete rows out from under every other card reading the same
    // cache — and out from under the order detail screen.
    final returns = [
      for (final request in ref.watch(returnsForOrderProvider(order.id)))
        if (request.countsAgainstOrder) request,
    ];

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.sm),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // displayCode, never '#$code': 25 of the 90 orders on this
                    // account already store the '#', so prefixing one here
                    // renders "##SF-10000016".
                    Text(
                      order.displayCode,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.title,
                    ),
                    if (order.createdAt != null) ...[
                      const SizedBox(height: 2),
                      Text(formatOrderDate(order.createdAt!),
                          style: context.text.caption,),
                    ],
                  ],
                ),
              ),
              AppSpacing.hXs,
              OrderStatusChip(status: order.status),
            ],
          ),
          AppSpacing.vXs,
          Row(
            children: [
              if (images.isNotEmpty) ...[
                _Thumbnails(urls: images),
                AppSpacing.hSm,
              ],
              Expanded(
                child: Text(
                  _itemCount(order.productsCount),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySm,
                ),
              ),
              AppSpacing.hXs,
              Text(order.amountDisplay, style: context.text.price),
            ],
          ),
          // A return against this order. Worth a line of its own: the status
          // chip says "Completed", which is true of the order and says nothing
          // about the two jars that went back.
          if (returns.isNotEmpty) ...[
            AppSpacing.vXs,
            Row(
              key: const Key('order-return-state'),
              children: [
                Icon(
                  Icons.keyboard_return_rounded,
                  size: 16,
                  color: context.colors.primaryDark,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    _returnSummary(returns),
                    style: context.text.caption
                        .copyWith(color: context.colors.primaryDark),
                  ),
                ),
              ],
            ),
          ],
          // Where the money is, when it is moving. The status chip above says
          // "Canceled" or "Processing" — neither answers "so where is my
          // ₹811?", which is the question that brings a customer back to this
          // list. Live, the two are independent: the 10 refunded orders are
          // `processing` (8) and `completed` (2), not cancelled.
          if (order.isRefunded || order.isRefundInProgress) ...[
            AppSpacing.vXs,
            Row(
              key: const Key('order-refund-state'),
              children: [
                Icon(
                  order.isRefunded
                      ? Icons.check_circle_outline_rounded
                      : Icons.schedule_rounded,
                  size: 16,
                  color: order.isRefunded
                      ? context.colors.savings
                      : AppColors.accentDark,
                ),
                const SizedBox(width: 4),
                // Flexible, not bare: at 320dp with the largest OS text scale
                // "Refund in process" is wider than the card, and a Row lets a
                // rigid child overflow rather than wrap it.
                Flexible(
                  child: Text(
                    order.isRefunded ? 'Refunded' : 'Refund in process',
                    style: context.text.caption.copyWith(
                      color: order.isRefunded
                          ? context.colors.savings
                          : AppColors.accentDark,
                    ),
                  ),
                ),
              ],
            ),
          ],
          // Only shown when the server actually has something to say: 7 of 90
          // orders send {value: null, label: ""} here, and rendering that gives
          // an empty chip or the string "null".
          if (order.shippingStatus.isNotEmpty &&
              order.shippingStatus.display.isNotEmpty) ...[
            AppSpacing.vXs,
            Row(
              children: [
                Icon(Icons.local_shipping_rounded,
                    size: 15, color: context.colors.muted,),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    order.shippingStatus.display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.caption,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// "2 items returned · Completed", in the newest request's words.
  ///
  /// Counted across every request against the order, because a customer can
  /// send two things back a week apart and both are still "returned".
  static String _returnSummary(List<OrderReturn> returns) {
    var units = 0;
    for (final request in returns) {
      for (final item in request.items) {
        units += item.quantity;
      }
    }
    final label = returns.first.stageLabel;
    final noun = units == 1 ? 'item' : 'items';
    return units == 0
        ? 'Return $label'.trim()
        : '$units $noun returned${label.isEmpty ? '' : ' · $label'}';
  }

  static String _itemCount(int count) =>
      count == 1 ? '1 item' : '$count items';
}

class _Thumbnails extends StatelessWidget {
  const _Thumbnails({required this.urls});

  final List<String> urls;

  static const double _size = 40;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final url in urls)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Container(
                width: _size,
                height: _size,
                decoration: BoxDecoration(
                  color: context.colors.surfaceAlt,
                  borderRadius: AppRadius.rSm,
                  border: Border.all(color: context.colors.hairline),
                ),
                clipBehavior: Clip.antiAlias,
                child: AppNetworkImage(url: url, fit: BoxFit.cover),
              ),
            ),
        ],
      );
}

/// A `{value, label}` status rendered as a scannable pill.
///
/// The **label** is what a customer reads — it is the server's own wording, and
/// the only thing that survives a status the app has never heard of. The
/// **value** picks the colour, so the list can be scanned without reading it.
///
/// Note `canceled` — one L, which is how this backend spells it.
class OrderStatusChip extends StatelessWidget {
  const OrderStatusChip({super.key, required this.status, this.dense = false});

  final StatusValue status;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (status.isEmpty || status.display.isEmpty) return const SizedBox.shrink();
    final color = colorFor(context, status.value);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: _tint),
        borderRadius: AppRadius.rPill,
        border: Border.all(color: color.withValues(alpha: 0.38)),
      ),
      child: Text(
        status.display,
        style: context.text.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// "Completed" is the one green here, and green *is* theme-dependent — the
  /// light value only reaches ~3.6:1 on a dark surface — so it starts from the
  /// palette, which already carries a lifted dark variant.
  ///
  /// The rest are brand-invariant [AppColors] constants, but "invariant" is not
  /// the same as "legible". They are picked to sit on a white card, and as chip
  /// *text* they miss AA at both ends: amber reaches only ~2.8:1 in light, and
  /// blue ~3.1:1 on the dark surface. Everything goes through [_legible].
  static Color colorFor(BuildContext context, String? value) => _legible(
        context,
        switch (value) {
          OrderStatuses.completed => context.colors.savings,
          OrderStatuses.processing => AppColors.info,
          OrderStatuses.canceled => AppColors.error,
          OrderStatuses.pending => AppColors.accentDark,
          _ => AppColors.teal,
        },
      );

  /// Opacity of the chip's fill — the label's real background.
  static const double _tint = 0.12;

  /// Steps [base] toward the current theme's text end until the label clears
  /// 4.5:1 against the tinted chip it sits on.
  ///
  /// Computed rather than hand-picked so a colour cannot silently fail in one
  /// theme, which is exactly how the amber "Pending" chip shipped: the same
  /// constant is legible on the dark card and 2.8:1 on the light one. A colour
  /// that already passes is returned untouched, so the brand values are what
  /// render wherever they can be.
  static Color _legible(BuildContext context, Color base) {
    final surface = context.colors.surface;
    final toward = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    var color = base;
    for (var step = 1; step <= 12; step++) {
      if (_contrast(color, Color.alphaBlend(color.withValues(alpha: _tint), surface)) >=
          4.5) {
        return color;
      }
      color = Color.lerp(base, toward, step * 0.08)!;
    }
    return color;
  }

  /// WCAG relative-contrast ratio, order-independent.
  static double _contrast(Color a, Color b) {
    final x = a.computeLuminance();
    final y = b.computeLuminance();
    return x > y ? (x + 0.05) / (y + 0.05) : (y + 0.05) / (x + 0.05);
  }
}

/// Order timestamps, in the reader's own zone. Shared by all three order
/// screens so a date reads the same everywhere.
///
/// `.toLocal()` is load-bearing. Every order timestamp carries a zone —
/// `"2026-07-16T17:04:00+05:30"` on the order routes, `"…T11:34:00.000000Z"`
/// on the tracking dump — and [DateTime.parse] returns a **UTC** DateTime for
/// both. [DateFormat] then prints that DateTime's own fields, so formatting it
/// straight showed an order placed at 5:04 PM as "11:34 AM", and anything
/// placed before 05:30 IST on the wrong calendar day. The returns routes send a
/// zoneless string, which parses as local already and is unaffected.
String formatOrderDate(DateTime when, {bool withTime = false}) =>
    DateFormat(withTime ? 'd MMM yyyy, h:mm a' : 'd MMM yyyy')
        .format(when.toLocal());

/// Placeholder rows for the first read, shaped like the cards they replace.
class _OrderListSkeleton extends StatelessWidget {
  const _OrderListSkeleton();

  @override
  Widget build(BuildContext context) => ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.md),
        itemCount: 4,
        separatorBuilder: (_, __) => AppSpacing.vSm,
        itemBuilder: (_, __) => const AppCard(
          padding: EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SkeletonBox(height: 14, width: 120, radius: AppRadius.sm),
                  Spacer(),
                  SkeletonBox(height: 20, width: 82, radius: AppRadius.pill),
                ],
              ),
              AppSpacing.vXs,
              SkeletonBox(height: 10, width: 90, radius: AppRadius.sm),
              AppSpacing.vSm,
              Row(
                children: [
                  SkeletonBox(height: 40, width: 40, radius: AppRadius.sm),
                  AppSpacing.hXs,
                  SkeletonBox(height: 40, width: 40, radius: AppRadius.sm),
                  Spacer(),
                  SkeletonBox(height: 14, width: 70, radius: AppRadius.sm),
                ],
              ),
            ],
          ),
        ),
      );
}

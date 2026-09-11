import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../core/utils/date_range.dart';
import '../providers/order_provider.dart';

/// Narrowing the order history: what state, and when.
///
/// ## Why one sheet instead of the chip row it replaced
///
/// The row of date chips took a whole line of the screen permanently, offered
/// only dates, and could not grow: status has six buckets and dates have six of
/// their own, which is twelve chips scrolling sideways above every list. A
/// button that says how many filters are on costs one icon and holds as many
/// as the shop ever needs.
///
/// ## Status and payment status are not the same axis
///
/// "Refunded" is a **payment** status. Live, the 10 refunded orders are
/// `processing` (8) and `completed` (2) — so it cannot be expressed as an order
/// status, and [OrderBucket] carries whichever parameter each bucket needs.
/// Both are real server-side filters (`status=completed` -> 27,
/// `payment_status=refunded` -> 10), so this half of the sheet costs one
/// request, not a local pass.
///
/// Dates are the opposite: `GET /orders` has no date parameter at all, so a
/// span makes the repository read the whole history and filter it. See
/// `docs/BACKEND_PATCH_order_date_filter.md`.
Future<OrderFilter?> showOrderFilterSheet(
  BuildContext context, {
  required OrderFilter current,
}) =>
    showModalBottomSheet<OrderFilter>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _OrderFilterSheet(current: current),
    );

class _OrderFilterSheet extends ConsumerStatefulWidget {
  const _OrderFilterSheet({required this.current});

  final OrderFilter current;

  @override
  ConsumerState<_OrderFilterSheet> createState() => _OrderFilterSheetState();
}

class _OrderFilterSheetState extends ConsumerState<_OrderFilterSheet> {
  late OrderFilter _draft = widget.current;

  /// Edited here and applied on Apply, not live.
  ///
  /// Each change to the real filter rebuilds the notifier and re-reads the
  /// history — and a date span reads *all* of it — so a live sheet would fire
  /// a full read per tap while the customer is still deciding.
  void _set(OrderFilter next) => setState(() => _draft = next);

  /// The Period section, once the customer's first order year is known.
  ///
  /// Absent while the years are loading and absent if there are none: a section
  /// that appears a beat late is better than one that offers the wrong years
  /// and corrects itself under the customer's finger.
  List<Widget> _period(BuildContext context) {
    final years = ref.watch(orderFilterYearsProvider).valueOrNull ??
        orderFilterYears(firstYear: kOrdersFirstYear);
    if (years.isEmpty) return const [];

    return [
      AppSpacing.vMd,
      Text('Period', style: context.text.title),
      AppSpacing.vXs,
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _chip(
            key: const Key('order-period-all'),
            label: OrderDateFilter.all.label,
            selected: !_draft.date.isActive,
            onTap: () => _set(_draft.copyWith(date: OrderDateFilter.all)),
          ),
          for (final year in years)
            _chip(
              key: Key('order-period-$year'),
              label: '$year',
              selected: _draft.date.year == year,
              onTap: () =>
                  _set(_draft.copyWith(date: OrderDateFilter.year(year))),
            ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Filter orders', style: context.text.h3)),
              TextButton(
                key: const Key('order-filter-reset'),
                // Only the sheet's own filters. Wiping the search box — which
                // the customer can see and did not open this sheet to change —
                // would be the sheet reaching outside itself.
                onPressed: _draft.activeCount == 0
                    ? null
                    : () => _set(_draft.withoutFilters),
                child: const Text('Reset'),
              ),
            ],
          ),
          AppSpacing.vSm,

          Text('Status', style: context.text.title),
          AppSpacing.vXs,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final bucket in OrderBucket.values)
                _chip(
                  key: Key('order-bucket-${bucket.name}'),
                  label: bucket.label,
                  selected: _draft.bucket == bucket,
                  onTap: () => _set(_draft.copyWith(bucket: bucket)),
                ),
            ],
          ),

          // Years, and nothing else.
          //
          // This offered "This month", "Last month", "This year", "Last year"
          // and a two-calendar custom range — five ways of asking a question
          // customers ask one way: "the order I placed some time in 2025". The
          // custom picker cost two calendars and four taps to express a span
          // the list cannot search inside anyway.
          //
          // Every year here is one the customer actually ordered in, because
          // the list is built from their first order — so no chip can come back
          // empty. A customer with no orders gets no section at all rather than
          // a year that can only disappoint.
          ..._period(context),

          AppSpacing.vLg,
          ElevatedButton(
            key: const Key('order-filter-apply'),
            onPressed: () => Navigator.pop(context, _draft),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  Widget _chip({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) =>
      ChoiceChip(
        key: key,
        selected: selected,
        // Tapping the selected chip re-opens the picker for the custom span and
        // is a no-op for the rest — "no selection at all" is not a state either
        // row can render, because All and All orders are what that means.
        onSelected: (_) => onTap(),
        avatar: icon == null
            ? null
            : Icon(
                icon,
                size: 16,
                color:
                    selected ? context.colors.primaryDark : context.colors.muted,
              ),
        label: Text(label),
        labelStyle: context.text.bodySm.copyWith(
          color: selected ? context.colors.primaryDark : context.colors.body,
        ),
        selectedColor: context.colors.primarySoft,
        backgroundColor: context.colors.surface,
        side: BorderSide(
          color: selected ? AppColors.primary : context.colors.line,
        ),
        showCheckmark: false,
      );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../data/models/order.dart';
import '../../../data/models/order_return.dart';
import '../../providers/return_provider.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/state_views.dart';
import '../../widgets/surfaces.dart';

/// The customer's return requests.
class ReturnsScreen extends ConsumerStatefulWidget {
  const ReturnsScreen({super.key});

  @override
  ConsumerState<ReturnsScreen> createState() => _ReturnsScreenState();
}

class _ReturnsScreenState extends ConsumerState<ReturnsScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 400) ref.read(returnsProvider.notifier).loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(returnsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('My returns')),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: () => ref.read(returnsProvider.notifier).refresh(),
        child: _body(context, state),
      ),
    );
  }

  Widget _body(BuildContext context, ReturnListState state) {
    if (state.loading) return const _ReturnListSkeleton();

    // An error with rows already on screen keeps the rows: losing a loaded page
    // because the next one failed is worse than the missing page.
    if (state.error != null && state.isEmpty) {
      return AppErrorView(
        error: state.error!,
        onRetry: () => ref.read(returnsProvider.notifier).load(),
      );
    }

    if (state.isEmpty) {
      return ListView(
        // Must scroll, or pull-to-refresh cannot start on an empty list.
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          EmptyView(
            title: 'No returns yet',
            subtitle: 'Return requests you raise will show up here.',
            icon: Icons.assignment_return_rounded,
          ),
        ],
      );
    }

    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.gutter),
      itemCount: state.items.length + (state.loadingMore ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= state.items.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return _ReturnRow(row: state.items[i]);
      },
    );
  }
}

class _ReturnListSkeleton extends StatelessWidget {
  const _ReturnListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      itemCount: 5,
      itemBuilder: (_, __) => const Padding(
        padding: EdgeInsets.only(bottom: 10),
        child: AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(height: 14, width: 140, radius: AppRadius.sm),
              SizedBox(height: 8),
              SkeletonBox(height: 12, width: 100, radius: AppRadius.sm),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReturnRow extends StatelessWidget {
  const _ReturnRow({required this.row});

  final OrderReturn row;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        onTap: () => context.push('/returns/${row.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    // The return's own code is never serialised, so the order
                    // it belongs to is what identifies it.
                    'Order ${row.displayCode}',
                    style: context.text.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                AppSpacing.hSm,
                ReturnStatusChip(row: row),
              ],
            ),
            AppSpacing.vXs,
            Text(
              '${row.itemsCount} item${row.itemsCount == 1 ? '' : 's'}'
              '${row.effectiveReason.isNotEmpty ? ' · ${returnReasonLabel(row.effectiveReason.value)}' : ''}',
              style: context.text.bodySm.copyWith(color: context.colors.muted),
            ),
            // The latest step, in the server's own words. `latest_history`
            // now carries a customer-facing `title` — "Return approved", "More
            // information needed" — so the row can say where the request is
            // without the app mapping status codes to sentences of its own.
            // `action.label` is deliberately not used: it is worded for staff
            // ("Resubmit requested by admin").
            if (row.latestHistory?.title case final step? when step.isNotEmpty)
              Text(
                step,
                key: const Key('return-latest-step'),
                style: context.text.caption
                    .copyWith(color: context.colors.muted),
              ),
            if (row.canResubmit) ...[
              AppSpacing.vXs,
              Row(
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 16, color: AppColors.accent,),
                  const SizedBox(width: 4),
                  Text(
                    'Needs more information',
                    style: context.text.caption
                        .copyWith(color: AppColors.accent),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Status pill for a return.
///
/// The API exposes no `progress` object and no timeline, so the stepper the old
/// docs described cannot be built — this derives its colour from the status
/// token and shows the server's label.
/// Where a return has got to, in one word.
///
/// Takes the whole request rather than its [StatusValue] because the word is
/// not a function of the status alone: `completed` reads "Refunded" only once
/// the money is actually back. Passing the return makes that impossible to get
/// wrong at a call site — see [OrderReturn.stageLabel].
class ReturnStatusChip extends StatelessWidget {
  const ReturnStatusChip({super.key, required this.row});

  final OrderReturn row;

  @override
  Widget build(BuildContext context) {
    // Approved and Refunded are different news, so they are different colours:
    // teal for "we have accepted this, the money is still coming", green for
    // "the money is back". Sharing one green is what made an approval look
    // like the end of the story.
    final (bg, fg) = switch (row.status.value) {
      ReturnStatuses.completed when row.isRefunded => (
          context.colors.primarySoft,
          context.colors.primaryDarker,
        ),
      ReturnStatuses.completed ||
      ReturnStatuses.processing =>
        (context.colors.tealSoft, AppColors.teal),
      ReturnStatuses.canceled => (context.colors.surfaceAlt, context.colors.muted),
      ReturnStatuses.resubmit => (context.colors.accentSoft, AppColors.accent),
      _ => (context.colors.surfaceAlt, context.colors.body),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: AppRadius.rPill),
      child: Text(
        row.stageLabel,
        key: const Key('return-stage-chip'),
        style: context.text.overline.copyWith(color: fg),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../core/utils/price_utils.dart';
import '../../../core/utils/refund_notice.dart';
import '../../../data/models/order_return.dart';
import '../../providers/return_provider.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/return_timeline.dart';
import '../../widgets/evidence_picker.dart';
import '../../widgets/media_viewer.dart';
import '../../widgets/required_label.dart';
import '../../widgets/state_views.dart';
import '../../widgets/surfaces.dart';
import 'returns_screen.dart';
import '../../widgets/app_message.dart';

/// One return request in full.
///
/// ## What this screen deliberately does not draw
///
/// The old integration docs described a `progress` object and a `histories`
/// timeline. **Neither exists.** `OrderReturnResource` exposes only
/// `latest_history` — and that carries just an id, an action and timestamps, no
/// description and no reason — so a stepper would have to be invented from
/// nothing. The status pill is the honest amount of information available.
///
/// The return's own code (`#RT-…`) is never serialised either, so the order it
/// belongs to is what identifies it here.
class ReturnDetailScreen extends ConsumerWidget {
  const ReturnDetailScreen({super.key, required this.returnId});

  final int returnId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(returnDetailProvider(returnId));

    return Scaffold(
      appBar: AppBar(
        title: Text(async.valueOrNull == null
            ? 'Return'
            : 'Order ${async.value!.displayCode}',),
      ),
      body: async.when(
        loading: () => const LoadingView(label: 'Loading your request…'),
        error: (e, __) => AppErrorView(
          error: e,
          onRetry: () => ref.invalidate(returnDetailProvider(returnId)),
        ),
        data: (row) => _body(context, ref, row),
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, OrderReturn row) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        // The attempt counter is deliberately NOT shown.
        //
        // The three-submission cap is real and the server enforces it, but it
        // is the shop's internal limit, not something to put in front of the
        // customer: a running "Attempt 2 of 3" turns asking for help into a
        // countdown, and reads as a warning about the customer rather than a
        // fact about the request. [OrderReturn.canResubmit] is what governs
        // the button, and it is the server's answer either way.
        Row(children: [ReturnStatusChip(row: row)]),
        AppSpacing.vSm,
        Text(_statusExplainer(row), style: context.text.bodySm),

        // The figure, once there is one to name. Withheld while the return is
        // still open on purpose: what a return asks for and what is paid out
        // are not the same number — a refund is netted against RTO charges and
        // non-refundable shipping first — so quoting the request's total early
        // would set up an argument about the difference.
        if (row.isRefunded && row.refundedTotal > 0) ...[
          AppSpacing.vXs,
          Text(
            'Refunded ${PriceUtils.format(row.refundedTotal)}',
            key: const Key('return-refunded-amount'),
            style: context.text.title
                .copyWith(color: context.colors.primaryDarker),
          ),
        ],

        // Only ever populated while the status is `resubmit`. For a *canceled*
        // return the server sends null, so the app genuinely cannot tell the
        // customer why it was rejected — that is a backend gap, not an omission
        // here.
        if ((row.adminFeedback ?? '').isNotEmpty) ...[
          AppSpacing.vMd,
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        size: 18, color: AppColors.accent,),
                    AppSpacing.hSm,
                    Text('What the team needs',
                        style: context.text.title
                            .copyWith(color: AppColors.accent),),
                  ],
                ),
                AppSpacing.vSm,
                Text(row.adminFeedback!, style: context.text.bodySm),
              ],
            ),
          ),
        ],

        const Divider(height: 32),
        Text('Items', style: context.text.h3),
        AppSpacing.vSm,
        for (final item in row.items) _ItemRow(item: item),

        // Only when there is no timeline to show it in.
        //
        // These two blocks render the **newest** submission from the return's
        // top-level `customer_comment` / `media_images` — which is all the API
        // used to keep. The timeline carries every round now, each with its own
        // photos (return 29 live: three submissions, 1+1, 1+1 and 2+2 files),
        // so leaving these in printed the newest one twice and, worse, kept a
        // caption that is no longer true: earlier rounds are NOT gone any more.
        if (!row.hasHistory && (row.customerComment ?? '').isNotEmpty) ...[
          const Divider(height: 32),
          Text('What you told us', style: context.text.h3),
          AppSpacing.vSm,
          Text(row.customerComment!, style: context.text.bodySm),
        ],

        // Photos **and videos**, and every one of them opens. The videos were
        // simply not rendered before — `media_videos` was parsed and then
        // dropped on the floor — so a customer who filmed the damage saw no
        // sign the shop had it.
        if (!row.hasHistory)
          if (_evidence(row) case final evidence when evidence.isNotEmpty) ...[
          const Divider(height: 32),
          Text('What you sent', style: context.text.h3),
          AppSpacing.vXs,
          // Only reachable on a response with no timeline, where these really
          // are the *only* fields kept: `OrderReturnHelper::
          // resubmitReturnOrder` overwrites `customer_comment`,
          // `media_images` and `media_videos` on the return row itself. The
          // timeline preserves each round separately, which is why this
          // sentence is confined to the branch where it is still true.
          if (row.submissionCount > 0)
            Text(
              'This is your latest submission. Resubmitting replaces what you '
              'sent before.',
              style: context.text.caption.copyWith(color: context.colors.muted),
            ),
          AppSpacing.vSm,
          SizedBox(
            height: 84,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: evidence.length,
              separatorBuilder: (_, __) => AppSpacing.hXs,
              itemBuilder: (context, i) => MediaThumb(
                media: evidence[i],
                size: 84,
                onTap: () =>
                    showMediaViewer(context, evidence, initialIndex: i),
              ),
            ),
          ),
        ],

        // `can_resubmit` is server-computed as `status == resubmit &&
        // submission_count < 3`. Trusted rather than re-derived — the attempt
        // cap is the server's to enforce.
        if (row.canResubmit) ...[
          const Divider(height: 32),
          _ResubmitCard(row: row),
        ],

        // The record of how this return got here.
        //
        // After the resubmit form on purpose: what the customer has to *do*
        // belongs above what already happened. Open on arrival, though —
        // folded, with the newest round also printed above it, a return that
        // ran three submissions looked like a return with one.
        //
        // Worth having at all because `admin_feedback` holds only the
        // **current** instruction: the moment the customer answers it, the
        // earlier ones vanish from that field. The timeline's `note` is the
        // only place the conversation survives.
        if (row.hasHistory) ...[
          const Divider(height: 32),
          _HistorySection(histories: row.histories),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  /// The return's own evidence, photos first, as the viewer takes it.
  ///
  /// `media_videos` are plain file URLs here — unlike a review's, whose
  /// `thumbnail` is the clip itself — so there is no poster to pass and
  /// [MediaThumb] falls back to the clip's first frame.
  static List<AppMedia> _evidence(OrderReturn row) => [
        for (final url in row.images)
          if (url.isNotEmpty) AppMedia.image(url),
        for (final url in row.videos)
          if (url.isNotEmpty) AppMedia.video(url),
      ];

  /// The sentence under the chip.
  ///
  /// Approval and refund are separate events here, so the two states they
  /// produce get separate sentences: an approved return is a promise the shop
  /// has made and not yet kept, and saying "complete" over it — as this used
  /// to — told the customer to stop waiting for money that had not moved.
  static String _statusExplainer(OrderReturn row) => switch (row.status.value) {
        ReturnStatuses.pending =>
          'Your request is with the team. We will update you here.',
        ReturnStatuses.processing =>
          'Approved. Your refund is being processed.',
        ReturnStatuses.completed when row.isRefunded => RefundNotice.issued,
        ReturnStatuses.completed => 'This return is complete.',
        ReturnStatuses.canceled => 'This request was closed.',
        ReturnStatuses.resubmit =>
          'The team needs a little more from you before they can continue.',
        _ => 'We will update you here as this progresses.',
      };
}

/// The return's own timeline, folded until asked for.
class _HistorySection extends StatefulWidget {
  const _HistorySection({required this.histories});

  final List<OrderReturnHistory> histories;

  @override
  State<_HistorySection> createState() => _HistorySectionState();
}

class _HistorySectionState extends State<_HistorySection> {
  /// Open on arrival.
  ///
  /// It was folded, and that hid the thing the customer came for: with the
  /// newest submission also printed above, a return with three rounds looked
  /// like a return with one. The timeline is not an appendix — it is the only
  /// place the earlier rounds and the store's earlier messages exist.
  bool _open = true;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: const Key('return-history-toggle'),
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                Expanded(child: Text('Return history', style: context.text.h3)),
                Icon(
                  _open
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: context.colors.muted,
                ),
              ],
            ),
          ),
          if (_open) ...[
            AppSpacing.vSm,
            ReturnTimeline(histories: widget.histories),
          ],
        ],
      );
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final OrderReturnItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: AppNetworkImage(
                url: item.imageUrl,
                borderRadius: AppRadius.rSm,
                fit: BoxFit.cover,
              ),
            ),
            AppSpacing.hSm,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySm,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Qty ${item.quantity} · '
                    '${returnReasonLabel(item.reason.value)}',
                    style: context.text.caption
                        .copyWith(color: context.colors.muted),
                  ),
                ],
              ),
            ),
            AppSpacing.hSm,
            // Per-item `refund_amount` is exposed even though the request-level
            // `refunded_amount` is not, so this is the only refund figure the
            // app can show.
            if (item.refundAmount > 0)
              Text(
                PriceUtils.format(item.refundAmount),
                style: context.text.title,
              ),
          ],
        ),
      ),
    );
  }
}

/// Resubmit form, shown only when the server says the customer may.
class _ResubmitCard extends ConsumerStatefulWidget {
  const _ResubmitCard({required this.row});

  final OrderReturn row;

  @override
  ConsumerState<_ResubmitCard> createState() => _ResubmitCardState();
}

class _ResubmitCardState extends ConsumerState<_ResubmitCard> {
  final _comment = TextEditingController();
  EvidenceSelection _evidence = const EvidenceSelection();
  bool _showErrors = false;

  static const int _minComment = 50;

  /// Evidence is required **by this shop**, not by the API — the same policy
  /// the first submission follows (`ReturnRequestScreen._hasEvidence`). The
  /// team asked for more proof; sending the form back with none is the one
  /// thing that guarantees another round trip.
  bool get _hasEvidence => !_evidence.isEmpty;

  bool get _isComplete =>
      _comment.text.trim().length >= _minComment && _hasEvidence;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _showErrors = true);
    if (!_isComplete) return;

    final ok = await ref.read(returnSubmitProvider.notifier).resubmit(
          returnId: widget.row.id,
          comment: _comment.text.trim(),
          // Items are identified by the **return item's** id, not the order
          // product's, and each must repeat its reason even though the server
          // already stored one.
          items: [
            for (final item in widget.row.items)
              if (item.reason.value != null)
                ReturnResubmitItemDraft(
                  returnItemId: item.id,
                  reason: item.reason.value!,
                ),
          ],
          imagePaths: _evidence.imagePaths,
          videoPaths: _evidence.videoPaths,
        );

    if (!mounted) return;
    if (ok) {
      context.showSuccessSnack('Sent — the team will take another look.');
    } else {
      final error = ref.read(returnSubmitProvider).error;
      context.showAlertSnack(error?.message ?? 'Could not resubmit.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final submit = ref.watch(returnSubmitProvider);
    final tooShort = _showErrors && _comment.text.trim().length < _minComment;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const RequiredLabel('Add what they asked for'),
        AppSpacing.vXs,
        Text(
          'At least $_minComment characters.',
          style: context.text.caption.copyWith(color: context.colors.muted),
        ),
        AppSpacing.vSm,
        TextField(
          key: const Key('resubmit-comment'),
          controller: _comment,
          enabled: !submit.busy,
          minLines: 3,
          maxLines: 6,
          maxLength: 2000,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Add the detail or photos the team asked for.',
            errorText: tooShort
                ? 'Please write at least $_minComment characters '
                    '(${_comment.text.trim().length} so far).'
                : null,
          ),
        ),
        AppSpacing.vMd,
        EvidencePicker(
          selection: _evidence,
          limits: EvidenceLimits.returns,
          enabled: !submit.busy,
          required: true,
          errorText: _showErrors && !_hasEvidence
              ? 'Add at least one photo or video.'
              : null,
          onChanged: (value) => setState(() => _evidence = value),
        ),
        AppSpacing.vMd,
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            key: const Key('resubmit-send'),
            onPressed: submit.busy ? null : _send,
            style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
            child: Text(submit.busy ? submit.label : 'Resubmit request'),
          ),
        ),
      ],
    );
  }
}

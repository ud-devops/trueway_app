import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../core/utils/price_utils.dart';
import '../../../data/models/order_return.dart';
import '../../providers/return_provider.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/evidence_picker.dart';
import '../../widgets/required_label.dart';
import '../../widgets/quantity_stepper.dart';
import '../../widgets/state_views.dart';
import '../../widgets/surfaces.dart';
import '../../widgets/app_message.dart';

/// Request a return for one order.
///
/// Partial returns are enabled on this install, which decides the whole shape
/// of this form: the customer picks **which** items and **how many** of each,
/// and every picked line needs its own reason. The top-level reason is optional
/// and is not collected — a per-item one is required anyway, so asking twice
/// would be asking the same question.
class ReturnRequestScreen extends ConsumerStatefulWidget {
  const ReturnRequestScreen({super.key, required this.orderId});

  final int orderId;

  @override
  ConsumerState<ReturnRequestScreen> createState() =>
      _ReturnRequestScreenState();
}

class _ReturnRequestScreenState extends ConsumerState<ReturnRequestScreen> {
  /// `order_item_id` → how many units, and why.
  final Map<int, _LineSelection> _selected = {};

  final _comment = TextEditingController();
  EvidenceSelection _evidence = const EvidenceSelection();
  bool _showErrors = false;

  /// The server's own minimum. Enforced here so the customer is not told to
  /// rewrite after a round trip.
  static const int _minComment = 50;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  bool get _hasItems => _selected.isNotEmpty;
  bool get _commentLongEnough => _comment.text.trim().length >= _minComment;
  bool get _allHaveReasons =>
      _selected.values.every((line) => line.reason != null);

  /// Evidence is required **by this shop**, not by the API.
  ///
  /// `OrderReturnRequest` has no media rules at all — a return with no photos
  /// validates server-side. Requiring one here is a business decision: a claim
  /// the team can see is a claim they can approve without a round trip. Kept as
  /// its own getter so it is obvious what to relax if that policy changes.
  bool get _hasEvidence => !_evidence.isEmpty;

  bool get _isComplete =>
      _hasItems && _allHaveReasons && _commentLongEnough && _hasEvidence;

  Future<void> _submit(List<ReturnReasonOption> reasons) async {
    setState(() => _showErrors = true);
    if (!_isComplete) return;

    final id = await ref.read(returnSubmitProvider.notifier).submit(
          orderId: widget.orderId,
          comment: _comment.text.trim(),
          items: [
            for (final entry in _selected.entries)
              ReturnItemDraft(
                orderItemId: entry.key,
                quantity: entry.value.quantity,
                reason: entry.value.reason!,
              ),
          ],
          imagePaths: _evidence.imagePaths,
          videoPaths: _evidence.videoPaths,
        );

    if (!mounted) return;
    if (id == null) {
      // The notifier holds the server's wording — a 422 on the comment, or the
      // 200-with-error refusal "You cannot return this order".
      final error = ref.read(returnSubmitProvider).error;
      context.showAlertSnack(error?.message ?? 'Could not submit your request.');
      return;
    }

    // The submit response carries no relations, so the detail screen re-reads
    // rather than being handed this object.
    context.pushReplacement('/returns/$id');
    context.showSuccessSnack('Return request submitted');
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(returnEligibilityProvider(widget.orderId));
    final submit = ref.watch(returnSubmitProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Claim & Refund')),
      body: async.when(
        loading: () => const LoadingView(label: 'Checking this order…'),
        error: (e, __) => AppErrorView(
          // The refusal explains itself — "Order must be in completed status to
          // be eligible for return.", "A return request has already been
          // submitted for this order." — and that sentence is more useful than
          // the generic message wrapping it.
          error: returnRefusalReason(e) ?? e,
          onRetry: () =>
              ref.invalidate(returnEligibilityProvider(widget.orderId)),
        ),
        data: (eligibility) {
          if (eligibility.items.isEmpty) {
            return const EmptyView(
              title: 'Nothing to return',
              subtitle: 'This order has no items that can be returned.',
              icon: Icons.assignment_return_rounded,
            );
          }
          return _form(context, eligibility, submit);
        },
      ),
      bottomSheet: async.valueOrNull == null
          ? null
          : _submitBar(context, async.value!.reasons, submit),
    );
  }

  Widget _form(
    BuildContext context,
    ReturnEligibility eligibility,
    ReturnSubmitState submit,
  ) {
    final reasons = eligibility.reasons.isNotEmpty
        ? eligibility.reasons
        : [for (final r in ReturnReasons.defaults) ReturnReasonOption(value: r)];

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.gutter,
        AppSpacing.gutter,
        120,
      ),
      children: [
        const RequiredLabel('What are you returning?'),
        AppSpacing.vXs,
        Text(
          'Pick the items and how many of each.',
          style: context.text.bodySm.copyWith(color: context.colors.muted),
        ),
        if (_showErrors && !_hasItems) ...[
          AppSpacing.vXs,
          Text(
            'Select at least one item.',
            style: context.text.bodySm.copyWith(color: AppColors.error),
          ),
        ],
        AppSpacing.vSm,
        for (final item in eligibility.items)
          _ItemTile(
            item: item,
            selection: _selected[item.orderItemId],
            reasons: reasons,
            enabled: !submit.busy,
            showError: _showErrors,
            onToggle: (on) => setState(() {
              if (on) {
                _selected[item.orderItemId] = const _LineSelection(quantity: 1);
              } else {
                _selected.remove(item.orderItemId);
              }
            }),
            onQuantity: (q) => setState(() {
              final current = _selected[item.orderItemId];
              if (current != null) {
                _selected[item.orderItemId] = current.copyWith(quantity: q);
              }
            }),
            onReason: (r) => setState(() {
              final current = _selected[item.orderItemId];
              if (current != null) {
                _selected[item.orderItemId] = current.copyWith(reason: r);
              }
            }),
          ),
        const Divider(height: 32),
        RequiredLabel('Tell us what happened', style: context.text.title),
        AppSpacing.vXs,
        Text(
          'At least $_minComment characters — the team reads this before '
          'approving.',
          style: context.text.caption.copyWith(color: context.colors.muted),
        ),
        AppSpacing.vSm,
        TextField(
          key: const Key('return-comment'),
          controller: _comment,
          enabled: !submit.busy,
          minLines: 4,
          maxLines: 8,
          maxLength: 2000,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText:
                'Describe the problem — what arrived, what was wrong with it, '
                'and what you would like done.',
            errorText: _showErrors && !_commentLongEnough
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
              ? 'Add at least one photo or video of the problem.'
              : null,
          onChanged: (value) => setState(() => _evidence = value),
        ),
      ],
    );
  }

  Widget _submitBar(
    BuildContext context,
    List<ReturnReasonOption> reasons,
    ReturnSubmitState submit,
  ) {
    return BottomActionBar(
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          key: const Key('return-submit'),
          onPressed: submit.busy ? null : () => _submit(reasons),
          style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
          child: submit.busy
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    AppSpacing.hSm,
                    Text(submit.label),
                  ],
                )
              : Text(submit.label),
        ),
      ),
    );
  }
}

/// One line the customer marked for return.
class _LineSelection {
  const _LineSelection({required this.quantity, this.reason});

  final int quantity;
  final String? reason;

  _LineSelection copyWith({int? quantity, String? reason}) => _LineSelection(
        quantity: quantity ?? this.quantity,
        reason: reason ?? this.reason,
      );
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.selection,
    required this.reasons,
    required this.enabled,
    required this.showError,
    required this.onToggle,
    required this.onQuantity,
    required this.onReason,
  });

  final ReturnableItem item;
  final _LineSelection? selection;
  final List<ReturnReasonOption> reasons;
  final bool enabled;
  final bool showError;
  final ValueChanged<bool> onToggle;
  final ValueChanged<int> onQuantity;
  final ValueChanged<String> onReason;

  bool get _picked => selection != null;

  @override
  Widget build(BuildContext context) {
    final needsReason = _picked && selection!.reason == null && showError;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  key: Key('return-item-${item.orderItemId}'),
                  value: _picked,
                  onChanged: enabled ? (v) => onToggle(v ?? false) : null,
                ),
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
                        '${PriceUtils.format(item.price)} · ${item.quantity} '
                        'ordered',
                        style: context.text.caption
                            .copyWith(color: context.colors.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_picked) ...[
              AppSpacing.vSm,
              Row(
                children: [
                  Text('Quantity', style: context.text.bodySm),
                  const Spacer(),
                  QuantityStepper(
                    quantity: selection!.quantity,
                    dense: true,
                    filled: false,
                    // Bounded by what was actually ordered: the server rejects
                    // more, and there is nothing to return beyond it.
                    onIncrement: enabled && selection!.quantity < item.quantity
                        ? () => onQuantity(selection!.quantity + 1)
                        : null,
                    onDecrement: enabled && selection!.quantity > 1
                        ? () => onQuantity(selection!.quantity - 1)
                        : null,
                  ),
                ],
              ),
              AppSpacing.vSm,
              DropdownButtonFormField<String>(
                key: Key('return-reason-${item.orderItemId}'),
                initialValue: selection!.reason,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Reason *',
                  errorText: needsReason ? 'Pick a reason' : null,
                ),
                items: [
                  for (final reason in reasons)
                    DropdownMenuItem(
                      value: reason.value,
                      // The server sends `label: ""` for every reason, so the
                      // wording is the app's — see `returnReasonLabel`.
                      child: Text(returnReasonLabel(reason.value)),
                    ),
                ],
                onChanged: enabled
                    ? (value) {
                        if (value != null) onReason(value);
                      }
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

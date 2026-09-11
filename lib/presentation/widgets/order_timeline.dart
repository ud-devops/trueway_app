import 'package:flutter/material.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../screens/orders/orders_screen.dart' show formatOrderDate;
import '../../data/models/order.dart';

/// An order's timeline, newest first — the same rows the website shows on its
/// "Order information" page.
///
/// Renders **in the order received**. The detail endpoint sends `id DESC`, and
/// the app does not re-sort: the server decides what "latest" means, and a
/// client that sorted by its own rule would disagree with the website the first
/// time two rows shared a timestamp.
///
/// ⚠ Note for anyone reusing this: `POST /orders/tracking` returns a
/// history array too, but with placeholders **unfilled** — captured live,
/// `"Order was verified by %user_name%"`. Only the authenticated detail
/// endpoint's rows are fit to display.
class OrderTimeline extends StatelessWidget {
  const OrderTimeline({
    super.key,
    required this.histories,
    this.showHeading = true,
    this.shippingCompanyName,
  });

  final List<OrderHistory> histories;

  /// The carrier the order was booked with, from the **order** — it is one fact
  /// about the shipment, not something a step reported, so it is passed in
  /// rather than read off each entry.
  ///
  /// Shown once, on the step where it starts being true: the row that says the
  /// order shipped, or the courier's own first scan.
  final String? shippingCompanyName;

  /// Whether to draw "Order history" above the entries.
  ///
  /// False when the caller has already written it — the order detail screen
  /// folds this section behind a tappable header that has to carry the title
  /// *and* the chevron, so leaving this on printed the heading twice, one
  /// under the other.
  final bool showHeading;

  @override
  Widget build(BuildContext context) {
    // No card, no heading, nothing. An order with no recorded history has
    // nothing to say, and an empty panel says it loudly.
    if (histories.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeading) ...[
          Text('Order history', style: context.text.h3),
          AppSpacing.vSm,
        ],
        for (var i = 0; i < histories.length; i++)
          _Entry(
            entry: histories[i],
            shippingCompanyName: shippingCompanyName,
            // The connector hangs *below* a marker, so the last row has none.
            isLast: i == histories.length - 1,
          ),
      ],
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({
    required this.entry,
    required this.isLast,
    this.shippingCompanyName,
  });

  final OrderHistory entry;
  final bool isLast;
  final String? shippingCompanyName;

  /// The marker, chosen by what the step **is**.
  ///
  /// This used to be `is_system ? gear : person`, and that split no longer
  /// separates anything: the server now filters its internal rows out before
  /// sending, so every row that arrives is customer-facing whichever way the
  /// flag happens to fall. Order 314 has `return_order` flagged `is_system:
  /// true` sitting beside `refund` flagged false, and both are plainly the
  /// customer's business.
  ///
  /// The set is **open-ended** — new codes are added server-side without an app
  /// release — so anything unrecognised falls through to a neutral dot and its
  /// text still renders. The icon is decoration; the sentence is the content.
  static IconData _iconFor(String action) => switch (action) {
        'create_order_from_payment_page' ||
        'create_order_from_admin_page' =>
          Icons.receipt_long_rounded,
        'confirm_order' => Icons.verified_rounded,
        'create_shipment' => Icons.local_shipping_rounded,
        'update_shipping_status' => Icons.local_shipping_rounded,
        'confirm_delivery' || 'mark_order_as_completed' =>
          Icons.check_circle_outline_rounded,
        'cancel_order' => Icons.cancel_rounded,
        'return_order' => Icons.keyboard_return_rounded,
        'refund' => Icons.account_balance_wallet_rounded,
        _ => Icons.circle_rounded,
      };

  /// Whether the carrier's name belongs on this row.
  ///
  /// Only where it starts being true. Repeating "Xpressbees Surface 20kg" on
  /// every scan turns the timeline into a column of the same phrase.
  bool get _showsCarrier =>
      (shippingCompanyName ?? '').trim().isNotEmpty &&
      entry.action == 'create_shipment';

  /// Marker diameter. The connector is centred on it.
  static const double _dot = 26;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: _dot,
                height: _dot,
                decoration: BoxDecoration(
                  color: context.colors.primarySoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  // The website does **not** colour-code by action, and neither
                  // does this: fifteen-plus codes in as many colours would read
                  // as a status, which none of them are. Only the glyph varies.
                  _iconFor(entry.action),
                  size: 14,
                  color: context.colors.primaryDarker,
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: context.colors.line,
                  ),
                ),
            ],
          ),
          AppSpacing.hSm,
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Plain text, already resolved server-side — no HTML, and no
                  // placeholder substitution left to do here.
                  Text(entry.description, style: context.text.body),
                  // What the courier itself reported — "Bhilwara Hub", or the
                  // carrier that scanned it. Both nullable and independent: a
                  // status moved by hand in admin has neither.
                  if (entry.courierNote case final note?) ...[
                    const SizedBox(height: 2),
                    Text(
                      note,
                      style: context.text.caption
                          .copyWith(color: context.colors.muted),
                    ),
                  ],
                  if (_showsCarrier) ...[
                    const SizedBox(height: 2),
                    Text(
                      shippingCompanyName!.trim(),
                      style: context.text.caption
                          .copyWith(color: context.colors.primaryDark),
                    ),
                  ],
                  if (entry.createdAt case final at?) ...[
                    const SizedBox(height: 2),
                    Text(
                      formatOrderDate(at, withTime: true),
                      style: context.text.caption,
                    ),
                  ],
                  if (entry.isRefund &&
                      (entry.refundAmountFormatted ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _RefundNote(entry: entry),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The refund amount, called out beside the row that mentions it.
///
/// The description already names the figure, but rounded — live, a
/// ₹1,493.97 refund reads as "Refund success ₹1,494". The exact amount is
/// what a customer checking their statement needs.
class _RefundNote extends StatelessWidget {
  const _RefundNote({required this.entry});

  final OrderHistory entry;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          color: context.colors.surfaceAlt,
          borderRadius: AppRadius.rSm,
        ),
        child: Text(
          'Refunded ${entry.refundAmountFormatted}',
          style: context.text.bodySm.copyWith(color: context.colors.savings),
        ),
      );
}

/// Why an order was cancelled, shown beside its status.
///
/// Includes the customer's own note when they left one, so this is not a
/// restatement of the status chip — it is the part the chip cannot carry.
/// What is happening to the customer's money, on the order itself.
///
/// The cancel confirmation already says this, but a SnackBar is four seconds
/// long and this is the one sentence a customer comes back to the order to
/// re-read: *when does my money return?* Leaving it only in the toast means
/// the answer exists exactly once, at the moment they are least likely to be
/// reading carefully.
///
/// Deliberately **not** styled like [OrderCancellationNote]. That one is red
/// because it reports something that went wrong; this reports that the shop is
/// giving the money back, which is reassurance — so it takes the calm tone.
class OrderRefundNote extends StatelessWidget {
  const OrderRefundNote({super.key, required this.message});

  /// From [Order.refundNotice], which decides *which* sentence — money already
  /// sent, card refund, or cash — and returns null when nothing was ever paid.
  final String message;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('order-refund-note'),
        margin: const EdgeInsets.only(top: AppSpacing.xs),
        padding: const EdgeInsets.all(AppSpacing.xs),
        decoration: BoxDecoration(
          color: context.colors.primarySoft,
          borderRadius: AppRadius.rSm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.account_balance_wallet_rounded,
              size: 16,
              color: context.colors.primaryDark,
            ),
            AppSpacing.hXs,
            Expanded(
              child: Text(
                message,
                style: context.text.bodySm
                    .copyWith(color: context.colors.primaryDark),
              ),
            ),
          ],
        ),
      );
}

class OrderCancellationNote extends StatelessWidget {
  const OrderCancellationNote({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: AppSpacing.xs),
        padding: const EdgeInsets.all(AppSpacing.xs),
        decoration: BoxDecoration(
          color: AppColors.error.withValues(alpha: 0.08),
          borderRadius: AppRadius.rSm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.info_outline_rounded,
              size: 16,
              color: AppColors.error,
            ),
            AppSpacing.hXs,
            Expanded(
              child: Text(
                message,
                style: context.text.bodySm.copyWith(color: AppColors.error),
              ),
            ),
          ],
        ),
      );
}

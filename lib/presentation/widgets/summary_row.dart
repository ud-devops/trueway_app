import 'package:flutter/material.dart';

import '../../core/design_system/theme_context.dart';

/// Label-on-the-left, amount-on-the-right line used by the cart bill and the
/// checkout summary.
///
/// The two screens each had their own copy and they had already drifted: the
/// cart's supported [valueColor], so a coupon discount rendered green there and
/// plain black at checkout for the same order.
class SummaryRow extends StatelessWidget {
  const SummaryRow(
    this.label,
    this.value, {
    super.key,
    this.bold = false,
    this.muted = false,
    this.valueColor,
    this.labelColor,
    this.dense = true,
  });

  final String label;
  final String value;

  /// Emphasises the line — used for the "To pay" total.
  final bool bold;

  /// Dims both sides, for incidental lines like included GST.
  final bool muted;

  /// Tints the amount only, e.g. [context.colors.savings] for a discount.
  final Color? valueColor;

  /// Tints the label too. A discount line reads as one thing, not as a plain
  /// label with a coloured number after it.
  final Color? labelColor;

  /// Smaller type, tighter rows — the default.
  ///
  /// A bill is six or seven lines the customer scans for one number. At body
  /// size it fills the screen and pushes the total below the fold; at this size
  /// the whole thing is readable at a glance, which is what a bill is for.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final labelStyle = bold
        ? context.text.title
        : (dense ? context.text.bodySm : context.text.body);
    final valueStyle = bold
        ? (dense ? context.text.title : context.text.price)
        : (dense ? context.text.bodySm : context.text.title);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 3 : 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Flexible so a long label — "Coupon (HNHPQ2YWQJD0)" — wraps instead
          // of overflowing the card at a large OS text scale.
          Flexible(
            child: Text(
              label,
              style: labelStyle.copyWith(
                color: labelColor ?? (muted ? context.colors.faint : null),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: valueStyle.copyWith(
              color: valueColor ?? (muted ? context.colors.faint : null),
            ),
          ),
        ],
      ),
    );
  }
}

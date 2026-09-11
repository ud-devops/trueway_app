import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/design_system/app_icons.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import 'surfaces.dart';

/// The bill, as the customer reads it.
///
/// One widget family for the three screens that show it — the basket, checkout
/// and the placed order. They each had their own hand-rolled column of
/// [SummaryRow]s, and this section has drifted between them before: the same
/// charge under a different name one tap apart is the bug `SummaryRow` itself
/// was extracted to stop. A bill is also the one part of the app a customer
/// reads suspiciously, so it has to look identical wherever they check it.
///
/// ## The shape
///
/// Each row is `icon · label · [saved chip] · [struck-through was] · value`.
/// The strikethrough is what carries a discount now: the old bill spent four
/// rows on it — MRP, product discount, coupon, item total — which is precise
/// and reads like an invoice. One row saying `~~₹799~~ ₹609` with a "Saved
/// ₹190" chip says the same arithmetic in the shape a customer actually scans.
///
/// **Nothing here computes money.** Every figure is passed in already
/// formatted by the caller, from a field the server sent. The strikethrough
/// pair is only ever "what it would have been" beside "what it is", never a
/// subtraction this widget performed.
///
/// ## What is deliberately not copied from the reference design
///
/// The reference marks each label with a dotted underline, which in that app
/// means "tap for an explanation". Drawing that here would be an affordance
/// the app does not honour — there is nothing to open. Rows that genuinely
/// have something more to say carry it in [BillRow.note] instead, in plain
/// sight rather than behind a tap.
class BillCard extends StatelessWidget {
  const BillCard({
    super.key,
    required this.rows,
    this.title = 'Bill details',
    this.showTitle = true,
    this.total,
    this.savings,
    this.footnotes = const [],
  });

  /// The charge lines, in the order they add up.
  final List<Widget> rows;

  final String title;

  /// Checkout numbers its sections above the card ("4. Bill details"), so the
  /// card's own heading there would say it twice.
  final bool showTitle;

  /// The payable, under its own rule above the rows.
  final Widget? total;

  /// The tinted band under everything — see [BillSavings].
  final Widget? savings;

  /// Caveats that belong to the whole bill rather than one row: a total that
  /// does not reconcile, a coupon with no amount, a weight estimate.
  final List<Widget> footnotes;

  @override
  Widget build(BuildContext context) => AppCard(
        key: const Key('bill-details'),
        // Zero, so the savings band can run edge to edge under its wave. The
        // rows below take the inset back for themselves; without this the band
        // would float in a white margin and the wave would read as a graphic
        // sitting on the card rather than as the card's own torn edge.
        padding: EdgeInsets.zero,
        child: ClipRRect(
          // Same radius as the card, so the band's bottom corners follow it
          // instead of squaring off over the rounding.
          borderRadius: AppRadius.rLg,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showTitle) ...[
                      Text(title, style: context.text.h3),
                      AppSpacing.vSm,
                    ],
                    ...rows,
                    if (total != null) ...[
                      const Divider(height: 20),
                      total!,
                    ],
                    if (footnotes.isNotEmpty) ...[
                      AppSpacing.vXs,
                      ...footnotes,
                    ],
                  ],
                ),
              ),
              if (savings != null) savings!,
            ],
          ),
        ),
      );
}

/// Every term of a bill, already formatted.
///
/// Strings, not numbers, and that is the whole point: **nothing downstream of
/// this can do arithmetic on money.** Each field is a figure the server sent,
/// rendered by the screen that read it. A null field is a term the payload did
/// not carry, and it is omitted rather than printed as zero — a fee of nothing
/// and a fee nobody mentioned are different things.
class BillTerms {
  const BillTerms({
    required this.total,
    this.totalLabel = 'Total',
    this.itemTotal,
    this.discount,
    this.couponCode,
    this.shipping,
    this.shippingRow,
    this.shippingMuted = false,
    this.shippingFree = false,
    this.tax,
    this.paymentFee,
    this.savings,
    this.savingsNote,
  });

  /// Goods, before anything came off them.
  final String? itemTotal;

  /// What came off, as a positive figure — the row prints the minus.
  final String? discount;

  /// Names the discount row when the shop knows which coupon did it.
  final String? couponCode;

  /// The courier's charge, or the word standing in for it ("FREE", "Add an
  /// address"). Ignored when [shippingRow] is given.
  final String? shipping;

  /// A shipping line that needs more than a figure — checkout's carries the
  /// courier's name under the label, so the bill and the selector cannot
  /// disagree about which quote is being charged.
  final Widget? shippingRow;

  /// Dims the shipping line, for a charge that is not yet known.
  final bool shippingMuted;

  /// Tints the shipping figure, for a charge a coupon took away.
  final bool shippingFree;

  final String? tax;
  final String? paymentFee;

  /// The payable, and what to call it. Checkout says "Subtotal" until a
  /// courier has quoted, so the figure cannot be read as the amount due.
  final String total;
  final String totalLabel;

  /// The band under the rule.
  ///
  /// **Pass it even when it is zero.** The wave is the bill's own bottom edge,
  /// not a reward for having saved something — hiding it on an undiscounted
  /// basket made the same card look designed on one screen and unfinished on
  /// the next, which is exactly the inconsistency sharing the composition was
  /// meant to end. The client's own reference prints "Your total savings
  /// ₹0.00" for the same reason.
  ///
  /// Null is for a bill that cannot answer the question at all — a placed order
  /// whose breakdown the server withheld.
  final String? savings;
  final String? savingsNote;
}

/// The bill, composed the same way everywhere it appears.
///
/// [BillCard] and [BillRow] made the *parts* shared; this makes the
/// **composition** shared, which is the half that had actually drifted. The
/// basket, checkout and a placed order each built their own column of rows, in
/// their own order, with their own labels — so the same order could show
/// "Discount" as its own line on one screen and folded into the item row on the
/// next, one tap apart. A customer comparing the two has no way to tell that is
/// a styling choice rather than a different charge.
class OrderBillCard extends StatelessWidget {
  const OrderBillCard({
    super.key,
    required this.terms,
    this.title = 'Bill details',
    this.showTitle = true,
    this.extraRows = const [],
    this.footnotes = const [],
  });

  final BillTerms terms;
  final String title;
  final bool showTitle;

  /// Rows that belong to one screen only — checkout's estimated-weight caveat.
  final List<Widget> extraRows;

  /// Caveats about the bill as a whole: a total that does not reconcile, a
  /// coupon with no amount.
  final List<Widget> footnotes;

  @override
  Widget build(BuildContext context) => BillCard(
        title: title,
        showTitle: showTitle,
        rows: [
          if (terms.itemTotal case final value?)
            BillRow(
              icon: BillIcons.items,
              label: 'Item total',
              value: value,
            ),
          // Its own row, named by the coupon that caused it. The server sends
          // ONE discount figure and no coupon-only amount, so a second row
          // would be a second deduction it never made.
          if (terms.discount case final value?)
            BillRow(
              icon: BillIcons.coupon,
              label: terms.couponCode == null
                  ? 'Discount'
                  : 'Discount (${terms.couponCode})',
              value: '- $value',
              valueColor: context.colors.savings,
            ),
          // "Shipping", not "Delivery": this row is the courier's charge, which
          // is what the shop calls it everywhere. "Delivery" is kept for the
          // arrival date, where it is the right word.
          if (terms.shippingRow case final row?)
            row
          else if (terms.shipping case final value?)
            BillRow(
              icon: BillIcons.shipping,
              label: 'Shipping',
              value: value,
              muted: terms.shippingMuted,
              valueColor: terms.shippingFree ? context.colors.savings : null,
            ),
          // Not dimmed. This backend ADDS tax on top, so a faint row reads as
          // "already included above" and makes the bill appear not to sum.
          if (terms.tax case final value?)
            BillRow(icon: BillIcons.tax, label: 'GST', value: value),
          if (terms.paymentFee case final value?)
            BillRow(icon: BillIcons.fee, label: 'Payment fee', value: value),
          ...extraRows,
        ],
        total: BillTotalRow(label: terms.totalLabel, value: terms.total),
        savings: terms.savings == null
            ? null
            : BillSavings(amount: terms.savings!, note: terms.savingsNote),
        footnotes: footnotes,
      );
}

/// One charge line.
class BillRow extends StatelessWidget {
  const BillRow({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.was,
    this.saved,
    this.note,
    this.valueColor,
    this.muted = false,
  });

  final String label;

  /// The figure that counts, already formatted.
  final String value;

  /// Sits in the icon column. Null keeps the column's width, so labels stay
  /// aligned down the bill whether or not every row has one.
  final IconData? icon;

  /// What this line would have been — struck through, to the left of [value].
  /// Only pass it when it differs from [value]; the same number twice, once
  /// crossed out, reads as a mistake.
  final String? was;

  /// "Saved ₹190", beside the label.
  final String? saved;

  /// A caption under the row — the coupon that produced the saving, the
  /// courier being charged for.
  final String? note;

  final Color? valueColor;

  /// Dims the whole line, for a charge that is not yet known.
  final bool muted;

  /// Width of the icon column, shared so every label starts at the same x.
  static const double _iconColumn = 26;

  /// How the row splits between what is being charged and what it costs.
  ///
  /// Shared with [BillTotalRow] and [BillSavings], because the three of them
  /// stack directly on top of one another and any disagreement shows as a
  /// ragged column of amounts.
  ///
  /// Both sides are [Expanded] rather than [Flexible]. That is the fix for the
  /// alignment this card shipped with: a loose Flexible sizes to its children,
  /// so the amount slot was only as wide as the digits in it and
  /// `WrapAlignment.end` had no leftover space to push against — every amount
  /// ended wherever its own digits ran out, ₹1,665.10 reaching further right
  /// than + ₹41.63, and none of them meeting the Total below.
  static const int labelFlex = 3;
  static const int amountFlex = 2;

  @override
  Widget build(BuildContext context) {
    final dim = muted ? context.colors.faint : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _iconColumn,
            child: icon == null
                ? null
                : Icon(
                    icon,
                    size: 17,
                    weight: 300,
                    color: dim ?? context.colors.muted,
                  ),
          ),
          Expanded(
            flex: labelFlex,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      label,
                      style: context.text.bodySm.copyWith(color: dim),
                    ),
                    if (saved != null) _SavedChip(text: saved!),
                  ],
                ),
                if (note != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    note!,
                    style: context.text.caption
                        .copyWith(color: context.colors.faint),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: amountFlex,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 0,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // The pair reads right-to-left in importance: the crossed-out
                // figure is context, the live one is the answer.
                if (was != null)
                  Text(was!, style: context.text.strike.copyWith(fontSize: 12)),
                Text(
                  value,
                  style: context.text.bodySm.copyWith(color: valueColor ?? dim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The payable. Heavier than the rows above it, and the only line in the card
/// with no icon column of its own — it is a conclusion, not another charge.
class BillTotalRow extends StatelessWidget {
  const BillTotalRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: BillRow.labelFlex, child: Text(label, style: context.text.h3)),
          const SizedBox(width: 10),
          Expanded(
            flex: BillRow.amountFlex,
            child: Text(
              value,
              key: const Key('bill-total'),
              textAlign: TextAlign.end,
              style: context.text.h3,
            ),
          ),
        ],
      );
}

/// The tinted band that closes the bill, torn off along a wave.
///
/// Worth its own emphasis rather than a row: it is the one figure in here the
/// customer is pleased to see, and burying it among the charges wastes it.
///
/// The wave is the point of the shape, and it is doing a job rather than
/// decorating. A bill is a column of numbers the customer is checking; the
/// torn edge says *the checking stops here, what follows is not another
/// charge*. A straight rule would have said "one more row".
///
/// It is a full period per [_wavelength] — crest then trough, drawn as two
/// quadratic curves — not a row of identical semicircular notches. Notches
/// read as a perforated coupon, which invites a tap that does nothing; a wave
/// reads as paper.
class BillSavings extends StatelessWidget {
  const BillSavings({super.key, required this.amount, this.note});

  final String amount;

  /// Where the saving came from — a coupon, free delivery, or both.
  final String? note;

  /// Half the peak-to-trough height. Small on purpose: at 4dp the wave is
  /// legible at a glance and still reads as one edge. Taller and the band
  /// starts looking like a separate card that has slid under this one.
  static const double _amplitude = 4;

  /// One crest and one trough. About four and a half periods across a 320dp
  /// card, which is enough repetition to read as a pattern rather than as a
  /// single dip someone left in by mistake.
  static const double _wavelength = 22;

  @override
  Widget build(BuildContext context) => ClipPath(
        clipper: const _WaveTopClipper(
          amplitude: _amplitude,
          wavelength: _wavelength,
        ),
        child: Container(
          key: const Key('bill-savings'),
          width: double.infinity,
          color: context.colors.primarySoft,
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            // Clears the trough — the wave eats into the band's own top, so
            // text placed at the ordinary inset would sit in the dip.
            AppSpacing.sm + _amplitude * 2,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The same two columns as every charge row above, so this
              // amount lands on their right edge rather than on its own.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: BillRow.labelFlex,
                    child: Text(
                      'Your total savings',
                      style: context.text.title
                          .copyWith(color: context.colors.primaryDarker),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: BillRow.amountFlex,
                    child: Text(
                      amount,
                      textAlign: TextAlign.end,
                      style: context.text.title
                          .copyWith(color: context.colors.primaryDarker),
                    ),
                  ),
                ],
              ),
              if (note != null) ...[
                const SizedBox(height: 2),
                Text(
                  note!,
                  style: context.text.caption
                      .copyWith(color: context.colors.primaryDark),
                ),
              ],
            ],
          ),
        ),
      );
}

/// Cuts a wave along the top edge of whatever it clips.
///
/// The path starts and ends at the wave's midline, so the widget's laid-out
/// height is what it says it is — the crests rise into the [_amplitude] of
/// padding above, and the troughs cut into the band. Nothing about the layout
/// depends on the curve, which is what keeps the band's height predictable at
/// any text scale.
class _WaveTopClipper extends CustomClipper<Path> {
  const _WaveTopClipper({required this.amplitude, required this.wavelength});

  final double amplitude;
  final double wavelength;

  @override
  Path getClip(Size size) {
    final path = Path()..moveTo(0, amplitude);

    // `<` rather than `<=`, and one extra period is allowed to overshoot the
    // right edge: a partial period looks like the wave was cut off, which it
    // is — but the clip hides the overshoot, so the edge stays mid-curve
    // instead of ending on a flat run.
    for (var x = 0.0; x < size.width; x += wavelength) {
      path
        ..quadraticBezierTo(
          x + wavelength * 0.25,
          0,
          x + wavelength * 0.5,
          amplitude,
        )
        ..quadraticBezierTo(
          x + wavelength * 0.75,
          amplitude * 2,
          x + wavelength,
          amplitude,
        );
    }

    return path
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(_WaveTopClipper oldClipper) =>
      oldClipper.amplitude != amplitude ||
      oldClipper.wavelength != wavelength;
}

/// "Saved ₹190" — the green pill beside a discounted row's label.
class _SavedChip extends StatelessWidget {
  const _SavedChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: context.colors.primarySoft,
          borderRadius: AppRadius.rSm,
        ),
        child: Text(
          text,
          style: context.text.overline
              .copyWith(color: context.colors.primaryDarker),
        ),
      );
}

/// The icons the bill's rows use, named once so the three screens cannot pick
/// different pictures for the same charge.
abstract final class BillIcons {
  static const IconData items = Symbols.receipt_long;
  static const IconData shipping = AppIcons.truck;
  static const IconData tax = Symbols.percent;
  static const IconData fee = Symbols.credit_card;
  static const IconData coupon = Symbols.sell;
}

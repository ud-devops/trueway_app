import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_icons.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../data/models/coupon.dart';
import '../providers/server_cart_provider.dart';
import 'skeletons.dart';
import 'state_views.dart';
import 'surfaces.dart';

/// What the coupon sheet was closed with, so the cart can say the right thing.
///
/// Only ever a *success*: a refusal never closes the sheet. That is the point
/// of showing a list — a code the server would not take should leave the
/// customer looking at the other codes, not back on the cart wondering.
@immutable
class CouponSheetResult {
  const CouponSheetResult._(this.appliedCode, this.removed);

  const CouponSheetResult.applied(String code) : this._(code, false);
  const CouponSheetResult.removed() : this._(null, true);

  final String? appliedCode;
  final bool removed;
}

/// Opens the coupon picker. Resolves to null when it is dismissed.
Future<CouponSheetResult?> showCouponSheet(BuildContext context) =>
    showModalBottomSheet<CouponSheetResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => const CouponSheet(),
    );

/// The coupons the shop advertises, plus a field for the ones it does not.
///
/// ## Both halves are load-bearing
///
/// `GET /coupons` returns only the codes an admin ticked as **visible at
/// checkout**. Codes sent over WhatsApp or SMS are absent from that list and
/// still apply perfectly well, so the manual field is not a fallback for an
/// empty list — it stays there always, and it is above the list because a
/// customer who arrived holding a code is not shopping for one.
///
/// ## Applying happens here, not in the caller
///
/// The sheet drives [ServerCartNotifier.applyCoupon] itself and only closes on
/// success. A refusal is painted inline instead: a SnackBar would render in the
/// Scaffold *underneath* this route and never be seen, and popping first would
/// throw the customer out of the list they were choosing from.
///
/// ## Refusals are expensive, which is why nothing is optimistic
///
/// A rejected code does not merely fail — `HandleApplyCouponService` returns
/// after `Cart::restore()` has already deleted the stored row, so the whole
/// basket goes with it and `ServerCartNotifier` has to rebuild it from its
/// mirror. Verified live: a 1-item cart was empty after one bad code. Every
/// control is therefore disabled for the duration of a call.
class CouponSheet extends ConsumerStatefulWidget {
  const CouponSheet({super.key});

  @override
  ConsumerState<CouponSheet> createState() => _CouponSheetState();
}

class _CouponSheetState extends ConsumerState<CouponSheet> {
  final _manual = TextEditingController();

  /// A call is in flight. Every button goes dead — a second concurrent write is
  /// how this backend loses a cart.
  bool _busy = false;

  /// The server's own refusal, verbatim. It names the actual constraint
  /// ("You are under ₹5,000.00 to apply the coupon, you must add ₹3,157.00
  /// more items to your cart") and paraphrasing loses the only useful part.
  String? _failure;

  @override
  void initState() {
    super.initState();
    _manual.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  Future<void> _apply(String code) async {
    final trimmed = code.trim().toUpperCase();
    if (trimmed.isEmpty || _busy) return;

    setState(() {
      _busy = true;
      _failure = null;
    });
    final failure =
        await ref.read(serverCartProvider.notifier).applyCoupon(trimmed);
    if (!mounted) return;

    if (failure == null) {
      Navigator.pop(context, CouponSheetResult.applied(trimmed));
      return;
    }
    setState(() {
      _busy = false;
      _failure = failure;
    });
  }

  Future<void> _remove() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    final failure = await ref.read(serverCartProvider.notifier).removeCoupon();
    if (!mounted) return;

    if (failure == null) {
      Navigator.pop(context, const CouponSheetResult.removed());
      return;
    }
    setState(() {
      _busy = false;
      _failure = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final applied = ref.watch(serverCartProvider).appliedCouponCode;
    final coupons = ref.watch(availableCouponsProvider);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Coupons', style: context.text.h3),
            AppSpacing.vSm,
            _manualEntry(context),
            if (_failure != null) ...[
              AppSpacing.vSm,
              _failureStrip(context, _failure!),
            ],
            AppSpacing.vMd,
            ...coupons.when(
              data: (list) => _list(context, list, applied),
              loading: () => [
                for (var i = 0; i < 2; i++) ...[
                  const SkeletonBox(height: 92, radius: 12),
                  AppSpacing.vSm,
                ],
              ],
              // An error is not "no coupons": the manual field above still
              // works, so the strip sits under it rather than replacing the
              // sheet.
              error: (e, _) => [
                InlineErrorStrip(
                  key: const Key('coupon-list-error'),
                  error: e,
                  label: 'the coupon list',
                  onRetry: () => ref.invalidate(availableCouponsProvider),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _manualEntry(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: const Key('coupon-manual-field'),
              controller: _manual,
              enabled: !_busy,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.done,
              inputFormatters: [_UpperCase()],
              onSubmitted: _apply,
              decoration: const InputDecoration(
                labelText: 'Have a code?',
                hintText: 'Enter coupon code',
              ),
            ),
          ),
          AppSpacing.hSm,
          Padding(
            // Aligns the button with the field's box rather than its label.
            padding: const EdgeInsets.only(top: 6),
            child: ElevatedButton(
              key: const Key('coupon-manual-apply'),
              onPressed: _busy || _manual.text.trim().isEmpty
                  ? null
                  : () => _apply(_manual.text),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(84, 48),
              ),
              child: const Text('Apply'),
            ),
          ),
        ],
      );

  List<Widget> _list(BuildContext context, List<Coupon> all, String? applied) {
    if (all.isEmpty) {
      // Not an error and not a dead end — the field above is the whole point.
      return [
        Text(
          key: const Key('coupon-list-empty'),
          'No offers running right now. If you have a code, enter it above.',
          style: context.text.bodySm.copyWith(color: context.colors.faint),
        ),
      ];
    }

    return [
      for (final coupon in all) ...[
        _CouponCard(
          coupon: coupon,
          isApplied: applied != null &&
              applied.toUpperCase() == coupon.code.toUpperCase(),
          busy: _busy,
          onApply: () => _apply(coupon.code),
          onRemove: _remove,
        ),
        AppSpacing.vSm,
      ],
    ];
  }

  Widget _failureStrip(BuildContext context, String message) => Container(
        key: const Key('coupon-failure'),
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.error.withValues(alpha: 0.08),
          borderRadius: AppRadius.rMd,
          border: Border.all(color: AppColors.error.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(AppIcons.info, size: 18, color: AppColors.error),
            AppSpacing.hXs,
            Expanded(child: Text(message, style: context.text.bodySm)),
          ],
        ),
      );
}

/// One offer.
class _CouponCard extends StatelessWidget {
  const _CouponCard({
    required this.coupon,
    required this.isApplied,
    required this.busy,
    required this.onApply,
    required this.onRemove,
  });

  final Coupon coupon;
  final bool isApplied;
  final bool busy;
  final VoidCallback onApply;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final blocked = coupon.blockedReason;
    // Applied wins over ineligible: a coupon can stop qualifying while it is on
    // the cart (the basket shrank), and the customer needs the Remove button
    // more than they need to be told it no longer qualifies.
    final dim = blocked != null && !isApplied;

    return AppCard(
      key: Key('coupon-card-${coupon.code}'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: dim ? context.colors.surfaceAlt : context.colors.accentSoft,
              borderRadius: AppRadius.rSm,
            ),
            child: Text(
              // The server's own rendering — "50%", "₹100.00". Formatting
              // `value` here disagrees with the web store by a paisa.
              coupon.valueFormatted,
              style: context.text.title.copyWith(
                color: dim ? context.colors.faint : AppColors.accentDark,
              ),
            ),
          ),
          AppSpacing.hSm,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  coupon.code,
                  style: context.text.title.copyWith(
                    color: dim ? context.colors.faint : null,
                  ),
                ),
                Text(
                  coupon.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.caption,
                ),
                if (blocked != null) ...[
                  AppSpacing.vXs,
                  Text(
                    // The server's shortfall, computed against this basket —
                    // the same number its refusal would quote.
                    blocked,
                    key: Key('coupon-blocked-${coupon.code}'),
                    style: context.text.caption
                        .copyWith(color: AppColors.accentDark),
                  ),
                ],
                if (coupon.endDate != null) ...[
                  AppSpacing.vXs,
                  Text(
                    'Valid till ${_shortDate(coupon.endDate!)}',
                    style: context.text.caption,
                  ),
                ],
              ],
            ),
          ),
          AppSpacing.hXs,
          if (isApplied)
            TextButton(
              key: Key('coupon-remove-${coupon.code}'),
              onPressed: busy ? null : onRemove,
              child: const Text('Remove'),
            )
          else
            TextButton(
              key: Key('coupon-apply-${coupon.code}'),
              // Dead only while a call is in flight or the server said this
              // basket cannot use it. `is_eligible` absent or null means the
              // server did not judge — see [Coupon.canApply] — and the button
              // stays live so the server gets the final word.
              onPressed: busy || !coupon.canApply ? null : onApply,
              child: const Text('Apply'),
            ),
        ],
      ),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _shortDate(DateTime d) =>
      '${d.day} ${_months[d.month - 1]} ${d.year}';
}

class _UpperCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}

import 'package:flutter/material.dart';

import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';

/// The app's standard panel: a surface block with rounded corners and either a
/// hairline border (default) or a soft shadow.
///
/// This decoration was written out by hand in six places — the cart's three
/// cards, the checkout summary, the cart line and the account groups — so a
/// change to the app's card treatment meant six edits, and they had already
/// diverged on padding.
/// The shape shared by every row in the Account menu.
///
/// Two files draw that row — the private `_MenuRow` in account_screen.dart and
/// [AppearanceTile] — and they sit directly on top of one another in a single
/// list, so a divergence of even 2dp shows as a jog in the left edge and one
/// card standing taller than its neighbours. Naming the numbers once is what
/// stops that.
///
/// 34 + 10 + 10 is a 54dp row. The rows were 64dp, which is comfortable for a
/// list of four and a lot of scrolling for a list of eleven; 54 still clears
/// the 48dp minimum tap target on its own, so nothing here is bought from the
/// customer's ability to hit it.
abstract final class MenuRowMetrics {
  /// Diameter of the tinted circle the icon sits in.
  ///
  /// 28, down from 34. The row cannot get shorter than 48dp — that is the
  /// minimum touch target and `account_screen_test` measures it — so the only
  /// way to make the list read tighter is to take the space out of the badge
  /// rather than out of the padding around it.
  static const double badge = 28;

  /// The row's own insets. Horizontal stays at the card default — it is the
  /// vertical that was making the list long.
  ///
  /// The rows sit inside one card with hairlines between them rather than each
  /// in a card of its own, so the padding no longer has to carry the visual gap
  /// as well — the divider does that.
  ///
  /// **10 with a 28dp badge is exactly 48dp**, the minimum touch target in both
  /// Material and iOS, which `account_screen_test`'s row-height group measures.
  /// The row cannot be made shorter; a tighter-looking list has to come from a
  /// smaller badge, and this pair is already at that floor.
  static const EdgeInsets padding =
      EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 10);

  /// The row's outline.
  ///
  /// `line` rather than `hairline`: on a white card over the #F7F8F6 list this
  /// screen uses, hairline is close enough to both to read as nothing at all,
  /// and an edge that is almost there is worse than no edge. Kept a function
  /// because the colour is theme-dependent — see the guard in
  /// test/core/theme_test.dart.
  static Border outline(BuildContext context) =>
      Border.all(color: context.colors.line);
}

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.sm),
    this.elevated = false,
    this.borderRadius = AppRadius.rLg,
    this.color,
    this.onTap,
    this.border,
  });

  final Widget child;

  /// Pass [EdgeInsets.zero] for cards whose children own their own insets
  /// (e.g. a column of `ListTile`s).
  final EdgeInsetsGeometry padding;

  /// Shadow instead of a border. Used for cards that sit on a tinted list.
  final bool elevated;

  /// Draws this border whatever [elevated] says.
  ///
  /// The two were an either/or, which left an elevated card's edge defined by
  /// nothing but a soft shadow — legible on white, mushy on the tinted list
  /// backgrounds these cards actually sit on. Pass a border to get both.
  final BoxBorder? border;

  final BorderRadius borderRadius;

  /// Defaults to the theme's surface. Only override for a card that is
  /// deliberately tinted.
  final Color? color;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? context.colors.surface,
        borderRadius: borderRadius,
        border: border ??
            (elevated ? null : Border.all(color: context.colors.hairline)),
        boxShadow: elevated ? AppShadows.soft : null,
      ),
      child: child,
    );

    if (onTap == null) return card;
    return InkWell(onTap: onTap, borderRadius: borderRadius, child: card);
  }
}

/// Pinned bar at the bottom of a screen holding its primary action.
///
/// Owns the gesture-inset padding so screens can't forget it — the cart,
/// checkout and product-detail bars each recomputed
/// `12 + MediaQuery.of(context).padding.bottom` inline.
class BottomActionBar extends StatelessWidget {
  const BottomActionBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.sm + MediaQuery.of(context).padding.bottom,
        ),
        decoration: BoxDecoration(
          color: context.colors.surface,
          boxShadow: AppShadows.raised,
        ),
        child: child,
      );
}

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'app_typography.dart';

export 'app_palette.dart' show AppPalette;

/// How widgets read the design tokens.
///
/// ```dart
/// Text('Bill details', style: context.text.h3)
/// Container(color: context.colors.surface)
/// ```
///
/// Both resolve against the active [ThemeData], so the same widget renders
/// correctly in light and dark. Reaching past these for `AppColors.surface` or
/// `AppTypography.h3` bakes in the light value — that is exactly what left the
/// app with a complete-but-unusable dark theme before.
///
/// [AppColors] is still the right thing to name directly for tokens that do not
/// change between themes: the brand green, the accents, the error/warning/info
/// triple and the decorative gradients.
extension ThemeContext on BuildContext {
  /// The palette for the active theme.
  ///
  /// [AppTheme] registers one on both of its themes, so this normally just
  /// reads it back. The fallback covers the case where a widget renders under a
  /// `Theme` this app did not build — a nested theme inside a package widget,
  /// or a bare `MaterialApp` — where picking by brightness still gives the
  /// right answer rather than throwing.
  AppPalette get colors {
    final theme = Theme.of(this);
    return theme.extension<AppPalette>() ??
        (theme.brightness == Brightness.dark
            ? AppPalette.dark
            : AppPalette.light);
  }

  AppText get text => AppText(colors);
}

/// The type ramp with theme-aware colours applied.
///
/// Mirrors [AppTypography] one-for-one — the sizes, weights and tracking still
/// live there; this only decides which palette entry each step is painted in.
@immutable
class AppText {
  const AppText(this._c);

  final AppPalette _c;

  // Headings take [AppPalette.ink].
  TextStyle get display => AppTypography.display.copyWith(color: _c.ink);
  TextStyle get h1 => AppTypography.h1.copyWith(color: _c.ink);
  TextStyle get h2 => AppTypography.h2.copyWith(color: _c.ink);
  TextStyle get h3 => AppTypography.h3.copyWith(color: _c.ink);
  TextStyle get title => AppTypography.title.copyWith(color: _c.ink);

  // Body copy steps down through body → muted.
  TextStyle get bodyLg => AppTypography.bodyLg.copyWith(color: _c.body);
  TextStyle get body => AppTypography.body.copyWith(color: _c.body);
  TextStyle get bodySm => AppTypography.bodySm.copyWith(color: _c.muted);
  TextStyle get caption => AppTypography.caption.copyWith(color: _c.muted);
  TextStyle get overline => AppTypography.overline.copyWith(color: _c.muted);

  // Prices read as headings.
  TextStyle get price => AppTypography.price.copyWith(color: _c.ink);
  TextStyle get priceLg => AppTypography.priceLg.copyWith(color: _c.ink);

  /// Struck-through MRP — deliberately the faintest step in both themes.
  TextStyle get strike => AppTypography.strike.copyWith(color: _c.faint);

  /// Label on a filled brand button. White in both themes: the button's fill is
  /// [AppColors.primary] either way, so this is not a theme-dependent choice.
  TextStyle get button => AppTypography.button;

  TextStyle get buttonSm => AppTypography.buttonSm.copyWith(color: _c.ink);
}

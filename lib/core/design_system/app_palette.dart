import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Every colour token whose value depends on the active theme.
///
/// [AppColors] stays the raw brand palette — the literal hex values, plus the
/// tokens that are identical in both themes (the brand green, the accents, the
/// semantic error/warning/info triple, and the decorative gradients, all of
/// which are saturated mid-tones designed to sit on either background).
/// Anything that has to *change* between light and dark lives here.
///
/// Read it through `context.colors`, never by constructing it:
///
/// ```dart
/// Container(color: context.colors.surface)
/// ```
///
/// Registered on both themes in [AppTheme], so `Theme.of(context)` always has
/// one — the `!` in the accessor cannot fail at runtime.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.ink,
    required this.body,
    required this.muted,
    required this.faint,
    required this.line,
    required this.hairline,
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.primaryDark,
    required this.primaryDarker,
    required this.primarySoft,
    required this.primarySurface,
    required this.accentSoft,
    required this.tealSoft,
    required this.savings,
    required this.headerWash,
    required this.tilePastels,
    required this.tileTints,
  });

  // ---- Text ---------------------------------------------------------------
  /// Headings.
  final Color ink;

  /// Body copy.
  final Color body;

  /// Secondary text.
  final Color muted;

  /// Hints, disabled, struck-through prices.
  final Color faint;

  // ---- Structure ----------------------------------------------------------
  /// Borders and dividers.
  final Color line;

  /// The lighter border used on cards.
  final Color hairline;

  final Color background;
  final Color surface;

  /// Recessed surface — image wells, filled inputs.
  final Color surfaceAlt;

  // ---- Brand green, contrast-corrected ------------------------------------
  //
  // In light these are *darker* greens so they read against white. On dark that
  // inverts: the same roles need greens *lighter* than [AppColors.primary], or
  // brand-coloured text disappears into the background. This is the single
  // biggest reason the screens could not simply be handed AppTheme.dark.

  /// Brand-coloured icons and text on a plain surface.
  final Color primaryDark;

  /// Brand-coloured text on [primarySoft].
  final Color primaryDarker;

  /// Brand tint — chips, badges, empty-state medallions.
  final Color primarySoft;

  /// The faintest brand tint.
  final Color primarySurface;

  final Color accentSoft;
  final Color tealSoft;

  /// Discount and "you save" amounts. Theme-aware because the light value
  /// (#16A34A) only reaches ~3.6:1 on a dark surface, which fails AA for the
  /// body-sized text it is used at.
  final Color savings;

  /// Wash behind the home greeting.
  final LinearGradient headerWash;

  /// Category tile backgrounds and their matching icon tints, by index.
  final List<Color> tilePastels;
  final List<Color> tileTints;

  Color tileBg(int i) => tilePastels[i % tilePastels.length];
  Color tileTint(int i) => tileTints[i % tileTints.length];

  static const light = AppPalette(
    ink: AppColors.ink,
    body: AppColors.body,
    muted: AppColors.muted,
    faint: AppColors.faint,
    line: AppColors.line,
    hairline: AppColors.hairline,
    background: AppColors.background,
    surface: AppColors.surface,
    surfaceAlt: AppColors.surfaceAlt,
    primaryDark: AppColors.primaryDark,
    primaryDarker: AppColors.primaryDarker,
    primarySoft: AppColors.primarySoft,
    primarySurface: AppColors.primarySurface,
    accentSoft: AppColors.accentSoft,
    tealSoft: AppColors.tealSoft,
    savings: AppColors.savings,
    headerWash: AppColors.homeHeaderWash,
    tilePastels: AppColors.tilePastels,
    tileTints: AppColors.tileTints,
  );

  static const dark = AppPalette(
    ink: AppColors.darkInk,
    body: AppColors.darkBody,
    muted: AppColors.darkMuted,
    faint: AppColors.darkFaint,
    line: AppColors.darkLine,
    hairline: AppColors.darkHairline,
    background: AppColors.darkBackground,
    surface: AppColors.darkSurface,
    surfaceAlt: AppColors.darkSurfaceAlt,
    primaryDark: AppColors.darkPrimaryStrong,
    primaryDarker: AppColors.darkPrimaryStronger,
    primarySoft: AppColors.darkPrimarySoft,
    primarySurface: AppColors.darkPrimarySurface,
    accentSoft: AppColors.darkAccentSoft,
    tealSoft: AppColors.darkTealSoft,
    savings: AppColors.darkSavings,
    headerWash: AppColors.darkHomeHeaderWash,
    tilePastels: AppColors.darkTilePastels,
    tileTints: AppColors.darkTileTints,
  );

  @override
  AppPalette copyWith({
    Color? ink,
    Color? body,
    Color? muted,
    Color? faint,
    Color? line,
    Color? hairline,
    Color? background,
    Color? surface,
    Color? surfaceAlt,
    Color? primaryDark,
    Color? primaryDarker,
    Color? primarySoft,
    Color? primarySurface,
    Color? accentSoft,
    Color? tealSoft,
    Color? savings,
    LinearGradient? headerWash,
    List<Color>? tilePastels,
    List<Color>? tileTints,
  }) =>
      AppPalette(
        ink: ink ?? this.ink,
        body: body ?? this.body,
        muted: muted ?? this.muted,
        faint: faint ?? this.faint,
        line: line ?? this.line,
        hairline: hairline ?? this.hairline,
        background: background ?? this.background,
        surface: surface ?? this.surface,
        surfaceAlt: surfaceAlt ?? this.surfaceAlt,
        primaryDark: primaryDark ?? this.primaryDark,
        primaryDarker: primaryDarker ?? this.primaryDarker,
        primarySoft: primarySoft ?? this.primarySoft,
        primarySurface: primarySurface ?? this.primarySurface,
        accentSoft: accentSoft ?? this.accentSoft,
        tealSoft: tealSoft ?? this.tealSoft,
        savings: savings ?? this.savings,
        headerWash: headerWash ?? this.headerWash,
        tilePastels: tilePastels ?? this.tilePastels,
        tileTints: tileTints ?? this.tileTints,
      );

  /// Drives the cross-fade when [ThemeMode] changes. Without it the whole UI
  /// snaps between palettes while the rest of the theme animates.
  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      ink: Color.lerp(ink, other.ink, t)!,
      body: Color.lerp(body, other.body, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
      line: Color.lerp(line, other.line, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      primaryDark: Color.lerp(primaryDark, other.primaryDark, t)!,
      primaryDarker: Color.lerp(primaryDarker, other.primaryDarker, t)!,
      primarySoft: Color.lerp(primarySoft, other.primarySoft, t)!,
      primarySurface: Color.lerp(primarySurface, other.primarySurface, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      tealSoft: Color.lerp(tealSoft, other.tealSoft, t)!,
      savings: Color.lerp(savings, other.savings, t)!,
      headerWash: LinearGradient.lerp(headerWash, other.headerWash, t)!,
      tilePastels: _lerpColors(tilePastels, other.tilePastels, t),
      tileTints: _lerpColors(tileTints, other.tileTints, t),
    );
  }

  static List<Color> _lerpColors(List<Color> a, List<Color> b, double t) => [
        for (var i = 0; i < a.length; i++) Color.lerp(a[i], b[i], t)!,
      ];
}


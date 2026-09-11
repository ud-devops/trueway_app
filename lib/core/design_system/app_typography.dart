import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

/// Type ramp built on **Plus Jakarta Sans** (trialling — Inter is the fallback).
///
/// ## Why this face, read off the ramp below
///
/// This is a *UI* ramp, not an editorial one. Five of its styles are 13px or
/// smaller — `bodySm` 13, `caption` 12, `overline` 11, `strike` 13,
/// `buttonSm` 13 — and the workhorses sit at 13-15px. Thirteen files render
/// prices, and a single 110dp product tile (three across a 411dp phone, see
/// `Responsive.homeProductColumns`) routinely carries a price, a struck-through
/// MRP, a unit rate and a discount badge. Overflow at the largest OS text scale
/// is a live enough problem to have its own tests.
///
/// So the font has one job: hold up small, dense, and full of numbers.
///
/// Inter was drawn for exactly that — a tall x-height, open apertures and
/// unambiguous figures at 11-13px. Its numerals are the reason it wins here:
/// nothing else on Google Fonts keeps a column of ₹ amounts as even.
///
/// ## What it replaced, and why those failed
///
/// **Poppins** and then **Outfit** are both *geometric* faces: circular,
/// wide, and drawn with a small x-height relative to their caps. They read
/// well as headlines and thin out at caption size — which is most of this app.
/// The negative tracking on every heading below (-0.5 to -0.2) is the
/// fingerprint they left: the ramp had been pulled inward to compensate for a
/// face too wide for the layout.
///
/// Outfit was chosen to sit near Blinkit's `Okra` (Zomato's cut of Metropolis).
/// It does — but Okra is a brand face carried by a design team that can afford
/// to tune it per screen, and this app's grids are denser than Blinkit's.
///
/// If more personality is wanted later, **Plus Jakarta Sans** is the closest
/// thing that keeps the geometric flavour without the small-size cost.
///
/// Single family, tuned weights + tracking.
class AppTypography {
  AppTypography._();

  static TextStyle _base(
    double size,
    FontWeight weight, {
    double? height,
    double? tracking,
    Color? color,
  }) {
    return GoogleFonts.plusJakartaSans(
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: tracking,
      color: color ?? AppColors.ink,
    );
  }

  // ---- Weight ramp -------------------------------------------------------
  //
  // Two constants, not per-style weights: they are what keeps the contrast
  // between emphasis and body consistent across the whole app.
  //
  // Back to w600 for Inter. It needed w700 under Outfit, whose strokes thin out
  // at text sizes — Inter is drawn with more weight at the same nominal value,
  // and w700 on a 15px title reads as shouting. Body stays at Regular.

  /// Headings, prices, buttons.
  static const FontWeight emphasis = FontWeight.w600;

  /// Body copy, captions, labels.
  static const FontWeight regular = FontWeight.w400;

  /// Between the two — used where a label needs to separate from body text
  /// without becoming a heading.
  static const FontWeight medium = FontWeight.w500;

  // Display / headings
  static TextStyle get display => _base(30, emphasis, height: 1.15, tracking: -0.5);
  static TextStyle get h1 => _base(24, emphasis, height: 1.2, tracking: -0.3);
  static TextStyle get h2 => _base(20, emphasis, height: 1.25, tracking: -0.2);
  static TextStyle get h3 => _base(17, emphasis, height: 1.3);
  static TextStyle get title => _base(15, medium, height: 1.35);

  // Body
  static TextStyle get bodyLg => _base(15, regular, height: 1.45, color: AppColors.body);
  static TextStyle get body => _base(14, regular, height: 1.45, color: AppColors.body);
  static TextStyle get bodySm => _base(13, regular, height: 1.4, color: AppColors.muted);
  static TextStyle get caption => _base(12, regular, height: 1.35, color: AppColors.muted);
  static TextStyle get overline => _base(11, medium, tracking: 0.6, color: AppColors.muted);

  // Numeric / price
  //
  // Prices keep a touch more weight than body text: they are the one thing a
  // shopper scans for, and at these sizes Regular reads as tentative.
  static TextStyle get price => _base(16, emphasis, tracking: -0.2);
  static TextStyle get priceLg => _base(22, emphasis, tracking: -0.4);
  static TextStyle get strike => _base(13, regular, color: AppColors.faint)
      .copyWith(decoration: TextDecoration.lineThrough);

  // Buttons
  static TextStyle get button => _base(15, medium, tracking: 0.1, color: Colors.white);
  static TextStyle get buttonSm => _base(13, medium, tracking: 0.1);

  static TextTheme textTheme(Color ink, Color body) => TextTheme(
        displaySmall: display.copyWith(color: ink),
        headlineMedium: h1.copyWith(color: ink),
        headlineSmall: h2.copyWith(color: ink),
        titleLarge: h3.copyWith(color: ink),
        titleMedium: title.copyWith(color: ink),
        bodyLarge: bodyLg.copyWith(color: body),
        bodyMedium: AppTypography.body.copyWith(color: body),
        bodySmall: bodySm,
        labelLarge: button,
      );
}

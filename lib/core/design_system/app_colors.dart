import 'package:flutter/material.dart';

/// Trueway Farms brand palette.
///
/// Primary green (#40B048) is sampled directly from the recovered app logo.
/// The rest of the ramp is an upgraded, accessibility-checked system built
/// around it — organic/fresh, but with premium Stripe/Linear-grade neutrals.
class AppColors {
  AppColors._();

  // ---- Brand green ramp -------------------------------------------------
  static const Color primary = Color(0xFF40B048); // recovered brand green
  static const Color primaryDark = Color(0xFF2E8B39);
  static const Color primaryDarker = Color(0xFF1F6B29);
  static const Color primaryLight = Color(0xFF7CCB80);
  static const Color primarySoft = Color(0xFFE7F5E8); // tint / chips
  static const Color primarySurface = Color(0xFFF1F9F1);

  // ---- Accent (harvest amber, for offers/badges) ------------------------
  static const Color accent = Color(0xFFF59E0B);
  static const Color accentDark = Color(0xFFD97706);
  static const Color accentSoft = Color(0xFFFEF3E2);

  // ---- Secondary (fresh teal — variety against the green) ---------------
  static const Color teal = Color(0xFF0E9A94);
  static const Color tealSoft = Color(0xFFDFF3F1);

  // ---- Extra accents used sparingly for colour variety ------------------
  static const Color berry = Color(0xFFE0518A); // rose highlights / hearts
  static const Color sky = Color(0xFF3B9FE0);

  // ---- Neutrals (slight green-warm ink) ---------------------------------
  static const Color ink = Color(0xFF0F1B12); // headings
  static const Color body = Color(0xFF37433A); // body text
  static const Color muted = Color(0xFF6B7A6F); // secondary text
  static const Color faint = Color(0xFF9AA69C); // hints / disabled
  static const Color line = Color(0xFFE4E9E4); // borders / dividers
  static const Color hairline = Color(0xFFEEF1EE);

  // ---- Ink drawn ON slider artwork --------------------------------------
  //
  // The shop's slider assets are LIGHT — a cream studio background with the
  // product spilling in from the edges — so copy on them is dark, exactly as
  // the website renders it. `#253D4E` is the website's own slider heading
  // colour; matching it is what makes the two look like one brand.
  //
  // ⚠ These two are deliberately **fixed, not theme-aware**. The image does not
  // change with the app's theme, so neither may the text on it: routing this
  // through `context.colors.ink` would flip the copy to near-white in dark mode
  // and leave it invisible on a cream photograph.
  static const Color onSliderInk = Color(0xFF253D4E);
  static const Color onSliderMuted = Color(0xFF5C6C79);

  // ---- Surfaces ----------------------------------------------------------
  static const Color background = Color(0xFFF7F8F6);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceAlt = Color(0xFFFBFCFB);

  // ---- Semantic ----------------------------------------------------------
  static const Color success = Color(0xFF16A34A);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFE11D48);
  static const Color info = Color(0xFF2563EB);
  static const Color savings = Color(0xFF16A34A); // discount / you-save text

  // ---- Dark theme --------------------------------------------------------
  //
  // Consumed through [AppPalette.dark], not directly. Widgets read
  // `context.colors.*`, which picks the right side of each pair.
  static const Color darkBackground = Color(0xFF0E120F);
  static const Color darkSurface = Color(0xFF161C18);
  static const Color darkSurfaceAlt = Color(0xFF1E251F);
  static const Color darkLine = Color(0xFF2A322C);
  static const Color darkHairline = Color(0xFF222A24);
  static const Color darkInk = Color(0xFFF2F5F2);
  static const Color darkBody = Color(0xFFC7CEC8);
  static const Color darkMuted = Color(0xFF8D968F);
  static const Color darkFaint = Color(0xFF6E776F);

  // The light theme's "dark green" roles invert on dark: brand-coloured text
  // and icons have to be *lighter* than [primary] to clear the background.
  static const Color darkPrimaryStrong = Color(0xFF6FC776);
  static const Color darkPrimaryStronger = Color(0xFF9BDBA0);
  static const Color darkPrimarySoft = Color(0xFF1B2C1E);
  static const Color darkPrimarySurface = Color(0xFF16231A);
  static const Color darkAccentSoft = Color(0xFF2E2416);
  static const Color darkTealSoft = Color(0xFF122A29);

  /// Lifted from #16A34A, which only reaches ~3.6:1 on [darkSurface].
  static const Color darkSavings = Color(0xFF4ADE80);

  // ---- Ashop pastel category tiles --------------------------------------
  // Soft rounded-tile backgrounds (Ashop signature) with matching icon tints.
  static const List<Color> tilePastels = [
    Color(0xFFE7F5E8), // mint (brand)
    Color(0xFFFFF3D6), // butter
    Color(0xFFDFF1F7), // sky
    Color(0xFFEDE7F8), // lilac
    Color(0xFFFCE8DE), // peach
    Color(0xFFFDE7EC), // blush
  ];
  static const List<Color> tileTints = [
    Color(0xFF40B048), // green
    Color(0xFFD79A18), // amber
    Color(0xFF3EA6C7), // teal-blue
    Color(0xFF8467C7), // purple
    Color(0xFFE07B53), // coral
    Color(0xFFDB5E7C), // rose
  ];

  // Dark counterparts: the same six hues dropped to tile-on-dark luminance,
  // with the tints lifted so an icon still reads against them.
  static const List<Color> darkTilePastels = [
    Color(0xFF1B2C1E), // mint (brand)
    Color(0xFF2E2616), // butter
    Color(0xFF15272E), // sky
    Color(0xFF241E33), // lilac
    Color(0xFF2E2019), // peach
    Color(0xFF2E1A20), // blush
  ];
  static const List<Color> darkTileTints = [
    Color(0xFF6FC776), // green
    Color(0xFFE9B84A), // amber
    Color(0xFF6FC3DD), // teal-blue
    Color(0xFFA894DB), // purple
    Color(0xFFEE9C79), // coral
    Color(0xFFEB8AA3), // rose
  ];

  static Color tileBg(int i) => tilePastels[i % tilePastels.length];
  static Color tileTint(int i) => tileTints[i % tileTints.length];

  // Warm home header wash (subtle brand tint behind search / greeting).
  static const LinearGradient homeHeaderWash = LinearGradient(
    colors: [Color(0xFFEAF7EB), Color(0xFFF7F8F6)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const LinearGradient darkHomeHeaderWash = LinearGradient(
    colors: [Color(0xFF16231A), Color(0xFF0E120F)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // ---- Gradients ---------------------------------------------------------
  static const LinearGradient brandGradient = LinearGradient(
    colors: [Color(0xFF43B94B), Color(0xFF2E8B39)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Hero promo card — deep organic green with a teal lift.
  static const LinearGradient heroGradient = LinearGradient(
    colors: [Color(0xFF2FA24C), Color(0xFF14876A)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Offer / sale card — warm harvest amber.
  static const LinearGradient offerGradient = LinearGradient(
    colors: [Color(0xFFFFB020), Color(0xFFF07E13)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

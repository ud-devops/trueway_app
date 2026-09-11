import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_palette.dart';
import 'app_spacing.dart';
import 'app_typography.dart';

/// Light + dark [ThemeData], both assembled by [_build] from an [AppPalette].
///
/// The two themes used to be written separately, with dark defined as
/// `light.copyWith(...)` patching a handful of properties. Everything the patch
/// missed — the chip tint, the input borders, the nav bar's label colours —
/// silently kept its light value. Deriving both from the same function means a
/// new themed component cannot be added to one and forgotten in the other.
class AppTheme {
  AppTheme._();

  static ThemeData get light => _build(Brightness.light, AppPalette.light);

  static ThemeData get dark => _build(Brightness.dark, AppPalette.dark);

  static ThemeData _build(Brightness brightness, AppPalette p) {
    final isDark = brightness == Brightness.dark;

    final scheme = ColorScheme(
      brightness: brightness,
      primary: AppColors.primary,
      onPrimary: Colors.white,
      secondary: AppColors.accent,
      onSecondary: Colors.white,
      surface: p.surface,
      onSurface: p.ink,
      error: AppColors.error,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      // Widgets read this through `context.colors`.
      extensions: [p],
      scaffoldBackgroundColor: p.background,
      textTheme: AppTypography.textTheme(p.ink, p.body),
      primaryColor: AppColors.primary,
      splashFactory: InkSparkle.splashFactory,
      dividerTheme: DividerThemeData(
        color: p.line,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: true,
        titleTextStyle: AppTypography.h3.copyWith(color: p.ink),
        iconTheme: IconThemeData(color: p.ink),
        // Status-bar glyphs must contrast with the app bar, so this inverts
        // with the theme rather than being pinned dark.
        systemOverlayStyle:
            isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        color: p.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.rLg),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor:
              isDark ? AppColors.darkPrimarySoft : AppColors.primaryLight,
          disabledForegroundColor: isDark ? p.faint : Colors.white,
          elevation: 0,
          minimumSize: const Size.fromHeight(54),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.rPill),
          textStyle: AppTypography.button,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.primaryDark,
          minimumSize: const Size.fromHeight(54),
          side: const BorderSide(color: AppColors.primary, width: 1.5),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.rPill),
          textStyle: AppTypography.button.copyWith(color: p.primaryDark),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.primaryDark,
          textStyle: AppTypography.buttonSm,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.primarySoft,
        labelStyle: AppTypography.bodySm.copyWith(color: p.primaryDarker),
        side: BorderSide.none,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.rPill),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surfaceAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        hintStyle: AppTypography.body.copyWith(color: p.faint),
        labelStyle: AppTypography.body.copyWith(color: p.muted),
        border: OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide(color: p.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide(color: p.line),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide(color: AppColors.primary, width: 1.6),
        ),
        errorBorder: const OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide(color: AppColors.error),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: p.surface,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: p.faint,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        // No pill behind the active destination — the selected tab is already
        // distinguished by its filled icon, heavier label and brand colour.
        indicatorColor: Colors.transparent,
        indicatorShape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
        ),
        height: 66,
        elevation: 8,
        shadowColor: Colors.black26,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => AppTypography.overline.copyWith(
            fontSize: 10,
            color: s.contains(WidgetState.selected) ? p.primaryDark : p.muted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            size: 24,
            color: s.contains(WidgetState.selected) ? p.primaryDark : p.muted,
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: AppTypography.h3.copyWith(color: p.ink),
        contentTextStyle: AppTypography.body.copyWith(color: p.body),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: p.primaryDark,
        textColor: p.ink,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.primary,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        // Inverted against the page, as a snack should be — on dark that means
        // a light chip, so the text colour has to invert with it.
        backgroundColor: isDark ? AppColors.darkInk : AppColors.ink,
        contentTextStyle: AppTypography.body.copyWith(
          color: isDark ? AppColors.darkBackground : Colors.white,
        ),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.rMd),
      ),
    );
  }
}

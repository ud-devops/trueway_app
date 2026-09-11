import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/design_system/theme_context.dart';

void main() {
  // These run as `testWidgets` even though they assert on plain ThemeData:
  // building a theme resolves the Poppins TextTheme, and google_fonts attempts
  // a network fetch for it. The widget-test binding stubs HTTP so that fetch
  // fails fast and falls back; a bare `test` hits a real socket and throws.
  group('AppTheme', () {
    testWidgets('both themes carry an AppPalette', (_) async {
      expect(AppTheme.light.extension<AppPalette>(), isNotNull);
      expect(AppTheme.dark.extension<AppPalette>(), isNotNull);
    });

    testWidgets('each theme carries the palette matching its brightness',
        (_) async {
      expect(
        AppTheme.light.extension<AppPalette>()!.surface,
        AppPalette.light.surface,
      );
      expect(
        AppTheme.dark.extension<AppPalette>()!.surface,
        AppPalette.dark.surface,
      );
    });

    testWidgets('brightness is set on the theme and its scheme', (_) async {
      expect(AppTheme.light.brightness, Brightness.light);
      expect(AppTheme.dark.brightness, Brightness.dark);
      expect(AppTheme.dark.colorScheme.brightness, Brightness.dark);
    });

    // The two themes used to be `light` and `light.copyWith(...)`, so anything
    // the patch forgot kept its light value. These are the properties that were
    // actually wrong before both themes came from one builder.
    testWidgets('themed component colours differ between light and dark',
        (_) async {
      expect(
        AppTheme.dark.scaffoldBackgroundColor,
        isNot(AppTheme.light.scaffoldBackgroundColor),
      );
      expect(
        AppTheme.dark.chipTheme.backgroundColor,
        isNot(AppTheme.light.chipTheme.backgroundColor),
      );
      expect(
        AppTheme.dark.inputDecorationTheme.fillColor,
        isNot(AppTheme.light.inputDecorationTheme.fillColor),
      );
      expect(
        AppTheme.dark.dividerTheme.color,
        isNot(AppTheme.light.dividerTheme.color),
      );
      expect(
        AppTheme.dark.snackBarTheme.backgroundColor,
        isNot(AppTheme.light.snackBarTheme.backgroundColor),
      );
    });
  });

  group('AppPalette', () {
    test('the two palettes differ on every colour that matters', () {
      const l = AppPalette.light;
      const d = AppPalette.dark;
      expect(d.ink, isNot(l.ink));
      expect(d.body, isNot(l.body));
      expect(d.surface, isNot(l.surface));
      expect(d.background, isNot(l.background));
      expect(d.line, isNot(l.line));
      expect(d.primarySoft, isNot(l.primarySoft));
      // The brand-green text roles have to invert, not just darken.
      expect(d.primaryDark, isNot(l.primaryDark));
      expect(d.savings, isNot(l.savings));
    });

    test('lerp interpolates rather than snapping', () {
      final mid = AppPalette.light.lerp(AppPalette.dark, 0.5);
      expect(mid.surface, isNot(AppPalette.light.surface));
      expect(mid.surface, isNot(AppPalette.dark.surface));
      expect(mid.tilePastels.length, AppPalette.light.tilePastels.length);
    });

    test('lerp endpoints return the exact palettes', () {
      expect(AppPalette.light.lerp(AppPalette.dark, 0).surface,
          AppPalette.light.surface,);
      expect(AppPalette.light.lerp(AppPalette.dark, 1).surface,
          AppPalette.dark.surface,);
    });

    test('tile helpers wrap instead of overflowing', () {
      const p = AppPalette.dark;
      expect(p.tileBg(0), p.tileBg(p.tilePastels.length));
      expect(p.tileTint(7), p.tileTints[7 % p.tileTints.length]);
    });
  });

  group('context.colors', () {
    testWidgets('resolves to the dark palette under the dark theme',
        (tester) async {
      late AppPalette palette;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        home: Builder(builder: (ctx) {
          palette = ctx.colors;
          return const SizedBox.shrink();
        },),
      ),
      );

      expect(palette.surface, AppPalette.dark.surface);
      expect(palette.ink, AppPalette.dark.ink);
    });

    testWidgets('resolves to the light palette under the light theme',
        (tester) async {
      late AppPalette palette;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.light,
        home: Builder(builder: (ctx) {
          palette = ctx.colors;
          return const SizedBox.shrink();
        },),
      ),
      );

      expect(palette.surface, AppPalette.light.surface);
    });

    // A widget can end up under a Theme this app did not build — a package's
    // nested Theme, or a bare MaterialApp. Falling back by brightness keeps it
    // rendering correctly instead of throwing on the null check.
    testWidgets('falls back by brightness when no palette is registered',
        (tester) async {
      late AppPalette palette;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Builder(builder: (ctx) {
          palette = ctx.colors;
          return const SizedBox.shrink();
        },),
      ),
      );

      expect(palette.surface, AppPalette.dark.surface);
    });

    testWidgets('context.text paints headings in the palette ink',
        (tester) async {
      late TextStyle heading;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.dark,
        home: Builder(builder: (ctx) {
          heading = ctx.text.h3;
          return const SizedBox.shrink();
        },),
      ),
      );

      expect(heading.color, AppPalette.dark.ink);
    });
  });

  // Guards the migration itself. Every theme-dependent token now lives on
  // AppPalette; naming one of these statically in a widget silently hardcodes
  // the light value, which is exactly how dark mode was broken before.
  group('presentation layer', () {
    const themeDependent = [
      'ink', 'body', 'muted', 'faint', 'line', 'hairline',
      'background', 'surface', 'surfaceAlt',
      'primaryDark', 'primaryDarker', 'primarySoft', 'primarySurface',
      'accentSoft', 'tealSoft', 'savings', 'homeHeaderWash',
    ];

    test('never reads a theme-dependent token off AppColors', () {
      final offenders = <String>[];

      for (final entity in Directory('lib/presentation')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          for (final token in themeDependent) {
            if (RegExp('\\bAppColors\\.$token\\b').hasMatch(line)) {
              offenders.add('${entity.path}:${i + 1}  AppColors.$token');
            }
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'Use context.colors.<token> instead:\n${offenders.join('\n')}',
      );
    });
  });
}

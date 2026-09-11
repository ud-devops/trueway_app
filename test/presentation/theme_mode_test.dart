import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/design_system/theme_context.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/theme_provider.dart';
import 'package:trueway_farms/presentation/widgets/appearance_tile.dart';
import 'package:trueway_farms/presentation/widgets/surfaces.dart';

Future<ProviderContainer> _container([Map<String, Object> seed = const {}]) async {
  SharedPreferences.setMockInitialValues(seed);
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  group('ThemeModeNotifier', () {
    testWidgets('defaults to system so a dark device opens dark', (_) async {
      final c = await _container();
      addTearDown(c.dispose);
      expect(c.read(themeModeProvider), ThemeMode.system);
    });

    testWidgets('persists the chosen mode', (_) async {
      final c = await _container();
      addTearDown(c.dispose);

      await c.read(themeModeProvider.notifier).set(ThemeMode.dark);
      expect(c.read(themeModeProvider), ThemeMode.dark);

      final prefs = c.read(sharedPreferencesProvider);
      expect(prefs.getString('theme_mode'), 'dark');
    });

    testWidgets('restores a previously saved mode', (_) async {
      final c = await _container({'theme_mode': 'light'});
      addTearDown(c.dispose);
      expect(c.read(themeModeProvider), ThemeMode.light);
    });

    // Stored as a name rather than the enum index, so a value that is no longer
    // recognised degrades to "follow the system" instead of picking whichever
    // mode happens to sit at that index.
    testWidgets('falls back to system on an unrecognised stored value',
        (_) async {
      final c = await _container({'theme_mode': 'sepia'});
      addTearDown(c.dispose);
      expect(c.read(themeModeProvider), ThemeMode.system);
    });
  });

  group('appearance switching', () {
    testWidgets('choosing Dark repaints widgets with the dark palette',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: Consumer(
            builder: (_, ref, __) => MaterialApp(
              theme: AppTheme.light,
              darkTheme: AppTheme.dark,
              themeMode: ref.watch(themeModeProvider),
              home: const Scaffold(
                body: Column(
                  children: [
                    AppearanceTile(),
                    AppCard(child: Text('Bill details')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scoped to the "Bill details" card specifically: [AppearanceTile] is
      // now an `AppCard` itself, so a bare `find.byType(AppCard)` matches two
      // widgets once it is on screen.
      Color cardColour() => (tester
              .widget<Container>(
                find.descendant(
                  of: find.widgetWithText(AppCard, 'Bill details'),
                  matching: find.byType(Container),
                ),
              )
              .decoration! as BoxDecoration)
          .color!;

      expect(cardColour(), AppPalette.light.surface);

      // The tile is a single row naming the current mode ("LIGHT"); the three
      // choices live in the sheet it opens, not inline.
      await tester.tap(find.byType(AppearanceTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();

      expect(cardColour(), AppPalette.dark.surface);
      expect(prefs.getString('theme_mode'), 'dark');
    });
  });
}

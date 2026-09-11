import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core_providers.dart';

/// The user's appearance choice, persisted across launches.
///
/// Defaults to [ThemeMode.system] so a device already set to dark opens dark
/// without anyone having to find the setting.
class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier(this._prefs) : super(_read(_prefs));

  final SharedPreferences _prefs;

  static const _key = 'theme_mode';

  /// Stored as a stable string rather than the enum's index: the index would
  /// silently remap if ThemeMode ever gains a value.
  static ThemeMode _read(SharedPreferences prefs) =>
      switch (prefs.getString(_key)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static String _name(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };

  Future<void> set(ThemeMode mode) async {
    if (state == mode) return;
    state = mode;
    await _prefs.setString(_key, _name(mode));
  }
}

final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, ThemeMode>(
  (ref) => ThemeModeNotifier(ref.watch(sharedPreferencesProvider)),
);

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/design_system/app_theme.dart';
import 'presentation/providers/core_providers.dart';
import 'presentation/providers/theme_provider.dart';
import 'presentation/router/app_router.dart';

/// A device is treated as a phone below this many logical pixels on its
/// **shortest** side.
///
/// Shortest side, not width: it does not change when the device is turned, so
/// the answer to "is this a phone" is the same in both orientations. 600 is the
/// conventional Android breakpoint (`sw600dp`, where the tablet resource
/// buckets begin) and matches what iPads report.
///
/// Deliberately not `Responsive.isTablet`'s 640: that one is about how much
/// room a *layout* has and is measured on the current width, which flips with
/// rotation. Sharing it here would make the lock chase itself.
const double kPhoneShortestSide = 600;

/// Portrait-only on phones; tablets keep every orientation.
///
/// Landscape on a phone buys nothing here — the catalogue is a vertical feed,
/// the checkout is a form, and the product page is a tall column — while the
/// tablet layouts (four and five column grids, the wider slider crop) are
/// designed for a landscape width.
///
/// Done in Dart rather than with `android:screenOrientation="portrait"` in the
/// manifest, because that attribute is per-activity and would pin tablets too.
Future<void> _applyOrientationLock() async {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final size = view.physicalSize / view.devicePixelRatio;
  final isPhone = size.shortestSide < kPhoneShortestSide;

  await SystemChrome.setPreferredOrientations(
    isPhone
        ? const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]
        // Everything, including both landscapes — an empty list would ALSO
        // mean "no preference", but stating it is clearer and survives a
        // hot restart that had previously locked the app.
        : const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ],
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _applyOrientationLock();
  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const TruewayApp(),
    ),
  );
}

class TruewayApp extends ConsumerWidget {
  const TruewayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Trueway Farms',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      // Both themes carry an AppPalette and every screen reads its colours
      // through `context.colors`, so this genuinely switches the whole UI.
      // The status bar follows too — `systemOverlayStyle` is set per theme in
      // AppTheme rather than pinned once at startup, which is why main() no
      // longer calls SystemChrome.setSystemUIOverlayStyle.
      themeMode: ref.watch(themeModeProvider),
      routerConfig: appRouter,
    );
  }
}

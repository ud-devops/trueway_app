import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../widgets/app_logo.dart';

/// Brand splash, and the point where [authProvider] is first read — which
/// restores any persisted Sanctum token + customer and installs the 401 hook on
/// ApiClient. Without this the session would only restore once the Account tab
/// was opened, and a revoked token would never sign the user out.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  /// Minimum hold so a fast restore doesn't flash the brand mark.
  static const _minimumHold = Duration(milliseconds: 1400);

  /// Never block startup on a slow network. The restored session is shown
  /// optimistically and revalidated in the background regardless.
  static const _maximumHold = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final started = DateTime.now();
    // Reading the provider starts session restore.
    ref.read(authProvider);
    await Future<void>.delayed(_minimumHold);

    while (mounted &&
        ref.read(authProvider).isResolving &&
        DateTime.now().difference(started) < _maximumHold) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    // White, not the brand gradient, and white in dark mode too — the native
    // launch window behind this is also white, so a themed splash would flash
    // one colour then the other before the app itself opened onto white.
    //
    // **The logo and nothing else.** No tagline — "Transforming Nature to
    // Natural" is drawn inside the wordmark itself, so a line of type under it
    // said the same thing twice. And no spinner: this screen is up for a fixed
    // 1.4s while the session restores, which is short enough that a progress
    // indicator reads as "something is slow" rather than as reassurance. If the
    // restore does drag, the hold is capped at 4s and the app moves on anyway
    // — see [_maximumHold] — so the spinner never had anything to report.
    return const Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        // `onLightSurface`: this screen is white in both themes (see the build
        // note above), so following the theme would paint the light wordmark
        // onto white and show nothing at all.
        //
        // Sized by width rather than height: the wordmark is wide (500x232), so
        // a fixed height left it small on every phone. 72% keeps a margin
        // either side.
        child: FractionallySizedBox(
          widthFactor: 0.72,
          child: AppLogo(onLightSurface: true),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

/// The Trueway wordmark, in the version that can be seen against the surface
/// behind it.
///
/// The shipped mark is dark green on transparent, so on a dark surface it
/// disappears into the background. `logo_dark.png` is the light-on-transparent
/// cut for exactly that case, and this is the one place that decides between
/// them — a screen that reaches for `Image.asset('assets/images/logo.png')`
/// directly is a screen whose logo vanishes the day someone turns dark mode on.
///
/// The choice follows the **surrounding theme's brightness**, not the platform
/// setting, so a widget deliberately painted on a light surface inside a dark
/// app still gets the dark-on-light mark — see [onLightSurface].
class AppLogo extends StatelessWidget {
  const AppLogo({
    super.key,
    this.height,
    this.width,
    this.alignment = Alignment.center,
    this.onLightSurface = false,
  });

  final double? height;
  final double? width;
  final Alignment alignment;

  /// Forces the dark-on-transparent mark regardless of theme.
  ///
  /// For a surface that is white whatever the theme says — the splash screen is
  /// the one in this app — where following the theme would paint a white
  /// wordmark onto white.
  final bool onLightSurface;

  /// Dark green on transparent. For light surfaces.
  static const String lightAsset = 'assets/images/logo.png';

  /// The light cut, for dark surfaces.
  static const String darkAsset = 'assets/images/logo_dark.png';

  /// Which file a given brightness needs.
  static String assetFor(Brightness brightness) =>
      brightness == Brightness.dark ? darkAsset : lightAsset;

  @override
  Widget build(BuildContext context) => Image.asset(
        onLightSurface
            ? lightAsset
            : assetFor(Theme.of(context).brightness),
        height: height,
        width: width,
        alignment: alignment,
        // Both files are the same artwork at different sizes (500x232 and
        // 2000x928), so either scales cleanly to the height asked for.
        fit: BoxFit.contain,
      );
}

/// The wordmark picks its own cut.
///
/// The shipped mark is dark green on transparent, so on a dark surface it is
/// invisible — which is the bug this widget exists to make impossible.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/presentation/widgets/app_logo.dart';

String _assetOf(WidgetTester tester) =>
    (tester.widget<Image>(find.byType(Image)).image as AssetImage).assetName;

Future<void> _pump(WidgetTester tester, ThemeData theme, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(theme: theme, home: Scaffold(body: child)),
  );
  await tester.pump();
}

void main() {
  testWidgets('takes the dark-on-light mark under the light theme',
      (tester) async {
    await _pump(tester, AppTheme.light, const AppLogo(height: 44));

    expect(_assetOf(tester), AppLogo.lightAsset);
  });

  testWidgets('takes the light mark under the dark theme', (tester) async {
    await _pump(tester, AppTheme.dark, const AppLogo(height: 44));

    expect(_assetOf(tester), AppLogo.darkAsset);
  });

  // The splash is white in both themes by design, so it is the one caller that
  // must not follow the theme — the light mark on white shows nothing.
  testWidgets('onLightSurface keeps the dark mark even in the dark theme',
      (tester) async {
    await _pump(
      tester,
      AppTheme.dark,
      const AppLogo(height: 92, onLightSurface: true),
    );

    expect(_assetOf(tester), AppLogo.lightAsset);
  });

  test('brightness maps to the matching file', () {
    expect(AppLogo.assetFor(Brightness.light), AppLogo.lightAsset);
    expect(AppLogo.assetFor(Brightness.dark), AppLogo.darkAsset);
    expect(AppLogo.lightAsset, isNot(AppLogo.darkAsset));
  });
}

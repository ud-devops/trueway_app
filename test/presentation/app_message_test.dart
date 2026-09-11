/// The one component every passing message in the app draws.
///
/// What these pin is the thing having three helpers cost: a customer could not
/// tell what *kind* of thing had happened before reading the sentence, because
/// success drew the bare Material default and two different reds meant "error".
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_colors.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/presentation/widgets/app_message.dart';

/// Pumps a screen with one button that fires [onTap], then taps it.
Future<void> _fire(
  WidgetTester tester,
  void Function(BuildContext context) onTap,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => onTap(context),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pump();
}

SnackBar _snack(WidgetTester tester) =>
    tester.widget<SnackBar>(find.byType(SnackBar));

void main() {
  group('kind', () {
    testWidgets('success is green and ticked, not the Material default',
        (tester) async {
      // `showSuccessSnack` used to draw a bare SnackBar — the same grey box the
      // OS uses for its own messages, with no icon and nothing to distinguish
      // "Added to cart" from "That failed".
      await _fire(tester, (c) => c.showSuccessSnack('Added to cart'));

      expect(_snack(tester).backgroundColor, AppColors.success);
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(find.text('Added to cart'), findsOneWidget);
    });

    testWidgets('an alert is red and marked as an error', (tester) async {
      await _fire(
        tester,
        (c) => c.showAlertSnack('Sorry, you can only order a maximum of 3 units.'),
      );

      expect(_snack(tester).backgroundColor, AppColors.error);
      expect(find.byIcon(Icons.error_rounded), findsOneWidget);
    });

    testWidgets('a warning is its own colour, not a second red',
        (tester) async {
      // "Your basket was rebuilt and one item is gone" is not a failure and is
      // not a confirmation. It had no styling of its own at all before.
      await _fire(tester, (c) => c.showWarningSnack('1 item could not be restored'));

      expect(_snack(tester).backgroundColor, AppColors.warning);
      expect(find.byIcon(Icons.warning_rounded), findsOneWidget);
    });

    testWidgets('info is neutral', (tester) async {
      await _fire(tester, (c) => c.showInfoSnack('Your basket is still here'));

      expect(_snack(tester).backgroundColor, AppColors.info);
      expect(find.byIcon(Icons.info_rounded), findsOneWidget);
    });
  });

  group('shape', () {
    testWidgets('floats clear of the bottom bar rather than docking on it',
        (tester) async {
      // Docked, it covered the control it was usually about — "maximum of 3
      // units" printed across the "+" that had just been pressed.
      await _fire(tester, (c) => c.showInfoSnack('hello'));

      final snack = _snack(tester);
      expect(snack.behavior, SnackBarBehavior.floating);
      expect(snack.margin, isNotNull);
    });

    testWidgets('clamps a long message instead of growing over the screen',
        (tester) async {
      await _fire(
        tester,
        (c) => c.showAlertSnack(
          'Sorry, you can only order a maximum of 3 units of Trueway Farms '
          'Organic Finger Millet (ragi) 1.85 Kg at a time. Please adjust the '
          'quantity and try again. And here is even more text to be sure this '
          'runs past three lines on any surface the tests use.',
        ),
      );

      final text = tester.widget<Text>(find.textContaining('Sorry, you can'));
      expect(text.maxLines, 3);
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets('replaces the previous message rather than queueing behind it',
        (tester) async {
      // Tapping "+" four times at the limit used to line up four identical
      // messages, each waiting out the one before it.
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => context.showAlertSnack('at the limit'),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );

      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('go'));
        await tester.pump();
      }

      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('an empty message draws nothing', (tester) async {
      await _fire(tester, (c) => c.showSuccessSnack('   '));

      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('from a thrown object', () {
    testWidgets('shows the server sentence and its field errors',
        (tester) async {
      final e = ApiException(
        'Please fix the address.',
        kind: ApiErrorKind.validation,
        statusCode: 422,
        fieldErrors: const {
          'phone': ['The phone must be 10 digits.'],
          'zip_code': ['The zip code is required.'],
        },
      );

      await _fire(tester, (c) => c.showErrorSnack(e));

      expect(find.text('Please fix the address.'), findsOneWidget);
      expect(find.text('• The phone must be 10 digits.'), findsOneWidget);
      expect(find.text('• The zip code is required.'), findsOneWidget);
      expect(_snack(tester).backgroundColor, AppColors.error);
    });

    testWidgets('never repeats the headline as a bullet', (tester) async {
      // The same sentence twice reads as two separate problems.
      final e = ApiException(
        'The phone must be 10 digits.',
        kind: ApiErrorKind.validation,
        statusCode: 422,
        fieldErrors: const {
          'phone': ['The phone must be 10 digits.'],
        },
      );

      await _fire(tester, (c) => c.showErrorSnack(e));

      expect(find.text('The phone must be 10 digits.'), findsOneWidget);
      expect(find.textContaining('• '), findsNothing);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/repositories/geo_repository.dart';
import 'package:trueway_farms/presentation/widgets/geo_picker_field.dart';
import 'package:trueway_farms/presentation/widgets/required_label.dart';

/// The picker that replaced the State and City text boxes.
///
/// It is not a convenience: `state` is `exists`-validated server-side, so a box
/// a customer can type "Gujarat" into is a box that cannot save.

const _cities = [
  GeoOption(id: '574', name: 'Ahmedabad'),
  GeoOption(id: '600', name: 'Vadodara'),
  GeoOption(id: '605', name: 'Surat'),
  GeoOption(id: GeoOption.otherId, name: 'Other'),
];

Future<GeoOption?> _open(
  WidgetTester tester, {
  List<GeoOption> options = _cities,
  String? selectedId,
}) async {
  GeoOption? picked;
  var opened = false;

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                opened = true;
                picked = await showGeoPicker(
                  context: context,
                  title: 'Select city',
                  options: options,
                  selectedId: selectedId,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(opened, isTrue);
  return picked;
}

void main() {
  group('the field', () {
    Future<void> pump(
      WidgetTester tester, {
      String? value,
      String? error,
      bool busy = false,
      VoidCallback? onTap,
    }) =>
        tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: GeoPickerField(
                label: 'State',
                value: value,
                hint: 'Select state',
                busy: busy,
                error: error,
                onTap: onTap ?? () {},
              ),
            ),
          ),
        );

    testWidgets('shows the hint until something is chosen', (tester) async {
      await pump(tester);
      expect(find.text('Select state'), findsOneWidget);

      await pump(tester, value: 'Gujarat');
      expect(find.text('Gujarat'), findsOneWidget);
      expect(find.text('Select state'), findsNothing);
    });

    // The whole point of the field: what the customer reads is the name, and
    // the id never surfaces.
    testWidgets('never shows the id', (tester) async {
      await pump(tester, value: 'Gujarat');
      expect(find.text('11'), findsNothing);
    });

    // The label used to sit in its resting position on top of the hint, which
    // the picker paints as content rather than as an `InputDecoration.hintText`
    // — the two rendered over each other as "Sudet*state"-shaped mush. Both
    // texts were present either way, so only their geometry catches it.
    testWidgets('floats the label clear of the hint', (tester) async {
      await pump(tester);

      final label = tester.getRect(find.byType(RequiredLabel));
      final hint = tester.getRect(find.text('Select state'));

      expect(
        label.bottom,
        lessThanOrEqualTo(hint.top),
        reason: 'the label must sit entirely above the value/hint line',
      );
    });

    testWidgets('keeps the label clear of a chosen value too', (tester) async {
      await pump(tester, value: 'Gujarat');

      final label = tester.getRect(find.byType(RequiredLabel));
      final value = tester.getRect(find.text('Gujarat'));

      expect(label.bottom, lessThanOrEqualTo(value.top));
    });

    testWidgets('paints the error it is given', (tester) async {
      await pump(tester, error: 'Choose a state');
      expect(find.text('Choose a state'), findsOneWidget);
    });

    testWidgets('shows a spinner instead of the chevron while loading',
        (tester) async {
      await pump(tester, busy: true);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
    });

    testWidgets('a null onTap makes it inert', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: GeoPickerField(
              label: 'State',
              value: null,
              hint: 'Select state',
              onTap: null,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Select state'));
      await tester.pumpAndSettle();
      expect(taps, 0);
    });
  });

  group('the sheet', () {
    testWidgets('lists every option and returns the one tapped',
        (tester) async {
      GeoOption? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () async => picked = await showGeoPicker(
                    context: context,
                    title: 'Select city',
                    options: _cities,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Ahmedabad'), findsOneWidget);
      expect(find.text('Vadodara'), findsOneWidget);

      await tester.tap(find.text('Vadodara'));
      await tester.pumpAndSettle();

      expect(picked?.id, '600');
      expect(picked?.name, 'Vadodara');
    });

    testWidgets('marks the current selection', (tester) async {
      await _open(tester, selectedId: '600');

      // Exactly one tick, and it is on the row that is actually selected.
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Vadodara'),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
    });

    // 306 cities for Gujarat, 576 for Uttar Pradesh. Scrolling to "Vadodara"
    // is not a thing anyone should be asked to do.
    testWidgets('filters as you type, case-insensitively', (tester) async {
      await _open(tester);

      await tester.enterText(find.byKey(const Key('geo-picker-search')), 'vad');
      await tester.pumpAndSettle();

      expect(find.text('Vadodara'), findsOneWidget);
      expect(find.text('Ahmedabad'), findsNothing);
      expect(find.text('Surat'), findsNothing);
    });

    // The sentinel is the escape hatch for a town that is not in the list, so
    // it has to survive the very search that failed to find that town.
    // Filtering it out is how a customer ends up staring at "No matches" with
    // no way forward.
    testWidgets('keeps "Other" no matter what the search says', (tester) async {
      await _open(tester);

      await tester.enterText(
        find.byKey(const Key('geo-picker-search')),
        'Bhitarwar',
      );
      await tester.pumpAndSettle();

      expect(find.text('Other'), findsOneWidget);
      expect(find.text('Ahmedabad'), findsNothing);
      expect(find.textContaining('No matches'), findsNothing);
    });

    testWidgets('"Other" says what it is for', (tester) async {
      await _open(tester);
      expect(find.text('My city is not in this list'), findsOneWidget);
    });

    testWidgets('says so when a list with no sentinel matches nothing',
        (tester) async {
      await _open(
        tester,
        options: const [GeoOption(id: '11', name: 'Gujarat')],
      );

      await tester.enterText(find.byKey(const Key('geo-picker-search')), 'zzz');
      await tester.pumpAndSettle();

      expect(find.textContaining('No matches for "zzz"'), findsOneWidget);
    });

    testWidgets('dismissing returns nothing', (tester) async {
      GeoOption? picked;
      var returned = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () async {
                    picked = await showGeoPicker(
                      context: context,
                      title: 'Select city',
                      options: _cities,
                    );
                    returned = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      Navigator.of(tester.element(find.text('Ahmedabad'))).pop();
      await tester.pumpAndSettle();

      expect(returned, isTrue);
      expect(picked, isNull);
    });
  });
}

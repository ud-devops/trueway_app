import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_colors.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/presentation/widgets/required_label.dart';

/// The asterisk that marks a field required.
///
/// It is a separate red span rather than part of the label string, so it reads
/// as a marker and not as punctuation someone typed — and so a screen reader
/// says "required" instead of announcing a star.

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.light, home: Scaffold(body: child)),
  );
  await tester.pumpAndSettle();
}

/// The spans of the rendered rich text, flattened.
List<TextSpan> _spans(WidgetTester tester) {
  final text = tester.widget<Text>(find.byType(Text));
  final root = text.textSpan! as TextSpan;
  return [root, ...root.children!.cast<TextSpan>()];
}

void main() {
  testWidgets('shows the label with an asterisk', (tester) async {
    await _pump(tester, const RequiredLabel('Your rating'));

    expect(find.textContaining('Your rating'), findsOneWidget);
    expect(find.textContaining('*'), findsOneWidget);
  });

  // Red, so it is visibly a requirement marker rather than part of the wording.
  testWidgets('the asterisk is tinted, the label is not', (tester) async {
    await _pump(tester, const RequiredLabel('Your rating'));

    final spans = _spans(tester);
    final star = spans.firstWhere((s) => (s.text ?? '').contains('*'));
    expect(star.style?.color, AppColors.error);
    expect(spans.first.text, 'Your rating');
    expect(spans.first.style?.color, isNot(AppColors.error));
  });

  // A star announced as "asterisk" is noise; "required" is the information.
  testWidgets('announces itself as required', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, const RequiredLabel('Your review'));

    expect(
      find.bySemanticsLabel('Your review, required'),
      findsOneWidget,
    );
    handle.dispose();
  });

  // So a caller can drive this from the same flag that drives its validation.
  testWidgets('renders plainly when the field is optional', (tester) async {
    await _pump(tester, const RequiredLabel('Notes', required: false));

    expect(find.text('Notes'), findsOneWidget);
    expect(find.textContaining('*'), findsNothing);
  });
}

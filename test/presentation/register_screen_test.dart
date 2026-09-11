import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/screens/auth/register_screen.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';

Future<void> _pumpRegister(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const RegisterScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every label on this form is a [RequiredLabel], i.e. a `Text.rich` carrying
/// the field name and a red ` *` span — so a plain `find.text` matches none of
/// them. `findRichText` looks inside the spans instead.
Finder _field(String label) => find.ancestor(
      of: find.textContaining(label, findRichText: true),
      matching: find.byType(TextFormField),
    );

/// A throwaway value that satisfies the form's rules.
///
/// This used to be a real customer account's real password, which had no
/// business being in the repository: these tests only type into a form field,
/// so the string never authenticates against anything and any valid-shaped
/// password does the job.
const _password = 'Str0ng!Pass';

/// Deliberately a *different* valid password, for the case where editing the
/// first field must re-fault an already-matching confirmation.
const _editedPassword = 'Str0ng!Passw';

void main() {
  group('live validation', () {
    // Regression: the password field used to call `_form.validate()`, which
    // validated EVERY field — so "Passwords don't match" appeared while the
    // customer was still typing the first password, before they had reached
    // the confirmation field at all.
    testWidgets('typing a password does not fault the untouched confirm field',
        (tester) async {
      await _pumpRegister(tester);

      await tester.enterText(_field('Password'), _password);
      await tester.pumpAndSettle();

      expect(find.text("Passwords don't match"), findsNothing);
      expect(find.text('Re-enter your password'), findsNothing);
    });

    testWidgets('a mismatched confirmation is reported once it is typed',
        (tester) async {
      await _pumpRegister(tester);

      await tester.enterText(_field('Password'), _password);
      await tester.enterText(_field('Confirm password'), 'Abcd@12');
      await tester.pumpAndSettle();

      expect(find.text("Passwords don't match"), findsOneWidget);
    });

    testWidgets('the mismatch clears once the confirmation matches',
        (tester) async {
      await _pumpRegister(tester);

      await tester.enterText(_field('Password'), _password);
      await tester.enterText(_field('Confirm password'), 'wrong');
      await tester.pumpAndSettle();
      expect(find.text("Passwords don't match"), findsOneWidget);

      await tester.enterText(_field('Confirm password'), _password);
      await tester.pumpAndSettle();
      expect(find.text("Passwords don't match"), findsNothing);
    });

    // Editing the password after the confirmation is filled must re-check it,
    // or a stale "matching" state would survive until submit.
    testWidgets('editing the password re-checks a filled confirmation',
        (tester) async {
      await _pumpRegister(tester);

      await tester.enterText(_field('Password'), _password);
      await tester.enterText(_field('Confirm password'), _password);
      await tester.pumpAndSettle();
      expect(find.text("Passwords don't match"), findsNothing);

      await tester.enterText(_field('Password'), _editedPassword);
      await tester.pumpAndSettle();
      expect(find.text("Passwords don't match"), findsOneWidget);
    });

    testWidgets('nothing is faulted on a freshly opened form', (tester) async {
      await _pumpRegister(tester);

      expect(find.text("Passwords don't match"), findsNothing);
      expect(find.text('Enter your name'), findsNothing);
      expect(find.text('Enter a valid email address'), findsNothing);
      expect(find.text('Enter a valid 10-digit mobile'), findsNothing);
    });
  });

  group('field-level messages', () {
    testWidgets('a name with digits explains the rule', (tester) async {
      await _pumpRegister(tester);

      await tester.enterText(_field('Full name'), 'Asha123');
      await tester.pumpAndSettle();

      expect(
        find.text('Use letters only — no numbers or symbols'),
        findsOneWidget,
      );
    });

    testWidgets('a malformed email is reported as typed', (tester) async {
      await _pumpRegister(tester);

      await tester.enterText(_field('Email address'), 'not-an-email');
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid email address'), findsOneWidget);
    });

    testWidgets('a short mobile number is reported as typed', (tester) async {
      await _pumpRegister(tester);

      await tester.enterText(_field('Mobile number'), '98765');
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid 10-digit mobile'), findsOneWidget);
    });

    // The password validator reports one unmet rule at a time so the customer
    // can fix them in order rather than facing the whole list.
    testWidgets('the password reports the specific unmet rule', (tester) async {
      await _pumpRegister(tester);

      await tester.enterText(_field('Password'), 'abc');
      await tester.pumpAndSettle();
      expect(find.text('Use at least 8 characters'), findsOneWidget);

      await tester.enterText(_field('Password'), 'abcdefgh');
      await tester.pumpAndSettle();
      expect(find.text('Add an uppercase letter (A–Z)'), findsOneWidget);

      await tester.enterText(_field('Password'), 'Abcdefgh');
      await tester.pumpAndSettle();
      expect(find.textContaining('Add a special character'), findsOneWidget);

      await tester.enterText(_field('Password'), 'Abcd@efgh');
      await tester.pumpAndSettle();
      expect(find.textContaining('Add a'), findsNothing);
    });
  });

  testWidgets('the country code is visible before the field is focused',
      (tester) async {
    // prefixText only paints on focus, which is why this needed a prefixIcon.
    await _pumpRegister(tester);
    expect(find.text('+91'), findsOneWidget);
  });
}

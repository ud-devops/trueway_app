/// The GST invoice form.
///
/// The regression it exists for: the cart used to ask for a GSTIN and nothing
/// else, and `ec_order_tax_information` cannot be written from a GSTIN alone —
/// `company_name`, `company_address`, `company_tax_code` and `company_email`
/// are all `required_if:with_tax_information,1` in the `CheckoutRequest` the
/// mobile endpoint shares with the website, and one `create()` writes all four.
/// So "a code on its own is refused" is the point of the whole change.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/tax_information.dart';
import 'package:trueway_farms/presentation/widgets/tax_information_sheet.dart';

TaxInformationSheetResult? _result;

/// Opens the sheet the way the cart does, and records what it closed with.
Future<void> _open(WidgetTester tester, {TaxInformation? initial}) async {
  _result = null;
  // The form is four fields plus a button; the default 800x600 test window
  // leaves the last of them off-screen and `tap` will not touch what it cannot
  // hit.
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              _result = await showTaxInformationSheet(context,
                  initial: initial,);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester, {String? taxCode}) async {
  await tester.enterText(
    find.byKey(const Key('tax-company-name')),
    'Uminber India Pvt Ltd',
  );
  await tester.enterText(
    find.byKey(const Key('tax-company-address')),
    '306, Jahnavi Arcade, Ahmedabad',
  );
  await tester.enterText(
    find.byKey(const Key('tax-company-tax-code')),
    taxCode ?? '27AAPFU0939F1Z5',
  );
  await tester.enterText(
    find.byKey(const Key('tax-company-email')),
    'billing@uminber.in',
  );
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('tax-save')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a GSTIN on its own is refused, and the sheet stays open',
      (tester) async {
    await _open(tester);

    await tester.enterText(
      find.byKey(const Key('tax-company-tax-code')),
      '27AAPFU0939F1Z5',
    );
    await _save(tester);

    // Still up, with the other three named.
    expect(find.byKey(const Key('tax-save')), findsOneWidget);
    expect(_result, isNull);
    expect(find.text('Enter the company name'), findsOneWidget);
    expect(find.text('Enter the company address'), findsOneWidget);
    expect(find.text('Enter the company email'), findsOneWidget);
    // ...and not the one field that was filled in.
    expect(find.text('Enter your GSTIN'), findsNothing);
  });

  testWidgets('nothing is marked wrong before the first save attempt',
      (tester) async {
    // Four red boxes on an untouched form reads as four things already broken
    // rather than a form waiting to be filled.
    await _open(tester);

    expect(find.text('Enter the company name'), findsNothing);
    expect(find.text('Enter your GSTIN'), findsNothing);
  });

  testWidgets('all four saves, and the code comes back uppercased',
      (tester) async {
    await _open(tester);
    await _fill(tester, taxCode: '27aapfu0939f1z5');
    await _save(tester);

    expect(_result, isNotNull);
    expect(_result!.removed, isFalse);
    final info = _result!.information!;
    expect(info.companyTaxCode, '27AAPFU0939F1Z5');
    expect(info.companyName, 'Uminber India Pvt Ltd');
    expect(info.violations(), isEmpty);
    expect(info.toJson().keys, TaxField.all);
  });

  testWidgets('a malformed GSTIN is caught even with everything else filled',
      (tester) async {
    await _open(tester);
    // Fits the server's own `min:3|max:20` and is still not a GSTIN.
    await _fill(tester, taxCode: 'AAA');
    await _save(tester);

    expect(_result, isNull);
    expect(find.text('Enter a valid 15-character GSTIN'), findsOneWidget);
  });

  group('editing an existing block', () {
    final existing = TaxInformation(
      companyName: 'Uminber India Pvt Ltd',
      companyAddress: '306, Jahnavi Arcade, Ahmedabad',
      companyTaxCode: '27AAPFU0939F1Z5',
      companyEmail: 'billing@uminber.in',
    );

    testWidgets('opens prefilled rather than blank', (tester) async {
      // Correcting a typo in the company address must not mean re-entering all
      // four fields.
      await _open(tester, initial: existing);

      expect(find.text('Uminber India Pvt Ltd'), findsOneWidget);
      expect(find.text('27AAPFU0939F1Z5'), findsOneWidget);
    });

    testWidgets('offers Remove, which a blank form does not', (tester) async {
      await _open(tester, initial: existing);
      expect(find.byKey(const Key('tax-remove')), findsOneWidget);

      await tester.tap(find.byKey(const Key('tax-remove')));
      await tester.pumpAndSettle();

      expect(_result!.removed, isTrue);
      expect(_result!.information, isNull);
    });

    testWidgets('a fresh sheet has nothing to remove', (tester) async {
      await _open(tester);
      expect(find.byKey(const Key('tax-remove')), findsNothing);
    });
  });
}

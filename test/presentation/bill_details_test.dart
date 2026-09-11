/// The bill card's shape: the wave, the band, and that neither overflows.
///
/// The wave is not decoration. A bill is a column of numbers the customer is
/// checking, and the torn edge says *the checking stops here* — what follows
/// is not another charge. A straight rule said "one more row".
///
/// The layout half of this file exists because the first cut of the card
/// painted past its own edge: the amount was two bare `Text`s at the end of a
/// `Row`, so nothing could shrink them and the label was squeezed towards zero
/// behind them — 18px over on a 320dp screen at NORMAL text size, 130px at
/// 1.5x. Every combination below is checked for that, because a bill that
/// spills over its card is the one place in the app a customer will not
/// forgive.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/presentation/widgets/bill_details.dart';

/// The worst case the live account produces: a struck-through figure, a chip,
/// a note naming a 13-character coupon, and four-digit amounts.
Widget _bill() => const BillCard(
      rows: [
        BillRow(
          icon: BillIcons.items,
          label: 'Item total',
          was: '₹1,257.90',
          saved: 'Saved ₹190.00',
          note: 'Includes ₹100.00 off with HNHPQ2YWQJD0',
          value: '₹1,067.90',
        ),
        BillRow(icon: BillIcons.tax, label: 'GST', value: '+ ₹30.45'),
        BillRow(icon: BillIcons.shipping, label: 'Shipping', value: 'FREE'),
      ],
      total: BillTotalRow(label: 'To pay', value: '₹1,098.35'),
      savings: BillSavings(
        amount: '₹190.00',
        note: 'Plus free delivery on this order',
      ),
    );

Future<void> _pump(WidgetTester tester, double width, double scale) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [_bill()],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A bill with amounts of visibly different widths — the shape that made the
/// misalignment obvious — including the Total and the savings band, which sit
/// outside the charge rows and have to agree with them anyway.
Future<void> _pumpLedger(
  WidgetTester tester,
  double width,
  double scale,
) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: const [
              BillCard(
                rows: [
                  BillRow(
                    icon: BillIcons.items,
                    label: 'Item total',
                    value: '₹1,665.10',
                  ),
                  BillRow(
                    icon: BillIcons.coupon,
                    label: 'Discount (HNHPQ2YWQJD0)',
                    value: '- ₹832.55',
                  ),
                  BillRow(
                    icon: BillIcons.shipping,
                    label: 'Shipping',
                    value: '₹118.00',
                  ),
                  BillRow(
                    icon: BillIcons.tax,
                    label: 'GST',
                    value: '+ ₹41.63',
                  ),
                ],
                total: BillTotalRow(label: 'Total', value: '₹992.18'),
                savings: BillSavings(amount: '₹832.55'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('it lays out', () {
    for (final width in const [320.0, 360.0, 412.0]) {
      for (final scale in const [1.0, 1.5, 2.0]) {
        testWidgets('at ${width.toInt()}dp, ${scale}x text', (tester) async {
          await _pump(tester, width, scale);

          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('one composition, everywhere', () {
    // [BillCard] and [BillRow] made the *parts* shared; this group is about the
    // half that had actually drifted. The basket, checkout and a placed order
    // each built their own column of rows, in their own order, with their own
    // labels — so one tap apart the same order described its own discount two
    // ways: folded into the item row behind a "Saved" chip on one screen, a
    // line of its own on the next. Nothing told the customer that was a styling
    // choice rather than a different charge.
    Future<void> pumpTerms(WidgetTester tester, BillTerms terms) async {
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [OrderBillCard(terms: terms)],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    const full = BillTerms(
      itemTotal: '₹1,665.10',
      discount: '₹832.55',
      couponCode: 'HNHPQ2YWQJD0',
      shipping: '₹118.00',
      tax: '+ ₹41.63',
      paymentFee: '₹10.00',
      total: '₹1,002.18',
      savings: '₹832.55',
    );

    testWidgets('the rows come in one order', (tester) async {
      await pumpTerms(tester, full);

      double y(String label) => tester.getTopLeft(find.text(label)).dy;

      expect(y('Item total'), lessThan(y('Discount (HNHPQ2YWQJD0)')));
      expect(y('Discount (HNHPQ2YWQJD0)'), lessThan(y('Shipping')));
      expect(y('Shipping'), lessThan(y('GST')));
      expect(y('GST'), lessThan(y('Payment fee')));
      expect(y('Payment fee'), lessThan(y('Total')));
    });

    testWidgets('the discount gets a line, named by its coupon',
        (tester) async {
      // Not a "Saved" chip on the item row. The server sends ONE discount
      // figure and no coupon-only amount, so this is the only place the code
      // can appear without inventing a second deduction.
      await pumpTerms(tester, full);

      expect(find.text('Discount (HNHPQ2YWQJD0)'), findsOneWidget);
      expect(find.text('- ₹832.55'), findsOneWidget);
      expect(find.textContaining('Saved'), findsNothing);
    });

    testWidgets('a term the payload did not carry gets no row',
        (tester) async {
      // A fee of nothing and a fee nobody mentioned are different things, and
      // printing ₹0.00 for the second is the app answering a question the
      // server did not.
      await pumpTerms(
        tester,
        const BillTerms(itemTotal: '₹599.00', total: '₹599.00'),
      );

      expect(find.text('Item total'), findsOneWidget);
      for (final absent in const [
        'Discount',
        'Shipping',
        'GST',
        'Payment fee',
      ]) {
        expect(find.text(absent), findsNothing, reason: absent);
      }
      expect(
        find.byKey(const Key('bill-savings')),
        findsNothing,
        reason: 'this bill passed no savings figure at all',
      );
    });

    testWidgets('the wave is there even when nothing was saved',
        (tester) async {
      // The band closes the card. Hiding it on an undiscounted basket made the
      // same card look designed on the order screen and unfinished on the
      // basket one tap away — which is the exact inconsistency that sharing the
      // composition was meant to end. The client's reference prints
      // "Your total savings ₹0.00" for the same reason.
      await pumpTerms(
        tester,
        const BillTerms(
          itemTotal: '₹899.00',
          tax: '+ ₹44.95',
          totalLabel: 'Subtotal',
          total: '₹943.95',
          savings: '₹0.00',
        ),
      );

      expect(find.byKey(const Key('bill-savings')), findsOneWidget);
      expect(find.text('Your total savings'), findsOneWidget);
      expect(find.text('₹0.00'), findsOneWidget);
    });

    testWidgets('the total carries whatever the screen calls it',
        (tester) async {
      // Checkout says "Subtotal" until a courier has quoted, so the figure
      // cannot be read as the amount due.
      await pumpTerms(
        tester,
        const BillTerms(
          itemTotal: '₹599.00',
          total: '₹599.00',
          totalLabel: 'Subtotal',
        ),
      );

      expect(find.text('Subtotal'), findsOneWidget);
      expect(find.text('Total'), findsNothing);
    });

    testWidgets('a screen that numbered its sections can drop the heading',
        (tester) async {
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: OrderBillCard(
              showTitle: false,
              terms: BillTerms(itemTotal: '₹599.00', total: '₹599.00'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bill details'), findsNothing);
      expect(find.text('Item total'), findsOneWidget);
    });
  });

  group('every amount shares one right edge', () {
    // The bug this pins: the amount slot was a *loose* `Flexible`, so it sized
    // to the digits inside it and `WrapAlignment.end` had no leftover space to
    // push against. Each amount started just after the label column and ended
    // wherever its own digits ran out — ₹1,665.10 reaching further right than
    // + ₹41.63 — while the Total below, which spans the full width, really was
    // flush. The column of figures read as crooked, which on a bill is the one
    // thing it must not.
    //
    // Checked across widths and text scales because the split is a flex ratio:
    // a ratio that right-aligns at 1x and lets a long amount wrap out of its
    // slot at 2x would put the raggedness back only for the customers least
    // able to read it.
    for (final width in const [320.0, 360.0, 412.0]) {
      for (final scale in const [1.0, 1.5, 2.0]) {
        testWidgets('at ${width.toInt()}dp, ${scale}x text', (tester) async {
          await _pumpLedger(tester, width, scale);

          final edges = [
            for (final amount in const [
              '₹1,665.10',
              '- ₹832.55',
              '₹118.00',
              '+ ₹41.63',
              '₹992.18', // the Total
              '₹832.55', // the savings band
            ])
              tester.getRect(find.text(amount)).right,
          ];

          for (final edge in edges) {
            expect(
              edge,
              closeTo(edges.first, 0.51),
              reason: 'amounts at $edges are not one column',
            );
          }
        });
      }
    }
  });

  group('the band', () {
    testWidgets('runs edge to edge and closes the card', (tester) async {
      // Both matter to the wave. Inset, it would read as a graphic sitting on
      // the card rather than as the card's own torn edge; short of the bottom,
      // it would leave a white strip under it.
      await _pump(tester, 360, 1);

      final card = tester.getRect(find.byKey(const Key('bill-details')));
      final band = tester.getRect(find.byKey(const Key('bill-savings')));

      // 1dp of slack each side: AppCard draws a hairline border and the band
      // sits inside it.
      expect((band.width - card.width).abs(), lessThanOrEqualTo(2.01));
      expect((band.bottom - card.bottom).abs(), lessThanOrEqualTo(1.01));
    });

    testWidgets('is absent when there is nothing saved', (tester) async {
      tester.view.physicalSize = const Size(360, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BillCard(
              rows: [BillRow(label: 'Item total', value: '₹609.00')],
              total: BillTotalRow(label: 'To pay', value: '₹609.00'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('bill-details')), findsOneWidget);
      expect(find.byKey(const Key('bill-savings')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('a row', () {
    testWidgets('shows the struck-through figure beside the live one',
        (tester) async {
      await _pump(tester, 412, 1);

      expect(find.text('₹1,257.90'), findsOneWidget, reason: 'was');
      expect(find.text('₹1,067.90'), findsOneWidget, reason: 'value');
      expect(find.text('Saved ₹190.00'), findsOneWidget, reason: 'chip');
    });

    testWidgets('names the coupon rather than hiding it in the chip',
        (tester) async {
      // The chip says how much came off; only the note says what did it, and
      // the coupon is the customer's own doing — the thing they went looking
      // for when they opened the bill.
      await _pump(tester, 412, 1);

      expect(
        find.text('Includes ₹100.00 off with HNHPQ2YWQJD0'),
        findsOneWidget,
      );
    });
  });
}

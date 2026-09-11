/// The order summary that stands in for an invoice before delivery.
///
/// The invoice is a delivery document in this shop — the button appears only
/// once the parcel has arrived, because the PDF is the tax invoice for a
/// completed sale. Everything before that had no record at all, which is what
/// this screen fixes. It is deliberately NOT an invoice: no invoice number,
/// nothing to download, and it never uses the word.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/order.dart';
import 'package:trueway_farms/data/repositories/order_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/screens/orders/order_summary_screen.dart';

/// Order 329 as the server returns it, trimmed to what this screen reads.
Map<String, dynamic> _order({Map<String, dynamic> extra = const {}}) => {
      'id': 329,
      'code': 'SF10000329',
      'created_at': '2026-08-25T15:30:09+05:30',
      'status': {'value': 'processing', 'label': 'Processing'},
      'shipping_status': {'value': 'approved', 'label': 'Approved'},
      'shipping_company_name': 'Xpressbees Surface 5kg',
      'payment_method': {'value': 'razorpay', 'label': 'Razorpay'},
      'payment_status': {'value': 'completed', 'label': 'Completed'},
      'amount': '1793.19',
      'amount_formatted': '₹1,793.19',
      'sub_total': '1457.09',
      'sub_total_formatted': '₹1,457.09',
      'shipping_amount': '336.10',
      'shipping_amount_formatted': '₹336.10',
      'tax_amount': '0.00',
      'discount_amount': '0.00',
      'payment_fee': '0.00',
      'shipping_info': {
        'name': 'Akash',
        'phone': '9644105947',
        'address': 'XIDGD XJD DJSCSOF SJS',
        'city': 'Ahmedabad',
        'state': 'Gujarat',
        'country': 'India',
        'zip_code': '382350',
      },
      'products': [
        {
          'id': 901,
          'product_id': 118,
          'product_name': 'Trueway Farms Organic Pure Honey',
          'quantity': 2,
          'total': '1457.09',
          'total_formatted': '₹1,457.09',
        },
      ],
      ...extra,
    };

class _FakeRepo implements OrderRepository {
  _FakeRepo(this.payload);

  final Map<String, dynamic> payload;

  @override
  Future<Order> order(int id) async => Order.fromJson(payload);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  double width = 400,
}) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        orderRepositoryProvider.overrideWithValue(_FakeRepo(payload)),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const OrderSummaryScreen(orderId: 329),
      ),
    ),
  );
  // Not pumpAndSettle: the product images keep a placeholder spinner turning
  // under the test binding, so settling never returns.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('it identifies the order the way the reference does',
      (tester) async {
    await _pump(tester, _order());

    expect(find.text('Order Summary'), findsWidgets, reason: 'title + block');
    expect(find.textContaining('Order placed'), findsOneWidget);
    // The heading is on the page, not only in the AppBar: this page gets
    // screenshotted, and a screenshot loses the AppBar.
    expect(find.byKey(const Key('summary-order-number')), findsOneWidget);
    expect(find.text('Order number SF10000329'), findsOneWidget);
  });

  testWidgets('the three blocks are all present', (tester) async {
    await _pump(tester, _order());

    expect(find.byKey(const Key('summary-ship-to')), findsOneWidget);
    expect(find.byKey(const Key('summary-payment')), findsOneWidget);
    expect(find.byKey(const Key('summary-money')), findsOneWidget);

    expect(find.text('Akash'), findsOneWidget);
    expect(
      find.text('XIDGD XJD DJSCSOF SJS'),
      findsOneWidget,
      reason: 'the street line keeps its own commas',
    );
    expect(
      find.text('Ahmedabad, Gujarat, 382350'),
      findsOneWidget,
      reason: 'city, state and pin share a line, as on a parcel',
    );
    expect(find.text('Razorpay'), findsOneWidget);
  });

  testWidgets('every figure is one the server sent', (tester) async {
    // The Grand Total is `amount` — what was charged — never a sum this screen
    // performed, and a term the payload omits is left out rather than printed
    // as zero.
    await _pump(tester, _order());

    expect(find.text('₹1,457.09'), findsWidgets, reason: 'subtotal + line');
    expect(find.text('₹336.10'), findsOneWidget, reason: 'shipping');
    expect(find.text('₹1,793.19'), findsOneWidget, reason: 'grand total');
    expect(find.text('Grand Total:'), findsOneWidget);

    // Zero tax, zero discount and a zero fee were all sent as 0.00 — none of
    // them earns a row.
    expect(find.text('GST:'), findsNothing);
    expect(find.text('Discount:'), findsNothing);
    expect(find.text('Payment fee:'), findsNothing);
  });

  group('the billing address', () {
    const billing = {
      'name': 'Uminber India',
      'phone': '8305317276',
      'address': '306, Ring Road',
      'city': 'Gwalior',
      'state': 'Madhya Pradesh',
      'country': 'India',
      'zip_code': '474010',
    };

    testWidgets('is printed when the invoice goes somewhere else',
        (tester) async {
      await _pump(tester, _order(extra: {'billing_info': billing}));

      expect(find.byKey(const Key('summary-bill-to')), findsOneWidget);
      expect(find.text('Bill to'), findsOneWidget);
      expect(find.text('Uminber India'), findsOneWidget);
      expect(find.text('306, Ring Road'), findsOneWidget);
    });

    testWidgets('sits under Ship to, in the same column', (tester) async {
      // The same kind of fact, read together — and a fourth column would take
      // the sheet past a single swipe for something most orders do not have.
      await _pump(tester, _order(extra: {'billing_info': billing}));

      final ship = tester.getTopLeft(find.byKey(const Key('summary-ship-to')));
      final bill = tester.getTopLeft(find.byKey(const Key('summary-bill-to')));

      expect(bill.dx, ship.dx, reason: 'same column');
      expect(bill.dy, greaterThan(ship.dy), reason: 'below it');
    });

    testWidgets('is absent when it is the delivery address again',
        (tester) async {
      // `billing_info` is all-nulls on most orders and, when present, is
      // usually the delivery address repeated — printing it twice under two
      // headings reads as two addresses.
      await _pump(
        tester,
        _order(extra: {'billing_info': _order()['shipping_info']}),
      );

      expect(find.byKey(const Key('summary-bill-to')), findsNothing);
      expect(find.text('Bill to'), findsNothing);
    });

    testWidgets('is absent when the server sent an empty block',
        (tester) async {
      await _pump(tester, _order());

      expect(find.byKey(const Key('summary-bill-to')), findsNothing);
    });
  });

  testWidgets('the items block is headed by a fact, not a guessed date',
      (tester) async {
    // The reference says "Arriving Thursday". This backend's order payload
    // carries no arrival date of any kind, so the shipment's real status and
    // courier stand in — a wrong arrival date is the worst thing a summary
    // like this could say.
    await _pump(tester, _order());

    expect(find.byKey(const Key('summary-items')), findsOneWidget);
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('Xpressbees Surface 5kg'), findsOneWidget);
    expect(find.textContaining('Arriving'), findsNothing);
  });

  testWidgets('it lists what was ordered', (tester) async {
    await _pump(tester, _order());

    expect(find.text('Trueway Farms Organic Pure Honey'), findsOneWidget);
    expect(find.text('Qty 2'), findsOneWidget);
    expect(
      find.text('₹1,457.09'),
      findsWidgets,
      reason: 'the price sits under the title, not at the margin',
    );
  });

  testWidgets('no seller line until the payload carries one', (tester) async {
    // `products[]` has no `store_name` on this backend. An invented seller on
    // a document like this is worse than none.
    await _pump(tester, _order());

    expect(find.textContaining('Sold by'), findsNothing);
  });

  testWidgets('it never calls itself an invoice', (tester) async {
    // There is no invoice for an undelivered order — that is the whole reason
    // this screen exists — and a summary that borrowed the word would be
    // claiming a tax document the shop has not issued.
    await _pump(tester, _order());

    expect(find.textContaining('Invoice'), findsNothing);
    expect(find.textContaining('invoice'), findsNothing);
    expect(find.textContaining('Download'), findsNothing);
  });

  testWidgets('an order with no shipping row says so rather than blanking',
      (tester) async {
    await _pump(tester, _order(extra: {'shipping_info': <String, dynamic>{}}));

    expect(find.byKey(const Key('summary-ship-to')), findsOneWidget);
    expect(find.text('No delivery address on this order.'), findsOneWidget);
  });

  group('it is set like a printed bill', () {
    // Smaller than the rest of the app, and deliberately. A bill is read
    // closely and all at once — the eye goes down the column of figures rather
    // than across a screen — and the point of a fixed-width sheet is that it
    // reads as one piece of paper. At the app's ordinary sizes the document
    // sprawled and needed more scrolling in both directions than it had
    // content.
    //
    // Pinned as numbers because the whole scale has to move together: a
    // document whose sections are set at slightly different sizes stops looking
    // printed, and that is exactly the drift a `copyWith(fontSize:)` at one
    // call site would cause.
    double sizeOf(WidgetTester tester, String text) =>
        tester.widgetList<Text>(find.text(text)).first.style!.fontSize!;

    testWidgets('every level of the sheet', (tester) async {
      await _pump(tester, _order());

      expect(sizeOf(tester, 'Order Summary'), 20, reason: 'the document title');
      expect(sizeOf(tester, 'Ship to'), 13, reason: 'a section title');
      expect(sizeOf(tester, 'Akash'), 12, reason: 'a line of the document');
      expect(sizeOf(tester, 'Approved'), 13, reason: 'the shipment title');
      expect(
        sizeOf(tester, 'Trueway Farms Organic Pure Honey'),
        12,
        reason: 'a product name',
      );
      expect(sizeOf(tester, 'Grand Total:'), 13, reason: 'a concluding figure');
      expect(sizeOf(tester, 'Qty 2'), 11, reason: 'secondary to the line above');
    });

    testWidgets('the title is smaller than the app writes a page title',
        (tester) async {
      // One step down from h1 (24). Large enough to title the page, small
      // enough not to shout on a sheet held at reading distance.
      await _pump(tester, _order());

      expect(sizeOf(tester, 'Order Summary'), lessThan(24));
    });
  });

  group('it is a sheet, not a page', () {
    // An invoice is a piece of paper of a known size. Reflowing the three
    // columns into a stack to fit a phone is what stopped this reading as one —
    // so the document keeps its proportions and the phone scrolls sideways
    // across it, the way you move a paper bill that is wider than your hand.
    testWidgets('everything is inside one bordered box', (tester) async {
      await _pump(tester, _order(), width: 360);

      expect(find.byKey(const Key('summary-sheet')), findsOneWidget);
      for (final part in const [
        'summary-ship-to',
        'summary-payment',
        'summary-money',
        'summary-items',
      ]) {
        expect(
          find.descendant(
            of: find.byKey(const Key('summary-sheet')),
            matching: find.byKey(Key(part)),
          ),
          findsOneWidget,
          reason: '$part belongs to the sheet',
        );
      }
    });

    testWidgets('the same width on a phone as on a tablet', (tester) async {
      await _pump(tester, _order(), width: 360);
      final onPhone = tester.getSize(find.byKey(const Key('summary-sheet')));

      await _pump(tester, _order(), width: 1000);
      final onTablet = tester.getSize(find.byKey(const Key('summary-sheet')));

      expect(onPhone.width, onTablet.width);
      expect(onPhone.width, greaterThan(360), reason: 'wider than the phone');
    });

    testWidgets('the columns stay columns on a phone', (tester) async {
      // The whole point. Stacked, the money column would sit below the address
      // instead of beside it.
      await _pump(tester, _order(), width: 360);

      final shipTo = tester.getTopLeft(find.byKey(const Key('summary-ship-to')));
      final money = tester.getTopLeft(find.byKey(const Key('summary-money')));

      expect(money.dy, shipTo.dy, reason: 'same row');
      expect(money.dx, greaterThan(shipTo.dx), reason: 'to its right');
    });

    testWidgets('and it scrolls sideways to reach the rest', (tester) async {
      await _pump(tester, _order(), width: 360);

      final before = tester.getTopLeft(find.byKey(const Key('summary-money')));
      await tester.dragFrom(const Offset(180, 400), const Offset(-300, 0));
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(const Key('summary-money'))).dx,
        lessThan(before.dx),
      );
      expect(tester.takeException(), isNull);
    });
  });
}

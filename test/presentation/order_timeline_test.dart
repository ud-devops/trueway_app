import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/order.dart';
import 'package:trueway_farms/presentation/widgets/order_timeline.dart';

/// The order timeline, as the website renders it: newest first, a marker per
/// row, a connector between them, and nothing at all when there is no history.

OrderHistory _entry({
  int id = 1,
  String action = 'create_order',
  String description = 'New order SF10000286 from Suraj ojha',
  bool isSystem = true,
  String? refundFormatted,
  String? location,
  String? courierName,
}) =>
    OrderHistory(
      id: id,
      action: action,
      description: description,
      isSystem: isSystem,
      createdAt: DateTime(2026, 8, 11, 21, 47),
      refundAmountFormatted: refundFormatted,
      location: location,
      courierName: courierName,
    );

/// Same host, with the carrier the order was booked with.
Future<void> _pumpWithCarrier(
  WidgetTester tester,
  List<OrderHistory> histories,
  String carrier,
) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: OrderTimeline(
            histories: histories,
            shippingCompanyName: carrier,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pump(WidgetTester tester, List<OrderHistory> histories) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: OrderTimeline(histories: histories),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders a row per history entry', (tester) async {
    await _pump(tester, [
      _entry(id: 803),
      _entry(id: 802, description: 'The email confirmation was sent'),
      _entry(id: 801, description: 'Order was verified', isSystem: false),
    ]);

    expect(find.text('Order history'), findsOneWidget);
    expect(find.textContaining('New order'), findsOneWidget);
    expect(find.textContaining('email confirmation'), findsOneWidget);
    expect(find.textContaining('Order was verified'), findsOneWidget);
  });

  // The description is the display text; `action.label` is the raw code and
  // would read as "send_order_confirmation_email" to a customer.
  testWidgets('never shows the action code', (tester) async {
    await _pump(tester, [
      _entry(action: 'send_order_confirmation_email', description: 'Email sent'),
    ]);

    expect(find.text('Email sent'), findsOneWidget);
    expect(find.textContaining('send_order_confirmation_email'), findsNothing);
  });

  // The marker says what the step IS. The website does not colour-code by
  // action and neither does this — only the glyph varies.
  group('the marker', () {
    testWidgets('comes from the action, not from is_system', (tester) async {
      // The old person/gear split separated nothing once the server started
      // filtering its internal rows out: order 314 has `return_order` flagged
      // `is_system: true` sitting beside `refund` flagged false, and both are
      // plainly the customer's business.
      await _pump(tester, [
        _entry(action: 'refund', isSystem: true, description: 'Refund completed'),
      ]);

      expect(
        find.byIcon(Icons.account_balance_wallet_rounded),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.settings_rounded), findsNothing);
      expect(find.byIcon(Icons.person_rounded), findsNothing);
    });

    testWidgets('the same action gets the same marker either way',
        (tester) async {
      for (final system in [true, false]) {
        await _pump(tester, [
          _entry(action: 'create_shipment', isSystem: system),
        ]);
        expect(
          find.byIcon(Icons.local_shipping_rounded),
          findsOneWidget,
          reason: 'is_system: $system',
        );
      }
    });

    // An unknown action must render like any other row rather than crash — the
    // code list is open-ended and grows server-side.
    testWidgets('an unknown action still renders', (tester) async {
      await _pump(tester, [
        _entry(action: 'some_future_action', description: 'Something happened'),
      ]);

      expect(tester.takeException(), isNull);
      expect(find.text('Something happened'), findsOneWidget);
      // A neutral dot, and the sentence still shows. The icon is decoration.
      expect(find.byIcon(Icons.circle_rounded), findsOneWidget);
    });
  });

  group('what the courier reported', () {
    testWidgets('a scan names its carrier and its place', (tester) async {
      await _pump(tester, [
        _entry(
          action: 'update_shipping_status',
          description: 'In Transit',
          location: 'Bhilwara Hub',
          courierName: 'Xpressbees',
        ),
      ]);

      expect(find.text('Xpressbees · Bhilwara Hub'), findsOneWidget);
    });

    testWidgets('a status moved by hand says nothing extra', (tester) async {
      // Both fields are null unless a courier actually reported them.
      await _pump(tester, [_entry(description: 'Order confirmed')]);

      expect(find.text('Order confirmed'), findsOneWidget);
      expect(find.textContaining('·'), findsNothing);
    });

    testWidgets('the carrier sits on the shipped row, once', (tester) async {
      // It is one fact about the shipment, so repeating it on every scan would
      // turn the timeline into a column of the same phrase.
      await _pumpWithCarrier(
        tester,
        [
          _entry(action: 'update_shipping_status', description: 'In Transit'),
          _entry(action: 'create_shipment', description: 'Order shipped'),
        ],
        'Xpressbees Surface 20kg',
      );

      expect(find.text('Xpressbees Surface 20kg'), findsOneWidget);
    });
  });

  group('the refund note', () {
    // The description rounds — live, a ₹1,493.97 refund reads as "₹1,494".
    testWidgets('shows the exact amount the description rounds',
        (tester) async {
      await _pump(tester, [
        _entry(
          action: 'refund',
          description: 'Refund success ₹1,494',
          refundFormatted: '₹1,493.97',
        ),
      ]);

      expect(find.textContaining('₹1,493.97'), findsOneWidget);
    });

    testWidgets('is absent on an ordinary row', (tester) async {
      await _pump(tester, [_entry()]);

      expect(find.textContaining('Refunded'), findsNothing);
    });

    // `refund_amount_formatted` is null when the amount is zero.
    testWidgets('is absent when the server sent no formatted amount',
        (tester) async {
      await _pump(tester, [_entry(action: 'refund', description: 'Refund')]);

      expect(find.textContaining('Refunded'), findsNothing);
    });
  });

  // An empty panel with a heading says "we have nothing" loudly. Hiding it says
  // the same thing quietly, which is what the instruction asks for.
  testWidgets('draws nothing at all when there is no history', (tester) async {
    await _pump(tester, const []);

    expect(find.text('Order history'), findsNothing);
    expect(find.byType(Icon), findsNothing);
  });

  group('the cancellation note', () {
    testWidgets('shows the reason the status chip cannot carry',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(
            body: OrderCancellationNote(
              message: 'Changed my mind — ordered the wrong pack size.',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('wrong pack size'), findsOneWidget);
    });
  });
}

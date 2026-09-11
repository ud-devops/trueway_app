/// What the confirmation screen states, and what it deliberately does not.
///
/// The card carried a "Shipping ₹226.36" line under "Total paid ₹855.31",
/// which is a breakdown on a screen whose whole job is to confirm one number.
/// A second figure there invites the arithmetic — "so the goods were 628?" —
/// that belongs on the order, not on the receipt for a payment that has just
/// gone through. The full bill is one tap away behind "View order".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/order.dart';
import 'package:trueway_farms/data/repositories/order_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/screens/checkout/order_success_screen.dart';

/// SF10000322 as the server returned it — the order in the screenshot that
/// prompted this, shipping and all. The row is gone from the *screen*, not
/// from the response.
Map<String, dynamic> _order() => {
      'id': 322,
      'code': 'SF10000322',
      'amount': 855.31,
      'amount_formatted': '₹855.31',
      'shipping_amount': 226.36,
      'shipping_amount_formatted': '₹226.36',
      'sub_total': 628.95,
      'sub_total_formatted': '₹628.95',
      'status': {'value': 'processing', 'label': 'Processing'},
      'payment_status': {'value': 'completed', 'label': 'Completed'},
      'created_at': '2026-08-20 14:08:00',
      'products': const [],
    };

class _FakeRepo implements OrderRepository {
  _FakeRepo(this.row);

  final Map<String, dynamic> row;

  @override
  Future<Order> order(int id) async => Order.fromJson(row);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<void> _pump(WidgetTester tester, Map<String, dynamic> row) async {
  tester.view.physicalSize = const Size(900, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [orderRepositoryProvider.overrideWithValue(_FakeRepo(row))],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const OrderSuccessScreen(orderId: 322),
      ),
    ),
  );
  // NOT pumpAndSettle: the screen plays a [ConfettiController], and confetti
  // keeps asking for frames, so settling never happens. A few fixed pumps are
  // enough — the card is built on the first frame after the order resolves.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('the total is stated', (tester) async {
    await _pump(tester, _order());

    expect(find.byKey(const Key('order-success-total')), findsOneWidget);
    expect(find.text('₹855.31'), findsOneWidget);
    expect(find.text('SF10000322'), findsOneWidget);
  });

  testWidgets('the shipping charge is not', (tester) async {
    await _pump(tester, _order());

    expect(find.text('Shipping'), findsNothing);
    expect(find.text('₹226.36'), findsNothing);
  });

  testWidgets('and nothing else breaks the total into parts', (tester) async {
    // The guard is the absence of a breakdown, not the absence of one row —
    // adding "Subtotal" or "Taxes" here would reintroduce exactly the problem.
    await _pump(tester, _order());

    expect(find.text('₹628.95'), findsNothing, reason: 'sub total');
    for (final label in const ['Subtotal', 'Sub total', 'Taxes', 'Discount']) {
      expect(find.text(label), findsNothing, reason: label);
    }
  });
}

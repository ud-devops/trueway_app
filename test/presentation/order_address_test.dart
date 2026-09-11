/// Which addresses the order detail screen shows, and when.
///
/// The bug: `_addresses()` opened with `if (shipping == null) return
/// SizedBox.shrink()`, so an order whose **shipping** block came back empty
/// showed no addresses at all — including a billing address the customer had
/// typed at checkout and could see nowhere else in the app.
///
/// The two blocks are two different `ec_order_addresses` rows, written at two
/// different moments in `OrderHelper::checkAndCreateOrderAddress`, and either
/// can be missing on its own:
///
///   * the shipping row is **deleted** outright when the order needs no
///     shipping (`is_save_order_shipping_address`, which the server computes
///     from the products — the app does not send it);
///   * the billing row is skipped whenever its own validation fails, and
///     `storeOrderBillingAddress` swallows that failure and returns — the
///     order is still created and still reports success.
///
/// So the absence of one says nothing about the other, and neither may hide
/// the other.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/order.dart';
import 'package:trueway_farms/data/repositories/order_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/screens/orders/order_detail_screen.dart';

/// The shape the resources emit. `billing_info` defaults to the all-null
/// object the server sends for an order with no billing row — `billingAddress`
/// is a `hasOne(...)->withDefault()`, so it is never actually absent, just
/// empty.
Map<String, dynamic> _order({
  Map<String, dynamic>? shipping,
  Object? billing,
}) =>
    {
      'id': 322,
      'code': 'SF10000322',
      'status': {'value': 'processing', 'label': 'Processing'},
      'created_at': '2026-08-20T14:08:00+05:30',
      'amount': '855.31',
      'amount_formatted': '₹855.31',
      'products': const <Map<String, dynamic>>[],
      'shipping_info': shipping ??
          const {
            'name': 'Suraj ojha',
            'phone': '8305317276',
            'address': '402, ganesh rivera',
            'city': 'Gwalior',
            'state': 'Madhya Pradesh',
            'country': 'India',
            'zip_code': '474010',
          },
      'billing_info': billing ?? _emptyContact,
    };

const _emptyContact = {
  'name': null,
  'phone': null,
  'email': null,
  'address': null,
  'city': null,
  'state': null,
  'country': null,
  'zip_code': null,
};

const _billing = {
  'name': 'Uminber India',
  'phone': '8305317276',
  'address': '306, Ring Road',
  'city': 'Ahmedabad',
  'state': 'Gujarat',
  'country': 'India',
  'zip_code': '382415',
};

class _FakeRepo implements OrderRepository {
  _FakeRepo(this.payload);

  final Map<String, dynamic> payload;

  @override
  Future<Order> order(int id) async => Order.fromJson(payload);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        orderRepositoryProvider.overrideWithValue(_FakeRepo(payload)),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: OrderDetailScreen(orderId: payload['id'] as int),
      ),
    ),
  );

  // Not `pumpAndSettle` — see order_bill_test.dart: the image placeholders
  // schedule frames forever under the test binding.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('delivery only, when there is no separate billing address',
      (tester) async {
    await _pump(tester, _order());

    expect(find.text('Delivery address'), findsOneWidget);
    expect(
      find.text('402, ganesh rivera, Gwalior, Madhya Pradesh, 474010, India'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('order-billing-address')), findsNothing);
    expect(find.text('Billed to the same address.'), findsOneWidget);
  });

  testWidgets('both, when the billing address is a different one',
      (tester) async {
    await _pump(tester, _order(billing: _billing));

    expect(find.text('Delivery address'), findsOneWidget);
    expect(find.byKey(const Key('order-billing-address')), findsOneWidget);
    expect(find.text('Uminber India'), findsOneWidget);
    expect(find.text('Billed to the same address.'), findsNothing);
  });

  testWidgets('the billing address survives an empty shipping block',
      (tester) async {
    // THE BUG. The screen showed nothing at all here — the customer typed a
    // billing address at checkout and the app had no screen that admitted it
    // existed.
    await _pump(tester, _order(shipping: _emptyContact, billing: _billing));

    expect(find.byKey(const Key('order-addresses')), findsOneWidget);
    expect(find.byKey(const Key('order-billing-address')), findsOneWidget);
    expect(find.text('Uminber India'), findsOneWidget);

    // And it does not invent a delivery address it was not given.
    expect(find.text('Delivery address'), findsNothing);
    expect(find.text('Billed to the same address.'), findsNothing);
  });

  testWidgets('the card is hidden only when both are genuinely empty',
      (tester) async {
    await _pump(tester, _order(shipping: _emptyContact));

    expect(find.byKey(const Key('order-addresses')), findsNothing);
    expect(find.text('Delivery address'), findsNothing);
    expect(find.text('Billed to the same address.'), findsNothing);
  });

  testWidgets('a `[]` billing block is read as absent, not as a crash',
      (tester) async {
    // `whenLoaded($rel, $callback, [])` serialises its default as a JSON
    // *array*, so this really does arrive over the wire.
    await _pump(tester, _order(billing: const <dynamic>[]));

    expect(find.text('Delivery address'), findsOneWidget);
    expect(find.byKey(const Key('order-billing-address')), findsNothing);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/order.dart';

/// The order timeline, from `GET /ecommerce/orders/{id}`.
///
/// Additive on the server: `histories`, `cancellation_reason` and
/// `cancellation_reason_message` were added without changing anything else, so
/// every default here has to survive a response that predates them — including
/// a list row, which never carries the key at all.

/// The backend's own sample, trimmed.
Map<String, dynamic> _order({
  List<Map<String, dynamic>>? histories,
  Object? cancellationReason,
  Object? cancellationMessage,
  String? cancellationDescription,
}) =>
    {
      'id': 286,
      'code': 'SF10000286',
      'status': {'value': 'processing', 'label': 'Processing'},
      'amount': '1000.00',
      if (histories != null) 'histories': histories,
      if (cancellationReason != null) 'cancellation_reason': cancellationReason,
      if (cancellationMessage != null)
        'cancellation_reason_message': cancellationMessage,
      if (cancellationDescription != null)
        'cancellation_reason_description': cancellationDescription,
    };

const _created = {
  'id': 803,
  'action': {'value': 'create_order', 'label': 'create_order'},
  'description': 'New order SF10000286 from Suraj ojha',
  'is_system': true,
  'created_at': '2026-08-11T21:47:35+05:30',
  'created_at_formatted': '11-08-2026 21:47:35',
};

const _confirmed = {
  'id': 801,
  'action': {'value': 'confirm_order', 'label': 'confirm_order'},
  'description': 'Order was verified by Suraj ojha',
  'is_system': false,
  'created_at': '2026-08-11T21:47:32+05:30',
  'created_at_formatted': '11-08-2026 21:47:32',
};

const _refunded = {
  'id': 226,
  'action': {'value': 'refund', 'label': 'refund'},
  'description': 'Refund success ₹1,494',
  'is_system': false,
  'created_at': '2026-02-14T16:25:40+05:30',
  'created_at_formatted': '14-02-2026 16:25:40',
  'refund_amount': 1493.97,
  'refund_amount_formatted': '₹1,493.97',
};

void main() {
  group('histories', () {
    test('reads the rows the server sends', () {
      final order = Order.fromJson(_order(histories: [_created, _confirmed]));

      expect(order.histories, hasLength(2));
      expect(order.hasHistory, isTrue);
      expect(order.histories.first.id, 803);
      expect(order.histories.first.description, contains('New order'));
      expect(order.histories.first.action, 'create_order');
    });

    // The endpoint sends `id DESC` and the app renders what it is given —
    // sorting by a client-side rule would disagree with the website the first
    // time two rows shared a timestamp.
    test('keeps the server order', () {
      final order = Order.fromJson(_order(histories: [_created, _confirmed]));

      expect(order.histories.map((h) => h.id), [803, 801]);
    });

    // A list row never carries the key, and neither does a response cached
    // before the server started sending it.
    test('an absent key is an empty timeline, not a failure', () {
      final order = Order.fromJson(_order());

      expect(order.histories, isEmpty);
      expect(order.hasHistory, isFalse);
    });

    test('an empty array is the same', () {
      final order = Order.fromJson(_order(histories: const []));

      expect(order.hasHistory, isFalse);
    });
  });

  group('a history row', () {
    OrderHistory row(Map<String, dynamic> j) => OrderHistory.fromJson(j);

    // `action.label` has no translation entry and falls back to the raw code,
    // so it would render "send_order_confirmation_email" at a customer. Only
    // `value` is kept, and only `description` is for display.
    test('keeps the action code, not its label', () {
      final history = row({
        'id': 1,
        'action': {'value': 'confirm_order', 'label': 'confirm_order'},
        'description': 'Order was verified by Suraj ojha',
      });

      expect(history.action, 'confirm_order');
      expect(history.description, 'Order was verified by Suraj ojha');
    });

    // Every other status field in this API has appeared in both shapes.
    test('also reads a bare string action', () {
      expect(row({'id': 1, 'action': 'refund'}).action, 'refund');
    });

    test('distinguishes system rows from people ones', () {
      expect(row(_created).isSystem, isTrue);
      expect(row(_confirmed).isSystem, isFalse);
    });

    // The icon is all that hangs on it, and an unattributed row is more
    // plausibly the system's.
    test('defaults to a system row when unattributed', () {
      expect(row({'id': 1, 'description': 'x'}).isSystem, isTrue);
    });

    test('parses the offset timestamp', () {
      final at = row(_created).createdAt!;

      expect(at.isUtc, isFalse, reason: 'converted to device local time');
      expect(at.toUtc().hour, 16, reason: '21:47 +05:30 is 16:17 UTC');
    });

    test('survives a row with no timestamp', () {
      expect(row({'id': 1, 'description': 'x'}).createdAt, isNull);
    });
  });

  group('refunds', () {
    test('carry the exact amount the description rounds', () {
      final history = OrderHistory.fromJson(_refunded);

      expect(history.isRefund, isTrue);
      expect(history.refundAmount, 1493.97);
      expect(history.refundAmountFormatted, '₹1,493.97');
      expect(
        history.description,
        contains('1,494'),
        reason: 'the sentence rounds; the field does not',
      );
    });

    test('an ordinary row carries no refund fields', () {
      final history = OrderHistory.fromJson(_created);

      expect(history.isRefund, isFalse);
      expect(history.refundAmount, isNull);
      expect(history.refundAmountFormatted, isNull);
    });
  });

  group('cancellation', () {
    test('reads the reason and its message', () {
      final order = Order.fromJson(
        _order(
          cancellationReason: 'change-mind',
          cancellationMessage: 'Changed my mind — ordered the wrong pack size.',
        ),
      );

      expect(order.cancellationReason, 'change-mind');
      expect(order.cancellationMessage, contains('wrong pack size'));
    });

    // The authenticated detail endpoint sends `..._message`; the public
    // tracking endpoint sends `..._description` — captured on live order 286.
    // Reading both means neither resource has to change.
    test('also reads the tracking endpoint spelling', () {
      final order = Order.fromJson(
        _order(cancellationDescription: 'Out of stock'),
      );

      expect(order.cancellationMessage, 'Out of stock');
    });

    test('is null on an order that was not cancelled', () {
      final order = Order.fromJson(_order());

      expect(order.cancellationReason, isNull);
      expect(order.cancellationMessage, isNull);
    });
  });
}

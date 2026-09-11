/// Approval and refund are two facts, not one.
///
/// The screens used to print `return_status.label` straight through, so a
/// return the shop had merely *accepted* read "Processing" and one it had
/// refunded read "Completed" — neither word telling the customer the thing
/// they were waiting on, which is whether the money moved.
///
/// The backend keeps them apart properly:
///
///   * `OrderReturnHelper` writes an `approved` timeline step at exactly the
///     transition into `processing` (`PROCESSING => APPROVED`), so `processing`
///     *is* approved;
///   * the money lives on `ec_order_returns.is_refunded` / `refunded_amount`,
///     written only by the admin's separate refund action;
///   * and `OrderReturnController::update` refuses to move a return to
///     `completed` while the order still has an unrefunded payment.
///
/// That last guard is why `completed` may stand in for "refunded" until the
/// API serialises `is_refunded` — verified absent live on 2026-08-19 against
/// both the list and the detail endpoint.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/order_return.dart';

Map<String, dynamic> _row(String status, {Map<String, dynamic> extra = const {}}) => {
      'id': 31,
      'order_id': 314,
      'order_code': 'SF10000314',
      'return_status': {'value': status, 'label': _serverLabel(status)},
      'reason': {'value': 'damaged', 'label': 'Damaged product'},
      'submission_count': 1,
      'items': [
        {
          'id': 1,
          'order_product_id': 900,
          'product_name': 'Trueway Farms Organic Pure Honey',
          'qty': 1,
          'price': 470.00,
          'refund_amount': 470.00,
        },
      ],
      ...extra,
    };

/// The server's own wording, so the tests are relabelling something real.
String _serverLabel(String status) => const {
      'pending': 'Pending',
      'processing': 'Processing',
      'completed': 'Completed',
      'canceled': 'Canceled',
      'resubmit': 'Resubmit Required',
    }[status]!;

void main() {
  group('the stage a return is at', () {
    test('an accepted return reads Approved, not Processing', () {
      final row = OrderReturn.fromJson(_row('processing'));

      expect(row.stageLabel, 'Approved');
      expect(row.isApproved, isTrue);
      expect(row.isRefunded, isFalse, reason: 'accepted is not paid out');
    });

    test('a finished return reads Refunded, not Completed', () {
      final row = OrderReturn.fromJson(_row('completed'));

      expect(row.stageLabel, 'Refunded');
      expect(row.isRefunded, isTrue);
      expect(row.isApproved, isTrue, reason: 'you cannot complete an unapproved one');
    });

    test('the other three keep the server’s own word', () {
      expect(OrderReturn.fromJson(_row('pending')).stageLabel, 'Pending');
      expect(OrderReturn.fromJson(_row('canceled')).stageLabel, 'Canceled');
      expect(
        OrderReturn.fromJson(_row('resubmit')).stageLabel,
        'Resubmit Required',
      );
    });
  });

  group('when is_refunded ships, it wins', () {
    // The whole point of parsing it nullable: the fallback is an inference
    // from a guard the app cannot see, and it must step aside the moment the
    // server states the fact itself.
    test('completed but not yet refunded stops claiming a refund', () {
      final row = OrderReturn.fromJson(
        _row('completed', extra: {'is_refunded': false}),
      );

      expect(row.isRefunded, isFalse);
      expect(row.stageLabel, 'Approved');
    });

    test('approved and already refunded reads Refunded', () {
      final row = OrderReturn.fromJson(
        _row('processing', extra: {'is_refunded': true}),
      );

      expect(row.isRefunded, isTrue);
      expect(
        row.stageLabel,
        'Approved',
        reason: 'the status is still the server’s word for where it is',
      );
    });

    test('an absent flag is not a false one', () {
      expect(OrderReturn.fromJson(_row('completed')).isRefundedFlag, isNull);
      expect(
        OrderReturn.fromJson(_row('completed', extra: {'is_refunded': false}))
            .isRefundedFlag,
        isFalse,
      );
    });
  });

  group('the amount', () {
    test('falls back to the sum of the items’ refunds', () {
      expect(OrderReturn.fromJson(_row('completed')).refundedTotal, 470.00);
    });

    test('but the server’s own figure wins when it sends one', () {
      // Not the same number on purpose: a payout is netted against RTO charges
      // and non-refundable shipping, so what was asked for and what was sent
      // legitimately differ.
      final row = OrderReturn.fromJson(
        _row('completed', extra: {'refunded_amount': 395.50}),
      );

      expect(row.refundTotal, 470.00, reason: 'what the return asked for');
      expect(row.refundedTotal, 395.50, reason: 'what actually went back');
    });

    test('a null amount does not become zero', () {
      final row = OrderReturn.fromJson(
        _row('completed', extra: {'refunded_amount': null}),
      );

      expect(row.refundedAmount, isNull);
      expect(row.refundedTotal, 470.00);
    });
  });
}

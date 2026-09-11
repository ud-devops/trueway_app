/// What the app promises about money coming back.
///
/// This is a commitment the shop has to keep, so the rule is not "always say
/// 5-7 days". The account's own 100 live orders are why:
///
/// ```
/// payment_method: razorpay 92, cod 8
/// payment_status: completed 84, refunded 10, pending 6
/// ```
///
/// A `pending` order was never charged, and a COD order's money arrived as
/// cash — neither can be sent back "to your original payment method".
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/utils/refund_notice.dart';
import 'package:trueway_farms/data/models/order.dart';

Order _order({
  String paymentStatus = 'completed',
  String paymentMethod = 'razorpay',
}) =>
    Order.fromJson({
      'id': 277,
      'code': 'SF10000277',
      'status': {'value': 'canceled', 'label': 'Canceled'},
      'amount': '1274.15',
      'amount_formatted': '₹1,274.15',
      'payment_status': {'value': paymentStatus, 'label': paymentStatus},
      'payment_method': {'value': paymentMethod, 'label': paymentMethod},
      'created_at': '2026-07-16T17:04:00+05:30',
    });

void main() {
  group('an online payment', () {
    test('is refunded the way it came', () {
      final order = _order();

      expect(order.wasPaid, isTrue);
      expect(order.isCashOnDelivery, isFalse);
      expect(order.refundNotice, RefundNotice.toOriginalMethod);
      expect(order.refundNotice, contains('5–7 business days'));
      expect(order.refundNotice, contains('original payment method'));
    });

    test('a refunded order counts as paid', () {
      // 10 of the 100 live orders sit in `refunded`: money *was* taken. It is
      // `pending` that means nothing ever was.
      expect(_order(paymentStatus: 'refunded').wasPaid, isTrue);
      expect(_order(paymentStatus: 'refunded').refundNotice, isNotNull);
    });
  });

  group('cash on delivery', () {
    test('never claims the money goes back the way it came', () {
      // 8 of the 100 live orders are COD. The cash cannot be reversed down the
      // route it arrived by, so the copy does not say it can.
      final order = _order(paymentMethod: 'cod');

      expect(order.isCashOnDelivery, isTrue);
      expect(order.refundNotice, RefundNotice.processed);
      expect(order.refundNotice, contains('5–7 business days'));
      expect(order.refundNotice, isNot(contains('original payment method')));
    });
  });

  group('an order nobody has paid for', () {
    test('is promised nothing', () {
      // 6 of the 100 are `pending`. Promising a refund here is promising to
      // return money that was never taken.
      final order = _order(paymentStatus: 'pending');

      expect(order.wasPaid, isFalse);
      expect(order.refundNotice, isNull);
    });

    test('COD and pending together still say nothing', () {
      expect(
        _order(paymentStatus: 'pending', paymentMethod: 'cod').refundNotice,
        isNull,
      );
    });
  });

  test('the window is written once', () {
    // Three sentences, one number. A screen that hard-coded "5-7" would drift
    // the day the policy changes.
    expect(kRefundWindow, '5–7 business days');
    for (final copy in [
      RefundNotice.toOriginalMethod,
      RefundNotice.processed,
      RefundNotice.issued,
    ]) {
      expect(copy, contains(kRefundWindow));
    }
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/placed_order.dart';

/// The two things `PlacedOrder` decides that cost real money:
///
///   * how much the Razorpay sheet opens at, and
///   * whether a sheet opens at all.
///
/// Both are read off the wire with no arithmetic anywhere, which is the point —
/// `data.razorpay.amount` is the *server's* `(int) round($order->amount * 100)`
/// and the app's only job is to not corrupt it on the way through.

Map<String, dynamic> _body({
  Object? amount = 127415,
  String orderId = 'order_abc',
  String keyId = 'rzp_test',
  bool withRazorpay = true,
}) =>
    {
      'order_id': 277,
      'order_token': 'a' * 32,
      'order_status': 'pending',
      'order_status_label': 'Pending',
      'payment_status': 'pending',
      'payment_method': 'razorpay',
      'subtotal': '899.00',
      'tax_amount': '44.95',
      'shipping_amount': '330.20',
      'discount_amount': '0.00',
      'payment_fee': '0.00',
      'total_amount': '1274.15',
      'cart_id': 'cart-1',
      if (withRazorpay) 'is_finished': false,
      if (withRazorpay)
        'razorpay': {
          'razorpay_order_id': orderId,
          'razorpay_key_id': keyId,
          'amount': amount,
          'currency': 'INR',
        },
    };

void main() {
  group('razorpay amount is whole minor units or nothing', () {
    test('takes an integer paise value verbatim', () {
      final order = PlacedOrder.fromJson(_body());
      expect(order.razorpay!.amountInPaise, 127415);
    });

    test('takes a numeric string verbatim', () {
      final order = PlacedOrder.fromJson(_body(amount: '127415'));
      expect(order.razorpay!.amountInPaise, 127415);
    });

    test('a whole double is still whole', () {
      final order = PlacedOrder.fromJson(_body(amount: 127415.0));
      expect(order.razorpay!.amountInPaise, 127415);
    });

    // The regression this guard exists for. `asInt` rounds, so a server that
    // started sending RUPEES here would have been read as 1274 paise — ₹12.74
    // charged for a ₹1,274.15 order, with nothing anywhere to notice.
    test('a fractional value is refused, never rounded', () {
      for (final amount in <Object>[1274.15, '1274.15', 803.25, '803.25']) {
        final order = PlacedOrder.fromJson(_body(amount: amount));
        expect(
          order.razorpay!.amountInPaise,
          0,
          reason: '$amount is not whole minor units',
        );
      }
    });

    test('a missing or unreadable amount is refused', () {
      for (final amount in <Object?>[null, '', 'lots', <String>[]]) {
        final order = PlacedOrder.fromJson(_body(amount: amount));
        expect(order.razorpay!.amountInPaise, 0, reason: '$amount');
      }
    });
  });

  group('the payment branch', () {
    test('a present block means money is due', () {
      expect(PlacedOrder.fromJson(_body()).requiresPayment, isTrue);
    });

    test('an absent block means the order is already finalised', () {
      final order = PlacedOrder.fromJson(_body(withRazorpay: false));
      expect(order.razorpay, isNull);
      expect(order.requiresPayment, isFalse);
      // Absence, not null — the server omits the key entirely on this branch.
      expect(order.isFinished, isNull);
    });

    // Presence, not usability. A broken block still means the server put this
    // order on the pay-online branch: reporting `requiresPayment: false` here
    // would send it down the already-paid branch, which clears the cart and
    // draws a receipt for an order nobody paid for. The block stays present and
    // provably unusable, and the payment request refuses to be built from it.
    test('a malformed block still requires payment, and carries nothing usable',
        () {
      for (final order in [
        PlacedOrder.fromJson(_body(orderId: '')),
        PlacedOrder.fromJson(_body(keyId: '')),
        PlacedOrder.fromJson(_body(amount: 1274.15)),
      ]) {
        expect(order.requiresPayment, isTrue);
        final handoff = order.razorpay!;
        final usable = handoff.orderId.isNotEmpty &&
            handoff.keyId.isNotEmpty &&
            handoff.amountInPaise > 0;
        expect(usable, isFalse);
      }
    });
  });

  // `shipping_amount` is now the SERVER's figure, not an echo of anything the
  // app sent — the app sends a `shipping_option` and no amount at all. It is
  // read, never recomputed, and it is the only delivery charge that may be
  // displayed.
  test('shipping_amount is read exactly as the server rendered it', () {
    final order = PlacedOrder.fromJson(_body());
    expect(order.shippingAmount.amount, 330.20);
    expect(order.shippingAmount.display, '₹330.20');
    expect(order.totalAmount.display, '₹1,274.15');
  });

  // ---- what the reconciliation step reads --------------------------------
  //
  // The order exists before the app learns any of these. The server re-quotes
  // Shiprocket from its own `store_zip_code`, and a rate id names a quote
  // rather than a courier, so the charged figure can legitimately differ from
  // the displayed one — in either direction. These three are the whole input to
  // "should we open the Razorpay sheet at all".
  group('reconciliation surface', () {
    test('exposes the server total, the server shipping, and the paise', () {
      final order = PlacedOrder.fromJson(_body());
      expect(order.totalAmount.amount, 1274.15);
      expect(order.shippingAmount.amount, 330.20);
      expect(order.amountInPaise, 127415);
    });

    test('amountInPaise is null when there is nothing to collect', () {
      final order = PlacedOrder.fromJson(_body(withRazorpay: false));
      expect(order.requiresPayment, isFalse);
      expect(order.amountInPaise, isNull);
    });

    // The paise figure is the server's own `round(amount * 100)`. It is not
    // re-derived here, and a caller must not re-derive it either.
    test('amountInPaise is the wire value, not totalAmount x 100', () {
      final order = PlacedOrder.fromJson(_body(amount: 999999));
      expect(order.totalAmount.amount, 1274.15);
      expect(order.amountInPaise, 999999);
    });

    test('totalMatches is true for the figure the button showed', () {
      final order = PlacedOrder.fromJson(_body());
      expect(order.totalMatches(1274.15), isTrue);
    });

    // The whole reason this is a method and not `==`. Both sides of the
    // comparison have been through a decimal string and back, and a UI total is
    // usually a sum of its own parts, so the two doubles that describe one
    // identical bill routinely differ in the last binary place. `==` would call
    // that a divergence and stop a perfectly good order.
    test('totalMatches survives a total that drifted in the last binary place',
        () {
      final order = PlacedOrder.fromJson(_body());
      for (final drifted in [1274.1499999999999, 1274.1500000000003]) {
        expect(drifted == 1274.15, isFalse, reason: '$drifted');
        expect(order.totalMatches(drifted), isTrue, reason: '$drifted');
      }
    });

    // Both directions are divergences. The undercharge is the likelier one
    // here: a `shipping_option` the server's re-quote does not contain misses
    // in silence and prices delivery at 0.00.
    test('totalMatches is false in both directions, including an undercharge',
        () {
      final order = PlacedOrder.fromJson(_body());
      expect(order.totalMatches(1604.35), isFalse, reason: 'overcharge');
      expect(order.totalMatches(943.95), isFalse, reason: 'shipping billed 0');
    });

    // A whole paise apart must never read as "the same bill"; half a paise is
    // the tolerance, so anything that rounds to a different paise fails.
    test('totalMatches rejects a one-paise difference', () {
      final order = PlacedOrder.fromJson(_body());
      expect(order.totalMatches(1274.16), isFalse);
      expect(order.totalMatches(1274.14), isFalse);
    });
  });

  group('order code', () {
    // The customer-facing identifier. `API/CheckoutController` does not send it
    // today — `checkout/cart/{id}` and `checkout/confirm-payment` both return
    // `order_id` and `order_token` only — so this is null and the checkout
    // screen shows no identifier rather than the internal id.
    test('is null when the server does not send one', () {
      expect(PlacedOrder.fromJson(_body()).code, isNull);
    });

    // Parsed already, so the backend adding one line lights it up with no app
    // change. Never derived: `get_order_code()` is prefix + start-number + id +
    // suffix, and all three are admin settings.
    test('is read when the server does send one', () {
      final order = PlacedOrder.fromJson({..._body(), 'code': 'SF10000315'});
      expect(order.code, 'SF10000315');
      expect(order.displayCode, 'SF10000315');
      expect(order.orderId, isNot(0), reason: 'the id is still parsed');
    });

    // 25 of this shop's 90 orders store the code with a leading `#` — it is
    // part of the column, not decoration. Rendering it raw shows `#SF-…`; the
    // rest of the app strips it through `Order.displayCode`, and so does this.
    test('the older `#SF-` form is rendered without its hash', () {
      final order = PlacedOrder.fromJson({..._body(), 'code': '#SF-10000016'});
      expect(order.code, '#SF-10000016');
      expect(order.displayCode, 'SF-10000016');
    });

    test('displayCode is null when there is no code', () {
      expect(PlacedOrder.fromJson(_body()).displayCode, isNull);
      expect(
        PlacedOrder.fromJson({..._body(), 'code': '   '}).displayCode,
        isNull,
      );
    });
  });
}

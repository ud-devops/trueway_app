import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/pricing/order_pricing.dart';
import 'package:trueway_farms/data/models/server_cart.dart';

/// A cart envelope in the shape `GET /ecommerce/cart/{id}` returns.
///
/// The figures below are a real response: two of SKU 118 at ₹943.95, captured
/// live on 2026-08-03. Note `order_total` (1887.90) is larger than
/// `discounted_sub_total` (1798.00) — the server adds tax on top rather than
/// treating prices as inclusive, which is precisely what the app's own
/// arithmetic used to get wrong.
Map<String, dynamic> cartJson({
  double rawSubTotal = 1798,
  double discountedSubTotal = 1798,
  double discountedTax = 89.9,
  double orderTotal = 1887.9,
  double couponDiscount = 0,
  double promotionDiscount = 0,
  String? couponCode,
  List<Map<String, dynamic>>? items,
}) =>
    {
      'id': 'b6adb7a6-750e-45fe-a929-08e98e99b7fc',
      'count': 2,
      'cart_items': items ??
          [
            {
              'id': 118,
              'row_id': 'abc',
              'name': 'Trueway Farms Organic Desi Khand',
              'quantity': 2,
              'price': 943.95,
              'weight': 5100,
            },
          ],
      'raw_sub_total': rawSubTotal,
      'promotion_discount_amount': promotionDiscount,
      'coupon_discount_amount': couponDiscount,
      'applied_coupon_code': couponCode,
      'discounted_sub_total': discountedSubTotal,
      'discounted_tax_amount': discountedTax,
      'order_total': orderTotal,
    };

ServerCart cart([Map<String, dynamic>? json]) =>
    ServerCart.fromJson(json ?? cartJson());

void main() {
  group('OrderSummary.fromServerCart', () {
    // The whole point of this class now: it reports, it does not calculate.
    test('reads every figure off the cart payload', () {
      final s = OrderSummary.fromServerCart(cart());

      expect(s.itemTotal, 1798);
      expect(s.subtotal, 1798);
      expect(s.gstIncluded, 89.9);
      expect(s.orderTotal, 1887.9);
      expect(s.couponDiscount, 0);
    });

    test('orderTotal is carried verbatim, never reassembled', () {
      // Deliberately incoherent: order_total does not equal
      // discounted_sub_total + discounted_tax_amount here. If anything in this
      // class ever starts deriving the total, this is the test that catches it.
      final s = OrderSummary.fromServerCart(
        cart(cartJson(
          discountedSubTotal: 1798,
          discountedTax: 89.9,
          orderTotal: 1234.56,
        ),),
      );
      expect(s.orderTotal, 1234.56);
      expect(s.payableOrSubtotal, 1234.56);
    });

    test('the bill rows sum to the total the server charges', () {
      // What the cart renders: item total, less the discounts, plus GST added
      // on top — because this backend is tax-exclusive.
      final s = OrderSummary.fromServerCart(
        cart(cartJson(
          discountedSubTotal: 1748,
          discountedTax: 87.4,
          orderTotal: 1835.4,
          couponDiscount: 50,
          couponCode: 'WELCOME50',
        ),),
      );

      expect(
        s.itemTotal - s.productDiscount - s.couponDiscount + s.gstIncluded,
        closeTo(s.payableOrSubtotal, 0.001),
      );
    });

    test('takes tax from the server, not from a rate', () {
      // The old client formula was `subtotal - subtotal / 1.05`, which on 1798
      // gives ~85.62. The server says 89.90 because it applies tax to the
      // discounted base its own way. The server wins.
      final s = OrderSummary.fromServerCart(cart());
      expect(s.gstIncluded, 89.9);
      expect(s.gstIncluded, isNot(closeTo(85.62, 0.5)));
    });

    test('reports the coupon the server says is applied', () {
      final s = OrderSummary.fromServerCart(
        cart(cartJson(couponCode: 'FRESH10', couponDiscount: 179.8)),
      );
      expect(s.couponCode, 'FRESH10');
      expect(s.couponDiscount, 179.8);
    });

    test('has no coupon when the server reports none', () {
      final s = OrderSummary.fromServerCart(cart());
      expect(s.couponCode, isNull);
      expect(s.couponDiscount, 0);
    });

    test('promotion discount is the product-level saving', () {
      final s = OrderSummary.fromServerCart(
        cart(cartJson(promotionDiscount: 50)),
      );
      expect(s.productDiscount, 50);
      expect(s.totalSavings, 50);
    });

    test('totalSavings combines promotion and coupon', () {
      final s = OrderSummary.fromServerCart(
        cart(cartJson(promotionDiscount: 50, couponDiscount: 100)),
      );
      expect(s.totalSavings, 150);
    });
  });

  group('delivery', () {
    // Shipping is quoted per destination. There is no threshold, no flat fee,
    // and nothing to compute — the app invented ₹499/₹40 and promised free
    // delivery on orders the courier charges ₹330 to ship.
    test('is unknown in the cart, where no address exists', () {
      final s = OrderSummary.fromServerCart(cart());

      expect(s.delivery, isNull);
      expect(s.isDeliveryKnown, isFalse);
      expect(s.payable, isNull,
          reason: 'a total cannot be stated before shipping is quoted',);
    });

    test('payableOrSubtotal stays renderable while delivery is unknown', () {
      final s = OrderSummary.fromServerCart(cart());

      // `order_total`, not `discounted_sub_total`. It used to return
      // `subtotal - couponDiscount` = 1798.00, which silently dropped the
      // ₹89.90 of GST the server adds on top — and that figure is the headline
      // on the cart bar, the bold row of the cart bill and checkout's
      // pre-shipping total.
      expect(s.payableOrSubtotal, 1887.9);
      expect(s.payableOrSubtotal, isNot(s.subtotal));
    });

    test('never takes the coupon off twice', () {
      // The regression, stated as a number. `discounted_sub_total` is already
      // net of the ₹179.80 coupon; the old expression took it off again, so a
      // basket the server prices at 1708.10 rendered as 1618.20 — a coupon's
      // worth of GST and a second coupon short.
      final s = OrderSummary.fromServerCart(
        cart(cartJson(
          couponCode: 'FRESH10',
          couponDiscount: 179.8,
          discountedSubTotal: 1618.2,
          discountedTax: 80.91,
          orderTotal: 1699.11,
        ),),
      );

      expect(s.payableOrSubtotal, 1699.11);
      expect(s.payableOrSubtotal, isNot(s.subtotal - s.couponDiscount));
      expect(s.payableOrSubtotal, greaterThan(s.subtotal));
    });

    test('the single-item live basket that started this', () {
      // Captured live: 1 x product 118. raw_sub_total 899.00,
      // discounted_tax_amount 44.95, order_total 943.95. The cart used to show
      // ₹899.00 as "Subtotal" for goods that cost ₹943.95.
      final s = OrderSummary.fromServerCart(
        cart(cartJson(
          rawSubTotal: 899,
          discountedSubTotal: 899,
          discountedTax: 44.95,
          orderTotal: 943.95,
        ),),
      );

      expect(s.payableOrSubtotal, 943.95);
    });

    test('adds the quoted charge to the server order total', () {
      final s = OrderSummary.fromServerCart(cart(), delivery: 139.36);

      expect(s.isDeliveryKnown, isTrue);
      // order_total (1887.90) + courier rate, not subtotal + rate.
      expect(s.payable, closeTo(1887.9 + 139.36, 0.001));
    });

    test('a zero quote is free delivery, and only a quote can be', () {
      final s = OrderSummary.fromServerCart(cart(), delivery: 0);
      expect(s.hasFreeDelivery, isTrue);
      expect(s.payable, 1887.9);
    });

    test('an unquoted cart is not free delivery', () {
      expect(OrderSummary.fromServerCart(cart()).hasFreeDelivery, isFalse);
    });
  });

  group('empty', () {
    test('is all zeroes and quotes nothing', () {
      expect(OrderSummary.empty.payable, 0);
      expect(OrderSummary.empty.orderTotal, 0);
      expect(OrderSummary.empty.payableOrSubtotal, 0);
      expect(OrderSummary.empty.totalSavings, 0);
      expect(OrderSummary.empty.couponCode, isNull);
    });
  });

  group('regression: cart and checkout agree', () {
    // Both screens render this one object, built from one cart payload, so they
    // cannot show different totals — the bug that started this class.
    test('the same cart yields the same figures everywhere', () {
      final source = cart(cartJson(couponCode: 'WELCOME50', couponDiscount: 50));

      final inCart = OrderSummary.fromServerCart(source);
      final atCheckout = OrderSummary.fromServerCart(source, delivery: 139.36);

      expect(inCart.subtotal, atCheckout.subtotal);
      expect(inCart.couponDiscount, atCheckout.couponDiscount);
      expect(inCart.couponCode, atCheckout.couponCode);
      expect(inCart.orderTotal, atCheckout.orderTotal);
      // Only the shipping line differs, and only because one of them knows it.
      expect(inCart.payable, isNull);
      expect(atCheckout.payable, isNotNull);
      // And the difference between the two headline figures is the courier's
      // quote, nothing else. Before the fix it was the quote *plus* 89.90 of
      // GST, so the number grew on the way to checkout for no visible reason.
      expect(
        atCheckout.payableOrSubtotal - inCart.payableOrSubtotal,
        closeTo(139.36, 0.001),
      );
    });
  });
}

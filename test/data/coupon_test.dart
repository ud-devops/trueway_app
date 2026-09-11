/// `GET /ecommerce/coupons`, parsed.
///
/// Fixtures are the live responses from dev.truewayerp.com, captured
/// 2026-08-11 — not hand-written shapes. The two coupons are the ones the shop
/// actually has visible at checkout.
///
/// The rule this file exists to pin is the **tri-state** on `is_eligible`:
///
/// | request                    | `is_eligible` |
/// |----------------------------|---------------|
/// | `?cart_id=<real>`          | `true` / `false` |
/// | no `cart_id`               | key **absent** |
/// | `?cart_id=<unknown>`       | key present, **`null`** |
///
/// The last row is the one a `json['is_eligible'] == true` reading gets wrong:
/// an id the server does not recognise still returns 200 with the whole list,
/// and folding that into "ineligible" greys out every coupon on the screen for
/// a customer whose cart id merely went stale.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/coupon.dart';

/// Live, `?cart_id=<real>`.
Map<String, dynamic> _eligible() => {
      'code': 'HNHPQ2YWQJD0',
      'title': null,
      'description': 'Cupan Code',
      'value': 50,
      'type_option': 'percentage',
      'value_formatted': '50%',
      'target': 'all-orders',
      'min_order_price': null,
      'min_order_price_formatted': null,
      'start_date': '2026-06-09T18:30:00.000000Z',
      'end_date': null,
      'can_use_with_promotion': true,
      'can_use_with_flash_sale': false,
      'is_eligible': true,
      'amount_to_add': null,
      'amount_to_add_formatted': null,
    };

/// The documented shortfall shape, with the server's own sentence figures.
Map<String, dynamic> _ineligible() => {
      ..._eligible(),
      'code': 'BIG5000',
      'description': null,
      'title': null,
      'value': 500,
      'type_option': 'amount',
      'value_formatted': '₹500.00',
      'target': 'minimum-order-amount',
      'min_order_price': 5000,
      'min_order_price_formatted': '₹5,000.00',
      'end_date': '2026-09-30T18:30:00.000000Z',
      'is_eligible': false,
      'amount_to_add': 3157,
      'amount_to_add_formatted': '₹3,157.00',
    };

void main() {
  group('is_eligible is three states, not two', () {
    test('true means offerable', () {
      final c = Coupon.fromJson(_eligible());

      expect(c.isEligible, isTrue);
      expect(c.canApply, isTrue);
      expect(c.isKnownIneligible, isFalse);
      expect(c.blockedReason, isNull);
    });

    test('false means the server judged and said no', () {
      final c = Coupon.fromJson(_ineligible());

      expect(c.isEligible, isFalse);
      expect(c.canApply, isFalse);
      expect(c.isKnownIneligible, isTrue);
      expect(c.blockedReason, 'Add ₹3,157.00 more to use this');
    });

    test('an ABSENT key is unknown, and stays offerable', () {
      // What comes back when `cart_id` is omitted.
      final json = _eligible()..remove('is_eligible');
      final c = Coupon.fromJson(json);

      expect(c.isEligible, isNull);
      expect(c.canApply, isTrue, reason: 'the server gets the final word');
      expect(c.isKnownIneligible, isFalse);
      expect(c.blockedReason, isNull);
    });

    test('a NULL key is unknown too — an unrecognised cart id', () {
      // Verified live: `?cart_id=not-a-real-cart` returns 200, the full list,
      // and `is_eligible: null` on every row.
      final c = Coupon.fromJson({..._eligible(), 'is_eligible': null});

      expect(c.isEligible, isNull);
      expect(c.canApply, isTrue);
    });

    test('a non-boolean is unknown rather than coerced', () {
      for (final odd in [1, 'true', 0, '']) {
        final c = Coupon.fromJson({..._eligible(), 'is_eligible': odd});
        expect(c.isEligible, isNull, reason: '$odd');
        expect(c.canApply, isTrue, reason: '$odd');
      }
    });
  });

  group('what a card renders', () {
    test('the subtitle falls back description -> title -> value', () {
      final base = _eligible();

      expect(Coupon.fromJson(base).subtitle, 'Cupan Code');
      expect(
        Coupon.fromJson({...base, 'description': null, 'title': 'Summer 50'})
            .subtitle,
        'Summer 50',
      );
      // Never blank: a card with no line under the code reads as broken.
      expect(
        Coupon.fromJson({...base, 'description': '  ', 'title': null}).subtitle,
        '50%',
      );
    });

    test('money is the server\'s string, never the raw double', () {
      final c = Coupon.fromJson(_ineligible());

      // 500 vs "₹500.00" — formatting the raw value in the app disagrees with
      // the web store by a paisa on figures like 351.048.
      expect(c.value, 500);
      expect(c.valueFormatted, '₹500.00');
      expect(c.minOrderPriceFormatted, '₹5,000.00');
      expect(c.amountToAddFormatted, '₹3,157.00');
    });

    test('blockedReason falls back to the minimum, then to a plain sentence',
        () {
      final noShortfall = Coupon.fromJson({
        ..._ineligible(),
        'amount_to_add': null,
        'amount_to_add_formatted': null,
      });
      expect(noShortfall.blockedReason, 'Minimum order ₹5,000.00');

      final nothingAtAll = Coupon.fromJson({
        ..._ineligible(),
        'amount_to_add': null,
        'amount_to_add_formatted': null,
        'min_order_price': null,
        'min_order_price_formatted': null,
      });
      expect(nothingAtAll.blockedReason, 'Not applicable to this basket');
    });

    test('a null end_date means no expiry, and a real one is local', () {
      expect(Coupon.fromJson(_eligible()).endDate, isNull);

      final expiring = Coupon.fromJson(_ineligible());
      // 2026-09-30T18:30:00Z is 1 Oct 00:00 IST — printing the UTC date would
      // tell an Indian customer the coupon dies a day early.
      expect(expiring.endDate, isNotNull);
      expect(expiring.endDate!.isUtc, isFalse);
      expect(
        expiring.endDate!.toUtc(),
        DateTime.utc(2026, 9, 30, 18, 30),
      );
    });

    test('min_order_price null means no minimum, not zero', () {
      expect(Coupon.fromJson(_eligible()).minOrderPrice, isNull);
      expect(Coupon.fromJson(_ineligible()).minOrderPrice, 5000);
    });
  });

  group('listFrom', () {
    test('reads the live two-coupon payload', () {
      final list = Coupon.listFrom([_eligible(), _ineligible()]);

      expect(list.map((c) => c.code), ['HNHPQ2YWQJD0', 'BIG5000']);
      expect(list.first.canUseWithPromotion, isTrue);
      expect(list.first.canUseWithFlashSale, isFalse);
    });

    test('an empty list is a valid answer, not a failure', () {
      // Only coupons the admin ticked as visible at checkout appear here, so
      // "none" is ordinary — the sheet still offers its manual code field.
      expect(Coupon.listFrom(const []), isEmpty);
    });

    test('a codeless row is dropped rather than rendered', () {
      // The code is the only thing a card can act on; a button that posts ""
      // would just draw a refusal.
      final list = Coupon.listFrom([
        _eligible(),
        {..._eligible(), 'code': ''},
        {..._eligible(), 'code': null},
      ]);
      expect(list, hasLength(1));
    });

    test('a non-list is empty rather than a crash', () {
      for (final junk in [null, 'nope', 42, <String, dynamic>{}]) {
        expect(Coupon.listFrom(junk), isEmpty, reason: '$junk');
      }
    });
  });

  test('coupons are identified by code', () {
    // The list is re-fetched on every cart change, so the same coupon arrives
    // as a fresh object with different eligibility. Identity has to be the code
    // or nothing can be matched against the cart's `applied_coupon_code`.
    expect(Coupon.fromJson(_eligible()), Coupon.fromJson(_eligible()));
    expect(
      Coupon.fromJson(_eligible()),
      Coupon.fromJson({..._eligible(), 'is_eligible': false}),
    );
    expect(
      Coupon.fromJson(_eligible()),
      isNot(Coupon.fromJson(_ineligible())),
    );
  });
}

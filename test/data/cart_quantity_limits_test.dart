/// Per-product cart quantity limits.
///
/// Every fixture below is a real row from the live catalogue, because the two
/// cases that matter are both counter-intuitive and both live:
///
///   * `Sona Moti Wheat` has **min 2** — a first "ADD" of 1 is refused;
///   * `An Organic Land` reports **quantity 0 with max 1000** — its stock is
///     not tracked, so capping at `quantity` would make it unbuyable.
///
/// The second is why the app must never derive the cap from `quantity`, and it
/// is the reason these fields were asked of the backend at all.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/product_model.dart';
import 'package:trueway_farms/data/models/server_cart.dart';

Map<String, dynamic> _product({
  int quantity = 85558,
  Object? min = 1,
  Object? max = 3,
}) =>
    {
      'id': 125,
      'slug': 'trueway-farms-organic-finger-millet-ragi-185-kg-125',
      'name': 'Trueway Farms Organic Finger Millet (ragi) 1.85 Kg',
      'sku': 'TRW3314-djZOO',
      'price': 313.95,
      'original_price': 570.15,
      'quantity': quantity,
      'is_out_of_stock': false,
      if (min != null) 'min_cart_quantity': min,
      if (max != null) 'max_cart_quantity': max,
    };

Map<String, dynamic> _line({int qty = 1, Object? min = 1, Object? max = 3}) => {
      'id': 125,
      'row_id': 'e89cfc3132e07146b2ff72d623ba44b0',
      'name': 'Trueway Farms Organic Finger Millet (ragi) 1.85 Kg',
      'quantity': qty,
      'price': 313.95,
      'cart_options': <String, dynamic>{},
      if (min != null) 'min_cart_quantity': min,
      if (max != null) 'max_cart_quantity': max,
    };

void main() {
  group('Product limits', () {
    test('reads the server-computed min and max', () {
      final p = Product.fromJson(_product(min: 2, max: 3));

      expect(p.minCartQuantity, 2);
      expect(p.maxCartQuantity, 3);
    });

    test('a first ADD starts at the minimum, not at 1', () {
      // `Sona Moti Wheat` is sold in twos. Adding 1 is refused, and a refusal
      // on this backend wipes the basket — see BACKEND_BUGS finding 0.
      expect(Product.fromJson(_product(min: 2)).initialCartQuantity, 2);
      expect(Product.fromJson(_product()).initialCartQuantity, 1);
    });

    test('NEVER caps at `quantity` — untracked stock reports 0', () {
      // The live row that proves the point: no stock recorded, still buyable
      // up to 1000.
      final p = Product.fromJson(_product(quantity: 0, min: 1, max: 1000));

      expect(p.quantity, 0);
      expect(p.maxCartQuantity, 1000);
      expect(p.canAdd(0), isTrue);
      expect(p.canAdd(999), isTrue);
      expect(p.canAdd(1000), isFalse);
    });

    test('clamps a wanted quantity into the server window', () {
      final p = Product.fromJson(_product(min: 2, max: 3));

      expect(p.clampCartQuantity(1), 2);
      expect(p.clampCartQuantity(2), 2);
      expect(p.clampCartQuantity(3), 3);
      expect(p.clampCartQuantity(99), 3);
    });

    test('an older server without the fields keeps the old behaviour', () {
      // 1 and 1000 are Botble's own fallbacks, so nothing is capped tighter
      // than the server would cap it.
      final p = Product.fromJson(_product(min: null, max: null));

      expect(p.minCartQuantity, 1);
      expect(p.maxCartQuantity, 1000);
    });

    test('a zero or negative max reads as "not stated", never as "none"', () {
      // A literal 0 would disable the product entirely, which is never what a
      // catalogue means by it.
      expect(Product.fromJson(_product(max: 0)).maxCartQuantity, 1000);
      expect(Product.fromJson(_product(max: -5)).maxCartQuantity, 1000);
    });

    test('a zero min is floored at 1', () {
      expect(Product.fromJson(_product(min: 0)).minCartQuantity, 1);
    });
  });

  group('ServerCartItem limits', () {
    test('reads the per-line limits the cart response carries', () {
      final item = ServerCartItem.fromJson(_line(qty: 1, min: 1, max: 3));

      expect(item.minCartQuantity, 1);
      expect(item.maxCartQuantity, 3);
    });

    test('stops incrementing at the maximum', () {
      expect(ServerCartItem.fromJson(_line(qty: 2, max: 3)).canIncrement, isTrue);
      expect(
        ServerCartItem.fromJson(_line(qty: 3, max: 3)).canIncrement,
        isFalse,
      );
      expect(ServerCartItem.fromJson(_line(qty: 3, max: 3)).isAtMaximum, isTrue);
    });

    test('stops decrementing at the minimum, not at 1', () {
      // A pack-of-two line stepped down to one is a quantity the server
      // rejects; removing the line is the legal move and the row has its own
      // control for that.
      final two = ServerCartItem.fromJson(_line(qty: 2, min: 2, max: 3));
      expect(two.canDecrement, isFalse);

      final three = ServerCartItem.fromJson(_line(qty: 3, min: 2, max: 3));
      expect(three.canDecrement, isTrue);
    });

    test('a line at a max of 1 can move in neither direction', () {
      final item = ServerCartItem.fromJson(_line(qty: 1, min: 1, max: 1));

      expect(item.canIncrement, isFalse);
      expect(item.canDecrement, isFalse);
      expect(item.isAtMaximum, isTrue);
    });

    test('an older server without the fields keeps the old behaviour', () {
      final item = ServerCartItem.fromJson(_line(qty: 5, min: null, max: null));

      expect(item.minCartQuantity, 1);
      expect(item.maxCartQuantity, 1000);
      expect(item.canIncrement, isTrue);
      expect(item.canDecrement, isTrue);
    });
  });
}

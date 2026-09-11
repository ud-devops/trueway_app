import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/home_sections.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/home_providers.dart';
import 'package:trueway_farms/presentation/widgets/flash_sale_section.dart';

import '../support/fake_cart_repository.dart';

/// Flash sales.
///
/// The shape was source-derived for a while — the store had never run a sale,
/// so `GET /ecommerce/flash-sales` answered `data: []`. **A real sale was
/// configured on 2026-08-11 and captured**, and the fixtures below now follow
/// it. See [group]`('the captured payload')` for the live figures.

/// One flash-sale row, in the shape the controller composes.
///
/// `FlashSaleProductResource` extends `AvailableProductResource` and
/// **overrides `price`** with the pivot price, so `price` here is the sale
/// price while `original_price` stays the catalogue one.
Map<String, dynamic> saleJson({
  String name = 'Monsoon flash sale',
  String? endDate = '2099-01-01 12:00:00',
  bool expired = false,
  List<Map<String, dynamic>>? products,
}) =>
    {
      'id': 3,
      'name': name,
      if (endDate != null) 'end_date': endDate,
      'expired': expired,
      'products': products ?? [productJson()],
    };

Map<String, dynamic> productJson({
  int id = 118,
  double price = 499,
  double originalPrice = 999,
  int quantity = 10,
  int sold = 4,
}) =>
    {
      'id': id,
      'slug': 'desi-khand',
      'name': 'Trueway Farms Organic Desi Khand',
      'price': price,
      'price_formatted': '₹${price.toStringAsFixed(2)}',
      'original_price': originalPrice,
      'original_price_formatted': '₹${originalPrice.toStringAsFixed(2)}',
      'quantity': quantity,
      'sold': sold,
      'sale_count_left': quantity - sold,
      // NOT a discount — `($pivot->sold / $pivot->quantity) * 100`.
      'sale_percent': quantity > 0 ? (sold / quantity) * 100 : 0,
      'is_out_of_stock': false,
    };

Future<Widget> _host(List<FlashSale> sales) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();

  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      cartRepositoryProvider.overrideWithValue(FakeCartRepository()),
      flashSalesProvider.overrideWith((ref) async => sales),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: const Scaffold(
        body: SingleChildScrollView(child: FlashSaleSection()),
      ),
    ),
  );
}

void main() {
  // -------------------------------------------------------------------------
  group('sale_percent is progress, not a discount', () {
    // The single most damaging misreading available here: rendering
    // `sale_percent` as a saving would advertise "80% OFF" on a sale that is
    // merely 80% sold out.
    test('is the share of the allocation already sold', () {
      final entry = FlashSaleProduct.fromJson(
        productJson(quantity: 10, sold: 8),
      );

      expect(entry.salePercent, 80);
      expect(entry.soldFraction, 0.8);
      // The actual saving comes from the two prices, and is a different number.
      expect(entry.product.discountPercent, 50);
      expect(entry.salePercent, isNot(entry.product.discountPercent));
    });

    test('an unlimited allocation reports no progress', () {
      // `quantity: 0` makes the server send `sale_percent: 0` rather than
      // dividing by zero.
      final entry = FlashSaleProduct.fromJson(
        productJson(quantity: 0, sold: 0),
      );

      expect(entry.salePercent, 0);
      expect(entry.isSoldOut, isFalse,
          reason: 'no allocation means unlimited, not sold out',);
    });

    test('an oversold row clamps rather than showing a negative', () {
      final json = productJson(quantity: 5, sold: 7)..['sale_count_left'] = -2;
      final entry = FlashSaleProduct.fromJson(json);

      expect(entry.remaining, 0);
      expect(entry.isSoldOut, isTrue);
      expect(entry.soldFraction, lessThanOrEqualTo(1.0));
    });
  });

  // -------------------------------------------------------------------------
  group('the captured payload', () {
    /// `GET /ecommerce/flash-sales`, captured live 2026-08-11 — sale "test
    /// sale", product 118, allocation 5, none sold.
    Map<String, dynamic> captured() => {
          'id': 118,
          'slug': 'trueway-farms-organic-desi-khand-brown-khandsari',
          'name': 'Trueway Farms Organic Desi Khand Brown (khandsari)',
          'price': 699.3,
          'price_formatted': '₹699.30',
          'original_price': 1199.1,
          'original_price_formatted': '₹1,199.10',
          'quantity': 5,
          'sold': 0,
          'sale_count_left': 5,
          'sale_percent': 0,
          'is_out_of_stock': false,
        };

    // `FlashSaleProductResource` used to publish the **raw pivot** under
    // `price`, bypassing `ProductPrice` — so the sale price arrived
    // tax-exclusive while every other price in the API is tax-inclusive. The
    // backend fixed it; this pins the fix.
    //
    // Proof it is fixed, from the same capture: adding product 118 to a cart
    // gives a line price of **666** ex-tax at `tax_rate: 5`, and
    // `666 × 1.05 = 699.30`. The endpoint reports 699.30, not 666. Before the
    // fix it reported 666, which would have shown the customer a price 5%
    // below what the cart charges.
    test('the sale price is tax-inclusive, matching the cart total', () {
      final entry = FlashSaleProduct.fromJson(captured());

      expect(entry.product.price, 699.3);
      expect(entry.product.price, isNot(666),
          reason: 'the raw pivot — what the unfixed resource returned',);
      // The cart's own total for this product, from the same capture.
      expect(entry.product.price, closeTo(666 * 1.05, 0.001));
    });

    // Both figures must share one convention or the badge is wrong. When
    // `price` was ex-tax and `original_price` inc-tax, this read 42% against a
    // true 42% only by coincidence of the ratio — with the mismatch it showed
    // (1199.10 − 666) / 1199.10 = 44%.
    test('price and original_price share the tax convention', () {
      final entry = FlashSaleProduct.fromJson(captured());

      expect(entry.product.originalPrice, 1199.1);
      // Same percentage whether computed inc- or ex-tax, which is the tell
      // that both sides scale together.
      expect(entry.product.discountPercent, 42);
      final exTax = ((1142 - 666) / 1142 * 100).round();
      expect(entry.product.discountPercent, exTax);
    });

    test('the allocation fields parse as sent', () {
      final entry = FlashSaleProduct.fromJson(captured());

      expect(entry.saleQuantity, 5);
      expect(entry.sold, 0);
      expect(entry.remaining, 5);
      expect(entry.isSoldOut, isFalse);
      expect(entry.soldFraction, 0);
    });

    test('the offset-less end_date parses', () {
      final sale = FlashSale.fromJson(
        saleJson(name: 'test sale', endDate: '2026-08-11 17:00:00'),
      );

      expect(sale.endsAt!.toUtc(), DateTime.utc(2026, 8, 11, 17));
      expect(sale.expired, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('the sale price', () {
    // `FlashSaleProductResource` overrides `price` with the pivot value, so the
    // ordinary product fields already carry the sale price — there is no second
    // figure to reconcile.
    test('replaces the catalogue price on the product itself', () {
      final entry = FlashSaleProduct.fromJson(
        productJson(price: 499, originalPrice: 999),
      );

      expect(entry.product.price, 499);
      expect(entry.salePrice, 499);
      expect(entry.product.originalPrice, 999);
      expect(entry.product.hasDiscount, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('end_date has no timezone', () {
    // `formatFlashSale` sends `Y-m-d H:i:s` with no offset while the server
    // runs on UTC. Parsing it as device-local would make an IST phone think the
    // sale ended 5h30m early.
    test('is read as UTC, not device local', () {
      final sale = FlashSale.fromJson(saleJson(endDate: '2030-06-01 10:00:00'));

      expect(sale.endsAt!.toUtc(), DateTime.utc(2030, 6, 1, 10));
    });

    test('an explicit zone is honoured as sent', () {
      final sale =
          FlashSale.fromJson(saleJson(endDate: '2030-06-01T10:00:00Z'));

      expect(sale.endsAt!.toUtc(), DateTime.utc(2030, 6, 1, 10));
    });

    test('an unparseable date is null rather than an epoch', () {
      final sale = FlashSale.fromJson(saleJson(endDate: 'not a date'));

      expect(sale.endsAt, isNull);
      expect(sale.timeLeft, isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('countdown formatting', () {
    // "50:14:09" reads as a broken clock, so days are spelled out.
    test('spells out days past 24 hours', () {
      expect(formatCountdown(const Duration(days: 2, hours: 3)), '2d 03h');
    });

    test('is hh:mm:ss under a day', () {
      expect(
        formatCountdown(const Duration(hours: 2, minutes: 14, seconds: 9)),
        '02:14:09',
      );
    });

    test('pads every field', () {
      expect(formatCountdown(const Duration(seconds: 5)), '00:00:05');
    });
  });

  // -------------------------------------------------------------------------
  group('the section', () {
    // The common case on this store: no sale configured. A heading over nothing
    // is worse than no heading.
    testWidgets('draws nothing at all when there is no sale', (tester) async {
      await tester.pumpWidget(await _host(const []));
      await tester.pumpAndSettle();

      expect(find.byType(FlashSaleCountdown), findsNothing);
      expect(find.textContaining('flash'), findsNothing);
      expect(find.textContaining('Flash'), findsNothing);
    });

    testWidgets('shows the name, a countdown and the products', (tester) async {
      await tester.pumpWidget(
        await _host([FlashSale.fromJson(saleJson())]),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(find.text('Monsoon flash sale'), findsOneWidget);
      expect(find.byType(FlashSaleCountdown), findsOneWidget);
      expect(find.textContaining('Ends in'), findsOneWidget);
      expect(find.text('6 left'), findsOneWidget);
    });

    testWidgets('shows the sale price beside the struck catalogue price',
        (tester) async {
      await tester.pumpWidget(
        await _host([FlashSale.fromJson(saleJson())]),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(find.text('₹499.00'), findsOneWidget);
      expect(find.text('₹999.00'), findsOneWidget);
      // The saving, not the sold-through percentage.
      expect(find.text('50% OFF'), findsOneWidget);
      expect(find.text('40% OFF'), findsNothing);
    });

    // The allocation running out is a **second** stock system on top of the
    // catalogue's: `is_out_of_stock` is false here, and the row is still
    // unbuyable. The shared card shows that the way it shows any sold-out
    // product — struck-out circle instead of ADD — so the two read alike.
    testWidgets('an exhausted allocation is unbuyable, though the catalogue '
        'still calls it in stock', (tester) async {
      final json = productJson(quantity: 5, sold: 5)..['sale_count_left'] = 0;
      expect(json['is_out_of_stock'], isFalse, reason: 'precondition');

      await tester.pumpWidget(
        await _host([
          FlashSale.fromJson(saleJson(products: [json])),
        ]),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(find.text('Sold out'), findsOneWidget);
      expect(find.byIcon(Icons.block_rounded), findsOneWidget);
      expect(find.text('ADD'), findsNothing);
    });

    // The countdown owns a periodic timer; a screen that leaves one running
    // rebuilds forever behind a static label.
    testWidgets('the countdown stops itself once the sale has ended',
        (tester) async {
      await tester.pumpWidget(
        await _host([
          FlashSale.fromJson(saleJson(endDate: '2000-01-01 00:00:00')),
        ]),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(find.text('Ended'), findsOneWidget);
      // No pending timer is left behind — pumpAndSettle would time out.
      await tester.pumpAndSettle(const Duration(seconds: 2));
    });
  });
}

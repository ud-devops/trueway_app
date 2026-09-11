import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/core/utils/price_utils.dart';
import 'package:trueway_farms/data/models/server_cart.dart';
import 'package:trueway_farms/data/repositories/cart_repository.dart';

// ===========================================================================
// Payloads captured live from dev.truewayerp.com. Verbatim — including the
// ₹ escapes and \/ escaping the server emits — so the decoder is exercised
// on exactly what ships.
// ===========================================================================

/// POST /ecommerce/cart {product_id: 118, qty: 1} — mints a cart. Note the
/// POST-only `status` + `content` tail.
const _cartCreate = r'''
{"id":"719c661a-6c80-423e-bac4-c0a97388756c","cart_items":{"5acb3bfb23270b5161fbb3652d44abd6":{"id":118,"row_id":"5acb3bfb23270b5161fbb3652d44abd6","name":"Trueway Farms Organic Desi Khand Brown (khandsari)","quantity":1,"select_qty":1,"description":null,"price":899,"price_formatted":"₹899.00","original_price":null,"original_price_formatted":"₹0.00","subtotal":899,"subtotal_formatted":"₹899.00","total_price":943.95,"total_price_formatted":"₹943.95","tax_price":44.95,"tax_price_formatted":"₹44.95","tax_total":44.95,"tax_total_formatted":"₹44.95","tax_rate":5,"weight":5100,"height":24,"length":19,"wide":6,"image":"https:\/\/dev.truewayerp.com\/storage\/products\/whole-wheat\/81xa52v7tol-sx679.jpg","image_url":"https:\/\/dev.truewayerp.com\/storage\/products\/whole-wheat\/81xa52v7tol-sx679.jpg","options":[],"cart_options":{"image":"https:\/\/dev.truewayerp.com\/storage\/products\/whole-wheat\/81xa52v7tol-sx679.jpg","attributes":"","taxRate":5,"taxClasses":{"gst":5},"options":[],"extras":[],"sku":"TRW3215","weight":5100,"height":24,"length":19,"wide":6,"store":{"id":10,"slug":"trueway-farms-1","name":"Trueway Farms","zip_code":"311001"}},"variation_attributes":"","option_values":[],"product_type":null}},"count":1,"total_weight":5100,"total_height":24,"total_wide":6,"total_length":19,"total_volume":2736,"package_dimensions":{"length":20,"breadth":7,"height":25,"weight":5.1,"box_id":null,"box_name":null},"raw_sub_total":899,"raw_sub_total_formatted":"₹899.00","raw_total":943.95,"raw_total_formatted":"₹943.95","promotion_discount_amount":0,"promotion_discount_amount_formatted":"₹0.00","coupon_discount_amount":0,"coupon_discount_amount_formatted":"₹0.00","applied_coupon_code":null,"discounted_sub_total":899,"discounted_sub_total_formatted":"₹899.00","discounted_tax_amount":44.95,"discounted_tax_amount_formatted":"₹44.95","order_total":943.95,"order_total_formatted":"₹943.95","status":true,"content":{"5acb3bfb23270b5161fbb3652d44abd6":{"rowId":"5acb3bfb23270b5161fbb3652d44abd6","id":118,"name":"Trueway Farms Organic Desi Khand Brown (khandsari)","qty":1,"price":899,"options":{"image":"products\/whole-wheat\/81xa52v7tol-sx679.jpg","attributes":"","taxRate":5,"taxClasses":{"gst":5},"options":[],"extras":[],"sku":"TRW3215","weight":5100,"height":24,"length":19,"wide":6},"tax":44.95,"subtotal":899,"updated_at":"2026-08-01T07:16:24.567469Z"}}}
''';

/// GET /ecommerce/cart/{id} — no `status`/`content`.
const _cartGet = r'''
{"id":"9dfd9610-e4ce-4d6f-8836-56dae7b4b5d1","cart_items":{"5acb3bfb23270b5161fbb3652d44abd6":{"id":118,"row_id":"5acb3bfb23270b5161fbb3652d44abd6","name":"Trueway Farms Organic Desi Khand Brown (khandsari)","quantity":2,"select_qty":2,"description":null,"price":899,"price_formatted":"₹899.00","original_price":null,"original_price_formatted":"₹0.00","subtotal":1798,"subtotal_formatted":"₹1,798.00","total_price":1887.9,"total_price_formatted":"₹1,887.90","tax_price":44.95,"tax_price_formatted":"₹44.95","tax_total":89.9,"tax_total_formatted":"₹89.90","tax_rate":5,"weight":5100,"height":24,"length":19,"wide":6,"image":"https:\/\/dev.truewayerp.com\/storage\/products\/whole-wheat\/81xa52v7tol-sx679.jpg","image_url":"https:\/\/dev.truewayerp.com\/storage\/products\/whole-wheat\/81xa52v7tol-sx679.jpg","options":[],"cart_options":{"image":"https:\/\/dev.truewayerp.com\/storage\/products\/whole-wheat\/81xa52v7tol-sx679.jpg","attributes":"","taxRate":5,"taxClasses":{"gst":5},"options":[],"extras":[],"sku":"TRW3215","weight":5100,"height":24,"length":19,"wide":6,"store":{"id":10,"slug":"trueway-farms-1","name":"Trueway Farms","zip_code":"311001"}},"variation_attributes":"","option_values":[],"product_type":null}},"count":2,"total_weight":10200,"total_height":48,"total_wide":12,"total_length":38,"total_volume":5472,"package_dimensions":{"length":20,"breadth":7,"height":49,"weight":10.2,"box_id":null,"box_name":null},"raw_sub_total":1798,"raw_sub_total_formatted":"₹1,798.00","raw_total":1887.9,"raw_total_formatted":"₹1,887.90","promotion_discount_amount":0,"promotion_discount_amount_formatted":"₹0.00","coupon_discount_amount":0,"coupon_discount_amount_formatted":"₹0.00","applied_coupon_code":null,"discounted_sub_total":1798,"discounted_sub_total_formatted":"₹1,798.00","discounted_tax_amount":89.9,"discounted_tax_amount_formatted":"₹89.90","order_total":1887.9,"order_total_formatted":"₹1,887.90"}
''';

/// The shape every wipe produces: `cart_items` flips from a keyed map to `[]`.
const _emptyCart = r'''
{"id":"53771491-b9db-4b63-b954-4c48cdf1bbb9","cart_items":[],"count":0,"total_weight":0,"total_height":0,"total_wide":0,"total_length":0,"total_volume":0,"package_dimensions":{"length":10,"breadth":15,"height":20,"weight":0.5,"box_id":null,"box_name":null},"raw_sub_total":0,"raw_sub_total_formatted":"₹0.00","raw_total":0,"raw_total_formatted":"₹0.00","promotion_discount_amount":0,"promotion_discount_amount_formatted":"₹0.00","coupon_discount_amount":0,"coupon_discount_amount_formatted":"₹0.00","applied_coupon_code":null,"discounted_sub_total":0,"discounted_sub_total_formatted":"₹0.00","discounted_tax_amount":0,"discounted_tax_amount_formatted":"₹0.00","order_total":0,"order_total_formatted":"₹0.00"}
''';

/// POST {product_id: 111} — the created line's id is 116, the default variation.
const _variationCreate = r'''
{"id":"53771491-b9db-4b63-b954-4c48cdf1bbb9","cart_items":{"bf255932ac9d0227ef1dc89d808f54f3":{"id":116,"row_id":"bf255932ac9d0227ef1dc89d808f54f3","name":"Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu)","quantity":2,"select_qty":2,"description":null,"price":877.62,"price_formatted":"₹877.62","original_price":null,"original_price_formatted":"₹0.00","subtotal":1755.24,"subtotal_formatted":"₹1,755.24","total_price":1843.002,"total_price_formatted":"₹1,843.00","tax_price":43.881,"tax_price_formatted":"₹43.88","tax_total":87.762,"tax_total_formatted":"₹87.76","tax_rate":5,"weight":5000,"height":34,"length":26,"wide":8,"image":"https://dev.truewayerp.com/storage/products/whole-wheat/81lm1nhmzol-sx679.jpg","image_url":"https://dev.truewayerp.com/storage/products/whole-wheat/81lm1nhmzol-sx679.jpg","options":[],"cart_options":{"image":"https://dev.truewayerp.com/storage/products/whole-wheat/81lm1nhmzol-sx679.jpg","attributes":"(Pack Size: 5 KG (Pack of 1))","taxRate":5,"taxClasses":{"gst":5},"options":[],"extras":[],"sku":"TRW3214","weight":5000,"height":34,"length":26,"wide":8,"store":{"id":10,"slug":"trueway-farms-1","name":"Trueway Farms","zip_code":"311001"}},"variation_attributes":"(Pack Size: 5 KG (Pack of 1))","option_values":[],"product_type":null}},"count":2,"total_weight":10000,"total_height":68,"total_wide":16,"total_length":52,"total_volume":14144,"package_dimensions":{"length":27,"breadth":9,"height":69,"weight":10,"box_id":null,"box_name":null},"raw_sub_total":1755.24,"raw_sub_total_formatted":"₹1,755.24","raw_total":1843.002,"raw_total_formatted":"₹1,843.00","promotion_discount_amount":0,"promotion_discount_amount_formatted":"₹0.00","coupon_discount_amount":0,"coupon_discount_amount_formatted":"₹0.00","applied_coupon_code":null,"discounted_sub_total":1755.24,"discounted_sub_total_formatted":"₹1,755.24","discounted_tax_amount":87.76,"discounted_tax_amount_formatted":"₹87.76","order_total":1843,"order_total_formatted":"₹1,843.00","status":true,"content":{"bf255932ac9d0227ef1dc89d808f54f3":{"rowId":"bf255932ac9d0227ef1dc89d808f54f3","id":116,"name":"Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu)","qty":2,"price":877.62,"options":{"image":"products/whole-wheat/81lm1nhmzol-sx679.jpg","attributes":"(Pack Size: 5 KG (Pack of 1))","taxRate":5,"taxClasses":{"gst":5},"options":[],"extras":[],"sku":"TRW3214","weight":5000,"height":34,"length":26,"wide":8},"tax":43.881,"subtotal":1755.24,"updated_at":"2026-08-01T10:42:19.164864Z"}}}
''';

/// PUT {product_id: 111} against a cart already holding line 116 — the upsert
/// added a second line instead of updating the first.
const _putDuplicatedVariation = r'''
{"id":"475d3d7f-c7da-4bcd-85e7-14efc2bcf845","cart_items":{"bf255932ac9d0227ef1dc89d808f54f3":{"id":116,"row_id":"bf255932ac9d0227ef1dc89d808f54f3","name":"Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu)","quantity":2,"select_qty":2,"description":null,"price":877.62,"price_formatted":"₹877.62","original_price":null,"original_price_formatted":"₹0.00","subtotal":1755.24,"subtotal_formatted":"₹1,755.24","total_price":1843.002,"total_price_formatted":"₹1,843.00","tax_price":43.881,"tax_price_formatted":"₹43.88","tax_total":87.762,"tax_total_formatted":"₹87.76","tax_rate":5,"weight":5000,"height":34,"length":26,"wide":8,"image":"https://dev.truewayerp.com/storage/products/whole-wheat/81lm1nhmzol-sx679.jpg","image_url":"https://dev.truewayerp.com/storage/products/whole-wheat/81lm1nhmzol-sx679.jpg","options":[],"cart_options":{"image":"https://dev.truewayerp.com/storage/products/whole-wheat/81lm1nhmzol-sx679.jpg","attributes":"(Pack Size: 5 KG (Pack of 1))","taxRate":5,"taxClasses":{"gst":5},"options":[],"extras":[],"sku":"TRW3214","weight":5000,"height":34,"length":26,"wide":8,"store":{"id":10,"slug":"trueway-farms-1","name":"Trueway Farms","zip_code":"311001"}},"variation_attributes":"(Pack Size: 5 KG (Pack of 1))","option_values":[],"product_type":null},"a05488848b31c4ccc076304c71853605":{"id":111,"row_id":"a05488848b31c4ccc076304c71853605","name":"Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu)","quantity":5,"select_qty":5,"description":null,"price":877.62,"price_formatted":"₹877.62","original_price":null,"original_price_formatted":"₹0.00","subtotal":4388.1,"subtotal_formatted":"₹4,388.10","total_price":4607.505,"total_price_formatted":"₹4,607.51","tax_price":43.881,"tax_price_formatted":"₹43.88","tax_total":219.405,"tax_total_formatted":"₹219.41","tax_rate":5,"weight":5000,"height":34,"length":26,"wide":8,"image":"https://dev.truewayerp.com/storage/products/whole-wheat/81lm1nhmzol-sx679.jpg","image_url":"https://dev.truewayerp.com/storage/products/whole-wheat/81lm1nhmzol-sx679.jpg","options":[],"cart_options":{"image":"https://dev.truewayerp.com/storage/products/whole-wheat/81lm1nhmzol-sx679.jpg","attributes":"","taxRate":5,"taxClasses":{"gst":5},"options":[],"extras":[],"sku":"TRW3214","weight":5000,"height":34,"length":26,"wide":8,"store":{"id":10,"slug":"trueway-farms-1","name":"Trueway Farms","zip_code":"311001"}},"variation_attributes":"","option_values":[],"product_type":null}},"count":7,"total_weight":35000,"total_height":238,"total_wide":56,"total_length":182,"total_volume":49504,"package_dimensions":{"length":27,"breadth":9,"height":239,"weight":35,"box_id":null,"box_name":null},"raw_sub_total":6143.34,"raw_sub_total_formatted":"₹6,143.34","raw_total":6450.507,"raw_total_formatted":"₹6,450.51","promotion_discount_amount":0,"promotion_discount_amount_formatted":"₹0.00","coupon_discount_amount":0,"coupon_discount_amount_formatted":"₹0.00","applied_coupon_code":null,"discounted_sub_total":6143.34,"discounted_sub_total_formatted":"₹6,143.34","discounted_tax_amount":307.17,"discounted_tax_amount_formatted":"₹307.17","order_total":6450.51,"order_total_formatted":"₹6,450.51","status":true,"content":{"bf255932ac9d0227ef1dc89d808f54f3":{"rowId":"bf255932ac9d0227ef1dc89d808f54f3","id":116,"name":"Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu)","qty":2,"price":877.62,"options":{"image":"products/whole-wheat/81lm1nhmzol-sx679.jpg","attributes":"(Pack Size: 5 KG (Pack of 1))","taxRate":5,"taxClasses":{"gst":5},"options":[],"extras":[],"sku":"TRW3214","weight":5000,"height":34,"length":26,"wide":8},"tax":43.881,"subtotal":1755.24,"updated_at":"2026-08-01T10:40:12.673507Z"},"a05488848b31c4ccc076304c71853605":{"rowId":"a05488848b31c4ccc076304c71853605","id":111,"name":"Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu)","qty":5,"price":877.62,"options":{"image":"products/whole-wheat/81lm1nhmzol-sx679.jpg","attributes":"","taxRate":5,"taxClasses":{"gst":5},"options":[],"extras":[],"sku":"TRW3214","weight":5000,"height":34,"length":26,"wide":8},"tax":43.881,"subtotal":4388.1,"updated_at":"2026-08-01T10:40:13.117731Z"}}}
''';

/// POST /ecommerce/coupon/remove — envelope-wrapped, `cart_id` instead of `id`,
/// and `cart_items` in the raw Cart `content` shape with no formatted twins.
const _couponRemoveSuccess = r'''
{"error":false,"data":{"cart_items":{"5acb3bfb23270b5161fbb3652d44abd6":{"rowId":"5acb3bfb23270b5161fbb3652d44abd6","id":118,"name":"Trueway Farms Organic Desi Khand Brown (khandsari)","qty":2,"price":899,"options":{"image":"products\/whole-wheat\/81xa52v7tol-sx679.jpg","attributes":"","taxRate":5,"taxClasses":{"gst":5},"options":[],"extras":[],"sku":"TRW3215","weight":5100,"height":24,"length":19,"wide":6},"tax":44.95,"subtotal":1798,"updated_at":"2026-08-01T07:25:46.494654Z"}},"count":2,"raw_sub_total":1798,"raw_sub_total_formatted":"₹1,798.00","raw_total":1887.9,"raw_total_formatted":"₹1,887.90","promotion_discount_amount":0,"promotion_discount_amount_formatted":"₹0.00","coupon_discount_amount":0,"coupon_discount_amount_formatted":"₹0.00","applied_coupon_code":null,"discounted_sub_total":1798,"discounted_sub_total_formatted":"₹1,798.00","discounted_tax_amount":89.9,"discounted_tax_amount_formatted":"₹89.90","order_total":1887.9,"order_total_formatted":"₹1,887.90","cart_id":"149e2ac6-9b1e-44f1-b247-a26e53bc172f"},"message":"Removed coupon code successfully!"}
''';

/// "Applied coupon successfully" on a cart that is empty and has no coupon —
/// the reason the repository never trusts this body.
const _couponApplyEmptyCart = r'''
{"error":false,"data":{"cart_items":[],"count":0,"raw_sub_total":0,"raw_sub_total_formatted":"₹0.00","raw_total":0,"raw_total_formatted":"₹0.00","promotion_discount_amount":0,"promotion_discount_amount_formatted":"₹0.00","coupon_discount_amount":0,"coupon_discount_amount_formatted":"₹0.00","applied_coupon_code":null,"discounted_sub_total":0,"discounted_sub_total_formatted":"₹0.00","discounted_tax_amount":0,"discounted_tax_amount_formatted":"₹0.00","order_total":0,"order_total_formatted":"₹0.00","cart_id":"47a328fe-2de0-40c6-914a-d3cbafd46766"},"message":"Applied coupon \"FRESH10\" successfully!"}
''';

/// HTTP 200 + `error: true` — the channel every business refusal arrives on.
const _overStock = {
  'error': true,
  'data': null,
  'message': 'Maximum quantity is 1891!',
};

const _couponRejected = {
  'error': true,
  'data': null,
  'message': 'This coupon is invalid or expired!',
};

/// DELETE success. Not an object — a bare JSON string.
const _deleteOk = 'Cart item removed successfully';

/// DELETE of a product that is not in the cart. 404, and the cart is now gone.
const _notInCart = {'error': 'Cart item not found'};

/// The one branch where `error` is a string rather than a bool.
const _apiKeyRejected = {
  'message': 'Invalid or missing API key. Please provide a valid X-API-KEY header.',
  'error': 'Unauthorized',
};

Map<String, dynamic> _decode(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

// ===========================================================================
// Transport fake
// ===========================================================================

class _Canned {
  const _Canned(this.statusCode, this.body);
  final int statusCode;
  final Object body;
}

/// Replays canned responses keyed by `METHOD /path`, and records the requests.
///
/// Keyed by method as well as path because the whole cart lives on one URL —
/// a POST, PUT, DELETE and GET of `/ecommerce/cart/{id}` do four different
/// things. A list per key is consumed in order, so a mutation and the re-read
/// that follows it can return different carts.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(Map<String, List<_Canned>> responses)
      : _responses = {
          for (final e in responses.entries) e.key: List<_Canned>.of(e.value),
        };

  final Map<String, List<_Canned>> _responses;
  final List<RequestOptions> requests = [];

  List<String> get calls =>
      requests.map((r) => '${r.method} ${r.path}').toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final queue = _responses['${options.method} ${options.path}'];
    final canned = queue == null || queue.isEmpty
        ? const _Canned(404, {'message': 'no canned response'})
        : (queue.length == 1 ? queue.first : queue.removeAt(0));
    return ResponseBody.fromString(
      jsonEncode(canned.body),
      canned.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<({CartRepository repo, _FakeAdapter adapter})> _build(
  Map<String, List<_Canned>> responses,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(responses);
  final dio = Dio()..httpClientAdapter = adapter;
  return (repo: CartRepository(ApiClient(prefs: prefs, dio: dio)), adapter: adapter);
}

const _cartId = '9dfd9610-e4ce-4d6f-8836-56dae7b4b5d1';
const _cartPath = '/ecommerce/cart/$_cartId';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // =========================================================================
  group('ServerCart.fromJson', () {
    test('parses a freshly minted cart', () {
      final cart = ServerCart.fromJson(_decode(_cartCreate));

      expect(cart.id, '719c661a-6c80-423e-bac4-c0a97388756c');
      expect(cart.count, 1);
      expect(cart.items, hasLength(1));
      expect(cart.isEmpty, isFalse);
      expect(cart.hasCoupon, isFalse);
      expect(cart.appliedCouponCode, isNull);
      expect(cart.orderTotal.amount, 943.95);
      expect(cart.orderTotal.display, '₹943.95');
      expect(cart.packageDimensions!.weight, 5.1);
      expect(cart.packageDimensions!.boxId, isNull);

      final line = cart.items.single;
      expect(line.lineId, const CartLineId.forSimpleProduct(118));
      expect(line.rowId, '5acb3bfb23270b5161fbb3652d44abd6');
      expect(line.quantity, 1);
      expect(line.unitPrice.display, '₹899.00');
      expect(line.sku, 'TRW3215');
      expect(line.taxRate, 5);
      expect(line.weight, 5100);
      expect(line.isVariation, isFalse);
      expect(line.variationLabel, isNull); // arrived as ""
      expect(line.originalPrice, isNull); // arrived as null
      expect(line.description, isNull);
      expect(line.options, isEmpty);
      expect(
        line.imageUrl,
        'https://dev.truewayerp.com/storage/products/whole-wheat/81xa52v7tol-sx679.jpg',
      );
    });

    test('reads totals off a multi-unit GET without recomputing them', () {
      final cart = ServerCart.fromJson(_decode(_cartGet));
      final line = cart.items.single;

      expect(cart.count, 2);
      expect(line.quantity, 2);
      expect(line.subtotal.display, '₹1,798.00');
      expect(line.unitTax.amount, 44.95);
      expect(line.totalTax.amount, 89.9);
      expect(line.lineTotal.amount, 1887.9);
      expect(cart.totalWeight, 10200);
      expect(cart.discountedTax.display, '₹89.90');
      expect(cart.orderTotal.display, '₹1,887.90');
    });

    test('survives cart_items flipping from a map to an empty array', () {
      // `as Map` throws here — and this is the shape every wipe produces, so it
      // is the single most important payload in this file.
      final cart = ServerCart.fromJson(_decode(_emptyCart));

      expect(cart.items, isEmpty);
      expect(cart.isEmpty, isTrue);
      expect(cart.count, 0);
      expect(cart.orderTotal.amount, 0);
      expect(cart.orderTotal.display, '₹0.00');
      expect(cart.packageDimensions, isNotNull);
    });

    test('keeps the variation id, not the product id that was added', () {
      // POST {product_id: 111} produced this. Sending 111 back to DELETE would
      // 404 and wipe the cart.
      final cart = ServerCart.fromJson(_decode(_variationCreate));
      final line = cart.items.single;

      expect(line.lineId.value, 116);
      expect(line.isVariation, isTrue);
      expect(line.variationLabel, '(Pack Size: 5 KG (Pack of 1))');
      expect(cart.lineFor(const CartLineId.forSimpleProduct(111)), isNull);
      expect(cart.quantityOf(const CartLineId.forSimpleProduct(116)), 2);
    });

    test('prefers the server label over the raw amount for display', () {
      // 1843.002 is what the server computed; ₹1,843.00 is what it renders, and
      // what the customer will see on the order.
      final line = ServerCart.fromJson(_decode(_variationCreate)).items.single;

      expect(line.lineTotal.amount, 1843.002);
      expect(line.lineTotal.display, '₹1,843.00');
      expect(line.totalTax.amount, 87.762);
      expect(line.totalTax.display, '₹87.76');
    });

    test('holds both lines when PUT duplicates a variable product', () {
      final cart = ServerCart.fromJson(_decode(_putDuplicatedVariation));

      expect(cart.items, hasLength(2));
      expect(cart.items.map((i) => i.lineId.value), [116, 111]);
      // count is units, not lines.
      expect(cart.count, 7);
      expect(cart.quantityOf(const CartLineId.forSimpleProduct(116)), 2);
      expect(cart.quantityOf(const CartLineId.forSimpleProduct(111)), 5);
      // The duplicate carries no variation label, which is how the UI can tell
      // the two apart.
      expect(cart.items.last.variationLabel, isNull);
    });

    test('fills in everything the payload omits', () {
      final cart = ServerCart.fromJson(const {}, fallbackId: 'abc');

      expect(cart.id, 'abc');
      expect(cart.items, isEmpty);
      expect(cart.count, 0);
      expect(cart.packageDimensions, isNull);
      expect(cart.rawSubTotal.amount, 0);
      expect(cart.rawSubTotal.formatted, isNull);
      expect(cart.orderTotal.display, PriceUtils.format(0));
      expect(cart.hasDiscount, isFalse);
    });

    test('parses a line that carries nothing but an id', () {
      final line = ServerCartItem.fromJson(const {'id': 118});

      expect(line.lineId.value, 118);
      expect(line.rowId, '');
      expect(line.name, '');
      expect(line.quantity, 1);
      expect(line.imageUrl, '');
      expect(line.sku, isNull);
      expect(line.weight, isNull);
      expect(line.subtotal.amount, 0);
    });

    test('coerces money-as-string and count-as-string', () {
      // Amounts arrive as num on the cart routes and as 2dp strings elsewhere;
      // the same model has to survive either.
      final json = _decode(_cartGet)
        ..['order_total'] = '1274.15'
        ..['count'] = '3'
        ..['raw_sub_total'] = '1213.48';

      final cart = ServerCart.fromJson(json);

      expect(cart.orderTotal.amount, 1274.15);
      expect(cart.rawSubTotal.amount, 1213.48);
      expect(cart.count, 3);
      // The formatted twin is still the one displayed.
      expect(cart.orderTotal.display, '₹1,887.90');
    });

    test('treats a null package_dimensions as absent', () {
      final json = _decode(_cartGet)..['package_dimensions'] = null;
      expect(ServerCart.fromJson(json).packageDimensions, isNull);
    });

    test('reads chosen options out of the resource shape', () {
      // Synthetic: no product in this catalogue has options, so all 135
      // captured lines had `options: []`. Field names are CartItemResource's —
      // the collection is keyed by option id, so it serializes as an object.
      final json = _decode(_cartGet);
      final line = (json['cart_items'] as Map).values.first as Map;
      line['options'] = {
        '7': {
          'option_type': 'dropdown',
          'values': 'Gift wrap',
          'affect_type': 0,
          'affect_price': 50,
          'price_label': '₹50.00',
        },
      };

      final parsed = ServerCart.fromJson(json).items.single.options.single;

      expect(parsed.type, 'dropdown');
      expect(parsed.value, 'Gift wrap');
      expect(parsed.priceLabel, '₹50.00');
      expect(parsed.affectPrice, 50);
    });
  });

  // =========================================================================
  // `cart_options.store.zip_code` — rung 2 of the server's own
  // ShipRocketService::getPickupPostcode() chain, and the only rung the mobile
  // API exposes. `ShippingQuery.fromCart` quotes from it so the app follows a
  // store move instead of holding a copy of the warehouse postcode.
  group('storeZipCode', () {
    test('is read off every line of a real cart', () {
      for (final body in [_cartCreate, _cartGet, _variationCreate]) {
        final cart = ServerCart.fromJson(_decode(body));
        expect(cart.items, isNotEmpty);
        for (final line in cart.items) {
          expect(
            line.storeZipCode,
            '311001',
            reason: 'every live line carries the Bhilwara store',
          );
        }
      }
    });

    // The raw `Cart` content shape has no `cart_options` bag at all — its
    // `options` key is the bag, and it carries no store. Null, not a value
    // hallucinated out of the wrong key.
    test('is null on the raw content line shape', () {
      final cart = ServerCart.tryFrom(_decode(_couponRemoveSuccess))!;
      expect(cart.items.single.storeZipCode, isNull);
    });

    test('is null when the store block is absent or empty', () {
      ServerCartItem line(Object? store) => ServerCartItem.fromJson({
            'id': 118,
            'quantity': 1,
            'price': 899,
            'cart_options': {if (store != null) 'store': store},
          });

      expect(line(null).storeZipCode, isNull);
      expect(line(const <String, dynamic>{}).storeZipCode, isNull);
      expect(line(const {'id': 10}).storeZipCode, isNull);
      expect(line(const {'zip_code': ''}).storeZipCode, isNull);
      expect(line(const {'zip_code': '   '}).storeZipCode, isNull);
      expect(line('not a map').storeZipCode, isNull);
      // Trimmed, and coerced from the number form the column has been seen as
      // on sibling endpoints.
      expect(line(const {'zip_code': ' 311001 '}).storeZipCode, '311001');
      expect(line(const {'zip_code': 311001}).storeZipCode, '311001');
    });
  });

  // =========================================================================
  group('ServerCart.tryFrom', () {
    test('unwraps the coupon envelope and the raw content line shape', () {
      final cart = ServerCart.tryFrom(_decode(_couponRemoveSuccess))!;

      expect(cart.id, '149e2ac6-9b1e-44f1-b247-a26e53bc172f'); // from cart_id
      expect(cart.count, 2);

      final line = cart.items.single;
      expect(line.lineId.value, 118);
      expect(line.rowId, '5acb3bfb23270b5161fbb3652d44abd6'); // rowId, not row_id
      expect(line.quantity, 2); // qty, not quantity
      expect(line.sku, 'TRW3215'); // out of `options`, not `cart_options`
      // The content shape has a per-unit `tax` and no line totals at all.
      expect(line.unitTax.amount, 44.95);
      expect(line.totalTax.amount, closeTo(89.9, 0.001));
      expect(line.lineTotal.amount, closeTo(1887.9, 0.001));
      // No _formatted twins on this shape, so display falls back to our own
      // formatter rather than showing a raw double.
      expect(line.subtotal.formatted, isNull);
      expect(line.subtotal.display, PriceUtils.format(1798));
      // And its image is storage-relative, unlike image_url on the cart routes.
      expect(
        line.imageUrl,
        'https://dev.truewayerp.com/storage/products/whole-wheat/81xa52v7tol-sx679.jpg',
      );
    });

    test('does not mistake the content shape\'s options bag for line options',
        () {
      // On this shape `options` is the cart-options bag, not the customer's
      // chosen options: {image, attributes, taxRate, taxClasses:{gst:5},
      // options:[], extras:[], sku, weight, height, length, wide}. Walking its
      // values for maps finds `taxClasses` and mints a blank option out of it,
      // which is a phantom row under every line on a coupon response.
      final line = ServerCart.tryFrom(_decode(_couponRemoveSuccess))!.items.single;

      expect(line.options, isEmpty);
      // The bag itself is still read for the fields that do live in it.
      expect(line.sku, 'TRW3215');
      expect(line.taxRate, 5);
      expect(line.weight, 5100);
    });

    test('reports no coupon even when the message says one was applied', () {
      final cart = ServerCart.tryFrom(_decode(_couponApplyEmptyCart))!;

      expect(cart.id, '47a328fe-2de0-40c6-914a-d3cbafd46766');
      expect(cart.isEmpty, isTrue);
      expect(cart.appliedCouponCode, isNull);
      expect(cart.hasCoupon, isFalse);
    });

    test('returns null for bodies that carry no cart', () {
      expect(ServerCart.tryFrom(_deleteOk), isNull);
      expect(ServerCart.tryFrom(_overStock), isNull);
      expect(ServerCart.tryFrom(_notInCart), isNull);
      expect(ServerCart.tryFrom(_apiKeyRejected), isNull);
      expect(ServerCart.tryFrom(null), isNull);
      expect(ServerCart.tryFrom(const []), isNull);
    });

    test('falls back to the POST-only content block', () {
      // `cart_items` is what the UI should read, but if it ever went missing the
      // same lines are duplicated under `content` on POST responses.
      final json = _decode(_cartCreate)..remove('cart_items');
      final cart = ServerCart.tryFrom(json)!;

      expect(cart.items, hasLength(1));
      expect(cart.items.single.lineId.value, 118);
      expect(cart.items.single.quantity, 1);
    });
  });

  // =========================================================================
  group('CartLineId', () {
    test('compares by value', () {
      expect(
        const CartLineId.forSimpleProduct(116),
        const CartLineId.forSimpleProduct(116),
      );
      expect(
        const CartLineId.forSimpleProduct(116),
        isNot(const CartLineId.forSimpleProduct(111)),
      );
    });
  });

  // =========================================================================
  group('CartRepository reads', () {
    test('fetch parses the cart', () async {
      final t = await _build({
        'GET $_cartPath': [_Canned(200, _decode(_cartGet))],
      });

      final cart = await t.repo.fetch(_cartId);

      expect(cart.count, 2);
      expect(t.adapter.calls, ['GET $_cartPath']);
    });

    test('fetch surfaces the string-valued Unauthorized branch as an error',
        () async {
      final t = await _build({
        'GET $_cartPath': [const _Canned(401, _apiKeyRejected)],
      });

      await expectLater(
        t.repo.fetch(_cartId),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiErrorKind.unauthorized),
        ),
      );
    });

    test('fetch rejects a 200 that is not a cart', () async {
      final t = await _build({
        'GET $_cartPath': [const _Canned(200, 'not a cart')],
      });

      await expectLater(t.repo.fetch(_cartId), throwsA(isA<ApiException>()));
    });
  });

  // =========================================================================
  group('CartRepository.createCart', () {
    test('returns the minted cart and its id', () async {
      final t = await _build({
        'POST /ecommerce/cart': [_Canned(200, _decode(_cartCreate))],
      });

      final result = await t.repo.createCart(productId: 118);

      expect(result.isSuccess, isTrue);
      expect(result.cart!.id, '719c661a-6c80-423e-bac4-c0a97388756c');
      expect(t.adapter.requests.single.data, {'product_id': 118, 'qty': 1});
    });

    test('reports failure with no cart, because none exists yet', () async {
      final t = await _build({
        'POST /ecommerce/cart': [const _Canned(200, _overStock)],
      });

      final result = await t.repo.createCart(productId: 118, qty: 99999);

      expect(result.isSuccess, isFalse);
      expect(result.message, 'Maximum quantity is 1891!');
      expect(result.cart, isNull);
      // Nothing to re-read — no follow-up request was made.
      expect(t.adapter.calls, ['POST /ecommerce/cart']);
    });
  });

  // =========================================================================
  group('CartRepository mutations', () {
    test('addItem uses the response cart and does not re-read', () async {
      final t = await _build({
        'POST $_cartPath': [_Canned(200, _decode(_cartGet))],
      });

      final result = await t.repo.addItem(cartId: _cartId, productId: 118, qty: 2);

      expect(result.isSuccess, isTrue);
      expect(result.cart!.count, 2);
      expect(t.adapter.calls, ['POST $_cartPath']);
      expect(t.adapter.requests.single.data, {'product_id': 118, 'qty': 2});
    });

    test('a refused add returns the error AND the cart the server kept',
        () async {
      // The defining behaviour: adding an over-stock quantity is refused with
      // HTTP 200 + error:true, and the two unrelated items that were in the
      // cart are gone. The caller must be handed the empty cart, not the one it
      // was holding.
      final t = await _build({
        'POST $_cartPath': [const _Canned(200, _overStock)],
        'GET $_cartPath': [_Canned(200, _decode(_emptyCart))],
      });

      final result =
          await t.repo.addItem(cartId: _cartId, productId: 118, qty: 99999);

      expect(result.isSuccess, isFalse);
      expect(result.error!.kind, ApiErrorKind.businessRule);
      expect(result.message, 'Maximum quantity is 1891!');
      expect(result.isCartKnown, isTrue);
      expect(result.cart!.isEmpty, isTrue);
      expect(t.adapter.calls, ['POST $_cartPath', 'GET $_cartPath']);
    });

    test('a validation failure also triggers the re-read', () async {
      final t = await _build({
        'POST $_cartPath': [
          const _Canned(422, {
            'message': 'The selected product id is invalid.',
            'errors': {
              'product_id': ['The selected product id is invalid.'],
            },
          }),
        ],
        'GET $_cartPath': [_Canned(200, _decode(_cartGet))],
      });

      final result = await t.repo.addItem(cartId: _cartId, productId: 999999);

      expect(result.error!.kind, ApiErrorKind.validation);
      expect(result.cart!.count, 2);
    });

    test('setQuantity targets the line id and sends the new qty', () async {
      final t = await _build({
        'PUT $_cartPath': [_Canned(200, _decode(_putDuplicatedVariation))],
      });

      final result = await t.repo.setQuantity(
        cartId: _cartId,
        line: const CartLineId.forSimpleProduct(116),
        qty: 7,
      );

      expect(result.isSuccess, isTrue);
      expect(t.adapter.requests.single.data, {'product_id': 116, 'qty': 7});
    });

    test('setQuantity refuses qty < 1 instead of letting the server guess',
        () async {
      final t = await _build({});

      // qty 0 leaves the line at one unit and qty -1 silently deletes it, so
      // neither is a usable "remove". The rejection arrives as a failed future,
      // not as a synchronous throw on the caller's frame.
      for (final qty in [0, -1]) {
        await expectLater(
          t.repo.setQuantity(
            cartId: _cartId,
            line: const CartLineId.forSimpleProduct(118),
            qty: qty,
          ),
          throwsArgumentError,
        );
      }
      expect(t.adapter.calls, isEmpty);
    });

    test('a PUT refused with HTTP 400 + a string `error` also re-reads',
        () async {
      // Raising the quantity past stock is the *stepper's* failure mode, and it
      // uses a different channel from the POST one above: HTTP 400 with `error`
      // holding a string instead of HTTP 200 with `error: true`
      // (sc/s16_putover_0.json, captured 8 times). It wipes the cart just the
      // same, so it has to reach the re-read.
      final t = await _build({
        'PUT $_cartPath': [
          const _Canned(400, {'error': 'Product is out of stock'}),
        ],
        'GET $_cartPath': [_Canned(200, _decode(_emptyCart))],
      });

      final result = await t.repo.setQuantity(
        cartId: _cartId,
        line: const CartLineId.forSimpleProduct(118),
        qty: 99999,
      );

      expect(result.isSuccess, isFalse);
      expect(result.error!.kind, ApiErrorKind.validation);
      // The string-valued `error` is the server's own sentence and is shown.
      expect(result.message, 'Product is out of stock');
      expect(result.cart!.isEmpty, isTrue);
      expect(result.isResolved, isFalse);
      expect(t.adapter.calls, ['PUT $_cartPath', 'GET $_cartPath']);
    });

    test('removeItem re-reads, because DELETE answers with a bare string',
        () async {
      final t = await _build({
        'DELETE $_cartPath': [const _Canned(200, _deleteOk)],
        'GET $_cartPath': [_Canned(200, _decode(_emptyCart))],
      });

      final result = await t.repo.removeItem(
        cartId: _cartId,
        line: const CartLineId.forSimpleProduct(118),
      );

      expect(result.isSuccess, isTrue);
      expect(result.cart!.isEmpty, isTrue);
      expect(t.adapter.calls, ['DELETE $_cartPath', 'GET $_cartPath']);
      expect(t.adapter.requests.first.data, {'product_id': 118});
    });

    test('a successful remove whose re-read fails is not a renderable result',
        () async {
      // DELETE answered "Cart item removed successfully" — the mutation worked —
      // but the follow-up GET died, so there is no cart to draw. isSuccess is
      // true here and cart is null, which is exactly the combination a caller
      // must not resolve with `cart!`.
      final t = await _build({
        'DELETE $_cartPath': [const _Canned(200, _deleteOk)],
        'GET $_cartPath': [const _Canned(500, {'message': 'Server Error'})],
      });

      final result = await t.repo.removeItem(
        cartId: _cartId,
        line: const CartLineId.forSimpleProduct(118),
      );

      expect(result.isSuccess, isTrue);
      expect(result.isCartKnown, isFalse);
      expect(result.isResolved, isFalse);
      expect(result.cart, isNull);
      expect(result.refreshError!.kind, ApiErrorKind.server);
    });

    test('a 404 remove exposes the wipe it caused', () async {
      final t = await _build({
        'DELETE $_cartPath': [const _Canned(404, _notInCart)],
        'GET $_cartPath': [_Canned(200, _decode(_emptyCart))],
      });

      final result = await t.repo.removeItem(
        cartId: _cartId,
        line: const CartLineId.forSimpleProduct(111),
      );

      expect(result.isSuccess, isFalse);
      expect(result.error!.kind, ApiErrorKind.notFound);
      expect(result.cart!.isEmpty, isTrue);
    });

    test('says so when the state after a failure is genuinely unknown',
        () async {
      final t = await _build({
        'POST $_cartPath': [const _Canned(200, _overStock)],
        'GET $_cartPath': [const _Canned(500, {'message': 'Server Error'})],
      });

      final result =
          await t.repo.addItem(cartId: _cartId, productId: 118, qty: 99999);

      expect(result.isSuccess, isFalse);
      expect(result.message, 'Maximum quantity is 1891!');
      expect(result.isCartKnown, isFalse);
      expect(result.cart, isNull);
      expect(result.refreshError!.kind, ApiErrorKind.server);
    });
  });

  // =========================================================================
  group('CartRepository coupons', () {
    test('apply sends cart_id in the body and re-reads the cart', () async {
      final t = await _build({
        'POST /ecommerce/coupon/apply': [_Canned(200, _decode(_couponApplyEmptyCart))],
        'GET $_cartPath': [_Canned(200, _decode(_cartGet))],
      });

      final result = await t.repo.applyCoupon(cartId: _cartId, code: 'FRESH10');

      expect(t.adapter.requests.first.data, {
        'coupon_code': 'FRESH10',
        'cart_id': _cartId,
      });
      expect(result.isSuccess, isTrue);
      // The coupon response claimed success on an empty cart; the re-read is
      // what the UI is given.
      expect(result.cart!.count, 2);
      expect(t.adapter.calls, [
        'POST /ecommerce/coupon/apply',
        'GET $_cartPath',
      ]);
    });

    test('a rejected code is reported with the surviving cart', () async {
      final t = await _build({
        'POST /ecommerce/coupon/apply': [const _Canned(200, _couponRejected)],
        'GET $_cartPath': [_Canned(200, _decode(_emptyCart))],
      });

      final result = await t.repo.applyCoupon(cartId: _cartId, code: 'NOPE123');

      expect(result.isSuccess, isFalse);
      expect(result.message, 'This coupon is invalid or expired!');
      // Same wipe as a failed add — apply() returns without storing the cart.
      expect(result.cart!.isEmpty, isTrue);
    });

    test('remove sends cart_id and re-reads', () async {
      final t = await _build({
        'POST /ecommerce/coupon/remove': [_Canned(200, _decode(_couponRemoveSuccess))],
        'GET $_cartPath': [_Canned(200, _decode(_cartGet))],
      });

      final result = await t.repo.removeCoupon(cartId: _cartId);

      expect(t.adapter.requests.first.data, {'cart_id': _cartId});
      expect(result.isSuccess, isTrue);
      expect(result.cart!.id, _cartId);
      expect(result.cart!.count, 2);
    });

    // -----------------------------------------------------------------------
    // GET /coupons — the advertised list
    //
    // The one cart-ish route that is genuinely read-only. Every other route
    // taking a cart id runs `Cart::restore()`, which loads the row by deleting
    // it; this one left a live 2-item cart at `count: 2` across four
    // consecutive calls. That is what makes re-fetching on every cart change
    // safe, and re-fetching is what eligibility requires.
    // -----------------------------------------------------------------------

    test('sends the cart id as a query parameter and reads the envelope',
        () async {
      final t = await _build({
        'GET /ecommerce/coupons': [
          const _Canned(200, {
            'error': false,
            'message': null,
            'data': [
              {
                'code': 'M20',
                'value': 20,
                'type_option': 'percentage',
                'value_formatted': '20%',
                'is_eligible': true,
              },
            ],
          }),
        ],
      });

      final coupons = await t.repo.availableCoupons(cartId: _cartId);

      expect(t.adapter.calls, ['GET /ecommerce/coupons']);
      expect(t.adapter.requests.single.queryParameters, {'cart_id': _cartId});
      expect(coupons.single.code, 'M20');
      expect(coupons.single.isEligible, isTrue);
    });

    test('omits cart_id entirely rather than sending a blank one', () async {
      for (final id in <String?>[null, '', '   ']) {
        final t = await _build({
          'GET /ecommerce/coupons': [
            const _Canned(200, {'error': false, 'data': []}),
          ],
        });
        await t.repo.availableCoupons(cartId: id);
        expect(
          t.adapter.requests.single.queryParameters,
          isEmpty,
          reason: id == null ? 'null' : '"$id"',
        );
      }
    });

    test('is not queued behind cart writes', () async {
      // Deliberately outside `_serialised`: it neither mutates nor destroys the
      // cart, so making it wait on the write queue would only delay the sheet.
      // If it ever *does* need the queue, this test is where that decision gets
      // revisited rather than discovered.
      final t = await _build({
        'GET /ecommerce/coupons': [
          const _Canned(200, {'error': false, 'data': []}),
        ],
      });

      await Future.wait([
        t.repo.availableCoupons(cartId: _cartId),
        t.repo.availableCoupons(cartId: _cartId),
        t.repo.availableCoupons(cartId: _cartId),
      ]);

      expect(t.adapter.calls, hasLength(3));
    });

    test('an error:true body throws rather than reading as "no coupons"',
        () async {
      // Same trap as apply/remove: a refusal is HTTP 200 with the failure in
      // the body. Returning [] here would tell the customer the shop has no
      // offers when the truth is that nobody managed to ask.
      final t = await _build({
        'GET /ecommerce/coupons': [
          const _Canned(200, {
            'error': true,
            'data': null,
            'message': 'Coupons are unavailable',
          }),
        ],
      });

      await expectLater(
        t.repo.availableCoupons(cartId: _cartId),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            'Coupons are unavailable',
          ),
        ),
      );
    });

    test('an empty list is returned as an empty list', () async {
      final t = await _build({
        'GET /ecommerce/coupons': [
          const _Canned(200, {'error': false, 'data': [], 'message': null}),
        ],
      });

      expect(await t.repo.availableCoupons(cartId: _cartId), isEmpty);
    });

    test('a body that is not a map is empty rather than a crash', () async {
      final t = await _build({
        'GET /ecommerce/coupons': [const _Canned(200, {})],
      });
      // `{}` has no `data`, which is not the same as a broken response — the
      // sheet shows "no offers" and its code field still works.
      expect(await t.repo.availableCoupons(cartId: _cartId), isEmpty);
    });

    test('"No coupon code found" is a refusal, and it too empties the cart',
        () async {
      final t = await _build({
        'POST /ecommerce/coupon/remove': [
          const _Canned(200, {
            'error': true,
            'data': null,
            'message': 'No coupon code found',
          }),
        ],
        'GET $_cartPath': [_Canned(200, _decode(_emptyCart))],
      });

      final result = await t.repo.removeCoupon(cartId: _cartId);

      expect(result.isSuccess, isFalse);
      expect(result.message, 'No coupon code found');
      expect(result.cart!.isEmpty, isTrue);
    });
  });
}

/// The body `CheckoutRepository.placeOrder` puts on the wire.
///
/// ## What is being defended
///
/// The app prices shipping the way the web checkout does: it names a courier
/// quote and lets the **server** put a number on it.
///
/// ```json
/// { "address": {…},
///   "payment_method": "razorpay",
///   "shipping_method": "shiprocket",
///   "shipping_option":  "shiprocket_1016322646" }
/// ```
///
/// Three separate things in that body will each, on their own, write a real
/// order that bills **0.00** for delivery — with an HTTP 200, a normal-looking
/// receipt, and no error anywhere:
///
///   1. **`shipping_amount` being present at all.**
///      `API/CheckoutController.php:425` sets
///      `$useClientShippingAmount = $request->has('shipping_amount')` and `:445`
///      skips the server's own pricing whenever that is true. `has()` is true
///      for a present-but-null key, so `"shipping_amount": null` is just as
///      fatal as a number. The field must be *absent*, and that is what
///      [_bodyOf] proves by asserting on `containsKey`.
///   2. **The wrong `shipping_method`.** It is the GROUP key, the literal
///      `"shiprocket"` (`HookServiceProvider.php:59` registers
///      `$result['shiprocket']`; `HandleShippingFeeService.php:58` matches with
///      `Arr::get($result, $method)`). A courier display name misses it, and so
///      does the old `"default"` — `:68` then does `Arr::get($filtered, null)`,
///      which returns the whole array one level too deep, so the later
///      `Arr::get($shippingMethod, 'price', 0)` finds nothing.
///   3. **A malformed `shipping_option`.** The member key is
///      `'shiprocket_' . Arr::get($courier, 'id')`
///      (`ShipRocketService.php:1870`, `:1889`) — the per-quote **rate id**.
///      `shiprocket_400` looks right and is not: 400 is `courier_company_id`,
///      and on the live row that carries it the rate id is `1016322646`.
///
/// Nothing here touches the network: `Dio`'s adapter is replaced, so the POST
/// is captured and answered locally. `POST /ecommerce/checkout/cart/{id}`
/// creates a real order with real stock and a real Razorpay order and must
/// never be exercised for real.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/repositories/checkout_repository.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// Passes [CheckoutAddressRules] — so a refusal in these tests is never the
/// address talking.
const _address = CheckoutAddress(
  name: 'Suraj Ojha',
  email: 'suraj.ojha@uminber.in',
  phone: '9876543210',
  address: '306, Jahnavi Arcade',
  city: 'Ahmedabad',
  state: 'Gujarat',
  zipCode: '382415',
);

/// Deliberately broken, for the ordering test only.
const _badAddress = CheckoutAddress(
  name: '',
  email: 'not-an-email',
  phone: '12',
  address: '',
  city: '',
  state: '',
  zipCode: 'nope',
);

/// A real member key: the rate id off the live `check-serviceability` row whose
/// `courier_company_id` is 400 (captured 2026-08-04, pickup 311001 -> 560001).
const _optionKey = 'shiprocket_1016322646';

const _cartId = '52aa3db4-57fc-41ab-b3a6-2ccba6d9f874';

/// The shape `mobileCheckout` answers with on the razorpay branch.
Map<String, dynamic> _successBody() => {
      'success': true,
      'message': 'Order placed successfully',
      'data': {
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
        'cart_id': _cartId,
        'is_finished': false,
        'razorpay': {
          'razorpay_order_id': 'order_abc',
          'razorpay_key_id': 'rzp_test',
          'amount': 127415,
          'currency': 'INR',
        },
      },
    };

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter(this.body);

  final Map<String, dynamic> body;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<({CheckoutRepository repo, _CapturingAdapter adapter})> _build() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _CapturingAdapter(_successBody());
  final dio = Dio()..httpClientAdapter = adapter;
  return (
    repo: CheckoutRepository(ApiClient(prefs: prefs, dio: dio)),
    adapter: adapter
  );
}

/// Places one order and hands back the JSON that actually left the device.
///
/// Reads `RequestOptions.data` rather than re-encoding the repository's map, so
/// a key that only *looks* absent — added after the map was built, or nulled on
/// the way out — cannot pass.
Future<Map<String, dynamic>> _bodyOf(_CapturingAdapter adapter) async {
  expect(
    adapter.requests,
    hasLength(1),
    reason: 'exactly one POST, never a retry',
  );
  return Map<String, dynamic>.from(
    jsonDecode(jsonEncode(adapter.requests.single.data)) as Map,
  );
}

void main() {
  group('the shipping contract on the wire', () {
    test(
        'sends the group key and the member key, and nothing else about '
        'shipping', () async {
      final h = await _build();
      final outcome = await h.repo.placeOrder(
        cartId: _cartId,
        address: _address,
        shippingOptionKey: _optionKey,
      );

      expect(outcome, isA<OrderPlaced>());
      final body = await _bodyOf(h.adapter);

      expect(body['shipping_method'], 'shiprocket');
      expect(body['shipping_option'], _optionKey);

      // The one that decides whether any of the above matters. `has()` is true
      // for a present-but-null key, so absence is the only safe state and
      // `containsKey` is the only assertion that proves it.
      expect(body.containsKey('shipping_amount'), isFalse);
    });

    test('shipping_method is the literal group key, not a courier name',
        () async {
      // Pinned as a constant too: a courier display name here misses
      // `Arr::get($result, $method)` and prices at 0.00 exactly like a wrong
      // option key. The two are not alternatives to each other.
      expect(CheckoutRepository.shippingMethod, 'shiprocket');
      expect(CheckoutRepository.shippingOptionPrefix, 'shiprocket_');
    });

    test('the rest of the body is unchanged', () async {
      final h = await _build();
      await h.repo.placeOrder(
        cartId: _cartId,
        address: _address,
        shippingOptionKey: _optionKey,
        notes: '  leave at the gate  ',
      );
      final body = await _bodyOf(h.adapter);

      expect(body['payment_method'], 'razorpay');
      expect(body['notes'], 'leave at the gate');
      expect((body['address'] as Map)['zip_code'], '382415');

      // Still never sent: a `currency` in the body breaks the X-CURRENCY
      // middleware, and payment_status / charge_id are derived server-side.
      for (final key in ['currency', 'payment_status', 'charge_id']) {
        expect(body.containsKey(key), isFalse, reason: key);
      }
    });

    test('the POST goes to the cart it was given', () async {
      final h = await _build();
      await h.repo.placeOrder(
        cartId: _cartId,
        address: _address,
        shippingOptionKey: _optionKey,
      );
      final request = h.adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/ecommerce/checkout/cart/$_cartId');
    });

    test('a whitespace-padded key is trimmed, not refused', () async {
      final h = await _build();
      final outcome = await h.repo.placeOrder(
        cartId: _cartId,
        address: _address,
        shippingOptionKey: '  $_optionKey  ',
      );
      expect(outcome, isA<OrderPlaced>());
      expect((await _bodyOf(h.adapter))['shipping_option'], _optionKey);
    });
  });

  group('no usable option key means no order', () {
    /// Every value that must never reach the server, and why.
    const unusable = <String?, String>{
      null: 'no courier quoted, or the quote is still loading',
      '': 'blank',
      '   ': 'whitespace',
      'shiprocket': 'the GROUP key, which is not a member of itself',
      'shiprocket_': 'the prefix with no rate id after it',
      'default': 'the old shipping_method; Arr::get(\$filtered, null) -> 0.00',
      'India Post - Speed Post Prepaid': 'the display name, for the UI only',
      '1016322646': 'the bare rate id, unprefixed',
    };

    test('refuses without sending anything', () async {
      for (final entry in unusable.entries) {
        final h = await _build();
        final outcome = await h.repo.placeOrder(
          cartId: _cartId,
          address: _address,
          shippingOptionKey: entry.key,
        );

        expect(
          outcome,
          isA<CheckoutShippingUnpriced>(),
          reason: '${entry.key} — ${entry.value}',
        );
        // The whole point of refusing here rather than server-side: nothing was
        // created, so there is nothing to reconcile and the retry is free.
        expect(h.adapter.requests, isEmpty, reason: '${entry.key}');
      }
    });

    test(
        'echoes the offending key for the log and says something usable to '
        'the customer', () async {
      final h = await _build();
      final outcome = await h.repo.placeOrder(
        cartId: _cartId,
        address: _address,
        // The old contract's value, which is the one a regression would most
        // plausibly reintroduce.
        shippingOptionKey: 'default',
      );

      final refusal = outcome as CheckoutShippingUnpriced;
      expect(refusal.shippingOptionKey, 'default');
      // A customer cannot act on a rate id, and a developer cannot act on
      // "please choose a delivery option" — so the two audiences are split.
      expect(refusal.message, isNot(contains('shiprocket')));
      expect(refusal.error.developerDetail, contains('"default"'));
      expect(refusal.error.developerDetail, contains(_cartId));
    });

    test('a null key is reported as null rather than as an empty string',
        () async {
      final h = await _build();
      final outcome = await h.repo.placeOrder(
        cartId: _cartId,
        address: _address,
        shippingOptionKey: null,
      );
      final refusal = outcome as CheckoutShippingUnpriced;
      expect(refusal.shippingOptionKey, isNull);
      expect(refusal.error.developerDetail, contains('got null'));
    });

    // `shiprocket_400` is the trap this whole contract exists for: 400 is the
    // `courier_company_id` of a live row whose rate id is 1016322646. It is
    // well-formed, so it CANNOT be caught here — it is caught by the caller
    // taking the key from `shippingOptionKeyProvider` instead of building it,
    // and by reconciling the server's total afterwards. Pinning that the guard
    // lets it through keeps anyone from believing this is a validity check.
    test('a well-formed key for the wrong number is NOT caught here', () async {
      expect(
        CheckoutRepository.isUsableShippingOptionKey('shiprocket_400'),
        isTrue,
      );

      final h = await _build();
      final outcome = await h.repo.placeOrder(
        cartId: _cartId,
        address: _address,
        shippingOptionKey: 'shiprocket_400',
      );
      expect(outcome, isA<OrderPlaced>());
      expect((await _bodyOf(h.adapter))['shipping_option'], 'shiprocket_400');
    });

    // A missing key is a precondition failure, not content to be corrected. If
    // the address were checked first, a typo in a house number would mask the
    // bug that silently bills the shop for every courier it ever eats.
    test('is reported ahead of an address problem', () async {
      final h = await _build();
      final outcome = await h.repo.placeOrder(
        cartId: _cartId,
        address: _badAddress,
        shippingOptionKey: null,
      );
      expect(outcome, isA<CheckoutShippingUnpriced>());
      expect(h.adapter.requests, isEmpty);
    });

    test('a good key still lets an address refusal through', () async {
      final h = await _build();
      final outcome = await h.repo.placeOrder(
        cartId: _cartId,
        address: _badAddress,
        shippingOptionKey: _optionKey,
      );
      expect(outcome, isA<CheckoutAddressRejected>());
      expect(h.adapter.requests, isEmpty);
    });
  });

  group('isUsableShippingOptionKey', () {
    test('accepts a real member key', () {
      expect(CheckoutRepository.isUsableShippingOptionKey(_optionKey), isTrue);
      expect(
        CheckoutRepository.isUsableShippingOptionKey('shiprocket_1051772883'),
        isTrue,
      );
    });

    test('is derived from the group key, not typed twice', () {
      // The server builds both from the same string; drifting them apart here
      // would be undetectable until an order billed 0.00.
      expect(
        CheckoutRepository.shippingOptionPrefix,
        '${CheckoutRepository.shippingMethod}_',
      );
    });

    test('rejects everything that is not one', () {
      for (final key in <String?>[
        null,
        '',
        ' ',
        'shiprocket',
        'shiprocket_',
        ' shiprocket_ ',
        'default',
        'SHIPROCKET_1016322646',
        '1016322646',
      ]) {
        expect(
          CheckoutRepository.isUsableShippingOptionKey(key),
          isFalse,
          reason: '$key',
        );
      }
    });
  });

  // =========================================================================
  // Billing address
  //
  // The flag is the whole point of this group. `CheckoutRequest::rules()`:
  //
  //   if (EcommerceHelper::isBillingAddressEnabled()) {
  //       $rules['billing_address_same_as_shipping_address'] =
  //           'nullable|' . Rule::in(['0', '1']);
  //       if (! $this->input('billing_address_same_as_shipping_address') || …) {
  //           $rules['billing_address'] = 'array';
  //           $rules = array_merge($rules, EcommerceHelper::
  //               getCustomerAddressValidationRules('billing_address.'));
  //       }
  //
  // Omit the flag and `! $this->input(...)` is true, which makes the entire
  // billing address REQUIRED. The app sent no flag and no billing address, so
  // the day the shop turns `billing_address_enabled` on, every order 422s with
  // "The Name field is required" against a form that has no billing name.
  // =========================================================================
  group('billing address', () {
    test('same-as-delivery is STATED, not omitted', () async {
      final h = await _build();
      await h.repo.placeOrder(
        cartId: _cartId,
        address: _address,
        shippingOptionKey: _optionKey,
      );
      final body = await _bodyOf(h.adapter);

      // The literal string, because the rule is `Rule::in(['0', '1'])`.
      expect(body['billing_address_same_as_shipping_address'], '1');
      expect(body.containsKey('billing_address'), isFalse);
    });

    test('the billing country is the ISO CODE, not the display name', () async {
      // The silent killer. `storeOrderBillingAddress` re-validates the billing
      // address — the shipping one is never validated — and with "Load
      // countries, states, cities from plugin location" on, the state rule is
      // `new StateRule('country')`, which resolves the country by **id or
      // code**:
      //
      //   $query->whereHas('country', fn ($q) => $q
      //       ->where('id', $countryId)->orWhere('code', $countryId));
      //
      // Live, India is `{"name": "India", "code": "IN"}` with id 1, and
      // `?country_id=India` matches nothing. So sending the display name makes
      // the state fail, and the address is dropped under an HTTP 200 with the
      // order created and nothing said.
      final h = await _build();
      await h.repo.placeOrder(
        cartId: _cartId,
        address: _address,
        shippingOptionKey: _optionKey,
        billingAddress: _billingAddress,
      );
      final body = await _bodyOf(h.adapter);

      expect((body['billing_address']! as Map)['country'], 'IN');
      // The shipping address keeps the display name: it is stored verbatim and
      // never validated, and it is what the order's address block prints.
      expect((body['address']! as Map)['country'], 'India');
    });

    test('a separate billing address flips the flag and rides along', () async {
      final h = await _build();
      await h.repo.placeOrder(
        cartId: _cartId,
        address: _address,
        shippingOptionKey: _optionKey,
        billingAddress: _billingAddress,
      );
      final body = await _bodyOf(h.adapter);

      expect(body['billing_address_same_as_shipping_address'], '0');
      final billing = body['billing_address']! as Map;
      expect(billing['name'], 'Uminber Accounts');
      expect(billing['zip_code'], '380015');
      // The delivery address is untouched by any of it.
      expect((body['address']! as Map)['zip_code'], '382415');
    });

    test('the flag is a string on the wire, never a bool', () async {
      // `Rule::in` compares as strings. A JSON `true` would arrive as the
      // boolean it is and miss both members of `['0', '1']`.
      for (final billing in <CheckoutAddress?>[null, _billingAddress]) {
        final h = await _build();
        await h.repo.placeOrder(
          cartId: _cartId,
          address: _address,
          shippingOptionKey: _optionKey,
          billingAddress: billing,
        );
        final flag =
            (await _bodyOf(h.adapter))['billing_address_same_as_shipping_address'];
        expect(flag, isA<String>(), reason: '$billing');
      }
    });

    test('a broken billing address is refused before anything is sent',
        () async {
      final h = await _build();
      final outcome = await h.repo.placeOrder(
        cartId: _cartId,
        address: _address,
        shippingOptionKey: _optionKey,
        billingAddress: _badAddress,
      );

      // Worth refusing even though the server never 422s on it:
      // `OrderHelper::storeOrderBillingAddress` re-validates against these same
      // rules and bare-`return`s on failure, so the order is written, 200 comes
      // back, and the invoice address is gone with nothing said.
      expect(outcome, isA<CheckoutAddressRejected>());
      expect((outcome as CheckoutAddressRejected).billingAddress, isNotEmpty);
      expect(outcome.address, isEmpty, reason: 'delivery was fine');
      expect(h.adapter.requests, isEmpty);
    });
  });

  // =========================================================================
  group('tax information', () {
    const taxBlock = {
      'company_name': 'Uminber India Pvt Ltd',
      'company_address': '306, Jahnavi Arcade, Ahmedabad',
      'company_tax_code': '27AAPFU0939F1Z5',
      'company_email': 'billing@uminber.in',
    };

    test('rides along with its enabling flag', () async {
      final h = await _build();
      await h.repo.placeOrder(
        cartId: _cartId,
        address: _address,
        shippingOptionKey: _optionKey,
        taxInformation: taxBlock,
      );
      final body = await _bodyOf(h.adapter);

      // Both, always. `$request->boolean('with_tax_information')` gates the
      // `$order->taxInformation()->create(...)` — the block alone is ignored.
      expect(body['with_tax_information'], isTrue);
      expect(body['tax_information'], taxBlock);
    });

    test('no tax details means neither key is sent', () async {
      for (final block in <Map<String, dynamic>?>[null, <String, dynamic>{}]) {
        final h = await _build();
        await h.repo.placeOrder(
          cartId: _cartId,
          address: _address,
          shippingOptionKey: _optionKey,
          taxInformation: block,
        );
        final body = await _bodyOf(h.adapter);
        expect(
          body.containsKey('with_tax_information'),
          isFalse,
          reason: '$block',
        );
        expect(body.containsKey('tax_information'), isFalse, reason: '$block');
      }
    });
  });
}

/// A billing address that is nobody's delivery address — different name, city
/// and PIN, so a test cannot pass by echoing the delivery one back.
const _billingAddress = CheckoutAddress(
  name: 'Uminber Accounts',
  email: 'billing@uminber.in',
  phone: '9812345670',
  address: '12 Prahlad Nagar Road',
  city: 'Ahmedabad',
  state: 'Gujarat',
  zipCode: '380015',
);

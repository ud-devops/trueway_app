import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/models/server_cart.dart';
import 'package:trueway_farms/data/repositories/cart_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/server_cart_provider.dart';

/// Surviving the cart-destroying backend defect, end to end.
///
/// `Cart::restore()` deletes the stored cart row as it loads it and every
/// controller error path returns before `store()` writes it back, so **any**
/// refusal — including the HTTP 200 + `"error": true` this backend reports every
/// business rule with — can leave the customer with an empty basket they did not
/// empty (docs/BACKEND_BUGS.md finding 0).
///
/// `server_cart_provider_test.dart` pins what the app does with the survivor.
/// This file pins the three mitigations that put the basket *back*, and it runs
/// them against a real [CartRepository] over a faked transport rather than a
/// fake repository, because two of the three (the request bodies, the ordering)
/// only exist at the wire.

// ---------------------------------------------------------------------------
// Transport fake
// ---------------------------------------------------------------------------

class _Canned {
  const _Canned(this.statusCode, this.body);
  final int statusCode;
  final Object body;
}

/// Replays canned responses keyed by `METHOD /path` and records the order calls
/// actually reached the wire in.
///
/// A list per key is consumed in order: the whole cart lives on one URL, so a
/// refused POST, the reads around it and the rebuild's own POSTs all share a
/// key and have to answer differently each time.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(Map<String, List<_Canned>> responses)
      : _responses = {
          for (final e in responses.entries) e.key: List<_Canned>.of(e.value),
        };

  final Map<String, List<_Canned>> _responses;
  final List<RequestOptions> requests = [];

  /// `start`/`end` per request — the only way to see whether two calls
  /// overlapped.
  final List<String> trace = [];

  /// Holds the *next* request open until completed.
  Completer<void>? gate;

  List<String> get calls =>
      requests.map((r) => '${r.method} ${r.path}').toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    trace.add('start ${options.method} ${options.path}');
    final open = gate;
    if (open != null) {
      gate = null;
      await open.future;
    }
    final queue = _responses['${options.method} ${options.path}'];
    final canned = queue == null || queue.isEmpty
        ? const _Canned(404, {'message': 'no canned response'})
        : (queue.length == 1 ? queue.first : queue.removeAt(0));
    trace.add('end ${options.method} ${options.path}');
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

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// `cart_items` is an object keyed by row id when populated and a JSON **array**
/// when empty — the shape every wipe produces.
Map<String, dynamic> _cart(
  List<Map<String, dynamic>> lines, {
  String id = 'cart-1',
  String? coupon,
}) =>
    {
      'id': id,
      'count': lines.fold<int>(0, (sum, l) => sum + (l['quantity']! as int)),
      'cart_items': lines.isEmpty
          ? <dynamic>[]
          : {for (final l in lines) 'row-${l['id']}': l},
      'applied_coupon_code': coupon,
      'raw_sub_total': 100,
      'order_total': 105,
    };

Map<String, dynamic> _line(int id, int qty) => {
      'id': id,
      'row_id': 'row-$id',
      'name': 'Product $id',
      'quantity': qty,
      'price': 100,
    };

/// A business refusal: HTTP 200, `error: true`.
const _refusal = {
  'error': true,
  'data': null,
  'message': 'Maximum quantity is 5!',
};

/// Line 121 is a **variation** id, not a parent — the id the mirror has to
/// carry so a rebuild reproduces the pack the customer chose.
const _mirrorWithCoupon = '{"cart_id":"cart-1","lines":['
    '{"product_id":118,"qty":2},{"product_id":121,"qty":1}],'
    '"coupon_code":"FRESH10"}';

const _mirrorNoCoupon = '{"cart_id":"cart-1","lines":['
    '{"product_id":118,"qty":2},{"product_id":121,"qty":1}]}';

typedef _Host = ({
  ProviderContainer container,
  _FakeAdapter adapter,
  SharedPreferences prefs,
});

Future<_Host> _host(
  Map<String, List<_Canned>> responses, {
  String? mirror,
}) async {
  SharedPreferences.setMockInitialValues({
    'server_cart_id_v1': 'cart-1',
    if (mirror != null) 'server_cart_mirror_v1': mirror,
  });
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(responses);
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      cartRepositoryProvider.overrideWithValue(
        CartRepository(
          ApiClient(prefs: prefs, dio: Dio()..httpClientAdapter = adapter),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, adapter: adapter, prefs: prefs);
}

Future<void> _settle(ProviderContainer container) async {
  for (var i = 0; i < 200; i++) {
    if (!container.read(serverCartProvider).loading) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('cart never finished loading');
}

ServerCartState _state(_Host h) => h.container.read(serverCartProvider);

CartMirror? _mirrorOf(_Host h) =>
    CartMirror.tryDecode(h.prefs.getString('server_cart_mirror_v1'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  group('mitigation 1 — the local mirror', () {
    test('is seeded by a read and rewritten by an accepted mutation', () async {
      final h = await _host({
        'GET /ecommerce/cart/cart-1': [
          _Canned(200, _cart([_line(118, 2)], coupon: 'FRESH10')),
        ],
        'POST /ecommerce/cart/cart-1': [
          _Canned(200, _cart([_line(118, 2), _line(121, 1)], coupon: 'FRESH10')),
        ],
      });
      final notifier = h.container.read(serverCartProvider.notifier);
      await _settle(h.container);

      // The restore read alone is enough. It used to leave no mirror at all —
      // an empty read being indistinguishable from a wipe — but that left every
      // install upgrading with a `server_cart_id_v1` already in prefs holding
      // nothing to rebuild from when its first refusal arrived, which is the
      // one outcome the mirror exists to prevent.
      final seeded = _mirrorOf(h)!;
      expect(seeded.cartId, 'cart-1');
      expect(seeded.lines.map((l) => l.productId), [118]);
      expect(seeded.lines.map((l) => l.qty), [2]);
      expect(seeded.couponCode, 'FRESH10');

      await notifier.addProductId(121);

      final mirror = _mirrorOf(h)!;
      expect(mirror.cartId, 'cart-1');
      expect(mirror.lines.map((l) => l.productId), [118, 121]);
      expect(mirror.lines.map((l) => l.qty), [2, 1]);
      expect(mirror.couponCode, 'FRESH10');
    });

    // The read is allowed to *widen* the mirror and never to shrink it. This
    // GET is exactly what a wipe looks like from the client — there is no way
    // to tell it apart from an honestly-emptied cart — so adopting it would
    // throw away the only record of what to put back, which is the reason the
    // mirror ignored reads in the first place.
    test('a read that comes back empty cannot empty it', () async {
      final h = await _host(
        {
          'GET /ecommerce/cart/cart-1': [
            _Canned(200, _cart(const [])),
          ],
        },
        mirror: _mirrorWithCoupon,
      );
      h.container.read(serverCartProvider.notifier);
      await _settle(h.container);

      expect(_state(h).isEmpty, isTrue, reason: 'the screen tells the truth');
      final mirror = _mirrorOf(h)!;
      expect(mirror.lines.map((l) => l.productId), [118, 121]);
      expect(mirror.lines.map((l) => l.qty), [2, 1]);
      expect(mirror.couponCode, 'FRESH10');
    });

    test('goes when the cart id goes', () async {
      final h = await _host({
        'GET /ecommerce/cart/cart-1': [
          _Canned(200, _cart([_line(118, 1)])),
        ],
        'POST /ecommerce/cart/cart-1': [
          _Canned(200, _cart([_line(118, 2)])),
        ],
      });
      final notifier = h.container.read(serverCartProvider.notifier);
      await _settle(h.container);
      await notifier.addProductId(118);
      expect(_mirrorOf(h), isNotNull);

      await notifier.forget();

      // A mirror outliving its cart id would try to rebuild a basket the
      // customer has already paid for.
      expect(_mirrorOf(h), isNull);
    });

    test('is never replayed into a cart it was not captured from', () async {
      final h = await _host(
        {
          'GET /ecommerce/cart/cart-1': [
            _Canned(200, _cart([_line(118, 1)])), // what cart-1 actually holds
            _Canned(200, _cart(const [])), // the refusal wiped it
            _Canned(200, _cart([_line(118, 1)])), // after the rebuild
          ],
          'POST /ecommerce/cart/cart-1': [
            const _Canned(200, _refusal),
            _Canned(200, _cart([_line(118, 1)])),
          ],
        },
        mirror: '{"cart_id":"cart-OTHER","lines":['
            '{"product_id":118,"qty":2},{"product_id":333,"qty":3}],'
            '"coupon_code":"OTHER10"}',
      );
      final notifier = h.container.read(serverCartProvider.notifier);
      await _settle(h.container);
      h.adapter.requests.clear();

      await notifier.addProductId(999);

      // The coupon lives on *that* cart's first line and the checkout hangs off
      // its id; replaying elsewhere would strand both. What drives this rebuild
      // is cart-1's own mirror, seeded from cart-1's own read: one unit of 118,
      // no line 333, and no coupon — none of which cart-OTHER agrees with.
      expect(h.adapter.calls, [
        'POST /ecommerce/cart/cart-1', // the refused add
        'GET /ecommerce/cart/cart-1', // what survived
        'POST /ecommerce/cart/cart-1', // line 118, back
        'GET /ecommerce/cart/cart-1',
      ]);
      expect(h.adapter.requests[2].data, {'product_id': 118, 'qty': 1});
      expect(_mirrorOf(h)!.cartId, 'cart-1');
      expect(_mirrorOf(h)!.couponCode, isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('mitigation 2 — rebuild on failure', () {
    test('a refusal that wiped the cart puts every line back and re-applies '
        'the coupon', () async {
      final full = _cart([_line(118, 2), _line(121, 1)], coupon: 'FRESH10');
      final h = await _host(
        {
          'GET /ecommerce/cart/cart-1': [
            _Canned(200, full),
            _Canned(200, _cart(const [])), // after the refusal: wiped
            _Canned(200, full), // after the rebuild
          ],
          'POST /ecommerce/cart/cart-1': [
            const _Canned(200, _refusal),
            _Canned(200, _cart([_line(118, 2)])),
            _Canned(200, _cart([_line(118, 2), _line(121, 1)])),
          ],
          'POST /ecommerce/coupon/apply': [
            _Canned(200, {'error': false, 'data': full, 'message': 'ok'}),
          ],
        },
        mirror: _mirrorWithCoupon,
      );
      final notifier = h.container.read(serverCartProvider.notifier);
      await _settle(h.container);
      h.adapter.requests.clear();

      final message = await notifier.addProductId(999, quantity: 9);

      // The refusal is still reported — the customer asked for something and did
      // not get it — but they do not also lose what they already had.
      expect(message, startsWith('Maximum quantity is 5!'));
      expect(_state(h).cart!.items, hasLength(2));
      expect(_state(h).cart!.appliedCouponCode, 'FRESH10');
      expect(_state(h).rebuild!.isComplete, isTrue);
      expect(_state(h).recoveryMessage, isNull, reason: 'nothing was lost');
      expect(_state(h).contentsUnknown, isFalse);
      expect(_state(h).busy, isFalse);

      expect(h.adapter.calls, [
        'POST /ecommerce/cart/cart-1', // the refused add
        'GET /ecommerce/cart/cart-1', // what survived
        'POST /ecommerce/cart/cart-1', // line 118, back
        'POST /ecommerce/cart/cart-1', // line 121 — the VARIATION id
        'POST /ecommerce/coupon/apply', // the coupon, back on the same cart id
        'GET /ecommerce/cart/cart-1',
      ]);
      // Same cart id throughout: a new one would strand the coupon, the
      // shipping quote and anything already quoted against it.
      expect(h.adapter.requests[2].data, {'product_id': 118, 'qty': 2});
      expect(h.adapter.requests[3].data, {'product_id': 121, 'qty': 1});
      expect(
        h.adapter.requests[4].data,
        {'coupon_code': 'FRESH10', 'cart_id': 'cart-1'},
      );
    });

    test('only the shortfall is posted, because POST accumulates', () async {
      final h = await _host(
        {
          'GET /ecommerce/cart/cart-1': [
            _Canned(200, _cart([_line(118, 2), _line(121, 1)])),
            _Canned(200, _cart([_line(118, 1)])), // one unit survived
            _Canned(200, _cart([_line(118, 2), _line(121, 1)])),
          ],
          'POST /ecommerce/cart/cart-1': [
            const _Canned(200, _refusal),
            _Canned(200, _cart([_line(118, 2)])),
            _Canned(200, _cart([_line(118, 2), _line(121, 1)])),
          ],
        },
        mirror: _mirrorNoCoupon,
      );
      final notifier = h.container.read(serverCartProvider.notifier);
      await _settle(h.container);
      h.adapter.requests.clear();

      await notifier.addProductId(999);

      expect(
        h.adapter.requests[2].data,
        {'product_id': 118, 'qty': 1},
        reason: 'one of the two units survived, so only one is owed',
      );
      expect(h.adapter.requests[3].data, {'product_id': 121, 'qty': 1});
      expect(_state(h).rebuild!.isComplete, isTrue);
    });

    test('a line the server will not take back is reported, not retried '
        'forever', () async {
      final h = await _host(
        {
          'GET /ecommerce/cart/cart-1': [
            _Canned(200, _cart([_line(118, 2), _line(121, 1)])),
            _Canned(200, _cart(const [])), // the refusal wiped it
            _Canned(200, _cart(const [])), // …and so did the refused re-POST
            _Canned(200, _cart([_line(121, 1)])),
          ],
          'POST /ecommerce/cart/cart-1': [
            const _Canned(200, _refusal),
            const _Canned(200, {
              'error': true,
              'data': null,
              'message': 'Product 118 is out of stock!',
            }),
            _Canned(200, _cart([_line(121, 1)])),
          ],
        },
        mirror: _mirrorNoCoupon,
      );
      final notifier = h.container.read(serverCartProvider.notifier);
      await _settle(h.container);

      final message = await notifier.addProductId(999);

      // The re-POST of 118 was refused, which wiped the cart a second time — so
      // the pass restarts from a fresh read and 121 still gets home.
      expect(_state(h).rebuild!.linesRestored, 1);
      expect(_state(h).rebuild!.linesLost, 1);
      expect(_state(h).itemsLost, isTrue);
      expect(_state(h).cart!.items.single.lineId.value, 121);
      expect(
        _state(h).recoveryMessage,
        allOf(contains('1 item could not be restored'), contains('out of stock')),
      );
      expect(message, startsWith('Maximum quantity is 5!'));
      expect(message, contains('could not be restored'));

      // Re-mirrored from what the customer actually has, so the dead line is not
      // re-attempted on every later failure.
      expect(_mirrorOf(h)!.lines.map((l) => l.productId), [121]);
    });

    test('a refused coupon wipes the rebuilt cart, so the lines go back twice',
        () async {
      final h = await _host(
        {
          'GET /ecommerce/cart/cart-1': [
            _Canned(200, _cart([_line(118, 2)], coupon: 'FRESH10')),
            _Canned(200, _cart(const [])), // the failed remove wiped it
            _Canned(200, _cart(const [])), // the refused coupon wiped it again
            _Canned(200, _cart([_line(118, 2)])),
          ],
          'DELETE /ecommerce/cart/cart-1': [
            const _Canned(404, {'error': 'Cart item not found'}),
          ],
          'POST /ecommerce/cart/cart-1': [
            _Canned(200, _cart([_line(118, 2)])),
          ],
          'POST /ecommerce/coupon/apply': [
            const _Canned(200, {
              'error': true,
              'data': null,
              'message': 'This coupon is invalid or expired!',
            }),
          ],
        },
        mirror: '{"cart_id":"cart-1","lines":[{"product_id":118,"qty":2}],'
            '"coupon_code":"FRESH10"}',
      );
      final notifier = h.container.read(serverCartProvider.notifier);
      await _settle(h.container);
      h.adapter.requests.clear();

      await notifier.remove(const CartLineId.forSimpleProduct(999));

      expect(h.adapter.calls, [
        'DELETE /ecommerce/cart/cart-1',
        'GET /ecommerce/cart/cart-1',
        'POST /ecommerce/cart/cart-1', // lines back
        'POST /ecommerce/coupon/apply', // refused — and it took them again
        'GET /ecommerce/cart/cart-1', // so re-read before assuming anything
        'POST /ecommerce/cart/cart-1', // lines back a second time
        'GET /ecommerce/cart/cart-1',
      ]);
      // Losing a discount is recoverable; losing the basket while recovering the
      // basket is not.
      expect(_state(h).cart!.items, hasLength(1));
      expect(_state(h).rebuild!.couponLost, isTrue);
      expect(_state(h).recoveryMessage, contains('coupon was removed'));
    });

    test('a refused removal is not undone by the rebuild', () async {
      final h = await _host(
        {
          'GET /ecommerce/cart/cart-1': [
            _Canned(200, _cart([_line(118, 2), _line(121, 1)])),
            _Canned(200, _cart(const [])), // the 404 wiped it
            _Canned(200, _cart([_line(118, 2)])),
          ],
          'DELETE /ecommerce/cart/cart-1': [
            const _Canned(404, {'error': 'Cart item not found'}),
          ],
          'POST /ecommerce/cart/cart-1': [
            _Canned(200, _cart([_line(118, 2)])),
          ],
        },
        mirror: _mirrorNoCoupon,
      );
      final notifier = h.container.read(serverCartProvider.notifier);
      await _settle(h.container);
      h.adapter.requests.clear();

      await notifier.remove(const CartLineId.forSimpleProduct(121));

      // "Cart item not found" 404s *and* wipes the cart, and it proves the line
      // was already gone. Rebuilding it would resurrect the very line the
      // customer asked to remove — so the mirror follows the intent.
      expect(h.adapter.calls, [
        'DELETE /ecommerce/cart/cart-1',
        'GET /ecommerce/cart/cart-1',
        'POST /ecommerce/cart/cart-1',
        'GET /ecommerce/cart/cart-1',
      ]);
      expect(h.adapter.requests[2].data, {'product_id': 118, 'qty': 2});
      expect(_state(h).cart!.items.single.lineId.value, 118);
      expect(_mirrorOf(h)!.lines.map((l) => l.productId), [118]);
    });

    test('never shows an empty cart when the truth is unknown', () async {
      final h = await _host(
        {
          'GET /ecommerce/cart/cart-1': [
            _Canned(200, _cart([_line(118, 2)])),
            const _Canned(500, {'message': 'Server Error'}),
          ],
          'POST /ecommerce/cart/cart-1': [const _Canned(200, _refusal)],
        },
        mirror: _mirrorNoCoupon,
      );
      final notifier = h.container.read(serverCartProvider.notifier);
      await _settle(h.container);

      await notifier.addProductId(999);

      // Every read failed, so nothing can be reconciled and nothing is posted
      // blind — posting blind would duplicate whatever the wipe left alone.
      expect(_state(h).contentsUnknown, isTrue);
      expect(_state(h).cart, isNull);
      expect(_state(h).error, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  group('mitigation 3 — serialised per cart id', () {
    // `store()` inserts a row keyed by (identifier, instance) and throws
    // CartAlreadyStoredException — a 500 — when one already exists, so two
    // requests interleaving between `restore()` and `store()` lose the cart.
    // `GET` is a writer here too: `index()` restores and re-stores.
    test('a read cannot overlap a write already in flight', () async {
      final h = await _host({
        'GET /ecommerce/cart/cart-1': [
          _Canned(200, _cart([_line(118, 2)])),
        ],
        'POST /ecommerce/cart/cart-1': [
          _Canned(200, _cart([_line(118, 3)])),
        ],
      });
      final repo = h.container.read(cartRepositoryProvider);
      final gate = Completer<void>();
      h.adapter.gate = gate;

      final write = repo.addItem(cartId: 'cart-1', productId: 118);
      final read = repo.fetch('cart-1');
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(
        h.adapter.trace,
        ['start POST /ecommerce/cart/cart-1'],
        reason: 'the read must wait, not race the write',
      );

      gate.complete();
      await Future.wait([write, read]);

      expect(h.adapter.trace, [
        'start POST /ecommerce/cart/cart-1',
        'end POST /ecommerce/cart/cart-1',
        'start GET /ecommerce/cart/cart-1',
        'end GET /ecommerce/cart/cart-1',
      ]);
    });

    test('a failed call does not deadlock the queue behind it', () async {
      final h = await _host({
        'GET /ecommerce/cart/cart-1': [
          const _Canned(500, {'message': 'Server Error'}),
          _Canned(200, _cart([_line(118, 2)])),
        ],
      });
      final repo = h.container.read(cartRepositoryProvider);

      final first = repo.fetch('cart-1');
      final second = repo.fetch('cart-1');

      await expectLater(first, throwsA(isA<Object>()));
      expect((await second).items, hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  group('mitigation 4 — the quantities that must never reach the wire', () {
    // `PUT` has no `min:1` rule: qty 0 leaves the line at one unit and a
    // negative qty silently deletes it. `POST` does validate min:1, but its 422
    // is a wipe like any other refusal.
    test('qty below 1 is refused locally', () async {
      final h = await _host({
        'GET /ecommerce/cart/cart-1': [
          _Canned(200, _cart([_line(118, 2)])),
        ],
      });
      final notifier = h.container.read(serverCartProvider.notifier);
      await _settle(h.container);
      h.adapter.requests.clear();

      expect(await notifier.addProductId(118, quantity: 0), isNotNull);
      expect(h.adapter.calls, isEmpty);

      final repo = h.container.read(cartRepositoryProvider);
      for (final qty in [0, -1]) {
        await expectLater(
          repo.addItem(cartId: 'cart-1', productId: 118, qty: qty),
          throwsArgumentError,
        );
        await expectLater(
          repo.createCart(productId: 118, qty: qty),
          throwsArgumentError,
        );
        await expectLater(
          repo.setQuantity(
            cartId: 'cart-1',
            line: const CartLineId.forSimpleProduct(118),
            qty: qty,
          ),
          throwsArgumentError,
        );
      }
      expect(h.adapter.calls, isEmpty);
    });

    // `POST /ecommerce/cart/refresh` is declared after `POST /cart/{id}` and
    // Laravel matches in registration order, so it binds `{id} = "refresh"` and
    // reads and writes a cart shared by every user of the app.
    test('nothing can address a cart called "refresh"', () async {
      final h = await _host({});
      final repo = h.container.read(cartRepositoryProvider);

      expect(
        () => repo.fetch('refresh'),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}

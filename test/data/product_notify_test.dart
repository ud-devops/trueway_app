import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/repositories/catalog_repository.dart';

/// Back-in-stock subscription, and the merchandising rails beside it.
///
/// Both are advisory features layered on a product page that has already
/// loaded, so the rule throughout is: **never let them fail the page**. The
/// rails answer with an empty list on error, the status check answers false,
/// and only the subscribe call surfaces anything — because its refusals are
/// written for the customer and name a cause the client cannot infer.

/// Replays one canned response, capturing what was asked for.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter({this.body, this.statusCode = 200, this.throwOffline = false});

  final Object? body;
  final int statusCode;
  final bool throwOffline;

  final List<String> paths = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    if (throwOffline) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    return ResponseBody.fromString(
      jsonEncode(body ?? const {}),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<({CatalogRepository repo, _CannedAdapter adapter})> _repo(
  _CannedAdapter adapter,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final dio = Dio()..httpClientAdapter = adapter;
  return (repo: CatalogRepository(ApiClient(prefs: prefs, dio: dio)), adapter: adapter);
}

void main() {
  // -------------------------------------------------------------------------
  group('notifyWhenInStock', () {
    test('reports the server sentence on success', () async {
      final h = await _repo(_CannedAdapter(body: {
        'error': false,
        'data': {'is_subscribed': true},
        'message': 'We will notify you when this product is back in stock.',
      },),);

      final result = await h.repo.notifyWhenInStock(118);

      expect(result.subscribed, isTrue);
      expect(
        result.message,
        'We will notify you when this product is back in stock.',
      );
      expect(h.adapter.paths.single, '/ecommerce/products/118/notify-me');
    });

    // The controller distinguishes a fresh subscription from one that already
    // existed, and says so. Neither is an error, and both are worth showing.
    test('carries the already-subscribed wording through unchanged', () async {
      final h = await _repo(_CannedAdapter(body: {
        'error': false,
        'data': {'is_subscribed': true},
        'message': 'You will be notified when this product is back in stock.',
      },),);

      final result = await h.repo.notifyWhenInStock(118);

      expect(result.subscribed, isTrue);
      expect(result.message, startsWith('You will be notified'));
    });

    // Three refusals, three different causes, and the client can tell them
    // apart from nothing but the sentence. They arrive as HTTP 200 with
    // `error: true` — the backend's business-rule channel — so a caller that
    // only checked the status code would treat each as a success.
    for (final refusal in const [
      'Your account does not have a valid email address.',
      'Product not found.',
      'This product is already in stock.',
    ]) {
      test('surfaces "$refusal" verbatim', () async {
        final h = await _repo(_CannedAdapter(body: {
          'error': true,
          'data': null,
          'message': refusal,
        },),);

        final result = await h.repo.notifyWhenInStock(118);

        expect(result.subscribed, isFalse);
        expect(result.message, refusal);
      });
    }

    test('a transport failure still yields a message, not a throw', () async {
      final h = await _repo(_CannedAdapter(throwOffline: true));

      final result = await h.repo.notifyWhenInStock(118);

      expect(result.subscribed, isFalse);
      expect(result.message, isNotEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('isSubscribedToStock', () {
    test('reads the flag off the data envelope', () async {
      final h = await _repo(_CannedAdapter(body: {
        'error': false,
        'data': {'is_subscribed': true},
      },),);

      expect(await h.repo.isSubscribedToStock(118), isTrue);
      expect(
        h.adapter.paths.single,
        '/ecommerce/products/118/notify-me/status',
      );
    });

    test('is false when the customer has not subscribed', () async {
      final h = await _repo(_CannedAdapter(body: {
        'error': false,
        'data': {'is_subscribed': false},
      },),);

      expect(await h.repo.isSubscribedToStock(118), isFalse);
    });

    // The button this drives is an offer. Offering it to someone already
    // subscribed is a smaller wrong than hiding it because a status check
    // failed — and unauthenticated the route answers with a **redirect to the
    // web login page**, not a 401, so "failed" is the common case.
    test('is false rather than fatal when the check fails', () async {
      final h = await _repo(_CannedAdapter(throwOffline: true));

      expect(await h.repo.isSubscribedToStock(118), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('merchandising rails', () {
    test('related products parse as ordinary catalogue rows', () async {
      final h = await _repo(_CannedAdapter(body: {
        'error': false,
        'data': [
          {'id': 119, 'slug': 'a', 'name': 'A', 'price': 100},
          {'id': 120, 'slug': 'b', 'name': 'B', 'price': 200},
        ],
      },),);

      final products = await h.repo.relatedProducts('desi-khand');

      expect(products.map((p) => p.id), [119, 120]);
      expect(
        h.adapter.paths.single,
        '/ecommerce/products/desi-khand/related',
      );
    });

    // Live, cross-sale is empty for every product on this store. An empty rail
    // must draw nothing rather than an empty section.
    test('an empty rail is an empty list, not an error', () async {
      final h = await _repo(_CannedAdapter(body: {'error': false, 'data': []}));

      expect(await h.repo.crossSaleProducts('desi-khand'), isEmpty);
    });

    // A missing merchandising block must never take the product page down.
    test('a failure degrades to empty', () async {
      final h = await _repo(_CannedAdapter(throwOffline: true));

      expect(await h.repo.relatedProducts('desi-khand'), isEmpty);
      expect(await h.repo.crossSaleProducts('desi-khand'), isEmpty);
    });

    test('a 404 degrades to empty too', () async {
      final h = await _repo(_CannedAdapter(statusCode: 404, body: {
        'message': 'Not found',
      },),);

      expect(await h.repo.relatedProducts('nope'), isEmpty);
    });
  });
}

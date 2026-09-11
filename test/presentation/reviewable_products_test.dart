import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/repositories/review_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/review_provider.dart';

/// The "Waiting for your review" tab.
///
/// `GET /ecommerce/reviews/products-to-review` answers this in one call. It
/// replaced a three-stage client derivation that existed only because no
/// endpoint did: read every review the customer had written, read their
/// completed orders, then fetch each order's **detail**, because a list row
/// carries no product ids. That was N+2 requests capped at ten orders — so the
/// answer was simply wrong for anyone with a longer purchase history.
///
/// The server also drops anything still inside the post-delivery waiting
/// period, which the derivation could not do at all: it had no idea a delay
/// rule existed, so it offered products the server would then refuse.

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.body, {this.status = 200});

  final Object body;
  final int status;
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
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The live payload shape, from the backend's own example.
Map<String, Object?> _payload(List<Map<String, Object?>> rows) => {
      'error': false,
      'data': rows,
    };

Map<String, Object?> _row({
  int id = 118,
  String name = 'Trueway Farms Organic Desi Khand Brown',
  String slug = 'trueway-farms-organic-desi-khand-brown-khandsari',
  Object? orderId = 285,
  String? completedAt = '2026-08-06T14:04:43+05:30',
}) =>
    {
      'id': id,
      'name': name,
      'slug': slug,
      'url': 'https://dev.truewayerp.com/products/$slug',
      'image': 'https://dev.truewayerp.com/storage/products/$id.jpg',
      'order_id': orderId,
      'order_completed_at': completedAt,
    };

Future<({ReviewRepository repo, _FakeAdapter adapter})> _build(
  Object body, {
  int status = 200,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(body, status: status);
  final dio = Dio()..httpClientAdapter = adapter;
  return (
    repo: ReviewRepository(ApiClient(prefs: prefs, dio: dio)),
    adapter: adapter,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('productsToReview', () {
    test('reads the rows the server sends', () async {
      final t = await _build(_payload([_row(), _row(id: 111, name: 'Wheat')]));

      final products = await t.repo.productsToReview();

      expect(products, hasLength(2));
      expect(products.first.id, 118);
      expect(products.first.name, 'Trueway Farms Organic Desi Khand Brown');
      expect(products.first.slug, contains('desi-khand'));
      expect(products.first.orderId, 285);
      expect(products.first.orderCompletedAt?.year, 2026);
    });

    // One request. The whole point of the endpoint.
    test('asks once, at the documented path', () async {
      final t = await _build(_payload([_row()]));

      await t.repo.productsToReview();

      expect(t.adapter.requests, hasLength(1));
      expect(t.adapter.requests.single.path, '/ecommerce/reviews/products-to-review');
      expect(t.adapter.requests.single.queryParameters['limit'], 12);
    });

    test('passes a caller-chosen limit', () async {
      final t = await _build(_payload([_row()]));

      await t.repo.productsToReview(limit: 4);

      expect(t.adapter.requests.single.queryParameters['limit'], 4);
    });

    test('an empty list is a valid answer, not an error', () async {
      final t = await _build(_payload([]));

      expect(await t.repo.productsToReview(), isEmpty);
    });

    // `order_id` is the only identifier for the purchase — there is no display
    // code on this payload — and it can be absent.
    test('survives a row with no order attached', () async {
      final t = await _build(_payload([_row(orderId: null, completedAt: null)]));

      final product = (await t.repo.productsToReview()).single;
      expect(product.orderId, isNull);
      expect(product.orderCompletedAt, isNull);
      expect(product.id, 118, reason: 'the rest still parses');
    });
  });

  group('reviewableProductsProvider', () {
    test('serves what the repository returned', () async {
      final t = await _build(_payload([_row(), _row(id: 111)]));
      final container = ProviderContainer(
        overrides: [reviewRepositoryProvider.overrideWithValue(t.repo)],
      );
      addTearDown(container.dispose);

      final products = await container.read(reviewableProductsProvider.future);

      expect(products.map((p) => p.id), [118, 111]);
    });

    // The derivation it replaced fired three classes of request; this fires one.
    test('costs a single request', () async {
      final t = await _build(_payload([_row()]));
      final container = ProviderContainer(
        overrides: [reviewRepositoryProvider.overrideWithValue(t.repo)],
      );
      addTearDown(container.dispose);

      await container.read(reviewableProductsProvider.future);

      expect(t.adapter.requests, hasLength(1));
    });
  });
}

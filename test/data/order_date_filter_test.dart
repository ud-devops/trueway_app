/// The order-history date filter, on both sides of the switch-over.
///
/// `GET /ecommerce/orders` has no date parameter — seven names were tried live
/// and all seven returned the account's whole 94-order history, un-filtered and
/// un-rejected (see `docs/BACKEND_PATCH_order_date_filter.md`). So the filter
/// runs on the device, behind [OrderRepository.serverFiltersByDate].
///
/// Half of this file tests the local pass. The other half sets that flag and
/// tests the request the server branch builds, so **flip day really is one
/// line** — the alternative is a branch nobody has ever executed going live the
/// same morning the backend does.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/core/utils/date_range.dart';
import 'package:trueway_farms/data/repositories/order_repository.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// One order row, trimmed to what the filter reads.
Map<String, dynamic> _order(int id, String createdAt) => {
      'id': id,
      'code': '#TW$id',
      'created_at': createdAt,
      'amount': 100,
      'status': {'value': 'completed', 'label': 'Completed'},
    };

/// A page of `GET /orders` in its real hybrid envelope.
Map<String, dynamic> _page(
  List<Map<String, dynamic>> rows, {
  required int currentPage,
  required int lastPage,
  int? total,
}) =>
    {
      'error': false,
      'message': null,
      'data': rows,
      'links': const {},
      'meta': {
        'current_page': currentPage,
        'last_page': lastPage,
        'per_page': 100,
        'total': total ?? rows.length,
      },
    };

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Serves a queue, so a multi-page walk gets different pages.
///
/// The shared adapter in `order_test.dart` answers every call with the same
/// body, which for a paging loop means `hasMore` never goes false.
class _QueueAdapter implements HttpClientAdapter {
  _QueueAdapter(this.pages);

  final List<Map<String, dynamic>> pages;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = pages.length == 1
        ? pages.first
        : pages[(requests.length - 1).clamp(0, pages.length - 1)];
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

Future<({OrderRepository repo, _QueueAdapter adapter})> _build(
  List<Map<String, dynamic>> pages,
) async {
  SharedPreferences.setMockInitialValues({'auth_token': 'test-token'});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _QueueAdapter(pages);
  final dio = Dio()..httpClientAdapter = adapter;
  return (
    repo: OrderRepository(ApiClient(prefs: prefs, dio: dio)),
    adapter: adapter,
  );
}

Map<String, dynamic> _queryOf(RequestOptions r) => r.queryParameters;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A stray `true` leaking into another test would make every date filter stop
  // reading the history and start trusting a server that ignores the params.
  tearDown(() => OrderRepository.serverFiltersByDate = false);

  group('no date filter — nothing changed', () {
    test('one ordinary paged request, and no date parameters', () async {
      final h = await _build([
        _page([_order(1, '2026-08-11T21:47:04+05:30')],
            currentPage: 1, lastPage: 3, total: 25,),
      ]);

      final res = await h.repo.orders(page: 2, perPage: 10, status: 'completed');

      expect(h.adapter.requests, hasLength(1));
      final q = _queryOf(h.adapter.requests.single);
      expect(q['page'], 2);
      expect(q['per_page'], 10);
      expect(q['status'], 'completed');
      expect(q.containsKey('from_date'), isFalse);
      expect(q.containsKey('to_date'), isFalse);
      // The server's own paging is left alone.
      expect(res.hasMore, isTrue);
      expect(res.meta.total, 25);
    });
  });

  group('the local pass', () {
    test('walks the whole history and keeps only the matching days', () async {
      final h = await _build([
        _page(
          [
            _order(1, '2026-08-11T21:47:04+05:30'),
            _order(2, '2026-08-01T09:00:00+05:30'),
            _order(3, '2026-07-31T23:59:00+05:30'),
            _order(4, '2026-09-01T00:01:00+05:30'),
          ],
          currentPage: 1,
          lastPage: 1,
        ),
      ]);

      final res = await h.repo.orders(
        dateRange: DateRange(DateTime(2026, 8, 1), DateTime(2026, 8, 31)),
      );

      expect(res.items.map((o) => o.id), [1, 2]);
      // A filtered read is complete, so the screen never tries to page it.
      expect(res.hasMore, isFalse);
      // The count is of what is on screen, not of the history behind it.
      expect(res.meta.total, 2);
    });

    test('an order at 21:47 on the closing day is IN the range', () async {
      // The bug an exclusive end bound would produce: the account's newest
      // order vanishing from a range that ends on the day it was placed.
      final h = await _build([
        _page([_order(1, '2026-08-11T21:47:04+05:30')],
            currentPage: 1, lastPage: 1,),
      ]);

      final res = await h.repo.orders(
        dateRange: DateRange(DateTime(2026, 8, 11), DateTime(2026, 8, 11)),
      );

      expect(res.items.map((o) => o.id), [1]);
    });

    test('sends NO date parameters — the server would ignore them anyway',
        () async {
      final h = await _build([
        _page([_order(1, '2026-08-11T21:47:04+05:30')],
            currentPage: 1, lastPage: 1,),
      ]);

      await h.repo.orders(
        dateRange: DateRange(DateTime(2026, 8, 1), DateTime(2026, 8, 31)),
      );

      final q = _queryOf(h.adapter.requests.single);
      expect(q.containsKey('from_date'), isFalse);
      expect(q.containsKey('to_date'), isFalse);
      // ...and asks for big pages, because it has to read everything.
      expect(q['per_page'], 100);
      expect(q['page'], 1);
    });

    test('follows the server\'s pagination to the end', () async {
      final h = await _build([
        _page([_order(1, '2026-08-11T10:00:00+05:30')],
            currentPage: 1, lastPage: 3,),
        _page([_order(2, '2026-03-05T10:00:00+05:30')],
            currentPage: 2, lastPage: 3,),
        _page([_order(3, '2026-08-02T10:00:00+05:30')],
            currentPage: 3, lastPage: 3,),
      ]);

      final res = await h.repo.orders(
        dateRange: DateRange(DateTime(2026, 8, 1), DateTime(2026, 8, 31)),
      );

      expect(h.adapter.requests, hasLength(3));
      expect(_queryOf(h.adapter.requests[1])['page'], 2);
      // A match on the LAST page still lands — the whole reason page-at-a-time
      // filtering was not an option.
      expect(res.items.map((o) => o.id), [1, 3]);
    });

    test('the server-side filters ride along unchanged', () async {
      final h = await _build([
        _page([_order(1, '2026-08-11T10:00:00+05:30')],
            currentPage: 1, lastPage: 1,),
      ]);

      await h.repo.orders(
        dateRange: DateRange(DateTime(2026, 8, 1), DateTime(2026, 8, 31)),
        status: 'completed',
        paymentStatus: 'completed',
      );

      final q = _queryOf(h.adapter.requests.single);
      expect(q['status'], 'completed');
      expect(q['payment_status'], 'completed');
      expect(q.containsKey('shipping_status'), isFalse);
    });

    test('an order with no date is left out rather than guessed at', () async {
      final h = await _build([
        _page(
          [
            _order(1, '2026-08-11T10:00:00+05:30'),
            {..._order(2, ''), 'created_at': null},
          ],
          currentPage: 1,
          lastPage: 1,
        ),
      ]);

      final res = await h.repo.orders(
        dateRange: DateRange(DateTime(2026, 8, 1), DateTime(2026, 8, 31)),
      );

      expect(res.items.map((o) => o.id), [1]);
    });

    test('a range matching nothing is empty, not an error', () async {
      final h = await _build([
        _page([_order(1, '2026-08-11T10:00:00+05:30')],
            currentPage: 1, lastPage: 1,),
      ]);

      final res = await h.repo.orders(
        dateRange: DateRange(DateTime(2020, 1, 1), DateTime(2020, 12, 31)),
      );

      expect(res.items, isEmpty);
      expect(res.meta.total, 0);
      expect(res.hasMore, isFalse);
    });

    test('a server that never runs out is bounded, not followed forever',
        () async {
      // Every page claims there is another. Without the guard this walks until
      // the request budget or the heap gives out.
      final h = await _build([
        _page([_order(1, '2026-08-11T10:00:00+05:30')],
            currentPage: 1, lastPage: 9999,),
      ]);

      final res = await h.repo.orders(
        dateRange: DateRange(DateTime(2026, 8, 1), DateTime(2026, 8, 31)),
      );

      expect(h.adapter.requests, hasLength(20));
      // What it did read is still returned — the rows are real, just possibly
      // not all of them. The truncation is logged for developers.
      expect(res.items, isNotEmpty);
    });
  });

  group('the day the backend ships it', () {
    setUp(() => OrderRepository.serverFiltersByDate = true);

    test('one request, with the days the patch documents', () async {
      final h = await _build([
        _page([_order(1, '2026-03-05T10:00:00+05:30')],
            currentPage: 1, lastPage: 1, total: 28,),
      ]);

      final res = await h.repo.orders(
        page: 1,
        perPage: 10,
        dateRange: DateRange(DateTime(2026, 3, 1), DateTime(2026, 3, 31)),
      );

      // One call, not a walk.
      expect(h.adapter.requests, hasLength(1));
      final q = _queryOf(h.adapter.requests.single);
      // `whereDate('created_at', '>=', $fromDate)` wants Y-m-d.
      expect(q['from_date'], '2026-03-01');
      expect(q['to_date'], '2026-03-31');
      // Ordinary paging is back: the server counts, the server pages.
      expect(q['per_page'], 10);
      expect(res.meta.total, 28);
    });

    test('paging is the server\'s again', () async {
      final h = await _build([
        _page([_order(1, '2026-03-05T10:00:00+05:30')],
            currentPage: 2, lastPage: 3, total: 28,),
      ]);

      final res = await h.repo.orders(
        page: 2,
        dateRange: DateRange(DateTime(2026, 3, 1), DateTime(2026, 3, 31)),
      );

      expect(_queryOf(h.adapter.requests.single)['page'], 2);
      expect(res.hasMore, isTrue);
    });

    test('nothing is filtered locally any more', () async {
      // The server is trusted: a row outside the range is rendered, because on
      // flip day the server is what decided it was in range. Double-filtering
      // would silently hide rows if the two ever disagreed about a boundary.
      final h = await _build([
        _page([_order(1, '2020-01-01T10:00:00+05:30')],
            currentPage: 1, lastPage: 1,),
      ]);

      final res = await h.repo.orders(
        dateRange: DateRange(DateTime(2026, 3, 1), DateTime(2026, 3, 31)),
      );

      expect(res.items.map((o) => o.id), [1]);
    });

    test('with no range it behaves exactly as before', () async {
      final h = await _build([
        _page([_order(1, '2026-08-11T10:00:00+05:30')],
            currentPage: 1, lastPage: 1,),
      ]);

      await h.repo.orders();

      final q = _queryOf(h.adapter.requests.single);
      expect(q.containsKey('from_date'), isFalse);
      expect(q.containsKey('to_date'), isFalse);
    });
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/repositories/notification_repository.dart';

/// The notification list endpoint does NOT use the `{data: [...]}` envelope the
/// rest of the API uses — its `data` is an object holding `notifications`,
/// `pagination` and `unread_count`. The repository used to hand that body to
/// `unwrapList`, which returns `const []` for a non-list `data`, so the screen
/// could only ever render empty no matter what the server sent. Every envelope
/// below was captured live from `https://dev.truewayerp.com/api/v1` on
/// 2026-08-01; the per-item row is transcribed from
/// `vendor/botble/api/src/Http/Controllers/NotificationController@index`
/// because the probe account has zero notifications.

class _Canned {
  const _Canned(this.statusCode, this.body);
  final int statusCode;
  final Object body;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);

  final Map<String, _Canned> responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final canned = responses[options.path] ??
        const _Canned(404, {'message': 'no canned response'});
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

Future<({NotificationRepository repo, _FakeAdapter adapter})> _build(
  Map<String, _Canned> responses,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(responses);
  final dio = Dio()..httpClientAdapter = adapter;
  return (
    repo: NotificationRepository(ApiClient(prefs: prefs, dio: dio)),
    adapter: adapter,
  );
}

const _list = '/notifications';
const _stats = '/notifications/stats';
const _markAll = '/notifications/mark-all-read';
String _markRead(int id) => '/notifications/$id/read';

/// One recipient row, field-for-field from the controller's transform array.
Map<String, dynamic> _row({
  int id = 9,
  bool isRead = false,
  String? actionUrl = '/orders/277',
  String? type = 'order',
}) =>
    {
      'id': id,
      'notification_id': 3,
      'title': 'Your order is on the way',
      'message': 'Order #277 has been dispatched.',
      'type': type,
      'action_url': actionUrl,
      'image_url': null,
      'data': null,
      'is_read': isRead,
      'is_clicked': false,
      'sent_at': '2026-08-01T07:34:01.000000Z',
      'read_at': null,
      'clicked_at': null,
      'created_at': '2026-08-01T07:34:01.000000Z',
    };

Map<String, dynamic> _listBody({
  List<Map<String, dynamic>> rows = const [],
  int currentPage = 1,
  int lastPage = 1,
  int perPage = 20,
  int total = 0,
  bool hasMore = false,
  int unreadCount = 0,
}) =>
    {
      'error': false,
      'data': {
        'notifications': rows,
        'pagination': {
          'current_page': currentPage,
          'last_page': lastPage,
          'per_page': perPage,
          'total': total,
          'has_more': hasMore,
        },
        'unread_count': unreadCount,
      },
      'message': null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('list', () {
    test('parses rows out of the nested data.notifications object', () async {
      final t = await _build({
        _list: _Canned(
          200,
          _listBody(
            rows: [_row(id: 9), _row(id: 10, isRead: true)],
            total: 2,
            unreadCount: 1,
          ),
        ),
      });

      final page = await t.repo.list();

      // The regression itself: this was `[]` before the fix.
      expect(page.items, hasLength(2));
      expect(page.items.first.id, 9);
      expect(page.items.first.title, 'Your order is on the way');
      expect(page.items.first.isRead, isFalse);
      expect(page.items.first.actionUrl, '/orders/277');
      expect(page.items.last.isRead, isTrue);
    });

    test('surfaces pagination and unread_count instead of dropping them', () async {
      final t = await _build({
        _list: _Canned(
          200,
          _listBody(
            rows: [_row()],
            currentPage: 2,
            lastPage: 5,
            perPage: 20,
            total: 93,
            hasMore: true,
            unreadCount: 7,
          ),
        ),
      });

      final page = await t.repo.list(page: 2);

      expect(page.currentPage, 2);
      expect(page.lastPage, 5);
      expect(page.perPage, 20);
      expect(page.total, 93);
      expect(page.hasMore, isTrue);
      expect(page.unreadCount, 7);
    });

    test('the real empty envelope yields an empty page, not an error', () async {
      // Verbatim live capture from the probe account (total = 0).
      final t = await _build({
        _list: const _Canned(200, {
          'error': false,
          'data': {
            'notifications': <dynamic>[],
            'pagination': {
              'current_page': 1,
              'last_page': 1,
              'per_page': 20,
              'total': 0,
              'has_more': false,
            },
            'unread_count': 0,
          },
          'message': null,
        }),
      });

      final page = await t.repo.list();

      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
      expect(page.unreadCount, 0);
    });

    test('falls back to page arithmetic when has_more is absent', () async {
      final t = await _build({
        _list: const _Canned(200, {
          'error': false,
          'data': {
            'notifications': <dynamic>[],
            'pagination': {'current_page': 1, 'last_page': 3},
            'unread_count': 0,
          },
        }),
      });

      expect((await t.repo.list()).hasMore, isTrue);
    });

    test('a malformed data payload degrades to an empty page', () async {
      final t = await _build({
        _list: const _Canned(200, {'error': false, 'data': null}),
      });

      final page = await t.repo.list();
      expect(page.items, isEmpty);
      expect(page.unreadCount, 0);
    });

    test('sends page, per_page and the optional filters', () async {
      final t = await _build({_list: _Canned(200, _listBody())});

      await t.repo.list(page: 3, perPage: 50, unreadOnly: true, type: 'order');

      final q = t.adapter.requests.single.uri.queryParameters;
      expect(q['page'], '3');
      expect(q['per_page'], '50');
      expect(q['unread_only'], 'true');
      expect(q['type'], 'order');
    });

    test('omits unread_only and type when they are not asked for', () async {
      final t = await _build({_list: _Canned(200, _listBody())});

      await t.repo.list();

      final q = t.adapter.requests.single.uri.queryParameters;
      expect(q.containsKey('unread_only'), isFalse);
      expect(q.containsKey('type'), isFalse);
    });

    test('a 401 surfaces as an ApiException rather than an empty inbox', () async {
      final t = await _build({
        _list: const _Canned(401, {
          'error': true,
          'data': null,
          'message': 'Unauthenticated.',
        }),
      });

      await expectLater(t.repo.list(), throwsA(isA<ApiException>()));
    });
  });

  group('stats', () {
    test('reads the four counters out of data', () async {
      final t = await _build({
        _stats: const _Canned(200, {
          'error': false,
          'data': {'total': 12, 'unread': 5, 'read': 7, 'clicked': 2},
          'message': null,
        }),
      });

      final stats = await t.repo.stats();

      expect(stats.total, 12);
      expect(stats.unread, 5);
      expect(stats.hasUnread, isTrue);
      expect(t.adapter.requests.single.path, _stats);
    });

    test('an all-zero account reports no unread', () async {
      final t = await _build({
        _stats: const _Canned(200, {
          'error': false,
          'data': {'total': 0, 'unread': 0, 'read': 0, 'clicked': 0},
          'message': null,
        }),
      });

      expect((await t.repo.stats()).hasUnread, isFalse);
    });
  });

  group('mutations', () {
    test('markAllRead returns the server-reported marked_count', () async {
      final t = await _build({
        _markAll: const _Canned(200, {
          'error': false,
          'data': {'marked_count': 4},
          'message': 'Marked 4 notifications as read',
        }),
      });

      expect(await t.repo.markAllRead(), 4);
      expect(t.adapter.requests.single.method, 'POST');
    });

    test('markAllRead reports 0 rather than guessing when data is null', () async {
      final t = await _build({
        _markAll: const _Canned(200, {'error': false, 'data': null}),
      });

      expect(await t.repo.markAllRead(), 0);
    });

    test('markRead posts to the recipient row id', () async {
      final t = await _build({
        _markRead(9): const _Canned(200, {
          'error': false,
          'data': null,
          'message': 'Notification marked as read',
        }),
      });

      await t.repo.markRead(9);

      expect(t.adapter.requests.single.path, '/notifications/9/read');
      expect(t.adapter.requests.single.method, 'POST');
    });

    test('delete hits DELETE /notifications/{id}', () async {
      final t = await _build({
        '/notifications/9': const _Canned(200, {
          'error': false,
          'data': null,
          'message': 'Notification deleted successfully',
        }),
      });

      await t.repo.delete(9);

      expect(t.adapter.requests.single.path, '/notifications/9');
      expect(t.adapter.requests.single.method, 'DELETE');
    });

    test('markRead on a foreign or deleted row raises the 404', () async {
      final t = await _build({
        _markRead(999999): const _Canned(404, {
          'error': true,
          'data': null,
          'message': 'Notification not found',
        }),
      });

      await expectLater(
        t.repo.markRead(999999),
        throwsA(
          isA<ApiException>()
              .having((e) => e.message, 'message', contains('not found')),
        ),
      );
    });
  });
}

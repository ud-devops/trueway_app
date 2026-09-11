import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/utils/json_utils.dart';
import '../models/app_notification.dart';

/// One page of `GET /api/v1/notifications`.
///
/// The list endpoint does NOT use the standard `{data: [...], meta: {...}}`
/// envelope that `PaginatedResponse` parses. Its `data` is an **object**:
///
/// ```jsonc
/// { "error": false,
///   "data": {
///     "notifications": [ ... ],
///     "pagination": { "current_page":1, "last_page":1, "per_page":20,
///                     "total":0, "has_more":false },
///     "unread_count": 0 },
///   "message": null }
/// ```
///
/// Verified live against `https://dev.truewayerp.com/api/v1/notifications`
/// (2026-08-01) and against
/// `vendor/botble/api/src/Http/Controllers/NotificationController@index`.
class NotificationPage {
  const NotificationPage({
    this.items = const [],
    this.currentPage = 1,
    this.lastPage = 1,
    this.perPage = 20,
    this.total = 0,
    this.hasMore = false,
    this.unreadCount = 0,
  });

  final List<AppNotification> items;
  final int currentPage;
  final int lastPage;
  final int perPage;
  final int total;

  /// Straight from `data.pagination.has_more` — the server computes it, so we
  /// never have to guess from `items.length`.
  final bool hasMore;

  /// `data.unread_count`, a whole-account count that is NOT limited to this
  /// page. Free with every list call, so the badge does not need `/stats`.
  final int unreadCount;

  factory NotificationPage.fromEnvelope(dynamic body) {
    // `data` is a map here, not a list — passing this body to `unwrapList`
    // silently yields `const []`, which is exactly why the screen could only
    // ever render empty.
    final data = (body is Map) ? body['data'] : body;
    if (data is! Map) return const NotificationPage();

    final rawItems = data['notifications'];
    final items = rawItems is List
        ? rawItems
            .whereType<Map>()
            .map((e) => AppNotification.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : <AppNotification>[];

    final rawPagination = data['pagination'];
    final pagination = rawPagination is Map
        ? Map<String, dynamic>.from(rawPagination)
        : const <String, dynamic>{};

    final currentPage = asInt(pagination['current_page'], 1);
    final lastPage = asInt(pagination['last_page'], 1);

    return NotificationPage(
      items: items,
      currentPage: currentPage,
      lastPage: lastPage,
      perPage: asInt(pagination['per_page'], items.length),
      total: asInt(pagination['total'], items.length),
      // Prefer the server's flag; fall back to the page arithmetic only when
      // the key is absent.
      hasMore: pagination.containsKey('has_more')
          ? asBool(pagination['has_more'])
          : currentPage < lastPage,
      unreadCount: asInt(data['unread_count']),
    );
  }
}

/// Customer notifications, from the `botble/api` package.
///
/// Every endpoint here is `auth:sanctum` — a signed-out customer gets 401, so
/// callers must gate on auth rather than letting the badge fire a doomed
/// request on every launch.
///
/// Route inventory verified against `vendor/botble/api/routes/api.php` lines
/// 42-47 and probed live on 2026-08-01. All four paths the app uses exist:
///   GET    /notifications                 200
///   GET    /notifications/stats           200
///   POST   /notifications/mark-all-read   200 `{marked_count}`
///   POST   /notifications/{id}/read       200 / 404 `Notification not found`
///   POST   /notifications/{id}/clicked  Allow: POST, bearer-guarded (probed)
///   DELETE /notifications/{id}           200 / 404 `Notification not found`
/// There is no `GET /notifications/{id}` — `OPTIONS` answers `Allow: DELETE`
/// alone, so a row can never be re-read after it is deleted.
class NotificationRepository {
  NotificationRepository(this._api);

  final ApiClient _api;

  Future<NotificationPage> list({
    int page = 1,
    int perPage = 20,
    bool unreadOnly = false,
    String? type,
  }) async {
    final res = await _api.get(
      ApiEndpoints.notifications,
      query: {
        'page': page,
        // The server caps this at 50.
        'per_page': perPage,
        if (unreadOnly) 'unread_only': true,
        if (type != null && type.isNotEmpty) 'type': type,
      },
    );
    return NotificationPage.fromEnvelope(res.data);
  }

  /// `GET /notifications/stats` -> `{total, unread, read, clicked}`.
  ///
  /// [NotificationStats] only models `total` and `unread`; `read` and
  /// `clicked` are returned by the server but not surfaced.
  Future<NotificationStats> stats() async {
    final res = await _api.get(ApiEndpoints.notificationStats);
    final data = res.data;
    final map = (data is Map && data['data'] is Map)
        ? Map<String, dynamic>.from(data['data'] as Map)
        : (data is Map ? Map<String, dynamic>.from(data) : const <String, dynamic>{});
    return NotificationStats.fromJson(map);
  }

  /// [id] is the recipient row id from [AppNotification.id].
  ///
  /// 404 `Notification not found` when the row belongs to someone else or has
  /// been deleted — surfaced as an `ApiException` by [ApiClient].
  Future<void> markRead(int id) =>
      _api.post(ApiEndpoints.markNotificationRead(id));

  /// Records that the customer *opened* [id].
  ///
  /// This is the tap handler's call, not [markRead]: `markAsClicked()` stamps
  /// `clicked_at` and cascades to `markAsRead()`, so one round trip does both.
  /// `/notifications/stats` publishes a `clicked` counter that stays at zero
  /// for ever if nothing ever calls this.
  Future<void> markClicked(int id) =>
      _api.post(ApiEndpoints.markNotificationClicked(id));

  /// Returns how many rows the server actually flipped (`data.marked_count`).
  Future<int> markAllRead() async {
    final res = await _api.post(ApiEndpoints.markAllNotificationsRead);
    final data = res.data;
    if (data is Map && data['data'] is Map) {
      return asInt((data['data'] as Map)['marked_count']);
    }
    return 0;
  }

  /// Deletes the **recipient row** only — the parent push notification, and
  /// everyone else's copy of it, are untouched. 404 `Notification not found`
  /// for an unknown id or one belonging to another customer; the two are
  /// indistinguishable.
  ///
  /// There is no undo: nothing in this API re-creates a recipient row.
  Future<void> delete(int id) => _api.delete(ApiEndpoints.notification(id));
}

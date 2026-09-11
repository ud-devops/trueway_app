import '../../core/utils/json_utils.dart';

/// A push notification delivered to the signed-in customer.
///
/// Shape from `GET /api/v1/notifications` (botble/api `NotificationController`),
/// which returns one entry per *recipient* row:
///
/// ```jsonc
/// { "id": 9, "notification_id": 3, "title": "…", "message": "…",
///   "type": "order", "action_url": "/orders/12", "image_url": null,
///   "is_read": false, "is_clicked": false,
///   "sent_at": "…", "read_at": null, "created_at": "…" }
/// ```
///
/// [id] is the recipient row — the id the read/click/delete endpoints take,
/// not [notificationId].
class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.isRead,
    this.isClicked = false,
    this.notificationId,
    this.type,
    this.actionUrl,
    this.imageUrl,
    this.createdAt,
  });

  final int id;
  final int? notificationId;
  final String title;
  final String message;
  final bool isRead;

  /// Whether this row has ever been opened, from `is_clicked`
  /// (`clicked_at != null` server-side).
  ///
  /// Kept so a tap on an already-opened row does not spend a round trip
  /// re-recording a click the server already has.
  final bool isClicked;

  /// Server-defined category, e.g. `order`, `promotion`.
  final String? type;

  /// Where tapping should take the customer, when the server supplies it.
  final String? actionUrl;

  final String? imageUrl;
  final DateTime? createdAt;

  AppNotification copyWith({bool? isRead, bool? isClicked}) => AppNotification(
        id: id,
        notificationId: notificationId,
        title: title,
        message: message,
        isRead: isRead ?? this.isRead,
        isClicked: isClicked ?? this.isClicked,
        type: type,
        actionUrl: actionUrl,
        imageUrl: imageUrl,
        createdAt: createdAt,
      );

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: asInt(j['id']),
        notificationId:
            j['notification_id'] == null ? null : asInt(j['notification_id']),
        title: asString(j['title']),
        message: asString(j['message']),
        isRead: asBool(j['is_read']),
        isClicked: asBool(j['is_clicked']),
        type: asStringOrNull(j['type']),
        actionUrl: asStringOrNull(j['action_url']),
        imageUrl: asStringOrNull(j['image_url']),
        createdAt: DateTime.tryParse(
          asString(j['created_at'] ?? j['sent_at']),
        ),
      );
}

/// Counts from `GET /api/v1/notifications/stats`.
class NotificationStats {
  const NotificationStats({this.total = 0, this.unread = 0});

  final int total;
  final int unread;

  bool get hasUnread => unread > 0;

  factory NotificationStats.fromJson(Map<String, dynamic> j) =>
      NotificationStats(
        total: asInt(j['total']),
        unread: asInt(j['unread']),
      );
}

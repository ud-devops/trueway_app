import '../../core/utils/json_utils.dart';
import '../../core/utils/price_utils.dart';
import 'order.dart';

/// Return-request status tokens.
///
/// Same American `canceled` spelling as [OrderStatuses]. `resubmit` means the
/// admin bounced the request back and the customer may edit and send it again —
/// see [OrderReturn.canResubmit].
class ReturnStatuses {
  ReturnStatuses._();

  static const String pending = 'pending';
  static const String processing = 'processing';
  static const String completed = 'completed';
  static const String canceled = 'canceled';
  static const String resubmit = 'resubmit';
}

/// Reason tokens the customer may submit.
///
/// The server's allowed set is admin-managed (`ec_order_reasons`), so this list
/// is a fallback for offline rendering only. Fetch the live list from
/// `OrderRepository.returnEligibility()` before showing a picker, otherwise a
/// disabled reason 422s with "The selected return reason is not allowed."
class ReturnReasons {
  ReturnReasons._();

  static const String damaged = 'damaged';
  static const String defective = 'defective';
  static const String incorrectItem = 'incorrect_item';
  static const String notAsDescribed = 'not_as_described';
  static const String other = 'other';

  /// The built-in fallback set, in the server's own order.
  static const List<String> defaults = [
    damaged,
    defective,
    incorrectItem,
    notAsDescribed,
    other,
  ];
}

/// The admin action that last touched a return.
class OrderReturnHistory {
  const OrderReturnHistory({
    required this.id,
    required this.action,
    this.title = '',
    this.note,
    this.submission,
    this.createdAt,
    this.updatedAt,
  });

  final int id;

  /// The machine code — `created`, `resubmit_requested`, `approved`,
  /// `rejected`, `resubmitted`, `mark_as_completed`.
  ///
  /// **Only ever used to pick an icon.** `action.label` is written for staff —
  /// "Resubmit requested by admin", "Mark as completed" — and must never reach
  /// a customer. The set is open-ended: new codes ship server-side without an
  /// app release, so anything unrecognised falls through to a neutral marker
  /// and still renders its [title].
  final StatusValue action;

  /// The customer-facing heading, written server-side: "Return requested",
  /// "More information needed", "Return approved". This is the text to show.
  final String title;

  /// The store's message attached to this step, when it left one.
  ///
  /// Distinct from [OrderReturn.adminFeedback], which is only ever the *current*
  /// instruction while the status is `resubmit`. Once the customer answers it,
  /// the instruction stops being current — and this is where it survives, so
  /// the conversation can still be read back.
  final String? note;

  /// What the customer sent at this step. Null on every store-side step.
  ///
  /// Populated only on `created` and `resubmitted` — a return allows three
  /// submissions, so a fully-used one carries three of these, each with its
  /// own photos.
  final ReturnSubmission? submission;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// True when this step is the customer's own, which is what decides whether
  /// it renders a submission block.
  bool get isFromCustomer => submission != null;

  static OrderReturnHistory? fromJson(dynamic raw) {
    // `whenLoaded` omits the key when the relation is absent, and the closure
    // itself returns null when there is no history row.
    if (raw is! Map || raw.isEmpty) return null;
    final j = Map<String, dynamic>.from(raw);
    return OrderReturnHistory(
      id: asInt(j['id']),
      action: StatusValue.fromJson(j['action']),
      title: decodeEntities(asString(j['title'])),
      note: asStringOrNull(j['note']),
      submission: ReturnSubmission.fromJson(j['submission']),
      createdAt: parseOrderDate(j['created_at']),
      updatedAt: parseOrderDate(j['updated_at']),
    );
  }

  /// The whole timeline, newest first as the server orders it.
  static List<OrderReturnHistory> listFrom(dynamic raw) => [
        for (final row in asMapList(raw))
          if (OrderReturnHistory.fromJson(row) case final h?) h,
      ];
}

/// What a customer sent with one submission of a return.
class ReturnSubmission {
  const ReturnSubmission({
    this.reason,
    this.comment,
    this.images = const [],
    this.videos = const [],
    this.items = const [],
  });

  /// Request-level reason. Usually null with partial returns on — the reason
  /// lives per item instead.
  final String? reason;

  /// The customer's own words. Required server-side at 50 characters minimum.
  final String? comment;

  /// Absolute URLs, ready to load.
  final List<String> images;

  /// Also absolute, and **not** images: a player badge, never an `<img>`.
  final List<String> videos;

  final List<ReturnSubmissionItem> items;

  bool get hasMedia => images.isNotEmpty || videos.isNotEmpty;

  bool get isEmpty =>
      (comment ?? '').trim().isEmpty && !hasMedia && items.isEmpty;

  /// Whether this has anything a screen actually renders.
  ///
  /// Narrower than [isEmpty] on purpose: the timeline shows the customer's own
  /// words and their evidence, and **not** the items — those are already listed
  /// once, with their reasons, in the return's own Items section. So a
  /// submission that named items and said nothing else is not empty data, but
  /// there is nothing to draw for it.
  bool get hasVisibleContent =>
      (comment ?? '').trim().isNotEmpty || hasMedia;

  static ReturnSubmission? fromJson(dynamic raw) {
    if (raw is! Map || raw.isEmpty) return null;
    final j = Map<String, dynamic>.from(raw);
    final submission = ReturnSubmission(
      reason: asStringOrNull(j['reason']),
      comment: asStringOrNull(j['customer_comment']),
      images: asStringList(j['media_images']),
      videos: asStringList(j['media_videos']),
      items: [
        for (final row in asMapList(j['items'])) ReturnSubmissionItem.fromJson(row),
      ],
    );
    // A submission block with nothing in it is not a submission; rendering an
    // empty card under a step would say the customer sent something blank.
    return submission.isEmpty ? null : submission;
  }
}

/// One product named in a submission, with the reason given for it.
class ReturnSubmissionItem {
  const ReturnSubmissionItem({
    required this.name,
    this.reason,
    this.images = const [],
    this.videos = const [],
  });

  final String name;

  /// Already the display label ("Incorrect item"), not a slug.
  final String? reason;

  final List<String> images;
  final List<String> videos;

  factory ReturnSubmissionItem.fromJson(Map<String, dynamic> j) =>
      ReturnSubmissionItem(
        name: decodeEntities(asString(j['product_name'])),
        reason: asStringOrNull(j['reason']),
        images: asStringList(j['media_images']),
        videos: asStringList(j['media_videos']),
      );
}

/// One product inside a return request.
class OrderReturnItem {
  const OrderReturnItem({
    required this.id,
    required this.orderReturnId,
    required this.orderProductId,
    required this.productId,
    required this.name,
    required this.imageUrl,
    required this.quantity,
    required this.price,
    required this.refundAmount,
    required this.reason,
    this.images = const [],
    this.videos = const [],
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final int orderReturnId;

  /// `ec_order_product.id` — links back to [OrderLine.id].
  final int orderProductId;
  final int productId;
  final String name;
  final String imageUrl;
  final int quantity;

  /// 2dp strings ("877.62"), as everywhere else.
  final double price;

  /// What the server calculated as refundable for this line — NOT
  /// `price * quantity`. It is prorated against the order's refundable pool
  /// (total minus shipping, tax and any Shiprocket RTO charge), so it can be
  /// lower than the line total. Always show this value, never recompute it.
  final double refundAmount;

  /// Per-item reason. Independent of the request-level [OrderReturn.reason]:
  /// with partial returns enabled the server requires the per-item one and
  /// leaves the request-level field empty.
  final StatusValue reason;

  final List<String> images;
  final List<String> videos;
  final DateTime? createdAt;

  /// Null on 10/12 captured items — only set once an admin touched the row.
  final DateTime? updatedAt;

  factory OrderReturnItem.fromJson(Map<String, dynamic> j) => OrderReturnItem(
        id: asInt(j['id']),
        orderReturnId: asInt(j['order_return_id']),
        orderProductId: asInt(j['order_product_id']),
        productId: asInt(j['product_id']),
        name: decodeEntities(asString(j['product_name'])),
        imageUrl: resolveOrderMedia(j['product_image']),
        quantity: asInt(j['qty']),
        price: asDouble(j['price']),
        refundAmount: asDouble(j['refund_amount']),
        reason: StatusValue.fromJson(j['reason']),
        images: asStringList(j['media_images']),
        videos: asStringList(j['media_videos']),
        createdAt: parseOrderDate(j['created_at']),
        updatedAt: parseOrderDate(j['updated_at']),
      );

  String get priceDisplay => PriceUtils.format(price);
  String get refundDisplay => PriceUtils.format(refundAmount);
}

/// A return request.
///
/// `GET /ecommerce/order-returns` (hybrid paginated envelope) and
/// `GET /ecommerce/order-returns/{id}` return the identical shape — unlike
/// orders, the list rows already carry their [items], so a returns list needs
/// no per-row detail call.
class OrderReturn {
  const OrderReturn({
    required this.id,
    required this.orderId,
    required this.orderCode,
    required this.status,
    required this.reason,
    required this.submissionCount,
    required this.itemsCount,
    this.customerComment,
    this.images = const [],
    this.videos = const [],
    this.items = const [],
    this.createdAt,
    this.updatedAt,
    this.latestHistory,
    this.canResubmit = false,
    this.histories = const [],
    this.adminFeedback,
    this.isRefundedFlag,
    this.refundedAmount,
  });

  final int id;
  final int orderId;

  /// Carries the same two-format problem as [Order.code] — use [displayCode].
  final String orderCode;

  final StatusValue status;

  /// ⚠ Empty on 9/10 captured returns, in BOTH degenerate forms:
  /// `{value: null, label: ""}` (7) and `{value: "", label: ""}` (2). With
  /// partial returns enabled the real reason lives on each [OrderReturnItem];
  /// [effectiveReason] resolves that.
  final StatusValue reason;

  /// Server-enforced: max 3 submissions, so [canResubmit] is false once this
  /// reaches 3 even while the status still says `resubmit`.
  final int submissionCount;

  /// Server-side `withCount`. Matched `items.length` on every captured row, but
  /// it is the count to trust if a future response ever truncates items.
  final int itemsCount;

  /// Required on submit: 50–2000 characters. Null on 3/10 older rows created
  /// before that rule existed.
  final String? customerComment;

  final List<String> images;
  final List<String> videos;
  final List<OrderReturnItem> items;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final OrderReturnHistory? latestHistory;

  /// Every step, newest first. Present on all four return endpoints — list,
  /// detail, create and resubmit — so a screen never needs a follow-up call.
  final List<OrderReturnHistory> histories;

  bool get hasHistory => histories.isNotEmpty;

  /// Server-computed as `status == resubmit && submission_count < 3`. Trust it
  /// rather than re-deriving.
  final bool canResubmit;

  /// The admin's rejection note, present only while the status is `resubmit`.
  /// Can be long (400+ chars observed) — give it room to wrap.
  final String? adminFeedback;

  /// Whether the shop has actually sent the money back — **null when the
  /// server did not say**, which is the case today.
  ///
  /// `ec_order_returns.is_refunded` is a real column, written only by the
  /// admin's refund action (OrderController::refund), and the admin UI already
  /// reads it. It is simply not serialised: verified live on 2026-08-19
  /// against both `GET /ecommerce/order-returns` and
  /// `/ecommerce/order-returns/{id}` — eighteen keys, and neither
  /// `is_refunded` nor `refunded_amount` among them.
  ///
  /// Kept nullable rather than defaulted to false so [isRefunded] can tell
  /// "the server says no" from "the server has not shipped this yet". The day
  /// it ships, the parsed value wins and the fallback below goes quiet on its
  /// own.
  final bool? isRefundedFlag;

  /// What was actually refunded, once the server reports it. See
  /// [isRefundedFlag]; [refundedTotal] is what to render.
  final double? refundedAmount;

  factory OrderReturn.fromJson(Map<String, dynamic> j) => OrderReturn(
        id: asInt(j['id']),
        orderId: asInt(j['order_id']),
        orderCode: asString(j['order_code']),
        status: StatusValue.fromJson(j['return_status']),
        reason: StatusValue.fromJson(j['reason']),
        submissionCount: asInt(j['submission_count']),
        itemsCount:
            j.containsKey('items_count') ? asInt(j['items_count']) : asMapList(j['items']).length,
        customerComment: asStringOrNull(j['customer_comment']),
        images: asStringList(j['media_images']),
        videos: asStringList(j['media_videos']),
        items: asMapList(j['items']).map(OrderReturnItem.fromJson).toList(),
        createdAt: parseOrderDate(j['created_at']),
        updatedAt: parseOrderDate(j['updated_at']),
        latestHistory: OrderReturnHistory.fromJson(j['latest_history']),
        histories: OrderReturnHistory.listFrom(j['histories']),
        canResubmit: asBool(j['can_resubmit']),
        adminFeedback: asStringOrNull(j['admin_feedback']),
        isRefundedFlag:
            j.containsKey('is_refunded') ? asBool(j['is_refunded']) : null,
        refundedAmount: asDoubleOrNull(j['refunded_amount']),
      );

  String get displayCode =>
      orderCode.startsWith('#') ? orderCode.substring(1) : orderCode;

  /// The reason to show: the request-level one when the server set it,
  /// otherwise the first item's.
  StatusValue get effectiveReason {
    if (reason.isNotEmpty) return reason;
    for (final item in items) {
      if (item.reason.isNotEmpty) return item.reason;
    }
    return StatusValue.none;
  }

  /// Sum of the server's prorated per-item refunds.
  double get refundTotal =>
      items.fold<double>(0, (sum, item) => sum + item.refundAmount);

  String get refundTotalDisplay => PriceUtils.format(refundTotal);

  bool get isOpen =>
      status.matches(ReturnStatuses.pending) ||
      status.matches(ReturnStatuses.processing) ||
      status.matches(ReturnStatuses.resubmit);

  /// How many units of order line [orderProductId] this request covers.
  ///
  /// Zero when the line is not part of it. `order_product_id` is the order's
  /// own `products[].id` — the *line* id, not the product id — so a basket
  /// holding the same product on two lines keeps them apart.
  int returnedQtyOf(int orderProductId) {
    var qty = 0;
    for (final item in items) {
      if (item.orderProductId == orderProductId) qty += item.quantity;
    }
    return qty;
  }

  /// Whether the money is back.
  ///
  /// Approving a return and refunding it are two different actions on two
  /// different admin screens, so they are two different facts — which is the
  /// whole reason this getter exists rather than the screens reading `status`.
  ///
  /// Until [isRefundedFlag] ships, `completed` is the proxy, and it is a sound
  /// one on this backend: `OrderReturnController::update` refuses to move a
  /// return to `completed` while the order still has an unrefunded payment
  /// ("This return must be refunded before it can be completed"), so the
  /// status cannot reach `completed` without the money having moved first.
  /// Sound, but inferred — the flag is what should decide this, which is why
  /// it is asked for.
  bool get isRefunded =>
      isRefundedFlag ?? status.matches(ReturnStatuses.completed);

  /// Whether the shop has accepted the request.
  ///
  /// `processing` is the server's word for it: [OrderReturnHelper] writes an
  /// `approved` timeline step at exactly the transition into that status
  /// (`PROCESSING => APPROVED`). A refunded return was approved too — you
  /// cannot complete one that never got that far.
  bool get isApproved =>
      status.matches(ReturnStatuses.processing) || isRefunded;

  /// What the amount refunded is, preferring the server's own figure.
  ///
  /// [refundTotal] sums the per-item `refund_amount`, which is what the return
  /// asked for. That can differ from what was paid out — a refund is netted
  /// against RTO charges and non-refundable shipping before it is sent — so
  /// the server's number wins the moment it is available.
  double get refundedTotal => refundedAmount ?? refundTotal;

  /// The customer's name for [status].
  ///
  /// The server's labels are written for staff. "Processing" does not say
  /// whether the request was accepted, and "Completed" does not say whether
  /// the money came back — and those two are the only things the customer is
  /// waiting to hear. Both are answerable, so both are answered.
  String get stageLabel => switch (status.value) {
        ReturnStatuses.processing => 'Approved',
        ReturnStatuses.completed => isRefunded ? 'Refunded' : 'Approved',
        _ => status.display,
      };

  /// Whether this request still counts against the line.
  ///
  /// A cancelled return did not take anything back, so a line it named is
  /// wholly the customer's again and must not read "1 of 5 returned".
  bool get countsAgainstOrder => !status.matches(ReturnStatuses.canceled);

  /// Attempts left before the server refuses further resubmissions.
  int get resubmitsLeft {
    final left = maxSubmissions - submissionCount;
    return left < 0 ? 0 : left;
  }

  static const int maxSubmissions = 3;
}

/// A `{value, label}` reason offered by the server for a specific order.
typedef ReturnReasonOption = StatusValue;

/// An order line the server says may be returned.
class ReturnableItem {
  const ReturnableItem({
    required this.orderItemId,
    required this.productId,
    required this.name,
    required this.imageUrl,
    required this.quantity,
    required this.price,
  });

  /// Send this back as `return_items[].order_item_id`.
  final int orderItemId;
  final int productId;
  final String name;

  /// ⚠ This route returns the RAW storage path, not a URL, unlike every other
  /// order route. [resolveOrderMedia] handles it.
  final String imageUrl;
  final int quantity;
  final double price;

  factory ReturnableItem.fromJson(Map<String, dynamic> j) => ReturnableItem(
        orderItemId: asInt(j['order_item_id']),
        productId: asInt(j['product_id']),
        name: decodeEntities(asString(j['product_name'])),
        imageUrl: resolveOrderMedia(j['product_image']),
        quantity: asInt(j['qty']),
        price: asDouble(j['price']),
      );

  String get priceDisplay => PriceUtils.format(price);
}

/// What `GET /ecommerce/orders/{id}/returns` returns when the order IS
/// returnable: the order, the lines that may be sent back, and the reason list
/// the server will accept right now.
///
/// When the order is NOT returnable the same route answers HTTP 200 with
/// `{"error": true, "message": "You cannot return this order", "data":
/// {"reason": "..."}}`, which ApiClient turns into a thrown businessRule
/// ApiException — and the `data.reason` hint is lost with it. See
/// `OrderRepository.returnEligibility`.
class ReturnEligibility {
  const ReturnEligibility({
    this.order,
    this.items = const [],
    this.reasons = const [],
  });

  final Order? order;
  final List<ReturnableItem> items;
  final List<ReturnReasonOption> reasons;

  factory ReturnEligibility.fromJson(Map<String, dynamic> j) {
    final order = j['order'];
    return ReturnEligibility(
      order: order is Map ? Order.fromJson(Map<String, dynamic>.from(order)) : null,
      items: asMapList(j['returnable_items']).map(ReturnableItem.fromJson).toList(),
      reasons: asMapList(j['return_reasons']).map(StatusValue.fromJson).toList(),
    );
  }

  bool get isEmpty => order == null && items.isEmpty;
}

/// One line of a return submission.
class ReturnItemDraft {
  const ReturnItemDraft({
    required this.orderItemId,
    required this.quantity,
    required this.reason,
    this.images = const [],
    this.videos = const [],
  });

  final int orderItemId;
  final int quantity;
  final String reason;

  /// URLs previously returned by `POST /ecommerce/order-returns/upload-media`.
  /// The submit endpoint does not accept file bytes.
  final List<String> images;
  final List<String> videos;

  Map<String, dynamic> toJson() => {
        'order_item_id': orderItemId,
        // The controller keeps only the items that HAVE an `is_return` key
        // (`Arr::where(..., fn ($v) => isset($v['is_return']))`), so omitting
        // it silently drops the line and the request fails with "Please select
        // at least 1 product to return!".
        'is_return': true,
        'qty': quantity,
        'reason': reason,
        if (images.isNotEmpty) 'media_images': images,
        if (videos.isNotEmpty) 'media_videos': videos,
      };
}

/// Body for `POST /ecommerce/order-returns`.
class ReturnDraft {
  const ReturnDraft({
    required this.orderId,
    required this.customerComment,
    required this.items,
    this.reason,
    this.images = const [],
    this.videos = const [],
  });

  final int orderId;

  /// Required, 50–2000 characters — the single most common 422 on this route.
  /// Validate with [commentError] before sending.
  final String customerComment;

  final List<ReturnItemDraft> items;

  /// Request-level reason. Only required when the shop has partial returns
  /// DISABLED; with them enabled the server wants a reason per item instead.
  /// Sending both is accepted.
  final String? reason;

  final List<String> images;
  final List<String> videos;

  static const int minCommentLength = 50;
  static const int maxCommentLength = 2000;

  /// Client-side mirror of the server rule, so the customer is not made to
  /// round-trip a 2000-character form to learn their note was too short.
  static String? commentError(String value) {
    final text = value.trim();
    if (text.isEmpty) {
      return 'Please enter additional comments describing your return.';
    }
    if (text.length < minCommentLength) {
      return 'Additional comments must be at least $minCommentLength characters.';
    }
    if (text.length > maxCommentLength) {
      return 'Additional comments must not be greater than $maxCommentLength characters.';
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'order_id': orderId,
        'customer_comment': customerComment,
        if (reason != null && reason!.isNotEmpty) 'reason': reason,
        'return_items': items.map((item) => item.toJson()).toList(),
        if (images.isNotEmpty) 'media_images': images,
        if (videos.isNotEmpty) 'media_videos': videos,
      };
}

/// Body for `POST /ecommerce/order-returns/{id}/resubmit`.
///
/// Carries no `order_id` — the return already knows its order — and references
/// existing rows by `return_item_id`, not `order_item_id`.
class ReturnResubmitDraft {
  const ReturnResubmitDraft({
    required this.customerComment,
    this.reason,
    this.items = const [],
    this.images = const [],
    this.videos = const [],
  });

  final String customerComment;
  final String? reason;
  final List<ReturnResubmitItemDraft> items;
  final List<String> images;
  final List<String> videos;

  Map<String, dynamic> toJson() => {
        'customer_comment': customerComment,
        if (reason != null && reason!.isNotEmpty) 'reason': reason,
        if (items.isNotEmpty)
          'return_items': items.map((item) => item.toJson()).toList(),
        if (images.isNotEmpty) 'media_images': images,
        if (videos.isNotEmpty) 'media_videos': videos,
      };
}

class ReturnResubmitItemDraft {
  const ReturnResubmitItemDraft({
    required this.returnItemId,
    required this.reason,
    this.images = const [],
    this.videos = const [],
  });

  /// [OrderReturnItem.id], not the order-product id.
  final int returnItemId;

  /// Required on every listed item — omitting it 422s with "Please select a
  /// return reason." even though the item already had one.
  final String reason;

  final List<String> images;
  final List<String> videos;

  Map<String, dynamic> toJson() => {
        'return_item_id': returnItemId,
        'reason': reason,
        if (images.isNotEmpty) 'media_images': images,
        if (videos.isNotEmpty) 'media_videos': videos,
      };
}

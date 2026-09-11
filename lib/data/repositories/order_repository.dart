import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../core/errors/api_exception.dart';
import '../../core/errors/error_presenter.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_response.dart';
import '../../core/utils/date_range.dart';
import '../../core/utils/json_utils.dart';
import '../models/order.dart';
import '../models/order_return.dart';

/// A downloaded invoice: the PDF bytes and the name the server gave them.
///
/// Held in memory rather than written to disk here — the repository has no
/// business choosing a directory, and `share_plus` takes bytes directly.
class InvoicePdf {
  const InvoicePdf({required this.bytes, required this.fileName});

  final Uint8List bytes;

  /// From the server's `Content-Disposition`, e.g. `invoice-INV-97.pdf`. The
  /// invoice code is numbered independently of orders — order 131 is invoice
  /// `INV-97` — so it can only come from the server.
  final String fileName;

  int get sizeBytes => bytes.length;
}

/// Orders and returns. Every route here needs a bearer token — guest tracking
/// was removed from the product, so there is no longer an anonymous order path.
///
/// Everything here goes through [ApiClient], which attaches the bearer token
/// and has already converted `HTTP 200 + {"error": true}` into a thrown
/// [ApiException] with `kind: businessRule` — so a method that returns normally
/// means the server agreed.
class OrderRepository {
  OrderRepository(this._api);

  final ApiClient _api;

  /// The controller's own default — `$request->integer('per_page', 10)` — and
  /// what a page of orders comes back as when the key is omitted
  /// (`01_orders_default.json`, `meta.per_page: 10`).
  ///
  /// Note this is NOT what an *unparseable* value falls back to: `per_page=0`
  /// and `per_page=abc` both reach the paginator as 0 and it substitutes its
  /// own 15 (`pg_per_page_0.json`, `pg_per_page_abc.json`). Sending 10
  /// explicitly is what keeps the page size predictable.
  static const int _defaultPerPage = 10;

  /// `per_page` above this is pointless — the account's whole history is 90
  /// rows — and large values make the response several hundred KB.
  static const int _maxPerPage = 100;

  /// **THE SWAP.** Flip this to `true` the day `GET /orders` learns
  /// `from_date` / `to_date`, and the whole date filter moves to the server —
  /// nothing above this file changes, and [_ordersInDateRange] below becomes
  /// dead code to delete.
  ///
  /// Verified false today, live and by param sweep: `from_date`+`to_date`,
  /// `start_date`+`end_date`, `date_from`+`date_to`, `year`, `year`+`month`,
  /// `created_at`, `from`+`to` — all seven returned the account's whole
  /// history of 94 orders, unfiltered. They are not rejected either, so a
  /// client sending one has no way to notice it did nothing. The spec is in
  /// `docs/BACKEND_PATCH_order_date_filter.md`.
  ///
  /// A mutable static rather than a `const` **so the far side can be tested
  /// before it is switched on**. Flip day is meant to be one line; that is only
  /// true if the request the server branch builds has been verified, and a
  /// `const false` makes that branch unreachable dead code the analyser cannot
  /// even see into. Tests set it and restore it in a `tearDown`; nothing in
  /// `lib/` writes to it.
  static bool serverFiltersByDate = false;

  /// Pages walked at most when filtering locally.
  ///
  /// 20 x 100 = 2,000 orders, against a busiest-account history of 94, so this
  /// is a runaway guard rather than a real limit. Hitting it is logged — see
  /// [_ordersInDateRange] — because a truncated range is exactly the point at
  /// which the server-side filter stops being optional.
  static const int _maxLocalFilterPages = 20;

  /// The customer's orders, newest first.
  ///
  /// Only `is_finished = 1` orders are visible, so an abandoned checkout never
  /// appears here.
  ///
  /// Response is the HYBRID envelope: `{data, links, meta, error, message}` —
  /// a paginated body with the simple envelope's keys bolted on.
  /// [PaginatedResponse] reads data/meta/links and ignores the rest.
  ///
  /// This is the ONLY call an order list screen should make. A row carries
  /// [Order.productsCount] and [Order.productImages] for the summary but no
  /// line items; fetching [order] per row would be an N+1 over 9 pages.
  ///
  /// Filters are exact string matches against the stored token. An unknown
  /// value is NOT rejected — `?status=cancelled` (two Ls) returns HTTP 200 with
  /// `total: 0`, which is indistinguishable from "no such orders". Pass
  /// [OrderStatuses] constants.
  ///
  /// ## [dateRange] is the odd one out
  ///
  /// Every other filter here is the server's. This one is not — see
  /// [serverFiltersByDate] — so passing it changes how the call is *made*, not
  /// merely what is sent: [page] and [perPage] are ignored and the whole
  /// history is walked once. Callers do not need to know that, which is the
  /// point; the result is a [PaginatedResponse] like any other, with
  /// `hasMore: false` because everything that matched is already in it.
/// The calendar year of the customer's **first** order, or null if they have
  /// none.
  ///
  /// Two small requests, because `GET /orders` sorts newest-first and offers no
  /// way to reverse it. The first asks for a single row to learn `last_page`
  /// (which at `per_page=1` is the order count); the second asks for that page,
  /// which holds the oldest order. Verified live on 2026-09-02: `last_page` 116
  /// and page 116 returns SF-10000014, dated 2025-07-05.
  ///
  /// Both reads are `per_page=1`, so this costs two rows however long the
  /// history is — and it is read once, by a provider that caches it, to build a
  /// list of year chips.
  ///
  /// Nulls rather than guesses on an empty history: a customer with no orders
  /// should be offered no years, not the current one.
  Future<int?> firstOrderYear() async {
    final probe = await orders(perPage: 1);
    if (probe.items.isEmpty) return null;

    final lastPage = probe.meta.lastPage;
    if (lastPage <= 1) return probe.items.first.createdAt?.toLocal().year;

    final oldest = await orders(perPage: 1, page: lastPage);
    if (oldest.items.isEmpty) return probe.items.first.createdAt?.toLocal().year;
    return oldest.items.first.createdAt?.toLocal().year;
  }

    Future<PaginatedResponse<Order>> orders({
    int page = 1,
    int perPage = _defaultPerPage,
    String? status,
    String? shippingStatus,
    String? paymentStatus,
    DateRange? dateRange,
    String query = '',
  }) async {
    final search = query.trim();
    // A date span the server can honour, or none — and nothing to search for.
    // `GET /orders` has no search parameter either: `search`, `keyword`, `code`
    // and `q` were all tried live and all four returned the full history,
    // unfiltered and un-rejected. So a query forces the same local pass a date
    // span does.
    if (search.isEmpty && (dateRange == null || serverFiltersByDate)) {
      final res = await _api.get(
        ApiEndpoints.orders,
        query: {
          'page': page < 1 ? 1 : page,
          'per_page': _safePerPage(perPage),
          if (status != null && status.isNotEmpty) 'status': status,
          if (shippingStatus != null && shippingStatus.isNotEmpty)
            'shipping_status': shippingStatus,
          if (paymentStatus != null && paymentStatus.isNotEmpty)
            'payment_status': paymentStatus,
          if (dateRange != null) ...{
            'from_date': dateRange.startDay,
            'to_date': dateRange.endDay,
          },
        },
      );
      return PaginatedResponse.fromJson(asMap(res.data), Order.fromJson);
    }

    return _filteredLocally(
      dateRange: dateRange,
      query: search,
      status: status,
      shippingStatus: shippingStatus,
      paymentStatus: paymentStatus,
    );
  }

  /// The date filter, done here because the server will not do it.
  ///
  /// ## Why this cannot be "filter the page you already have"
  ///
  /// Filtering a 10-row page locally would leave the screen paging through the
  /// server's pagination while showing a different number of rows per page.
  /// `meta.total` would count orders the customer cannot see, `hasMore` would
  /// be about the unfiltered list, and a month with two orders spread over
  /// pages 3 and 7 would look empty until the customer scrolled to the bottom
  /// of their whole history.
  ///
  /// So a date filter reads the **entire** history and answers in one go:
  /// `hasMore: false`, and a `total` that counts what is actually on screen.
  /// That is affordable precisely here — the whole history is 94 rows and
  /// `per_page` is honoured up to at least 500 (`last_page: 1` at 100, 200 and
  /// 500 alike) — and it is affordable nowhere else, which is the argument for
  /// the backend patch.
  ///
  /// The server-side filters ride along untouched: status is still `?status=`,
  /// so this only ever adds work, never replaces a filter the server can do.
  Future<PaginatedResponse<Order>> _filteredLocally({
    required DateRange? dateRange,
    required String query,
    String? status,
    String? shippingStatus,
    String? paymentStatus,
  }) async {
    final matched = <Order>[];
    var page = 1;
    var exhausted = false;

    while (page <= _maxLocalFilterPages) {
      final res = await _api.get(
        ApiEndpoints.orders,
        query: {
          'page': page,
          'per_page': _maxPerPage,
          if (status != null && status.isNotEmpty) 'status': status,
          if (shippingStatus != null && shippingStatus.isNotEmpty)
            'shipping_status': shippingStatus,
          if (paymentStatus != null && paymentStatus.isNotEmpty)
            'payment_status': paymentStatus,
        },
      );
      final chunk = PaginatedResponse.fromJson(asMap(res.data), Order.fromJson);

      for (final order in chunk.items) {
        if (query.isNotEmpty && !order.matches(query)) continue;
        if (dateRange != null) {
          final placed = order.createdAt;
          // An order with no date cannot be judged, so it is left out rather
          // than shown under a range it may not belong to. `created_at` is
          // present on every row this API returns.
          if (placed == null || !dateRange.contains(placed)) continue;
        }
        matched.add(order);
      }

      if (!chunk.hasMore) {
        exhausted = true;
        break;
      }
      page++;
    }

    if (!exhausted) {
      // Not shown to the customer — the rows on screen are real, just possibly
      // not all of them — but a developer needs to know the guard fired,
      // because it means the local filter has outgrown the account it was
      // sized for and the backend patch is now required rather than nice.
      ErrorLog.capture(
        ApiException.local(
          'Order history is longer than the local date filter can walk.',
          developerDetail:
              'Stopped after $_maxLocalFilterPages pages of $_maxPerPage while '
              'filtering ${dateRange?.startDay ?? '-'}..${dateRange?.endDay ?? '-'} '
              'query="$query". Results may be incomplete. Ship '
              'from_date/to_date server-side and flip '
              'OrderRepository.serverFiltersByDate — see '
              'docs/BACKEND_PATCH_order_date_filter.md.',
        ),
        context: 'orders.dateFilter.truncated',
      );
    }

    return PaginatedResponse(
      items: matched,
      // Everything that matched is already here, so there is no next page to
      // offer and the count is of what the customer is looking at — not of the
      // unfiltered history behind it.
      meta: PaginationMeta(
        currentPage: 1,
        lastPage: 1,
        perPage: matched.length,
        total: matched.length,
      ),
    );
  }

  /// Full order with line items and the capability flags.
  ///
  /// A list row cannot answer "what did I buy" or "can I cancel this" — those
  /// keys only exist here. Call it when the detail screen opens, not before.
  ///
  /// Throws [ApiException] with `kind: notFound` for an id that is not this
  /// customer's or is not finished; the server's message for that case is
  /// Laravel's raw "No query results for model [...]", which ApiException
  /// already suppresses as developer-facing.
  Future<Order> order(int id) async {
    final res = await _api.get(ApiEndpoints.order(id));
    return _requireObject(res.data, Order.fromJson, 'order $id');
  }

  /// Cancel an order.
  ///
  /// [reason] must be one of the shop's *customer-visible* cancellation tokens
  /// (`change-mind`, `found-better-price`, `out-of-stock`, `shipping-delays`,
  /// `incorrect-address`, `not-as-described`, `payment-issues`,
  /// `unforeseen-circumstances`, `technical-issues`, `other`). The allowed set
  /// is admin-managed in `ec_order_reasons` and there is NO endpoint exposing
  /// it, so the app either ships this list or lets the 422 speak.
  ///
  /// [description] is required when [reason] is `other` (min 3, max 255) and
  /// optional otherwise.
  ///
  /// Refusals arrive as a businessRule [ApiException] ("You cannot cancel this
  /// order"); gate the button on [Order.canBeCanceled] from the detail call.
  Future<void> cancelOrder(
    int id, {
    required String reason,
    String? description,
  }) async {
    await _api.post(
      ApiEndpoints.cancelOrder(id),
      data: {
        'cancellation_reason': reason,
        if (description != null && description.isNotEmpty)
          'cancellation_reason_description': description,
      },
    );
  }

  /// Mark a delivered order as received.
  ///
  /// Gated server-side on the *shipment's* `can_confirm_delivery`, surfaced as
  /// [Order.canConfirmDelivery] on the detail response only.
  Future<void> confirmDelivery(int id) =>
      _api.post(ApiEndpoints.confirmDelivery(id));

  /// URL of the order invoice.
  ///
  /// Returns a link to a server-rendered page rather than the file itself —
  /// `{"data": {"url": "https://…/customer/invoices/75/generate-invoice"}}`.
  /// [forPrint] appends `?type=print` to the same URL.
  ///
  /// 404s when the order has no invoice (every canceled order), and that
  /// response carries an EMPTY message, so the thrown [ApiException] falls back
  /// to its own "Not found" wording. Check [Order.isInvoiceAvailable] first.
  ///
  /// ⚠ **This URL cannot be opened by the app.** It points at
  /// `customer.invoices.generate_invoice`, a web route whose middleware is
  /// `web, core, customer` — a **session** guard. A mobile client has no session
  /// cookie, so the link answers a bearer-token request with a redirect to the
  /// storefront login page. It is kept for a future WebView that holds a real
  /// web session; for showing a customer their invoice, use [downloadInvoice].
  Future<String> invoiceUrl(int id, {bool forPrint = false}) async {
    final res = await _api.get(
      ApiEndpoints.orderInvoice(id),
      query: {if (forPrint) 'type': 'print'},
    );
    final url = asStringOrNull(asMap(asMap(res.data)['data'])['url']);
    if (url == null) {
      throw ApiException.local(
        'The invoice is not available for this order.',
        developerDetail: 'GET ${ApiEndpoints.orderInvoice(id)} returned no url',
      );
    }
    return url;
  }

  /// The invoice PDF itself, as bytes.
  ///
  /// This is the **only** invoice route a mobile client can use — see
  /// [invoiceUrl] for why the other one cannot. The body is raw PDF, not JSON,
  /// not base64 and not a link.
  ///
  /// A 404 is *routine*, not a fault: `Order::isInvoiceAvailable()` requires an
  /// `ec_invoices` row, a non-canceled order, and (when the setting is on) a
  /// confirmed order. Cancelled orders never have one. Gate the button on
  /// [Order.isInvoiceAvailable] and treat a 404 as "no invoice", never as an
  /// error state.
  ///
  /// The invoice code is **unrelated to the order** — order 131 / `SF10000131`
  /// is invoice `INV-97` — so the filename comes from the server's
  /// `Content-Disposition` rather than being composed here.
  Future<InvoicePdf> downloadInvoice(int id, {bool forPreview = false}) async {
    final res = await _api.getBytes(
      ApiEndpoints.orderInvoiceDownload(id),
      query: {if (forPreview) 'type': 'print'},
    );

    final data = res.data;
    if (data is! List<int> || data.isEmpty) {
      throw ApiException.local(
        'The invoice could not be downloaded. Please try again.',
        developerDetail:
            'GET ${ApiEndpoints.orderInvoiceDownload(id)} returned '
            '${data.runtimeType} rather than PDF bytes',
      );
    }

    return InvoicePdf(
      bytes: Uint8List.fromList(data),
      fileName: _invoiceFileName(res.headers.value('content-disposition'), id),
    );
  }

  /// Pulls the filename out of `Content-Disposition`, e.g.
  /// `attachment; filename=invoice-INV-97.pdf`.
  ///
  /// Falls back to the order id, which is honest — the app genuinely does not
  /// know the invoice code — rather than inventing an `INV-` number from it.
  static String _invoiceFileName(String? disposition, int orderId) {
    final fallback = 'invoice-order-$orderId.pdf';
    final header = disposition ?? '';

    // Matches both `filename=x.pdf` and the RFC 5987 `filename*=UTF-8''x.pdf`.
    // Deliberately not one clever pattern: the encoded form's `''` is awkward
    // to express inside a Dart string, and stripping it afterwards is plainer
    // to read than escaping it.
    final match = RegExp(
      'filename[^=]*=([^;]+)',
      caseSensitive: false,
    ).firstMatch(header);
    if (match == null) return fallback;

    var name = match.group(1)!.trim().replaceAll('"', '');
    final encoded = name.indexOf("''");
    if (encoded >= 0) name = name.substring(encoded + 2);

    name = Uri.decodeComponent(name).trim();
    // A path separator here would let the server choose where the file lands.
    name = name.split(RegExp(r'[/\\]')).last;

    return name.isEmpty ? fallback : name;
  }

  // =========================================================================
  // Returns
  // =========================================================================

  /// The customer's return requests, newest first. Hybrid envelope again.
  ///
  /// Unlike orders, each row already includes its [OrderReturn.items], so a
  /// returns list never needs a follow-up detail call.
  Future<PaginatedResponse<OrderReturn>> returns({
    int page = 1,
    int perPage = _defaultPerPage,
  }) async {
    final res = await _api.get(
      ApiEndpoints.orderReturns,
      query: {
        'page': page < 1 ? 1 : page,
        'per_page': _safePerPage(perPage),
      },
    );
    return PaginatedResponse.fromJson(asMap(res.data), OrderReturn.fromJson);
  }

  /// A single return request.
  ///
  /// The route is constrained to a numeric id, so a non-numeric one is a
  /// routing 404 ("The route … could not be found") rather than a model 404.
  Future<OrderReturn> orderReturn(int id) async {
    final res = await _api.get(ApiEndpoints.orderReturn(id));
    return _requireObject(res.data, OrderReturn.fromJson, 'return $id');
  }

  /// What may be returned from an order, and why.
  ///
  /// Call this before showing the return form: it is the only source of the
  /// reason list the server will accept right now (the set is admin-managed),
  /// and of `order_item_id` values for the submission.
  ///
  /// When the order is not eligible the server answers HTTP 200 with
  /// `error: true`, so this throws a businessRule [ApiException] whose message
  /// is the generic "You cannot return this order". The specific hint —
  /// "Order must be in completed status…", "A return request has already been
  /// submitted for this order.", "The return window for this order has
  /// expired." — travels in `data.reason`, which ApiClient discards on its way
  /// to the exception. [eligibilityHint] recovers it from the exception's
  /// developer detail so the customer can be told which one it was.
  Future<ReturnEligibility> returnEligibility(int orderId) async {
    final res = await _api.get(ApiEndpoints.returnsForOrder(orderId));
    return _requireObject(
      res.data,
      ReturnEligibility.fromJson,
      'return eligibility $orderId',
    );
  }

  /// Pulls the `data.reason` sentence out of a refusal thrown by
  /// [returnEligibility]. Returns null when the exception is anything else.
  ///
  /// This reads the body preview ApiException keeps for logs, because that is
  /// the only place the structured payload survives. The clean fix is for
  /// ApiException to retain the parsed body — noted as a follow-up rather than
  /// done here, since that file belongs to another slice.
  static String? eligibilityHint(ApiException error) {
    if (error.kind != ApiErrorKind.businessRule) return null;
    final detail = error.developerDetail;
    if (detail == null) return null;
    final match = RegExp(r'"reason"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(detail);
    return match?.group(1)?.replaceAll(r'\/', '/').replaceAll(r'\"', '"');
  }

  /// Submit a return request.
  ///
  /// ⚠ NOT executed against the live backend — the client's dev account had no
  /// order eligible for return, and creating one would have left real data
  /// behind. The body shape comes from `OrderReturnRequest` in the backend plus
  /// the 24 captured 422 responses, and every rule those exercise is mirrored
  /// in [ReturnDraft]. Treat the success path as unverified.
  ///
  /// Known rejections, all HTTP 422 with a Laravel `errors` bag:
  ///   * `order_id` — "Same Order ID already exists in a previous return
  ///     request." One return per order, ever. There is no way to amend an
  ///     existing one except [resubmitReturn].
  ///   * `customer_comment` — 50 character minimum, 2000 maximum.
  ///   * `return_items.N.reason` — "The selected return reason is not allowed."
  ///     when the token is not in the shop's current list.
  ///
  /// Upload media first with [uploadReturnMedia]; this route takes URLs only.
  Future<OrderReturn> submitReturn(ReturnDraft draft) async {
    final res = await _api.post(ApiEndpoints.orderReturns, data: draft.toJson());
    return _requireObject(res.data, OrderReturn.fromJson, 'submitted return');
  }

  /// Resubmit a return the admin bounced back.
  ///
  /// ⚠ NOT executed live, for the same reason as [submitReturn]. Allowed only
  /// while [OrderReturn.canResubmit] is true — at most 3 submissions total.
  Future<OrderReturn> resubmitReturn(int id, ReturnResubmitDraft draft) async {
    final res =
        await _api.post(ApiEndpoints.resubmitReturn(id), data: draft.toJson());
    return _requireObject(res.data, OrderReturn.fromJson, 'resubmitted return');
  }

  /// Upload return evidence and get back storage URLs to put in a
  /// [ReturnDraft].
  ///
  /// ⚠ The success path has NOT been executed live, but the request encoding
  /// has been pinned down from the captured 422s: the controller reads
  /// `$request->file('files')`, which only exists on a **multipart** body, and
  /// `returns/u02_files_arrstr.json` proves a JSON array is rejected with
  /// "The files.0 must be a file.". So this must be a [FormData] with repeated
  /// `files[]` keys — PHP only folds a bracketed key into an array — exactly
  /// like `ReviewRepository.create`.
  ///
  /// Server rules, from the same captured 422s:
  ///   files    required, array, 1–10 entries
  ///   files.*  image -> jpg/jpeg/png/webp, max 5 MB
  ///           video -> mp4/mov/avi/webm,  max 50 MB
  ///   type     "image" | "video"; anything else is a 200 + `error: true`
  ///
  /// [filePaths] are on-device paths, as returned by image_picker. Count is
  /// checked here so a 10-file limit is not learned after uploading 11 videos.
  Future<List<String>> uploadReturnMedia({
    required List<String> filePaths,
    bool isVideo = false,
  }) async {
    if (filePaths.isEmpty) {
      throw ApiException.local(
        'Please choose at least one file to upload.',
        developerDetail: 'uploadReturnMedia called with no paths',
      );
    }
    if (filePaths.length > maxUploadFiles) {
      throw ApiException.local(
        'You can upload at most $maxUploadFiles files at a time.',
        developerDetail: 'uploadReturnMedia called with ${filePaths.length} paths',
      );
    }

    final FormData body;
    try {
      // `MultipartFile.fromFile` stats the path and throws a raw
      // FileSystemException when it is gone — a picker temp file the OS
      // reclaimed. Every other exit from this repository is an ApiException, so
      // letting that escape would break `on ApiException` handlers.
      body = FormData.fromMap({
        'type': isVideo ? 'video' : 'image',
        'files[]': [
          for (final path in filePaths) await MultipartFile.fromFile(path),
        ],
      });
    } on Object catch (e) {
      throw ApiException.local(
        "One of the attachments couldn't be read. Please pick it again.",
        developerDetail: 'MultipartFile.fromFile failed.\nfiles: $filePaths\n$e',
      );
    }

    final res = await _api.post(ApiEndpoints.orderReturnUploadMedia, data: body);
    return asStringList(asMap(asMap(res.data)['data'])['urls']);
  }

  /// Server-side `max:10` on `files`.
  static const int maxUploadFiles = 10;

  // =========================================================================

  /// `per_page=-5` is a **HTTP 500**, not a 422 — Laravel's paginator rejects a
  /// negative page size and the exception escapes. 0 and non-numeric values are
  /// harmless (both fall back to 15), but the negative case has to be stopped
  /// client-side.
  static int _safePerPage(int requested) {
    if (requested < 1) return _defaultPerPage;
    return requested > _maxPerPage ? _maxPerPage : requested;
  }

  /// Unwraps `{data: {...}}` and refuses to invent an empty object when the
  /// server sent something unusable.
  static T _requireObject<T>(
    dynamic body,
    T Function(Map<String, dynamic>) fromJson,
    String what,
  ) {
    final parsed = unwrapObject(body, fromJson);
    if (parsed == null) {
      throw ApiException.local(
        "Couldn't read the $what from the server.",
        developerDetail: 'unexpected body: $body',
      );
    }
    return parsed;
  }
}

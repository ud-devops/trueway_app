import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_palette.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_response.dart';
import 'package:trueway_farms/core/utils/date_range.dart';
import 'package:trueway_farms/data/models/order.dart';
import 'package:trueway_farms/data/models/order_return.dart';
import 'package:trueway_farms/data/repositories/order_repository.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/order_provider.dart';
import 'package:trueway_farms/presentation/screens/orders/order_detail_screen.dart';
import 'package:trueway_farms/presentation/screens/orders/orders_screen.dart';
import 'package:trueway_farms/presentation/widgets/app_network_image.dart';
import 'package:trueway_farms/presentation/widgets/skeletons.dart';
import 'package:trueway_farms/presentation/widgets/state_views.dart';

/// Orders slice: history list, order detail (with its two destructive-ish
/// actions). Guest tracking was removed from the product.
///
/// Nothing here touches the network — [_FakeOrderRepository] stands in through
/// `orderRepositoryProvider`, and the auth status is overridden through
/// `ordersAuthStatusProvider` so no [AuthNotifier] (and therefore no ApiClient
/// session restore) is ever built.

// ---------------------------------------------------------------------------
// Fixtures — rows copied from captured
// GET /ecommerce/orders and GET /ecommerce/orders/277 responses.
// ---------------------------------------------------------------------------

/// The modern code format (id >= 61): no '#', no dash.
Map<String, dynamic> _listRow({
  int id = 277,
  String code = 'SF10000277',
  String statusValue = 'processing',
  String statusLabel = 'Processing',
  Map<String, dynamic>? shippingStatus,
  int productsCount = 1,
  // Empty by default so `pumpAndSettle` can be used: a real thumbnail leaves
  // CachedNetworkImage spinning forever under the test binding. 9 of the
  // account's 90 rows genuinely have no images, so this is a real shape — the
  // thumbnail strip gets its own pump-only test below.
  List<String> images = const [],
}) =>
    {
      'id': id,
      'code': code,
      'status': {'value': statusValue, 'label': statusLabel},
      // Dead on every captured row — must never be rendered.
      'status_html': <String, dynamic>{},
      'customer': {'name': 'Suraj ojha', 'email': 'suraj.ojha@uminber.in'},
      'created_at': '2026-07-16T17:04:00+05:30',
      // Amounts are 2dp STRINGS with a formatted twin.
      'amount': '1274.15',
      'amount_formatted': '₹1,274.15',
      'tax_amount': '44.95',
      'tax_amount_formatted': '₹44.95',
      'shipping_amount': '330.20',
      'shipping_amount_formatted': '₹330.20',
      'shipping_method': {'value': 'shiprocket', 'label': 'ShipRocket'},
      'shipping_status':
          shippingStatus ?? {'value': 'approved', 'label': 'Approved'},
      'payment_method': {'value': 'razorpay', 'label': 'Razorpay'},
      'payment_status': {'value': 'completed', 'label': 'Completed'},
      'products_count': productsCount,
      'product_image': images.isEmpty ? null : images.first,
      'product_images': images,
    };

/// The legacy format (id <= 57): the '#' AND the dash are stored in the column.
/// 25 of the account's 90 orders look like this.
final _legacy = Order.fromJson(_listRow(
  id: 16,
  code: '#SF-10000016',
  statusValue: 'canceled',
  statusLabel: 'Canceled',
  // 7 of 90 orders have no shipment row at all.
  shippingStatus: {'value': null, 'label': ''},
  productsCount: 3,
  images: const [],
),);

final _modern = Order.fromJson(_listRow());

/// A row that does carry thumbnails, as 81 of the 90 do.
final _withThumbs = Order.fromJson(_listRow(
  id: 275,
  code: 'SF10000275',
  productsCount: 2,
  images: const [
    'https://dev.truewayerp.com/storage/map-location-150x150.png',
    'https://dev.truewayerp.com/storage/products/dals/61a1sdxqijl.jpg',
  ],
),);

/// Detail shape: adds products[], discount_amount and the capability flags.
Map<String, dynamic> _detailRow({
  bool canCancel = true,
  bool canConfirm = false,
  String statusValue = 'processing',
  String statusLabel = 'Processing',
  Map<String, dynamic>? shippingStatus,
}) =>
    {
      ..._listRow(
        statusValue: statusValue,
        statusLabel: statusLabel,
        shippingStatus: shippingStatus,
      ),
      // The detail route drops product_images and adds the lines.
      'product_images': <String>[],
      // `sub_total` and `payment_fee` are serialized by this backend as of
      // 2026-08-04 and are what let the bill draw rows that sum:
      // 899.00 + 44.95 + 330.20 + 0.00 = 1274.15 = amount.
      //
      // A server that predates them is a real shape the app must still handle,
      // and it has its own coverage — see the un-upgraded-server case in
      // test/presentation/order_bill_test.dart, which is built from the live
      // order 14 capture rather than from this hand-written row.
      'sub_total': '899.00',
      'sub_total_formatted': '₹899.00',
      'payment_fee': '0.00',
      'payment_fee_formatted': '₹0.00',
      'discount_amount': '0.00',
      'discount_amount_formatted': '₹0.00',
      'coupon_code': null,
      'can_be_canceled': canCancel,
      'can_confirm_delivery': canConfirm,
      'can_be_returned': false,
      'is_invoice_available': true,
      'products': [
        {
          'id': 386,
          'product_id': 118,
          'product_name': 'Trueway Farms Organic Desi Khand Brown &amp; Jaggery',
          'product_image': '',
          'sku': 'TRW3215',
          'amount': '899.00',
          'amount_formatted': '₹899.00',
          'quantity': 1,
          'total': 899,
          'total_formatted': '₹899.00',
          'options': {'sku': 'TRW3215', 'attributes': '', 'weight': 5100},
        },
      ],
      'shipping_info': {
        'name': 'Suraj ojha',
        'phone': '8305317276',
        'address': '306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad',
        // Opaque geo ids — must never reach the screen.
        'city': '574',
        'state': '11',
        'country': 'India',
        'zip_code': '382415',
      },
      'billing_info': {
        'name': null,
        'phone': null,
        'address': null,
        'city': null,
        'state': null,
        'country': null,
        'zip_code': null,
      },
    };

/// Implements the interface rather than subclassing, so no ApiClient — and
/// therefore no Dio and no socket — is ever constructed.
class _FakeOrderRepository implements OrderRepository {
  _FakeOrderRepository({
    this.pages = const [],
    this.detail,
    this.listError,
    this.detailError,
    this.writeError,
    this.delay,
    this.returnRows = const [],
  });

  /// The customer's return requests, which the order screens read through
  /// `orderReturnsByOrderProvider` and index by `order_id`.
  final List<OrderReturn> returnRows;

  @override
  Future<PaginatedResponse<OrderReturn>> returns({
    int page = 1,
    int perPage = 10,
  }) async =>
      PaginatedResponse<OrderReturn>(
        items: returnRows,
        meta: PaginationMeta(
          currentPage: 1,
          lastPage: 1,
          perPage: returnRows.length,
          total: returnRows.length,
        ),
      );

  /// One entry per page, in order. Page N reads `pages[N - 1]`.
  final List<List<Order>> pages;
  final Order? detail;

  ApiException? listError;
  final ApiException? detailError;
  final ApiException? writeError;
  final Duration? delay;

  int reads = 0;
  final List<int> pagesRequested = [];

  /// Every `dateRange` the notifier asked for, null included. The real
  /// repository decides how to honour one — locally today, server-side once
  /// `from_date`/`to_date` land — so what a screen test can check is that the
  /// span reached it at all.
  final List<DateRange?> rangesRequested = [];

  /// Every free-text query the notifier asked for. Client-side, because
  /// `GET /orders` has no search parameter — `search`, `keyword`, `code` and
  /// `q` were all tried live and all four returned the full history.
  final List<String> queriesRequested = [];

  /// The status pair each read carried. "Refunded" is a *payment* status, so
  /// the two travel separately.
  final List<({String? status, String? paymentStatus})> bucketsRequested = [];

  int detailReads = 0;
  final List<({String reason, String? description})> canceled = [];
  final List<int> confirmed = [];

  @override
  Future<PaginatedResponse<Order>> orders({
    int page = 1,
    int perPage = 10,
    String? status,
    String? shippingStatus,
    String? paymentStatus,
    DateRange? dateRange,
    String query = '',
  }) async {
    reads++;
    pagesRequested.add(page);
    rangesRequested.add(dateRange);
    queriesRequested.add(query);
    bucketsRequested.add((status: status, paymentStatus: paymentStatus));
    if (delay != null) await Future<void>.delayed(delay!);
    if (listError != null) throw listError!;

    // Stands in for the real repository's local pass: a filtered read is
    // complete in one go, so it reports `hasMore: false` and a total of what
    // it matched — the screen's paging and its "N orders" line both key off
    // that.
    if (dateRange != null || query.trim().isNotEmpty) {
      final matched = [
        for (final page in pages)
          for (final order in page)
            if ((dateRange == null ||
                    (order.createdAt != null &&
                        dateRange.contains(order.createdAt!))) &&
                order.matches(query))
              order,
      ];
      return PaginatedResponse<Order>(
        items: matched,
        meta: PaginationMeta(
          currentPage: 1,
          lastPage: 1,
          perPage: matched.length,
          total: matched.length,
        ),
      );
    }

    final items = page <= pages.length ? pages[page - 1] : const <Order>[];
    return PaginatedResponse<Order>(
      items: items,
      meta: PaginationMeta(
        currentPage: page,
        lastPage: pages.isEmpty ? 1 : pages.length,
        perPage: perPage,
        total: pages.fold<int>(0, (sum, p) => sum + p.length),
      ),
    );
  }

  /// Holds a detail read open until the test releases it — deterministic where
  /// [delay] would be a race against the RefreshIndicator's own animation.
  Completer<void>? gate;

  @override
  Future<Order> order(int id) async {
    detailReads++;
    if (gate != null) await gate!.future;
    if (delay != null) await Future<void>.delayed(delay!);
    if (detailError != null) throw detailError!;
    return detail!;
  }

  @override
  Future<void> cancelOrder(
    int id, {
    required String reason,
    String? description,
  }) async {
    canceled.add((reason: reason, description: description));
    if (writeError != null) throw writeError!;
  }

  @override
  Future<void> confirmDelivery(int id) async {
    confirmed.add(id);
    if (writeError != null) throw writeError!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

Future<Widget> _wrap(
  Widget child, {
  required _FakeOrderRepository repo,
  AuthStatus status = AuthStatus.authenticated,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      orderRepositoryProvider.overrideWithValue(repo),
      ordersAuthStatusProvider.overrideWithValue(status),
    ],
    child: MaterialApp(theme: AppTheme.light, home: child),
  );
}

/// A tall surface so the whole list is laid out — off-screen items are never
/// built, and a finder cannot reach a row that does not exist.
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The vertical order list.
///
/// Keyed rather than `find.byType(ListView)`: the date-filter chip row above it
/// is a horizontal ListView, so a bare type finder matches two widgets and
/// `drag()` refuses to guess.
Finder get _ordersList => find.byKey(const Key('orders-list'));

void _usePhoneSurface(WidgetTester tester, {double width = 400}) {
  tester.view.physicalSize = Size(width, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Lets a SnackBar's timer elapse — `testWidgets` fails on a pending timer.
Future<void> _settleSnack(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

Finder _row(int id) => find.byKey(ValueKey('order-$id'));

/// WCAG relative-contrast ratio between two opaque colours.
double _contrastRatio(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return x > y ? (x + 0.05) / (y + 0.05) : (y + 0.05) / (x + 0.05);
}

void main() {
  // -------------------------------------------------------------------------
  // The list — four states
  // -------------------------------------------------------------------------

  testWidgets('shows skeletons while the first page is in flight',
      (tester) async {
    final repo = _FakeOrderRepository(
      pages: [
        [_modern],
      ],
      delay: const Duration(milliseconds: 50),
    );
    await tester.pumpWidget(await _wrap(const OrdersScreen(), repo: repo));
    await tester.pump();

    expect(find.byType(SkeletonBox), findsWidgets);
    expect(_row(277), findsNothing);

    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(SkeletonBox), findsNothing);
    expect(_row(277), findsOneWidget);
  });

  testWidgets('a failed first page shows a retryable error that re-requests',
      (tester) async {
    final repo = _FakeOrderRepository(
      listError: ApiException.local('No internet connection'),
    );
    await tester.pumpWidget(await _wrap(const OrdersScreen(), repo: repo));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.textContaining('No internet connection'), findsOneWidget);
    expect(repo.reads, 1);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(repo.reads, 2);
    // Still failing, so the view stays rather than silently emptying.
    expect(find.byType(AppErrorView), findsOneWidget);
  });

  testWidgets('an account with no orders says so, and never hardcodes it',
      (tester) async {
    final repo = _FakeOrderRepository();
    await tester.pumpWidget(await _wrap(const OrdersScreen(), repo: repo));
    await tester.pumpAndSettle();

    expect(find.byType(EmptyView), findsOneWidget);
    expect(find.text('No orders yet'), findsOneWidget);
    // The old screen showed this to everyone; it may only appear after a read.
    expect(repo.reads, 1);
  });

  testWidgets('signed out, the list asks for a sign-in instead of reading',
      (tester) async {
    final repo = _FakeOrderRepository(pages: [
      [_modern],
    ],);
    await tester.pumpWidget(
      await _wrap(const OrdersScreen(),
          repo: repo, status: AuthStatus.signedOut,),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign in to see your orders'), findsOneWidget);
    expect(repo.reads, 0);
    // Guest tracking was removed from the product: there is no way into this
    // app's order history without a session, so signing in is the only action
    // offered here.
    expect(find.textContaining('Track an order'), findsNothing);
  });

  testWidgets('while auth is still resolving nothing claims to be signed out',
      (tester) async {
    final repo = _FakeOrderRepository();
    await tester.pumpWidget(
      await _wrap(const OrdersScreen(), repo: repo, status: AuthStatus.unknown),
    );
    await tester.pump();

    expect(find.text('Sign in to see your orders'), findsNothing);
    expect(find.byType(SkeletonBox), findsWidgets);
    expect(repo.reads, 0);
  });

  testWidgets('a populated list renders a row per order', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeOrderRepository(pages: [
      [_modern, _legacy],
    ],);
    await tester.pumpWidget(await _wrap(const OrdersScreen(), repo: repo));
    await tester.pumpAndSettle();

    expect(_row(277), findsOneWidget);
    expect(_row(16), findsOneWidget);

    // The server's own formatted total, not a recomputed one.
    expect(find.text('₹1,274.15'), findsNWidgets(2));
    // Status labels, not values.
    expect(find.text('Processing'), findsOneWidget);
    expect(find.text('Canceled'), findsOneWidget);
    expect(find.text('processing'), findsNothing);
    // products_count off the list row — no detail call is made for it.
    expect(find.text('1 item'), findsOneWidget);
    expect(find.text('3 items'), findsOneWidget);
    expect(repo.detailReads, 0);
  });

  // pump-only: a real thumbnail URL keeps CachedNetworkImage's placeholder
  // spinning under the test binding, so pumpAndSettle would never return.
  testWidgets('a row shows the thumbnails its list payload carries',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeOrderRepository(pages: [
      [_withThumbs, _modern],
    ],);
    await tester.pumpWidget(await _wrap(const OrdersScreen(), repo: repo));
    await tester.pump();
    await tester.pump();

    expect(_row(275), findsOneWidget);
    // Two images on that row; the row with none renders no image well at all,
    // so the strip degrades to the item count rather than a broken box.
    expect(
      find.descendant(of: _row(275), matching: find.byType(AppNetworkImage)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: _row(277), matching: find.byType(AppNetworkImage)),
      findsNothing,
    );
    expect(find.text('2 items'), findsOneWidget);
  });

  testWidgets('both stored code formats render exactly once, never "##"',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeOrderRepository(pages: [
      [_modern, _legacy],
    ],);
    await tester.pumpWidget(await _wrap(const OrdersScreen(), repo: repo));
    await tester.pumpAndSettle();

    expect(find.text('SF10000277'), findsOneWidget);
    // The legacy row stores "#SF-10000016"; the '#' is stripped for display and
    // must not be re-added — "##SF-10000016" is the bug this guards.
    expect(find.text('SF-10000016'), findsOneWidget);
    expect(find.text('#SF-10000016'), findsNothing);
    expect(find.text('##SF-10000016'), findsNothing);
  });

  testWidgets('an empty shipping status renders nothing, not "null"',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeOrderRepository(pages: [
      [_modern, _legacy],
    ],);
    await tester.pumpWidget(await _wrap(const OrdersScreen(), repo: repo));
    await tester.pumpAndSettle();

    // {value: "approved"} is shown...
    expect(
      find.descendant(of: _row(277), matching: find.text('Approved')),
      findsOneWidget,
    );
    // ...and {value: null, label: ""} produces no line at all.
    expect(find.text('null'), findsNothing);
    expect(
      find.descendant(
        of: _row(16),
        matching: find.byIcon(Icons.local_shipping_rounded),
      ),
      findsNothing,
    );
  });

  testWidgets('scrolling to the end pages in the next set of orders',
      (tester) async {
    _usePhoneSurface(tester);
    // A full page, so the list actually overflows the viewport — a list that
    // fits has no scroll extent and could never page.
    final page1 = [
      for (var i = 0; i < 6; i++)
        Order.fromJson(_listRow(id: 300 + i, code: 'SF1000${300 + i}')),
    ];
    final repo = _FakeOrderRepository(pages: [page1, [_legacy]]);
    await tester.pumpWidget(await _wrap(const OrdersScreen(), repo: repo));
    await tester.pumpAndSettle();

    expect(_row(300), findsOneWidget);
    expect(_row(16), findsNothing);
    expect(repo.pagesRequested, [1]);

    await tester.drag(_ordersList, const Offset(0, -800));
    await tester.pumpAndSettle();

    expect(repo.pagesRequested, [1, 2]);
    // The second page is appended, not swapped in.
    await tester.drag(_ordersList, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(_row(16), findsOneWidget);
    expect(find.text('All 7 orders shown'), findsOneWidget);
  });

  // Every order timestamp carries a zone, and DateTime.parse turns both stored
  // formats into a UTC DateTime. Formatting that straight printed the UTC
  // fields: an order placed at 5:04 PM IST read "11:34 AM", and anything placed
  // before 05:30 IST read as the previous day.
  testWidgets('a date is rendered in the reader zone, not UTC', (tester) async {
    _useTallSurface(tester);
    final placed = DateTime.parse('2026-07-16T17:04:00+05:30');
    expect(placed.isUtc, isTrue, reason: 'the premise of this test');

    // The detail header is the one that prints a clock time.
    final repo = _FakeOrderRepository(detail: Order.fromJson(_detailRow()));
    await tester.pumpWidget(
      await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
    );
    await tester.pumpAndSettle();

    final local = DateFormat('d MMM yyyy, h:mm a').format(placed.toLocal());
    expect(find.text('Placed $local'), findsOneWidget);

    // The regression guard proper: on any machine that is not on UTC, the UTC
    // rendering of the same instant must not be what reached the screen.
    if (DateTime.now().timeZoneOffset != Duration.zero) {
      final utc = DateFormat('d MMM yyyy, h:mm a').format(placed);
      expect(find.text('Placed $utc'), findsNothing);
    }
  });

  testWidgets('a failed refresh keeps the rows and admits the failure',
      (tester) async {
    _usePhoneSurface(tester);
    final repo = _FakeOrderRepository(pages: [
      [_modern],
    ],);
    await tester.pumpWidget(await _wrap(const OrdersScreen(), repo: repo));
    await tester.pumpAndSettle();
    expect(_row(277), findsOneWidget);

    repo.listError = ApiException.local('Gateway timeout');
    await tester.drag(_ordersList, const Offset(0, 400),
        touchSlopY: 0,);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    // The read failed; the order did not vanish.
    expect(_row(277), findsOneWidget);
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.textContaining('Gateway timeout'), findsWidgets);
  });

  // A page that fails must not be re-requested by the scroll listener, which
  // fires on every frame of the bounce at the bottom of the list: that turned
  // one dead endpoint into a request per frame, and flickered the error strip
  // away and back as each attempt cleared and re-set it.
  testWidgets('a failed page stops the automatic paging until Retry',
      (tester) async {
    _usePhoneSurface(tester);
    final page1 = [
      for (var i = 0; i < 6; i++)
        Order.fromJson(_listRow(id: 300 + i, code: 'SF1000${300 + i}')),
    ];
    final repo = _FakeOrderRepository(pages: [page1, [_legacy]]);
    await tester.pumpWidget(await _wrap(const OrdersScreen(), repo: repo));
    await tester.pumpAndSettle();

    repo.listError = ApiException.local('Gateway timeout');
    await tester.drag(_ordersList, const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(repo.pagesRequested, [1, 2]);
    expect(find.textContaining("Couldn't load more orders"), findsOneWidget);

    // Two more drags at the bottom: still one attempt at page 2.
    await tester.drag(_ordersList, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.drag(_ordersList, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(repo.pagesRequested, [1, 2]);

    // Retry is the way out, and it asks for the page that failed.
    repo.listError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(repo.pagesRequested, [1, 2, 2]);
    expect(_row(16), findsOneWidget);
  });

  // A failed pull-to-refresh is not a failed page: the rows are stale, not
  // partial. Reporting it as "couldn't load more" and retrying with loadMore
  // appended page 2 to the very rows the customer asked to have replaced.
  testWidgets('a failed refresh offers a refresh, not a next page',
      (tester) async {
    _usePhoneSurface(tester);
    final repo = _FakeOrderRepository(pages: [
      [_modern],
      [_legacy],
    ],);
    await tester.pumpWidget(await _wrap(const OrdersScreen(), repo: repo));
    await tester.pumpAndSettle();
    expect(repo.pagesRequested, [1]);

    repo.listError = ApiException.local('Gateway timeout');
    await tester.drag(_ordersList, const Offset(0, 400),
        touchSlopY: 0,);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't load the latest orders"),
        findsOneWidget,);
    expect(find.textContaining("Couldn't load more orders"), findsNothing);

    repo.listError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    // Page 1 again — not page 2 appended to rows that were never replaced.
    expect(repo.pagesRequested, [1, 1, 1]);
    expect(_row(16), findsNothing);
  });

  // -------------------------------------------------------------------------
  // Detail
  // -------------------------------------------------------------------------

  testWidgets('detail shows a skeleton, then the order', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeOrderRepository(
      detail: Order.fromJson(_detailRow()),
      delay: const Duration(milliseconds: 50),
    );
    await tester.pumpWidget(
      await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
    );
    await tester.pump();
    expect(find.byType(SkeletonBox), findsWidgets);

    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(SkeletonBox), findsNothing);
    expect(find.text('SF10000277'), findsWidgets);
    // HTML entities in the product name are decoded by the model.
    expect(
      find.textContaining('Desi Khand Brown & Jaggery'),
      findsOneWidget,
    );
  });

  testWidgets('a failed detail read is retryable', (tester) async {
    final repo = _FakeOrderRepository(
      detailError: ApiException.local('The server had a problem'),
    );
    await tester.pumpWidget(
      await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(repo.detailReads, 1);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(repo.detailReads, 2);
  });

  // `onRefresh: () async => ref.invalidate(...)` completed on the frame it was
  // called, so the spinner retracted while the re-read was still in flight —
  // the gesture claimed to have refreshed an order nobody had asked about yet.
  testWidgets('detail pull-to-refresh waits for the re-read', (tester) async {
    _usePhoneSurface(tester);
    final repo = _FakeOrderRepository(detail: Order.fromJson(_detailRow()));
    await tester.pumpWidget(
      await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
    );
    await tester.pumpAndSettle();
    expect(repo.detailReads, 1);

    // The next read hangs until this is completed.
    final gate = Completer<void>();
    repo.gate = gate;

    // The *detail* screen's list, not the history's — it has only one, and no
    // filter bar above it, so the type finder is unambiguous here.
    await tester.drag(find.byType(ListView), const Offset(0, 400),
        touchSlopY: 0,);
    await tester.pump();
    // A second of frames — far longer than the indicator's arm-and-dismiss
    // animation. `pumpAndSettle` cannot be used while a spinner is on screen:
    // an indeterminate indicator schedules a frame forever.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(repo.detailReads, 2);
    // Still in flight, so the spinner is still up. Invalidating without
    // awaiting retracted it here, mid-read.
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(find.text('SF10000277'), findsWidgets);
  });

  testWidgets('the bill shows only figures the server sent', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeOrderRepository(detail: Order.fromJson(_detailRow()));
    await tester.pumpWidget(
      await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(find.text('Item total'), findsOneWidget);
    expect(find.text('₹899.00'), findsWidgets);
    expect(find.text('₹330.20'), findsOneWidget);
    // GST carries a plus: this backend is tax-exclusive, so the row is an
    // addition and reads as one. Same as the cart's bill.
    expect(find.text('+ ₹44.95'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(find.text('₹1,274.15'), findsOneWidget);
    // discount_amount is "0.00" here, so no discount line is invented.
    expect(find.text('Discount'), findsNothing);
    // The opaque geo ids stored on the address never reach the screen.
    expect(find.text('574'), findsNothing);
    expect(find.textContaining('382415'), findsOneWidget);
    // billing_info is the all-nulls null-object on 82/90 orders.
    expect(find.text('Billed to the same address.'), findsOneWidget);
  });

  testWidgets('cancel asks first and sends nothing when kept', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeOrderRepository(detail: Order.fromJson(_detailRow()));
    await tester.pumpWidget(
      await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel order').first);
    await tester.pumpAndSettle();

    expect(find.text('Cancel this order?'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);

    await tester.tap(find.text('Keep order'));
    await tester.pumpAndSettle();
    expect(repo.canceled, isEmpty);
  });

  testWidgets('a confirmed cancel sends the chosen reason and re-reads',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeOrderRepository(detail: Order.fromJson(_detailRow()));
    await tester.pumpWidget(
      await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
    );
    await tester.pumpAndSettle();
    expect(repo.detailReads, 1);

    await tester.tap(find.text('Cancel order').first);
    await tester.pumpAndSettle();
    // Confirm from inside the dialog.
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Cancel order'),
      ),
    );
    await tester.pumpAndSettle();

    expect(repo.canceled, hasLength(1));
    // A token from the shop's list, not free text.
    expect(repo.canceled.single.reason, 'change-mind');
    expect(repo.canceled.single.description, isNull);
    // The status changed server-side, so the order is re-read.
    expect(repo.detailReads, 2);
    expect(find.textContaining('has been cancelled'), findsOneWidget);
    // The refund window is deliberately NOT in here. A SnackBar is four
    // seconds long; the sentence lives on the order itself, where the customer
    // can sit and read it — see the 'refund note on the order' group.
    expect(find.textContaining('business days'), findsNothing);

    await _settleSnack(tester);
  });

  testWidgets('a refused cancel never claims the order was cancelled',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeOrderRepository(
      detail: Order.fromJson(_detailRow()),
      // HTTP 200 + error:true is how this backend refuses.
      writeError: const ApiException(
        'You cannot cancel this order',
        kind: ApiErrorKind.businessRule,
        statusCode: 200,
        serverMessage: 'You cannot cancel this order',
      ),
    );
    await tester.pumpWidget(
      await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel order').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Cancel order'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('has been cancelled'), findsNothing);
    // The server's own sentence is shown verbatim.
    expect(find.text('You cannot cancel this order'), findsOneWidget);

    await _settleSnack(tester);
  });

  testWidgets('the actions the server has not offered are absent',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeOrderRepository(
      detail: Order.fromJson(_detailRow(canCancel: false)),
    );
    await tester.pumpWidget(
      await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cancel order'), findsNothing);
    expect(find.text('Confirm delivery'), findsNothing);
  });

  testWidgets('confirm delivery asks first, then posts', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeOrderRepository(
      detail: Order.fromJson(_detailRow(canCancel: false, canConfirm: true)),
    );
    await tester.pumpWidget(
      await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Confirm delivery'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm delivery?'), findsOneWidget);

    await tester.tap(find.text('Not yet'));
    await tester.pumpAndSettle();
    expect(repo.confirmed, isEmpty);

    await tester.tap(find.text('Confirm delivery'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes, received'));
    await tester.pumpAndSettle();

    expect(repo.confirmed, [277]);
    expect(find.textContaining('delivery confirmed'), findsOneWidget);

    await _settleSnack(tester);
  });


  // -------------------------------------------------------------------------
  // Layout on a real phone
  // -------------------------------------------------------------------------

  testWidgets('a row lays out on a 320dp screen at the largest text scale',
      (tester) async {
    _usePhoneSurface(tester, width: 320);
    final repo = _FakeOrderRepository(pages: [
      [_modern, _legacy],
    ],);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
        child: await _wrap(const OrdersScreen(), repo: repo),
      ),
    );
    await tester.pumpAndSettle();

    // Nothing paints the overflow stripes on the way down the list.
    expect(tester.takeException(), isNull);
    expect(_row(277), findsOneWidget);
  });

  testWidgets('the detail screen lays out on a 320dp screen', (tester) async {
    _usePhoneSurface(tester, width: 320);
    final repo = _FakeOrderRepository(
      detail: Order.fromJson(_detailRow(canConfirm: true)),
    );
    await tester.pumpWidget(
      await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Both actions are reachable: they are stacked, not in a Row, which would
    // overflow this width by 33px before any text scaling.
    expect(find.text('Cancel order'), findsOneWidget);
    expect(find.text('Confirm delivery'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // Legibility
  // -------------------------------------------------------------------------

  // The chip label is an 11px semi-bold on a 12% tint of its own colour. The
  // brand semantics are chosen for a white card and miss AA at both ends —
  // amber ~2.8:1 in light, blue ~3.1:1 in dark — so every status is checked in
  // both themes rather than eyeballed in one.
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('every status colour clears AA in ${mode.name} mode',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: mode,
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        },),
      ),);

      final surface = mode == ThemeMode.dark
          ? AppPalette.dark.surface
          : AppPalette.light.surface;

      for (final value in [
        OrderStatuses.pending,
        OrderStatuses.processing,
        OrderStatuses.completed,
        OrderStatuses.canceled,
        // A status the app has never heard of still has to be readable.
        'delivering',
      ]) {
        final color = OrderStatusChip.colorFor(ctx, value);
        final chip = Color.alphaBlend(color.withValues(alpha: 0.12), surface);
        expect(
          _contrastRatio(color, chip),
          greaterThanOrEqualTo(4.5),
          reason: '"$value" label on its own chip in ${mode.name}',
        );
      }
    });
  }

  // -------------------------------------------------------------------------
  // Provider-level
  // -------------------------------------------------------------------------

  test('loadMore is dropped while one page is already in flight', () async {
    final repo = _FakeOrderRepository(
      pages: [
        [_modern],
        [_legacy],
      ],
      delay: const Duration(milliseconds: 20),
    );
    final container = ProviderContainer(
      overrides: [orderRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    final sub = container.listen(ordersProvider, (_, __) {});
    addTearDown(sub.close);

    await Future<void>.delayed(const Duration(milliseconds: 40));
    final notifier = container.read(ordersProvider.notifier);

    final first = notifier.loadMore();
    await notifier.loadMore(); // dropped: one is in flight
    await first;

    expect(repo.pagesRequested, [1, 2]);
    expect(container.read(ordersProvider).orders, hasLength(2));
    // Page 2 is the last, so nothing more is promised.
    expect(container.read(ordersProvider).hasMore, isFalse);
  });

  test('a failed page keeps the pages already loaded', () async {
    final repo = _FakeOrderRepository(pages: [
      [_modern],
      [_legacy],
    ],);
    final container = ProviderContainer(
      overrides: [orderRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    final sub = container.listen(ordersProvider, (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    repo.listError = ApiException.local('Gateway timeout');
    await container.read(ordersProvider.notifier).loadMore();

    final state = container.read(ordersProvider);
    expect(state.orders, hasLength(1));
    expect(state.error?.message, 'Gateway timeout');
    expect(state.loadingMore, isFalse);
  });

  // -------------------------------------------------------------------------
  // Date filter
  //
  // `GET /ecommerce/orders` has no date parameter — seven names were tried
  // live and all seven returned the whole 94-order history, unfiltered and
  // un-rejected. So the span is honoured by [OrderRepository]; what these
  // tests pin is that the screen asks for one, says which one is on screen,
  // and can always get back out of it.
  // -------------------------------------------------------------------------

  group('search and filter', () {
    final march = Order.fromJson({
      ..._listRow(id: 301, code: 'SF10000301'),
      'created_at': '2026-03-05T10:00:00+05:30',
    });
    final august = Order.fromJson({
      ..._listRow(id: 302, code: 'SF10000302'),
      'created_at': '2026-08-11T21:47:04+05:30',
    });

    Future<_FakeOrderRepository> pump(
      WidgetTester tester, {
      List<Order> orders = const [],
    }) async {
      _useTallSurface(tester);
      final repo = _FakeOrderRepository(pages: [orders]);
      await tester.pumpWidget(await _wrap(const OrdersScreen(), repo: repo));
      await tester.pumpAndSettle();
      return repo;
    }

    Future<void> type(WidgetTester tester, String query) async {
      await tester.enterText(
        find.byKey(const Key('order-search-field')),
        query,
      );
      await tester.pumpAndSettle();
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    Future<void> openFilters(WidgetTester tester) =>
        tapKey(tester, 'order-filter-button');

    testWidgets('opens unfiltered, asking the server for nothing in particular',
        (tester) async {
      final repo = await pump(tester, orders: [august, march]);

      expect(find.byKey(const Key('order-search-field')), findsOneWidget);
      expect(find.byKey(const Key('order-filter-button')), findsOneWidget);
      // No badge and no summary until something is on.
      expect(find.byKey(const Key('order-filter-count')), findsNothing);
      expect(find.byKey(const Key('order-filter-summary')), findsNothing);

      expect(repo.queriesRequested, ['']);
      expect(repo.rangesRequested, [null]);
      expect(repo.bucketsRequested.single.status, isNull);
      expect(find.text('SF10000301'), findsOneWidget);
      expect(find.text('SF10000302'), findsOneWidget);
    });

    testWidgets('typing an order number narrows the list', (tester) async {
      // `GET /orders` has no search parameter — `search`, `keyword`, `code` and
      // `q` all came back with the whole history — so this is a local pass and
      // the query has to reach the repository to be applied at all.
      final repo = await pump(tester, orders: [august, march]);

      await type(tester, '10000301');

      expect(repo.queriesRequested.last, '10000301');
      expect(find.text('SF10000301'), findsOneWidget);
      expect(find.text('SF10000302'), findsNothing);
    });

    testWidgets('the clear button restores the whole list', (tester) async {
      await pump(tester, orders: [august, march]);
      await type(tester, '10000301');
      expect(find.text('SF10000302'), findsNothing, reason: 'the premise');

      await tapKey(tester, 'order-search-clear');

      expect(find.text('SF10000301'), findsOneWidget);
      expect(find.text('SF10000302'), findsOneWidget);
    });

    testWidgets('a status bucket is sent to the server, not filtered here',
        (tester) async {
      // `?status=` is a real filter — live, `status=completed` returns 27 of
      // 94 — so this half costs one request rather than reading everything.
      final repo = await pump(tester, orders: [august, march]);

      await openFilters(tester);
      await tapKey(tester, 'order-bucket-canceled');
      await tapKey(tester, 'order-filter-apply');

      expect(repo.bucketsRequested.last.status, 'canceled');
      expect(repo.bucketsRequested.last.paymentStatus, isNull);
      // No local pass: no date span and no query.
      expect(repo.rangesRequested.last, isNull);
      expect(repo.queriesRequested.last, '');
    });

    testWidgets('Refunded travels as a PAYMENT status', (tester) async {
      // It cannot be an order status: live, the 10 refunded orders are
      // `processing` (8) and `completed` (2).
      final repo = await pump(tester, orders: [august, march]);

      await openFilters(tester);
      await tapKey(tester, 'order-bucket-refunded');
      await tapKey(tester, 'order-filter-apply');

      expect(repo.bucketsRequested.last.paymentStatus, 'refunded');
      expect(repo.bucketsRequested.last.status, isNull);
    });

    testWidgets('a period narrows the list and the button counts it',
        (tester) async {
      final repo = await pump(tester, orders: [august, march]);

      await openFilters(tester);
      await tapKey(tester, 'order-period-2026');
      await tapKey(tester, 'order-filter-apply');

      expect(repo.rangesRequested.last, isNotNull);
      // One filter on, and the button says so — a funnel icon alone cannot
      // tell the customer whether this is the whole history or a slice.
      expect(find.byKey(const Key('order-filter-count')), findsOneWidget);
      // The footer says "All 2 orders shown" too, so read the summary line
      // itself rather than counting matches across the screen.
      final summary = tester.widget<Text>(
        find.byKey(const Key('order-filter-summary')),
      );
      expect(summary.data, '2 orders · 2026');
    });

    testWidgets('the badge counts both filters, and never the search box',
        (tester) async {
      // The query has its own visible field; counting it there too would tell
      // the customer there are filters hidden behind the button that are not.
      final repo = await pump(tester, orders: [august, march]);

      await type(tester, 'SF1000');
      expect(find.byKey(const Key('order-filter-count')), findsNothing);

      await openFilters(tester);
      await tapKey(tester, 'order-bucket-completed');
      await tapKey(tester, 'order-period-2026');
      await tapKey(tester, 'order-filter-apply');

      final badge = tester.widget<Text>(
        find.byKey(const Key('order-filter-count')),
      );
      expect(badge.data, '2');
      // ...and all three reached the repository together.
      expect(repo.queriesRequested.last, 'SF1000');
      expect(repo.bucketsRequested.last.status, 'completed');
      expect(repo.rangesRequested.last, isNotNull);
    });

    testWidgets('Reset clears the sheet but keeps what was typed',
        (tester) async {
      final repo = await pump(tester, orders: [august, march]);

      await type(tester, 'SF1000');
      await openFilters(tester);
      await tapKey(tester, 'order-bucket-canceled');
      await tapKey(tester, 'order-filter-reset');
      await tapKey(tester, 'order-filter-apply');

      expect(repo.bucketsRequested.last.status, isNull);
      // The search box is the customer's, and visible. The sheet does not
      // reach outside itself.
      expect(repo.queriesRequested.last, 'SF1000');
    });

    testWidgets('a filter that matches nothing says so, and offers the way out',
        (tester) async {
      // Not "No orders yet" — that would be a false statement about an account
      // that has two.
      await pump(tester, orders: [august, march]);

      await type(tester, 'nothing-matches-this');

      expect(find.text('No orders match'), findsOneWidget);
      expect(find.text('No orders yet'), findsNothing);

      await tapKey(tester, 'order-filter-clear');

      expect(find.text('SF10000301'), findsOneWidget);
      expect(find.text('SF10000302'), findsOneWidget);
    });

    testWidgets('a customer with no orders at all gets no search bar',
        (tester) async {
      await pump(tester);

      expect(find.byKey(const Key('order-search-field')), findsNothing);
      expect(find.text('No orders yet'), findsOneWidget);
    });

    // A plain `test`, not `testWidgets`: this one builds no widgets, and
    // `testWidgets` runs inside FakeAsync — an awaited `Future.delayed` there
    // never completes unless something pumps the clock, so it hangs to the
    // harness timeout rather than failing.
    test('signing out drops the span', () async {
      // One account's "This year" must not greet the next.
      final repo = _FakeOrderRepository(
        pages: [
          [august, march],
        ],
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final status = StateController<AuthStatus>(AuthStatus.authenticated);
      addTearDown(status.dispose);

      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          orderRepositoryProvider.overrideWithValue(repo),
          ordersAuthStatusProvider.overrideWith((ref) => status.state),
        ],
      );
      addTearDown(container.dispose);

      container.read(orderFilterProvider.notifier).state = OrderFilter(
        query: 'SF1000',
        bucket: OrderBucket.canceled,
        date: const OrderDateFilter.year(2026),
      );
      expect(container.read(orderFilterProvider).isFiltered, isTrue);

      // A listener is what keeps the provider alive to hear the auth change.
      final sub = container.listen(orderFilterProvider, (_, __) {});
      addTearDown(sub.close);

      status.state = AuthStatus.signedOut;
      container.refresh(ordersAuthStatusProvider);
      await Future<void>.delayed(Duration.zero);

      // Everything goes — the search box included. One account's "cancelled,
      // this year, SF1000" must not greet the next.
      expect(container.read(orderFilterProvider), const OrderFilter());
    });
  });

  // The invoice is a delivery document on this shop, so the button is offered
  // only once the parcel has arrived — even though the server has had an
  // invoice since the order was placed.
  group('invoice button', () {
    testWidgets('is withheld while the order is still on its way',
        (tester) async {
      final repo = _FakeOrderRepository(
        detail: Order.fromJson(
          _detailRow(
            shippingStatus: {
              'value': 'out_for_delivery',
              'label': 'Out for delivery',
            },
          ),
        ),
      );
      await tester.pumpWidget(
        await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Download invoice'), findsNothing);
    });

    testWidgets('appears once the shipment is delivered', (tester) async {
      final repo = _FakeOrderRepository(
        detail: Order.fromJson(
          _detailRow(
            shippingStatus: {'value': 'delivered', 'label': 'Delivered'},
          ),
        ),
      );
      await tester.pumpWidget(
        await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Download invoice'), findsOneWidget);
    });

    testWidgets('a completed order counts as delivered', (tester) async {
      // The backend sets `completed` *from* a delivered shipment, so an order
      // whose shipment row never caught up must not lose its invoice.
      final repo = _FakeOrderRepository(
        detail: Order.fromJson(
          _detailRow(statusValue: 'completed', statusLabel: 'Completed'),
        ),
      );
      await tester.pumpWidget(
        await _wrap(const OrderDetailScreen(orderId: 277), repo: repo),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Download invoice'), findsOneWidget);
    });
  });
  // -------------------------------------------------------------------------
  // The refund line on the order itself
  //
  // The cancel toast says it once, for four seconds, at the moment the customer
  // is least likely to be reading carefully. "When does my money come back?" is
  // exactly the question they reopen the order to answer, so it has to be on
  // the page.
  // -------------------------------------------------------------------------

  group('refund note on the order', () {
    Future<void> pump(WidgetTester tester, Map<String, dynamic> row) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _wrap(
          const OrderDetailScreen(orderId: 277),
          repo: _FakeOrderRepository(detail: Order.fromJson(row)),
        ),
      );
      await tester.pumpAndSettle();
    }

    Map<String, dynamic> cancelled({
      String paymentStatus = 'completed',
      String paymentMethod = 'razorpay',
    }) =>
        {
          ..._detailRow(statusValue: 'canceled', statusLabel: 'Canceled'),
          'payment_status': {'value': paymentStatus, 'label': paymentStatus},
          'payment_method': {'value': paymentMethod, 'label': paymentMethod},
        };

    testWidgets('a cancelled card order says when the money returns',
        (tester) async {
      await pump(tester, cancelled());

      expect(find.byKey(const Key('order-refund-note')), findsOneWidget);
      expect(
        find.textContaining('original payment method in 5–7 business days'),
        findsOneWidget,
      );
    });

    testWidgets('an already-refunded order says it has been sent',
        (tester) async {
      // `refunded` means *issued*, not *landed* — the bank still takes days —
      // so the window is still the useful half of the sentence.
      await pump(tester, cancelled(paymentStatus: 'refunded'));

      expect(find.textContaining('Refunded.'), findsOneWidget);
      expect(find.textContaining('5–7 business days'), findsOneWidget);
    });

    testWidgets('a cancelled COD order is not promised a card refund',
        (tester) async {
      await pump(tester, cancelled(paymentMethod: 'cod'));

      expect(find.byKey(const Key('order-refund-note')), findsOneWidget);
      expect(find.textContaining('original payment method'), findsNothing);
      expect(
        find.textContaining('processed in 5–7 business days'),
        findsOneWidget,
      );
    });

    testWidgets('a cancelled but unpaid order gets no refund line',
        (tester) async {
      await pump(tester, cancelled(paymentStatus: 'pending'));

      expect(find.byKey(const Key('order-refund-note')), findsNothing);
    });

    testWidgets('a live order is not told about refunds at all', (tester) async {
      // The regression this guards: a delivered order the customer is perfectly
      // happy with, carrying a refund window for no reason.
      await pump(tester, _detailRow());

      expect(find.byKey(const Key('order-refund-note')), findsNothing);
      expect(find.textContaining('business days'), findsNothing);
    });
  });
  // -------------------------------------------------------------------------
  // Folding, and the second address
  // -------------------------------------------------------------------------

  group('order detail folding', () {
    Map<String, dynamic> withLines(int count) => {
          ..._detailRow(),
          'products': [
            for (var i = 1; i <= count; i++)
              {
                'id': 400 + i,
                'product_id': 100 + i,
                'product_name': 'Item $i',
                'product_image': '',
                'sku': 'SKU$i',
                'amount': '99.00',
                'quantity': 1,
                'total': 99,
                'options': <String, dynamic>{},
              },
          ],
        };

    Future<void> pump(WidgetTester tester, Map<String, dynamic> row) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _wrap(
          const OrderDetailScreen(orderId: 277),
          repo: _FakeOrderRepository(detail: Order.fromJson(row)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a short order is not folded at all', (tester) async {
      // Three folding to two saves one row and costs a tap. The button only
      // appears once there is something real behind it.
      await pump(tester, withLines(3));

      expect(find.text('Item 3'), findsOneWidget);
      expect(find.byKey(const Key('order-items-toggle')), findsNothing);
    });

    testWidgets('a long order shows two and offers the rest', (tester) async {
      await pump(tester, withLines(6));

      expect(find.text('Item 1'), findsOneWidget);
      expect(find.text('Item 2'), findsOneWidget);
      expect(find.text('Item 3'), findsNothing);
      expect(find.text('Show all 6 items'), findsOneWidget);
      // The count in the heading is of the order, not of what is on screen.
      expect(find.text('6 items'), findsOneWidget);

      await tester.tap(find.byKey(const Key('order-items-toggle')));
      await tester.pumpAndSettle();

      expect(find.text('Item 6'), findsOneWidget);
      expect(find.text('Show less'), findsOneWidget);
    });

    testWidgets('the history is folded until it is asked for', (tester) async {
      // The longest block on the screen, and a *record* — useful when
      // something looks wrong, in the way of the bill the rest of the time.
      await pump(tester, {
        ..._detailRow(),
        'histories': [
          {
            'id': 1,
            'action': 'create_order',
            'description': 'Order was created',
            'created_at': '2026-07-16T17:04:00+05:30',
          },
        ],
      });

      expect(find.text('Order history'), findsOneWidget);
      expect(find.text('Order was created'), findsNothing);

      await tester.tap(find.byKey(const Key('order-history-toggle')));
      await tester.pumpAndSettle();

      expect(find.text('Order was created'), findsOneWidget);
      // Still ONE heading. The timeline draws its own by default, and opening
      // the section used to put a second "Order history" directly under the
      // toggle's.
      expect(find.text('Order history'), findsOneWidget);
    });
  });

  group('billing address', () {
    Future<void> pump(WidgetTester tester, Map<String, dynamic> row) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _wrap(
          const OrderDetailScreen(orderId: 277),
          repo: _FakeOrderRepository(detail: Order.fromJson(row)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('an all-null billing block says "same address"',
        (tester) async {
      // 82 of 90 orders look like this — the resource emits the keys either
      // way, so "present" is not the same as "different".
      await pump(tester, _detailRow());

      expect(find.byKey(const Key('order-billing-address')), findsNothing);
      expect(find.text('Billed to the same address.'), findsOneWidget);
    });

    testWidgets('a billing block identical to shipping is not printed twice',
        (tester) async {
      // The two come from different rows written at different moments, so one
      // can carry an email the other does not while naming the same doorstep.
      await pump(tester, {
        ..._detailRow(),
        'billing_info': {
          'name': 'Suraj ojha',
          'phone': '8305317276',
          // Present here, absent on the shipping block. Same doorstep.
          'email': 'suraj.ojha@uminber.in',
          'address': '306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad',
          'city': '574',
          'state': '11',
          'country': 'India',
          'zip_code': '382415',
        },
      });

      expect(find.byKey(const Key('order-billing-address')), findsNothing);
      expect(find.text('Billed to the same address.'), findsOneWidget);
    });

    testWidgets('a genuinely different billing address gets its own block',
        (tester) async {
      await pump(tester, {
        ..._detailRow(),
        'billing_info': {
          'name': 'Uminber Accounts',
          'phone': '9812345670',
          'address': '12 Prahlad Nagar Road',
          'city': 'Ahmedabad',
          'state': 'Gujarat',
          'country': 'India',
          'zip_code': '380015',
        },
      });

      expect(find.byKey(const Key('order-billing-address')), findsOneWidget);
      expect(find.text('Billed to the same address.'), findsNothing);
      expect(find.text('Uminber Accounts'), findsOneWidget);
      // ...and the delivery address is still there, above it.
      expect(find.text('Delivery address'), findsOneWidget);
    });
  });
  // -------------------------------------------------------------------------
  // Returns, shown on the order they came off
  //
  // Nothing on the order side knows about them: `GET /orders/{id}` has no
  // `returns` key and no per-line returned quantity, and `/orders/{id}/returns`
  // is the *eligibility* route ("You cannot return this order"). The returns
  // list has everything though — each row carries `order_id` and its full
  // `items`, each with `order_product_id` and `qty`, and `order_product_id` is
  // the order's own `products[].id`. Verified live on order 314, whose lines
  // are 452-456 and whose return names 452.
  // -------------------------------------------------------------------------

  group('returns on an order', () {
    /// A line on the order, and the return that took part of it back.
    Map<String, dynamic> orderWithLines() => {
          ..._detailRow(),
          'id': 314,
          'products': [
            {
              'id': 452,
              'product_id': 134,
              'product_name': 'A2 Gir Cow Ghee',
              'product_image': '',
              'sku': 'GHEE',
              'amount': '599.00',
              'quantity': 5,
              'total': 2995,
              'options': <String, dynamic>{},
            },
            {
              'id': 453,
              'product_id': 118,
              'product_name': 'Desi Khand',
              'product_image': '',
              'sku': 'KHAND',
              'amount': '899.00',
              'quantity': 2,
              'total': 1798,
              'options': <String, dynamic>{},
            },
          ],
        };

    Map<String, dynamic> returnRow({
      String status = 'completed',
      int qty = 1,
      int orderProductId = 452,
    }) =>
        {
          'id': 30,
          'order_id': 314,
          'order_code': 'SF10000314',
          'return_status': {'value': status, 'label': status},
          'reason': {'value': 'damaged', 'label': 'Damaged product'},
          'items_count': 1,
          'items': [
            {
              'id': 90,
              'order_return_id': 30,
              'order_product_id': orderProductId,
              'product_id': 134,
              'product_name': 'A2 Gir Cow Ghee',
              'qty': qty,
              'price': '599.00',
              'refund_amount': '479.20',
              'reason': {'value': 'damaged', 'label': 'Damaged product'},
            },
          ],
        };

    Future<void> pumpDetail(
      WidgetTester tester, {
      required List<Map<String, dynamic>> returns,
      Map<String, dynamic>? order,
    }) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _wrap(
          const OrderDetailScreen(orderId: 314),
          repo: _FakeOrderRepository(
            detail: Order.fromJson(order ?? orderWithLines()),
            returnRows: [for (final r in returns) OrderReturn.fromJson(r)],
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a returned item gets its own card, with quantity and refund',
        (tester) async {
      // The badge used to live inside the order line's text column, so a long
      // product name grew the row a third line and it collided with the next
      // thumbnail. A return is its own event with its own quantity, price and
      // status; it gets its own card.
      await pumpDetail(tester, returns: [returnRow()]);

      expect(find.byKey(const Key('order-returned-toggle')), findsOneWidget);
      expect(find.text('1 item returned'), findsOneWidget);
      // Folded until asked for — most orders have no returns, and the ones
      // that do are usually opened for the bill.
      expect(find.byKey(const ValueKey('returned-item-90')), findsNothing);

      await tester.tap(find.byKey(const Key('order-returned-toggle')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('returned-item-90')), findsOneWidget);
      // Quantity and unit price, and the server's own refund figure — which is
      // prorated against the order's discount, so it is NOT qty x price.
      expect(find.textContaining('1 × ₹599.00'), findsOneWidget);
      expect(find.text('₹479.20'), findsOneWidget);
    });

    testWidgets('two requests are counted together in the heading',
        (tester) async {
      // A customer can send things back a week apart; both are still returned.
      await pumpDetail(
        tester,
        returns: [
          returnRow(qty: 1),
          {...returnRow(qty: 2), 'id': 31},
        ],
      );

      expect(find.text('3 items returned'), findsOneWidget);
    });

    testWidgets('a cancelled return does not count at all', (tester) async {
      // It took nothing back, so the order is wholly the customer's again and
      // the card must not appear.
      await pumpDetail(tester, returns: [returnRow(status: 'canceled')]);

      expect(find.byKey(const Key('order-returned-toggle')), findsNothing);
    });

    testWidgets('an order with no returns says nothing at all', (tester) async {
      await pumpDetail(tester, returns: const []);

      expect(find.byKey(const Key('order-returned-toggle')), findsNothing);
      expect(find.textContaining('returned'), findsNothing);
    });

    testWidgets('the list row says a return is on the order', (tester) async {
      // The status chip says "Processing", which is true of the order and
      // silent about the jar that went back.
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _wrap(
          const OrdersScreen(),
          repo: _FakeOrderRepository(
            pages: [
              [Order.fromJson({..._listRow(id: 314, code: 'SF10000314')})],
            ],
            returnRows: [OrderReturn.fromJson(returnRow())],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('order-return-state')), findsOneWidget);
      expect(find.textContaining('1 item returned'), findsOneWidget);
    });
  });
}

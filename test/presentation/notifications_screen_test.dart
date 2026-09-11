import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/models/app_notification.dart';
import 'package:trueway_farms/data/models/customer.dart';
import 'package:trueway_farms/data/repositories/auth_repository.dart';
import 'package:trueway_farms/data/repositories/notification_repository.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/notification_provider.dart';
import 'package:trueway_farms/presentation/screens/notifications/notifications_screen.dart';
import 'package:trueway_farms/presentation/widgets/state_views.dart';

/// Covers the screen whose only reachable state used to be "empty": the
/// repository handed a nested `{data: {notifications: [...]}}` body to
/// `unwrapList`, which yields `const []` for a non-list `data`. These tests pin
/// all four surfaces — loading, error + retry, empty and populated — plus the
/// paging, the unread badge and both mark-read paths, so the screen cannot
/// silently regress to empty again.

AppNotification _n(
  int id, {
  bool isRead = false,
  bool isClicked = false,
  String? actionUrl,
}) =>
    AppNotification.fromJson({
      'id': id,
      'notification_id': id,
      'title': 'Order #$id dispatched',
      'message': 'Your order is on the way.',
      'type': 'order',
      'action_url': actionUrl,
      'is_read': isRead,
      'is_clicked': isClicked,
      'created_at': '2026-08-01T07:34:01.000000Z',
    });

/// A [NotificationRepository] that answers from canned pages instead of Dio.
///
/// It extends the real class so the provider override keeps its declared type
/// and any signature change here breaks the test rather than passing silently.
class _FakeNotificationRepo extends NotificationRepository {
  _FakeNotificationRepo(super.api, {this.pages = const [], this.failWith});

  /// One entry per requested page, 1-indexed.
  List<NotificationPage> pages;
  ApiException? failWith;

  /// When set, [list] hangs — used to hold the screen in its loading state.
  Completer<NotificationPage>? gate;

  int listCalls = 0;
  int markAllCalls = 0;
  final List<int> markedRead = [];

  /// What a *tap* posts. `/{id}/clicked` cascades to `markAsRead()` server
  /// side, so a tap lands here and never in [markedRead].
  final List<int> markedClicked = [];
  final List<int> deleted = [];

  /// Fails the delete alone, leaving [list] working — otherwise the re-read
  /// that follows a refused delete would fail too and the assertion could not
  /// tell "the row survived" from "the list is gone".
  ApiException? deleteFailure;
  int markAllResult = 0;

  @override
  Future<NotificationPage> list({
    int page = 1,
    int perPage = 20,
    bool unreadOnly = false,
    String? type,
  }) {
    listCalls++;
    if (gate != null) return gate!.future;
    if (failWith != null) return Future.error(failWith!);
    final i = page - 1;
    return Future.value(
      i >= 0 && i < pages.length ? pages[i] : const NotificationPage(),
    );
  }

  @override
  Future<void> markRead(int id) async {
    if (failWith != null) throw failWith!;
    markedRead.add(id);
  }

  @override
  Future<void> markClicked(int id) async {
    if (failWith != null) throw failWith!;
    markedClicked.add(id);
  }

  @override
  Future<void> delete(int id) async {
    if (deleteFailure != null) throw deleteFailure!;
    if (failWith != null) throw failWith!;
    deleted.add(id);
  }

  @override
  Future<int> markAllRead() async {
    markAllCalls++;
    if (failWith != null) throw failWith!;
    return markAllResult;
  }
}

/// Skips the background token check so the fake session is not torn down
/// mid-test by a network call, and signs in without one either.
class _OfflineAuthRepo extends AuthRepository {
  _OfflineAuthRepo(super.api);

  @override
  Future<bool> validateSession() async => true;

  @override
  Future<AuthSession> loginWithPassword({
    required String email,
    required String password,
  }) async => const AuthSession(
        token: 'test-token',
        customer: Customer(id: 1, name: 'Test Customer'),
      );
}

/// Builds the screen with a real signed-in [AuthNotifier].
///
/// Auth is driven through seeded prefs rather than a stubbed notifier because
/// `_restore` reads the cached customer synchronously — the screen therefore
/// sees `AuthStatus.authenticated` on its very first build, exactly as it does
/// on a warm start.
Future<Widget> _wrap(
  _FakeNotificationRepo repo, {
  bool signedIn = true,
  GoRouter? router,
}) async {
  SharedPreferences.setMockInitialValues(
    signedIn
        ? {
            'auth_token': 'test-token',
            'auth_customer_v1': jsonEncode({
              'id': 1,
              'name': 'Test Customer',
              'phone': '9800000000',
            }),
          }
        : {},
  );
  final prefs = await SharedPreferences.getInstance();

  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      authRepositoryProvider.overrideWithValue(
        _OfflineAuthRepo(ApiClient(prefs: prefs, dio: Dio())),
      ),
      notificationRepositoryProvider.overrideWithValue(repo),
    ],
    child: router == null
        ? MaterialApp(theme: AppTheme.light, home: const NotificationsScreen())
        : MaterialApp.router(theme: AppTheme.light, routerConfig: router),
  );
}

/// A router that knows `/product/:slug` and, deliberately, nothing about
/// `/orders/:id` — which is exactly the shape the API docs give as an example
/// `action_url`.
GoRouter _router() => GoRouter(
      initialLocation: '/notifications',
      routes: [
        GoRoute(
          path: '/notifications',
          builder: (_, __) => const NotificationsScreen(),
        ),
        GoRoute(
          path: '/product/:slug',
          builder: (_, s) => Scaffold(
            body: Text('product ${s.pathParameters['slug']}'),
          ),
        ),
      ],
    );

_FakeNotificationRepo _repo({
  List<NotificationPage> pages = const [],
  ApiException? failWith,
}) =>
    _FakeNotificationRepo(
      ApiClient(prefs: _prefs!, dio: Dio()),
      pages: pages,
      failWith: failWith,
    );

SharedPreferences? _prefs;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('holds a real loading state while the first page is in flight',
      (tester) async {
    final repo = _repo();
    repo.gate = Completer<NotificationPage>();

    await tester.pumpWidget(await _wrap(repo));
    await tester.pump();

    expect(find.byType(LoadingView), findsOneWidget);
    expect(find.byType(EmptyView), findsNothing);

    repo.gate!.complete(const NotificationPage());
    repo.gate = null;
    await tester.pumpAndSettle();
  });

  testWidgets('a failure renders an error with a retry, never an empty inbox',
      (tester) async {
    final repo = _repo(
      failWith: const ApiException('Something went wrong', statusCode: 500),
    );

    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorView), findsOneWidget);
    // The regression this whole slice exists to prevent.
    expect(find.text('Nothing new'), findsNothing);

    // Retry actually refetches, and a now-healthy server replaces the error.
    repo.failWith = null;
    repo.pages = [
      NotificationPage(items: [_n(1)], total: 1, unreadCount: 1),
    ];
    final callsBefore = repo.listCalls;

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(repo.listCalls, greaterThan(callsBefore));
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.text('Order #1 dispatched'), findsOneWidget);
  });

  testWidgets('an account with no notifications shows the empty state',
      (tester) async {
    final repo = _repo(pages: const [NotificationPage()]);

    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('Nothing new'), findsOneWidget);
    expect(find.byType(AppErrorView), findsNothing);
    // Nothing to mark, so the action is not offered.
    expect(find.text('Mark all read'), findsNothing);
  });

  testWidgets('renders a tile per notification and the unread badge',
      (tester) async {
    final repo = _repo(
      pages: [
        NotificationPage(
          items: [_n(1), _n(2, isRead: true), _n(3)],
          total: 3,
          unreadCount: 2,
        ),
      ],
    );

    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();

    expect(find.byType(ListTile), findsNWidgets(3));
    expect(find.text('Order #2 dispatched'), findsOneWidget);
    // Straight from data.unread_count, not counted off the visible page.
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Mark all read'), findsOneWidget);
  });

  testWidgets('the badge reports the account-wide count, capped at 99+',
      (tester) async {
    final repo = _repo(
      pages: [
        NotificationPage(items: [_n(1)], total: 400, unreadCount: 400),
      ],
    );

    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('mark-all-read clears the badge and reports the server count',
      (tester) async {
    final repo = _repo(
      pages: [
        NotificationPage(items: [_n(1), _n(2)], total: 2, unreadCount: 2),
      ],
    );
    repo.markAllResult = 2;

    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mark all read'));
    await tester.pumpAndSettle();

    expect(repo.markAllCalls, 1);
    expect(find.text('Marked 2 notifications as read'), findsOneWidget);
    // Badge and action both retire once nothing is unread.
    expect(find.text('Mark all read'), findsNothing);
  });

  testWidgets('tapping a notification records the open on just that row',
      (tester) async {
    final repo = _repo(
      pages: [
        NotificationPage(
          // Row 3 is read but never opened — "mark all read" leaves rows in
          // exactly that state, and opening one later is still a real open.
          items: [_n(1), _n(2, isRead: true, isClicked: true), _n(3, isRead: true)],
          total: 3,
          unreadCount: 1,
        ),
      ],
    );

    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Order #1 dispatched'));
    await tester.pumpAndSettle();

    // `/clicked`, not `/read` — one round trip that stamps `clicked_at` and
    // cascades to read. Nothing should reach the read-only route.
    expect(repo.markedClicked, [1]);
    expect(repo.markedRead, isEmpty);

    // An already-opened row must not spend a request.
    await tester.tap(find.text('Order #2 dispatched'));
    await tester.pumpAndSettle();

    expect(repo.markedClicked, [1]);

    // ...but read-and-never-opened is not the same thing: the click is what
    // the store's click-through figures count, so it still gets recorded.
    await tester.tap(find.text('Order #3 dispatched'));
    await tester.pumpAndSettle();

    expect(repo.markedClicked, [1, 3]);
    expect(repo.markedRead, isEmpty);
  });

  testWidgets('pages on has_more and stops when the server says so',
      (tester) async {
    final repo = _repo(
      pages: [
        NotificationPage(
          items: [for (var i = 1; i <= 20; i++) _n(i)],
          currentPage: 1,
          lastPage: 2,
          total: 25,
          hasMore: true,
          unreadCount: 25,
        ),
        NotificationPage(
          items: [for (var i = 21; i <= 25; i++) _n(i)],
          currentPage: 2,
          lastPage: 2,
          total: 25,
          hasMore: false,
          unreadCount: 25,
        ),
      ],
    );

    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();

    expect(repo.listCalls, 1);

    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();

    expect(repo.listCalls, 2);

    // Scroll on to the freshly appended tail. hasMore is now false, so this
    // second drag must not fire a third request.
    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();

    expect(find.text('Order #25 dispatched'), findsOneWidget);
    expect(repo.listCalls, 2);
  });

  testWidgets('a failed next page keeps the loaded rows and offers a retry',
      (tester) async {
    final repo = _repo(
      pages: [
        NotificationPage(
          items: [for (var i = 1; i <= 20; i++) _n(i)],
          currentPage: 1,
          lastPage: 2,
          total: 25,
          hasMore: true,
          unreadCount: 25,
        ),
      ],
    );

    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();

    repo.failWith = const ApiException('Network unreachable');
    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();

    expect(find.byType(InlineErrorStrip), findsOneWidget);
    // The already-loaded page survives the failure — the strip is admitted
    // above the rows rather than replacing them with a full-screen error.
    expect(find.byType(ListTile), findsWidgets);
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.text('Nothing new'), findsNothing);
  });

  testWidgets('a signed-out customer is prompted to sign in, not shown an error',
      (tester) async {
    final repo = _repo();

    await tester.pumpWidget(await _wrap(repo, signedIn: false));
    await tester.pumpAndSettle();

    expect(find.text('Sign in to see notifications'), findsOneWidget);
    expect(find.byType(AppErrorView), findsNothing);
    // No doomed 401 fired on a screen the customer cannot use yet.
    expect(repo.listCalls, 0);
  });

  // The signed-out render skips the fetch, so the notifier holds an empty
  // never-fetched state. Signing in from this very screen (tap "Sign in", come
  // back) has to refetch, or a full inbox renders as "Nothing new".
  testWidgets('signing in from the prompt actually fetches the inbox',
      (tester) async {
    final repo = _repo(
      pages: [
        NotificationPage(items: [_n(1)], total: 1, unreadCount: 1),
      ],
    );

    await tester.pumpWidget(await _wrap(repo, signedIn: false));
    await tester.pumpAndSettle();
    expect(repo.listCalls, 0);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotificationsScreen)),
    );
    await container
        .read(authProvider.notifier)
        .loginWithPassword(email: 'a@b.c', password: 'secret');
    await tester.pumpAndSettle();

    expect(repo.listCalls, 1);
    expect(find.text('Order #1 dispatched'), findsOneWidget);
    expect(find.text('Nothing new'), findsNothing);
  });

  // The live endpoint really does answer `{"marked_count": 0}`. Clearing the
  // badge and painting every row read off the back of that would be asserting
  // an outcome the server never reported.
  testWidgets('a mark-all that marked nothing does not fake a read inbox',
      (tester) async {
    final repo = _repo(
      pages: [
        NotificationPage(items: [_n(1), _n(2)], total: 2, unreadCount: 2),
      ],
    );
    repo.markAllResult = 0;

    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mark all read'));
    await tester.pumpAndSettle();

    expect(repo.markAllCalls, 1);
    expect(find.text('Nothing left to mark'), findsOneWidget);
    // Reconciled with the server rather than assumed.
    expect(repo.listCalls, 2);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Mark all read'), findsOneWidget);
  });

  testWidgets('a failed mark-read leaves the row unread and says so',
      (tester) async {
    final repo = _repo(
      pages: [
        NotificationPage(items: [_n(1)], total: 1, unreadCount: 1),
      ],
    );

    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();

    repo.failWith = const ApiException('Network unreachable');
    await tester.tap(find.text('Order #1 dispatched'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    // Badge untouched — the row is still unread, because the server said no.
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('a repeated page is neither appended twice nor paged forever',
      (tester) async {
    final rows = [for (var i = 1; i <= 20; i++) _n(i)];
    // A server that clamps an out-of-range page hands back page 1 again with
    // has_more still true.
    final repeated = NotificationPage(
      items: rows,
      currentPage: 1,
      lastPage: 2,
      total: 25,
      hasMore: true,
      unreadCount: 25,
    );
    final repo = _repo(pages: [repeated, repeated]);

    await tester.pumpWidget(await _wrap(repo));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(repo.listCalls, 2);

    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotificationsScreen)),
    );
    expect(container.read(notificationsProvider).items, hasLength(20));
    expect(container.read(notificationsProvider).hasMore, isFalse);
    expect(repo.listCalls, 2);
  });

  group('action_url', () {
    testWidgets('follows a path this app can actually render', (tester) async {
      final repo = _repo(
        pages: [
          NotificationPage(
            items: [_n(1, actionUrl: '/product/apple')],
            total: 1,
            unreadCount: 1,
          ),
        ],
      );

      await tester.pumpWidget(await _wrap(repo, router: _router()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Order #1 dispatched'));
      await tester.pumpAndSettle();

      expect(find.text('product apple'), findsOneWidget);
    });

    // `action_url` is authored in the Botble admin against the website's URL
    // space — the docs' own example is `/orders/12`, which has no route here.
    // Pushing it blind lands on go_router's "no routes for location" screen.
    testWidgets('does not push a path with no route', (tester) async {
      final repo = _repo(
        pages: [
          NotificationPage(
            items: [_n(1, actionUrl: '/orders/12')],
            total: 1,
            unreadCount: 1,
          ),
        ],
      );

      await tester.pumpWidget(await _wrap(repo, router: _router()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Order #1 dispatched'));
      await tester.pumpAndSettle();

      expect(find.byType(NotificationsScreen), findsOneWidget);
      expect(find.textContaining('no routes for location'), findsNothing);
      // The tap still did its other job.
      expect(repo.markedClicked, [1]);
    });
  });

  // `DELETE /notifications/{id}` removes the recipient row only, and nothing
  // in this API re-creates one — so there is no undo to offer and the row may
  // not leave the list until the server has confirmed.
  group('swipe to delete', () {
    testWidgets('removes the row the server confirmed', (tester) async {
      final repo = _repo(
        pages: [
          NotificationPage(
            items: [_n(1), _n(2)],
            total: 2,
            unreadCount: 2,
          ),
        ],
      );

      await tester.pumpWidget(await _wrap(repo));
      await tester.pumpAndSettle();

      await tester.drag(
        find.text('Order #1 dispatched'),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();

      expect(repo.deleted, [1]);
      expect(find.text('Order #1 dispatched'), findsNothing);
      expect(find.text('Order #2 dispatched'), findsOneWidget);
      expect(find.text('Notification deleted'), findsOneWidget);
    });

    testWidgets('keeps the row when the server refuses', (tester) async {
      final repo = _repo(
        pages: [
          NotificationPage(items: [_n(1)], total: 1, unreadCount: 1),
        ],
      );

      await tester.pumpWidget(await _wrap(repo));
      await tester.pumpAndSettle();

      // 404 is what this API answers both for a row that is already gone and
      // for one belonging to someone else — indistinguishable, so the screen
      // re-reads instead of guessing.
      repo.deleteFailure =
          const ApiException('Notification not found', statusCode: 404);
      await tester.drag(
        find.text('Order #1 dispatched'),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();

      // Dismissed visually would be a lie: the server still holds the row.
      expect(find.text('Order #1 dispatched'), findsOneWidget);
    });
  });
}

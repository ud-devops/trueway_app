import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../core/errors/api_exception.dart';
import '../../../data/models/app_notification.dart';
import '../../providers/auth_provider.dart';
import '../../providers/notification_provider.dart';
import '../../widgets/state_views.dart';
import '../../widgets/app_message.dart';

/// Customer notifications, from `GET /api/v1/notifications`.
///
/// Every notification endpoint requires a bearer token, so a signed-out
/// customer is shown a sign-in prompt rather than an error.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final state = ref.watch(notificationsProvider);

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Notifications'),
            // `data.unread_count` is an account-wide count, not a per-page one,
            // so this stays honest even before the customer scrolls.
            if (auth.isAuthenticated && state.unreadCount > 0) ...[
              AppSpacing.hSm,
              _UnreadBadge(count: state.unreadCount),
            ],
          ],
        ),
        actions: [
          // Offered only when there is actually something to mark, so the
          // action never fires a request that can only be a no-op.
          if (auth.isAuthenticated && state.unreadCount > 0)
            TextButton(
              onPressed: state.busy ? null : () => _markAllRead(context, ref),
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: switch (auth.status) {
        AuthStatus.unknown => const LoadingView(),
        AuthStatus.authenticated => _Body(state: state),
        _ => EmptyView(
            icon: Icons.notifications_none_rounded,
            title: 'Sign in to see notifications',
            subtitle: 'Order updates and offers will appear here.',
            action: SizedBox(
              width: 220,
              child: ElevatedButton(
                onPressed: () => context.push('/login'),
                child: const Text('Sign in'),
              ),
            ),
          ),
      },
    );
  }

  Future<void> _markAllRead(BuildContext context, WidgetRef ref) async {
    try {
      final marked = await ref.read(notificationsProvider.notifier).markAllRead();
      if (!context.mounted) return;
      // Report what actually happened rather than a blanket confirmation — the
      // notifier returns the count the server accepted.
      context.showSuccessSnack(
        marked == 0
            ? 'Nothing left to mark'
            : 'Marked $marked notification${marked == 1 ? '' : 's'} as read',
      );
    } catch (e) {
      if (context.mounted) context.showErrorSnack(e);
    }
  }
}

/// Account-wide unread count, straight from `data.unread_count`.
///
/// Capped at `99+` so a neglected inbox cannot widen the app bar title until
/// the "Mark all read" action is pushed off screen.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: const BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.all(Radius.circular(999)),
        ),
        child: Text(
          count > 99 ? '99+' : '$count',
          style: context.text.caption.copyWith(
            // Fixed white: the pill's fill is the brand green in both themes,
            // so the label must not follow the theme's text colour.
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}

/// The authenticated list: loading, failure, empty and populated.
///
/// A failure is rendered as an error with a retry, never as an empty list — a
/// dead endpoint must not read as "you have no notifications".
class _Body extends ConsumerStatefulWidget {
  const _Body({required this.state});

  final NotificationListState state;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      // Never auto-retry a page that just failed — that turns one dead request
      // into a scroll-triggered loop. The customer taps Retry on the strip.
      if (ref.read(notificationsProvider).error != null) return;
      if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
        ref.read(notificationsProvider.notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final notifier = ref.read(notificationsProvider.notifier);

    if (state.loading) return const LoadingView();

    // Checked before the empty branch on purpose.
    if (state.error != null && state.items.isEmpty) {
      return AppErrorView(error: state.error, onRetry: notifier.refresh);
    }

    if (state.isEmpty) {
      return RefreshIndicator(
        onRefresh: notifier.refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 120),
            EmptyView(
              icon: Icons.notifications_none_rounded,
              title: 'Nothing new',
              subtitle: "We'll let you know when something happens.",
            ),
          ],
        ),
      );
    }

    // A failed *next* page must not wipe the pages already on screen, so it is
    // admitted in a strip above the list instead of replacing it.
    final tail = (state.error != null || state.hasMore) ? 1 : 0;

    return RefreshIndicator(
      onRefresh: notifier.refresh,
      child: ListView.separated(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        itemCount: state.items.length + tail,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          if (i >= state.items.length) {
            if (state.error != null) {
              return InlineErrorStrip(
                error: state.error,
                label: 'more notifications',
                onRetry: notifier.loadMore,
              );
            }
            return const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            );
          }
          final notification = state.items[i];
          return Dismissible(
            // Keyed on the recipient row id, not the index: the list shifts
            // under a delete and an index key would carry the dismissed
            // animation onto whichever row slid up into its place.
            key: ValueKey('notification-${notification.id}'),
            direction: DismissDirection.endToStart,
            background: _deleteBackground(context),
            // Removal is confirmed by the *server* before the row leaves the
            // list, so `confirmDismiss` does the delete and then always answers
            // false — the notifier drops the row itself on success, and on
            // failure the row stays where it is instead of vanishing from a
            // list the server never changed.
            confirmDismiss: (_) async {
              await _delete(notification);
              return false;
            },
            child: _NotificationTile(
              notification: notification,
              onTap: () => _open(notification),
            ),
          );
        },
      ),
    );
  }

  /// The red panel behind a swiped row. Right-to-left only — a left-to-right
  /// swipe on this list means "go back" on iOS.
  Widget _deleteBackground(BuildContext context) => Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        color: AppColors.accent,
        child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
      );

  /// Deletes one row, permanently.
  ///
  /// No undo is offered because none exists: nothing in this API re-creates a
  /// recipient row, so an "Undo" would be a button that cannot keep its word.
  Future<void> _delete(AppNotification n) async {
    try {
      await ref.read(notificationsProvider.notifier).delete(n.id);
      if (!mounted) return;
      context.showSuccessSnack('Notification deleted');
    } on ApiException catch (e) {
      // 404 here means the row is gone or was never theirs — the two are
      // indistinguishable on this API — so the list is re-read rather than
      // guessing which happened.
      if (!mounted) return;
      context.showErrorSnack(e);
      await ref.read(notificationsProvider.notifier).refresh();
    }
  }

  Future<void> _open(AppNotification n) async {
    // Navigation must not depend on the read succeeding — the notifier already
    // reconciles from the server, and a failed mark-read is not worth blocking
    // the customer from opening their order.
    ApiException? readFailure;
    if (!n.isClicked) {
      try {
        // `/clicked`, not `/read`: it stamps `clicked_at` and cascades to
        // `markAsRead()` in one round trip. Marking read alone left the
        // store's click-through figures at zero for every notification it
        // ever sent.
        await ref.read(notificationsProvider.notifier).markClicked(n.id);
      } on ApiException catch (e) {
        // Already logged by ApiClient. The row stays visibly unread, so the
        // failure is never painted as success — but it must not be swallowed
        // in silence either: on a row with no destination the tap would
        // otherwise do nothing at all with no explanation.
        readFailure = e;
      }
    }
    if (!mounted) return;

    final target = _navigableTarget(n.actionUrl);
    if (target != null) {
      context.push(target);
      return;
    }
    if (readFailure != null) context.showErrorSnack(readFailure);
  }

  /// `action_url` as somewhere this app can actually go, or null.
  ///
  /// The field is authored in the Botble admin against the *website's* URL
  /// space, not this app's router — the API docs' own example is `/orders/12`,
  /// which has no route here. Pushing it blind drops the customer on
  /// go_router's "no routes for location" error page, so the path is matched
  /// against the live route table first and simply not followed when it misses.
  String? _navigableTarget(String? raw) {
    if (raw == null || !raw.startsWith('/')) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    return GoRouter.of(context).configuration.findMatch(uri).isError
        ? null
        : raw;
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, required this.onTap});

  final AppNotification notification;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unread = !notification.isRead;

    return ListTile(
      onTap: onTap,
      tileColor: unread ? context.colors.primarySurface : null,
      leading: CircleAvatar(
        backgroundColor: context.colors.primarySoft,
        child: Icon(
          _iconFor(notification.type),
          size: 20,
          color: context.colors.primaryDark,
        ),
      ),
      title: Text(
        notification.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: context.text.title,
      ),
      subtitle: Text(
        notification.message,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: context.text.bodySm,
      ),
      trailing: unread
          ? const CircleAvatar(radius: 4, backgroundColor: AppColors.primary)
          : null,
    );
  }

  static IconData _iconFor(String? type) => switch (type) {
        'order' => Icons.receipt_long_rounded,
        'promotion' || 'offer' => Icons.local_offer_rounded,
        'delivery' => Icons.local_shipping_rounded,
        _ => Icons.notifications_rounded,
      };
}

import 'dart:math' as math;

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../data/models/order.dart';
import '../../providers/checkout_provider.dart';
import '../../providers/order_provider.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/state_views.dart';
import '../../widgets/summary_row.dart';
import '../../widgets/surfaces.dart';
import '../orders/orders_screen.dart';

/// The receipt for an order that has been **proved paid**.
///
/// ## Why this screen takes an id and makes a request
///
/// It used to take nothing and say "Order placed!" over static confetti, which
/// was accurate only because no order was ever placed. Now it names a real one,
/// and two of the three things it shows can only come from
/// `GET /ecommerce/orders/{id}`:
///
///   * **the customer-facing code** (`SF10001287`) — `ec_orders.code` is
///     generated in `Order::booted()` and appears in *no* checkout or
///     confirm-payment response. It is the only string the customer can quote
///     to support, and it is opaque: never parsed, never regexed, never
///     prefixed with a `#` (the legacy generation already carries one, which is
///     what [Order.displayCode] handles);
///   * **the total** — rendered by the server as `amount_formatted`
///     ("₹9,034.20") and displayed verbatim. Nothing on this screen adds
///     anything up. The app's own arithmetic is exactly what this slice existed
///     to stop: the figure here is the one the customer's card was charged,
///     including whatever the server did with the shipping amount and any
///     free-shipping coupon that overrode it.
///
/// ## Reaching it at all is the guarantee
///
/// Nothing routes here except [CheckoutFlowNotifier] settling an order, and it
/// only settles on `payment_status == "completed"`. That matters because every
/// weaker signal in this flow is a false positive: `HTTP 200 + success: true`
/// on confirm-payment is emitted for failed payments too, `is_finished` is set
/// unconditionally with no payment check, and `order.status == "processing"`
/// says nothing about money.
///
/// A failure to *read* the order is therefore not a failure of the order. The
/// congratulation stays on screen and only the detail block retries.
class OrderSuccessScreen extends ConsumerStatefulWidget {
  const OrderSuccessScreen({super.key, required this.orderId});

  /// The numeric `ec_orders.id` from the checkout response.
  final int orderId;

  @override
  ConsumerState<OrderSuccessScreen> createState() => _OrderSuccessScreenState();
}

class _OrderSuccessScreenState extends ConsumerState<OrderSuccessScreen> {
  late final ConfettiController _confetti;

  @override
  void initState() {
    super.initState();
    _confetti = ConfettiController(duration: const Duration(seconds: 2))..play();
  }

  @override
  void dispose() {
    _confetti.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(orderDetailProvider(widget.orderId));

    return PopScope(
      // Back must not return to checkout: that screen is built around a cart
      // that no longer exists, and its primary action creates orders.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/');
      },
      child: Scaffold(
        backgroundColor: context.colors.surface,
        body: Stack(
          alignment: Alignment.topCenter,
          children: [
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 108,
                        height: 108,
                        decoration: BoxDecoration(
                          color: context.colors.primarySoft,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_circle_rounded,
                          color: AppColors.primary,
                          size: 72,
                        ),
                      ),
                      AppSpacing.vLg,
                      Text(
                        'Order placed!',
                        style: context.text.display,
                        textAlign: TextAlign.center,
                      ),
                      AppSpacing.vSm,
                      Text(
                        'Thank you for shopping with Trueway Farms.\n'
                        'Your organic order is being prepared.',
                        style: context.text.body,
                        textAlign: TextAlign.center,
                      ),
                      AppSpacing.vLg,
                      detail.when(
                        loading: () => const _DetailSkeleton(),
                        error: (error, _) => _unreadable(context, error),
                        data: (order) => _OrderCard(order: order),
                      ),
                      AppSpacing.vXl,
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          key: const Key('order-success-view-order'),
                          onPressed: () =>
                              context.push('/order/${widget.orderId}'),
                          child: const Text('View order'),
                        ),
                      ),
                      AppSpacing.vXs,
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          key: const Key('order-success-continue'),
                          onPressed: () => context.go('/'),
                          child: const Text('Continue shopping'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ConfettiWidget(
              confettiController: _confetti,
              blastDirection: math.pi / 2,
              emissionFrequency: 0.05,
              numberOfParticles: 20,
              gravity: 0.2,
              colors: [
                AppColors.primary,
                AppColors.accent,
                AppColors.primaryLight,
                context.colors.savings,
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The order is paid; the app just cannot read it back yet.
  ///
  /// Deliberately not [AppErrorView]: that is the full-screen "this failed"
  /// treatment, and nothing about the order failed. The one fact the customer
  /// needs while the read is broken is the numeric id, which is enough for
  /// support to find the order.
  Widget _unreadable(BuildContext context, Object error) => AppCard(
        key: const Key('order-success-unreadable'),
        padding: const EdgeInsets.all(AppSpacing.md),
        color: context.colors.surfaceAlt,
        child: Column(
          children: [
            Text(
              'Your payment went through. We could not load the order details '
              'just now.',
              style: context.text.bodySm,
              textAlign: TextAlign.center,
            ),
            AppSpacing.vXs,
            // No identifier here. The one the customer is given anywhere else
            // is the order code, and this branch exists precisely because the
            // order could not be read — so the code is what is missing. The
            // numeric id used to stand in for it; it is an internal key that
            // appears on no invoice, no email and no other screen, so showing
            // it only invites a customer to quote a number support does not
            // ask for. The order reaches Orders with its code either way.
            AppSpacing.vXs,
            TextButton(
              key: const Key('order-success-retry'),
              onPressed: () =>
                  ref.invalidate(orderDetailProvider(widget.orderId)),
              child: const Text('Try again'),
            ),
          ],
        ),
      );
}

/// Code, date and total — all three read off the server's own response.
///
/// Total only, deliberately: no breakdown. See the note at the total row.
class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) => AppCard(
        key: const Key('order-success-summary'),
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          children: [
            Text('Order number', style: context.text.caption),
            AppSpacing.gapXxs,
            Text(
              // Opaque. Two incompatible formats coexist in this shop's data
              // and `displayCode` is the only safe rendering of both.
              order.displayCode,
              key: const Key('order-success-code'),
              style: context.text.h3,
              textAlign: TextAlign.center,
            ),
            if (order.createdAt != null) ...[
              AppSpacing.gapXxs,
              Text(
                'Placed ${formatOrderDate(order.createdAt!)}',
                style: context.text.caption,
              ),
            ],
            const Divider(height: 22),
            // `amount_formatted`, exactly as the server rendered it. This is
            // the charged figure — not the button's estimate, and never
            // re-derived from the parts.
            SummaryRow(
              'Total paid',
              order.amountDisplay,
              key: const Key('order-success-total'),
              bold: true,
            ),
            // No shipping row. This screen exists to confirm one number —
            // what was charged — and a second figure under it invites the
            // arithmetic ("so the goods were 628?") that a confirmation screen
            // is the wrong place to start. The full bill, shipping included,
            // is on the order itself, behind the "View order" button below.
            AppSpacing.vXs,
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.verified_rounded,
                  size: 16,
                  color: context.colors.savings,
                ),
                AppSpacing.hXs,
                Flexible(
                  child: Text(
                    order.paymentStatus.label.isEmpty
                        ? 'Payment confirmed'
                        : 'Payment ${order.paymentStatus.label.toLowerCase()}',
                    style: context.text.caption,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) => const AppCard(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Column(
          children: [
            SkeletonBox(height: 12, width: 100, radius: AppRadius.sm),
            AppSpacing.vXs,
            SkeletonBox(height: 18, width: 160, radius: AppRadius.sm),
            AppSpacing.vSm,
            SkeletonBox(height: 14, radius: AppRadius.sm),
          ],
        ),
      );
}

// ===========================================================================
// Launch-time recovery
// ===========================================================================

/// Runs the pending-order reconciliation once per app start, and acts on it.
///
/// Wrapped around the root route rather than living inside a screen, because
/// the thing it recovers from is the app not being here: a crash, a force-quit
/// or a kill between `POST /checkout/cart/{id}` and a confirmed payment leaves
/// an order that **no read endpoint can find** — both order routes filter
/// `is_finished = 1` — so the only handle on it is the journal on disk, and the
/// only moment guaranteed to come around is startup.
///
/// It renders [child] unchanged. All it adds is:
///
///   * watching [pendingOrderRecoveryProvider], which is what starts the pass;
///   * routing to this screen when the order turns out to have been paid;
///   * a one-time SnackBar for the outcomes that are only news
///     ("your last order wasn't paid for, so it was not placed").
///
/// Deliberately silent while checking. The overwhelmingly common case is no
/// record at all, and a splash that flashed a spinner for it would make every
/// launch feel slower for a state nobody is in.
class PendingOrderRecoveryGate extends ConsumerWidget {
  const PendingOrderRecoveryGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<PendingRecoveryState>(pendingOrderRecoveryProvider, (_, next) {
      final message = next.message;
      if (message == null) return;

      if (next.phase == PendingRecoveryPhase.paid && next.orderId != null) {
        context.push('/order-success/${next.orderId}');
      } else {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 8),
            action: next.orderId == null
                ? null
                : SnackBarAction(
                    label: 'View',
                    onPressed: () => context.push('/order/${next.orderId}'),
                  ),
          ),
        );
      }

      // Consumed last, so the news cannot be shown twice on a rebuild. Setting
      // it re-enters this listener with a null message, which returns above.
      ref.read(pendingOrderRecoveryProvider.notifier).acknowledge();
    });

    // Reading it here — not just listening — is what constructs the notifier
    // and therefore starts the pass.
    ref.watch(pendingOrderRecoveryProvider);
    return child;
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_icons.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/utils/responsive.dart';
import '../../../core/design_system/theme_context.dart';
import '../../providers/wishlist_provider.dart';
import '../../widgets/product_grid.dart';
import '../../widgets/state_views.dart';
import '../../widgets/app_message.dart';

/// Saved products.
///
/// Deliberately has **no auth gate**. The wishlist endpoints identify a list
/// purely by an opaque id in the path and never read the bearer token, so a
/// signed-out visitor keeps a real list that survives login — see
/// `WishlistRepository`. Asking someone to sign in here would be inventing a
/// restriction the server does not have.
///
/// Removal is the heart on each tile: it is already the control that put the
/// item here, it is the one the customer will reach for, and routing it through
/// [WishlistNotifier.toggle] means removal gets the same server reconciliation
/// as saving. A per-tile overlay button would have needed [ProductGrid] to grow
/// a slot for it, and would have given the same action two different affordances
/// on the same screen.
class WishlistScreen extends ConsumerStatefulWidget {
  const WishlistScreen({super.key, this.showBack = true});

  final bool showBack;

  @override
  ConsumerState<WishlistScreen> createState() => _WishlistScreenState();
}

class _WishlistScreenState extends ConsumerState<WishlistScreen> {
  /// True while [WishlistNotifier.clear] is in flight.
  ///
  /// Clearing is not one request: there is no bulk-delete route, so the
  /// repository walks the list removing one product at a time. That is seconds
  /// of work on a list of any size, and every one of those calls is a mutation
  /// that *destroys the stored row before re-storing it* — so a heart tapped
  /// half way through would interleave with the loop on a list that is being
  /// rebuilt underneath it. The grid therefore blocks and says what is
  /// happening, rather than sitting there fully interactive and apparently idle.
  bool _clearing = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(wishlistProvider);

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        automaticallyImplyLeading: widget.showBack,
        title: const Text('Wishlist'),
        actions: [
          // Always present, in every state. [AppErrorView] only offers its own
          // retry for errors it judges retryable, so a wishlist left unreadable
          // by a 404 or a validation failure would otherwise be a dead end with
          // no way to re-read it. Re-reading the list is a plain GET and is
          // always worth offering.
          IconButton(
            tooltip: 'Refresh',
            onPressed: state.loading || _clearing ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (state.entries.isNotEmpty)
            IconButton(
              tooltip: 'Clear wishlist',
              onPressed: state.loading || _clearing ? null : _confirmClear,
              icon: const Icon(AppIcons.trash),
            ),
        ],
      ),
      body: Stack(
        children: [
          _Body(state: state),
          if (_clearing)
            Positioned.fill(
              child: AbsorbPointer(
                child: ColoredBox(
                  color: context.colors.background.withValues(alpha: 0.78),
                  child: const LoadingView(label: 'Clearing your wishlist…'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _refresh() => ref.read(wishlistProvider.notifier).refresh();

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear wishlist?'),
        content: const Text(
          'Every saved item will be removed. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _clearing = true);
    try {
      await ref.read(wishlistProvider.notifier).clear();
      if (mounted) context.showSuccessSnack(_clearedMessage());
    } catch (e) {
      // Catches everything, not just ApiException. Clearing is a loop of
      // mutations whose responses are parsed client-side, so a malformed
      // envelope throws a plain TypeError — and an `on ApiException` clause let
      // that escape as an unhandled async error, leaving a half-cleared list
      // with no message at all. `showErrorSnack` takes `Object?` and routes it
      // through ErrorPresenter, so a non-ApiException never leaks its
      // toString() to the customer.
      //
      // The notifier has already adopted the repository's re-read, so the grid
      // below is showing whatever actually survived — this only reports it.
      if (mounted) context.showErrorSnack(e, context: 'wishlist.clear');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  /// Rows whose catalogue product has been deleted cannot be removed — there is
  /// no id left to send — so a "clear" that leaves them behind must not claim
  /// the list is empty. The customer's own count would disagree.
  String _clearedMessage() {
    final left = ref.read(wishlistProvider).unavailableCount;
    if (left == 0) return 'Wishlist cleared';
    return left == 1
        ? 'Cleared. 1 unavailable item could not be removed.'
        : 'Cleared. $left unavailable items could not be removed.';
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.state});

  final WishlistState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Nothing has come back yet: the grid's own geometry, so the page does not
    // jump when the list lands.
    if (state.loading && !state.isKnown) return const ProductGridSkeleton();

    // Unknown, not empty. Either the read failed, or a mutation failed and the
    // repository's re-read failed too — in which case the server may have just
    // destroyed the list. Rendering the pre-failure items here would show saved
    // products that no longer exist.
    if (!state.isKnown) {
      return AppErrorView(
        error: state.error,
        onRetry: () => ref.read(wishlistProvider.notifier).refresh(),
      );
    }

    return Column(
      children: [
        // A mutation failed but we still know what the list holds. The grid
        // stays usable; the failure is not swallowed.
        if (state.error != null)
          InlineErrorStrip(
            error: state.error,
            label: 'your wishlist',
            onRetry: () => ref.read(wishlistProvider.notifier).refresh(),
          ),
        // Only alongside rows that *can* be shown. When every remaining row is
        // a ghost there is nothing for the note to sit above, and pairing it
        // with the empty view produced a flat contradiction: "3 saved items are
        // no longer sold" directly over the headline "Nothing saved yet". The
        // empty view states the same fact itself in that case.
        if (state.unavailableCount > 0 && state.entries.isNotEmpty)
          _UnavailableNote(count: state.unavailableCount),
        Expanded(
          child: state.entries.isEmpty
              ? _Empty(
                  // An empty list that follows a failure is not the same thing
                  // as an empty list nobody has filled in yet. A failed mutation
                  // on this API can wipe the list server-side, and telling
                  // someone whose saved items were just destroyed that they
                  // have "nothing saved yet" reads as if they never saved
                  // anything at all.
                  afterFailure: state.error != null,
                  // ...and neither is a list the server still counts but whose
                  // every product has been deleted from the catalogue.
                  unavailable: state.unavailableCount,
                  onRefresh: () => ref.read(wishlistProvider.notifier).refresh(),
                )
              : Column(
                  children: [
                    _CountHeader(count: state.count),
                    Expanded(
                      child: ProductGrid(
                        products: state.products,
                        // Three across, like the home feed. A saved list is a
                        // list to scan, not to browse — the customer already
                        // knows what is on it — so more of it per screen beats
                        // a larger photo. The card adapts at this tile width
                        // (its ADD drops to an icon), and the matching aspect
                        // keeps the photo roughly square.
                        columns: Responsive.homeProductColumns(
                          MediaQuery.sizeOf(context).width,
                        ),
                        aspectRatio: Responsive.homeProductAspect(
                          MediaQuery.sizeOf(context).width,
                        ),
                        onRefresh: () =>
                            ref.read(wishlistProvider.notifier).refresh(),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Count plus the removal hint. The heart is the remove button on this screen,
/// so it is worth saying once rather than leaving it to be discovered.
class _CountHeader extends StatelessWidget {
  const _CountHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          0,
        ),
        child: Row(
          children: [
            Text(
              count == 1 ? '1 item saved' : '$count items saved',
              style: context.text.bodySm,
            ),
            const Spacer(),
            Icon(AppIcons.heart, fill: 1, size: 13, color: context.colors.faint),
            AppSpacing.hXs,
            Text('Tap to remove', style: context.text.caption),
          ],
        ),
      );
}

/// Rows the server counts but that carry no product any more.
///
/// They cannot be rendered and cannot be removed — the catalogue product is
/// gone, so there is no id left to send. Saying so beats letting the customer's
/// count silently disagree with what they can see.
class _UnavailableNote extends StatelessWidget {
  const _UnavailableNote({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          0,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: context.colors.surfaceAlt,
            borderRadius: AppRadius.rMd,
            border: Border.all(color: context.colors.line),
          ),
          child: Row(
            children: [
              Icon(AppIcons.info, size: 18, color: context.colors.muted),
              AppSpacing.hSm,
              Expanded(
                child: Text(
                  count == 1
                      ? '1 saved item is no longer sold and cannot be shown.'
                      : '$count saved items are no longer sold and cannot be shown.',
                  style: context.text.caption,
                ),
              ),
            ],
          ),
        ),
      );
}

/// Empty state, made pull-to-refresh-able: the list is shared by identifier, so
/// it can change on another device while this screen is open.
class _Empty extends StatelessWidget {
  const _Empty({
    required this.onRefresh,
    this.afterFailure = false,
    this.unavailable = 0,
  });

  final Future<void> Function() onRefresh;

  /// Whether this emptiness is the result of a failed call rather than a list
  /// nobody has filled in yet. The [InlineErrorStrip] above carries the server's
  /// own message; this only stops the headline from contradicting it.
  final bool afterFailure;

  /// Rows the server still counts whose catalogue product has been deleted.
  ///
  /// When this is the *whole* list, the grid is empty but the list is not, and
  /// "Nothing saved yet" is simply false — the customer saved those items and
  /// the server still holds the rows. It ranks above [afterFailure] because it
  /// explains the emptiness precisely, where "the server reports nothing saved"
  /// would be another wrong sentence.
  final int unavailable;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: onRefresh,
        child: LayoutBuilder(
          builder: (_, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: EmptyView(
                icon: AppIcons.heart,
                title: _title,
                subtitle: _subtitle,
                action: SizedBox(
                  width: 220,
                  child: ElevatedButton(
                    onPressed: () => context.push('/products'),
                    child: const Text('Browse products'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  String get _title {
    if (unavailable > 0) return 'Nothing left to show';
    return afterFailure ? 'Your wishlist is empty' : 'Nothing saved yet';
  }

  String get _subtitle {
    if (unavailable > 0) {
      return unavailable == 1
          ? 'The one item on your list is no longer sold, so it cannot be '
              'shown or removed.'
          : 'All $unavailable items on your list are no longer sold, so they '
              'cannot be shown or removed.';
    }
    return afterFailure
        ? 'That last change did not go through, and the server now reports '
            'nothing saved. Pull down to check again.'
        : 'Tap the heart on any product to keep it here.';
  }
}

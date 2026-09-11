import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../data/models/review.dart';
import '../../providers/review_provider.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/state_views.dart';
import '../../widgets/review_tile.dart';
import '../../widgets/surfaces.dart';
import '../../widgets/app_message.dart';

/// The customer's reviews, in two tabs.
///
/// **To review** is derived, not fetched — no endpoint answers "what could I
/// review?", so it is assembled from completed orders minus what has already
/// been reviewed. See [reviewableProductsProvider].
///
/// **Reviewed** is the real list, and each row shows whether the server has
/// published it. A review is created as `pending` and only appears on the
/// product page once approved, so a customer who cannot find their review needs
/// that status to make sense of it.
class MyReviewsScreen extends ConsumerStatefulWidget {
  const MyReviewsScreen({super.key});

  @override
  ConsumerState<MyReviewsScreen> createState() => _MyReviewsScreenState();
}

class _MyReviewsScreenState extends ConsumerState<MyReviewsScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 400) ref.read(myReviewsProvider.notifier).loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(myReviewsProvider);
    final pending = ref.watch(reviewableProductsProvider);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('My reviews'),
          bottom: TabBar(
            tabs: [
              Tab(text: _tabLabel('To review', pending.valueOrNull?.length)),
              Tab(
                text: _tabLabel(
                  'Reviewed',
                  state.loading ? null : state.items.length,
                ),
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _PendingTab(products: pending),
            RefreshIndicator(
              color: AppColors.primary,
              onRefresh: () => ref.read(myReviewsProvider.notifier).refresh(),
              child: _body(context, state),
            ),
          ],
        ),
      ),
    );
  }

  /// Counts only appear once known — "Reviewed (0)" while the list is still
  /// loading states something false.
  static String _tabLabel(String text, int? count) =>
      count == null ? text : '$text ($count)';

  Widget _body(BuildContext context, MyReviewsState state) {
    if (state.loading) return const _ReviewListSkeleton();

    if (state.error != null && state.isEmpty) {
      return AppErrorView(
        error: state.error!,
        onRetry: () => ref.read(myReviewsProvider.notifier).load(),
      );
    }

    if (state.isEmpty) {
      return ListView(
        // Must scroll, or pull-to-refresh cannot start on an empty list.
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          EmptyView(
            title: 'No reviews yet',
            subtitle: 'Reviews you write will show up here.',
            icon: Icons.rate_review_rounded,
          ),
        ],
      );
    }

    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.gutter),
      itemCount: state.items.length + (state.loadingMore ? 1 : 0),
      itemBuilder: (_, i) {
        if (i >= state.items.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final review = state.items[i];
        return _MyReviewRow(
          review: review,
          deleting: state.deleting.contains(review.id),
          onDelete: () => _confirmDelete(review),
        );
      },
    );
  }

  /// Deleting is irreversible — there is no undo route — so it asks first.
  Future<void> _confirmDelete(Review review) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this review?'),
        content: const Text(
          'It will be removed from the product page. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final failure = await ref.read(myReviewsProvider.notifier).delete(review.id);
    if (!mounted) return;
    if (failure == null) {
      context.showSuccessSnack('Review deleted');
    } else {
      context.showAlertSnack(failure);
    }
  }
}

/// Products bought and not yet reviewed.
class _PendingTab extends ConsumerWidget {
  const _PendingTab({required this.products});

  final AsyncValue<List<ReviewableProduct>> products;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: () async => ref.invalidate(reviewableProductsProvider),
      child: products.when(
        loading: () => const _ReviewListSkeleton(),
        error: (e, __) => AppErrorView(
          error: e,
          onRetry: () => ref.invalidate(reviewableProductsProvider),
        ),
        data: (items) {
          if (items.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 120),
                EmptyView(
                  title: 'Nothing waiting',
                  subtitle: "You've reviewed everything from your recent "
                      'orders. Thank you!',
                  icon: Icons.done_all_rounded,
                ),
              ],
            );
          }

          return ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.gutter),
            itemCount: items.length,
            itemBuilder: (_, i) => _PendingRow(product: items[i]),
          );
        },
      ),
    );
  }
}

class _PendingRow extends StatelessWidget {
  const _PendingRow({required this.product});

  final ReviewableProduct product;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if ((product.image ?? '').isNotEmpty) ...[
              SizedBox(
                width: 44,
                height: 44,
                child: AppNetworkImage(
                  url: product.image!,
                  borderRadius: AppRadius.rSm,
                  fit: BoxFit.cover,
                ),
              ),
              AppSpacing.hSm,
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.name,
                    style: context.text.bodySm,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  // No order line. `GET /reviews/reviewable` returns
                  // `order_id` and no code, and a bare numeric id is not an
                  // identifier this shop shows its customers — they are given
                  // `SF…` codes everywhere else. The product name above is
                  // what makes the row recognisable anyway.
                ],
              ),
            ),
            AppSpacing.hSm,
            OutlinedButton(
              key: Key('review-now-${product.id}'),
              // The theme's OutlinedButton carries
              // `minimumSize: Size.fromHeight(54)`, and `Size.fromHeight` means
              // `Size(double.infinity, 54)`. A Row gives its non-flex children
              // an unbounded width, so that minimum resolves to an *infinite*
              // width — an invalid constraint that fails layout and renders the
              // whole tab blank, tab count and all.
              //
              // Bounded here rather than in the theme: the infinite default is
              // what makes a button stretch when it is the only thing in a
              // column, which most of the app relies on. Same fix as the
              // Account screen's sign-out button.
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: () => context.push(
                '/product/${product.id}/review'
                '?name=${Uri.encodeComponent(product.name)}'
                '&slug=${Uri.encodeComponent(product.slug)}',
              ),
              child: const Text('Rate'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MyReviewRow extends StatelessWidget {
  const _MyReviewRow({
    required this.review,
    required this.deleting,
    required this.onDelete,
  });

  final Review review;
  final bool deleting;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final product = review.product;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        // Opens the review, not the product. Tapping a row in a list of *your
        // reviews* and landing on a product page loses the thing you tapped —
        // the comment is clamped here and the photos are not shown at all, so
        // there was no way to read your own review back. The product is still
        // one tap away, from inside the sheet.
        key: Key('my-review-${review.id}'),
        onTap: () => showMyReviewSheet(context, review),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ((product?.image ?? '').isNotEmpty) ...[
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: AppNetworkImage(
                      url: product!.image!,
                      borderRadius: AppRadius.rSm,
                      fit: BoxFit.cover,
                    ),
                  ),
                  AppSpacing.hSm,
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product?.name ?? 'Product',
                        style: context.text.bodySm,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      _Stars(count: review.star),
                    ],
                  ),
                ),
                if (deleting)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    onPressed: onDelete,
                    tooltip: 'Delete review',
                    icon: Icon(Icons.delete_outline_rounded,
                        color: context.colors.muted,),
                  ),
              ],
            ),
            AppSpacing.vXs,
            _ReviewStatusChip(review: review),
            if (review.comment.isNotEmpty) ...[
              AppSpacing.vSm,
              Text(
                review.comment,
                style: context.text.bodySm,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (review.createdAtRelative.isNotEmpty) ...[
              AppSpacing.vXs,
              Text(
                review.createdAtRelative,
                style: context.text.caption.copyWith(color: context.colors.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Whether the server has published this review.
///
/// A review is created as `pending` and only appears on the product page once
/// an admin approves it. Without this, a customer who wrote a review and cannot
/// find it has no way to tell whether it failed or is simply waiting.
///
/// The **label is the server's** (`status_label`) with the token as a fallback,
/// so an admin adding a third status still reads as words rather than a slug.
class _ReviewStatusChip extends StatelessWidget {
  const _ReviewStatusChip({required this.review});

  final Review review;

  @override
  Widget build(BuildContext context) {
    final (icon, colour, fallback) = review.isPublished
        ? (Icons.check_circle_rounded, context.colors.primaryDark, 'Published')
        : review.isPending
            ? (Icons.schedule_rounded, AppColors.accent, 'Awaiting approval')
            : (Icons.info_outline_rounded, context.colors.muted, 'Not shown');

    final label = review.statusLabel.trim().isNotEmpty
        ? review.statusLabel
        : fallback;

    return Row(
      children: [
        Icon(icon, size: 14, color: colour),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: context.text.caption.copyWith(color: colour),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (review.isPending) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '· not on the product page yet',
              style:
                  context.text.caption.copyWith(color: context.colors.muted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}

class _Stars extends StatelessWidget {
  const _Stars({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            i <= count ? Icons.star_rounded : Icons.star_border_rounded,
            size: 15,
            color: i <= count ? AppColors.accent : context.colors.line,
          ),
      ],
    );
  }
}

class _ReviewListSkeleton extends StatelessWidget {
  const _ReviewListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      itemCount: 5,
      itemBuilder: (_, __) => const Padding(
        padding: EdgeInsets.only(bottom: 10),
        child: AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(height: 14, width: 160, radius: AppRadius.sm),
              SizedBox(height: 8),
              SkeletonBox(height: 12, width: 90, radius: AppRadius.sm),
              SizedBox(height: 10),
              SkeletonBox(height: 12, width: 220, radius: AppRadius.sm),
            ],
          ),
        ),
      ),
    );
  }
}


/// One of the customer's own reviews, in full.
///
/// Everything the row has to leave out: the whole comment rather than three
/// clamped lines, every photo and video, the store's reply, and whether it is
/// still waiting for approval.
///
/// Built from the [Review] the list already holds — there is no endpoint that
/// returns a single review, and there is nothing here the list did not already
/// download.
Future<void> showMyReviewSheet(BuildContext context, Review review) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: context.colors.surface,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      builder: (_) => _MyReviewSheet(review: review),
    );

class _MyReviewSheet extends StatelessWidget {
  const _MyReviewSheet({required this.review});

  final Review review;

  @override
  Widget build(BuildContext context) {
    final product = review.product;

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.md,
              ),
              children: [
                if (product != null) _ProductHeader(product: product),
                // Not compact: the comment runs to its full length and the media
                // strip is shown, each thumbnail opening the full-screen viewer.
                ReviewTile(review: review, isMine: true),
              ],
            ),
          ),
          if (product != null && product.slug.isNotEmpty) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  key: const Key('my-review-open-product'),
                  onPressed: () {
                    Navigator.pop(context);
                    context.push('/product/${product.slug}');
                  },
                  child: const Text('View product'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The product the review is about, at the top of the sheet.
class _ProductHeader extends StatelessWidget {
  const _ProductHeader({required this.product});

  final ReviewProduct product;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Row(
          children: [
            if ((product.image ?? '').isNotEmpty) ...[
              SizedBox(
                width: 44,
                height: 44,
                child: AppNetworkImage(
                  url: product.image!,
                  borderRadius: AppRadius.rSm,
                ),
              ),
              AppSpacing.hSm,
            ],
            Expanded(
              child: Text(
                product.name,
                style: context.text.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
}

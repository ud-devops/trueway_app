import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../core/utils/responsive.dart';
import '../../../data/models/category_model.dart';
import '../../providers/home_providers.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/state_views.dart';

/// Categories tab: a browse index rather than a product list.
///
/// Each top-level category becomes a section heading with its subcategories as
/// a grid of tiles beneath it. Tapping a tile opens `CategoryBrowseScreen`,
/// which pairs a rail of that tile's siblings with its products.
///
/// Six of the ten top-level categories currently have no children, so a strict
/// "heading + children" layout would render six empty sections. Those are
/// collected into a single trailing section instead, which keeps every category
/// reachable without a page of lone tiles under their own headings.
class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Categories'),
      ),
      body: categories.when(
        loading: () => const LoadingView(),
        error: (e, __) => AppErrorView(
          error: e,
          onRetry: () => ref.invalidate(categoriesProvider),
        ),
        // Filtered the same way the home strip is, so the two cannot disagree
        // about which categories this shop has. A category listed here and
        // missing from the strip — or the reverse — reads as a bug even when
        // both are individually defensible.
        data: (roots) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(categoriesProvider),
          child: _Index(roots: categoriesWithProducts(roots)),
        ),
      ),
    );
  }
}

class _Index extends StatelessWidget {
  const _Index({required this.roots});

  final List<Category> roots;

  @override
  Widget build(BuildContext context) {
    if (roots.isEmpty) {
      return const EmptyView(
        title: 'No categories yet',
        subtitle: 'Check back soon',
        icon: Icons.grid_view_rounded,
      );
    }

    // Children are filtered too, not just the roots. Otherwise a section keeps
    // its empty sub-categories — `Wheat & Wheat Flour` lists `Wheat Flour` and
    // `Wheat` alongside `Sona Moti Wheat` while only the last has anything in
    // it, and two of the three tiles are dead ends.
    final withTiles = [
      for (final root in roots) (root, categoriesWithProducts(root.children)),
    ];

    // A root whose children are ALL empty is not an empty section — it is a
    // standalone tile. Its own products are still real (that is why it survived
    // the root filter), so it moves across rather than rendering a heading with
    // nothing under it.
    final grouped = withTiles.where((e) => e.$2.isNotEmpty).toList();
    final standalone = withTiles
        .where((e) => e.$2.isEmpty)
        .map((e) => e.$1)
        .toList();

    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      children: [
        for (final (root, tiles) in grouped)
          _Section(title: root.name, tiles: tiles),
        if (standalone.isNotEmpty)
          _Section(
            // These are top-level categories in their own right; the heading
            // only stops them reading as children of the section above.
            title: grouped.isEmpty ? 'All categories' : 'More categories',
            tiles: standalone,
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.tiles});

  final String title;
  final List<Category> tiles;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.lg,
            AppSpacing.gutter,
            AppSpacing.sm,
          ),
          child: Text(title, style: context.text.h3),
        ),
        GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          // The page is one scroll view; each grid sizes to its own content.
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: Responsive.categoryColumns(width),
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.sm,
            // Taller than wide: an image with up to two lines of label under it.
            childAspectRatio: 0.78,
          ),
          itemCount: tiles.length,
          itemBuilder: (_, i) => _CategoryTile(category: tiles[i]),
        ),
      ],
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.category});

  final Category category;

  @override
  Widget build(BuildContext context) {
    final image = category.displayImage;

    return InkWell(
      onTap: () => context.push('/category/${category.id}'),
      borderRadius: AppRadius.rLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: context.colors.primarySurface,
                borderRadius: AppRadius.rLg,
              ),
              // No inner padding when there is a photo: the image is clipped to
              // the tile's own radius and fills it, rather than sitting as a
              // smaller square inside a rounded box.
              clipBehavior: Clip.antiAlias,
              child: image == null
                  ? Icon(
                      Icons.eco_rounded,
                      color: context.colors.primaryDark,
                      size: 28,
                    )
                  : AppNetworkImage(url: image, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            category.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: context.text.caption.copyWith(color: context.colors.ink),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/app_typography.dart';
import '../../../core/utils/responsive.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../data/models/category_model.dart';
import '../../providers/home_providers.dart';
import '../../providers/catalog_filter_provider.dart';
import '../../providers/products_provider.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/product_grid.dart';
import '../../widgets/product_filter_sheet.dart';
import '../../widgets/state_views.dart';

const _sortOptions = <({String label, String? value})>[
  (label: 'Recommended', value: null),
  (label: 'Price: Low to High', value: 'price_asc'),
  (label: 'Price: High to Low', value: 'price_desc'),
  (label: 'Name: A to Z', value: 'name_asc'),
  (label: 'Newest first', value: 'date_desc'),
];

/// Products within one branch of the category tree: a rail of sibling
/// categories on the left, the selected category's products on the right.
///
/// Reached by tapping a tile on [CategoriesScreen]. The rail holds the tapped
/// category's *siblings* — the other children of its parent — so a customer who
/// lands on "Wheat Flour" can move to "Wheat" or "Sona Moti Wheat" without
/// going back. A category with no parent in the tree gets the root list
/// instead, which keeps childless top-level categories navigable.
class CategoryBrowseScreen extends ConsumerStatefulWidget {
  const CategoryBrowseScreen({super.key, required this.categoryId});

  final int categoryId;

  @override
  ConsumerState<CategoryBrowseScreen> createState() =>
      _CategoryBrowseScreenState();
}

class _CategoryBrowseScreenState extends ConsumerState<CategoryBrowseScreen> {
  /// Selected rail entry. Seeded from the route and never null here — unlike
  /// the old all-categories screen there is no "All" pseudo-entry, because the
  /// rail is already scoped to one branch.
  late int _catId = widget.categoryId;

  String? _sort;
  FilterSelection _filters = const FilterSelection();
  final _scroll = ScrollController();

  static const double _railWidth = 88;

  /// Every filter goes into the query, so a change refetches from the server.
  /// In-stock joins them now that `in_stock=1` exists, which is what lets paging
  /// stay on — see [FilterSelection.inStockOnly] for the local pass that still
  /// backs it up.
  ProductQuery get _query => ProductQuery(
        categoryId: _catId,
        sort: _sort,
        attributeIds: _filters.sortedAttributeIds,
        tagIds: _filters.sortedTagIds,
        brandIds: _filters.sortedBrandIds,
        ratings: _filters.ratingTokens,
        discounts: _filters.sortedDiscounts,
        collectionIds: _filters.sortedCollectionIds,
        minPrice: _filters.minPrice,
        maxPrice: _filters.maxPrice,
        inStockOnly: _filters.inStockOnly,
      );

  /// Width the grid actually gets, once the rail has taken its share. Deriving
  /// the geometry from this instead of the screen width is what lets the grid
  /// go to 3 columns on a tablet — it used to be pinned at 2 for every device.
  double get _contentWidth => MediaQuery.sizeOf(context).width - _railWidth;

  int get _gridColumns => Responsive.productColumns(_contentWidth);

  /// A notch below the full-width aspect: these tiles are narrower, and the
  /// card's text block (name, pack size, unit price, rating) does not shrink
  /// with them, so it needs the extra vertical room.
  double get _gridAspect => Responsive.productAspect(_contentWidth) - 0.03;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
        ref.read(productsProvider(_query).notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// The rail's contents and the screen title, derived from the tree.
  ///
  /// Returns the siblings of [widget.categoryId] plus the heading to show
  /// above them.
  ({List<Category> siblings, String title}) _branch(List<Category> roots) {
    for (final root in roots) {
      if (root.id == widget.categoryId) {
        // A top-level category: its own children are the natural rail, but the
        // root list is the fallback when it has none (6 of 10 do not).
        return root.hasChildren
            ? (siblings: root.children, title: root.name)
            : (siblings: roots, title: 'Categories');
      }
      if (root.children.any((c) => c.id == widget.categoryId)) {
        return (siblings: root.children, title: root.name);
      }
    }
    return (siblings: roots, title: 'Categories');
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider);

    return Scaffold(
      backgroundColor: context.colors.background,
      body: categories.when(
        loading: () => const _BrowseScaffold(child: LoadingView()),
        error: (e, __) => _BrowseScaffold(
          child: AppErrorView(
            error: e,
            onRetry: () => ref.invalidate(categoriesProvider),
          ),
        ),
        data: (allRoots) {
          // Same filter as the Categories tab and the home strip. Without it
          // the rail offers siblings that lead to an empty grid, and the
          // fallback below could land the screen on one.
          final roots = categoriesWithProducts(allRoots);
          final branch = _branch(roots);
          // A tapped id that is not in the tree (stale deep link) would leave
          // the rail with nothing selected; fall back to the first sibling so
          // the screen still shows products.
          if (!branch.siblings.any((c) => c.id == _catId) &&
              branch.siblings.isNotEmpty) {
            _catId = branch.siblings.first.id;
          }
          return _BrowseScaffold(
            title: branch.title,
            child: Row(
              children: [
                _rail(branch.siblings),
                Expanded(child: _content()),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---- Left category rail ----------------------------------------------
  //
  // No "All" entry: the rail is already scoped to one branch, and an All that
  // silently widened the results would misrepresent where the products came
  // from.
  Widget _rail(List<Category> cats) {
    return Container(
      width: _railWidth,
      color: context.colors.surfaceAlt,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: cats.length,
        itemBuilder: (_, i) => _railItem(
          id: cats[i].id,
          name: cats[i].name,
          imageUrl: cats[i].displayImage,
          index: i,
        ),
      ),
    );
  }

  // `id` is non-null here, unlike the old screen where it doubled as the "All"
  // sentinel.
  Widget _railItem({
    required int id,
    required String name,
    String? imageUrl,
    required int index,
  }) {
    final selected = _catId == id;
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
    return InkWell(
      onTap: () => setState(() => _catId = id),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: selected ? context.colors.surface : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: selected ? AppColors.primary : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Column(
          children: [
            Container(
              width: 50,
              height: 50,
              // No padding when there is a photo: it used to inset the image by
              // 7dp on every side, so the picture floated at its own size in
              // the middle of the disc instead of filling it.
              decoration: BoxDecoration(
                color: selected ? context.colors.primarySoft : context.colors.tileBg(index),
                shape: BoxShape.circle,
              ),
              clipBehavior: Clip.antiAlias,
              child: hasImage
                  ? AppNetworkImage(url: imageUrl, fit: BoxFit.cover)
                  : Icon(Icons.eco_rounded,
                      color: selected ? AppColors.primary : context.colors.tileTint(index), size: 24,),
            ),
            const SizedBox(height: 5),
            Text(
              name,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: context.text.overline.copyWith(
                fontSize: 10,
                color: selected ? context.colors.primaryDark : context.colors.muted,
                fontWeight:
                    selected ? AppTypography.emphasis : AppTypography.regular,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Right content: toolbar + grid -----------------------------------
  Widget _content() {
    final state = ref.watch(productsProvider(_query));
    final items =
        // Belt and braces. The server filter could not be proven on this store
        // — every product in the catalogue is in stock — so the page is swept
        // again rather than trusting a parameter that might be a no-op.
        _filters.inStockOnly
            ? state.items.where((p) => !p.isOutOfStock).toList()
            : state.items;

    return Column(
      children: [
        _toolbar(),
        Expanded(
          child: Builder(builder: (_) {
            if (state.loading) {
              return ProductGridSkeleton(
                itemCount: 4,
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.sm, AppSpacing.xxs, AppSpacing.sm, AppSpacing.md,),
                columns: _gridColumns,
                aspectRatio: _gridAspect,
              );
            }
            if (state.error != null && state.items.isEmpty) {
              return AppErrorView(
                error: state.error,
                onRetry: () => ref.read(productsProvider(_query).notifier).refresh(),
              );
            }
            if (items.isEmpty) {
              return const EmptyView(
                title: 'No products here',
                subtitle: 'Try another category or filter',
                icon: Icons.search_off_rounded,
              );
            }
            return ProductGrid(
              products: items,
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm, AppSpacing.xxs, AppSpacing.sm, AppSpacing.md,),
              // Paging is driven by the server; while the in-stock filter is on
              // we're hiding rows client-side, so "more" is not a promise we
              // can keep.
              // Paging no longer has to be switched off for the in-stock
              // toggle: `in_stock=1` goes to the server, so "more" means more
              // products that are actually in stock.
              showLoadMore: state.hasMore,
              // This grid does not get the full screen width — the 88dp rail
              // takes the left edge — so the screen-width defaults would make
              // the tiles too short for their text. See _railWidth.
              columns: _gridColumns,
              aspectRatio: _gridAspect,
            );
          },),
        ),
      ],
    );
  }

  Widget _toolbar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: _pillButton(
              icon: Icons.tune_rounded,
              label: _filters.isEmpty ? 'Filters' : 'Filters · ${_filters.count}',
              active: !_filters.isEmpty,
              onTap: _openFilters,
            ),
          ),
          AppSpacing.hXs,
          Expanded(
            child: _pillButton(
              icon: Icons.swap_vert_rounded,
              label: _sortOptions.firstWhere((o) => o.value == _sort).label,
              active: _sort != null,
              onTap: _openSort,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pillButton({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.rPill,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active ? context.colors.primarySoft : context.colors.surface,
          borderRadius: AppRadius.rPill,
          border: Border.all(color: active ? AppColors.primary : context.colors.line),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: active ? context.colors.primaryDark : context.colors.muted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.buttonSm.copyWith(
                    color: active ? context.colors.primaryDark : context.colors.body,
                  ),),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSort() async {
    final chosen = await showModalBottomSheet<String?>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Sort by', style: context.text.h3),
            ),
            ..._sortOptions.map((o) => RadioListTile<String?>(
                  value: o.value,
                  // ignore: deprecated_member_use
                  groupValue: _sort,
                  activeColor: AppColors.primary,
                  title: Text(o.label, style: context.text.body),
                  // ignore: deprecated_member_use
                  onChanged: (v) => Navigator.pop(ctx, v),
                ),),
            AppSpacing.vSm,
          ],
        ),
      ),
    );
    if (chosen != _sort) setState(() => _sort = chosen);
  }

  Future<void> _openFilters() async {
    // Facets are scoped to the category being viewed, so the sheet is rebuilt
    // against `_catId` — switching rail entries changes what is on offer.
    final chosen = await showProductFilterSheet(
      context,
      categoryId: _catId,
      selection: _filters,
    );
    if (chosen != null && chosen != _filters) {
      setState(() => _filters = chosen);
    }
  }
}

/// Shared chrome so the loading, error and loaded states keep the same app bar
/// and back button — a bare Scaffold per state made the title flicker in.
class _BrowseScaffold extends StatelessWidget {
  const _BrowseScaffold({required this.child, this.title});

  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: context.colors.background,
        appBar: AppBar(title: Text(title ?? 'Categories')),
        body: child,
      );
}

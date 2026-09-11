import 'package:flutter/material.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/utils/responsive.dart';
import '../../data/models/product_model.dart';
import 'product_card.dart';
import 'skeletons.dart';

/// The one place a catalogue grid's geometry is defined.
///
/// Home (twice), Products, Search and Categories each built their own
/// `SliverGridDelegateWithFixedCrossAxisCount` with the same numbers copied in,
/// and the Categories copy had already drifted to a different aspect ratio.
/// Tile shape changes belong here now — not in five screens.
const double _spacing = 14;

SliverGridDelegate _delegate(
  double width, {
  int? columns,
  double? aspectRatio,
}) =>
    SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns ?? Responsive.productColumns(width),
      mainAxisSpacing: _spacing,
      crossAxisSpacing: _spacing,
      childAspectRatio: aspectRatio ?? Responsive.productAspect(width),
    );

/// Scrollable product grid, with optional pull-to-refresh and an infinite-scroll
/// footer.
///
/// [columns] and [aspectRatio] exist for grids that do *not* get the full screen
/// width — the Categories screen gives 88dp to its category rail, so the
/// screen-width defaults would size its tiles wrong. Leave both null elsewhere
/// so every full-width grid keeps the same tile shape.
class ProductGrid extends StatelessWidget {
  const ProductGrid({
    super.key,
    required this.products,
    this.controller,
    this.padding = const EdgeInsets.all(AppSpacing.gutter),
    this.showLoadMore = false,
    this.onRefresh,
    this.columns,
    this.aspectRatio,
  });

  final List<Product> products;
  final ScrollController? controller;
  final EdgeInsetsGeometry padding;

  /// Appends placeholder tiles while the next page is in flight.
  final bool showLoadMore;

  /// Wraps the grid in a [RefreshIndicator] when provided.
  final Future<void> Function()? onRefresh;

  final int? columns;
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) {
    final grid = GridView.builder(
      controller: controller,
      padding: padding,
      gridDelegate: _delegate(
        MediaQuery.sizeOf(context).width,
        columns: columns,
        aspectRatio: aspectRatio,
      ),
      itemCount: products.length + (showLoadMore ? 2 : 0),
      itemBuilder: (_, i) => i >= products.length
          ? const _LoadMoreTile()
          : ProductCard(product: products[i]),
    );

    if (onRefresh == null) return grid;
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: onRefresh!,
      child: grid,
    );
  }
}

/// Sliver form of [ProductGrid], for screens whose feed is a `CustomScrollView`.
class ProductSliverGrid extends StatelessWidget {
  const ProductSliverGrid({
    super.key,
    required this.products,
    this.padding,
    this.columns,
    this.aspectRatio,
  });

  final List<Product> products;

  /// Defaults to the responsive page gutter, horizontally only.
  final EdgeInsetsGeometry? padding;
  final int? columns;
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return SliverPadding(
      padding: padding ??
          EdgeInsets.symmetric(horizontal: Responsive.gutter(width)),
      sliver: SliverGrid(
        gridDelegate: _delegate(width, columns: columns, aspectRatio: aspectRatio),
        delegate: SliverChildBuilderDelegate(
          (_, i) => ProductCard(product: products[i]),
          childCount: products.length,
        ),
      ),
    );
  }
}

/// Loading state for a product grid — same geometry as the real thing, so the
/// page doesn't jump when the data lands.
class ProductGridSkeleton extends StatelessWidget {
  const ProductGridSkeleton({
    super.key,
    this.itemCount = 6,
    this.padding = const EdgeInsets.all(AppSpacing.gutter),
    this.columns,
    this.aspectRatio,
  });

  final int itemCount;
  final EdgeInsetsGeometry padding;
  final int? columns;
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) => GridView.builder(
        // The real grid scrolls; this must not, or a pull gesture during load
        // fights the RefreshIndicator that replaces it. [shrinkWrap] is what
        // lets it sit inside a SliverToBoxAdapter on Home, where the height
        // constraint is unbounded.
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        padding: padding,
        gridDelegate: _delegate(
          MediaQuery.sizeOf(context).width,
          columns: columns,
          aspectRatio: aspectRatio,
        ),
        itemCount: itemCount,
        itemBuilder: (_, __) => const SkeletonBox(
          height: double.infinity,
          radius: AppRadius.lg,
        ),
      );
}

class _LoadMoreTile extends StatelessWidget {
  const _LoadMoreTile();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
}

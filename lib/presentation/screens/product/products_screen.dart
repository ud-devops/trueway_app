import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design_system/theme_context.dart';
import '../../../core/utils/responsive.dart';
import '../../providers/products_provider.dart';
import '../../widgets/cart_badge_button.dart';
import '../../widgets/product_grid.dart';
import '../../widgets/state_views.dart';

class ProductsScreen extends ConsumerStatefulWidget {
  const ProductsScreen({super.key, this.query = const ProductQuery(), this.title = 'Products'});

  final ProductQuery query;
  final String title;

  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
        ref.read(productsProvider(widget.query).notifier).loadMore();
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
    final state = ref.watch(productsProvider(widget.query));

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(title: Text(widget.title), actions: const [CartBadgeButton()]),
      body: Builder(
        builder: (_) {
          if (state.loading) return const ProductGridSkeleton();
          if (state.error != null && state.items.isEmpty) {
            return AppErrorView(
              error: state.error,
              onRetry: () => ref.read(productsProvider(widget.query).notifier).refresh(),
            );
          }
          if (state.isEmpty) {
            return const EmptyView(
              title: 'No products found',
              subtitle: 'Try a different category or search',
              icon: Icons.search_off_rounded,
            );
          }
          final width = MediaQuery.sizeOf(context).width;
          return ProductGrid(
            products: state.items,
            controller: _scroll,
            // Three across on a phone, matching the home feed — this screen is
            // the same browsing job, and two wide tiles showed barely four
            // products a screen.
            columns: Responsive.homeProductColumns(width),
            aspectRatio: Responsive.homeProductAspect(width),
            showLoadMore: state.hasMore,
            onRefresh: () => ref.read(productsProvider(widget.query).notifier).refresh(),
          );
        },
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../providers/products_provider.dart';
import '../../widgets/product_grid.dart';
import '../../widgets/state_views.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _term = '';

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _term = value.trim());
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (v) => setState(() => _term = v.trim()),
          decoration: InputDecoration(
            hintText: 'Search organic products',
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _controller.clear();
                      setState(() => _term = '');
                    },
                  ),
          ),
        ),
      ),
      body: _term.isEmpty ? _prompt() : _results(),
    );
  }

  Widget _prompt() => const EmptyView(
        title: 'Search Trueway Farms',
        subtitle: 'Find organic wheat, sugar, grains and more',
        icon: Icons.search_rounded,
      );

  Widget _results() {
    final state = ref.watch(productsProvider(ProductQuery(search: _term)));
    if (state.loading) return const ProductGridSkeleton();
    if (state.error != null && state.items.isEmpty) {
      return AppErrorView(
        error: state.error,
        onRetry: () => ref.read(productsProvider(ProductQuery(search: _term)).notifier).refresh(),
      );
    }
    if (state.isEmpty) {
      return EmptyView(
        title: 'No results for "$_term"',
        subtitle: 'Try another keyword',
        icon: Icons.search_off_rounded,
      );
    }
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter, AppSpacing.xs, AppSpacing.gutter, AppSpacing.xxs,),
            child: Text('${state.items.length} result${state.items.length == 1 ? '' : 's'}',
                style: context.text.bodySm,),
          ),
        ),
        Expanded(child: ProductGrid(products: state.items)),
      ],
    );
  }
}

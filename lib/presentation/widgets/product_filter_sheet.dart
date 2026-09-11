import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../core/utils/price_utils.dart';
import '../../data/models/home_sections.dart';
import '../providers/catalog_filter_provider.dart';
import 'state_views.dart';

/// Facet filters for a category listing.
///
/// The facets come from `GET /ecommerce/filters?categories[]=<id>`, so every
/// option shown belongs to a product in *this* category — the sheet never
/// offers a choice that can only return an empty list.
///
/// ## What is offered, and what is not
///
/// Everything here goes to the server, and each facet was verified live to
/// change the result. Only one thing is held back: the **brand** section hides
/// itself when the store has a single brand, because one choice cannot narrow
/// anything.
///
/// Price, collections and the rating/offer bands all arrived with the backend
/// changes of 2026-08-12. Before that, price compared a figure the API never
/// showed, collections had no readable names, and the bands were hardcoded from
/// the PHP source — see docs/BACKEND_REQUEST_product_filters.md for the history.
///
/// Returns the chosen [FilterSelection], or null when dismissed.
Future<FilterSelection?> showProductFilterSheet(
  BuildContext context, {
  required int categoryId,
  required FilterSelection selection,
}) =>
    showModalBottomSheet<FilterSelection>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // Tall sheets need a ceiling or a long facet list pushes Apply off screen.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      builder: (_) => _ProductFilterSheet(
        categoryId: categoryId,
        initial: selection,
      ),
    );

class _ProductFilterSheet extends ConsumerStatefulWidget {
  const _ProductFilterSheet({required this.categoryId, required this.initial});

  final int categoryId;
  final FilterSelection initial;

  @override
  ConsumerState<_ProductFilterSheet> createState() =>
      _ProductFilterSheetState();
}

class _ProductFilterSheetState extends ConsumerState<_ProductFilterSheet> {
  late FilterSelection _draft = widget.initial;

  @override
  Widget build(BuildContext context) {
    final facets = ref.watch(categoryFiltersProvider(widget.categoryId));

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(),
          const Divider(height: 1),
          Flexible(
            child: facets.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: LoadingView(),
              ),
              // The facets failing must not strand the customer: the in-stock
              // toggle is client-side and still works, so the sheet degrades to
              // that rather than showing an error page over a working control.
              error: (_, __) => _body(CatalogFilters.empty),
              data: _body,
            ),
          ),
          const Divider(height: 1),
          _actions(),
        ],
      ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.xs,
          AppSpacing.sm,
        ),
        child: Row(
          children: [
            Text('Filters', style: context.text.h3),
            const Spacer(),
            if (!_draft.isEmpty)
              TextButton(
                key: const Key('filter-clear'),
                onPressed: () =>
                    setState(() => _draft = const FilterSelection()),
                child: const Text('Clear all'),
              ),
          ],
        ),
      );

  Widget _body(CatalogFilters facets) {
    // Only shown when there is a choice to make. A single brand cannot narrow
    // anything, and the server has exactly one.
    final brands = facets.brands.length > 1 ? facets.brands : const <FilterFacet>[];

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.md,
      ),
      children: [
        SwitchListTile(
          key: const Key('filter-in-stock'),
          value: _draft.inStockOnly,
          activeThumbColor: AppColors.primary,
          contentPadding: EdgeInsets.zero,
          title: const Text('In stock only'),
          onChanged: (v) =>
              setState(() => _draft = _draft.copyWith(inStockOnly: v)),
        ),
        for (final set in facets.attributeSets)
          _FacetGroup(
            title: set.title,
            options: [
              for (final value in set.values)
                (id: value.id, label: value.title, count: null),
            ],
            selected: _draft.attributeIds,
            onToggle: (id) =>
                setState(() => _draft = _draft.toggleAttribute(id)),
          ),
        _PriceRange(
          key: const Key('filter-price'),
          ceiling: facets.maxPrice,
          from: _draft.minPrice,
          to: _draft.maxPrice,
          onChanged: (from, to) => setState(
            () => _draft = _draft.withPriceRange(from, to, facets.maxPrice),
          ),
        ),
        // Server-driven since the backend started emitting `rating_ranges` and
        // `discount_ranges`. The app used to hardcode these tokens, read out of
        // the PHP source, which meant the bands could not be changed in admin
        // without a mobile release.
        _FacetTokenGroup(
          title: 'Customer rating',
          options: [
            for (final band in facets.ratingRanges)
              (
                token: band.token,
                label: band.productsCount > 0
                    ? '${band.name} (${band.productsCount})'
                    : band.name,
              ),
          ],
          selected: _draft.minRating == null
              ? const {}
              : {'rating_${_draft.minRating}'},
          onToggle: (token) => setState(
            () => _draft = _draft.toggleRating(
              int.parse(token.split('_').last),
            ),
          ),
        ),
        _FacetTokenGroup(
          title: 'Offers',
          options: [
            for (final band in facets.discountRanges)
              (
                token: band.token,
                label: band.productsCount > 0
                    ? '${band.name} (${band.productsCount})'
                    : band.name,
              ),
          ],
          selected: _draft.discounts,
          onToggle: (token) =>
              setState(() => _draft = _draft.toggleDiscount(token)),
        ),
        if (facets.collections.isNotEmpty)
          _FacetGroup(
            title: 'Collections',
            options: [
              for (final collection in facets.collections)
                (
                  id: collection.id,
                  label: collection.name,
                  count: collection.productsCount,
                ),
            ],
            selected: _draft.collectionIds,
            onToggle: (id) =>
                setState(() => _draft = _draft.toggleCollection(id)),
          ),
        if (facets.tags.isNotEmpty)
          _FacetGroup(
            title: 'Good for',
            options: [
              for (final tag in facets.tags)
                (id: tag.id, label: tag.name, count: tag.productsCount),
            ],
            selected: _draft.tagIds,
            onToggle: (id) => setState(() => _draft = _draft.toggleTag(id)),
          ),
        if (brands.isNotEmpty)
          _FacetGroup(
            title: 'Brand',
            options: [
              for (final brand in brands)
                (id: brand.id, label: brand.name, count: brand.productsCount),
            ],
            selected: _draft.brandIds,
            onToggle: (id) => setState(() => _draft = _draft.toggleBrand(id)),
          ),
      ],
    );
  }

  Widget _actions() => Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ),
            AppSpacing.hSm,
            Expanded(
              flex: 2,
              child: FilledButton(
                key: const Key('filter-apply'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () => Navigator.pop(context, _draft),
                child: Text(
                  _draft.isEmpty ? 'Apply' : 'Apply ${_draft.count}',
                ),
              ),
            ),
          ],
        ),
      );
}

/// One titled block of multi-select chips.
///
/// Chips rather than checkboxes: an attribute set holds a handful of short
/// values ("1 Kg", "5 KG (Pack of 2)") and a wrapped chip row fits them in a
/// third of the vertical space a checkbox list needs — which matters when three
/// groups have to share one sheet.
class _FacetGroup extends StatelessWidget {
  const _FacetGroup({
    required this.title,
    required this.options,
    required this.selected,
    required this.onToggle,
  });

  final String title;
  final List<({int id, String label, int? count})> options;
  final Set<int> selected;
  final void Function(int id) onToggle;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: context.text.title),
          AppSpacing.vSm,
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final option in options) _chip(context, option),
            ],
          ),
        ],
      ),
    );
  }

  /// Every colour is set explicitly, none inherited.
  ///
  /// The app's `ChipThemeData.backgroundColor` is `primarySoft` — a pale green
  /// — so an unstyled [FilterChip] renders *unselected* in the same green it
  /// uses for selected, and the whole group read as already chosen. Unselected
  /// is the plain surface with a hairline; selected is the green fill, a
  /// primary border and a heavier label, so the difference is carried by three
  /// things rather than a tint someone has to squint at.
  Widget _chip(BuildContext context, ({int id, String label, int? count}) option) {
    final isSelected = selected.contains(option.id);

    return FilterChip(
      key: Key('facet-${option.id}'),
      selected: isSelected,
      onSelected: (_) => onToggle(option.id),
      showCheckmark: false,
      label: Text(
        // The count is what turns a guess into a decision, so it is shown
        // wherever the server sends one. Attribute values carry none.
        option.count == null
            ? option.label
            : '${option.label} (${option.count})',
        style: context.text.bodySm.copyWith(
          color: isSelected ? context.colors.primaryDarker : context.colors.body,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      backgroundColor: context.colors.surface,
      selectedColor: context.colors.primarySoft,
      side: BorderSide(
        color: isSelected ? AppColors.primary : context.colors.line,
        width: isSelected ? 1.5 : 1,
      ),
    );
  }
}

/// The same block as [_FacetGroup], for options the server identifies by a
/// token rather than an id — `rating_4`, `on_sale`, `discount_25`.
///
/// Separate rather than generic over the key type: the two differ in where
/// their options come from (the filters endpoint vs a fixed list here), and one
/// widget taking both would have to explain that in its own parameters.
class _FacetTokenGroup extends StatelessWidget {
  const _FacetTokenGroup({
    required this.title,
    required this.options,
    required this.selected,
    required this.onToggle,
  });

  final String title;
  final List<({String token, String label})> options;
  final Set<String> selected;
  final void Function(String token) onToggle;

  @override
  Widget build(BuildContext context) {
    // A heading with nothing under it is worse than no section. The server only
    // sends bands that match products, so an empty list is the ordinary case in
    // a category where nothing is on sale.
    if (options.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: context.text.title),
          AppSpacing.vSm,
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final option in options) _chip(context, option),
            ],
          ),
        ],
      ),
    );
  }

  /// Colours set explicitly for the same reason as [_FacetGroup]: the app's
  /// ChipThemeData fills every chip with `primarySoft`, so an unstyled chip
  /// reads as already selected.
  Widget _chip(BuildContext context, ({String token, String label}) option) {
    final isSelected = selected.contains(option.token);

    return FilterChip(
      key: Key('facet-${option.token}'),
      selected: isSelected,
      onSelected: (_) => onToggle(option.token),
      showCheckmark: false,
      label: Text(
        option.label,
        style: context.text.bodySm.copyWith(
          color: isSelected ? context.colors.primaryDarker : context.colors.body,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      backgroundColor: context.colors.surface,
      selectedColor: context.colors.primarySoft,
      side: BorderSide(
        color: isSelected ? AppColors.primary : context.colors.line,
        width: isSelected ? 1.5 : 1,
      ),
    );
  }
}

/// Price bounds, in the currency the cards show.
///
/// A [RangeSlider] rather than two text fields: the bound that matters is
/// "roughly this much", and typing exact rupees into a filter is more work than
/// the answer deserves.
///
/// The ceiling is the server's `max_price` for the current scope, which is
/// derived from the same figure the filter compares — so the slider's right
/// edge really is "everything". It used to report 4444, a price no product was
/// listed at.
class _PriceRange extends StatelessWidget {
  const _PriceRange({
    super.key,
    required this.ceiling,
    required this.from,
    required this.to,
    required this.onChanged,
  });

  final double ceiling;
  final double? from;
  final double? to;
  final void Function(double from, double to) onChanged;

  @override
  Widget build(BuildContext context) {
    // Nothing to bound. Happens when the facets could not be read, and a
    // 0-to-0 slider is worse than no slider.
    if (ceiling <= 0) return const SizedBox.shrink();

    final start = (from ?? 0).clamp(0.0, ceiling);
    final end = (to ?? ceiling).clamp(start, ceiling);

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Price', style: context.text.title),
              const Spacer(),
              Text(
                '${PriceUtils.format(start)} - ${PriceUtils.format(end)}',
                style: context.text.bodySm,
              ),
            ],
          ),
          RangeSlider(
            values: RangeValues(start, end),
            max: ceiling,
            // One division per ₹50 keeps the thumb from landing on figures like
            // ₹437.83, which read as a bug rather than a choice.
            divisions: (ceiling / 50).ceil().clamp(1, 200),
            activeColor: AppColors.primary,
            labels: RangeLabels(
              PriceUtils.format(start),
              PriceUtils.format(end),
            ),
            onChanged: (values) => onChanged(values.start, values.end),
          ),
        ],
      ),
    );
  }
}

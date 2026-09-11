import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/home_sections.dart';
import 'core_providers.dart';

/// The facets available inside one category.
///
/// `GET /ecommerce/filters?categories[]=<id>` narrows the attribute sets, tags
/// and brands to the ones the category's products actually use, so a customer
/// is never offered a filter that can only return nothing.
///
/// Kept alive rather than `autoDispose`: the filter sheet is opened and closed
/// repeatedly on one screen, and re-reading the facets on each open shows a
/// spinner where the customer expects the list they just had. The list is small
/// and changes only when the catalogue does.
final categoryFiltersProvider =
    FutureProvider.family<CatalogFilters, int>((ref, categoryId) async {
  return ref.watch(homeRepositoryProvider).filters(categoryId: categoryId);
});

/// A customer's selections, before they press Apply.
///
/// Held apart from [ProductQuery] so the sheet can be edited freely and thrown
/// away on Cancel — the query is the *applied* state, this is the draft.
class FilterSelection {
  const FilterSelection({
    this.attributeIds = const {},
    this.tagIds = const {},
    this.brandIds = const {},
    this.collectionIds = const {},
    this.minPrice,
    this.maxPrice,
    this.minRating,
    this.discounts = const {},
    this.inStockOnly = false,
  });

  final Set<int> attributeIds;
  final Set<int> tagIds;
  final Set<int> brandIds;
  final Set<int> collectionIds;

  /// Rupees, inclusive, against the same `price` the product cards show — the
  /// server compares the displayed figure since 2026-08-12. Null means "no
  /// bound on this end"; both null means the slider is untouched.
  final double? minPrice;
  final double? maxPrice;

  /// "4 stars & above". Single-valued: the server ORs the list, so selecting
  /// both 3+ and 4+ would just mean 3+, which is a control that cannot say
  /// anything the simpler one cannot.
  ///
  /// Sent as `ratings[]=rating_4` — `ProductRepository` matches on the
  /// `rating_` prefix and a bare `4` is silently ignored.
  final int? minRating;

  /// `on_sale`, or `discount_25` for "25% off or more". Same prefix rule as
  /// [minRating]; these are ORed together, which is what the chips imply.
  final Set<String> discounts;

  /// Sent as `in_stock=1`, **and** applied to the returned page as a safety
  /// net.
  ///
  /// The parameter is new and could not be proven on this store: every product
  /// in the catalogue is currently in stock, so a filtered and an unfiltered
  /// request return the same six rows. Keeping the local pass costs nothing and
  /// means a customer who asked to hide sold-out products never sees one, even
  /// if the server's filter turns out not to bite.
  final bool inStockOnly;

  bool get isEmpty =>
      attributeIds.isEmpty &&
      tagIds.isEmpty &&
      brandIds.isEmpty &&
      collectionIds.isEmpty &&
      minPrice == null &&
      maxPrice == null &&
      minRating == null &&
      discounts.isEmpty &&
      !inStockOnly;

  /// How many choices are active, for the "Filters · 3" pill.
  int get count =>
      attributeIds.length +
      tagIds.length +
      brandIds.length +
      collectionIds.length +
      (minPrice == null && maxPrice == null ? 0 : 1) +
      discounts.length +
      (minRating == null ? 0 : 1) +
      (inStockOnly ? 1 : 0);

  FilterSelection toggleAttribute(int id) =>
      copyWith(attributeIds: _toggled(attributeIds, id));

  FilterSelection toggleTag(int id) => copyWith(tagIds: _toggled(tagIds, id));

  FilterSelection toggleBrand(int id) =>
      copyWith(brandIds: _toggled(brandIds, id));

  FilterSelection toggleCollection(int id) =>
      copyWith(collectionIds: _toggled(collectionIds, id));

  /// A range covering the whole catalogue is the same as no range at all, so it
  /// is stored as none — otherwise the pill would count a filter that narrows
  /// nothing and the query would carry bounds the server has to ignore.
  FilterSelection withPriceRange(double? from, double? to, double ceiling) {
    final wholeRange = (from ?? 0) <= 0 && (to == null || to >= ceiling);
    return FilterSelection(
      attributeIds: attributeIds,
      tagIds: tagIds,
      brandIds: brandIds,
      collectionIds: collectionIds,
      minPrice: wholeRange ? null : from,
      maxPrice: wholeRange ? null : to,
      minRating: minRating,
      discounts: discounts,
      inStockOnly: inStockOnly,
    );
  }

  /// Tapping the chosen threshold again clears it, so there is a way back to
  /// "any rating" without a separate control.
  FilterSelection toggleRating(int stars) =>
      minRating == stars ? copyWith(clearRating: true) : copyWith(minRating: stars);

  FilterSelection toggleDiscount(String token) {
    final next = {...discounts};
    if (!next.remove(token)) next.add(token);
    return copyWith(discounts: next);
  }

  FilterSelection copyWith({
    Set<int>? attributeIds,
    Set<int>? tagIds,
    Set<int>? brandIds,
    Set<int>? collectionIds,
    int? minRating,
    Set<String>? discounts,
    bool? inStockOnly,
    bool clearRating = false,
  }) =>
      FilterSelection(
        attributeIds: attributeIds ?? this.attributeIds,
        tagIds: tagIds ?? this.tagIds,
        brandIds: brandIds ?? this.brandIds,
        collectionIds: collectionIds ?? this.collectionIds,
        minPrice: minPrice,
        maxPrice: maxPrice,
        minRating: clearRating ? null : (minRating ?? this.minRating),
        discounts: discounts ?? this.discounts,
        inStockOnly: inStockOnly ?? this.inStockOnly,
      );

  /// Sorted, so two selections made in a different order are the same query —
  /// otherwise the provider would refetch for a selection it already holds.
  List<int> get sortedAttributeIds => _sorted(attributeIds);
  List<int> get sortedTagIds => _sorted(tagIds);
  List<int> get sortedBrandIds => _sorted(brandIds);
  List<int> get sortedCollectionIds => _sorted(collectionIds);

  /// The `rating_N` tokens the server expects, or empty for "any".
  List<String> get ratingTokens =>
      minRating == null ? const [] : ['rating_$minRating'];

  List<String> get sortedDiscounts => [...discounts]..sort();

  static Set<int> _toggled(Set<int> from, int id) {
    final next = {...from};
    if (!next.remove(id)) next.add(id);
    return next;
  }

  static List<int> _sorted(Set<int> ids) => [...ids]..sort();

  @override
  bool operator ==(Object other) =>
      other is FilterSelection &&
      other.inStockOnly == inStockOnly &&
      other.minRating == minRating &&
      other.minPrice == minPrice &&
      other.maxPrice == maxPrice &&
      _sameSet(other.collectionIds, collectionIds) &&
      _sameStrings(other.discounts, discounts) &&
      _sameSet(other.attributeIds, attributeIds) &&
      _sameSet(other.tagIds, tagIds) &&
      _sameSet(other.brandIds, brandIds);

  @override
  int get hashCode => Object.hash(
        inStockOnly,
        minRating,
        minPrice,
        maxPrice,
        Object.hashAll(_sorted(collectionIds)),
        Object.hashAll(_sorted(attributeIds)),
        Object.hashAll(_sorted(tagIds)),
        Object.hashAll(_sorted(brandIds)),
        Object.hashAll(sortedDiscounts),
      );

  static bool _sameSet(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);

  static bool _sameStrings(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}

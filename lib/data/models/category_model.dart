import '../../core/utils/json_utils.dart';

/// A shop category, from `GET /ecommerce/product-categories`.
///
/// Payload shape (verified live):
/// ```jsonc
/// {
///   "id": 17, "name": "Wheat & Wheat Flour", "slug": "wheat-wheat-flour",
///   "parent_id": 0, "is_featured": 0,
///   "icon": "ti ti-wheat", "icon_image": null,
///   "image_with_sizes": { "origin": "…", "thumb": "…", "medium": "…" }
/// }
/// ```
///
/// The endpoint returns a **flat** list — nesting is expressed through
/// `parent_id` (0 = top level), so the tree is assembled client-side by
/// [buildTree].
class Category {
  const Category({
    required this.id,
    required this.name,
    required this.slug,
    required this.parentId,
    this.isFeatured = false,
    this.imageUrl,
    this.thumbUrl,
    this.children = const [],
    this.productsCount = 0,
  });

  final int id;
  final String name;
  final String slug;

  /// 0 for a top-level category.
  final int parentId;

  final bool isFeatured;

  /// Full-size image, when the category has one.
  final String? imageUrl;

  /// Small image for tabs and rails.
  final String? thumbUrl;

  /// Populated by [buildTree]; empty as parsed.
  final List<Category> children;

  /// Products attached to **this category only**, from `products_count`.
  ///
  /// Direct members, not a roll-up: the backend adds it with
  /// `withCount('products')`, which does not look at descendants. Live proof —
  /// `Wheat & Wheat Flour` reports 5 while its child `Sona Moti Wheat` reports
  /// 3 of its own, for 8 between them.
  ///
  /// So this is **not** the number to decide whether a category is worth
  /// showing. Use [totalProductsCount].
  final int productsCount;

  /// Products in this category *and everything under it*.
  ///
  /// The rollup the strip actually needs. Filtering on [productsCount] alone
  /// would hide a parent whose stock all lives one level down — which is how
  /// this catalogue is already arranged in one place, and would have hidden
  /// `Wheat & Wheat Flour` the moment its 5 direct products were re-filed under
  /// `Sona Moti Wheat`.
  ///
  /// Computed here rather than asked of the server because the payload already
  /// contains every child with its own count, so the roll-up costs nothing and
  /// needs no second endpoint. Recursive, so it survives a third level if the
  /// shop ever adds one.
  int get totalProductsCount =>
      productsCount +
      children.fold<int>(0, (sum, c) => sum + c.totalProductsCount);

  /// Whether there is anything to buy in here.
  ///
  /// The test for "should this appear in a browse control at all" — tapping a
  /// category to find an empty grid is a dead end the customer paid a tap for.
  bool get hasProducts => totalProductsCount > 0;

  bool get isRoot => parentId == 0;
  bool get hasChildren => children.isNotEmpty;

  /// Best image for a small tab or rail item, or null when there is none.
  String? get displayImage {
    for (final candidate in [thumbUrl, imageUrl]) {
      if (candidate != null && candidate.isNotEmpty) return candidate;
    }
    return null;
  }

  Category copyWith({List<Category>? children}) => Category(
        id: id,
        name: name,
        slug: slug,
        parentId: parentId,
        isFeatured: isFeatured,
        imageUrl: imageUrl,
        thumbUrl: thumbUrl,
        children: children ?? this.children,
        // Carried deliberately. [buildTree] rebuilds every root through this to
        // attach its children, so dropping the count here would zero it on
        // exactly the rows the strip filters on — and every category would
        // vanish at once.
        productsCount: productsCount,
      );

  factory Category.fromJson(Map<String, dynamic> j) {
    final sizes = asMap(j['image_with_sizes']);
    String? pick(String key) => asStringOrNull(sizes[key]);

    return Category(
      id: asInt(j['id']),
      name: asString(j['name']),
      slug: asString(j['slug']),
      parentId: asInt(j['parent_id']),
      isFeatured: asBool(j['is_featured']),
      // `image` / `image_url` are fallbacks for endpoints that embed a
      // category without the sizes map.
      imageUrl: pick('origin') ??
          pick('medium') ??
          asStringOrNull(j['image'] ?? j['image_url']),
      thumbUrl: pick('thumb') ?? pick('product-thumb') ?? pick('medium'),
      // Absent on a server that predates the field, which reads as 0 — so
      // [hasProducts] is false for everything and a caller that filters on it
      // would empty the strip. Callers therefore fall back to showing
      // everything when NO category reports a count; see
      // `categoriesWithProducts`.
      productsCount: asInt(j['products_count']),
    );
  }

  /// Turns the flat API list into a two-level tree, preserving API order.
  ///
  /// A child whose parent is missing from the list is promoted to the top
  /// level rather than dropped — losing an entire category because its parent
  /// is unpublished would be worse than showing it slightly out of place.
  static List<Category> buildTree(List<Category> flat) {
    final ids = {for (final c in flat) c.id};
    final childrenOf = <int, List<Category>>{};

    for (final c in flat) {
      if (c.isRoot || !ids.contains(c.parentId)) continue;
      childrenOf.putIfAbsent(c.parentId, () => []).add(c);
    }

    return [
      for (final c in flat)
        if (c.isRoot || !ids.contains(c.parentId))
          c.copyWith(children: childrenOf[c.id] ?? const []),
    ];
  }
}

/// [all] with the categories that have nothing to sell removed.
///
/// ## Why a category with no products is worth removing
///
/// Tapping one costs the customer a tap and returns an empty grid. On this
/// catalogue nine of ten top-level categories are in that state.
///
/// ## Why it counts descendants
///
/// `products_count` is `withCount('products')` — direct members only. A parent
/// whose stock all lives one level down reports 0 and would be hidden while
/// being full. [Category.totalProductsCount] rolls the children in, and the
/// children are already in the same payload, so this costs no request.
///
/// ## Why an all-zero list is returned untouched
///
/// A server that does not send `products_count` makes every category read 0.
/// Filtering that would empty the strip completely — the app would look broken
/// against an older backend, and the failure would be silent because an empty
/// list is also a legitimate answer. So "nobody reported a count" is treated as
/// "counts are unavailable", not as "nothing is in stock".
///
/// Note this deliberately does **not** distinguish "no count field" from "every
/// count is genuinely zero". A shop with a real catalogue never has the latter,
/// and getting it wrong in that direction shows too much rather than too little.
List<Category> categoriesWithProducts(List<Category> all) {
  if (all.isEmpty) return all;
  final anyCounted = all.any((c) => c.totalProductsCount > 0);
  if (!anyCounted) return all;
  return all.where((c) => c.hasProducts).toList();
}

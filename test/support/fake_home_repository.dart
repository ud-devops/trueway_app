import 'package:trueway_farms/data/models/home_sections.dart';
import 'package:trueway_farms/data/repositories/home_repository.dart';

/// Stands in for `GET /ecommerce/filters`.
///
/// Every product card now reads it, indirectly: it is how the app finds out
/// which products are variable, since a catalogue listing row cannot say. The
/// filter's attribute ids are fed back to `/products?attributes[]=…`, and only
/// variable products carry attributes — so the answer is exactly the variable
/// set.
///
/// Defaults to **no attribute sets**, which short-circuits the whole scan: no
/// products request, no variable products, every tile a plain ADD. That is what
/// most widget tests want, and it keeps them off the network.
class FakeHomeRepository implements HomeRepository {
  FakeHomeRepository({
    this.attributeSets = const [],
    this.tags = const [],
    this.collections = const [],
    this.discountRanges = const [],
    this.ratingRanges = const [],
    this.maxPrice = 0,
  });

  /// `[{id, title, slug, display_layout, attributes: [{id, title, …}]}]`, in
  /// the shape `/ecommerce/filters` returns.
  final List<Map<String, dynamic>> attributeSets;

  /// `[{id, name, slug, products_count}]`, as `/ecommerce/filters` returns.
  final List<Map<String, dynamic>> tags;

  /// Merchandising groups, same shape as [tags].
  final List<Map<String, dynamic>> collections;

  /// `[{id: 'on_sale', name: 'On Sale', products_count: 5}]` — the `id` is the
  /// token the products endpoint expects.
  final List<Map<String, dynamic>> discountRanges;
  final List<Map<String, dynamic>> ratingRanges;

  /// Upper bound for the price slider. 0 means "no price facet", which is what
  /// most tests want.
  final double maxPrice;

  int filterCalls = 0;

  /// Which category the facets were last asked for — the filter sheet has to
  /// scope them to the category being browsed.
  int? lastCategoryId;

  @override
  Future<CatalogFilters> filters({
    int? categoryId,
    List<FilterPriceRange> priceRanges = const [],
  }) async {
    filterCalls++;
    lastCategoryId = categoryId;
    return CatalogFilters.fromJson({
      'data': {
        'attributes': attributeSets,
        'tags': tags,
        'collections': collections,
        'discount_ranges': discountRanges,
        'rating_ranges': ratingRanges,
        'max_price': maxPrice,
      },
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'FakeHomeRepository does not implement ${invocation.memberName}',
      );
}

/// The live Pack Size set: one axis, three packs, on products 111 and 120.
const kPackSizeAttributeSets = [
  {
    'id': 6,
    'title': 'Pack Size',
    'slug': 'pack-size',
    'display_layout': 'price-box',
    'attributes': [
      {'id': 21, 'title': '1.85 KG (Pack of 1)', 'slug': '185-kg-pack-of-1'},
      {'id': 22, 'title': '5 KG (Pack of 1)', 'slug': '5-kg-pack-of-1'},
      {'id': 23, 'title': '5 KG (Pack of 2)', 'slug': '5-kg-pack-of-2'},
    ],
  },
];

/// The live tag list: three health tags, with the counts the server sends.
const kHealthTags = [
  {'id': 15, 'name': 'Diabetes Friendly', 'slug': 'diabetes-friendly', 'products_count': 2},
  {'id': 18, 'name': "Women's Health", 'slug': 'womens-health', 'products_count': 1},
  {'id': 13, 'name': 'Immunity Concern', 'slug': 'immunity-concern', 'products_count': 3},
];

/// The live collections, as `/ecommerce/filters` returns them.
const kCollections = [
  {'id': 1, 'name': 'New Arrival', 'slug': 'new-arrival', 'products_count': 4},
  {'id': 3, 'name': 'Special Offer', 'slug': 'special-offer', 'products_count': 2},
];

/// The live offer bands. The `id` is the token, not a number.
const kDiscountRanges = [
  {'id': 'on_sale', 'name': 'On Sale', 'products_count': 5},
  {'id': 'discount_10', 'name': '10% or more', 'products_count': 5, 'percentage': 10},
  {'id': 'discount_20', 'name': '20% or more', 'products_count': 5, 'percentage': 20},
];

const kRatingRanges = [
  {'id': 'rating_4', 'name': '4+ Stars', 'products_count': 2, 'rating': 4},
  {'id': 'rating_3', 'name': '3+ Stars', 'products_count': 2, 'rating': 3},
];

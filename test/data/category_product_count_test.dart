/// Hiding categories that have nothing to sell.
///
/// The fixtures are the live `GET /ecommerce/product-categories` tree, because
/// its shape is what makes the naive version of this wrong: `products_count` is
/// `withCount('products')` — **direct members only** — and this catalogue
/// already keeps part of one category's stock a level down.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/category_model.dart';

Map<String, dynamic> _row(
  int id,
  String name, {
  int parent = 0,
  Object? count = 0,
}) =>
    {
      'id': id,
      'name': name,
      'slug': name.toLowerCase().replaceAll(' ', '-'),
      'parent_id': parent,
      'is_featured': 0,
      if (count != null) 'products_count': count,
    };

/// The live tree, trimmed to the rows that matter.
///
///   Wheat & Wheat Flour  5 direct   -> Sona Moti Wheat 3, Wheat 0, Wheat Flour 0
///   Millets              0          -> Whole Millets 0, Millet Flour 0
///   Rice                 0
///   Sweeteners           1
List<Category> _liveTree() => Category.buildTree([
      Category.fromJson(_row(17, 'Wheat & Wheat Flour', count: 5)),
      Category.fromJson(_row(29, 'Wheat Flour', parent: 17)),
      Category.fromJson(_row(28, 'Wheat', parent: 17)),
      Category.fromJson(_row(40, 'Sona Moti Wheat', parent: 17, count: 3)),
      Category.fromJson(_row(18, 'Millets')),
      Category.fromJson(_row(30, 'Whole Millets', parent: 18)),
      Category.fromJson(_row(31, 'Millet Flour', parent: 18)),
      Category.fromJson(_row(20, 'Rice')),
      Category.fromJson(_row(24, 'Sweeteners', count: 1)),
    ]);

List<String> _names(List<Category> cats) => cats.map((c) => c.name).toList();

void main() {
  test('buildTree keeps the count on every root', () {
    // `copyWith` is what buildTree rebuilds roots through. Dropping the count
    // there would zero it on exactly the rows the filter reads, and every
    // category would disappear at once.
    final tree = _liveTree();

    expect(tree.firstWhere((c) => c.id == 17).productsCount, 5);
    expect(tree.firstWhere((c) => c.id == 24).productsCount, 1);
  });

  test('totalProductsCount rolls the children in', () {
    final wheat = _liveTree().firstWhere((c) => c.id == 17);

    expect(wheat.productsCount, 5, reason: 'direct members only');
    expect(wheat.totalProductsCount, 8, reason: '5 direct + 3 in Sona Moti');
  });

  test('a parent whose stock all lives in a child is KEPT', () {
    // The failure this exists to prevent. Filtering on `products_count` alone
    // would hide a full category the moment its products were re-filed under
    // a child — and nothing about the screen would say why.
    final tree = Category.buildTree([
      Category.fromJson(_row(17, 'Wheat & Wheat Flour')), // 0 direct
      Category.fromJson(_row(40, 'Sona Moti Wheat', parent: 17, count: 3)),
      Category.fromJson(_row(20, 'Rice')),
    ]);

    final kept = categoriesWithProducts(tree);

    expect(_names(kept), ['Wheat & Wheat Flour']);
  });

  test('drops the categories with nothing under them', () {
    final kept = categoriesWithProducts(_liveTree());

    expect(_names(kept), ['Wheat & Wheat Flour', 'Sweeteners']);
    expect(_names(kept), isNot(contains('Millets')));
    expect(_names(kept), isNot(contains('Rice')));
  });

  test('an all-zero list is returned UNTOUCHED', () {
    // A server that does not send `products_count` makes every category read 0.
    // Filtering that would empty the strip against an older backend, and the
    // result — an empty list — is also a legitimate answer, so the breakage
    // would be silent.
    final tree = Category.buildTree([
      Category.fromJson(_row(17, 'Wheat & Wheat Flour', count: null)),
      Category.fromJson(_row(18, 'Millets', count: null)),
      Category.fromJson(_row(20, 'Rice', count: null)),
    ]);

    expect(tree.every((c) => c.productsCount == 0), isTrue);
    expect(_names(categoriesWithProducts(tree)), [
      'Wheat & Wheat Flour',
      'Millets',
      'Rice',
    ]);
  });

  test('an empty list stays empty', () {
    expect(categoriesWithProducts(const []), isEmpty);
  });

  test('the roll-up survives a third level', () {
    // Nothing in this shop is three deep today, but `buildTree` promotes an
    // orphan rather than dropping it, so a deeper tree is reachable.
    final leaf = Category.fromJson(_row(99, 'Deep', parent: 40, count: 4));
    final mid = Category.fromJson(_row(40, 'Sona Moti Wheat', parent: 17))
        .copyWith(children: [leaf]);
    final root = Category.fromJson(_row(17, 'Wheat & Wheat Flour'))
        .copyWith(children: [mid]);

    expect(root.totalProductsCount, 4);
    expect(root.hasProducts, isTrue);
  });
}

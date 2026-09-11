import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/category_model.dart';

/// Real row shape from GET /ecommerce/product-categories.
Map<String, dynamic> row(
  int id,
  String name, {
  int parentId = 0,
  bool withImage = true,
}) =>
    {
      'id': id,
      'name': name,
      'slug': name.toLowerCase().replaceAll(' ', '-'),
      'parent_id': parentId,
      'is_featured': 0,
      'icon': 'ti ti-wheat',
      'icon_image': null,
      if (withImage)
        'image_with_sizes': {
          'origin': 'https://x/$id.jpg',
          'thumb': 'https://x/$id-150x150.jpg',
          'medium': 'https://x/$id-800x800.jpg',
          'product-thumb': 'https://x/$id-400x400.jpg',
        },
    };

void main() {
  group('Category.fromJson', () {
    test('parses the product-category payload', () {
      final c = Category.fromJson(row(17, 'Wheat & Wheat Flour'));
      expect(c.id, 17);
      expect(c.name, 'Wheat & Wheat Flour');
      expect(c.slug, 'wheat-&-wheat-flour');
      expect(c.parentId, 0);
      expect(c.isRoot, isTrue);
    });

    test('prefers the thumb for small display, origin for full size', () {
      final c = Category.fromJson(row(17, 'Wheat'));
      expect(c.thumbUrl, 'https://x/17-150x150.jpg');
      expect(c.imageUrl, 'https://x/17.jpg');
      expect(c.displayImage, 'https://x/17-150x150.jpg');
    });

    test('reports no image when the sizes map is absent', () {
      final c = Category.fromJson(row(17, 'Wheat', withImage: false));
      expect(c.displayImage, isNull);
    });

    test('treats is_featured as the int the API sends', () {
      expect(Category.fromJson({...row(1, 'A'), 'is_featured': 1}).isFeatured,
          isTrue,);
      expect(Category.fromJson(row(1, 'A')).isFeatured, isFalse);
    });

    test('survives a nearly empty row', () {
      final c = Category.fromJson({'id': 5});
      expect(c.id, 5);
      expect(c.name, '');
      expect(c.isRoot, isTrue);
      expect(c.displayImage, isNull);
    });
  });

  group('Category.buildTree', () {
    // The endpoint returns a FLAT list; nesting is via parent_id.
    test('nests children under their parent', () {
      final tree = Category.buildTree([
        Category.fromJson(row(17, 'Wheat & Wheat Flour')),
        Category.fromJson(row(28, 'Wheat', parentId: 17)),
        Category.fromJson(row(29, 'Wheat Flour', parentId: 17)),
        Category.fromJson(row(18, 'Millets')),
      ]);

      expect(tree.map((c) => c.id), [17, 18]);
      expect(tree.first.children.map((c) => c.id), [28, 29]);
      expect(tree.first.hasChildren, isTrue);
      expect(tree.last.hasChildren, isFalse);
    });

    test('preserves API ordering', () {
      final tree = Category.buildTree([
        Category.fromJson(row(20, 'Rice')),
        Category.fromJson(row(17, 'Wheat')),
        Category.fromJson(row(18, 'Millets')),
      ]);
      expect(tree.map((c) => c.id), [20, 17, 18]);
    });

    test('promotes orphans instead of dropping them', () {
      // A child whose parent is unpublished must still be reachable — losing a
      // whole category is worse than showing it at the top level.
      final tree = Category.buildTree([
        Category.fromJson(row(28, 'Wheat', parentId: 999)),
        Category.fromJson(row(18, 'Millets')),
      ]);
      expect(tree.map((c) => c.id), [28, 18]);
    });

    test('handles an empty list', () {
      expect(Category.buildTree([]), isEmpty);
    });

    test('does not duplicate a child at the top level', () {
      final tree = Category.buildTree([
        Category.fromJson(row(17, 'Wheat')),
        Category.fromJson(row(28, 'Sub', parentId: 17)),
      ]);
      expect(tree.length, 1);
      expect(tree.single.children.single.id, 28);
    });
  });
}

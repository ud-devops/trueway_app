import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/product_model.dart';

Map<String, dynamic> productJson(Map<String, dynamic> overrides) => {
      'id': 1,
      'slug': 'organic-sona-moti-wheat',
      'name': 'Organic Sona Moti Wheat',
      'sku': 'TW-001',
      'price': 921.501,
      'original_price': 1100,
      'quantity': '0',
      'is_out_of_stock': 0,
      ...overrides,
    };

void main() {
  group('Product.fromJson', () {
    test('coerces the backend\'s mixed types', () {
      final p = Product.fromJson(productJson({}));
      expect(p.price, 921.501);
      expect(p.originalPrice, 1100);
      expect(p.quantity, 0); // arrived as the string "0"
      expect(p.isOutOfStock, isFalse); // arrived as the int 0
    });

    test('survives a response with almost nothing in it', () {
      final p = Product.fromJson({'id': 5});
      expect(p.id, 5);
      expect(p.name, '');
      expect(p.price, 0);
      expect(p.images, isEmpty);
      expect(p.stockStatusLabel, 'In stock');
    });

    test('defaults originalPrice to price when absent', () {
      final p = Product.fromJson(productJson({'original_price': null}));
      expect(p.originalPrice, p.price);
      expect(p.hasDiscount, isFalse);
    });

    test('prefers medium images, falling back to raw', () {
      final withSizes = Product.fromJson(productJson({
        'images': ['raw.jpg'],
        'image_with_sizes': {
          'medium': ['medium.jpg'],
        },
      }),);
      expect(withSizes.images, ['medium.jpg']);

      final withoutSizes = Product.fromJson(productJson({
        'images': ['raw.jpg'],
      }),);
      expect(withoutSizes.images, ['raw.jpg']);
    });
  });

  group('Product.inStock', () {
    // Regression: this was `!isOutOfStock && quantity > 0 || (!isOutOfStock)`,
    // which reduces to `!isOutOfStock` — the quantity term was dead.
    test('follows the backend flag', () {
      expect(Product.fromJson(productJson({'is_out_of_stock': 0})).inStock, isTrue);
      expect(Product.fromJson(productJson({'is_out_of_stock': 1})).inStock, isFalse);
    });

    test('stays in stock when quantity is untracked', () {
      final p = Product.fromJson(productJson({'quantity': 0, 'is_out_of_stock': false}));
      expect(p.inStock, isTrue);
    });

    test('quantity alone never overrides the flag', () {
      final p = Product.fromJson(productJson({'quantity': 99, 'is_out_of_stock': true}));
      expect(p.inStock, isFalse);
    });
  });

  group('Product pricing', () {
    test('computes the discount percentage', () {
      final p = Product.fromJson(productJson({'price': 800, 'original_price': 1000}));
      expect(p.hasDiscount, isTrue);
      expect(p.discountPercent, 20);
    });

    test('reports no discount when price >= original', () {
      final p = Product.fromJson(productJson({'price': 1000, 'original_price': 1000}));
      expect(p.hasDiscount, isFalse);
      expect(p.discountPercent, 0);
    });
  });


  group('packLabel', () {
    String? pack(int grams) =>
        Product.fromJson(productJson({'weight': grams})).packLabel;

    test('shows whole kilograms without a decimal', () {
      expect(pack(5000), '5 kg');
      expect(pack(1000), '1 kg');
    });

    test('shows one decimal for part kilograms', () {
      expect(pack(15200), '15.2 kg');
      expect(pack(5100), '5.1 kg');
    });

    test('stays in grams below a kilogram', () {
      expect(pack(500), '500 g');
      expect(pack(130), '130 g');
    });

    // Omitted rather than rendered as "0 g" when the backend has no weight.
    test('is null when there is no weight', () {
      expect(pack(0), isNull);
      expect(Product.fromJson(productJson({})).packLabel, isNull);
    });
  });

  group('unitPriceLabel', () {
    String? unit(int grams, double price) => Product.fromJson(
          productJson({'weight': grams, 'price': price}),
        ).unitPriceLabel;

    test('is per kilogram for packs of 200 g and above', () {
      expect(unit(5000, 921.501), contains('/kg'));
      expect(unit(500, 29), contains('/kg'));
      expect(unit(200, 10), contains('/kg'));
    });

    test('is per 100 g for small packs', () {
      expect(unit(130, 10), contains('/100 g'));
    });

    test('computes the rate correctly', () {
      // 29 for 500 g == 58/kg
      expect(unit(500, 29), contains('58'));
    });

    test('is null without a weight or price', () {
      expect(unit(0, 100), isNull);
      expect(unit(500, 0), isNull);
    });
  });

  group('stockNote', () {
    String? note(String label) =>
        Product.fromJson(productJson({'stock_status_label': label})).stockNote;

    test('hides the unremarkable in-stock case', () {
      expect(note('In stock'), isNull);
      expect(note('in stock'), isNull);
    });

    test('surfaces anything else verbatim', () {
      expect(note('On backorder'), 'On backorder');
      expect(note('Out of stock'), 'Out of stock');
    });
  });

  group('optionsLabel', () {
    test('is null without options', () {
      expect(Product.fromJson(productJson({})).optionsLabel, isNull);
    });

    test('pluralises', () {
      Product withOptions(int n) => Product.fromJson(productJson({
            'product_options': [
              for (var i = 0; i < n; i++) {'id': i, 'name': 'Opt \$i'},
            ],
          }),);
      expect(withOptions(1).optionsLabel, '1 option');
      expect(withOptions(3).optionsLabel, '3 options');
    });
  });

  group('videos', () {
    // Both shapes are copied from the live catalogue: products 119/120 carry
    // the YouTube one, 123/125 the Amazon Live one. Neither url is a media
    // file, and every thumbnail is a real still.
    test('keeps the provider and reads a YouTube embed page', () {
      final p = Product.fromJson(productJson({
        'videos': [
          {
            'provider': 'youtube',
            'url':
                'https://www.youtube.com/embed/-XOd-l4CpcA?si=OlIEL77K4Us99UGu',
            'thumbnail': 'https://dev.truewayerp.com/storage/a.jpg',
          },
        ],
      }),);
      expect(p.videos.single.provider, 'youtube');
      expect(p.videos.single.url, contains('youtube.com/embed/'));
      expect(p.videos.single.thumbnail, endsWith('a.jpg'));
    });

    test("provider 'video' does not mean a video file", () {
      final p = Product.fromJson(productJson({
        'videos': [
          {
            'provider': 'video',
            'url': 'https://www.amazon.in/live/video/1ad46949130f4bdc80cea9303d982ca9',
            'thumbnail': 'https://dev.truewayerp.com/storage/demo/millets/4.jpg',
          },
        ],
      }),);
      expect(p.videos.single.provider, 'video');
      // An HTML page, despite the label.
      expect(p.videos.single.url, isNot(endsWith('.mp4')));
    });

    test('is empty when the column is', () {
      expect(Product.fromJson(productJson({'videos': []})).videos, isEmpty);
    });
  });

  group('product_conditions', () {
    // Copied from the live payload for product 120.
    test('reads the badges the merchant configured', () {
      final p = Product.fromJson(productJson({
        'product_conditions': [
          {
            'image': 'https://dev.truewayerp.com/storage/product-condition/a.jpg',
            'title': 'Free delivery',
            'description': null,
            'page_reference': null,
          },
          {'image': null, 'title': 'No Return'},
        ],
      }),);
      expect(p.conditions.map((c) => c.title), ['Free delivery', 'No Return']);
      expect(p.conditions.first.image, endsWith('a.jpg'));
      expect(p.conditions.last.image, isNull);
    });

    test('an empty array is an answer, not a gap', () {
      // Product 125 really does return []. Nothing is drawn there, rather than
      // falling back to badges the merchant never configured.
      expect(Product.fromJson(productJson({'product_conditions': []})).conditions, isEmpty);
    });

    test('a titleless row is dropped', () {
      final p = Product.fromJson(productJson({
        'product_conditions': [
          {'image': 'https://x.test/a.jpg', 'title': '  '},
          {'title': 'Secure payment'},
        ],
      }),);
      expect(p.conditions.single.title, 'Secure payment');
    });

    test('a list payload, which omits the key, still builds', () {
      expect(Product.fromJson(productJson({})).conditions, isEmpty);
    });
  });

  group('dietType', () {
    // Verbatim from product 120's `description`. There is no diet field on any
    // endpoint — this scraped Amazon row is the only place the fact exists.
    const dietRow =
        '<tr class="a-spacing-small po-diet_type" style="margin-bottom:8px;">'
        '<td class="a-span3"><span class="a-size-base a-text-bold">'
        '<strong>Diet Type</strong></span></td>'
        '<td class="a-span9"><span class="a-size-base po-break-word">'
        'VALUE</span></td></tr>';

    Product withDiet(String value) => Product.fromJson(productJson({
          'description':
              '<figure class="table"><table><tbody>'
              '${dietRow.replaceAll('VALUE', value)}'
              '</tbody></table></figure>',
        }),);

    test('reads Vegetarian off the spec table', () {
      expect(withDiet('Vegetarian').dietType, DietType.vegetarian);
    });

    test('non-vegetarian is not read as vegetarian', () {
      // "non-vegetarian" contains "vegetarian": testing the positive first
      // would mark every non-veg product green.
      for (final value in const [
        'Non-Vegetarian',
        'Non Vegetarian',
        'non-veg',
      ]) {
        expect(withDiet(value).dietType, DietType.nonVegetarian, reason: value);
      }
    });

    test('vegan counts as vegetarian', () {
      expect(withDiet('Vegan').dietType, DietType.vegetarian);
    });

    test('a product with no diet row states nothing', () {
      // Products 118, 123 and 125 are exactly this case. Their tables carry
      // Brand / Item Weight / Shelf Life and no diet row at all.
      final p = Product.fromJson(productJson({
        'description': '<table><tbody><tr><td>Brand</td><td>Trueway</td></tr>'
            '</tbody></table>',
      }),);
      expect(p.dietType, isNull);
    });

    test('wording the parser does not recognise states nothing', () {
      // Never a default. An unknown diet must render no mark rather than a
      // guessed one — the mark is a food-safety claim.
      expect(withDiet('Eggetarian').dietType, isNull);
      expect(withDiet('').dietType, isNull);
      expect(Product.fromJson(productJson({'description': ''})).dietType, isNull);
    });

    test('a plain table row labelled Diet Type is read too', () {
      // The `po-diet_type` class comes from Amazon's markup; a hand-typed row
      // has no class to anchor on.
      final p = Product.fromJson(productJson({
        'description': '<table><tbody><tr><td><b>Diet Type</b></td>'
            '<td>Vegetarian</td></tr></tbody></table>',
      }),);
      expect(p.dietType, DietType.vegetarian);
    });
  });
}

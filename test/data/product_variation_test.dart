import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/product_variation.dart';

/// Variations, against the payloads the backend actually sends.
///
/// Every fixture here was captured live on 2026-08-03 from
/// `dev.truewayerp.com`, product 120 ("Sona Moti Wheat"), whose three options
/// are attribute 21 (1.85 KG, ₹493.50), 22 (5 KG Pack of 1, ₹921.50, default)
/// and 23 (5 KG Pack of 2, ₹921.50).
///
/// The reason this file exists at all is that the two endpoints disagree about
/// what `price` means, and getting it wrong quotes the customer the MRP.

// ---------------------------------------------------------------------------
// Fixtures — trimmed to the fields the parser reads, values verbatim.
// ---------------------------------------------------------------------------

/// `GET /ecommerce/product-variation/120?attributes[]=21`, `data`.
///
/// Note `price` (571.20) is the **MRP** and `sale_price` (493.50) is what the
/// customer pays. This is the inverse of every other product endpoint.
Map<String, dynamic> resolvedVariation({
  double price = 571.2,
  double salePrice = 493.5,
  double originalPrice = 571.2,
}) =>
    {
      'id': 122,
      'name': 'Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu)',
      'sku': 'TRUE-1114-dxgaT',
      'quantity': 98,
      'is_out_of_stock': false,
      'stock_status_label': 'In stock',
      'price': price,
      'formatted_price': '₹571.20',
      'sale_price': salePrice,
      'formatted_sale_price': '₹493.50',
      'original_price': originalPrice,
      'formatted_original_price': '₹571.20',
      'display_price': '₹571.20',
      'display_sale_price': '₹493.50',
      'sale_percentage': '-13%',
      'success_message': '98 products available',
      'error_message': null,
      'warning_message': null,
      'weight': 1850,
      'height': 34,
      'wide': 8,
      'length': 26,
      'unavailable_attribute_ids': <int>[],
      'image_with_sizes': {
        'origin': ['https://x/o1.jpg'],
        'thumb': ['https://x/t1.jpg'],
        'medium': ['https://x/m1.jpg', 'https://x/m2.jpg'],
        'product-thumb': ['https://x/p1.jpg'],
      },
      // The flat shape — `/products/{slug}` nests a whole attribute_set here.
      'selected_attributes': [
        {'id': 21, 'slug': '185-kg-pack-of-1', 'set_slug': 'pack-size', 'set_id': 6},
      ],
    };

/// `GET /ecommerce/products/{slug}` — the four sibling keys of `data`.
Map<String, dynamic> detailEnvelope() => {
      'data': {'id': 120, 'name': 'Sona Moti Wheat'},
      'default_product_variation': {
        'id': 121,
        'sku': 'TRW3214-6u62u',
        'quantity': 1891,
        'is_out_of_stock': false,
        'stock_status_label': 'In stock',
        // The ordinary catalogue convention: `price` is the selling price and
        // there is no `sale_price` key at all.
        'price': 921.501,
        'price_formatted': '₹921.50',
        'original_price': 1296.75,
        'original_price_formatted': '₹1,296.75',
        // Null on this shape, unlike a resolved variation.
        'image_with_sizes': null,
        'weight': null,
        'height': null,
        'wide': null,
        'length': null,
        'image_url':
            'https://dev.truewayerp.com/vendor/core/core/base/images/placeholder.png',
      },
      'attribute_sets': [
        {
          'id': 6,
          'title': 'Pack Size',
          'slug': 'pack-size',
          'order': 0,
          'display_layout': 'price-box',
          'attributes': [
            {
              'id': 21,
              'title': '1.85 KG (Pack of 1)',
              'slug': '185-kg-pack-of-1',
              'color': 'rgb(0, 0, 0)',
              'image': '',
              'order': 0,
              'price': 493.5,
              'original_price': 571.2,
              'weight': 1850,
              'height': 34,
              'wide': 8,
              'length': 26,
            },
            {
              'id': 22,
              'title': '5 KG (Pack of 1)',
              'slug': '5-kg-pack-of-1',
              'color': '',
              'image': '',
              'order': 1,
              'price': 921.501,
              'original_price': 1296.75,
              'weight': 5000,
              'height': 34,
              'wide': 8,
              'length': 26,
            },
            {
              'id': 23,
              'title': '5 KG (Pack of 2)',
              'slug': '5-kg-pack-of-2',
              'color': '',
              'image': '',
              'order': 2,
              'price': 921.501,
              'original_price': 1296.75,
              'weight': 5000,
              'height': 34,
              'wide': 8,
              'length': 26,
            },
          ],
        },
      ],
      'unavailable_attribute_ids': <int>[],
      // The nested shape — note the whole `attribute_set` object inside.
      'selected_attributes': [
        {
          'id': 22,
          'title': '5 KG (Pack of 1)',
          'slug': '5-kg-pack-of-1',
          'attribute_set': {
            'id': 6,
            'title': 'Pack Size',
            'slug': 'pack-size',
            'order': 0,
            'display_layout': 'price-box',
          },
        },
      ],
    };

void main() {
  // -------------------------------------------------------------------------
  group('the price inversion', () {
    // The whole reason this model exists rather than reusing Product.fromJson.
    // Reading `price` here quotes ₹571.20 for a pack that costs ₹493.50.
    test('a resolved variation is priced from sale_price, not price', () {
      final v = ProductVariation.fromJson(resolvedVariation());

      expect(v.price, 493.5, reason: 'sale_price is what the customer pays');
      expect(v.price, isNot(571.2), reason: 'price is the MRP on this endpoint');
      expect(v.originalPrice, 571.2);
      expect(v.hasDiscount, isTrue);
    });

    test('its labels come from the sale-price pair', () {
      final v = ProductVariation.fromJson(resolvedVariation());

      expect(v.priceFormatted, '₹493.50');
      expect(v.originalPriceFormatted, '₹571.20');
    });

    // Not every variation is discounted. With no sale, `price` *is* the price —
    // so the parser cannot simply always read `sale_price`.
    test('falls back to price when nothing is on sale', () {
      final v = ProductVariation.fromJson(
        resolvedVariation(price: 571.2, salePrice: 0, originalPrice: 571.2),
      );

      expect(v.price, 571.2);
      expect(v.priceFormatted, '₹571.20');
      expect(v.hasDiscount, isFalse);
    });

    // `default_product_variation` follows the *ordinary* convention — a third
    // naming scheme again — so one parser has to handle both.
    test('the default variation is priced from price, its own way', () {
      final options =
          ProductVariationOptions.fromEnvelope(detailEnvelope());
      final v = options.defaultVariation!;

      expect(v.id, 121);
      expect(v.price, 921.501, reason: 'no sale_price key: price is the price');
      expect(v.originalPrice, 1296.75);
      expect(v.priceFormatted, '₹921.50');
      expect(v.originalPriceFormatted, '₹1,296.75');
    });
  });

  // -------------------------------------------------------------------------
  group('the cart id', () {
    // Posting the parent (120) silently gets the default variation and throws
    // away the customer's pick. This id is the one that must go to the cart.
    test('is the variation id, not the parent product id', () {
      final v = ProductVariation.fromJson(resolvedVariation());

      expect(v.id, 122);
      expect(v.id, isNot(120));
    });
  });

  // -------------------------------------------------------------------------
  group('server-authored messages', () {
    // Shown verbatim: "98 products available" names the constraint far better
    // than anything the client could compose from `quantity`.
    test('are carried through unchanged', () {
      final v = ProductVariation.fromJson(resolvedVariation());

      expect(v.successMessage, '98 products available');
      expect(v.errorMessage, isNull);
      expect(v.warningMessage, isNull);
    });

    test('the discount badge prefers the server percentage', () {
      final v = ProductVariation.fromJson(resolvedVariation());

      // Server sends "-13%"; the app's badges read "13% OFF".
      expect(v.salePercentage, '-13%');
      expect(v.discountLabel, '13% OFF');
    });

    test('and derives one when the server sent none', () {
      final json = resolvedVariation()..remove('sale_percentage');
      final v = ProductVariation.fromJson(json);

      expect(v.discountLabel, '${v.discountPercent}% OFF');
      expect(v.discountPercent, 14, reason: '(571.2-493.5)/571.2 rounds to 14');
    });
  });

  // -------------------------------------------------------------------------
  group('images', () {
    test('a resolved variation carries its own gallery, medium preferred', () {
      final v = ProductVariation.fromJson(resolvedVariation());

      expect(v.images, ['https://x/m1.jpg', 'https://x/m2.jpg']);
    });

    // The reason the detail screen must fall back to the parent's images for
    // the default variation but not for a resolved one.
    test('the default variation has none, so callers must fall back', () {
      final options = ProductVariationOptions.fromEnvelope(detailEnvelope());

      expect(options.defaultVariation!.images, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('selected_attributes — two shapes, one key', () {
    test('the flat shape on a resolved variation', () {
      final v = ProductVariation.fromJson(resolvedVariation());
      expect(v.selectedAttributeIds, [21]);
    });

    // Here each entry nests a whole `attribute_set`. A parser that reached for
    // `attribute_set.id` on the flat shape, or for the nested `id` here, would
    // read the *set* id (6) as the attribute id.
    test('the nested shape on product detail', () {
      final options = ProductVariationOptions.fromEnvelope(detailEnvelope());

      expect(options.selectedAttributeIds, [22]);
      expect(options.selectedAttributeIds, isNot(contains(6)));
    });
  });

  // -------------------------------------------------------------------------
  group('attribute sets', () {
    test('parse in display order with their own prices', () {
      final options = ProductVariationOptions.fromEnvelope(detailEnvelope());
      final set = options.attributeSets.single;

      expect(set.title, 'Pack Size');
      expect(set.displayLayout, 'price-box');
      expect(set.attributes.map((a) => a.id), [21, 22, 23]);
      // Per-option pricing with no extra request — this is what lets the
      // selector show a price beside every option.
      expect(set.attributes.map((a) => a.price), [493.5, 921.501, 921.501]);
    });

    test('report varying prices, which is what justifies showing them', () {
      final options = ProductVariationOptions.fromEnvelope(detailEnvelope());
      expect(options.attributeSets.single.hasVaryingPrices, isTrue);
    });

    test('carry pack weights, which the default variation does not', () {
      final options = ProductVariationOptions.fromEnvelope(detailEnvelope());
      final attrs = options.attributeSets.single.attributes;

      expect(attrs.map((a) => a.packLabel), ['1.9 kg', '5 kg', '5 kg']);
      expect(options.defaultVariation!.weightGrams, 0);
    });

    test('an ordinary product is not variable', () {
      final options = ProductVariationOptions.fromEnvelope({
        'data': {'id': 118},
      });

      expect(options.isVariable, isFalse);
      expect(options.defaultVariation, isNull);
      expect(options.attributeSets, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('default selection', () {
    test('is what the server marked selected', () {
      final options = ProductVariationOptions.fromEnvelope(detailEnvelope());

      expect(options.defaultSelection, {6: 22});
    });

    // A picker rendered with nothing chosen has no price to show and no id to
    // add, so there is always a fallback.
    test('falls back to the first available option', () {
      final envelope = detailEnvelope()..['selected_attributes'] = <dynamic>[];
      final options = ProductVariationOptions.fromEnvelope(envelope);

      expect(options.defaultSelection, {6: 21});
    });

    test('skips options the server says are unavailable', () {
      final envelope = detailEnvelope()
        ..['selected_attributes'] = <dynamic>[]
        ..['unavailable_attribute_ids'] = [21];
      final options = ProductVariationOptions.fromEnvelope(envelope);

      expect(options.defaultSelection, {6: 22});
    });
  });
}

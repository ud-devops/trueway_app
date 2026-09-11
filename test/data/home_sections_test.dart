import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/brand_model.dart';
import 'package:trueway_farms/data/models/home_sections.dart';

/// Real capture of `GET /ecommerce/top-products-group` (api-probe/top_products.json).
///
/// Trimmed only for readability: each section keeps one product instead of
/// 2-4, the `images`/`images_thumb`/`image_with_sizes` arrays keep their first
/// entry, and `description`/`content` are cut to their first 60 characters.
/// Every key and every value *type* is verbatim. `recently_added` is emptied to
/// stand in for the empty-section case, which the live endpoint produces
/// routinely (top_selling is empty whenever no paid order landed in 30 days).
const String _topProductsGroupJson = r'''
{
  "error": false,
  "data": {
    "top_selling": [
      {
        "id": 118,
        "slug": "trueway-farms-organic-desi-khand-brown-khandsari",
        "name": "Trueway Farms Organic Desi Khand Brown (khandsari)",
        "sku": "TRW3215",
        "description": "<figure class=\"table\" style=\"width:513.25px;\"><table class=\"",
        "content": "<h2 class=\"a-size-base-plus a-text-bold\" style=\"background-c",
        "quantity": 93,
        "is_out_of_stock": false,
        "stock_status_label": "In stock",
        "stock_status_html": "<span class=\"text-success\">In stock</span>",
        "price": 943.95,
        "price_formatted": "₹943.95",
        "original_price": 1199.1,
        "original_price_formatted": "₹1,199.10",
        "reviews_avg": 5,
        "reviews_count": 1,
        "images": ["https://dev.truewayerp.com/storage/products/whole-wheat/81xa52v7tol-sx679.jpg"],
        "images_thumb": ["https://dev.truewayerp.com/storage/products/whole-wheat/81xa52v7tol-sx679-150x150.jpg"],
        "image_with_sizes": {
          "origin": ["https://dev.truewayerp.com/storage/products/whole-wheat/81xa52v7tol-sx679.jpg"],
          "thumb": ["https://dev.truewayerp.com/storage/products/whole-wheat/81xa52v7tol-sx679-150x150.jpg"],
          "medium": ["https://dev.truewayerp.com/storage/products/whole-wheat/81xa52v7tol-sx679-800x800.jpg"],
          "product-thumb": ["https://dev.truewayerp.com/storage/products/whole-wheat/81xa52v7tol-sx679-400x400.jpg"]
        },
        "weight": 5100,
        "height": 24,
        "wide": 6,
        "length": 19,
        "image_url": "https://dev.truewayerp.com/storage/products/whole-wheat/81xa52v7tol-sx679-150x150.jpg",
        "videos": [],
        "product_conditions": [],
        "product_options": [],
        "store": {
          "id": 10,
          "slug": "trueway-farms-1",
          "name": "Trueway Farms",
          "zip_code": "311001"
        }
      }
    ],
    "trending": [
      {
        "id": 111,
        "slug": "trueway-farms-organic-sona-moti-wheat-sonamoti-gehu-5kg-pack",
        "name": "Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu)",
        "sku": "TRW3214",
        "description": "<div style=\"background-color:rgb(255,255,255);color:rgb(15,1",
        "content": "<ul class=\"a-unordered-list a-nostyle a-vertical a-spacing-n",
        "quantity": 1989,
        "is_out_of_stock": false,
        "stock_status_label": "In stock",
        "stock_status_html": "<span class=\"text-success\">In stock</span>",
        "price": 921.501,
        "price_formatted": "₹921.50",
        "original_price": 1296.75,
        "original_price_formatted": "₹1,296.75",
        "reviews_avg": 5,
        "reviews_count": 1,
        "images": ["https://dev.truewayerp.com/storage/products/whole-wheat/61dmn5j-dul-sl1080.jpg"],
        "images_thumb": ["https://dev.truewayerp.com/storage/products/whole-wheat/61dmn5j-dul-sl1080-150x150.jpg"],
        "image_with_sizes": {
          "origin": ["https://dev.truewayerp.com/storage/products/whole-wheat/61dmn5j-dul-sl1080.jpg"],
          "thumb": ["https://dev.truewayerp.com/storage/products/whole-wheat/61dmn5j-dul-sl1080-150x150.jpg"],
          "medium": ["https://dev.truewayerp.com/storage/products/whole-wheat/61dmn5j-dul-sl1080-800x800.jpg"],
          "product-thumb": ["https://dev.truewayerp.com/storage/products/whole-wheat/61dmn5j-dul-sl1080-400x400.jpg"]
        },
        "weight": 5000,
        "height": 34,
        "wide": 8,
        "length": 26,
        "image_url": "https://dev.truewayerp.com/storage/products/whole-wheat/81lm1nhmzol-sx679-150x150.jpg",
        "videos": [],
        "product_conditions": [],
        "product_options": [],
        "store": {
          "id": 10,
          "slug": "trueway-farms-1",
          "name": "Trueway Farms",
          "zip_code": "311001"
        }
      }
    ],
    "recently_added": [],
    "top_rated": [
      {
        "id": 118,
        "slug": "trueway-farms-organic-desi-khand-brown-khandsari",
        "name": "Trueway Farms Organic Desi Khand Brown (khandsari)",
        "sku": "TRW3215",
        "quantity": 93,
        "is_out_of_stock": false,
        "stock_status_label": "In stock",
        "price": 943.95,
        "price_formatted": "₹943.95",
        "original_price": 1199.1,
        "original_price_formatted": "₹1,199.10",
        "reviews_avg": null,
        "reviews_count": 0,
        "images": [],
        "images_thumb": [],
        "image_with_sizes": null,
        "weight": 5100,
        "image_url": "https://dev.truewayerp.com/storage/products/whole-wheat/81xa52v7tol-sx679-150x150.jpg",
        "videos": [],
        "product_conditions": [],
        "product_options": [],
        "store": {
          "id": 10,
          "slug": "trueway-farms-1",
          "name": "Trueway Farms",
          "zip_code": "311001"
        }
      }
    ]
  },
  "message": "All product sections with 4 products each"
}
''';

/// Real capture of `GET /ecommerce/filters?categories[]=17`
/// (api-probe/home_filters_category17.json), with the 21-entry category list cut
/// to two and `price_ranges` filled in from a live probe of
/// `?price_ranges[0][from]=0&price_ranges[0][to]=500` — the server echoes the
/// request's own numbers back as STRINGS, which is the point of that field here.
const String _filtersJson = r'''
{
  "data": {
    "categories": [
      {"id": 17, "name": "Wheat & Wheat Flour", "slug": "wheat-wheat-flour", "url": "product-categories/wheat-wheat-flour", "parent_id": 0},
      {"id": 29, "name": "Wheat Flour", "slug": "wheat-flour", "url": "product-categories/wheat-flour", "parent_id": 17}
    ],
    "brands": [],
    "tags": [],
    "price_ranges": [{"from": "0", "to": "500"}],
    "max_price": 4444,
    "current_category_id": 0,
    "current_filter_categories": ["17"],
    "attributes": [
      {
        "id": 3,
        "title": "Weight",
        "slug": "weight",
        "display_layout": "price-box",
        "attributes": [
          {"id": 11, "title": "1 Kg", "slug": "1-kg", "color": "", "image": null, "is_default": 1, "is_selected": false},
          {"id": 16, "title": "5 Kg", "slug": "5-kg", "color": "", "image": null, "is_default": 0, "is_selected": true}
        ]
      }
    ]
  },
  "error": false,
  "message": null
}
''';

/// Real capture of the unscoped `GET /ecommerce/filters` (api-probe/b-filters.json),
/// cut to the fields that differ from the scoped call: brands and tags populated,
/// `max_price` an order of magnitude larger, `price_ranges` empty.
const String _filtersUnscopedJson = r'''
{
  "data": {
    "categories": [],
    "brands": [
      {"id": 8, "name": "Trueway Farms", "slug": "trueway-farms", "url": "https://dev.truewayerp.com/products?brands%5B%5D=8", "products_count": 4}
    ],
    "tags": [
      {"id": 15, "name": "Diabetes Friendly", "slug": "diabetes-friendly", "url": "https://dev.truewayerp.com/products?tags%5B%5D=15", "products_count": 2}
    ],
    "price_ranges": [],
    "max_price": 40005,
    "current_category_id": 0,
    "current_filter_categories": [],
    "attributes": [
      {
        "id": 6,
        "title": "Pack Size",
        "slug": "pack-size",
        "display_layout": "price-box",
        "attributes": [
          {"id": 21, "title": "1.85 KG (Pack of 1)", "slug": "185-kg-pack-of-1", "color": "rgb(0, 0, 0)", "image": null, "is_default": 1, "is_selected": false}
        ]
      }
    ]
  },
  "error": false,
  "message": null
}
''';

/// Real capture of `GET /ecommerce/flash-sales` (api-probe/flash_sales.json).
/// This is the ONLY flash-sale response ever observed: an empty array.
const String _flashSalesEmptyJson =
    r'''{"error":false,"data":[],"message":null}''';

/// SYNTHETIC — no populated flash sale has ever been captured from this backend.
/// Constructed from the backend source (`FlashSaleController::formatFlashSale`
/// and `FlashSaleProductResource`, which extends `AvailableProductResource` and
/// overrides `price`/`quantity` from the pivot row). These tests prove the
/// parser handles that documented shape; they do NOT prove the shape is right.
const String _flashSalePopulatedJson = r'''
{
  "error": false,
  "data": [
    {
      "id": 3,
      "name": "Harvest Sale",
      "end_date": "2030-01-31 23:59:59",
      "expired": false,
      "products": [
        {
          "id": 118,
          "slug": "trueway-farms-organic-desi-khand-brown-khandsari",
          "name": "Trueway Farms Organic Desi Khand Brown (khandsari)",
          "sku": "TRW3215",
          "is_out_of_stock": false,
          "stock_status_label": "In stock",
          "original_price": 1199.1,
          "original_price_formatted": "₹1,199.10",
          "reviews_avg": 5,
          "reviews_count": 1,
          "images": [],
          "images_thumb": [],
          "image_with_sizes": null,
          "weight": 5100,
          "image_url": "https://dev.truewayerp.com/storage/products/whole-wheat/81xa52v7tol-sx679-150x150.jpg",
          "videos": [],
          "product_conditions": [],
          "product_options": [],
          "price": 799,
          "price_formatted": "₹799.00",
          "quantity": 50,
          "sold": 20,
          "sale_count_left": 30,
          "sale_percent": 40
        }
      ]
    }
  ],
  "message": null
}
''';

/// Real capture of `GET /ecommerce/brands` (api-probe/brands_list.json) — the
/// hybrid envelope: paginated `data`/`links`/`meta` PLUS `error`/`message`.
const String _brandsJson = r'''
{
  "data": [
    {
      "id": 8,
      "name": "Trueway Farms",
      "website": null,
      "description": null,
      "is_featured": 1,
      "slug": "trueway-farms",
      "logo_with_sizes": {
        "origin": "https://dev.truewayerp.com/storage/logo/trueway-farms-favicon-color.png",
        "thumb": "https://dev.truewayerp.com/storage/logo/trueway-farms-favicon-color-150x150.png",
        "medium": "https://dev.truewayerp.com/storage/logo/trueway-farms-favicon-color-800x800.png",
        "product-thumb": "https://dev.truewayerp.com/storage/logo/trueway-farms-favicon-color-400x400.png"
      }
    }
  ],
  "links": {"first": "https://dev.truewayerp.com/api/v1/ecommerce/brands?page=1", "last": "https://dev.truewayerp.com/api/v1/ecommerce/brands?page=1", "prev": null, "next": null},
  "meta": {"current_page": 1, "from": 1, "last_page": 1, "per_page": 16, "to": 1, "total": 1},
  "error": false,
  "message": null
}
''';

Map<String, dynamic> _decode(String s) =>
    jsonDecode(s) as Map<String, dynamic>;

void main() {
  group('HomeSections', () {
    test('parses the real four-carousel payload', () {
      final s = HomeSections.fromJson(_decode(_topProductsGroupJson));

      expect(s.topSelling, hasLength(1));
      expect(s.trending, hasLength(1));
      expect(s.topRated, hasLength(1));
      expect(s.isEmpty, isFalse);

      final p = s.topSelling.first;
      expect(p.id, 118);
      expect(p.name, 'Trueway Farms Organic Desi Khand Brown (khandsari)');
      expect(p.price, 943.95);
      expect(p.priceFormatted, '₹943.95');
      expect(p.hasDiscount, isTrue);
      expect(p.weightGrams, 5100);
      // medium size wins over the raw `images` list.
      expect(p.images.single, endsWith('-800x800.jpg'));
      expect(p.store?.name, 'Trueway Farms');
      expect(p.inStock, isTrue);
    });

    test('an empty section is dropped from sections but keeps its field', () {
      final s = HomeSections.fromJson(_decode(_topProductsGroupJson));

      expect(s.recentlyAdded, isEmpty);
      expect(
        s.sections.map((x) => x.kind),
        [
          HomeSectionKind.topSelling,
          HomeSectionKind.trending,
          HomeSectionKind.topRated,
        ],
      );
      expect(s.sections.first.title, 'Best sellers');
    });

    test('reviews_avg null and image_with_sizes null are survivable', () {
      // The live endpoint sends both: reviews_avg is null until a product is
      // reviewed, image_with_sizes is null when the product has no images.
      final s = HomeSections.fromJson(_decode(_topProductsGroupJson));
      final p = s.topRated.single;

      expect(p.reviewsAvg, isNull);
      expect(p.rating, 0);
      expect(p.images, isEmpty);
      expect(p.primaryImage, isNotEmpty); // falls back to image_url
    });

    test('price arriving as int vs double both parse', () {
      final json = _decode(_topProductsGroupJson);
      final data = json['data'] as Map<String, dynamic>;
      (data['top_selling'] as List).first['price'] = 943; // int, not double
      (data['trending'] as List).first['price'] = '943.95'; // 2dp string

      final s = HomeSections.fromJson(json);
      expect(s.topSelling.single.price, 943);
      expect(s.trending.single.price, 943.95);
    });

    test('accepts the bare data object as well as the envelope', () {
      final envelope = _decode(_topProductsGroupJson);
      final bare = HomeSections.fromJson(
        Map<String, dynamic>.from(envelope['data'] as Map),
      );
      expect(bare.topSelling, hasLength(1));
      expect(bare.trending, hasLength(1));
    });

    test('all four sections absent yields an empty, non-throwing result', () {
      final s = HomeSections.fromJson({'error': false, 'data': {}});
      expect(s.isEmpty, isTrue);
      expect(s.sections, isEmpty);
    });

    test('a section arriving as a non-list is ignored, not fatal', () {
      // Defensive: `data` has been observed as an object everywhere, but a
      // scalar in one slot must not take down the whole home screen.
      final s = HomeSections.fromJson({
        'data': {'top_selling': 'nope', 'trending': null, 'top_rated': []},
      });
      expect(s.isEmpty, isTrue);
    });

    test('data arriving as a list instead of an object is not fatal', () {
      // Laravel emits `[]` for an empty associative array, so a future
      // controller change (or an error branch) can hand back a list here.
      final s = HomeSections.fromJson({'error': false, 'data': <dynamic>[]});
      expect(s.isEmpty, isTrue);
      expect(s.sections, isEmpty);
    });
  });

  group('CatalogFilters', () {
    test('parses the category-scoped payload', () {
      final f = CatalogFilters.fromJson(_decode(_filtersJson));

      expect(f.categories, hasLength(2));
      expect(f.maxPrice, 4444);
      expect(f.rootCategories.single.id, 17);
      expect(f.childrenOf(17).single.slug, 'wheat-flour');
      expect(f.categories.first.url, 'product-categories/wheat-wheat-flour');
    });

    test('current_filter_categories arrives as strings and coerces to ints',
        () {
      final f = CatalogFilters.fromJson(_decode(_filtersJson));
      expect(f.currentFilterCategoryIds, [17]);
      // The server reports the scoping category here, NOT in current_category_id.
      expect(f.currentCategoryId, 0);
    });

    test('price_ranges echo back as strings', () {
      final f = CatalogFilters.fromJson(_decode(_filtersJson));
      final r = f.priceRanges.single;
      expect(r.from, 0.0);
      expect(r.to, 500.0);
    });

    test('attribute values: is_default int, empty colour, null image', () {
      final f = CatalogFilters.fromJson(_decode(_filtersJson));
      final set = f.attributeSets.single;

      expect(set.title, 'Weight');
      expect(set.displayLayout, 'price-box');
      expect(set.values, hasLength(2));
      expect(set.values.first.isDefault, isTrue); // arrived as int 1
      expect(set.values.last.isDefault, isFalse); // arrived as int 0
      expect(set.values.first.color, isNull); // arrived as ""
      expect(set.values.first.imageUrl, isNull);
      expect(set.selected.single.id, 16);
    });

    test('scoping empties brands and tags', () {
      final scoped = CatalogFilters.fromJson(_decode(_filtersJson));
      expect(scoped.brands, isEmpty);
      expect(scoped.tags, isEmpty);

      final all = CatalogFilters.fromJson(_decode(_filtersUnscopedJson));
      expect(all.brands.single.id, 8);
      expect(all.brands.single.productsCount, 4);
      expect(all.tags.single.name, 'Diabetes Friendly');
      expect(all.maxPrice, 40005);
      expect(all.priceRanges, isEmpty);
      expect(all.attributeSets.single.values.single.color, 'rgb(0, 0, 0)');
    });

    test('an all-empty response parses to empty lists, not nulls', () {
      final f = CatalogFilters.fromJson({
        'data': {
          'categories': [],
          'brands': [],
          'tags': [],
          'price_ranges': [],
          'max_price': 0,
          'current_category_id': 0,
          'current_filter_categories': [],
          'attributes': [],
        },
      });
      expect(f.categories, isEmpty);
      expect(f.attributeSets, isEmpty);
      expect(f.maxPrice, 0);
      expect(f.currentFilterCategoryIds, isEmpty);
    });

    test('every field absent still yields a usable object', () {
      final f = CatalogFilters.fromJson(const {});
      expect(f.categories, isEmpty);
      expect(f.rootCategories, isEmpty);
      expect(f.maxPrice, 0);
      expect(f.currentFilterCategoryIds, isEmpty);
    });

    test('current_filter_categories as a sparse object still yields ids', () {
      // PHP's array_filter preserves keys, so dropping a falsy entry from
      // anywhere but the tail of $categoriesRequest makes json_encode emit an
      // object. A List-only check would silently report "unscoped".
      final f = CatalogFilters.fromJson({
        'data': {
          'current_filter_categories': {'1': '17', '2': 29},
        },
      });
      expect(f.currentFilterCategoryIds, [17, 29]);
    });

    test('max_price as a 2dp string still parses', () {
      final f = CatalogFilters.fromJson({
        'data': {'max_price': '40005.00'},
      });
      expect(f.maxPrice, 40005.0);
    });
  });

  group('FlashSale', () {
    test('the only observed response — an empty array — parses to no sales', () {
      final body = _decode(_flashSalesEmptyJson);
      final sales = (body['data'] as List)
          .cast<Map<String, dynamic>>()
          .map(FlashSale.fromJson)
          .toList();
      expect(sales, isEmpty);
    });

    test('parses the source-derived populated shape', () {
      final sale = FlashSale.fromJson(
        ((_decode(_flashSalePopulatedJson)['data']) as List).first
            as Map<String, dynamic>,
      );

      expect(sale.id, 3);
      expect(sale.name, 'Harvest Sale');
      expect(sale.expired, isFalse);
      // `end_date` is emitted by the server as a bare `Y-m-d H:i:s` with no
      // offset, and the server clock is UTC (trueway_ecom config/app.php sets
      // 'timezone' => 'UTC'; every other timestamp on this API carries a `Z`
      // that lines up with UTC). Reading it as device-local would be 5h30m
      // early on an IST phone.
      expect(sale.endsAt!.toUtc(), DateTime.utc(2030, 1, 31, 23, 59, 59));
      expect(sale.endsAt!.isUtc, isFalse); // handed back in device local time
      expect(sale.isLive, isTrue);
      expect(sale.timeLeft, isNotNull);

      final item = sale.products.single;
      expect(item.salePrice, 799);
      expect(item.priceLabel, '₹799.00');
      expect(item.saleQuantity, 50);
      expect(item.sold, 20);
      expect(item.remaining, 30);
      expect(item.salePercent, 40);
      expect(item.soldFraction, closeTo(0.4, 1e-9));
      expect(item.isSoldOut, isFalse);
      expect(item.isPurchasable, isTrue);
    });

    test('an end_date that already carries an offset is honoured as sent', () {
      // Defensive: if the controller is ever changed to ->toIso8601String()
      // the zone must not be double-applied.
      final sale = FlashSale.fromJson({
        'id': 9,
        'end_date': '2030-01-31T23:59:59+05:30',
      });
      expect(sale.endsAt!.toUtc(), DateTime.utc(2030, 1, 31, 18, 29, 59));
    });

    test('a sold-out allocation is not purchasable even though stock remains',
        () {
      // `is_out_of_stock` is the WAREHOUSE answer (93 units) and knows nothing
      // about the sale allocation, so product.inStock alone would let a
      // customer add a unit the sale no longer has.
      final item = FlashSaleProduct.fromJson({
        'id': 118,
        'is_out_of_stock': false,
        'price': 799,
        'quantity': 50,
        'sold': 50,
        'sale_count_left': 0,
        'sale_percent': 100,
      });
      expect(item.product.inStock, isTrue);
      expect(item.isSoldOut, isTrue);
      expect(item.isPurchasable, isFalse);
      expect(item.soldFraction, 1);
    });

    test('a null pivot price falls back to the regular price, not ₹0', () {
      // ec_flash_sale_products.price is a nullable column and the resource
      // copies it through unguarded. Untreated this reads as free + 100% off.
      final item = FlashSaleProduct.fromJson({
        'id': 118,
        'price': null,
        'price_formatted': null,
        'original_price': 1199.1,
        'original_price_formatted': '₹1,199.10',
      });
      expect(item.salePrice, 1199.1);
      expect(item.priceLabel, '₹1,199.10');
      expect(item.product.price, 1199.1);
      expect(item.product.hasDiscount, isFalse);
      expect(item.product.discountPercent, 0);
    });

    test('the pivot quantity does not masquerade as stock', () {
      // FlashSaleProductResource overwrites `quantity` with the sale
      // allocation. If it leaked into Product.quantity the card would claim 50
      // in stock when the warehouse has 93 (or 0).
      final item = FlashSaleProduct.fromJson({
        'id': 118,
        'quantity': 50,
        'sold': 20,
        'price': 799,
        'is_out_of_stock': false,
      });
      expect(item.saleQuantity, 50);
      expect(item.product.quantity, 0);
      expect(item.product.inStock, isTrue); // is_out_of_stock stays the truth
      // The regular price survives on original_price, so the discount is real.
      final discounted = FlashSaleProduct.fromJson({
        'id': 118,
        'price': 799,
        'original_price': 1199.1,
      });
      expect(discounted.product.hasDiscount, isTrue);
      expect(discounted.product.discountPercent, 33);
    });

    test('sale_count_left is derived when absent and clamped when negative',
        () {
      final derived = FlashSaleProduct.fromJson({
        'quantity': 50,
        'sold': 20,
      });
      expect(derived.saleCountLeft, 30);

      final oversold = FlashSaleProduct.fromJson({
        'quantity': 10,
        'sold': 12,
        'sale_count_left': -2,
      });
      expect(oversold.saleCountLeft, -2);
      expect(oversold.remaining, 0);
      expect(oversold.isSoldOut, isTrue);
    });

    test('string money and string counters coerce', () {
      final item = FlashSaleProduct.fromJson({
        'price': '799.00',
        'price_formatted': '₹799.00',
        'quantity': '50',
        'sold': '20',
        'sale_percent': '40.00',
      });
      expect(item.salePrice, 799.0);
      expect(item.saleQuantity, 50);
      expect(item.sold, 20);
      expect(item.salePercent, 40.0);
      expect(item.priceLabel, '₹799.00');
    });

    test('missing price_formatted falls back to local formatting', () {
      final item = FlashSaleProduct.fromJson({'price': 799});
      expect(item.priceLabel, '₹799.00');
    });

    test('sale_percent 0 with no allocation does not divide by zero', () {
      final item = FlashSaleProduct.fromJson({
        'quantity': 0,
        'sold': 0,
        'sale_percent': 0,
      });
      expect(item.soldFraction, 0);
      expect(item.isSoldOut, isFalse); // no allocation != sold out
    });

    test('a sale with no products or an unparseable end_date is not live', () {
      final noProducts = FlashSale.fromJson({
        'id': 1,
        'name': 'Empty',
        'end_date': '2030-01-01 00:00:00',
        'expired': false,
        'products': [],
      });
      expect(noProducts.isLive, isFalse);

      final noDate = FlashSale.fromJson({'id': 2, 'name': 'X'});
      expect(noDate.endsAt, isNull);
      expect(noDate.timeLeft, isNull);
      expect(noDate.expired, isFalse);
      expect(noDate.products, isEmpty);
    });

    test('expired is honoured over the device clock', () {
      final sale = FlashSale.fromJson({
        'id': 4,
        'name': 'Past',
        // Far future date, but the server says it is over — the server wins.
        'end_date': '2030-01-01 00:00:00',
        'expired': true,
        'products': [
          {'id': 1, 'price': 1},
        ],
      });
      expect(sale.isLive, isFalse);
    });
  });

  group('brands', () {
    test('parses the hybrid paginated+error envelope', () {
      final body = _decode(_brandsJson);
      final brands = (body['data'] as List)
          .cast<Map<String, dynamic>>()
          .map(Brand.fromJson)
          .toList();

      expect(brands, hasLength(1));
      expect(brands.single.id, 8);
      expect(brands.single.isFeatured, isTrue); // arrived as int 1
      expect(brands.single.website, isNull);
      expect(brands.single.logo, endsWith('-150x150.png'));
      // The hybrid envelope carries BOTH pagination meta and error/message.
      expect(body['error'], isFalse);
      expect(body['meta'], isA<Map>());
    });
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/repositories/wishlist_repository.dart';

// ===========================================================================
// Captured payloads. Every constant below is a byte-for-byte copy of a live
// response from dev.truewayerp.com, except the three marked SYNTHETIC.
// ===========================================================================

/// GET of a list holding 118 (simple, reviewed) and 119 (backorder, no reviews).
const kGetTwoItems = r'''
{"id":"ffffffff-1111-2222-3333-444444444444","data":{"count":2,"items":{"25fae31c24dc7b07150603d471a693bd":{"id":118,"rowId":"25fae31c24dc7b07150603d471a693bd","name":"Trueway Farms Organic Desi Khand Brown (khandsari) (Trueway Farms)","sku":"TRW3215","description":"<figure class=\"table\" style=\"width:513.25px;\"><table class=\"a-normal a-spacing-micro\" style=\"background-color:rgb(255,255,255);border-collapse:collapse;color:rgb(15,17,17);font-family:'Amazon Ember', Arial, sans-serif;font-size:14px;font-style:normal;font-weight:400;margin-bottom:0px;word-spacing:0px;\"><tbody><tr class=\"a-spacing-small po-brand\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Brand<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">TRUEWAY FARMS - AN ORGANIC LAND -NATURE TO NATURAL<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_form\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Form<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Crystal<\/span><\/td><\/tr><tr class=\"a-spacing-small po-flavor\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Flavour<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Desi khand<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_weight\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Weight<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">5000 Grams<\/span><\/td><\/tr><tr class=\"a-spacing-small po-container.type\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Package Information<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Packet<\/span><\/td><\/tr><tr class=\"a-spacing-small po-number_of_items\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Number of Items<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">1<\/span><\/td><\/tr><tr class=\"a-spacing-small po-unit_count\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Net Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">5000.0 Grams<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_package_quantity\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Package Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">1<\/span><\/td><\/tr><tr class=\"a-spacing-small po-specialty\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Speciality<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Certified Organic<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_package_weight\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Package Weight<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">5040 Grams<\/span><\/td><\/tr><\/tbody><\/table><\/figure>","slug":"trueway-farms-organic-desi-khand-brown-khandsari","with_storehouse_management":true,"quantity":93,"is_out_of_stock":false,"stock_status_label":"In stock","stock_status_html":"<span class=\"text-success\">In stock<\/span>","price":943.95,"price_formatted":"\u20b9943.95","original_price":1199.1,"original_price_formatted":"\u20b91,199.10","total_taxes_percentage":5,"reviews_avg":5,"reviews_count":1,"image_with_sizes":null,"weight":5100,"height":24,"wide":6,"length":19,"image_url":"https:\/\/dev.truewayerp.com\/storage\/products\/whole-wheat\/81xa52v7tol-sx679-150x150.jpg","is_variation":0,"original_product_id":118,"product_options":[],"store_id":10,"store":{"id":10,"name":"Trueway Farms","slug":"trueway-farms-1","logo":"https:\/\/dev.truewayerp.com\/storage\/logo\/twftrueway-farms-vertical-copy-3.png"}},"00e60eaa2ab22ce5e4fee92b429ba767":{"id":119,"rowId":"00e60eaa2ab22ce5e4fee92b429ba767","name":"Trueway Farms - An Organic Land -nature To Natural Sona Moti Wheat (sonamoti Gehu) (Trueway Farms)","sku":"TRW3314","description":"<figure class=\"table\" style=\"width:513.25px;\"><table class=\"a-normal a-spacing-micro\" style=\"background-color:rgb(255,255,255);border-collapse:collapse;color:rgb(15,17,17);font-family:'Amazon Ember', Arial, sans-serif;font-size:14px;font-style:normal;font-weight:400;margin-bottom:0px;word-spacing:0px;\"><tbody><tr class=\"a-spacing-small po-brand\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Brand<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">TRUEWAY FARMS - AN ORGANIC LAND -NATURE TO NATURAL<\/span><\/td><\/tr><tr class=\"a-spacing-small po-diet_type\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Diet Type<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Vegetarian<\/span><\/td><\/tr><tr class=\"a-spacing-small po-unit_count\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Net Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">15000.0 Grams<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_weight\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Weight<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">15 Kilograms<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_package_quantity\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Package Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">1<\/span><\/td><\/tr><\/tbody><\/table><\/figure>","slug":"trueway-farms-an-organic-land-nature-to-natural-sona-moti-wheat-sonamoti-gehu-sugar-free-wheat-15-kg","with_storehouse_management":false,"quantity":0,"is_out_of_stock":false,"stock_status_label":"On backorder","stock_status_html":"<span class=\"text-info\">On backorder<\/span>","price":3108,"price_formatted":"\u20b93,108.00","original_price":42005.25,"original_price_formatted":"\u20b942,005.25","total_taxes_percentage":5,"reviews_avg":null,"reviews_count":0,"image_with_sizes":null,"weight":15200,"height":34,"wide":8,"length":26,"image_url":"https:\/\/dev.truewayerp.com\/storage\/sliders\/817voulgejl-sl1500-150x150.jpg","is_variation":0,"original_product_id":119,"product_options":[],"store_id":10,"store":{"id":10,"name":"Trueway Farms","slug":"trueway-farms-1","logo":"https:\/\/dev.truewayerp.com\/storage\/logo\/twftrueway-farms-vertical-copy-3.png"}}}}}
''';

/// POST that ADDED 118 - carries `added: true` and a `message`.
const kToggleOn118 = r'''
{"id":"ffffffff-1111-2222-3333-444444444444","message":"Added product Trueway Farms Organic Desi Khand Brown (khandsari) successfully!","data":{"count":1,"added":true,"items":{"25fae31c24dc7b07150603d471a693bd":{"id":118,"rowId":"25fae31c24dc7b07150603d471a693bd","name":"Trueway Farms Organic Desi Khand Brown (khandsari) (Trueway Farms)","sku":"TRW3215","description":"<figure class=\"table\" style=\"width:513.25px;\"><table class=\"a-normal a-spacing-micro\" style=\"background-color:rgb(255,255,255);border-collapse:collapse;color:rgb(15,17,17);font-family:'Amazon Ember', Arial, sans-serif;font-size:14px;font-style:normal;font-weight:400;margin-bottom:0px;word-spacing:0px;\"><tbody><tr class=\"a-spacing-small po-brand\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Brand<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">TRUEWAY FARMS - AN ORGANIC LAND -NATURE TO NATURAL<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_form\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Form<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Crystal<\/span><\/td><\/tr><tr class=\"a-spacing-small po-flavor\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Flavour<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Desi khand<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_weight\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Weight<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">5000 Grams<\/span><\/td><\/tr><tr class=\"a-spacing-small po-container.type\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Package Information<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Packet<\/span><\/td><\/tr><tr class=\"a-spacing-small po-number_of_items\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Number of Items<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">1<\/span><\/td><\/tr><tr class=\"a-spacing-small po-unit_count\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Net Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">5000.0 Grams<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_package_quantity\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Package Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">1<\/span><\/td><\/tr><tr class=\"a-spacing-small po-specialty\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Speciality<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Certified Organic<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_package_weight\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Package Weight<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">5040 Grams<\/span><\/td><\/tr><\/tbody><\/table><\/figure>","slug":"trueway-farms-organic-desi-khand-brown-khandsari","with_storehouse_management":true,"quantity":93,"is_out_of_stock":false,"stock_status_label":"In stock","stock_status_html":"<span class=\"text-success\">In stock<\/span>","price":943.95,"price_formatted":"\u20b9943.95","original_price":1199.1,"original_price_formatted":"\u20b91,199.10","total_taxes_percentage":5,"reviews_avg":5,"reviews_count":1,"image_with_sizes":null,"weight":5100,"height":24,"wide":6,"length":19,"image_url":"https:\/\/dev.truewayerp.com\/storage\/products\/whole-wheat\/81xa52v7tol-sx679-150x150.jpg","is_variation":0,"original_product_id":118,"product_options":[],"store_id":10,"store":{"id":10,"name":"Trueway Farms","slug":"trueway-farms-1","logo":"https:\/\/dev.truewayerp.com\/storage\/logo\/twftrueway-farms-vertical-copy-3.png"}}}}}
''';

/// POST of a product already on the list: it was REMOVED. `added: false`,
/// and `items` collapses to a JSON array.
const kToggleOff = r'''
{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0020","message":"Removed product Trueway Farms Organic Desi Khand Brown (khandsari) from wishlist successfully!","data":{"count":0,"added":false,"items":[]}}
''';

/// GET of an identifier the server has never seen: 200, not 404.
const kEmptyList = r'''
{"id":"00000000-0000-0000-0000-000000000000","data":{"count":0,"items":[]}}
''';

/// Parent 111 plus variation 117. 117 has a blank `slug`, `is_variation: 1`,
/// `original_product_id: 111` and a pre-rendered `variation_attributes`.
const kVariationList = r'''
{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0010","message":"Added product Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu) successfully!","data":{"count":2,"added":true,"items":{"7afa05253badc98cd7ea149bc9794ca4":{"id":111,"rowId":"7afa05253badc98cd7ea149bc9794ca4","name":"Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu) (Trueway Farms)","sku":"TRW3214","description":"<div style=\"background-color:rgb(255,255,255);color:rgb(15,17,17);font-family:'Amazon Ember', Arial, sans-serif;font-size:14px;font-style:normal;font-weight:400;word-spacing:0px;\"><div class=\"a-section a-spacing-small a-spacing-top-small\" style=\"margin-bottom:0px;margin-top:8px;\"><figure class=\"table\" style=\"width:637.688px;\"><table class=\"a-normal a-spacing-micro\" style=\"border-collapse:collapse;margin-bottom:0px;\"><tbody><tr class=\"a-spacing-small po-brand\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:152.725px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Brand<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:484.962px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">TRUEWAY FARMS - AN ORGANIC LAND -NATURE TO NATURAL<\/span><\/td><\/tr><tr class=\"a-spacing-small po-diet_type\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:152.725px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Diet Type<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:484.962px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Vegetarian<\/span><\/td><\/tr><tr class=\"a-spacing-small po-unit_count\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:152.725px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Net Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:484.962px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">5000.0 Grams<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_weight\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:152.725px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Weight<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:484.962px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">5 Kilograms<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_package_quantity\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:152.725px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Package Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:484.962px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">1<\/span><\/td><\/tr><\/tbody><\/table><\/figure><\/div><\/div><p><br>\u00a0<\/p>","slug":"trueway-farms-organic-sona-moti-wheat-sonamoti-gehu-5kg-pack","with_storehouse_management":true,"quantity":1989,"is_out_of_stock":false,"stock_status_label":"In stock","stock_status_html":"<span class=\"text-success\">In stock<\/span>","price":921.501,"price_formatted":"\u20b9921.50","original_price":1296.75,"original_price_formatted":"\u20b91,296.75","total_taxes_percentage":5,"reviews_avg":5,"reviews_count":1,"image_with_sizes":null,"weight":5000,"height":34,"wide":8,"length":26,"image_url":"https:\/\/dev.truewayerp.com\/storage\/products\/whole-wheat\/81lm1nhmzol-sx679-150x150.jpg","is_variation":0,"original_product_id":111,"product_options":[],"store_id":10,"store":{"id":10,"name":"Trueway Farms","slug":"trueway-farms-1","logo":"https:\/\/dev.truewayerp.com\/storage\/logo\/twftrueway-farms-vertical-copy-3.png"}},"fdcb5e1e73c02961a4040b0a752b1ddb":{"id":117,"rowId":"fdcb5e1e73c02961a4040b0a752b1ddb","name":"Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu) (Trueway Farms)","sku":"TRUE-1114","description":"","slug":"","with_storehouse_management":true,"quantity":98,"is_out_of_stock":false,"stock_status_label":"In stock","stock_status_html":"<span class=\"text-success\">In stock<\/span>","price":493.5,"price_formatted":"\u20b9493.50","original_price":571.2,"original_price_formatted":"\u20b9571.20","total_taxes_percentage":5,"reviews_avg":null,"reviews_count":0,"image_with_sizes":null,"weight":1850,"height":34,"wide":8,"length":26,"image_url":"https:\/\/dev.truewayerp.com\/storage\/61bkclvifql-sl1191-150x150.jpg","is_variation":1,"original_product_id":111,"product_options":[],"variation_attributes":"(Pack Size: 1.85 KG (Pack of 1))","store_id":10,"store":{"id":10,"name":"Trueway Farms","slug":"trueway-farms-1","logo":"https:\/\/dev.truewayerp.com\/storage\/logo\/twftrueway-farms-vertical-copy-3.png"}}}}}
''';

/// The compare list. Same envelope; the item adds brand/categories/
/// attributes/variations/product_conditions, which nothing here reads.
const kCompareGet = r'''
{"id":"cccccccc-bbbb-cccc-dddd-eeeeeeee0001","data":{"count":2,"items":{"25fae31c24dc7b07150603d471a693bd":{"id":118,"rowId":"25fae31c24dc7b07150603d471a693bd","name":"Trueway Farms Organic Desi Khand Brown (khandsari) (Trueway Farms)","sku":"TRW3215","description":"<figure class=\"table\" style=\"width:513.25px;\"><table class=\"a-normal a-spacing-micro\" style=\"background-color:rgb(255,255,255);border-collapse:collapse;color:rgb(15,17,17);font-family:'Amazon Ember', Arial, sans-serif;font-size:14px;font-style:normal;font-weight:400;margin-bottom:0px;word-spacing:0px;\"><tbody><tr class=\"a-spacing-small po-brand\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Brand<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">TRUEWAY FARMS - AN ORGANIC LAND -NATURE TO NATURAL<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_form\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Form<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Crystal<\/span><\/td><\/tr><tr class=\"a-spacing-small po-flavor\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Flavour<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Desi khand<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_weight\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Weight<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">5000 Grams<\/span><\/td><\/tr><tr class=\"a-spacing-small po-container.type\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Package Information<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Packet<\/span><\/td><\/tr><tr class=\"a-spacing-small po-number_of_items\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Number of Items<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">1<\/span><\/td><\/tr><tr class=\"a-spacing-small po-unit_count\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Net Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">5000.0 Grams<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_package_quantity\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Package Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">1<\/span><\/td><\/tr><tr class=\"a-spacing-small po-specialty\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Speciality<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Certified Organic<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_package_weight\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Package Weight<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">5040 Grams<\/span><\/td><\/tr><\/tbody><\/table><\/figure>","slug":"trueway-farms-organic-desi-khand-brown-khandsari","with_storehouse_management":true,"quantity":93,"is_out_of_stock":false,"stock_status_label":"In stock","stock_status_html":"<span class=\"text-success\">In stock<\/span>","price":943.95,"price_formatted":"\u20b9943.95","original_price":1199.1,"original_price_formatted":"\u20b91,199.10","total_taxes_percentage":5,"reviews_avg":5,"reviews_count":1,"image_with_sizes":null,"weight":5100,"height":24,"wide":6,"length":19,"image_url":"https:\/\/dev.truewayerp.com\/storage\/products\/whole-wheat\/81xa52v7tol-sx679-150x150.jpg","product_conditions":[],"is_variation":0,"original_product_id":118,"brand":"Trueway Farms","categories":"","attributes":[],"variations":[],"product_options":[],"store_id":10,"store":{"id":10,"name":"Trueway Farms","slug":"trueway-farms-1","logo":"https:\/\/dev.truewayerp.com\/storage\/logo\/twftrueway-farms-vertical-copy-3.png"}},"00e60eaa2ab22ce5e4fee92b429ba767":{"id":119,"rowId":"00e60eaa2ab22ce5e4fee92b429ba767","name":"Trueway Farms - An Organic Land -nature To Natural Sona Moti Wheat (sonamoti Gehu) (Trueway Farms)","sku":"TRW3314","description":"<figure class=\"table\" style=\"width:513.25px;\"><table class=\"a-normal a-spacing-micro\" style=\"background-color:rgb(255,255,255);border-collapse:collapse;color:rgb(15,17,17);font-family:'Amazon Ember', Arial, sans-serif;font-size:14px;font-style:normal;font-weight:400;margin-bottom:0px;word-spacing:0px;\"><tbody><tr class=\"a-spacing-small po-brand\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Brand<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">TRUEWAY FARMS - AN ORGANIC LAND -NATURE TO NATURAL<\/span><\/td><\/tr><tr class=\"a-spacing-small po-diet_type\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Diet Type<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Vegetarian<\/span><\/td><\/tr><tr class=\"a-spacing-small po-unit_count\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Net Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">15000.0 Grams<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_weight\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Weight<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">15 Kilograms<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_package_quantity\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Package Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">1<\/span><\/td><\/tr><\/tbody><\/table><\/figure>","slug":"trueway-farms-an-organic-land-nature-to-natural-sona-moti-wheat-sonamoti-gehu-sugar-free-wheat-15-kg","with_storehouse_management":false,"quantity":0,"is_out_of_stock":false,"stock_status_label":"On backorder","stock_status_html":"<span class=\"text-info\">On backorder<\/span>","price":3108,"price_formatted":"\u20b93,108.00","original_price":42005.25,"original_price_formatted":"\u20b942,005.25","total_taxes_percentage":5,"reviews_avg":null,"reviews_count":0,"image_with_sizes":null,"weight":15200,"height":34,"wide":8,"length":26,"image_url":"https:\/\/dev.truewayerp.com\/storage\/sliders\/817voulgejl-sl1500-150x150.jpg","product_conditions":[],"is_variation":0,"original_product_id":119,"brand":"Trueway Farms","categories":"Sona Moti Wheat","attributes":[],"variations":[],"product_options":[],"store_id":10,"store":{"id":10,"name":"Trueway Farms","slug":"trueway-farms-1","logo":"https:\/\/dev.truewayerp.com\/storage\/logo\/twftrueway-farms-vertical-copy-3.png"}}}}}
''';

/// 119: `reviews_avg: null`, `price` an integer, `quantity: 0` while
/// `is_out_of_stock: false` (untracked stock).
const kAdd119 = r'''
{"id":"d3b51ed5-c9ce-4a12-96c1-c147d76ceaa9","message":"Added product Trueway Farms - An Organic Land -nature To Natural Sona Moti Wheat (sonamoti Gehu) successfully!","data":{"count":1,"added":true,"items":{"00e60eaa2ab22ce5e4fee92b429ba767":{"id":119,"rowId":"00e60eaa2ab22ce5e4fee92b429ba767","name":"Trueway Farms - An Organic Land -nature To Natural Sona Moti Wheat (sonamoti Gehu) (Trueway Farms)","sku":"TRW3314","description":"<figure class=\"table\" style=\"width:513.25px;\"><table class=\"a-normal a-spacing-micro\" style=\"background-color:rgb(255,255,255);border-collapse:collapse;color:rgb(15,17,17);font-family:'Amazon Ember', Arial, sans-serif;font-size:14px;font-style:normal;font-weight:400;margin-bottom:0px;word-spacing:0px;\"><tbody><tr class=\"a-spacing-small po-brand\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Brand<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">TRUEWAY FARMS - AN ORGANIC LAND -NATURE TO NATURAL<\/span><\/td><\/tr><tr class=\"a-spacing-small po-diet_type\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Diet Type<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">Vegetarian<\/span><\/td><\/tr><tr class=\"a-spacing-small po-unit_count\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Net Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">15000.0 Grams<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_weight\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Weight<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">15 Kilograms<\/span><\/td><\/tr><tr class=\"a-spacing-small po-item_package_quantity\" style=\"margin-bottom:8px;\"><td class=\"a-span3\" style=\"margin-right:0px;padding:0.1875rem;width:122.922px;\"><span class=\"a-size-base a-text-bold\" style=\"font-size:14px;line-height:20px;\"><strong>Item Package Quantity<\/strong><\/span><\/td><td class=\"a-span9\" style=\"margin-right:0px;padding:0.1875rem;width:390.328px;\"><span class=\"a-size-base po-break-word\" style=\"font-size:14px;line-height:20px;\">1<\/span><\/td><\/tr><\/tbody><\/table><\/figure>","slug":"trueway-farms-an-organic-land-nature-to-natural-sona-moti-wheat-sonamoti-gehu-sugar-free-wheat-15-kg","with_storehouse_management":false,"quantity":0,"is_out_of_stock":false,"stock_status_label":"On backorder","stock_status_html":"<span class=\"text-info\">On backorder<\/span>","price":3108,"price_formatted":"\u20b93,108.00","original_price":42005.25,"original_price_formatted":"\u20b942,005.25","total_taxes_percentage":5,"reviews_avg":null,"reviews_count":0,"image_with_sizes":null,"weight":15200,"height":34,"wide":8,"length":26,"image_url":"https:\/\/dev.truewayerp.com\/storage\/sliders\/817voulgejl-sl1500-150x150.jpg","is_variation":0,"original_product_id":119,"product_options":[],"store_id":10,"store":{"id":10,"name":"Trueway Farms","slug":"trueway-farms-1","logo":"https:\/\/dev.truewayerp.com\/storage\/logo\/twftrueway-farms-vertical-copy-3.png"}}}}}
''';

/// HTTP 404 body for DELETE of a product that is not on the list. `error`
/// is a STRING here, and this response also wiped the whole list.
const kDeleteNotInList = r'''
{"error":"Product not found in wishlist"}
''';

/// HTTP 422 from the FormRequest. Fires before the controller runs, so
/// unlike the 404 above it leaves the stored list intact.
const kInvalidProductId = r'''
{"message":"The selected product id is invalid.","errors":{"product_id":["The selected product id is invalid."]}}
''';

/// Identifiers are echoed verbatim and need not be UUIDs.
const kNumericIdentifier = r'''
{"id":"118","data":{"count":0,"items":[]}}
''';

/// SYNTHETIC — not captured; derived from `WishlistItemResource::toArray()`,
/// which returns a bare `[]` when the product row no longer exists. The line
/// still occupies a slot in `data.count`.
const kGhostItem = r'''
{"id":"ghost-list","data":{"count":2,"items":{"25fae31c24dc7b07150603d471a693bd":{"id":118,"rowId":"25fae31c24dc7b07150603d471a693bd","name":"Trueway Farms Organic Desi Khand Brown (khandsari)","sku":"TRW3215","slug":"trueway-farms-organic-desi-khand-brown-khandsari","quantity":93,"is_out_of_stock":false,"stock_status_label":"In stock","price":943.95,"price_formatted":"₹943.95","original_price":1199.1,"original_price_formatted":"₹1,199.10","reviews_avg":5,"reviews_count":1,"image_with_sizes":null,"weight":5100,"image_url":"https://dev.truewayerp.com/x-150x150.jpg","is_variation":0,"original_product_id":118,"product_options":[]},"deadbeefdeadbeefdeadbeefdeadbeef":[]}}}
''';

/// SYNTHETIC — money as a 2dp string with a `*_formatted` twin, the shape other
/// endpoints on this backend use. The wishlist has only ever been observed
/// sending `num`, so this guards the coercion rather than documenting it.
const kStringMoney = r'''
{"id":"str-money","data":{"count":1,"items":{"aa":{"id":118,"rowId":"aa","name":"Khand","sku":"TRW3215","slug":"khand","quantity":"93","is_out_of_stock":0,"stock_status_label":"In stock","price":"943.95","price_formatted":"₹943.95","original_price":"1199.10","original_price_formatted":"₹1,199.10","reviews_avg":"4.5","reviews_count":"1","image_with_sizes":null,"weight":"5100","image_url":"https://dev.truewayerp.com/x.jpg","is_variation":"0","original_product_id":"118","product_options":[]}}}}
''';

/// SYNTHETIC — the envelope with `data` missing entirely, i.e. the contract
/// broken outright. Nothing may throw.
const kNoData = r'{"id":"broken"}';

// ===========================================================================
// Test doubles
// ===========================================================================

class _Canned {
  const _Canned(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

/// Replays canned responses keyed by `METHOD /path`, in order, and records what
/// was sent. A queue rather than a single value because the toggle semantics
/// mean the same path is hit repeatedly with different outcomes.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);

  final Map<String, List<_Canned>> responses;
  final List<RequestOptions> requests = [];

  List<String> get calls => [for (final r in requests) '${r.method} ${r.path}'];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final key = '${options.method} ${options.path}';
    final queue = responses[key];
    final canned = (queue == null || queue.isEmpty)
        ? _Canned(500, '{"message":"no canned response for $key"}')
        : (queue.length == 1 ? queue.first : queue.removeAt(0));
    return ResponseBody.fromString(
      canned.body,
      canned.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

typedef _Harness = ({
  WishlistRepository wishlist,
  CompareRepository compare,
  SharedPreferences prefs,
  _FakeAdapter adapter,
});

Future<_Harness> _build(
  Map<String, List<_Canned>> responses, {
  Map<String, Object> seed = const {},
}) async {
  SharedPreferences.setMockInitialValues(seed);
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(responses);
  final api = ApiClient(prefs: prefs, dio: Dio()..httpClientAdapter = adapter);
  return (
    wishlist: WishlistRepository(api, prefs),
    compare: CompareRepository(api, prefs),
    prefs: prefs,
    adapter: adapter,
  );
}

const _id = 'ffffffff-1111-2222-3333-444444444444';
const _wlRoot = '/ecommerce/wishlist';
const _wlId = '$_wlRoot/$_id';

_Canned _ok(String body) => _Canned(200, body);

/// [kVariationList] with the parent row dropped, so the list holds *only* the
/// variation 117 — the state a product-detail page produces when the customer
/// wishlists a chosen variant.
///
/// Every byte of the surviving row and of the envelope is the captured one; the
/// only edit is deleting the other entry and correcting `count`, which is what
/// the server would have sent had 111 never been added.
final String _variationOnly = (() {
  final root = Map<String, dynamic>.from(
    jsonDecode(kVariationList) as Map<String, dynamic>,
  );
  final data = Map<String, dynamic>.from(root['data'] as Map);
  final items = Map<String, dynamic>.from(data['items'] as Map)
    ..removeWhere((_, v) => (v as Map)['id'] != 117);
  return jsonEncode({
    ...root,
    'data': {...data, 'count': 1, 'items': items},
  });
})();

Future<Object?> _errorFrom(Future<Object?> future) =>
    future.then<Object?>((_) => null, onError: (Object e) => e);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // =========================================================================
  group('WishlistSnapshot.fromJson', () {
    test('parses the happy path: items keyed by rowId under data', () {
      final s = WishlistSnapshot.fromJson(jsonDecode(kGetTwoItems));

      expect(s.id, _id);
      expect(s.serverCount, 2);
      expect(s.count, 2);
      expect(s.entries.map((e) => e.product.id), [118, 119]);
      expect(s.entries.first.rowId, '25fae31c24dc7b07150603d471a693bd');
      expect(s.entries.first.product.priceFormatted, '₹943.95');
      expect(s.entries.first.product.price, 943.95);
      // No `message` and no `added` on a plain read.
      expect(s.message, isNull);
      expect(s.added, isNull);
    });

    test('empty list arrives as items: [] , not {}', () {
      final s = WishlistSnapshot.fromJson(jsonDecode(kEmptyList));

      expect(s.entries, isEmpty);
      expect(s.isEmpty, isTrue);
      expect(s.serverCount, 0);
      expect(s.id, '00000000-0000-0000-0000-000000000000');
    });

    test('toggle-off response: added false, items collapse to an array', () {
      final s = WishlistSnapshot.fromJson(jsonDecode(kToggleOff));

      expect(s.added, isFalse);
      expect(s.entries, isEmpty);
      expect(s.message, contains('Removed product'));
    });

    test('toggle-on response carries added: true', () {
      final s = WishlistSnapshot.fromJson(jsonDecode(kToggleOn118));

      expect(s.added, isTrue);
      expect(s.count, 1);
      expect(s.message, contains('Added product'));
    });

    test('variation row: blank slug, parent id, rendered attribute label', () {
      final s = WishlistSnapshot.fromJson(jsonDecode(kVariationList));
      final variation = s.entries.firstWhere((e) => e.product.id == 117);

      expect(variation.isVariation, isTrue);
      expect(variation.product.slug, isEmpty);
      expect(variation.originalProductId, 111);
      expect(variation.variationAttributes, contains('Pack Size'));
      // Mutations must echo the variation id, never the parent.
      expect(variation.mutationId, 117);

      final parent = s.entries.firstWhere((e) => e.product.id == 111);
      expect(parent.isVariation, isFalse);
      expect(parent.variationAttributes, isNull);
      expect(parent.originalProductId, 111);
    });

    test(
        'a card for the parent shows as wishlisted when only the variation '
        'is on the list', () {
      final s = WishlistSnapshot.fromJson(jsonDecode(kVariationList));

      expect(s.contains(117), isTrue);
      expect(s.contains(111), isTrue);
      expect(s.contains(118), isFalse);
      expect(s.entryFor(111)!.product.id, 111);
    });

    test(
        'nullable fields absent: reviews_avg null, image_with_sizes null, '
        'integral price', () {
      final s = WishlistSnapshot.fromJson(jsonDecode(kAdd119));
      final p = s.entries.single.product;

      expect(p.reviewsAvg, isNull);
      expect(p.rating, 0);
      expect(p.reviewsCount, 0);
      expect(p.price, 3108.0);
      expect(p.images, isEmpty);
      expect(p.primaryImage, startsWith('https://'));
      // `content`, `images` and `videos` are simply not in this resource.
      expect(p.content, isEmpty);
      expect(p.videos, isEmpty);
      // quantity 0 with is_out_of_stock false — untracked stock, still buyable.
      expect(p.quantity, 0);
      expect(p.inStock, isTrue);
      expect(p.stockNote, 'On backorder');
    });

    test('money as a 2dp string coerces, formatted twin still preferred', () {
      final s = WishlistSnapshot.fromJson(jsonDecode(kStringMoney));
      final p = s.entries.single.product;

      expect(p.price, 943.95);
      expect(p.originalPrice, 1199.10);
      expect(p.priceFormatted, '₹943.95');
      expect(p.quantity, 93);
      expect(p.reviewsAvg, 4.5);
      expect(p.isOutOfStock, isFalse);
      expect(s.entries.single.isVariation, isFalse);
      expect(s.entries.single.originalProductId, 118);
    });

    test('a row whose product was deleted is skipped, and count disagrees', () {
      final s = WishlistSnapshot.fromJson(jsonDecode(kGhostItem));

      expect(s.count, 1);
      expect(s.serverCount, 2);
      expect(s.entries.single.product.id, 118);
    });

    test('a missing data block yields an empty snapshot rather than throwing',
        () {
      final s = WishlistSnapshot.fromJson(jsonDecode(kNoData));

      expect(s.id, 'broken');
      expect(s.entries, isEmpty);
      expect(s.serverCount, 0);
    });

    test('non-map bodies do not throw', () {
      expect(WishlistSnapshot.fromJson(null).entries, isEmpty);
      expect(WishlistSnapshot.fromJson('nope').entries, isEmpty);
      expect(WishlistSnapshot.fromJson(const <int>[1, 2]).entries, isEmpty);
      expect(WishlistSnapshot.fromJson(null, fallbackId: 'x').id, 'x');
    });

    test('identifiers are echoed verbatim and need not be UUIDs', () {
      expect(
        WishlistSnapshot.fromJson(jsonDecode(kNumericIdentifier)).id,
        '118',
      );
    });

    test('compare shares the envelope; its extra item keys are ignored', () {
      final s = WishlistSnapshot.fromJson(jsonDecode(kCompareGet));

      expect(s.count, 2);
      expect(s.entries.map((e) => e.product.id), [118, 119]);
      expect(s.entries.first.product.name, contains('Khand'));
    });
  });

  // =========================================================================
  group('reads', () {
    test('refresh with no stored identifier makes no request', () async {
      final h = await _build({});

      final s = await h.wishlist.refresh();

      expect(s.isEmpty, isTrue);
      expect(s.id, isNull);
      expect(h.adapter.requests, isEmpty);
    });

    test('refresh reads the stored identifier and caches the result', () async {
      final h = await _build(
        {'GET $_wlId': [_ok(kGetTwoItems)]},
        seed: {'wishlist_id': _id},
      );

      final s = await h.wishlist.refresh();

      expect(s.count, 2);
      expect(h.wishlist.latest, same(s));
      expect(h.adapter.calls, ['GET $_wlId']);
    });

    test('contains uses the cache instead of re-fetching', () async {
      final h = await _build(
        {'GET $_wlId': [_ok(kGetTwoItems)]},
        seed: {'wishlist_id': _id},
      );

      expect(await h.wishlist.contains(118), isTrue);
      expect(await h.wishlist.contains(999), isFalse);
      expect(h.adapter.calls, ['GET $_wlId']);
    });

    test('compare uses its own path and its own storage key', () async {
      final h = await _build(
        {'GET /ecommerce/compare/cmp-1': [_ok(kCompareGet)]},
        seed: {'wishlist_id': _id, 'compare_id': 'cmp-1'},
      );

      final s = await h.compare.refresh();

      expect(s.count, 2);
      expect(h.adapter.calls, ['GET /ecommerce/compare/cmp-1']);
    });
  });

  // =========================================================================
  group('toggle', () {
    test('first POST goes to the bare route and persists the minted id',
        () async {
      final h = await _build({
        'POST $_wlRoot': [_ok(kToggleOn118)],
      });

      final s = await h.wishlist.toggle(118);

      expect(s.added, isTrue);
      expect(h.prefs.getString('wishlist_id'), _id);
      expect(h.wishlist.identifier, _id);
      expect(h.adapter.calls, ['POST $_wlRoot']);
      expect(h.adapter.requests.single.data, {'product_id': 118});
    });

    test('later POSTs go to the id route', () async {
      final h = await _build(
        {'POST $_wlId': [_ok(kToggleOn118)]},
        seed: {'wishlist_id': _id},
      );

      await h.wishlist.toggle(118);

      expect(h.adapter.calls, ['POST $_wlId']);
    });

    test('add is a no-op when the product is already on the list', () async {
      final h = await _build(
        {'GET $_wlId': [_ok(kGetTwoItems)]},
        seed: {'wishlist_id': _id},
      );

      final s = await h.wishlist.add(118);

      expect(s.count, 2);
      expect(h.adapter.calls, ['GET $_wlId'], reason: 'no POST issued');
    });

    test('add corrects itself when a stale cache makes the toggle remove',
        () async {
      // Cache says empty, but the list actually held the product, so the first
      // POST takes it off. `added: false` betrays that and a second POST puts
      // it back.
      final h = await _build(
        {
          'GET $_wlId': [_ok(kEmptyList)],
          'POST $_wlId': [_ok(kToggleOff), _ok(kToggleOn118)],
        },
        seed: {'wishlist_id': _id},
      );

      final s = await h.wishlist.add(118);

      expect(s.added, isTrue);
      expect(s.count, 1);
      expect(h.adapter.calls, [
        'GET $_wlId',
        'POST $_wlId',
        'POST $_wlId',
      ]);
    });

    test('the corrective toggle fires at most once', () async {
      // Server keeps answering `added: true` although removal was asked for.
      // One correction, then stop — no unbounded ping-pong.
      final h = await _build(
        {
          'GET $_wlId': [_ok(kGetTwoItems)],
          'POST $_wlId': [_ok(kToggleOn118)],
        },
        seed: {'wishlist_id': _id},
      );

      await h.wishlist.remove(118);

      expect(h.adapter.calls.where((c) => c.startsWith('POST')).length, 2);
    });

    test('remove never touches DELETE', () async {
      final h = await _build(
        {
          'GET $_wlId': [_ok(kGetTwoItems)],
          'POST $_wlId': [_ok(kToggleOff)],
        },
        seed: {'wishlist_id': _id},
      );

      final s = await h.wishlist.remove(118);

      expect(s.isEmpty, isTrue);
      expect(h.adapter.calls.any((c) => c.startsWith('DELETE')), isFalse);
    });

    test('remove is a no-op when the product was never on the list', () async {
      final h = await _build(
        {'GET $_wlId': [_ok(kEmptyList)]},
        seed: {'wishlist_id': _id},
      );

      await h.wishlist.remove(118);

      expect(h.adapter.calls, ['GET $_wlId']);
    });

    test('clear empties the list without a DELETE', () async {
      final h = await _build(
        {
          'GET $_wlId': [_ok(kGetTwoItems)],
          'POST $_wlId': [_ok(kToggleOff)],
        },
        seed: {'wishlist_id': _id},
      );

      final s = await h.wishlist.clear();

      expect(s.isEmpty, isTrue);
      expect(h.adapter.calls.any((c) => c.startsWith('DELETE')), isFalse);
    });

    test('removing by parent id posts the stored variation id', () async {
      // The list holds variation 117 only. A product card knows nothing of
      // variations, so it asks to remove 111 — and `contains(111)` is true.
      // Posting 111 would not match the stored line: the server would ADD 111
      // as a second row, the correction would remove it again, and 117 would
      // still be wishlisted while `remove` reported success.
      final h = await _build(
        {
          'GET $_wlId': [_ok(_variationOnly)],
          'POST $_wlId': [_ok(kToggleOff)],
        },
        seed: {'wishlist_id': _id},
      );

      final s = await h.wishlist.remove(111);

      final posts = h.adapter.requests.where((r) => r.method == 'POST');
      expect(posts.map((r) => r.data), [
        {'product_id': 117},
      ]);
      expect(s.isEmpty, isTrue);
      expect(s.contains(111), isFalse);
    });

    test('an exact line id beats a parent match when both rows are present',
        () async {
      // kVariationList holds parent 111 AND variation 117; removing 111 must
      // remove the parent row, not whichever row happens to come first.
      final h = await _build(
        {
          'GET $_wlId': [_ok(kVariationList)],
          'POST $_wlId': [_ok(kToggleOff)],
        },
        seed: {'wishlist_id': _id},
      );

      await h.wishlist.remove(111);

      expect(
        h.adapter.requests.firstWhere((r) => r.method == 'POST').data,
        {'product_id': 111},
      );
    });

    test('a failed POST re-reads the list instead of trusting the cache',
        () async {
      // POST is destructive on failure: the controller restores (deleting the
      // stored row) before it can fail, and only stores on the way out. A 500
      // therefore means the list is probably gone.
      final h = await _build(
        {
          'GET $_wlId': [_ok(kGetTwoItems), _ok(kEmptyList)],
          'POST $_wlId': [const _Canned(500, '{"message":"Server Error"}')],
        },
        seed: {'wishlist_id': _id},
      );

      await h.wishlist.refresh();
      expect(h.wishlist.latest!.count, 2);

      final error = await _errorFrom(h.wishlist.toggle(118));

      expect((error! as ApiException).kind, ApiErrorKind.server);
      expect(
        h.wishlist.latest!.isEmpty,
        isTrue,
        reason: 'the failed POST wiped the list; the cache must not deny it',
      );
      expect(h.adapter.calls, ['GET $_wlId', 'POST $_wlId', 'GET $_wlId']);
    });

    test('add/remove inherit the re-read, and drop the cache if it fails',
        () async {
      final h = await _build(
        {
          'GET $_wlId': [
            _ok(kGetTwoItems),
            const _Canned(503, '{"message":"down"}'),
          ],
          'POST $_wlId': [const _Canned(500, '{"message":"Server Error"}')],
        },
        seed: {'wishlist_id': _id},
      );

      final error = await _errorFrom(h.wishlist.remove(118));

      expect((error! as ApiException).kind, ApiErrorKind.server);
      expect(
        h.wishlist.latest,
        isNull,
        reason: 'nothing is known about the list any more',
      );
    });

    test('a failed mint leaves no identifier and no cached list', () async {
      final h = await _build({
        'POST $_wlRoot': [const _Canned(500, '{"message":"Server Error"}')],
      });

      await _errorFrom(h.wishlist.toggle(118));

      expect(h.wishlist.identifier, isNull);
      expect(h.wishlist.latest, isNull);
      // Nothing to read back — no identifier was ever learned.
      expect(h.adapter.calls, ['POST $_wlRoot']);
    });

    test('a 422 from the FormRequest surfaces as a validation ApiException',
        () async {
      final h = await _build({
        'POST $_wlRoot': [_Canned(422, kInvalidProductId)],
      });

      final error = await _errorFrom(h.wishlist.toggle(999999));

      expect(error, isA<ApiException>());
      final api = error! as ApiException;
      expect(api.kind, ApiErrorKind.validation);
      expect(api.fieldErrors!['product_id'], isNotEmpty);
      expect(api.message, 'The selected product id is invalid.');
      // Validation runs before the controller, so no identifier was minted.
      expect(h.wishlist.identifier, isNull);
    });
  });

  // =========================================================================
  group('removeViaDelete — the list-wiping route', () {
    test('refuses to call DELETE for a product that is not on the list',
        () async {
      // This guard is the whole reason the method is safe to expose: the miss
      // path on the server 404s AND destroys the stored list.
      final h = await _build(
        {'GET $_wlId': [_ok(kEmptyList)]},
        seed: {'wishlist_id': _id},
      );

      final s = await h.wishlist.removeViaDelete(119);

      expect(s.isEmpty, isTrue);
      expect(h.adapter.calls, ['GET $_wlId']);
    });

    test('sends product_id and returns the new state on success', () async {
      final h = await _build(
        {
          'GET $_wlId': [_ok(kGetTwoItems)],
          'DELETE $_wlId': [_ok(kToggleOff)],
        },
        seed: {'wishlist_id': _id},
      );

      await h.wishlist.removeViaDelete(118);

      final del = h.adapter.requests.firstWhere((r) => r.method == 'DELETE');
      expect(del.data, {'product_id': 118});
    });

    test('re-fetches after a failure and reports the list as wiped', () async {
      // Verified live: list [118, 119] -> DELETE a product the server cannot
      // match -> 404 -> the next GET returns count 0. The cached snapshot must
      // not be believed after this.
      final h = await _build(
        {
          'GET $_wlId': [_ok(kGetTwoItems), _ok(kEmptyList)],
          'DELETE $_wlId': [_Canned(404, kDeleteNotInList)],
        },
        seed: {'wishlist_id': _id},
      );

      final error = await _errorFrom(h.wishlist.removeViaDelete(119));

      expect(error, isA<ApiException>());
      final api = error! as ApiException;
      expect(api.kind, ApiErrorKind.notFound);
      // `error` is a bare string on this branch, not the usual bool.
      expect(api.serverMessage, 'Product not found in wishlist');

      expect(
        h.wishlist.latest!.isEmpty,
        isTrue,
        reason: 'the failed DELETE destroyed the list',
      );
      expect(h.adapter.calls, [
        'GET $_wlId',
        'DELETE $_wlId',
        'GET $_wlId',
      ]);
    });

    test('the original error wins when the recovery read also fails', () async {
      final h = await _build(
        {
          'GET $_wlId': [
            _ok(kGetTwoItems),
            const _Canned(503, '{"message":"down"}'),
          ],
          'DELETE $_wlId': [_Canned(404, kDeleteNotInList)],
        },
        seed: {'wishlist_id': _id},
      );

      final error = await _errorFrom(h.wishlist.removeViaDelete(119));

      expect((error! as ApiException).kind, ApiErrorKind.notFound);
      expect(
        h.wishlist.latest,
        isNull,
        reason: 'the cache describes a list the DELETE probably destroyed; '
            'unknown is honest, stale is a lie',
      );
    });

    test('targets the stored variation, never the parent id', () async {
      // `contains(111)` is true because the variation carries
      // `original_product_id: 111`. Sending 111 is the exact miss that 404s
      // AND wipes the list, so the parent id must never reach the wire.
      final h = await _build(
        {
          'GET $_wlId': [_ok(_variationOnly)],
          'DELETE $_wlId': [_ok(kToggleOff)],
        },
        seed: {'wishlist_id': _id},
      );

      await h.wishlist.removeViaDelete(111);

      final del = h.adapter.requests.firstWhere((r) => r.method == 'DELETE');
      expect(del.data, {'product_id': 117});
    });

    test('does nothing at all before an identifier exists', () async {
      final h = await _build({});

      expect((await h.wishlist.removeViaDelete(118)).isEmpty, isTrue);
      expect(h.adapter.requests, isEmpty);
    });
  });

  // =========================================================================
  group('identifier persistence', () {
    test('survives a new repository instance over the same prefs', () async {
      final h = await _build({
        'POST $_wlRoot': [_ok(kToggleOn118)],
      });
      await h.wishlist.toggle(118);

      final api = ApiClient(
        prefs: h.prefs,
        dio: Dio()..httpClientAdapter = h.adapter,
      );
      expect(WishlistRepository(api, h.prefs).identifier, _id);
    });

    test('forget drops the local id and the cache only', () async {
      final h = await _build(
        {'GET $_wlId': [_ok(kGetTwoItems)]},
        seed: {'wishlist_id': _id},
      );
      await h.wishlist.refresh();

      await h.wishlist.forget();

      expect(h.wishlist.identifier, isNull);
      expect(h.wishlist.latest, isNull);
      expect(h.prefs.getString('wishlist_id'), isNull);
    });

    test('an empty stored id is treated as absent', () async {
      final h = await _build({}, seed: {'wishlist_id': ''});

      expect(h.wishlist.identifier, isNull);
      expect((await h.wishlist.refresh()).isEmpty, isTrue);
      expect(h.adapter.requests, isEmpty);
    });

    test('wishlist and compare identifiers do not collide', () async {
      final h = await _build({
        'POST $_wlRoot': [_ok(kToggleOn118)],
        'POST /ecommerce/compare': [_ok(kCompareGet)],
      });

      await h.wishlist.toggle(118);
      await h.compare.toggle(118);

      expect(h.prefs.getString('wishlist_id'), _id);
      expect(
        h.prefs.getString('compare_id'),
        'cccccccc-bbbb-cccc-dddd-eeeeeeee0001',
      );
    });

    test('the whole flow needs no bearer token', () async {
      final h = await _build({
        'POST $_wlRoot': [_ok(kToggleOn118)],
      });

      await h.wishlist.toggle(118);

      expect(
        h.adapter.requests.single.headers.containsKey('Authorization'),
        isFalse,
      );
    });
  });
}

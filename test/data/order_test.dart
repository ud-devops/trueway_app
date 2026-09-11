import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/core/network/api_response.dart';
import 'package:trueway_farms/data/models/order.dart';
import 'package:trueway_farms/data/models/order_return.dart';
import 'package:trueway_farms/data/repositories/order_repository.dart';

// ===========================================================================
// Payloads
// ===========================================================================
//
// Captured verbatim from dev.truewayerp.com against the client's real
// 90-order / 10-return test account, then pasted here as raw strings so the
// suite never touches the network. Each one was picked because it carries a
// shape that broke a naive decoder — see the comment above it.
//
// Two payloads are marked TRIMMED. Nothing was reshaped in them; whole
// sub-objects the models deliberately ignore were dropped so the literal stays
// readable, and each omission is called out where it happened.

/// `GET /ecommerce/orders?per_page=1` — the hybrid envelope
/// (`data + links + meta + error + message`) and, because 90 pages is more than
/// the pager renders, the `...` entry in `meta.links` that has NO `page` key.
const String _ordersPerPage1 = r'''
{
 "data": [
  {
   "id": 277,
   "code": "SF10000277",
   "status": {"value": "processing", "label": "Processing"},
   "status_html": {},
   "customer": {"name": "Suraj ojha", "email": "suraj.ojha@uminber.in", "phone": "8305317276"},
   "created_at": "2026-07-16T17:04:00+05:30",
   "amount": "1274.15",
   "amount_formatted": "₹1,274.15",
   "tax_amount": "44.95",
   "tax_amount_formatted": "₹44.95",
   "shipping_amount": "330.20",
   "shipping_amount_formatted": "₹330.20",
   "shipping_method": {"value": "shiprocket", "label": "ShipRocket"},
   "shipping_status": {"value": "approved", "label": "Approved"},
   "shipping_status_html": {},
   "shipping_info": {
    "name": "Suraj ojha",
    "phone": "8305317276",
    "email": "suraj.ojha@uminber.in",
    "address": "306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad",
    "city": "574",
    "state": "11",
    "country": "India",
    "zip_code": "382415"
   },
   "billing_info": {
    "name": null, "phone": null, "email": null, "address": null,
    "city": null, "state": null, "country": null, "zip_code": null
   },
   "payment_method": {"value": "razorpay", "label": "Razorpay"},
   "payment_status": {"value": "completed", "label": "Completed"},
   "payment_status_html": {},
   "products_count": 1,
   "product_image": "https://dev.truewayerp.com/storage/map-location-150x150.png",
   "product_images": ["https://dev.truewayerp.com/storage/map-location-150x150.png"]
  }
 ],
 "links": {
  "first": "https://dev.truewayerp.com/api/v1/ecommerce/orders?page=1",
  "last": "https://dev.truewayerp.com/api/v1/ecommerce/orders?page=90",
  "prev": null,
  "next": "https://dev.truewayerp.com/api/v1/ecommerce/orders?page=2"
 },
 "meta": {
  "current_page": 1,
  "from": 1,
  "last_page": 90,
  "links": [
   {"url": null, "label": "&laquo; Previous", "page": null, "active": false},
   {"url": "https://dev.truewayerp.com/api/v1/ecommerce/orders?page=1", "label": "1", "page": 1, "active": true},
   {"url": "https://dev.truewayerp.com/api/v1/ecommerce/orders?page=2", "label": "2", "page": 2, "active": false},
   {"url": null, "label": "...", "active": false},
   {"url": "https://dev.truewayerp.com/api/v1/ecommerce/orders?page=90", "label": "90", "page": 90, "active": false},
   {"url": "https://dev.truewayerp.com/api/v1/ecommerce/orders?page=2", "label": "Next &raquo;", "page": 2, "active": false}
  ],
  "path": "https://dev.truewayerp.com/api/v1/ecommerce/orders",
  "per_page": 1,
  "to": 1,
  "total": 90
 },
 "error": false,
 "message": null
}
''';

/// Order 47 — every degenerate form the 90-row list contains, in one row:
/// the legacy `#SF-` code, `shipping_method` with EMPTY STRINGS,
/// `shipping_status` with a NULL value, `shipping_status_html` as a STRING
/// where 83 other rows send `{}`, an all-null `shipping_info`, a null
/// `product_image` and an empty `product_images`.
const String _degenerateRow = r'''
{
 "id": 47,
 "code": "#SF-10000047",
 "status": {"value": "completed", "label": "Completed"},
 "status_html": {},
 "customer": {"name": "Suraj ojha", "email": "suraj.ojha@uminber.in", "phone": "8305317276"},
 "created_at": "2025-11-03T21:11:53+05:30",
 "amount": "1707.30",
 "amount_formatted": "₹1,707.30",
 "tax_amount": "81.30",
 "tax_amount_formatted": "₹81.30",
 "shipping_amount": "0.00",
 "shipping_amount_formatted": "₹0.00",
 "shipping_method": {"value": "", "label": ""},
 "shipping_status": {"value": null, "label": ""},
 "shipping_status_html": "",
 "shipping_info": {
  "name": null, "phone": null, "email": null, "address": null,
  "city": null, "state": null, "country": null, "zip_code": null
 },
 "billing_info": {
  "name": null, "phone": null, "email": null, "address": null,
  "city": null, "state": null, "country": null, "zip_code": null
 },
 "payment_method": {"value": "razorpay", "label": "Razorpay"},
 "payment_status": {"value": "completed", "label": "Completed"},
 "payment_status_html": {},
 "products_count": 3,
 "product_image": null,
 "product_images": []
}
''';

/// `GET /ecommerce/orders/243` — a detail response whose single line has the
/// FLAT `options` map, a float `total`, `variation_attributes` and `sold_by`.
const String _detail243 = r'''
{
 "data": {
  "id": 243,
  "code": "SF10000243",
  "status": {"value": "completed", "label": "Completed"},
  "status_html": {},
  "customer": {"name": "Suraj ojha", "email": "suraj.ojha@uminber.in", "phone": "8305317276"},
  "created_at": "2026-05-08T18:37:12+05:30",
  "amount": "1193.56",
  "amount_formatted": "₹1,193.56",
  "tax_amount": "43.88",
  "tax_amount_formatted": "₹43.88",
  "shipping_amount": "272.06",
  "shipping_amount_formatted": "₹272.06",
  "shipping_method": {"value": "shiprocket", "label": "ShipRocket"},
  "shipping_status": {"value": "delivered", "label": "Delivered"},
  "shipping_status_html": {},
  "shipping_info": {
   "name": "Suraj ojha",
   "phone": "8305317276",
   "email": "suraj.ojha@uminber.in",
   "address": "306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad",
   "city": "574",
   "state": "11",
   "country": "India",
   "zip_code": "382415"
  },
  "billing_info": {
   "name": null, "phone": null, "email": null, "address": null,
   "city": null, "state": null, "country": null, "zip_code": null
  },
  "payment_method": {"value": "razorpay", "label": "Razorpay"},
  "payment_status": {"value": "completed", "label": "Completed"},
  "payment_status_html": {},
  "products": [
   {
    "id": 338,
    "product_id": 116,
    "product_name": "Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu)",
    "product_image": "https://dev.truewayerp.com/storage/products/whole-wheat/81lm1nhmzol-sx679-150x150.jpg",
    "product_url": "https://dev.truewayerp.com/products/trueway-farms-organic-sona-moti-wheat-sonamoti-gehu-5kg-pack",
    "sku": "TRW3214",
    "attributes": "(Pack Size: 5 KG (Pack of 1))",
    "amount": "877.62",
    "amount_formatted": "₹877.62",
    "quantity": 1,
    "total": 877.62,
    "total_formatted": "₹877.62",
    "options": {
     "image": "products/whole-wheat/81lm1nhmzol-sx679.jpg",
     "attributes": "(Pack Size: 5 KG (Pack of 1))",
     "taxRate": 5,
     "taxClasses": {"gst": 5},
     "options": [],
     "extras": [],
     "sku": "TRW3214",
     "weight": 5000,
     "height": 34,
     "length": 26,
     "wide": 8
    },
    "product_options": [],
    "variation_attributes": [
     {"attribute_set_title": "Pack Size", "title": "5 KG (Pack of 1)", "color": "", "image": ""}
    ],
    "sold_by": {
     "store_name": "Trueway Farms",
     "store_url": "https://dev.truewayerp.com/stores/trueway-farms-1"
    }
   }
  ],
  "discount_amount": "0.00",
  "discount_amount_formatted": "₹0.00",
  "discount_description": null,
  "coupon_code": null,
  "can_be_canceled": false,
  "can_confirm_delivery": false,
  "is_invoice_available": true,
  "can_be_returned": false,
  "invoice_links": {
   "print": "https://dev.truewayerp.com/customer/orders/print/243?type=print",
   "download": "https://dev.truewayerp.com/customer/orders/print/243"
  }
 },
 "error": false,
 "message": null
}
''';

/// One line of `GET /ecommerce/orders/133` — the OTHER `options` shape, where
/// PHP's private-property mangling (`\u0000*\u0000items`) hides the data from
/// the server's own `Arr::get`, so `sku` and `attributes` arrive null.
/// `total` is an int here where order 243 sent a float.
const String _detailLineWrappedOptions = r'''
{
 "id": 170,
 "product_id": 101,
 "product_name": "Trueway Farms Organic Chana Dal 1.85 Kg &amp; Kali Masoor Sabut",
 "product_image": "https://dev.truewayerp.com/storage/products/wheat-flour/black-wheat/61pxixorijl-sl1138-150x150.jpg",
 "product_url": null,
 "sku": null,
 "attributes": null,
 "amount": "985.00",
 "amount_formatted": "₹985.00",
 "quantity": 2,
 "total": 1970,
 "total_formatted": "₹1,970.00",
 "options": {
  "\u0000*\u0000items": {
   "image": "products/wheat-flour/black-wheat/61pxixorijl-sl1138.jpg",
   "attributes": "",
   "taxRate": 5,
   "taxClasses": {"gst": 5},
   "options": [],
   "extras": [],
   "sku": "TRUE-2342",
   "weight": 5000
  },
  "\u0000*\u0000escapeWhenCastingToString": false
 },
 "product_options": null
}
''';

/// `GET /ecommerce/orders/14` — verbatim, and the reason [Order.subTotal] must
/// never be derived from the header amounts:
///   amount 487.00, tax 0.00, shipping 0.00, discount 0.00
///   lines  -123 + 600 = 477
/// The ₹10 gap is a `payment_fee` that NEITHER order route exposes (only the
/// tracking dump has the key), so `amount - tax - shipping + discount` is 487
/// on a list row while the detail screen sums 477 for the same order. Orders 15
/// (587 vs 577) and 17 (7510 vs 7500) have the same gap.
///
/// It also carries a NEGATIVE line whose `*_formatted` twins have had the sign
/// stripped by Laravel's `format_price()`, and a `taxClasses` that is a JSON
/// ARRAY here where every other line sends an object.
const String _detail14 = r'''
{
 "data": {
  "id": 14,
  "code": "#SF-10000014",
  "status": {"value": "pending", "label": "Pending"},
  "status_html": {},
  "customer": {"name": "Suraj ojha", "email": "suraj.ojha@uminber.in", "phone": "8305317276"},
  "created_at": "2025-07-05T15:22:02+05:30",
  "amount": "487.00",
  "amount_formatted": "₹487.00",
  "tax_amount": "0.00",
  "tax_amount_formatted": "₹0.00",
  "shipping_amount": "0.00",
  "shipping_amount_formatted": "₹0.00",
  "shipping_method": {"value": "default", "label": "Default"},
  "shipping_status": {"value": "pending", "label": "Pending"},
  "shipping_status_html": {},
  "shipping_info": {
   "name": "Suraj ojha",
   "phone": "8305317276",
   "email": "suraj.ojha@uminber.in",
   "address": "306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad",
   "city": "574",
   "state": "11",
   "country": "India",
   "zip_code": "382415"
  },
  "billing_info": {
   "name": null, "phone": null, "email": null, "address": null,
   "city": null, "state": null, "country": null, "zip_code": null
  },
  "payment_method": {"value": "cod", "label": "Cash on delivery (COD)"},
  "payment_status": {"value": "completed", "label": "Completed"},
  "payment_status_html": {},
  "products": [
   {
    "id": 16,
    "product_id": 59,
    "product_name": "BLACK WHEAT / KALA GEHU",
    "product_image": "https://dev.truewayerp.com/storage/products/foxtail-millet/61rg93o7vql-sl1186-150x150.jpg",
    "product_url": null,
    "sku": "BLACK-WHEAT",
    "attributes": "",
    "amount": "-123.00",
    "amount_formatted": "₹123.00",
    "quantity": 1,
    "total": -123,
    "total_formatted": "₹123.00",
    "options": {
     "image": "products/foxtail-millet/61rg93o7vql-sl1186.jpg",
     "attributes": "",
     "taxRate": 0,
     "taxClasses": [],
     "options": [],
     "extras": [],
     "sku": "BLACK-WHEAT",
     "weight": 1000
    },
    "product_options": []
   },
   {
    "id": 17,
    "product_id": 69,
    "product_name": "Trueway farms Organic Foxtail Millet (Kangani) 1.85 kg",
    "product_image": "https://dev.truewayerp.com/storage/products/whole-wheat/61igpzdhwal-sl1188-150x150.jpg",
    "product_url": null,
    "sku": "TW-2443-3RM1",
    "attributes": "(Weight: 1 Kg)",
    "amount": "600.00",
    "amount_formatted": "₹600.00",
    "quantity": 1,
    "total": 600,
    "total_formatted": "₹600.00",
    "options": {
     "image": "products/whole-wheat/61igpzdhwal-sl1188.jpg",
     "attributes": "(Weight: 1 Kg)",
     "taxRate": 0,
     "taxClasses": [],
     "options": [],
     "extras": [],
     "sku": "TW-2443-3RM1",
     "weight": 1850
    },
    "product_options": []
   }
  ],
  "discount_amount": "0.00",
  "discount_amount_formatted": "₹0.00",
  "discount_description": null,
  "coupon_code": null,
  "can_be_canceled": true,
  "can_confirm_delivery": false,
  "is_invoice_available": true,
  "can_be_returned": false,
  "invoice_links": {
   "print": "https://dev.truewayerp.com/customer/orders/print/14?type=print",
   "download": "https://dev.truewayerp.com/customer/orders/print/14"
  }
 },
 "error": false,
 "message": null
}
''';

/// ⚠ SYNTHESIZED, not captured — every one of the 90 orders on the dev account
/// is ineligible, so the success branch of `GET /ecommerce/orders/{id}/returns`
/// has never been on the wire. Assembled key-for-key from
/// `API\OrderReturnController::getReturnOrder` (`order` is an
/// OrderDetailResource, so the detail body above is reused verbatim) and
/// `Supports\OrderReturnHelper::getReturnableItems` / `getReturnReasons`.
///
/// The point of the fixture is the one asymmetry the source guarantees:
/// `getReturnableItems` passes `$product->product_image` through UNTOUCHED
/// while every other order route wraps it in `RvMedia::getImageUrl`, so these
/// image values are RAW storage paths.
const String _eligibilitySuccess = r'''
{
 "error": false,
 "message": null,
 "data": {
  "order": {
   "id": 243,
   "code": "SF10000243",
   "status": {"value": "completed", "label": "Completed"},
   "amount": "1193.56",
   "amount_formatted": "₹1,193.56",
   "tax_amount": "43.88",
   "shipping_amount": "272.06",
   "discount_amount": "0.00",
   "shipping_method": {"value": "shiprocket", "label": "ShipRocket"},
   "shipping_status": {"value": "delivered", "label": "Delivered"},
   "payment_method": {"value": "razorpay", "label": "Razorpay"},
   "payment_status": {"value": "completed", "label": "Completed"},
   "products": [
    {
     "id": 338,
     "product_id": 116,
     "product_name": "Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu)",
     "product_image": "https://dev.truewayerp.com/storage/products/whole-wheat/81lm1nhmzol-sx679-150x150.jpg",
     "sku": "TRW3214",
     "attributes": "(Pack Size: 5 KG (Pack of 1))",
     "amount": "877.62",
     "quantity": 1,
     "total": 877.62,
     "options": {"sku": "TRW3214", "weight": 5000},
     "product_options": []
    }
   ],
   "can_be_returned": true,
   "can_be_canceled": false,
   "is_invoice_available": true,
   "invoice_links": {"print": null, "download": null}
  },
  "returnable_items": [
   {
    "order_item_id": 338,
    "product_id": 116,
    "product_name": "Trueway Farms Organic Chana Dal 1.85 Kg &amp; Kali Masoor Sabut",
    "product_image": "products/whole-wheat/81lm1nhmzol-sx679.jpg",
    "price": "877.62",
    "qty": 1
   }
  ],
  "return_reasons": [
   {"value": "damaged", "label": "Damaged product"},
   {"value": "defective", "label": "Defective"},
   {"value": "incorrect_item", "label": "Incorrect item"},
   {"value": "not_as_described", "label": "Not as described"},
   {"value": "other", "label": "Other"}
  ]
 }
}
''';

/// `POST /ecommerce/order-returns/upload-media` success shape, from
/// `uploadMedia()`'s `setData(['urls' => $urls])`.
const String _uploadMediaResponse = r'''
{
 "error": false,
 "message": "Files uploaded successfully.",
 "data": {"urls": [
  "https://dev.truewayerp.com/storage/order-returns/a.jpg",
  "https://dev.truewayerp.com/storage/order-returns/b.jpg"
 ]}
}
''';

/// `POST /ecommerce/orders/{id}/cancel` refusal — HTTP 200, `error: true`.
const String _cancelRefusal = r'''
{"error": true, "data": null, "message": "You cannot cancel this order"}
''';

/// Detail tail of a canceled order — `invoice_links` present but both null.
const String _canceledInvoiceLinks = r'''
{"print": null, "download": null}
''';

/// `GET /ecommerce/order-returns?per_page=2` — hybrid envelope again. Row 29
/// has hit the 3-submission ceiling; row 24 has an EMPTY-STRING reason.
const String _returnsPerPage2 = r'''
{
 "data": [
  {
   "id": 29,
   "order_id": 247,
   "order_code": "SF10000247",
   "return_status": {"value": "completed", "label": "Completed"},
   "reason": {"value": "defective", "label": "Defective"},
   "customer_comment": "analyse the codebase and tell me what is the why mobile api giving this error in return flow egdwrg 3rd resubmit",
   "media_images": [
    "https://dev.truewayerp.com/storage/order-returns/scaled-02aabb5f-e86e-46ab-aa83-17a7374d23dc3275457893110970285-2.jpg",
    "https://dev.truewayerp.com/storage/order-returns/scaled-d522a7fb-a903-493a-a2f3-c8d72b7ee8b53417895116111680850.jpg"
   ],
   "media_videos": [
    "https://dev.truewayerp.com/storage/order-returns/56dd0a3a-55cc-4495-967b-a22692e7e32f8503054958492733163-2.mp4",
    "https://dev.truewayerp.com/storage/order-returns/21f80383-9c55-41bd-aaa0-c106086666c23501986060540274629.mp4"
   ],
   "submission_count": 3,
   "customer_id": 16,
   "items_count": 1,
   "items": [
    {
     "id": 31,
     "order_return_id": 29,
     "order_product_id": 342,
     "product_id": 117,
     "product_name": "Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu)",
     "product_image": "https://dev.truewayerp.com/storage/61bkclvifql-sl1191-150x150.jpg",
     "price": "470.00",
     "qty": 1,
     "reason": {"value": "defective", "label": "Defective"},
     "refund_amount": "470.00",
     "media_images": [],
     "media_videos": [],
     "created_at": "2026-05-14 16:58:52",
     "updated_at": "2026-05-14 17:30:48"
    }
   ],
   "created_at": "2026-05-14 16:58:52",
   "updated_at": "2026-05-14 17:33:04",
   "latest_history": {
    "id": 52,
    "action": {"value": "mark_as_completed", "label": "Mark as completed"},
    "created_at": "2026-05-14 17:33:04",
    "updated_at": "2026-05-14 17:33:04"
   },
   "can_resubmit": false,
   "admin_feedback": null
  },
  {
   "id": 24,
   "order_id": 246,
   "order_code": "SF10000246",
   "return_status": {"value": "completed", "label": "Completed"},
   "reason": {"value": "", "label": ""},
   "customer_comment": "Aur isse pehle wala error bhi automatically theek ho jayega",
   "media_images": [],
   "media_videos": [],
   "submission_count": 2,
   "customer_id": 16,
   "items_count": 1,
   "items": [
    {
     "id": 26,
     "order_return_id": 24,
     "order_product_id": 341,
     "product_id": 116,
     "product_name": "Trueway Farms Organic Sona Moti Wheat (sonamoti Gehu)",
     "product_image": "https://dev.truewayerp.com/storage/products/whole-wheat/81lm1nhmzol-sx679-150x150.jpg",
     "price": "877.62",
     "qty": 1,
     "reason": {"value": "damaged", "label": "Damaged product"},
     "refund_amount": "877.62",
     "media_images": ["https://dev.truewayerp.com/storage/customers/16/return/246/61qhi9x71zl-sl1193-1.jpg"],
     "media_videos": ["https://dev.truewayerp.com/storage/customers/16/return/246/win-20260120-18-02-15-pro-1.mp4"],
     "created_at": "2026-05-11 16:36:30",
     "updated_at": "2026-05-11 16:51:24"
    }
   ],
   "created_at": "2026-05-11 16:36:30",
   "updated_at": "2026-05-11 16:57:13",
   "latest_history": {
    "id": 41,
    "action": {"value": "mark_as_completed", "label": "Mark as completed"},
    "created_at": "2026-05-11 16:57:13",
    "updated_at": "2026-05-11 16:57:13"
   },
   "can_resubmit": false,
   "admin_feedback": null
  }
 ],
 "links": {
  "first": "https://dev.truewayerp.com/api/v1/ecommerce/order-returns?page=1",
  "last": "https://dev.truewayerp.com/api/v1/ecommerce/order-returns?page=5",
  "prev": null,
  "next": "https://dev.truewayerp.com/api/v1/ecommerce/order-returns?page=2"
 },
 "meta": {
  "current_page": 1,
  "from": 1,
  "last_page": 5,
  "links": [
   {"url": null, "label": "&laquo; Previous", "page": null, "active": false},
   {"url": "https://dev.truewayerp.com/api/v1/ecommerce/order-returns?page=1", "label": "1", "page": 1, "active": true},
   {"url": "https://dev.truewayerp.com/api/v1/ecommerce/order-returns?page=2", "label": "Next &raquo;", "page": 2, "active": false}
  ],
  "path": "https://dev.truewayerp.com/api/v1/ecommerce/order-returns",
  "per_page": 2,
  "to": 2,
  "total": 10
 },
 "error": false,
 "message": null
}
''';

/// Return 3 — `reason` is `{value: null}` at the request level while the two
/// items carry the real reason, `updated_at` is null on both items, and the
/// product name is HTML-escaped. Refunds exceed the line prices because the
/// server prorates the tax share into them.
const String _returnNullReason = r'''
{
 "id": 3,
 "order_id": 131,
 "order_code": "SF10000131",
 "return_status": {"value": "completed", "label": "Completed"},
 "reason": {"value": null, "label": ""},
 "customer_comment": "testing",
 "media_images": ["https://dev.truewayerp.com/storage/customers/16/return/131/chatgpt-image-feb-22-2026-10-48-49-pm.png"],
 "media_videos": ["https://dev.truewayerp.com/storage/customers/16/return/131/win-20260120-18-02-15-pro.mp4"],
 "submission_count": 1,
 "customer_id": 16,
 "items_count": 2,
 "items": [
  {
   "id": 3,
   "order_return_id": 3,
   "order_product_id": 166,
   "product_id": 98,
   "product_name": "Trueway Farms Organic Chana Dal 1.85 Kg &amp; Trueway Farms Organic Kali Masoor Sabut (black Masoor Whole) 1.85 Kg (combo Of 2)",
   "product_image": "https://dev.truewayerp.com/storage/products/dals/61a1sdxqijl-sx569-150x150.jpg",
   "price": "966.00",
   "qty": 1,
   "reason": {"value": "no_longer_want", "label": "No longer want"},
   "refund_amount": "1014.30",
   "media_images": [],
   "media_videos": [],
   "created_at": "2026-03-14 17:21:37",
   "updated_at": null
  },
  {
   "id": 4,
   "order_return_id": 3,
   "order_product_id": 167,
   "product_id": 101,
   "product_name": "Trueway Farms Organic Black Wheat Flour",
   "product_image": "https://dev.truewayerp.com/storage/products/wheat-flour/black-wheat/61pxixorijl-sl1138-150x150.jpg",
   "price": "985.00",
   "qty": 1,
   "reason": {"value": "no_longer_want", "label": "No longer want"},
   "refund_amount": "1034.25",
   "media_images": [],
   "media_videos": [],
   "created_at": "2026-03-14 17:21:37",
   "updated_at": null
  }
 ],
 "created_at": "2026-03-14 17:21:37",
 "updated_at": "2026-03-17 15:44:40",
 "latest_history": {
  "id": 12,
  "action": {"value": "mark_as_completed", "label": "Mark as completed"},
  "created_at": "2026-03-17 15:44:40",
  "updated_at": "2026-03-17 15:44:40"
 },
 "can_resubmit": false,
 "admin_feedback": null
}
''';

/// Return 10 — the only resubmittable row: null `customer_comment` (predates
/// the 50-char rule), empty-string reason, and a long `admin_feedback`.
const String _returnResubmittable = r'''
{
 "id": 10,
 "order_id": 198,
 "order_code": "SF10000198",
 "return_status": {"value": "resubmit", "label": "Resubmit Required"},
 "reason": {"value": "", "label": ""},
 "customer_comment": null,
 "media_images": [],
 "media_videos": [],
 "submission_count": 1,
 "customer_id": 16,
 "items_count": 1,
 "items": [
  {
   "id": 12,
   "order_return_id": 10,
   "order_product_id": 286,
   "product_id": 94,
   "product_name": "Trueway Farms Organic Jaggery Powder (gud Powder) 1.85 Kg",
   "product_image": "https://dev.truewayerp.com/storage/products/jaggery/61zkbnvnshl-sl1181-150x150.jpg",
   "price": "425.00",
   "qty": 1,
   "reason": {"value": "damaged", "label": "Damaged product"},
   "refund_amount": "425.00",
   "media_images": ["https://dev.truewayerp.com/storage/customers/16/return/198/chatgpt-image-feb-22-2026-10-48-49-pm.png"],
   "media_videos": ["https://dev.truewayerp.com/storage/customers/16/return/198/win-20260120-18-02-15-pro.mp4"],
   "created_at": "2026-03-26 14:45:32",
   "updated_at": null
  }
 ],
 "created_at": "2026-03-26 14:45:32",
 "updated_at": "2026-07-06 15:54:01",
 "latest_history": {
  "id": 55,
  "action": {"value": "resubmit_requested", "label": "Resubmit requested by admin"},
  "created_at": "2026-07-06 15:54:01",
  "updated_at": "2026-07-06 15:54:01"
 },
 "can_resubmit": true,
 "admin_feedback": "Lorem Ipsum is simply dummy text of the printing and typesetting industry."
}
''';

/// `GET /ecommerce/order-returns?page=99` — the empty-collection shape. Note
/// `from`/`to` go null and `last_page` disagrees with `current_page`.
const String _returnsEmptyPage = r'''
{
 "data": [],
 "links": {
  "first": "https://dev.truewayerp.com/api/v1/ecommerce/order-returns?page=1",
  "last": "https://dev.truewayerp.com/api/v1/ecommerce/order-returns?page=1",
  "prev": "https://dev.truewayerp.com/api/v1/ecommerce/order-returns?page=98",
  "next": null
 },
 "meta": {
  "current_page": 99,
  "from": null,
  "last_page": 1,
  "links": [
   {"url": "https://dev.truewayerp.com/api/v1/ecommerce/order-returns?page=98", "label": "&laquo; Previous", "page": 98, "active": false},
   {"url": "https://dev.truewayerp.com/api/v1/ecommerce/order-returns?page=1", "label": "1", "page": 1, "active": false},
   {"url": null, "label": "Next &raquo;", "page": null, "active": false}
  ],
  "path": "https://dev.truewayerp.com/api/v1/ecommerce/order-returns",
  "per_page": 10,
  "to": null,
  "total": 10
 },
 "error": false,
 "message": null
}
''';


/// `GET /ecommerce/orders/277/returns` for an ineligible order — HTTP 200 with
/// `error: true` and the real explanation buried in `data.reason`.
const String _returnRefusal = r'''
{
 "error": true,
 "data": {"reason": "Order must be in completed status to be eligible for return."},
 "message": "You cannot return this order"
}
''';

/// `GET /ecommerce/orders/133/invoice`.
const String _invoiceResponse = r'''
{"error": false, "data": {"url": "https://dev.truewayerp.com/customer/invoices/75/generate-invoice"}, "message": null}
''';

Map<String, dynamic> _json(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

// ===========================================================================
// Fake transport — same pattern as auth_repository_test.dart.
// ===========================================================================

class _Canned {
  const _Canned(this.statusCode, this.body);
  final int statusCode;
  final Object body;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);

  final Map<String, _Canned> responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final canned = responses[options.path] ??
        const _Canned(404, {'message': 'no canned response'});
    return ResponseBody.fromString(
      jsonEncode(canned.body),
      canned.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<({OrderRepository repo, _FakeAdapter adapter})> _build(
  Map<String, _Canned> responses,
) async {
  SharedPreferences.setMockInitialValues({'auth_token': 'test-token'});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(responses);
  final dio = Dio()..httpClientAdapter = adapter;
  return (repo: OrderRepository(ApiClient(prefs: prefs, dio: dio)), adapter: adapter);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StatusValue', () {
    test('reads the {value,label} object', () {
      final status = StatusValue.fromJson(
        const {'value': 'processing', 'label': 'Processing'},
      );
      expect(status.value, 'processing');
      expect(status.display, 'Processing');
      expect(status.matches(OrderStatuses.processing), isTrue);
      expect(status.isNotEmpty, isTrue);
    });

    test('treats {value: null} and {value: ""} alike as unset', () {
      final nullValue =
          StatusValue.fromJson(const {'value': null, 'label': ''});
      final emptyValue = StatusValue.fromJson(const {'value': '', 'label': ''});
      expect(nullValue.isEmpty, isTrue);
      expect(emptyValue.isEmpty, isTrue);
      expect(nullValue.display, '');
      expect(emptyValue.matches(''), isFalse);
    });

    test('survives an absent key', () {
      expect(StatusValue.fromJson(null).isEmpty, isTrue);
      expect(StatusValue.fromJson(const <String, dynamic>{}).isEmpty, isTrue);
    });

    test('falls back to a humanized value when the label is blank', () {
      final status = StatusValue.fromJson(
        const {'value': 'ready_to_be_shipped_out', 'label': ''},
      );
      expect(status.display, 'Ready to be shipped out');
    });

    test('accepts a bare string, which other resources send', () {
      expect(StatusValue.fromJson('in_transit').display, 'In transit');
    });
  });

  group('Order list row', () {
    test('parses the hybrid envelope through PaginatedResponse', () {
      final page = PaginatedResponse.fromJson(
        _json(_ordersPerPage1),
        Order.fromJson,
      );
      expect(page.items, hasLength(1));
      expect(page.meta.total, 90);
      expect(page.meta.lastPage, 90);
      expect(page.meta.perPage, 1);
      expect(page.hasMore, isTrue);
      expect(page.links?.next, contains('page=2'));
    });

    test('coerces the 2dp string amounts and keeps the formatted twins', () {
      final order =
          PaginatedResponse.fromJson(_json(_ordersPerPage1), Order.fromJson)
              .items
              .first;
      expect(order.amount, 1274.15);
      expect(order.taxAmount, 44.95);
      expect(order.shippingAmount, 330.20);
      expect(order.amountDisplay, '₹1,274.15');
      expect(order.createdAt?.year, 2026);
    });

    test('carries no line items and no capability flags', () {
      final order =
          PaginatedResponse.fromJson(_json(_ordersPerPage1), Order.fromJson)
              .items
              .first;
      expect(order.hasLineItems, isFalse);
      expect(order.lines, isEmpty);
      expect(order.productsCount, 1);
      expect(order.productImages, hasLength(1));
      // Detail-only keys are absent, so nothing enables an action button here.
      expect(order.canBeCanceled, isFalse);
      expect(order.canBeReturned, isFalse);
      expect(order.discountAmount, 0);
    });

    test('handles the row where every optional field degenerates', () {
      final order = Order.fromJson(_json(_degenerateRow));
      expect(order.shippingStatus.isEmpty, isTrue); // {value: null}
      expect(order.shippingMethod.isEmpty, isTrue); // {value: ""}
      expect(order.paymentStatus.value, 'completed');
      expect(order.productImage, isNull);
      expect(order.productImages, isEmpty);
      expect(order.thumbnail, isNull);
      expect(order.shippingInfo, isNull); // all-null block
      expect(order.billingInfo, isNull);
      expect(order.customer?.name, 'Suraj ojha');
    });

    test('handles both code formats without ever adding a #', () {
      final legacy = Order.fromJson(_json(_degenerateRow));
      final current =
          PaginatedResponse.fromJson(_json(_ordersPerPage1), Order.fromJson)
              .items
              .first;
      expect(legacy.code, '#SF-10000047');
      expect(legacy.displayCode, 'SF-10000047');
      expect(current.code, 'SF10000277');
      expect(current.displayCode, 'SF10000277');
    });

    test('treats a billing_info sent as an empty ARRAY as absent', () {
      // `whenLoaded(..., [])` in OrderResource serializes its default as a JSON
      // array, so a Map cast would throw where a null check should have run.
      final row = _json(_degenerateRow)..['billing_info'] = <dynamic>[];
      expect(Order.fromJson(row).billingInfo, isNull);
    });

    test('refuses to invent a subtotal on a list row, which has none', () {
      final order = Order.fromJson(_json(_degenerateRow));
      expect(order.hasLineItems, isFalse);
      // The tempting `amount - tax - shipping + discount` (1707.30 - 81.30 = 1626)
      // is missing the payment_fee term neither order route exposes; order 14
      // proves it disagrees with the server's own line totals. Show nothing.
      expect(order.subTotal, isNull);
      expect(order.subTotalDisplay, isNull);
    });
  });

  group('Order detail', () {
    Order detail() =>
        Order.fromJson(_json(_detail243)['data'] as Map<String, dynamic>);

    test('parses line items and the capability flags', () {
      final order = detail();
      expect(order.hasLineItems, isTrue);
      expect(order.lines, hasLength(1));
      expect(order.canBeCanceled, isFalse);
      expect(order.isInvoiceAvailable, isTrue);
      expect(order.invoiceLinks.download, contains('/print/243'));
      expect(order.couponCode, isNull);
      expect(order.discountAmount, 0);
      expect(order.productsCount, 1); // no products_count key -> line count
    });


    // The shop's rule: the invoice is a delivery document, so the app only
    // offers it once the parcel has arrived. Both signals count, because the
    // backend ties them together — `ShipmentController` answers a `delivered`
    // shipment with `OrderHelper::shippingStatusDelivered()`, which is
    // `setOrderCompleted()`.
    test('a completed order counts as delivered', () {
      // Order 243 is `status: completed` with `shipping_status: approved` —
      // the shipment row never caught up. Reading only `shipping_status` would
      // withhold the invoice for an order the backend has already closed.
      final order = detail();
      expect(order.isCompleted, isTrue);
      expect(order.isDelivered, isTrue);
    });

    test('a delivered shipment counts even before the order closes', () {
      final json = _json(_detail243)['data'] as Map<String, dynamic>;
      final order = Order.fromJson({
        ...json,
        'status': {'value': 'processing', 'label': 'Processing'},
        'shipping_status': {'value': 'delivered', 'label': 'Delivered'},
      });
      expect(order.isCompleted, isFalse);
      expect(order.isDelivered, isTrue);
    });

    test('an order still on its way is not delivered', () {
      final json = _json(_detail243)['data'] as Map<String, dynamic>;
      final order = Order.fromJson({
        ...json,
        'status': {'value': 'processing', 'label': 'Processing'},
        'shipping_status': {'value': 'out_for_delivery', 'label': 'Out for delivery'},
      });
      expect(order.isDelivered, isFalse);
      // The invoice exists server-side; the app simply does not offer it yet.
      expect(order.isInvoiceAvailable, isTrue);
    });

    test('reads a float total and the flat options map', () {
      final line = detail().lines.single;
      expect(line.id, 338); // the id a return must reference
      expect(line.productId, 116);
      expect(line.total, 877.62);
      expect(line.totalDisplay, '₹877.62');
      expect(line.quantity, 1);
      expect(line.sku, 'TRW3214');
      expect(line.weightGrams, 5000);
      expect(line.storeName, 'Trueway Farms');
      expect(line.variationAttributes.single.display, 'Pack Size: 5 KG (Pack of 1)');
      expect(line.variantLabel, 'Pack Size: 5 KG (Pack of 1)');
    });

    test('recovers sku from the mangled options wrapper', () {
      final line = OrderLine.fromJson(_json(_detailLineWrappedOptions));
      // Both top-level fields are null because the server's own Arr::get could
      // not see through PHP's "\0*\0items" key.
      expect(line.sku, 'TRUE-2342');
      expect(line.weightGrams, 5000);
      // options.attributes is "" here, which must read as absent, not empty.
      expect(line.attributes, isNull);
      expect(line.variantLabel, isNull);
      // `total` arrived as an int on this line and a double on order 243's.
      expect(line.total, 1970.0);
      expect(line.unitPrice, 985.0);
    });

    test('decodes HTML entities in product names', () {
      final line = OrderLine.fromJson(_json(_detailLineWrappedOptions));
      expect(line.name, contains('Chana Dal 1.85 Kg & Kali Masoor'));
      expect(line.name, isNot(contains('&amp;')));
    });

    test('reports an unavailable invoice when both links are null', () {
      final links = OrderInvoiceLinks.fromJson(_json(_canceledInvoiceLinks));
      expect(links.isAvailable, isFalse);
      expect(links.print, isNull);
    });

    test('sums the server line totals for the subtotal when lines are present',
        () {
      expect(detail().subTotal, closeTo(877.62, 0.001));
      expect(detail().subTotalDisplay, '₹877.62');
    });

    test('never derives the subtotal from the header amounts (order 14)', () {
      final order = Order.fromJson(_json(_detail14)['data'] as Map<String, dynamic>);
      // Header says 487.00 with tax, shipping and discount all zero; the two
      // lines total 477. The ₹10 delta is a payment_fee this route omits, so
      // the arithmetic would put a different number on the list screen than on
      // the detail screen for the SAME order.
      expect(order.amount, 487.0);
      expect(order.taxAmount, 0);
      expect(order.shippingAmount, 0);
      expect(order.discountAmount, 0);
      expect(order.subTotal, closeTo(477.0, 0.001));
      expect(
        order.amount - order.taxAmount - order.shippingAmount + order.discountAmount,
        isNot(closeTo(order.subTotal!, 0.001)),
      );
    });

    // -----------------------------------------------------------------------
    // `sub_total` and `payment_fee`, once the backend serializes them
    // -----------------------------------------------------------------------
    //
    // Both columns always existed on `ec_orders`; only the API resources omitted
    // them. Verified against the local backend after the fix, order 131:
    //   sub_total "490.00", payment_fee "0.00", tax 24.50, shipping 101.36,
    //   discount 0.00, amount "615.86"  ->  490 + 24.50 + 101.36 = 615.86 exactly.

    /// A detail payload carrying the two new keys.
    Map<String, dynamic> withBreakdown({
      String subTotal = '490.00',
      String paymentFee = '0.00',
      String amount = '615.86',
    }) {
      final json = _json(_detail243)['data'] as Map<String, dynamic>;
      return {
        ...json,
        'sub_total': subTotal,
        'sub_total_formatted': '₹$subTotal',
        'payment_fee': paymentFee,
        'payment_fee_formatted': '₹$paymentFee',
        'amount': amount,
        'tax_amount': '24.50',
        'shipping_amount': '101.36',
        'discount_amount': '0.00',
      };
    }

    test('prefers the server sub_total over the sum of the lines', () {
      final order = Order.fromJson(withBreakdown());

      // The line sum for this fixture is 877.62 — deliberately nothing like the
      // server's figure, so a fallback would be visible.
      expect(order.serverSubTotal, 490.0);
      expect(order.subTotal, 490.0);
      expect(order.subTotalDisplay, '₹490.00');
    });

    test('falls back to the line sum when the server omits sub_total', () {
      // A build talking to a server that predates the field.
      expect(detail().serverSubTotal, isNull);
      expect(detail().subTotal, closeTo(877.62, 0.001));
    });

    test('an absent payment_fee is null, never zero', () {
      // The distinction the whole bill rests on: "the server did not say" is not
      // "there is no fee". Reading it as 0 is how order 14 came to display a
      // total ₹10.00 above its own rows.
      expect(detail().paymentFee, isNull);
      expect(detail().paymentFeeDisplay, isNull);
      expect(detail().hasFullBreakdown, isFalse);
      expect(detail().breakdownTotal, isNull);
      expect(detail().breakdownReconciles, isFalse);

      final served = Order.fromJson(withBreakdown());
      expect(served.paymentFee, 0.0);
      expect(served.hasFullBreakdown, isTrue);
    });

    test('the breakdown reconciles with the total the server charged', () {
      final order = Order.fromJson(withBreakdown());

      // max(490 - 0, 0) + 24.50 + 101.36 + 0 = 615.86
      expect(order.breakdownTotal, closeTo(615.86, 0.001));
      expect(order.amount, 615.86);
      expect(order.breakdownReconciles, isTrue);
    });

    test('a payment fee is carried into the breakdown — the order 14 case', () {
      // Order 14's exact shape: rows summing to 477 against a charged 487, the
      // ₹10.00 being the fee the resource used to omit.
      final order = Order.fromJson(
        withBreakdown(subTotal: '477.00', paymentFee: '10.00', amount: '487.00')
          ..['tax_amount'] = '0.00'
          ..['shipping_amount'] = '0.00',
      );

      expect(order.breakdownTotal, closeTo(487.0, 0.001));
      expect(order.breakdownReconciles, isTrue);
      expect(order.paymentFeeDisplay, '₹10.00');
    });

    test('a breakdown that does not add up reports itself rather than hiding',
        () {
      // Order 52's class of defect: ₹0.01 out through discount/tax rounding.
      final order = Order.fromJson(withBreakdown(amount: '615.87'));

      expect(order.hasFullBreakdown, isTrue);
      expect(order.breakdownReconciles, isFalse);
      // The charged figure still wins wherever it is displayed.
      expect(order.amount, 615.87);
    });

    test('keeps the sign on a negative line the server formats as positive', () {
      final order = Order.fromJson(_json(_detail14)['data'] as Map<String, dynamic>);
      final credit = order.lines.first;
      expect(credit.unitPrice, -123.0);
      expect(credit.total, -123.0);
      // The server's own twins have had the minus stripped by format_price().
      expect(credit.unitPriceFormatted, '₹123.00');
      expect(credit.totalFormatted, '₹123.00');
      // Rendering them verbatim would show a ₹123 credit as a ₹123 charge.
      expect(credit.totalDisplay, startsWith('-'));
      expect(credit.unitPriceDisplay, startsWith('-'));
      // The positive line still uses the server's own wording.
      expect(order.lines[1].totalDisplay, '₹600.00');
    });

    test('survives taxClasses arriving as an array instead of an object', () {
      // 148 lines send `taxClasses: {"gst": 5}`; order 14's two send `[]`.
      final order = Order.fromJson(_json(_detail14)['data'] as Map<String, dynamic>);
      expect(order.lines, hasLength(2));
      expect(order.lines.first.sku, 'BLACK-WHEAT');
      expect(order.lines.first.weightGrams, 1000);
      // `attributes: ""` at both levels must read as absent, not empty.
      expect(order.lines.first.attributes, isNull);
      expect(order.lines[1].attributes, '(Weight: 1 Kg)');
    });

    test('does not double-decode an escaped entity', () {
      // A doubly-escaped "&amp;lt;" must come back as the literal "&lt;", not
      // as "<" — decoding "&amp;" first would inject markup the server escaped.
      expect(decodeEntities('a &amp;lt;b&amp;gt; c'), 'a &lt;b&gt; c');
      expect(decodeEntities('Chana Dal &amp; Masoor'), 'Chana Dal & Masoor');
    });
  });

  // ------------------------------------------------------------------------
  // OrderContact.streetLine — resolved names, with a raw id still possible
  // ------------------------------------------------------------------------
  //
  // The order routes emit `city_name`/`state_name` (verified live on order 277:
  // "Ahmedabad" / "Gujarat"). But `LocationTrait` falls back to the stored value
  // when it cannot resolve one, and live rows are mixed — state "11" beside city
  // "Ahmadabad City" — so the line decides by value, not by endpoint.
  group('OrderContact.streetLine', () {
    OrderContact contact(Map<String, dynamic> overrides) =>
        OrderContact.fromJson({
          'name': 'Suraj Ojha',
          'phone': '9876543210',
          'address': '306, Ring Road',
          'zip_code': '382415',
          'country': 'India',
          ...overrides,
        })!;

    test('shows resolved city and state — the order-route shape', () {
      expect(
        contact({'city': 'Ahmedabad', 'state': 'Gujarat'}).streetLine,
        '306, Ring Road, Ahmedabad, Gujarat, 382415, India',
      );
    });

    test('drops a geo id the server could not resolve', () {
      // Printing these would read "306, Ring Road, 574, 11, 382415, India".
      expect(
        contact({'city': '574', 'state': '11'}).streetLine,
        '306, Ring Road, 382415, India',
      );
    });

    test('keeps the half of a mixed row that reads as a place', () {
      // Real on this account: address 57 stores state "11" with city
      // "Ahmadabad City".
      expect(
        contact({'city': 'Ahmadabad City', 'state': '11'}).streetLine,
        '306, Ring Road, Ahmadabad City, 382415, India',
      );
    });

    test('NEVER drops the PIN code, which is legitimately all digits', () {
      // The id filter was briefly written across the whole list, which silently
      // removed "382415" — the one field a courier cannot do without.
      expect(
        contact({'city': '574', 'state': '11'}).streetLine,
        contains('382415'),
      );
      expect(
        contact({'city': 'Ahmedabad', 'state': 'Gujarat'}).streetLine,
        contains('382415'),
      );
    });

    test('keeps a place name that merely contains digits', () {
      // "Sector 12" is a name; "12" is an id. The filter is anchored on the
      // whole string for exactly this reason.
      expect(
        contact({'city': 'Sector 12', 'state': 'Haryana'}).streetLine,
        contains('Sector 12'),
      );
    });

    test('survives a row with no city or state at all', () {
      expect(contact({}).streetLine, '306, Ring Road, 382415, India');
    });
  });

  group('OrderPageLink', () {
    test('tolerates the ellipsis entry that omits the page key', () {
      final links = OrderPageLink.listFrom(_json(_ordersPerPage1));
      final ellipsis = links.firstWhere((link) => link.label == '...');
      expect(ellipsis.page, isNull);
      expect(ellipsis.isEllipsis, isTrue);
      // The numbered entries still decode.
      expect(links.where((link) => link.page != null).length, 4);
      expect(links.singleWhere((link) => link.isActive).page, 1);
    });

    test('decodes the entity-escaped prev/next labels', () {
      final links = OrderPageLink.listFrom(_json(_ordersPerPage1));
      expect(links.first.label, '« Previous');
      expect(links.last.label, 'Next »');
    });
  });

  group('OrderReturn', () {
    test('parses the paginated list, items included', () {
      final page = PaginatedResponse.fromJson(
        _json(_returnsPerPage2),
        OrderReturn.fromJson,
      );
      expect(page.items, hasLength(2));
      expect(page.meta.total, 10);
      expect(page.hasMore, isTrue);

      final first = page.items.first;
      expect(first.id, 29);
      expect(first.orderCode, 'SF10000247');
      expect(first.status.matches(ReturnStatuses.completed), isTrue);
      expect(first.items, hasLength(1));
      expect(first.images, hasLength(2));
      expect(first.videos, hasLength(2));
      expect(first.latestHistory?.action.value, 'mark_as_completed');
      // 3 submissions is the server-side ceiling.
      expect(first.submissionCount, 3);
      expect(first.resubmitsLeft, 0);
      expect(first.canResubmit, isFalse);
    });

    test('falls back to the per-item reason when the top-level one is unset',
        () {
      final byNull = OrderReturn.fromJson(_json(_returnNullReason));
      expect(byNull.reason.isEmpty, isTrue); // {value: null, label: ""}
      expect(byNull.effectiveReason.value, 'no_longer_want');
      expect(byNull.effectiveReason.display, 'No longer want');

      final byEmptyString = PaginatedResponse.fromJson(
        _json(_returnsPerPage2),
        OrderReturn.fromJson,
      ).items[1];
      expect(byEmptyString.reason.isEmpty, isTrue); // {value: "", label: ""}
      expect(byEmptyString.effectiveReason.value, 'damaged');
    });

    test('keeps the server-prorated refund rather than price x qty', () {
      final orderReturn = OrderReturn.fromJson(_json(_returnNullReason));
      final line = orderReturn.items.first;
      expect(line.price, 966.0);
      expect(line.refundAmount, 1014.30); // includes the prorated tax share
      expect(orderReturn.refundTotal, closeTo(2048.55, 0.001));
      expect(orderReturn.itemsCount, 2);
    });

    test('handles nulls: comment, item updated_at, admin feedback', () {
      final resubmit = OrderReturn.fromJson(_json(_returnResubmittable));
      expect(resubmit.customerComment, isNull);
      expect(resubmit.adminFeedback, isNotNull);
      expect(resubmit.canResubmit, isTrue);
      expect(resubmit.resubmitsLeft, 2);
      expect(resubmit.isOpen, isTrue);

      final completed = OrderReturn.fromJson(_json(_returnNullReason));
      expect(completed.items.first.updatedAt, isNull);
      expect(completed.adminFeedback, isNull);
      expect(completed.isOpen, isFalse);
      // Zoneless "2026-03-14 17:21:37" still parses.
      expect(completed.createdAt?.month, 3);
    });

    test('decodes HTML entities in item names', () {
      final orderReturn = OrderReturn.fromJson(_json(_returnNullReason));
      expect(orderReturn.items.first.name, contains('Chana Dal 1.85 Kg &'));
      expect(orderReturn.items.first.name, isNot(contains('&amp;')));
    });

    test('reads an out-of-range page as empty, not as an error', () {
      final page = PaginatedResponse.fromJson(
        _json(_returnsEmptyPage),
        OrderReturn.fromJson,
      );
      expect(page.items, isEmpty);
      expect(page.meta.currentPage, 99);
      expect(page.meta.from, isNull);
      expect(page.meta.to, isNull);
      expect(page.hasMore, isFalse);
    });

    test('drops the # from a legacy order code', () {
      final row = _json(_returnNullReason)..['order_code'] = '#SF-10000016';
      expect(OrderReturn.fromJson(row).displayCode, 'SF-10000016');
    });
  });

  group('ReturnEligibility', () {
    ReturnEligibility parse() => ReturnEligibility.fromJson(
          _json(_eligibilitySuccess)['data'] as Map<String, dynamic>,
        );

    test('reads the order, the returnable lines and the live reason list', () {
      final eligibility = parse();
      expect(eligibility.isEmpty, isFalse);
      expect(eligibility.order?.id, 243);
      expect(eligibility.order?.canBeReturned, isTrue);
      expect(eligibility.items, hasLength(1));
      // order_item_id, NOT product_id — this is what a ReturnItemDraft sends.
      expect(eligibility.items.single.orderItemId, 338);
      expect(eligibility.items.single.productId, 116);
      expect(eligibility.items.single.quantity, 1);
      expect(eligibility.items.single.price, 877.62);
      expect(
        eligibility.reasons.map((reason) => reason.value),
        ReturnReasons.defaults,
      );
    });

    test('resolves the RAW storage path this route alone returns', () {
      // getReturnableItems passes $product->product_image through untouched,
      // unlike every other order route which wraps it in RvMedia::getImageUrl.
      expect(
        parse().items.single.imageUrl,
        'https://dev.truewayerp.com/storage/'
        'products/whole-wheat/81lm1nhmzol-sx679.jpg',
      );
      expect(parse().items.single.name, isNot(contains('&amp;')));
    });

    test('degrades to empty rather than throwing on a body with neither key',
        () {
      final eligibility =
          ReturnEligibility.fromJson(const {'order': null, 'returnable_items': null});
      expect(eligibility.isEmpty, isTrue);
      expect(eligibility.reasons, isEmpty);
    });
  });

  group('Return drafts', () {
    test('always sets is_return, which the controller filters on', () {
      final draft = ReturnDraft(
        orderId: 243,
        customerComment: 'x' * 60,
        reason: ReturnReasons.damaged,
        items: const [
          ReturnItemDraft(orderItemId: 338, quantity: 1, reason: 'damaged'),
        ],
      );
      final body = draft.toJson();
      expect(body['order_id'], 243);
      expect(body['reason'], 'damaged');
      final items = body['return_items'] as List;
      expect(items.single['is_return'], isTrue);
      expect(items.single['order_item_id'], 338);
      expect(items.single['qty'], 1);
      // Media keys are omitted rather than sent empty.
      expect(body.containsKey('media_images'), isFalse);
    });

    test('mirrors the server comment rule at both boundaries', () {
      expect(ReturnDraft.commentError(''), isNotNull);
      expect(ReturnDraft.commentError('x' * 49), contains('at least 50'));
      expect(ReturnDraft.commentError('x' * 50), isNull);
      expect(ReturnDraft.commentError('x' * 2000), isNull);
      expect(ReturnDraft.commentError('x' * 2001), contains('2000'));
      // Trimmed before measuring, like the server's sanitizer.
      expect(ReturnDraft.commentError('   ${'x' * 49}   '), isNotNull);
    });

    test('resubmit references return_item_id, not order_item_id', () {
      const draft = ReturnResubmitDraft(
        customerComment: 'comment',
        items: [ReturnResubmitItemDraft(returnItemId: 12, reason: 'damaged')],
      );
      final items = draft.toJson()['return_items'] as List;
      expect(items.single['return_item_id'], 12);
      expect(items.single['reason'], 'damaged');
      expect(draft.toJson().containsKey('order_id'), isFalse);
    });
  });

  group('OrderRepository', () {
    test('never lets per_page reach the value that 500s', () async {
      final built = await _build({
        '/ecommerce/orders': _Canned(200, jsonDecode(_ordersPerPage1)),
      });
      await built.repo.orders(page: 0, perPage: -5);
      expect(built.adapter.requests.single.queryParameters['per_page'], 10);
      expect(built.adapter.requests.single.queryParameters['page'], 1);

      await built.repo.orders(perPage: 5000);
      expect(built.adapter.requests.last.queryParameters['per_page'], 100);
    });

    test('sends only the filters that were supplied', () async {
      final built = await _build({
        '/ecommerce/orders': _Canned(200, jsonDecode(_ordersPerPage1)),
      });
      await built.repo.orders(status: OrderStatuses.canceled);
      final query = built.adapter.requests.single.queryParameters;
      expect(query['status'], 'canceled');
      expect(query.containsKey('shipping_status'), isFalse);
      expect(query.containsKey('payment_status'), isFalse);
    });

    test('unwraps the order detail envelope', () async {
      final built = await _build({
        '/ecommerce/orders/243': _Canned(200, jsonDecode(_detail243)),
      });
      final order = await built.repo.order(243);
      expect(order.id, 243);
      expect(order.lines, hasLength(1));
    });

    test('pulls the invoice url out and adds type=print on request', () async {
      final built = await _build({
        '/ecommerce/orders/133/invoice':
            _Canned(200, jsonDecode(_invoiceResponse)),
      });
      final url = await built.repo.invoiceUrl(133, forPrint: true);
      expect(url, endsWith('/generate-invoice'));
      expect(built.adapter.requests.single.queryParameters['type'], 'print');
    });

    test('turns an ineligible return into a businessRule error and keeps the '
        'specific reason recoverable', () async {
      final built = await _build({
        '/ecommerce/orders/277/returns':
            _Canned(200, jsonDecode(_returnRefusal)),
      });

      ApiException? thrown;
      try {
        await built.repo.returnEligibility(277);
      } on ApiException catch (error) {
        thrown = error;
      }

      expect(thrown, isNotNull);
      expect(thrown!.kind, ApiErrorKind.businessRule);
      expect(thrown.statusCode, 200); // the refusal really is an HTTP 200
      expect(thrown.message, 'You cannot return this order');
      expect(
        OrderRepository.eligibilityHint(thrown),
        'Order must be in completed status to be eligible for return.',
      );
    });

    test('eligibilityHint ignores errors that are not refusals', () {
      const network = ApiException('offline', kind: ApiErrorKind.network);
      expect(OrderRepository.eligibilityHint(network), isNull);
    });

    test('parses the eligibility success envelope', () async {
      final built = await _build({
        '/ecommerce/orders/243/returns':
            _Canned(200, jsonDecode(_eligibilitySuccess)),
      });
      final eligibility = await built.repo.returnEligibility(243);
      expect(eligibility.items.single.orderItemId, 338);
      expect(eligibility.reasons, hasLength(5));
    });

    test('lists returns through the hybrid envelope, items included', () async {
      final built = await _build({
        '/ecommerce/order-returns': _Canned(200, jsonDecode(_returnsPerPage2)),
      });
      final page = await built.repo.returns(page: -3, perPage: 0);
      expect(page.items, hasLength(2));
      expect(page.items.first.items.single.refundAmount, 470.0);
      final query = built.adapter.requests.single.queryParameters;
      expect(query['page'], 1);
      expect(query['per_page'], 10);
    });

    test('unwraps a single return', () async {
      final built = await _build({
        '/ecommerce/order-returns/10':
            _Canned(200, {'error': false, 'data': jsonDecode(_returnResubmittable)}),
      });
      final orderReturn = await built.repo.orderReturn(10);
      expect(orderReturn.canResubmit, isTrue);
      expect(orderReturn.effectiveReason.value, 'damaged');
    });

    test('posts the exact submit body and decodes the created return',
        () async {
      final built = await _build({
        '/ecommerce/order-returns':
            _Canned(200, {'error': false, 'data': jsonDecode(_returnResubmittable)}),
      });
      final created = await built.repo.submitReturn(
        ReturnDraft(
          orderId: 198,
          customerComment: 'x' * 60,
          items: const [
            ReturnItemDraft(orderItemId: 286, quantity: 1, reason: 'damaged'),
          ],
        ),
      );
      expect(created.id, 10);
      final sent = built.adapter.requests.single.data as Map;
      expect(sent['order_id'], 198);
      expect(sent.containsKey('reason'), isFalse); // per-item reason only
      final items = sent['return_items'] as List;
      expect(items.single['is_return'], isTrue);
      expect(items.single['order_item_id'], 286);
    });

    test('resubmit posts to the {id}/resubmit path', () async {
      final built = await _build({
        '/ecommerce/order-returns/10/resubmit':
            _Canned(200, {'error': false, 'data': jsonDecode(_returnResubmittable)}),
      });
      await built.repo.resubmitReturn(
        10,
        const ReturnResubmitDraft(
          customerComment: 'still broken',
          items: [ReturnResubmitItemDraft(returnItemId: 12, reason: 'damaged')],
        ),
      );
      final sent = built.adapter.requests.single.data as Map;
      expect(sent.containsKey('order_id'), isFalse);
      expect((sent['return_items'] as List).single['return_item_id'], 12);
    });

    test('uploads return media as multipart with repeated files[] keys',
        () async {
      // Regression: this used to post `{"files": [MultipartFile]}` as a JSON
      // map, which dio cannot encode ("Converting object to an encodable object
      // failed") — and which Laravel rejects anyway, because uploadMedia() reads
      // $request->file('files'). Captured proof: returns/u02_files_arrstr.json,
      // "The files.0 must be a file.".
      final dir = Directory.systemTemp.createTempSync('return_media');
      addTearDown(() {
        // Windows keeps the handle open until the multipart stream is GC'd.
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          // Best effort — it is a temp dir.
        }
      });
      final one = File('${dir.path}/one.jpg')..writeAsBytesSync([1, 2, 3]);
      final two = File('${dir.path}/two.jpg')..writeAsBytesSync([4, 5, 6]);

      final built = await _build({
        '/ecommerce/order-returns/upload-media':
            _Canned(200, jsonDecode(_uploadMediaResponse)),
      });
      final urls = await built.repo
          .uploadReturnMedia(filePaths: [one.path, two.path]);

      expect(urls, hasLength(2));
      expect(urls.first, endsWith('/a.jpg'));

      final sent = built.adapter.requests.single.data;
      expect(sent, isA<FormData>());
      final form = sent as FormData;
      // PHP only folds a BRACKETED key into an array.
      expect(form.files.map((entry) => entry.key), ['files[]', 'files[]']);
      expect(
        form.fields.map((entry) => '${entry.key}=${entry.value}'),
        ['type=image'],
      );
    });

    test('refuses an upload the server would reject on count', () async {
      final built = await _build({
        '/ecommerce/order-returns/upload-media':
            _Canned(200, jsonDecode(_uploadMediaResponse)),
      });
      await expectLater(
        built.repo.uploadReturnMedia(filePaths: const []),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        built.repo.uploadReturnMedia(
          filePaths: List<String>.filled(11, 'a.jpg'),
        ),
        throwsA(isA<ApiException>()),
      );
      // Neither attempt reached the network.
      expect(built.adapter.requests, isEmpty);
    });

    test('turns an unreadable attachment into an ApiException, not a raw '
        'FileSystemException', () async {
      final built = await _build({
        '/ecommerce/order-returns/upload-media':
            _Canned(200, jsonDecode(_uploadMediaResponse)),
      });
      await expectLater(
        built.repo.uploadReturnMedia(
          filePaths: ['${Directory.systemTemp.path}/definitely-not-here.jpg'],
        ),
        throwsA(isA<ApiException>()),
      );
    });

    test('sends the cancellation reason and surfaces a refusal', () async {
      final built = await _build({
        '/ecommerce/orders/14/cancel': _Canned(200, jsonDecode(_cancelRefusal)),
      });
      ApiException? thrown;
      try {
        await built.repo.cancelOrder(14, reason: 'other', description: 'changed');
      } on ApiException catch (error) {
        thrown = error;
      }
      expect(thrown?.kind, ApiErrorKind.businessRule);
      expect(thrown?.message, 'You cannot cancel this order');
      final sent = built.adapter.requests.single.data as Map;
      expect(sent['cancellation_reason'], 'other');
      expect(sent['cancellation_reason_description'], 'changed');
    });

    test('omits an empty cancellation description rather than sending ""',
        () async {
      final built = await _build({
        '/ecommerce/orders/14/cancel':
            _Canned(200, {'error': false, 'data': null, 'message': 'ok'}),
      });
      await built.repo.cancelOrder(14, reason: 'change-mind', description: '');
      final sent = built.adapter.requests.single.data as Map;
      expect(sent.containsKey('cancellation_reason_description'), isFalse);
    });

    test('confirms delivery with an empty body', () async {
      final built = await _build({
        '/ecommerce/orders/243/confirm-delivery':
            _Canned(200, {'error': false, 'data': null, 'message': 'ok'}),
      });
      await built.repo.confirmDelivery(243);
      expect(
        built.adapter.requests.single.path,
        '/ecommerce/orders/243/confirm-delivery',
      );
    });

    test('reports a missing invoice url instead of returning an empty string',
        () async {
      final built = await _build({
        '/ecommerce/orders/47/invoice':
            _Canned(200, {
          'error': false,
          'data': {'url': null},
        }),
      });
      await expectLater(
        built.repo.invoiceUrl(47),
        throwsA(isA<ApiException>()),
      );
    });
  });
  group('the order timeline, as the backend now sends it', () {
    // Live on order 314. The server filters its internal rows out before
    // sending — 8 customer-facing steps where the raw table holds 10 — and
    // writes `description` for the customer.
    Map<String, dynamic> history({
      String action = 'update_shipping_status',
      String description = 'Delivered',
      bool isSystem = false,
      String? location,
      String? courierName,
    }) =>
        {
          'id': 869,
          'action': {'value': action, 'label': action},
          'description': description,
          'is_system': isSystem,
          'created_at': '2026-08-14T17:59:13+05:30',
          'location': location,
          'courier_name': courierName,
        };

    test('the courier note joins whichever half arrived', () {
      // Both are nullable and independent: a status moved by hand in admin has
      // neither, and a scan can carry one without the other.
      OrderHistory of(Map<String, dynamic> j) => OrderHistory.fromJson(j);

      expect(of(history()).courierNote, isNull);
      expect(
        of(history(location: 'Bhilwara Hub')).courierNote,
        'Bhilwara Hub',
      );
      expect(
        of(history(courierName: 'Xpressbees')).courierNote,
        'Xpressbees',
      );
      expect(
        of(history(location: 'Bhilwara Hub', courierName: 'Xpressbees'))
            .courierNote,
        'Xpressbees · Bhilwara Hub',
      );
    });

    test('blank strings are not a note', () {
      expect(
        OrderHistory.fromJson(history(location: '  ', courierName: '')).courierNote,
        isNull,
      );
    });

    test('the carrier is on the ORDER, not on a step', () {
      // One fact about the shipment rather than something a step reported.
      final order = Order.fromJson({
        'id': 314,
        'code': 'SF10000314',
        'status': {'value': 'completed', 'label': 'Completed'},
        'shipping_company_name': 'Xpressbees Surface 20kg',
        'histories': [history(action: 'create_shipment', description: 'Order shipped')],
      });

      expect(order.shippingCompanyName, 'Xpressbees Surface 20kg');
      expect(order.histories.single.description, 'Order shipped');
    });

    test('an order with no shipment has no carrier, and does not invent one',
        () {
      final order = Order.fromJson({
        'id': 1,
        'code': 'SF1',
        'status': {'value': 'pending', 'label': 'Pending'},
      });

      expect(order.shippingCompanyName, isNull);
    });

    test('description is rendered as-is — there is nothing to map', () {
      // `action.label` repeats the raw slug on the order enum ("label":
      // "refund"), so it is useless for display and the app never reads it.
      final h = OrderHistory.fromJson(history(
        action: 'refund',
        description: 'Refund completed',
      ),);

      expect(h.description, 'Refund completed');
      expect(h.action, 'refund');
    });
  });
}
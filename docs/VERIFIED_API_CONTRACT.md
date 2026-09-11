# Verified API Contract — Trueway Farms Mobile

Base URL: `https://dev.truewayerp.com/api/v1`

Every contract in this document was exercised against the **live dev backend**.
Nothing here is inferred from the route file. Where a behaviour could not be
observed, it is marked **UNVERIFIED** with the exact step needed to close it.

**This document supersedes `docs/MOBILE_API_INTEGRATION_PLAN.md` wherever the
two disagree.** The plan doc was written from the backend route file; this one
is written from observed responses.

**Credentials never appear in this file.** Examples use `<API_KEY>` (the
`X-API-KEY` header value) and `<BEARER_TOKEN>` (a Sanctum personal access
token). Do not paste real values in.

### Scope and companion document

| Surface | Documented in |
|---|---|
| Catalogue, categories, brands, variants | This doc, §2 |
| Related / cross-sale / reviews | This doc, §3 |
| Logistics / serviceability | This doc, §4 |
| **The shipping contract checkout is priced by** | **This doc, §4.5 — authoritative** |
| OTP auth | This doc, §5 |
| Email/password auth + account | This doc, §6 |
| Coupons | This doc, §7 |
| Notifications + device tokens | This doc, §8 |
| **Cart, checkout, orders, addresses, wishlist, compare, profile, settings** | **`docs/VERIFIED_API_CONTRACT_AUTH.md`** |

The two documents were produced by separate probe runs. Where they overlap
(notifications, device tokens) both agree; §8 here is the fuller version.
Where they **conflict**, §1.3 records it explicitly — do not pick one silently.

> ⚠ **One known conflict, resolved here: shipping.**
> `VERIFIED_API_CONTRACT_AUTH.md` still answers open question 5 with *"the app
> sends `shipping_amount`"* (its §5.1, and the summary row at its line 39). That
> was true when it was written and is **no longer true of shipped code**. The app
> sends `shipping_method` + `shipping_option` and omits `shipping_amount`
> entirely. **§4.5 of this document is authoritative on shipping**; the AUTH doc
> remains correct about the *server's* validation rules for the field
> (`nullable|numeric|min:0`, no `max`) — the app simply does not use it.

---

## 1. Corrections to the plan doc

These are the findings that break a naive implementation *silently* — the code
compiles, the tests pass, and the feature is dead or dishonest in production.
Read all of §1 before writing any integration code.

### 1.1 Corrections that change money or user-visible truth

| # | Plan doc says | Live behaviour | Where |
|---|---|---|---|
| M1 | §E2 / §F: totals come from the cart response and the app must not recompute | **The finding stands; the app defect it described is FIXED.** Tax is **ADDED ON TOP** — live cart `raw_sub_total` 1798 + `discounted_tax_amount` 89.90 = `order_total` **1887.90** — and the app used to treat GST as already included, under-quoting every order by the full ~5%. `order_pricing.dart` now reads `order_total` verbatim (`OrderSummary.orderTotal`), `payable` is `order_total` plus the courier's quote, and `payableOrSubtotal` (`:110`) falls back to `orderTotal` rather than to a recomputed figure. The plan doc's instruction — *do not recompute* — is the correct one and is now what the code does. | §7.3 |
| M2 | §F: "a fake code is rejected by the server" | Only when the cart is **non-empty**. Against an empty or nonexistent cart, **any** 3–20 char string returns `error:false` + `Applied coupon "X" successfully!` with `coupon_discount_amount: 0` and `applied_coupon_code: null`. `error:false` is **not** proof a coupon is real. | §7.1 |
| M3 | §F: `FRESH10`/`ORGANIC15`/`WELCOME50` are "hardcoded client-side… real validation is server-side" | Confirmed and worse: all three are **rejected live** with `This coupon is invalid or expired!`, byte-identical to a random fake code — so they are not real coupons on this backend. **The app-side half of this finding is fixed:** the hardcoded client-side discounts and the cart screen that advertised the three codes by name are both gone (grepped 2026-08-04 — `lib/` mentions `FRESH10` only in a `cart_repository.dart` doc comment quoting the server's success string). Coupons now go through `POST /coupon/apply` and the app renders the server's `applied_coupon_code`. | §7.1 |
| M4 | §F: "Both return the full cart data — re-render from the response" | Wrong three ways. (a) Failure responses carry `data:null`. (b) Success `data` is a **reduced** cart missing `id`, `content`, `package_dimensions`, `status`, `total_weight/height/wide/length/volume`. (c) Its `cart_items` entries use the raw `Cart::content` shape and **lack** `image_url`, `row_id`, `quantity`, `price_formatted`, `subtotal_formatted`, `tax_rate`, `cart_options`. **You cannot re-render a cart screen from it** — re-`GET /ecommerce/cart/{id}` after every coupon call. | §7.1 |
| M5 | §F, §331: `POST /coupon/apply {coupon_code}` | `cart_id` is **also required** (422 without it). `POST /coupon/remove` — documented as taking no body — requires **both** `cart_id` **and** `coupon_code`. | §7.1, §7.2 |
| M6 | *(not mentioned anywhere)* | **EVERY failure path of `apply` and `remove` PERMANENTLY EMPTIES THE CART.** Verified on 8+ carts: count 3 → 0 after one rejected coupon. A control proves `GET` is not the cause. Shipping §F as written means a customer who mistypes a coupon loses their entire cart. | §7.4 |
| M7 | §H1: place order at `POST /ecommerce/checkout/cart/{cartId}` | Correct. But the UI audit and some probe notes reference `POST /ecommerce/checkout/place-order`, which the authenticated probe run found **DOES NOT EXIST** (`VERIFIED_API_CONTRACT_AUTH.md` §2.6). See §1.3 — resolve before wiring. | §1.3 |
| M8 | Open question 5: "Are shipping rates server-calculated, or does the app send `shipping_amount`?" | **Answered — server-calculated. SETTLED, do not re-litigate.** The app sends `shipping_method: "shiprocket"` + `shipping_option: "shiprocket_<rateId>"` and **no `shipping_amount`**, which is precisely what activates server pricing (`API/CheckoutController.php:425`). The field *is* still accepted and still client-trusted at `min:0` with no `max` (`VERIFIED_API_CONTRACT_AUTH.md` §5.1, `BACKEND_BUGS.md` finding 6) — the app declines to use it. Full contract in **§4.5**. Separately, `/logistics/check-pincode`'s `shipping_charge` is **not** the checkout price: it is quoted from a different warehouse (§4.4). The app's own ₹40 / free-over-₹499 rule exists nowhere on the server and has been removed. | §4.5 |

### 1.2 Corrections that break parsing

| # | Plan doc says | Live behaviour | Where |
|---|---|---|---|
| P1 | §0 finding 2: "`categories[]=` does not filter, even with correct IDs. `?categories[]=17` → 0 products" | **Wrong.** `categories[]=` filters correctly — it matches **DIRECT assignment only**. `categories[]=40` (leaf) → 3 products. `categories[]=17` returned 0 because root 17 has no directly-assigned products, which was correct behaviour. Meanwhile `/product-categories/{id}/products` **expands to descendants**. Both routes work; they answer different questions. The wrong comment is still repeated in `lib/core/network/api_endpoints.dart:53-54` — *"the `categories[]` query parameter on [products] is accepted but does not filter — verified live, 0 rows for every id"* (an earlier revision of this row cited `:22`, which is now the related-products doc; re-check before quoting). | §2.4 |
| P2 | §A5: "`brands[]=` **is** honoured… Optionally switch to `/ecommerce/brands/{id}/products` for consistency" | **Do not switch — that route does not filter at all.** ids `8`, `0`, `99999`, `"abc"` and `"bogus-slug-zzz"` every one returns the identical full 4-product catalogue. `?brands[]=<bogus>` correctly returns 0. This is the exact mirror image of categories, and `CatalogRepository.productsByBrand` (`catalog_repository.dart:212-229`) **still** calls `ApiEndpoints.productsInBrand`, i.e. the broken route — re-confirmed 2026-08-04. `api_endpoints.dart:62-63` even documents it as "for symmetry; either is fine", which it is not. | §2.5 |
| P3 | §E2 / §299: `cart_items[]` — an array | `cart_items` is a **MAP keyed by row id** when the cart has contents, and degrades to a bare **ARRAY `[]`** when empty. A `as Map` cast crashes on empty carts; a `as List` cast crashes on every real one. The coupon endpoints return a **second, differently-named** item shape (`rowId`/`qty`/`tax` vs `row_id`/`quantity`/`tax_price`). | §7.1 |
| P4 | §246: "`/notifications`, `/device-tokens` — Push-notification infrastructure, unused" | **13 working routes**, all returning real 2xx bodies. And `GET /notifications` returns `data` as an **OBJECT** (`{notifications, pagination, unread_count}`), not an array — so `unwrapList` (`api_response.dart:9-13`) silently returns `const []` and the Notifications screen shows "Nothing new" **forever, for every customer, with no error**. | §8.1 |
| P5 | §A2: category fields "at minimum `id`, `name`, `slug`, `parent_id`, `image`/`image_url`" | A product category has **no `image` and no `image_url`**. The 8 keys are exactly `id, name, icon, icon_image, is_featured, parent_id, slug, image_with_sizes`. `image_with_sizes` is absolute URLs; `icon_image` is a **relative** storage path needing the origin prepended. Mixing them produces broken images. | §2.3 |
| P6 | §A3: `productsByCategory(int categoryId, {int page, int perPage = 20})` | `/product-categories/{id}/products` **ignores `per_page` entirely** and is hardcoded to 15. Verified against `per_page`, `per-page`, `perPage`, `limit`, `take`, `page_size`, `paginate`, `num` — all ignored, `meta.per_page` always 15. Only `page` works. Drop the `perPage` parameter or document it as a no-op. | §2.4 |
| P7 | §69: "`X-API-KEY` is enforced on everything (401 without it)" | **Both logistics routes are completely unauthenticated** — 200 with no key, a wrong key, and a bogus bearer. They are registered outside the api-key middleware group. Anyone can enumerate the store's Shiprocket rate card and product-id space for free. | §4.1 |
| P8 | §D2: OTP endpoints return the `{error, data, message}` envelope | Every OTP endpoint emits **TWO incompatible envelopes at the same 422 status**: Laravel field-validation → bare `{message, errors:{field:[…]}}` with **no `error` key**; controller/business failure → `{error:true, data:null, message}` with **no `errors` key**. `POST /login` does the same thing. | §5.1, §6.2 |
| P9 | *(implied uniform envelope)* | The API uses **seven** envelope shapes, not two. `lib/core/network/api_response.dart:1-3` documents two. Full inventory in §1.4. | §1.4 |
| P10 | §A4: "21 categories with `parent_id` (0 = root)" | Exact split: **10 roots** (17,18,19,20,21,22,23,24,25,27), **11 children**. Max depth 2, no grandchildren. Ids 26, 37, 38 **do not exist** — never assume contiguous ids. | §2.3 |
| P11 | §A: acceptance "every category in the rail returns products" | **Unachievable on this dataset.** The whole catalogue is 4 products. Only categories 17 and 40 return anything; **19 of 21 return an empty array**. The app needs a real empty state and the acceptance criterion needs rewording. | §2.4 |
| P12 | §J: "Variants — `ProductOption` and `ProductOptionValue` are already parsed" | `product_options` is **`[]` in all 572 product objects observed across every probe**. `ProductOption`/`ProductOptionValue`/`Product.optionsLabel` are dead code. Real variants live in `attribute_sets` / `default_product_variation` / `selected_attributes`, which are **siblings of `data`** in the detail response and are thrown away by `unwrapObject`. | §2.2 |
| P13 | §1 line 30, general | `per_page` is **silently ignored by `/ecommerce/products`** — `meta.per_page` stays 15 for 0, 1, 2, 20, 100, 1000, -1, `abc` and `perPage`. The working params are **`per-page`** or **`num`**. `/ecommerce/orders` and `/notifications` *do* honour `per_page`, which is why this looks like it works. | §2.1 |
| P14 | §232: "the probe used GET, which this Laravel setup 404s" — noted in passing | This is a **contract-wide rule**: a wrong HTTP verb returns **404, not 405**, on every route probed. `api_exception.dart:218` maps 404 → `notFound`, so a verb mistake is indistinguishable from a missing resource. | §1.5 |
| P15 | §D4 table: `/email/check` returns `{exists: bool}` | Returns the full envelope, and when the account exists `data` carries an **undocumented nested `user` object** leaking the customer's full name: `{"exists":true,"user":{"name":"…","email":"…"}}`. | §6.3 |
| P16 | §D4 table: `/register` … `phone` (nullable server-side) | True, but when present `phone` must be numeric, **exactly 10 digits**, and match `^[6-9][0-9]{9}$`. `+919876543210` and `91987654321` are both **rejected**. `auth_repository.dart:159-169` always sends phone, so any user typing a country code gets a 422. Also undocumented: `name`/`first_name`/`last_name` min 2 max 120. | §6.1 |
| P17 | §D4 table: `/password/forgot` — "Emails a reset link" | There is **no API route to complete the reset**. `/password/reset`, `/password/change`, `/email/verify` all 404 on GET and POST. The flow can only be finished on the website. Also an unknown email returns 422 `We can't find a user with that email address.` — it leaks account existence. | §6.4 |
| P18 | §D4 table omits it | **`PUT /api/v1/me` exists** (proven by the server's own `Supported methods: GET, HEAD, PUT`). Almost certainly the profile-update endpoint an account screen needs. Contract in `VERIFIED_API_CONTRACT_AUTH.md` §4.2. | §6.5 |
| P19 | §C: "`POST /logistics/check-pincode` … also requires product information; **confirm the exact payload with the backend team**" (open question 3) | **Resolved by probing — no backend round-trip needed.** The field is `product_id`, a single scalar int. `products:[{…}]` and `product_ids:[…]` both fail. Section C is buildable today. | §4.1 |
| P20 | §C: "Response: `{success, status, message, deliverable}`" | That 4-key shape is only the check-pincode **400/404** body. The 200 body has **10 keys** (adds `pin_code`, `estimated_delivery_days`, `estimated_delivery_date`, `shipping_charge`, `courier_name`, `cod_available`). A model written to the doc's shape discards the rate, courier and ETA. | §4.1 |
| P21 | §C: "`POST /logistics/check-serviceability` for cart-level checks" | It accepts **no cart id, no product id and no line items**. It is a raw Shiprocket rate-card proxy needing 9 client-computed fields including a `pickup_postcode` that **still has no settings route** — but it is no longer undiscoverable: every cart line carries `cart_options.store.zip_code` (live `"311001"`), and `GET /ecommerce/cart/{id}` returns `package_dimensions` + `total_weight` for the parcel. The app now reads all of that (`pickupPinCodeFromCart`, `shipping_provider.dart:152`) and assembles the 9 fields itself; there is still no server-side cart aggregation in this family. | §4.2, §4.5 |
| P22 | §I: "Shiprocket tracking is available via the logistics plugin" | The logistics plugin exposes **exactly two routes**. 28 candidate tracking paths were enumerated; all 404. Order tracking is `POST /ecommerce/orders/tracking` in the ecommerce plugin. | §4.3 |
| P23 | §0 note: "`setting('fast2sms_otp_login')` must be ON or `send` returns 422 *OTP login is not enabled*" | OTP login **is on** for dev (high confidence — every probe reached the customer lookup). But the **exact wording of that message is UNVERIFIED**, and `auth_repository.dart:32` hard-codes the substring `otp login is not enabled`. If the server says anything else, the match fails silently. | §5.1 |
| P24 | §D2: "`otp` must be exactly 6 chars" | The rule is **size-based, not digit-based**. `"abcdef"` passes validation despite the error message saying "digits". Do not rely on the server to reject non-numeric OTPs. Also `otp` and `phone` must be JSON **strings** — integers are rejected. | §5.2 |
| P25 | §441: "`flutter test` green (73 today)" | **1290 tests across 50 files, all passing** as of 2026-08-04. The two that actively certified wrong behaviour have been removed — see §1.6. Any test count in any of these docs is a snapshot that goes stale within days; run `flutter test` rather than cite it. | §1.6 |

### 1.3 Unresolved contradiction between the two verified docs

`POST /ecommerce/checkout/place-order`

- The authenticated probe run (`VERIFIED_API_CONTRACT_AUTH.md` §2.6) states this route **DOES NOT EXIST**.
- A separate probe reported it returning `401 Unauthenticated`, which normally implies a matched route.

Both cannot be true. **Do not implement against `place-order`.** The
plan doc, the AUTH doc and the order-placement probe all agree the working
route is `POST /ecommerce/checkout/cart/{cartId}` — use that. Resolve the
discrepancy by re-probing both paths with the same bearer before Section H
work starts.

### 1.4 The seven response envelopes

`lib/core/network/api_response.dart` documents two. Live, there are seven.
**Never truth-test `body['error']` — branch on the HTTP status code.**

| # | Shape | Where |
|---|---|---|
| A | `{error:bool, data:[…], message}` | sliders, ads, brands (unpaginated), related, cross-sale, categories list *without* `per_page` |
| B | `{data:[…], links, meta}` | classic paginated |
| C | `{data:{…}, error, message, +sibling keys}` | **product detail** — `attribute_sets`, `default_product_variation`, `selected_attributes`, `unavailable_attribute_ids` are siblings of `data` and are silently dropped by `unwrapObject` |
| D | `{data:[…], links, meta, error, message}` — **hybrid** | `/product-categories` *with* `per_page`, `/product-categories/{id}/products` |
| E | `{error:bool, data:{<key>:[…], pagination:{…}}, message}` | `GET /notifications` — nested non-standard `pagination`, **not** `links`/`meta` |
| F | bare Laravel `{message, errors:{field:[…]}}` — **no `error`, no `data`** | every 422 field-validation failure |
| G | `{message, error:"Unauthorized"}` — **`error` is a STRING** | every X-API-KEY 401 |

Plus two degenerate bodies that are not envelopes at all:

- `{"message": ""}` — 404 for an unknown slug. **Empty message string**, no `error`, no `data`. A generic parser renders a blank error dialog.
- `{"message":"The GET method is not supported for route …"}` — bare, for a wrong verb.

**The two incompatible 401s.** They disagree on the *type* of `error` and need
opposite handling:

| Cause | Body | Action |
|---|---|---|
| Expired / missing bearer | `{"error":true,"data":null,"message":"Unauthenticated."}` (`error` = **bool**) | log the user out |
| Missing / wrong X-API-KEY | `{"message":"Invalid or missing API key…","error":"Unauthorized"}` (`error` = **string**) | **build/config bug — must NOT log anyone out** |

`api_client.dart:41` currently cannot distinguish them: it gates on
`headers.containsKey('Authorization')`, which is true for *every* request once
a token exists. A rotated API key therefore signs every user out.

### 1.5 Cross-cutting HTTP behaviour

- **Wrong verb → 404, never 405**, with a bare `{message}` body naming the supported methods. Useful as a **side-effect-free route-existence oracle** (the request is rejected before any controller runs).
- **`Accept: application/json` is mandatory on sanctum routes.** Without it (including curl's default `Accept: */*`), `GET /me` and `GET /logout` return **302 to `https://dev.truewayerp.com/login` with an HTML body**. The trap is narrower than feared — validation 422s and X-API-KEY 401s return JSON regardless of `Accept` — but the app's auto-logout genuinely depends on the header.
- **Middleware order**: on sanctum-protected routes, sanctum fires **before** the api-key check. A request with no key and a bad token returns `Unauthenticated.`, never the api-key message.
- **Unvalidated input crashes endpoints.** `?per_page=-1` on `/products/{slug}/reviews` → **HTTP 500**. `?per_page=abc` on `/product-categories` → **HTTP 500**. Never forward a raw query value from UI state or a deep link.
- **No rate limiting anywhere probed.** 25 rapid `/otp/send` calls and 13 rapid bad-credential `/login` calls: zero 429s, no `X-RateLimit-*`, no `Retry-After`.
- **Params are accepted from any source** — JSON body, form-encoded, and query string all work identically on the POST routes probed.
- **Pagination is not clamped.** Requesting a page beyond `last_page` returns 200 with an empty array and `current_page` echoing your request. Compare `current_page` against `last_page` yourself.

### 1.6 Tests that certified wrong behaviour — **both removed**

Kept as a record so nobody re-adds them. Two tests were green-lighting a
guarantee the app did not provide; neither name exists in
`test/core/order_pricing_test.dart` any more (grepped 2026-08-04):

- *"GST is shown as an included portion, never added on top"* — encoded M1, and the suite green-lit a ~5% under-quote on every order. GST is added on top; see M1.
- *"regression: cart and checkout must agree"* — **vacuous**: it called the pure function `OrderSummary.from` twice with byte-identical arguments and asserted the results matched. A pure function cannot disagree with itself. It never constructed `CartScreen` or `CheckoutScreen`.

The lesson generalises: a pricing test that never renders a screen proves nothing
about whether two screens agree.

### 1.7 Security findings to escalate to the backend team

1. **`POST /device-tokens` is an IDOR.** It sits outside the sanctum group and never calls `$request->user()` — `user_type` and `user_id` come straight from the request body. Verified live: with only the (app-embedded, therefore public) API key, a device token was attached to customer 16, and that customer's own bearer then listed it. Anyone holding the API key can receive any customer's order and promo pushes.
2. **`POST /otp/send` is an unthrottled phone-enumeration oracle** *and* an SMS-bombing / direct-cost vector against any registered number.
3. **`POST /email/check` is an unauthenticated account-enumeration oracle that additionally discloses the customer's full name.** `POST /password/forgot` is a second one.
4. **Both logistics routes are entirely unauthenticated** (P7).
5. **`/product-categories/{id}/products` 404 leaks the Eloquent class name**: `No query results for model [Botble\Ecommerce\Models\ProductCategory] 99999`.
6. **`/products/{slug}/reviews` serves unmoderated reviews** — a `status:"pending"` row is returned to anonymous callers (§3.3).
7. **The X-API-KEY is a live enforced credential embedded in the shipped APK** and written into `docs/BACKEND_API.md:10`. Treat it as burned; rotate it.

---

## 2. Family: Catalogue

### 2.1 `GET /ecommerce/products`

| | |
|---|---|
| **Auth** | `X-API-KEY` only |
| **Envelope** | **B** — `{data:[…], links, meta}` |

**Query contract**

| Param | Status |
|---|---|
| `per-page` **(hyphen)**, `num` | ✅ **the working page-size params** (12/24/36 verified; 1000 falls back to 15) |
| `per_page` (underscore), `perPage` | ❌ **silently ignored** — `meta.per_page` stays 15 for 0, 1, 2, 20, 100, 1000, -1, `abc` |
| `page` | ✅ |
| `categories[]=<id>` | ✅ filters on **DIRECT assignment only** (leaf 40 → 3 rows; root 17 → 0 rows; bogus → 0). `categories=17` without brackets → 0. |
| `brands[]=<id>` | ✅ filters correctly (real id → 4, bogus → 0) |
| `is_featured` | ✅ |
| `q` | ✅ search |

> ⚠️ `lib/core/network/api_endpoints.dart:22` claims `categories[]` "does not
> filter — verified live, it returns 0 rows for every category id". That comment
> is **wrong** (P1) and must be corrected.

**Item shape — 29 keys**: `id, slug, name, sku, description, content, quantity,
is_out_of_stock, stock_status_label, stock_status_html, price, price_formatted,
original_price, original_price_formatted, reviews_avg, reviews_count, images,
images_thumb, image_with_sizes, weight, height, wide, length, image_url, videos,
product_conditions, product_options, store`.

Notes that bite:

- **No `categories` field on any product payload.** There is no API that maps product → its categories.
- `product_options` is **`[]` in all 572 observed product objects** (P12).
- `videos` is `[]` in all 571 observed payloads.
- `description` and `content` are multi-KB inline-styled HTML blobs.
- `image_url` is the **150×150 thumbnail**; `images[0]` is the full-size original. `primaryImage` in `product_model.dart:196` currently prefers the thumbnail.
- `weight` is **gross shipping weight, not pack size**: product 118 has `weight: 5100` for a "Net Quantity 5000.0 Grams" pack; 119 has `15200` for 15 kg. Deriving a pack label or unit price from it is wrong by ~2%.
- Product 118 is returned by **no category** (probed all 21 ids). **UNVERIFIED** whether it is uncategorised or assigned to a soft-deleted category — the product resource carries no `categories` field. *To verify: backend confirms 118's assignment in admin, or adds `categories` to the product resource.*

**Dataset reality**: `meta.total = 4` (ids 111, 118, 119, 120).

### 2.2 `GET /ecommerce/products/{slug}` — product detail (and variants)

| | |
|---|---|
| **Auth** | `X-API-KEY` only |
| **Envelope** | **C** — `{data:{…}, error, message, + siblings}` |

**The headline**: the variant data lives in **siblings of `data`**, not inside
it, and `unwrapObject` (`api_response.dart:18`) discards all of them:

| Sibling key | Contains |
|---|---|
| `attribute_sets` | e.g. product 111: set *Pack Size* → attribute `21` = "1.85 KG (Pack of 1)" price 493.5 weight 1850; attribute `22` = "5 KG (Pack of 1)" price 921.501 weight 5000 |
| `default_product_variation` | **the id the cart actually needs** (product 111 → `116`) |
| `selected_attributes` | currently-selected attribute ids |
| `unavailable_attribute_ids` | out-of-stock combinations |

Consequences:

- **`weight` is `null` on the detail endpoint for variable products** but populated in the list endpoint, because the real weight moved into `attribute_sets[].attributes[].weight`. The pack-size pill and unit price appear on the product card and vanish on the detail page for the same product.
- Product 111's detail shows only the parent (₹921.50, SKU TRW3214). The cheaper 1.85 kg variant at ₹493.50 is **unreachable from the app** — a 1.9× price spread the customer never sees.
- `POST /ecommerce/cart` with **parent** id 111 returns a cart line with **id 116** and `variation_attributes: "(Pack Size: 5 KG (Pack of 1))"`. The server silently resolves parent → default variation. Any `quantityOf(product.id)` lookup keyed on the parent id **returns 0 forever**, so the ADD button never becomes a stepper.

Resolution endpoint: `GET /ecommerce/product-variation/{id}?attributes[<setId>]=<attrId>`
(verified resolving product 111 + attribute 21 → variation 117 at ₹493.50).

**Errors**: `404 {"message": ""}` for an unknown slug — unambiguous "does not
exist", no fallback search needed. `401` envelope **G** with no/bad key.

### 2.3 `GET /ecommerce/product-categories`

| | |
|---|---|
| **Auth** | `X-API-KEY` only |
| **Envelope** | **A** *without* `per_page` · **D** *with* `per_page` — **same URL, two shapes** |

**Query contract**

| Param | Status |
|---|---|
| `per_page` | ✅ — **and its presence changes the envelope**. Omit → `{data,error,message}`, all 21 rows, no meta. Send → `{data,links,meta,error,message}`. |
| `page` | ✅ only when `per_page` is also sent; `?page=2` alone returns all 21 rows |
| `is_featured` (0\|1) | ✅ — `1` → 18 rows, `0` → 3 rows (17, 18, 22) |
| `parent_id`, `limit`, `search`, `q` | ❌ ignored — all return the full 21 rows |

There is **no way to ask the server for only roots or only children**. Fetch all
21 and build the tree client-side. Recommended call: `?per_page=100` in one shot,
or omit `per_page` entirely and parse envelope A.

**Item shape — exactly 8 keys**: `id:int, name:string, icon:string|null,
icon_image:string|null, is_featured:int(0|1 — **not bool**), parent_id:int
(**0 for root, never null**), slug:string, image_with_sizes:object|null`.

- `image_with_sizes` when non-null has 4 keys of **absolute** URLs: `origin`, `thumb`, `medium`, `"product-thumb"` (**hyphen**, not underscore). 9 of 21 rows are null.
- `icon_image` is a **relative** storage path (`product-categories-1/2488.jpg`) needing the origin prepended. 6 of 21 rows have it.
- 6 categories (31–36) have neither → they render imageless. Design for it.
- Default sort is neither id order nor tree order, but is stable across pages.

**Tree**: 10 roots (17,18,19,20,21,22,23,24,25,27), 11 children.
`17 → [28,29,40]`, `18 → [30,31]`, `21 → [32,33,34]`, `22 → [35,36,39]`.
Max depth 2. Ids 26, 37, 38 do not exist.

**Errors**: `500 {"message":"Server Error"}` on `?per_page=abc`. `per_page=0`
and `-1` do not crash — they fall back to envelope A. `401` → envelope G.

### 2.4 `GET /ecommerce/product-categories/{slug}` and `/{id}/products`

**Route binding is inconsistent and opposite between these two adjacent routes:**

| Route | Accepts | Rejects |
|---|---|---|
| `/product-categories/{slug}` | **slug only** | numeric id → 404 |
| `/product-categories/{id}/products` | **numeric id only** | slug → 404 |

**`GET /product-categories/{slug}`** — envelope **A**, `data` is a bare object.
Same 8 keys **plus `description`** (HTML string\|null). Metadata only: no
products, no children.

> ⚠️ **`icon` is polymorphic across endpoints.** The list returns the Tabler CSS
> class `"ti ti-wheat"`; this detail route returns **full rendered `<svg …>`
> markup** for the same category. Any shared model must treat `icon` as an
> opaque string, never as an icon-name lookup.

**`GET /product-categories/{id}/products`** — envelope **D**, always paginated
regardless of params, `meta.per_page` always **15**. `data` is an array of the
full 29-key product resource.

**✅ Answered: a root category DOES return its children's products.** The app
must **not** query children separately. Proof chain: `?categories[]=40` → 3
products; `?categories[]=17` → 0 (so they are assigned only to child 40);
`/product-categories/17/products` → those same 3 products.

> **UNVERIFIED — recursion depth.** The tree is only 2 levels and only one
> branch (17→40) has products, so "aggregates all descendants recursively" is
> **unproven**; only "aggregates direct children" is proven, on a **sample size
> of one branch**. *To verify: backend creates a root→child→grandchild chain with
> a product on the grandchild only, and assigns a product under any child of 18,
> 21 or 22.*

**Errors**: `404 {"message":"No query results for model [Botble\\Ecommerce\\Models\\ProductCategory] 99999"}`
(same for id 0, -1, `abc`, and for a slug — and it leaks the model class).
Over-paging returns **200** with `data:[]` and `current_page` echoing your request.

**Coverage**: probed all 21 ids. Only 17 and 40 return anything (the same 3
products). The other 19 return `data:[]`, `total:0`.

### 2.5 `GET /ecommerce/brands/{id}/products` — ⛔ DOES NOT FILTER

Ids `8`, `0`, `99999`, `"abc"` and `"bogus-slug-zzz"` **all return the identical
full 4-product catalogue** (`[119,118,111,120]`). Use
`GET /ecommerce/products?brands[]=<id>` instead, which filters correctly.
`CatalogRepository.productsByBrand` (`catalog_repository.dart:134`) currently
uses the broken route and is reachable in production via `/products?brand=<id>`.

`GET /ecommerce/brands` returns envelope **B** (paginated), not the simple
envelope `unwrapList` assumes — it works today only because exactly one brand
exists.

---

## 3. Family: Related / Cross-sale / Reviews

All three are public (`X-API-KEY` only), all use envelope **A** — but with
**two different `data` shapes**:

| Route | `data` is |
|---|---|
| `/related` | a bare **ARRAY** |
| `/cross-sale` | a bare **ARRAY** |
| `/reviews` | an **OBJECT** — the reviews are one level deeper at `data.reviews` |

A shared `ApiResponse<List<T>>` unwrapper written against `/related` silently
returns empty on `/reviews`.

### 3.1 `GET /ecommerce/products/{slug}/related`

- Path param **must be the slug**; a numeric id → 404.
- **No query params are honoured** — `per_page=1`, `per_page=1000`, `limit=1` and `page=2` all returned the byte-identical full 3-item body. Do not build a "load more" on related products.
- Result is a **real relation**, not "all other products": 118 → [119,111,120]; 119 → [111,120]; 111 → 2 items; 120 → 2 items.

**Item shape — exactly 17 keys**, a **strict subset** of the list item. It is
**missing** `sku, description, content, images, images_thumb, videos, weight,
height, wide, length, product_options` — 11 fields. Reusing `Product.fromJson`
requires every one of them to be nullable/defaulted.

### 3.2 `GET /ecommerce/products/{slug}/cross-sale`

**VERIFIED ONLY AS EMPTY.** Exact 40-byte body for all 4 products:
`{"data":[],"error":false,"message":null}`.

> **BLOCKED — the shape of a populated cross-sale item is UNVERIFIED.** Do not
> assume it matches `/related`. Safe to ship a "hide the section when empty" UI;
> the item DTO cannot be written from evidence. *To verify: add a cross-sale
> relation to any product in the admin panel and re-probe.*

### 3.3 `GET /ecommerce/products/{slug}/reviews`

**Query contract**

| Param | Status |
|---|---|
| `page` | ✅ 1-based; `page=2` and `page=99999` return an empty array at 200 |
| `per_page` | ✅ `per_page=1` returned exactly 1 |
| `star` | ✅ **only for 1–5**. `star=0`, `abc`, `99` return the **full unfiltered set** at 200 — and `99` is still interpolated into `message`. Validate client-side. |
| `limit` | ❌ silently ignored (`limit=1` returned all 2) |
| `Authorization` | ignored — a bogus bearer does not 401; still returns `has_reviewed:false` |

**Response**: `{error:false, data:{reviews:[…], has_reviewed:bool,
user_review:null}, message:string}`.

**Review object — exactly 13 keys**: `id, user_name, user_avatar,
created_at_tz, created_at, comment, star, status, status_text, images, videos,
ordered_at_tz, ordered_at`.

Four traps in that shape:

1. **`user_avatar` is an inline base64 `data:image/jpeg;base64,…` URI** whenever the reviewer has no uploaded avatar (a 250×250 JPEG, ~3,959 JSON chars). Reviewers who *do* have one get a normal https URL — **both cases occur in the same array**, so branch on `startsWith('data:')` → `Image.memory(base64Decode(…))` vs `Image.network(…)`.
2. **It is NON-DETERMINISTIC.** Five identical GETs returned avatar lengths 3939 / 3687 / 4003 / 3259 / 3899 and bodies 7610 / 7355 / 7662 / 6914 / 7564 bytes. The server re-encodes per request, so HTTP/CDN caching and any image cache keyed on the URI are **both defeated** (`Cache-Control: no-cache, private`, no ETag). Budget **~4 KB incompressible per review** — a 20-review page is ~80 KB of avatars alone; gzip only halves the whole body because base64 does not compress.
3. **`created_at` is a relative English string** ("2 weeks ago") — use `created_at_tz` (ISO8601 + offset) for any real formatting. `ordered_at` ships with a literal ✅ emoji baked in: `"✅ Purchased 7 months ago"`. Do not render it next to your own verified-purchase badge.
4. **`videos[].thumbnail` is the .mp4 URL itself**, not an image. Feeding it to an image widget fails.

**No pagination metadata at all** — no `links`, `meta`, `total`, `current_page`,
`last_page`. `page`/`per_page` work as *inputs* but the response gives you
nothing to build a pager from. The **only** source of the total count is a
human-readable English sentence in `message`:
`2 review(s) for "Trueway Farms Organic Desi Khand Brown (khandsari)"`.
Any "showing X of Y" UI must regex that string and will break on a locale change.

**No star-count / rating breakdown exists anywhere** — not here, not in the
product detail (which has only `reviews_avg` + `reviews_count`). Rendering a
histogram requires 5 separate `?star=1..5` calls plus regex-parsing each
`message`. **Flag to the backend team as a missing field.**

**⚠️ Unmoderated reviews are served publicly.** Review 1019 has
`status:"pending"` and is returned to anonymous callers. This is why counts
disagree: `/reviews` returns 2 and says "2 review(s)", while the product detail
and list both report `reviews_count:1` (correctly excluding the pending row).
**The app will show a different count in the header than in the list unless it
filters `status == 'published'` client-side.**

**Errors**: `500 {"message":"Server Error"}` on `?per_page=-1` — **never emit a
negative per_page**. `?per_page=0`, `abc`, `?page=abc`, `?page=-1` return 200
unfiltered. `404 {"message":""}` for an unknown slug or a numeric id.

> **UNVERIFIED — the `per_page` cap and default.** `per_page=1000` returned 200
> with all 2 reviews, which proves nothing: the entire dataset is 3 reviews
> across 4 products. The default is simply ≥ 2. *To verify: seed >100 reviews on
> one product, or read the controller's `paginate()` default.*

### 3.4 `POST /ecommerce/reviews`, `GET /ecommerce/reviews`, `DELETE /ecommerce/reviews/{id}`

All three **bearer-required**. Only the 401 body is verified:
`{"error":true,"data":null,"message":"Unauthenticated."}` (55 bytes) — identical
whether the header is missing or the token is invalid, so the two cases are
indistinguishable.

`GET /ecommerce/reviews` is the customer's **own** reviews list, not a public
product list.

> **BLOCKED — the `POST /ecommerce/reviews` request body and 422 contract.**
> Sanctum auth runs **before** FormRequest validation, so every unauthenticated
> probe returns 401 and never reaches the validator. **Do not let anyone guess
> the field names from the web form.** *To unblock: (a) a pre-issued Sanctum
> bearer for a test customer, or (b) the `ReviewRequest`/`ReviewController`
> `rules()` from the Botble source.*
>
> Same blocker for the authenticated shapes of `GET`/`DELETE`, and for
> `data.user_review` / `has_reviewed:true` (always null/false without a token).

---

## 4. Family: Logistics / Serviceability

> **Both routes are completely UNAUTHENTICATED** (P7). Verified 200 with no
> `X-API-KEY`, with a wrong key, with a bogus bearer, and with no `Accept`
> header. Control probe in the same session: `GET /ecommerce/products` without
> the key → 401. Sending the key is harmless and recommended for consistency.

**Section C is buildable today.** No backend question remains.

> **§4.5 is the section to read if you are here about money.** It records the
> shipping contract the app actually ships — `shipping_method` +
> `shipping_option`, **no `shipping_amount`** — the two ways it silently bills
> ₹0.00, why the courier price is a sum of four components and not the row's
> `rate`, why **no courier is preselected**, and where the server ships from.
> §4.1–§4.4 describe the two endpoints; §4.5 describes what the app does with
> them.

### 4.1 `POST /logistics/check-pincode` — deliverability only, **not a price**

**Request** — JSON, form-encoded or query string. Exactly **two** fields, both required:

| Field | Type | Rules |
|---|---|---|
| `pin_code` | string\|int | `^[1-9][0-9]{6-digit}$` — leading whitespace trimmed. The alias `pincode` is **not** accepted. |
| `product_id` | int\|numeric-string | **a single scalar.** `products:[{…}]` and `product_ids:[…]` both fail. |

Everything else is **silently ignored** — `quantity`, `qty`, `cod`, `weight`
and unknown keys produce byte-identical responses. Weight/dimensions are read
**server-side from the product record**, so `shipping_charge` is a
**single-unit, single-product** figure. **Do not multiply it by cart quantity
and do not present it as the cart's shipping total.** And it is priced from a
**different warehouse** from the one checkout bills against — see §4.4. Treat
this endpoint's answer as `deliverable` + ETA, never as rupees.

**Response — envelope: FLAT, no `data` wrapper, no `error` key.** This is an
eighth shape not in §1.4. The key set **varies by outcome**, so everything below
the first four must be nullable in Dart.

**200 success — 10 keys**:

| Key | Type | Note |
|---|---|---|
| `status` | String | `"success"` |
| `message` | String | `"Delivery available"` |
| `deliverable` | **bool** | |
| `pin_code` | String | echoed, trimmed |
| `estimated_delivery_days` | **String** | `"2"` — **not an int** |
| `estimated_delivery_date` | String | `"03-08-2026"` — **dd-MM-yyyy** |
| `shipping_charge` | double | e.g. `321.51` |
| `courier_name` | String | `"DTDC Surface 10kg"` |
| `cod_available` | **int** | `1`/`0` — **not a bool**, even though `deliverable` and `success` in the same object are real bools |
| `success` | bool | |

**422 (unknown pincode) — 5 keys**: `status, message, deliverable, pin_code, success`.
**400 / 404 — 4 keys only**: `success, status, message, deliverable`.

HTTP status **is** meaningful and correct on this endpoint (unlike 4.2).

**Errors**

| Status | Message | Trigger |
|---|---|---|
| 400 | `Pin code is required` | `pin_code` absent, `""`, or sent as `pincode` |
| 400 | `Product information is required` | `product_id` absent, null, 0, negative, or non-numeric — all treated as **missing**, not invalid |
| 400 | `Please enter a valid 6-digit pin code` | 5 or 7 digits, alphabetic, `000000`, leading zero. Matches `lib/core/utils/validators.dart` exactly. |
| 404 | `Product not found` | numeric but nonexistent id, or `[118]` |
| 422 | `Unable to check delivery availability` | passes the regex but Shiprocket has no zone (123456, 100000, 999999). **This is "we don't deliver there", not an outage.** |
| 404 | `The GET method is not supported…` | wrong verb |

**"Service temporarily unavailable" did NOT reproduce** in 12 consecutive calls
(all 200, live courier data, real Aug-2026 ETDs). The Shiprocket integration
**is** configured and working on dev. That message's trigger remains
**UNVERIFIED** — most likely an upstream-timeout or token-refresh catch block.
*To verify: backend greps the logistics plugin for the string.*
**Mitigation regardless: treat any 4xx/5xx from check-pincode as "could not
verify" and allow the address rather than hard-blocking checkout.**

**⚠️ Product scope leak**: this route resolves product ids **not in the public
catalogue** (117 and 121 both return 200 with real rates, though
`GET /ecommerce/products` reports `total:4`). A 200 here does **not** imply the
product is purchasable.

Deterministic: 4 repeat calls returned byte-identical bodies.
Headers: no rate-limit headers, `Cache-Control: no-cache`,
`Access-Control-Allow-Origin: *`, OPTIONS preflight → 204.

### 4.2 `POST /logistics/check-serviceability` — a raw Shiprocket proxy

**Not a cart-level check** (P21). **Nine** required fields, all of which the
client must compute: `pickup_postcode`, `delivery_postcode`, `cod`, `height`,
`breadth`, `length`, `weight`, `declared_value`, `qc_check`.

Validation is **presence-only** (Laravel `filled()`): `0` is accepted, `""` and
`null` count as missing. Values are otherwise **not validated** — the
`(6-digit)` and `(0 or 1)` hints in the error text are **not enforced**;
`cod:"yes"`, `cod:2`, `weight:-1` and a 5-digit pickup postcode all pass
straight through to Shiprocket.

**🔴 BIGGEST TRAP IN THIS FAMILY: every upstream Shiprocket error returns HTTP
200.** No-courier, invalid pickup pincode, zero weight, parcel-too-heavy — all
200. Dio will not throw. **Branch on the `success` boolean**, and read
`data.status` for the real upstream code. Only local presence-validation uses 400.

**200 body — 5 keys**: `success, status, message, data, deliverable`.
On success `data` is the **raw Shiprocket response, double-nested** — the
courier list is at `data.data.available_courier_companies` (~7 objects, ~85
fields each). Useful leaves: `id` (**the rate id** — the one `shipping_option` is
built from, distinct from `courier_company_id`), `courier_name`,
**`freight_charge` + `coverage_charges` + `other_charges` + `cod_charges` (the
four the price is summed from — §4.5)**, `rate` (upstream's own total, which omits
coverage and other charges — **do not display it**), `cod`, `etd`
(`"Aug 04, 2026"` — **a different date format from check-pincode's
`"04-08-2026"`**), `estimated_delivery_days` (String), `rating`, `city`, `state`,
`courier_company_id`. `cost` is the empty string `""` on every row of every
capture — ignore it.
On upstream failure `data` collapses to `{message, status:int}` where `status`
is **Shiprocket's own code** — the only place the real error appears.

**400 body — 4 keys**: `success, status, message, errors` — and **`deliverable`
is ABSENT**, unlike every check-pincode error which always carries it.
`errors` is a **Map<String,String>** of human hints, not Laravel's
`{field:[messages]}` array form.

> **`pickup_postcode` — no longer blocked, but not certain either.** There is
> still **no settings route**: `/ecommerce/settings`, `/ecommerce/store`,
> `/ecommerce/shipping-settings`, `/ecommerce/store-locators`,
> `/ecommerce/warehouse`, `/site-info`, `/general-settings`, `/marketplace/stores`
> all 404, and check-pincode never echoes the pickup it used. The value was
> instead **derived from 62 real orders** and is **311001** (Bhilwara), with the
> live origin readable off any cart line at `cart_options.store.zip_code`.
> **`382415` is wrong** — it is a *delivery* pincode and quotes 45–70 % low.
> Method, evidence and the four unexplained orders: **§4.5**.
>
> **`declared_value` is the pre-shipping order total** — `order_total` from
> `GET /ecommerce/cart/{id}`, i.e. total-after-discount *before* shipping is
> added. Confirmed against `API/CheckoutController.php:381` (`$orderAmount =
> $cartTotals['total_after_discount']`), `:433` (that figure is what gets passed
> into the shipping quote) and `:462` (shipping is added to it only afterwards).
> Matching the server matters: this field is **not** free-form, it moves the
> price via `coverage_charges` (§4.5). The app sends the cart's `order_total`
> verbatim; the historical reconstruction used `(int) order_total` because that
> is what the server had computed.
>
> **Multi-item parcel aggregation is solved, and the server does it for you.**
> `GET /ecommerce/cart/{id}` returns `package_dimensions`
> (`{length, breadth, height, weight, box_id, box_name}`) and `total_weight` in
> grams. Live 2026-08-04, product 118 × 1: `{20, 7, 25, 5.1}`, `total_weight`
> 5100, `order_total` 943.95. `PackageDimensionCalculator`'s rule is
> L = max(length)+1, B = max(breadth)+1, H = Σ(height × qty)+1, W = Σ(weight × qty)/1000,
> with `box_id`/`box_name` null because no box catalogue is configured. **Read
> the cart's block; do not recompute it** — the rule above is only for
> reconstructing historical orders whose products are no longer purchasable.

**Recommendation: use both, for different questions.** `check-pincode` answers
"can we deliver here" in 2 fields with correct HTTP codes, and it is the right
call behind a PDP or address-entry check — but **its `shipping_charge` is priced
from a different warehouse** (§4.4), so it must never be shown as a price.
`check-serviceability` is the one that produces the courier *choice* list and the
`shipping_option` checkout is priced from (§4.5).

### 4.3 Routes that do not exist

28 candidate paths enumerated under `/logistics` (`track`, `tracking`,
`order-tracking`, `awb`, `shipments`, `rates`, `couriers`, `shipping-rates`,
`estimate`, `pickup-locations`, `zones`, `warehouse`, `config`, `settings`,
`status`, `create-order`, `generate-awb`, `cancel-shipment`, `check-cod`, …)
with both GET and POST. **All 404.** The plugin exposes exactly two routes.
Order tracking is `POST /ecommerce/orders/tracking` in the ecommerce plugin.

### 4.4 ANSWERED — check-pincode's `shipping_charge` is **not** the amount charged

It is quoted from a **different warehouse from the one checkout bills against**,
and the two are unrelated by construction. This is now proved, not suspected.

| | pickup postcode comes from | value |
|---|---|---|
| `check-pincode` | `PinCodeDeliveryService::getPickupPostcode()` `:145-148` → `setting('logistics_pickup_postcode', '110001')` | **110001** (Delhi) |
| checkout / `check-serviceability` | `EcommerceHelper::getOriginAddress()` `:1102,1114` → `get_ecommerce_setting('store_zip_code')`, then the marketplace store's own zip (`ShipRocketService.php:1715-1740`) | **311001** (Bhilwara) — see §4.5 |

Two different settings keys, in two different plugins, with two different
defaults. Neither reads the other.

**Confirmed empirically, not just from source.** check-pincode's exact parcel was
replayed through `check-serviceability` against 8 candidate pickup pincodes; for
products 117 and 119 the (courier, `rate`, `etd`) triple reproduced at **110001
only**.

**Rule for the app: use check-pincode for the yes/no deliverability answer and
never render its rupee figure as a price.** Any screen that needs a number —
PDP delivery estimate, pincode checker, checkout — must re-quote through
`check-serviceability` with the cart's real parcel. A ₹-figure from this endpoint
on a screen the customer buys from is quoting a warehouse they will not be billed
against.

---

### 4.5 THE SHIPPING CONTRACT AS SHIPPED — read this before touching checkout

**Settled. The app sends `shipping_method` + `shipping_option` and NOT
`shipping_amount`; the server prices the order.** This is the same contract the
web checkout uses. It is implemented and working. Do not reopen it.

#### The two fields

```jsonc
POST /ecommerce/checkout/cart/{cart_id}
{
  "shipping_method": "shiprocket",              // the GROUP key — a literal
  "shipping_option": "shiprocket_1016322646"    // the MEMBER key — "shiprocket_" + rate id
  //  NO "shipping_amount" — its absence is what turns server pricing ON
}
```

| Step | Backend | What it establishes |
|---|---|---|
| group key | `logistics/HookServiceProvider.php:59` — `$result['shiprocket'] = $serviceabilityRates` | the group is the literal `"shiprocket"`, never a courier name |
| member key | `ShipRocketService.php:1889` — `'shiprocket_' . $rateId`, where `:1870` is `$rateId = Arr::get($courier, 'id')` | the row's **`id`**, *not* `courier_company_id` |
| group lookup | `HandleShippingFeeService.php:58` — `Arr::get($result, $method, [])` | `shipping_method` selects the group |
| member lookup | `HandleShippingFeeService.php:68` — `Arr::get($filtered, $option)` | `shipping_option` selects the row |
| price | `ShipRocketService.php:1894` — `'price' => $totalCost`, read by `API/CheckoutController.php:445-446` | the server's own number lands on the order |
| the switch | `API/CheckoutController.php:425` — `$useClientShippingAmount = $request->has('shipping_amount')`, and `:445` skips server pricing when true | **sending the field — even as `null` — disables server pricing** |

#### The two ways it can silently bill ₹0.00

Both are **undercharges on a real, dispatchable order**, and neither raises an
error the client can see:

1. **`shipping_method: "default"` (or omitting it).** With no `shipping_option`,
   `HandleShippingFeeService.php:68` calls `Arr::get($filtered, null)`, and
   Laravel's `Arr::get` with a null key returns **the entire array** — one level
   too deep. `CheckoutController.php:443` takes `Arr::first()` of that, `:446`
   finds no `price` key at that level and falls through to its `0` default. This
   is the real cause of "mobile orders ship free" — **not** missing shipping
   rules. It returns 0.00 whether or not `ec_shipping` has rows.
2. **A rate id the server's own re-quote does not contain.** A Shiprocket rate id
   identifies a *quote*, not a courier. The server calls Shiprocket again at
   checkout time and looks the key up in the table that call built; if the quote
   has aged out or the origin differs, the lookup misses and lands on the same
   `0` default.

The web throws a `ValidationException` here
(`PublicCheckoutController.php:743-750`). The mobile API degrades silently.
**So a sent key is not a guarantee** — `PlacedOrder.shippingAmount` must be
reconciled after `placeOrder` returns and before the payment sheet opens.

#### The price of a courier row is a SUM, not its `rate` field

**This is the money finding. Quote the sum; never quote `rate`.**

`ShipRocketService::formatServiceabilityRates()` rebuilds the rate table itself
and never reads the row's `rate`. Line by line, all four components read with
`(float) Arr::get($courier, …, 0)`:

```php
// ShipRocketService.php — extract, non-contiguous lines elided
:1874  $freightCharge   = (float) Arr::get($courier, 'freight_charge', 0);
:1875  $coverageCharges = (float) Arr::get($courier, 'coverage_charges', 0);
:1876  $codCharges      = (float) Arr::get($courier, 'cod_charges', 0);
:1877  $otherCharges    = (float) Arr::get($courier, 'other_charges', 0);
:1880  $baseShippingCost = $freightCharge + $coverageCharges;
:1883  $totalCost        = $baseShippingCost + $otherCharges;
:1884  if ($this->isCodOrder($originalData)) {
:1885      $totalCost += $codCharges;
:1886  }
:1889  $rateIdKey = 'shiprocket_' . $rateId;
:1894  $rates[$rateIdKey] = [ … 'price' => $totalCost … ];
```

and that `price` is what lands on the order:

```php
// API/CheckoutController.php
:446  $shippingAmount = Arr::get($shippingMethod, 'price', 0);
:462  $orderAmount   += (float) $shippingAmount;
```

So the billed figure is **`freight_charge + coverage_charges + other_charges`**,
plus **`cod_charges` only when the quote was requested with `cod: 1`** — the
condition at `:1884` is `isCodOrder($originalData)`, a property of the *request*,
not of the row. A COD-ness flag therefore has to ride with the rate list rather
than be re-derived at each call site.

**The live ₹49.00 step.** Probed 2026-08-04, pickup 311001 → delivery 382415,
5.0 kg 20×7×49, `qc_check` 0, `cod` 0, varying **only** `declared_value`:

| `declared_value` | `coverage_charges` on every row | Xpressbees Surface 5kg `rate` | `freight_charge` | what the server bills |
|---|---|---|---|---|
| 2400 | 0.00 | 272.06 | 272.06 | 272.06 — **agrees** |
| **2500** | **49.00** | 272.06 | 272.06 | **321.06** — `rate` is **₹49.00 low** |

The same step reproduces at 10 kg on the same lane: `declared_value` 314 →
coverage 0, `rate` 741.32 = billed 741.32; `declared_value` 3108 → coverage 49.00,
`rate` 741.32 but billed **790.32**.

`declared_value` is the basket's own `order_total` (§4.2), so **every basket at or
above roughly ₹2,500 crosses this step**, and `rate` under-quotes it by exactly the
coverage line.

**Does `rate` ever already equal the sum? Yes — and that is coincidence, not
agreement.** `rate` is `freight_charge` on a prepaid quote and
`freight_charge + cod_charges` on a COD one. It **never** carries
`coverage_charges` or `other_charges`. So on any row where both of those are zero
— i.e. every quote below the insurance threshold — the two figures happen to
match. Summing the four components reproduces `rate` exactly on the agreeing rows
and is the server's own number on the diverging ones, so the sum is correct for
both and `rate` is correct only by luck.

**Historical corroboration, from real orders:**

- order 275 (`declared_value` 3108) recorded **802.12**, which is today's 311001
  quote of 741.32 plus **49.00 coverage** plus 11.80;
- order 266 (COD) recorded **326.31** = 272.06 plus **48.35 `cod_charges`** plus
  5.90.

⚠ **The residual ₹11.80 and ₹5.90 are rate-card drift, not `other_charges`.**
They are ₹1 per kg of the courier's base slab plus 18 % GST (10 kg → 11.80, 5 kg →
5.90), the same uniform revision that explains nine other orders in the pickup
derivation below — orders 272/274/276/277, 273, 269/271. An order record stores
`shipping_amount` as **one number** and never breaks it into components, so no
order can evidence a particular component. Do not read these two as an
`other_charges` sighting; an earlier draft of this section did, and it was wrong.

`other_charges` was **zero on every row of every capture taken**. It is summed
anyway because the server sums it (`:1877`, `:1883`) — the day upstream starts
populating it, a client that omitted it under-quotes silently and there is no
signal that anything changed. Do not use `cost` either: it is the empty string
`""` on every row of every capture.

✅ **Implemented app-side.** `CourierOption` parses `coverage_charges` and
`other_charges` and exposes `billedPrice` (`shipping_quote.dart:465-469`), which
is `$totalCost` term for term; `codQuoted` (`:407`) is stamped onto every row by
`listFrom(body, cod:)` from the request the list was fetched with.
`billedPriceFormatted` is the only price string a customer may be shown —
`rateFormatted` was deleted so nothing can regress to it. `rate` is still parsed
and kept (every capture and note refers to it, and it is a cheap cross-check) but
is **used nowhere for money**: `shippingChargeProvider`, the widget price renders,
`listFrom`'s zero-price drop guard, the sort comparators and `CourierOption ==`
all key on `billedPrice`.

#### Nothing is preselected — the customer picks the courier

**Product decision, 2026-08-04, implemented.** `CourierOption.best` and
`ShippingRates.best` are deleted. `selectedShippingProvider` returns null unless
the customer picked *for this exact `ShippingQuery`* and that courier is still in
the live list, and `shippingChargeProvider` / `shippingMethodProvider` /
`shippingOptionKeyProvider` are null with it. Null means **"no delivery option
chosen"** — not zero, not free. Two auto-selects were removed: the `rates.best`
fallback in the provider and a `?? rates.options.first` in the cart's delivery bar,
which drew a full summary row (courier, date, price) for a courier nobody had
chosen. Even a single-courier quote must be tapped. `sortBest` / `byBestFirst`
survive as **display order only**.

Why it mattered: the old rule was fastest-first with cheapest as tie-break, which
on a live quote selected Blue Dart Air at ₹1,284.15 when Xpressbees Surface was
₹324.30 two days later — ₹960 the customer never agreed to.

**The comment claiming `best` mirrored the web was wrong.** That rule is
`PinCodeDeliveryService::findBestCourier` (`:157-177` — `usort` on
`estimated_delivery_days` then `rate`, `return $couriers[0]`), and that service
serves **`POST /logistics/check-pincode`**, the product page's "delivers to your
pincode" widget. Checkout never calls it.

**What the web checkout actually does — verified in source, and it is not
"preselects nothing" in general either:**

- `HandleCheckoutOrderData.php:94` — on a first visit `$defaultShippingMethod`
  falls back to `ShippingMethodEnum::DEFAULT`, which is the literal `'default'`
  (`ShippingMethodEnum.php:13`).
- `:130` — `$defaultShippingOption = Arr::first(array_keys(Arr::first($shipping)))`,
  i.e. the **first** option of the **first group**. A first-rule, never a
  fastest-or-cheapest ranking.
- `HandleShippingFeeService::execute()` puts the flat `default` group into
  `$result` first (`:43-49`) and only then runs
  `apply_filters('handle_shipping_fee', …)` (`:55`), which is where
  `logistics/HookServiceProvider.php:59` appends `$result['shiprocket']`. So the
  shiprocket group is never first when a `default` group exists.
- `shipping-methods.blade.php:21` marks a radio `checked` only when **both**
  `old('shipping_method', $defaultShippingMethod) == $shippingKey` **and**
  `old('shipping_option', $defaultShippingOption) == $shippingOption`.

Put together: `'default' == 'shiprocket'` is false, so **no Shiprocket courier is
ever checked on a first render** — either a flat "Default Shipping" rule is
preselected, or (when no default rule matches) nothing is. The app matching "no
courier preselected" is therefore correct as to couriers; the blanket claim that
the web "preselects nothing at all" is not, and should not be repeated.

#### Where the server ships from: **311001**, strong but not certain

`get_ecommerce_setting('store_zip_code')` has **no public route**, so this was
derived rather than read. The value **311001** is correct today.

✅ **The app no longer hardcodes it.** `ServerCartItem.storeZipCode`
(`server_cart.dart:254`) parses `cart_options.store.zip_code`;
`pickupPinCodeFromCart` (`shipping_provider.dart:154-164`) resolves the basket to
one postcode; `checkoutParcelProvider` (`checkout_provider.dart:230`) is the live
path. `kDefaultPickupPinCode = '311001'` (`shipping_provider.dart:123`) is now a
**fallback**, not the pickup postcode — it stands in for an empty cart, a line with
no store block, a store zip that fails the six-digit rule, or a basket spanning two
stores with different postcodes. Its value is unchanged, so no rate moved.

**Method — redo this when the store moves.** All read-only; no order, address,
review, return or OTP was touched.

1. **Orders.** `GET /ecommerce/orders?per_page=50` × 2 pages → all 90 orders; 62
   carry `shipping_method: "shiprocket"` with a non-zero `shipping_amount`.
   `GET /ecommerce/orders/{id}` for each → the recorded amount, the delivery
   `shipping_info.zip_code`, and each line's stored options blob (weight g,
   length, wide, height).
2. **Parcel reconstruction.** Disposable anonymous carts
   (`POST /ecommerce/cart {product_id, qty}`) rebuilt 6 of the baskets and their
   `package_dimensions` / `total_weight` / `order_total` were read back. They
   reproduce the historical totals exactly — cart `{118:1}` → `order_total`
   943.95, and order 277 is `1274.15 − 330.20 = 943.95` — which validates the
   reconstruction. `declared_value = (int) order_total` (pre-shipping; see §4.2).
3. **Sweep.** `POST /logistics/check-serviceability` varying **only**
   `pickup_postcode`: 4 named candidates, then 35 pincodes spanning India, then
   all 62 orders × {311001, 110001, 382415}. Every row scored on **both**
   `freight+coverage+other(+cod)` and raw `rate`, matched to 0.005.

**Result.**

- **5 exact matches at 311001**, none anywhere else: orders 237, 243, 246
  (₹272.06, Xpressbees Surface 5kg) and 264, 268 (₹741.32, Xpressbees Surface
  10kg). The matching figure is the **sum**, never `rate` — which is the second,
  independent proof of the section above.
- **9 more drift-consistent at 311001**: recorded = today's quote + N × 1.18,
  where N is the courier's base slab in kg — a uniform ₹1/kg-of-slab rate-card
  revision plus 18 % GST. Orders 272/274/276/277 (330.20 = 324.30 + 5.90),
  273 (521.82 = 510.02 + 11.80), 269/271 (753.12 = 741.32 + 11.80),
  275 (802.12 = 741.32 + 11.80 + 49.00 coverage), 266 COD
  (326.31 = 272.06 + 5.90 + 48.35 `cod_charges`).
- **14 of 18** reconstructible 2026 shiprocket orders explained.
- **Gujarat is decisively excluded.** 0/62 exact at 382415 or 380049; they quote
  45–70 % low (order 264 recorded 741.32; best from 382415 is 501.16, from 380049
  is 391.76). 395003 and 388001 fail too. The server does **not** price from the
  store's Ahmedabad-area delivery region.

**Why "strong" and not "proved" — stated plainly.** ₹272.06 and ₹741.32 are not
unique to 311001: of 35 pincodes swept, 28 give byte-identical Xpressbees rates
to 382415, because that zone table is flat outside Gujarat/NE/Kerala. Only
sub-2 kg parcels separate 311001 from 110001 — and the only two sub-2 kg orders
(247, 248, ₹147.36) match **neither**. Orders 238 (₹340.36) and 267 (₹1806.96)
are unmatched at every candidate. All four end in `.36`, the
Xpressbees/Shadowfax/Delhivery family, and most likely rode couriers that have
since left the Shiprocket account. **Reported as misses: 4 of 18.**

**Corroborating, all pointing at Bhilwara 311001:**

- every live cart line carries
  `cart_options.store = {"id":10, "slug":"trueway-farms-1", "name":"Trueway Farms", "zip_code":"311001"}`
  (re-read live 2026-08-04);
- the real invoice PDF for order 276 prints *"Sold By: Trueway Farms … Bhilwara-311001 … State/UT Code: 08 … Place of Dispatch: Rajasthan"*. **Caveat:**
  `marketplace/src/Providers/HookServiceProvider.php:292-293` sets
  `'company_zipcode' => $storeZipCode ?: …`, i.e. the invoice's company zip is
  **overridden with the marketplace store's**. So the invoice evidences the
  *store* row, not the ecommerce setting — it corroborates, it does not prove;
- structurally, 311001 is also what the server falls back to when
  `store_zip_code` is unset: `ShipRocketService::getPickupPostcode()` `:1715`
  tries `origin.zip_code` first, then `getStorePostcodeFromCartItems()` `:1753`,
  which returns the marketplace store's zip — 311001.

#### Two standing instructions this produced

1. ~~**Stop hardcoding the pickup pincode.**~~ — **DONE.** Every cart response
   carries the live origin at `cart_items[*].cart_options.store.zip_code`, and the
   app now reads it there (`pickupPinCodeFromCart`, `shipping_provider.dart:152`),
   keeping `kDefaultPickupPinCode` only as the fallback. **Read the residual risk
   before assuming this closed the question:** the app reads **rung 2** of
   `ShipRocketService::getPickupPostcode()` (`:1715-1745`), while the server tries
   **rung 1** (`origin.zip_code` = `get_ecommerce_setting('store_zip_code')`)
   first. The two agree only while rung 1 is unset. See the SQL below.
2. **Reconcile with a tolerance, not with `==` — but keep the tolerance tight.**
   Shiprocket's rate card moved by ₹5–10 + GST between 2026-07-06 and 2026-07-16
   — orders 264/268 and 269/271 are the identical parcel days apart at ₹741.32 vs
   ₹753.12, and exact equality would have interrupted 13 of these 18 real orders.

   **An earlier revision of this doc recommended ±2 % or ±₹15. That
   recommendation is withdrawn and does not describe the shipped code.** The
   historical drift it was sized for was between orders placed *days* apart.
   Within one checkout session the app and the server quote *seconds* apart from
   the same warehouse, so once the price formula is correct there is no legitimate
   drift for a wide band to absorb — and a ₹15 band would have waved through
   exactly the ₹49.00 coverage error this section documents, plus up to ₹15 of
   silent overcharge on every order. What ships is
   `TotalDivergence.tolerance = 0.005` (`checkout_provider.dart:742`) — half a
   paise, wide enough only for binary floating-point dust on `decimal(15,2)`
   columns. `PlacedOrder.totalMatches` (`placed_order.dart:313`) uses the same
   `0.005`. A wide band belongs, if anywhere, in an **ops** report over historical
   orders — never in the sheet that asks a customer to approve a price.

#### The one question that closes the last 5 %

```sql
SELECT value FROM settings WHERE `key` = 'ecommerce_store_zip_code';
```

— or one look at **Admin → Ecommerce → Settings → General**. Empty confirms 311001
via the fallback chain, and the app's cart-read lands on the same lane the server
does. **Any other value wins server-side**, because rung 1 is checked before the
store row the app reads — and then the app quotes one warehouse while the order is
billed from another, on every order. In that case the fix is *not* to edit
`kDefaultPickupPinCode` (it is only the empty-cart fallback now); it is to get the
resolved pickup postcode onto the cart response, or a read-only settings endpoint
exposing rungs 1 and 3.

---

## 5. Family: OTP Auth

All three routes are `POST`-only at `/api/v1/otp/{send,verify,resend}` and need
**`X-API-KEY` only** — no bearer. `lib/core/network/api_endpoints.dart:35-37`
already has the correct paths.

Only these three exist — confirmed using the wrong-verb 404 as a side-effect-free
oracle. `/otp/status`, `/check`, `/login`, `/register`, `/validate`, `/confirm`
all return "route could not be found".

**Every endpoint in this family emits two incompatible envelopes at the same 422
status** (P8):

| Failure kind | Envelope | Keys |
|---|---|---|
| Laravel field validation | **F** | `{message, errors:{field:[…]}}` — **no `error`, no `data`** |
| Controller / business | **A** | `{error:true, data:null, message}` — **no `errors`** |

Branch on the **presence of `errors`**, not on `body['error']`.

### 5.1 `POST /otp/send`

**Request**: `{"phone": "<string>"}` — the only field read. Rules are exactly
`required|string`: **no regex, no min/max, no digits rule.** `"1"`,
`"abcdefghij"` and a 40-char string all passed validation and reached the
customer lookup. `phone` **must be a JSON string** — integer `0` and array
forms are rejected.

**The app must do its own phone-format validation.** The server will not catch
a malformed number — it just says "Phone number not found!", which the app then
routes to the **register** screen, so a user who typos their number is sent to
sign up for a duplicate account.

**Errors**

| Status | Body | Trigger |
|---|---|---|
| 422 | `{message:"Phone number is required.", errors:{phone:[…]}}` | `{}`, `""`, `null` — all byte-identical. **Custom text**, not Laravel's default. |
| 422 | `{message:"The phone must be a string.", …}` | integer or array |
| 422 | `{"error":true,"data":null,"message":"Phone number not found!"}` | well-formed string, no matching customer. **Exact text**, trailing `!`, no period. This is the string the app routes to registration on. |
| 401 | envelope **G** | missing/wrong key |
| 404 | bare `{message}` | wrong verb |
| — | **no 429 ever observed** | 25 rapid requests, zero rate-limit headers |

> **UNVERIFIED — the success payload.** The plan's
> `{error:false, data:{message, phone, customer_id, expires_in}, message:"OTP sent successfully"}`
> is an **assumption, not a contract**. Confirming it requires dispatching a
> real SMS at real cost to a real person. *To unblock: a team-owned registered
> phone number with consent, or read-only access to
> `platform/plugins/uminber/src/Http/Controllers/API/OtpController.php` (zero SMS).*
>
> **UNVERIFIED — the "OTP login is not enabled" wording** (P23). Never
> reproducible. `auth_repository.dart:32` hard-codes the substring
> `otp login is not enabled`; if the server says anything else the match fails
> **silently** and users get a generic error. *To unblock: read the controller,
> or have an admin toggle `fast2sms_otp_login` OFF for ~60s while `/otp/send` is
> re-probed with `0000000000` — that probe sends no SMS and is free.*
>
> **OTP login IS ON for dev** — high confidence, not absolute proof: every probe
> reached the customer lookup and the "not enabled" message never appeared on
> ~35 requests. **Production is entirely unverified** — only dev was probed.

### 5.2 `POST /otp/verify`

**Request**: `{"customer_id": <int|numeric-string>, "phone": "<string>",
"otp": "<6-char string>"}` — all three required.

- `customer_id` carries an `exists:customers` rule. A numeric string is accepted and cast.
- `otp` **must be a string**; the rule is **size-based, not digit-based** — `"abcdef"` passes despite the message saying "digits".
- `phone` is required but is **not** observably cross-checked against the customer record — a non-matching phone produced the same generic "Invalid or expired OTP." **UNVERIFIED** whether it is checked at all.

**⚠️ "Customer not found" arrives in the errors bag**, not as a business
message: `errors.customer_id = ["Customer not found."]`. And the top-level
`message` is Laravel's **aggregate** string — with 3 failures it literally reads
`"Customer ID is required. (and 2 more errors)"`. **Showing `body.message`
verbatim renders that to the user.**

**Errors** (all 422 unless noted): empty body → aggregate + 3 fields; bogus
`customer_id` → `Customer not found.`; 5/7-char otp → `OTP must be exactly 6
digits.`; integer otp → `The otp must be a string.`; valid customer + wrong otp
→ `{"error":true,"data":null,"message":"Invalid or expired OTP. Please try
again."}` (the deepest verified point in the flow). 401 → envelope **G**.
Wrong verb → 404.

> **UNVERIFIED — the success payload** (`{token, customer:{…}}`). Same blocker
> as 5.1.

**Safe enumeration note for future probing**: pairing a bogus `customer_id`
with `otp="12345"` is side-effect-free — the 5-char OTP always fails the size
rule, so Laravel rejects at the validation layer and the controller never runs
(no SMS, no OTP consumed, no attempt counter). This established that customer
ids 1–5 and 10 do **not** exist and id 20 does. `/otp/verify` only *checks* an
OTP; it never sends one.

### 5.3 `POST /otp/resend`

**Request**: `{"customer_id", "phone"}` — both required. `otp` is **not**
accepted (an empty body reports exactly two missing fields).

Only the bare Laravel validation envelope was reachable safely.

> **BLOCKED BY DESIGN — everything past validation.** Reaching the controller
> **sends a real SMS to a real customer's phone**, which the safety rules
> forbid. The plan's claim that resend returns `{message, expires_in}` is
> **UNVERIFIED**, and `auth_repository.dart:55-65` is already coded against it.
> The success body, business-error bodies, and whether it requires a prior
> `/otp/send` are all unknown.
>
> **UNVERIFIED — OTP lifetime / `expires_in`.** The plan's "5 minutes / 300"
> could not be tested. `auth_repository.dart:62-64` defaults to 300 when absent,
> which is a reasonable fallback but not a contract.

### 5.4 There is no machine-readable error code

Verified across all 24 captured OTP payloads: **zero** `code` / `error_code` /
`errorCode` fields anywhere. The app **cannot** branch on a code — it is forced
to string-match, which `auth_repository.dart:249-258` (`_mapOtpError`) already
does, and which **currently works** for the unknown-phone case.

Recommended robust approach:

1. Branch primarily on **HTTP status + envelope shape** — presence of an `errors` map means field validation (render per-field); absence means a business failure.
2. Keep the substring match but **normalise hard** (lowercase, strip all non-alphanumerics) and match a short stable core such as `phonenumbernotfound`, so punctuation drift cannot break routing to the register screen.
3. **Log every 422 from `/otp/send` whose message matches neither known string**, so server wording drift is detected instead of silently degrading.
4. Ask the backend team to add a stable `code` field — **the only real fix.**

---

## 6. Family: Email/Password Auth + Account

All six documented endpoints exist. **No account was created and no email or
SMS was sent** during probing — every `/register` probe carried a deliberate
guard failure.

### 6.1 `POST /api/v1/register`

**Auth**: `X-API-KEY` only. **Verified status**: 422 paths only.

| Field | Rules |
|---|---|
| `name` **OR** (`first_name` **AND** `last_name`) | string, **min 2, max 120** each. `required_without` in both directions — `first_name` alone is not enough. |
| `email` | required, valid email, **min 6, max 60**, unique |
| `password` | required, min 6 (no max found at 200), rule `confirmed` |
| `password_confirmation` | **required whenever `password` is sent** |
| `phone` | **nullable** (omitted, `null`, `""` all pass). When present: numeric, **exactly 10 digits**, `^[6-9][0-9]{9}$`. `+919876543210` and `91987654321` both **rejected**. |

Unknown extra fields (`is_admin`, `confirmed_at`, `foo`) are silently ignored.

Validation errors use envelope **F** only, returned as JSON regardless of `Accept`.

> **BLOCKED — the 2xx success envelope.** Creating an account was out of scope.
> Whether registration returns a token (the plan claims it does not) is
> **unknown**. It is also not 100% certain that
> `name + email + password + password_confirmation` alone is a complete valid
> payload — only that no further *required-field* errors appear. *To unblock:
> one throwaway registration on dev explicitly authorised by the backend owner,
> or a pasted 200/201 body.*

### 6.2 `POST /api/v1/login`

**Auth**: `X-API-KEY` only. Body: `email` (valid address) + `password`. No
`device_name` or other Sanctum param needed.

**🔴 HIGHEST INTEGRATION RISK IN THIS FAMILY: `/login` returns two structurally
different bodies at the SAME 422 status.**

| Cause | Envelope | Body |
|---|---|---|
| Wrong credentials | **A** | `{"error":true,"data":null,"message":"Email or password is not correct!"}` |
| Missing/malformed fields | **F** | `{"message":"The email field is required. (and 1 more error)","errors":{…}}` |

**Error mapping must branch on the presence of `errors`, not on status.**

A wrong password on a **real** account and a login for a **non-existent** email
return the identical message — `/login` does not leak account existence.
**No rate limiting**: 13 bad-credential attempts in ~10s, all 422, no 429, no
`Retry-After`.

> **BLOCKED — the 200 success body.** `auth_repository.dart:99-115` assumes
> `data.token` and no customer object; that is **unconfirmed**. *To unblock:
> credentials for a disposable dev test customer, or a captured payload.*
>
> **UNVERIFIED — the plan's claim (§268) that `/login` enforces `confirmed_at`.**
> A wrong password on a real account returned the same generic message, so no
> `confirmed_at`-specific behaviour was observable. **Not a contract.**

### 6.3 `POST /api/v1/email/check`

**Auth**: `X-API-KEY`. Body: `email` (required, valid). Length limits are
**not** applied here (unlike `/register`). Lookup is **case-insensitive**.

**Both branches verified live** — envelope **A**:

```jsonc
// not found
{"error": false, "data": {"exists": false}, "message": null}   // message is JSON null

// found — `user` is UNDOCUMENTED and leaks the customer's name
{"error": false,
 "data": {"exists": true, "user": {"name": "Trueway Farms", "email": "info@truewayfarms.com"}},
 "message": null}
```

`data.user` is present **only** when `exists` is true. `data.exists` is a real
JSON bool. The app's `isEmailTaken()` reads `data.exists` correctly.

**Security**: an unauthenticated, unthrottled account-enumeration oracle that
additionally discloses the customer's full name. Escalate.

### 6.4 `POST /api/v1/password/forgot`

**Auth**: `X-API-KEY`. Body: `email` — required, valid format, **and must
resolve to an existing customer**.

- 422 `{"message":"We can't find a user with that email address.","errors":{…}}` for an unknown email — it does **not** silently pretend to succeed, so this is a second enumeration oracle.

> **UNVERIFIED — the 2xx shape.** Triggering it against a real address would
> email a real person.
>
> **🔴 CRITICAL GAP: there is NO route to complete a password reset.**
> `/password/reset`, `/password/change`, `/email/verify`, `/refresh-token`,
> `/token`, `/me/avatar`, `/update/profile`, `/update/password` all 404 on both
> GET and POST. **The password-reset flow cannot be completed inside the app** —
> the emailed link goes to the website. The plan doc does not mention this.

### 6.5 `GET /api/v1/me`, `PUT /api/v1/me`, `GET /api/v1/logout`

**All bearer-required.** Headers: `Authorization`, `X-API-KEY`, and —
**critically** — `Accept: application/json`.

**The Accept-header trap is REAL and CONFIRMED, and narrower than feared**: it
affects **only** the sanctum 401 on `/me` and `/logout`. Without the header
(including curl's default `*/*`) both return **302 → `https://dev.truewayerp.com/login`
with an HTML body**. `Accept: application/json` or
`X-Requested-With: XMLHttpRequest` restores the real 401:
`{"error":true,"data":null,"message":"Unauthenticated."}`.

`/logout` is **GET, not POST** — confirmed by the server's own supported-methods
message. The app already uses GET, which is correct.

**`PUT /api/v1/me` exists** (P18) — proven by `Supported methods: GET, HEAD, PUT`.
Its request body and rules are documented in `VERIFIED_API_CONTRACT_AUTH.md` §4.2.

**`GET /me` returns more than the app models** (per the authenticated probe):
`{id, email, name, phone, avatar, dob, gender, description, settings}` where
`settings = {biometric_enabled, notification_enabled, language, currency, theme,
timezone}`. **`avatar` is not a URL** — it is a ~3,891-character
`data:image/jpeg;base64,…` URI. `Customer.toJson` currently writes that whole
blob into SharedPreferences on every session save and `operator==`
string-compares it on every auth rebuild.

> **BLOCKED — the `/logout` 200 body** and the plan's claim (§243) that it
> revokes **all** tokens. Nothing establishes this. *To unblock: a valid bearer
> plus a second token to test revocation against.*
>
> **BLOCKED — whether a valid bearer still requires `X-API-KEY` on `/me` and
> `/logout`.** The middleware order means a bad token always masks the api-key
> check. *To unblock: a valid bearer, then repeat with the key removed.*

---

## 7. Family: Coupons

Both endpoints are `POST`, **`X-API-KEY` only** — a bogus bearer is ignored, so
they are anonymous-capable.

**🔴 Read §7.4 before implementing either one.**

### 7.1 `POST /ecommerce/coupon/apply`

**Request** — JSON, form-encoded, or `cart_id` as a query param:

| Field | Rules |
|---|---|
| `coupon_code` | required, **min 3, max 20** (undocumented) |
| `cart_id` | **REQUIRED — undocumented in the plan doc.** No UUID-format and **no existence validation**: `"x"`, `"zz"`, `"not-a-uuid"` are all accepted and echoed back. |

Cart id in the **path** is not supported (404).

**Success (200)** — envelope **A**, `data` has exactly **18 keys**:
`cart_items, count, raw_sub_total(+_formatted), raw_total(+_formatted),
promotion_discount_amount(+_formatted), coupon_discount_amount(+_formatted),
applied_coupon_code, discounted_sub_total(+_formatted),
discounted_tax_amount(+_formatted), order_total(+_formatted), cart_id`.

Three surprises:

1. **`cart_items` is a MAP keyed by rowId when non-empty, and a bare ARRAY `[]` when empty.** A Dart `as Map` cast crashes on empty carts.
2. **Item values use the raw `Cart::content` shape** — `{rowId, id, name, qty, price, options{}, tax, subtotal, updated_at}`. **Not** the enriched `GET /cart` shape: missing `row_id`, `quantity`, `image_url`, `image`, `price_formatted`, `subtotal_formatted`, `total_price`, `tax_rate`, `cart_options`, `option_values`, dimensions, `product_type`, `description`.
3. **`data` is a REDUCED cart** vs `GET /ecommerce/cart` — missing `id`, `content`, `package_dimensions`, `status`, `total_weight/height/wide/length/volume`; adds `cart_id`.

**⇒ You cannot re-render a cart screen from a coupon response. Re-`GET
/ecommerce/cart/{id}` after every coupon call.**

**Errors**

| Status | Body | Trigger |
|---|---|---|
| **200** | `{"error":true,"data":null,"message":"This coupon is invalid or expired!"}` | invalid/unknown coupon. **NOT 4xx — do not branch on status code.** Verified for FRESH10, ORGANIC15, WELCOME50 and three control fakes. |
| 422 | envelope **F**, `errors:{coupon_code, cart_id}` | missing both |
| 422 | `The cart id field is required.` | missing `cart_id` |
| 422 | `The coupon code field is required.` / `must be at least 3 characters.` / `must not be greater than 20 characters.` | `coupon_code` violations |
| 401 | envelope **G** | no/bad key (returns JSON even without `Accept`) |
| 404 | bare `{message}` | GET instead of POST; cart id in path |
| **200** | `{"error":false, …, "message":"Applied coupon \"<anything>\" successfully!"}` with `cart_items:[]`, `count:0`, all totals 0, `applied_coupon_code:null` | **FALSE SUCCESS** on an empty or nonexistent cart. Verified with `00000000-…`, `not-a-uuid`, `zz`. |

**⇒ Never treat `error:false` as proof a coupon is real. Require
`coupon_discount_amount > 0` AND `applied_coupon_code != null`.**

### 7.2 `POST /ecommerce/coupon/remove`

**Request**: you must send **BOTH `cart_id` AND `coupon_code`**. `coupon_code`
on remove is entirely undocumented — the plan shows remove taking no body.
There is **no 422 validation** on this route; omitting fields yields a 200
business error instead. The code is **not** checked against what is actually
applied — an arbitrary string still returns "Removed coupon code successfully!".

**Success `data` is byte-for-byte the same 18-key set as apply** (verified
programmatically), with the same map/array and reduced-shape surprises.
`applied_coupon_code` is `null` afterwards.

**Errors** — all HTTP **200**:

| Body | Trigger | Cart destroyed? |
|---|---|---|
| `{"error":true,"data":null,"message":"No coupon code found"}` | `cart_id` present, `coupon_code` missing | **YES** (verified: count 2 → 0) |
| `{"error":true,"data":null,"message":"Cart is empty"}` | empty body `{}`, or `coupon_code` without `cart_id`, or an already-emptied cart | — |
| envelope **G**, 401 | no `X-API-KEY` | — |

**PRACTICAL RULE: always send `coupon_code` on remove, even a placeholder, or
you will delete the user's cart.**

### 7.3 The tax direction — M1 restated

Live evidence that GST is **added on top**, not included:

| Source | Numbers |
|---|---|
| `cart_get` | `raw_sub_total` 1798 → `discounted_tax_amount` 89.90 → `order_total` **1887.90** |
| checkout `financial_summary` | `{subtotal 1798, tax_amount 89.90, shipping_amount 0, total 1887.90}` — the `0` here is **not** evidence that mobile ships free: this is the checkout **GET** (`process`), which never prices shipping at all. Shipping is priced on the POST, from `shipping_option` (§4.5) |
| `checkout/taxes/calculate` | `{sub_total 42289, tax_amount 2114.45, total 44403.45}` |

**Client status: fixed — the description below is of code that no longer
exists, kept because the server-side observation still stands.** The app used to
compute `gstIncluded = subtotal - subtotal/(1+0.05)`, exclude it from `payable`,
and label the row **"GST (incl.)"**. All three are gone. Today
`order_pricing.dart:165` reads `gstIncluded: cart.discountedTax.amount`
verbatim off the cart, `payable` is `order_total + delivery`, and both
`cart_screen.dart:432` and `checkout_screen.dart:965` render a plain **"GST"**
row. The field name remains a misnomer — see `KNOWN_ISSUES.md`.

The server-side point is unchanged and still matters: `tax_rate` comes back
**per line item** (`taxClasses:{gst:5}`), so any client that hardcodes a single
rate is silently wrong for a mixed-rate cart. The app no longer derives tax at
all, which is what makes it immune.

### 7.4 🔴 CRITICAL DEFECT — failed coupon calls destroy the cart

**Verified**: cart `b018284b-…` created with product 119 × 3 → `GET` shows
`count: 3` → `POST apply {coupon_code:"NOPE123"}` → *"This coupon is invalid or
expired!"* → `GET` shows `count: 0`, `raw_total: 0`.

- **Control**: three consecutive `GET`s on a separate cart returned `count: 1` each time — `GET` is not the cause.
- **Reproduced on 8+ separate carts**, on **both** apply and remove failure paths.
- **The `remove` success path is the only non-destructive coupon call found** (count 2 before and after, twice).
- Likely mechanism (**INFERRED, not verified**): `Cart::restore($id)` deletes the stored DB row after loading it into session, and the controller returns early on the error path without re-storing.
- **This is why a naive retry "looks like it worked"**: on a fresh cart the first apply rejects the code and empties the cart; a second identical apply then returns "successfully" — because the now-empty cart hits the false-success path in §7.1.

**Client mitigation until the backend fixes it**: never adopt a cart body
returned alongside `error:true`, and re-`GET` the cart after every coupon call
so the destruction is at least *visible* rather than silent.

### 7.5 Blocked and not-applicable

> **BLOCKED — the shape of a genuinely SUCCESSFUL coupon application**
> (`coupon_discount_amount > 0`, `applied_coupon_code` non-null,
> `discounted_sub_total < raw_sub_total`). No valid coupon code is known on dev
> and there is **no API to discover one**: `/ecommerce/coupons`, `/coupon`,
> `/discounts`, `/promotions` all 404. Every success response captured came
> from an **empty** cart, so all money fields were 0. *To unblock: an admin
> creates a test discount (Ecommerce → Discounts, type Coupon, e.g. 10% off, no
> min-order) and shares the code — one apply call then confirms the shape.*
>
> **BLOCKED — whether apply's SUCCESS path preserves a NON-EMPTY cart.**
> `remove`-success provably does, and the two share an identical 18-key
> response, but apply-success was only ever observed on empty carts. **This
> matters**: if apply-success is also non-destructive the bug is confined to
> failure paths; if not, coupons are unusable entirely. Same unblock as above.
>
> **BLOCKED — per-customer coupon rules** (usage limits, first-order-only,
> "already used"). Needs a bearer token.
>
> **NOT APPLICABLE — pagination.** Neither route is a collection.
> `?per_page=1000&page=2` changed nothing.

---

## 8. Family: Notifications + Device Tokens

**13 live, working routes** — the plan doc's "unused infrastructure, no methods"
(P4) is wrong. All verified with a real customer bearer (customer 16) against
the deployed source at `trueway_ecom/vendor/botble/api`, which matches the live
route table verb-for-verb.

**The data is empty, not the code**: `stats` returns `total: 0` backend-wide and
the probe's `device_tokens` row was created as **id 1**, proving push has never
been used on this deployment.

### 8.1 `GET /api/v1/notifications` — 🔴 the app-breaking one

**Auth**: bearer **required** (X-API-KEY alone is not sufficient).

**Query** — all optional, **none validated**: `page` (default 1, **not clamped**
— `page=5` against `last_page=1` returns 200 + empty list), `per_page` (default
20, **hard cap 50**), `unread_only` (Laravel `boolean()`), **`type`**
(undocumented in the app — filters on the parent notification's type).

**Envelope E** — `data` is an **OBJECT**, not an array:

```jsonc
{"error": false,
 "data": {
   "notifications": [ … ],
   "pagination": {"current_page": 1, "last_page": 1, "per_page": 20,
                  "total": 0, "has_more": false},
   "unread_count": 0 },
 "message": null}
```

`pagination` is **nested inside `data`** and is **not** the standard
`links`/`meta` envelope — it uses `has_more` rather than making you compare
`current_page < last_page`.

**⇒ `unwrapList` (`api_response.dart:9-13`) gets a Map, fails the `data is List`
test, and returns `const []` — SILENTLY. `NotificationsScreen` renders "Nothing
new" forever, for every customer, with no error and no crash.**
Read `data['notifications']`, `data['pagination']`, `data['unread_count']`.

**`per_page` edge cases** (the cap is `min($input, 20→50)`, unvalidated):
`per_page=1000` → 50. **`per_page=abc` → 50**, not the 20 default (PHP
string-compares `"abc"` vs `"50"`). `per_page=0` → 15 (Laravel's internal
default). **`per_page=-1` echoes -1 — do not send it; behaviour with real rows
is UNVERIFIED and Laravel's paginator may throw.**

> **UNVERIFIED — the per-item object.** The field list below is transcribed
> verbatim from the controller's transform array
> (`vendor/botble/api/src/Http/Controllers/NotificationController.php:56-75`).
> It is unambiguous but **source-derived, not captured**, because zero
> notifications exist backend-wide. *To unblock: an admin sends one test push
> from Settings → API → Send Notification to the customer whose bearer you hold,
> then re-run this GET.*

`{id, notification_id, title, message, type, action_url, image_url, data,
is_read, is_clicked, sent_at, read_at, clicked_at, created_at}`

- **`id` is the `push_notification_recipients` row id** — this is the id every read/clicked/delete route takes, **not** `notification_id`.
- `is_read`/`is_clicked` are computed from `read_at`/`clicked_at != null`.
- **`data` is a json column with an Eloquent `array` cast — it can deserialise as either a Dart `Map` or a `List`.** Given the `cart_items` trap already found elsewhere in this API, **model it as `dynamic`** until a real payload is seen.
- `created_at` is UTC ISO8601 — call `.toLocal()`.

**Errors**: two incompatible 401s (§1.4). **302 → HTML login page** without
`Accept: application/json`. Wrong verb → **404**, not 405.

### 8.2 `GET /api/v1/notifications/stats`

**Auth**: bearer. No params. Envelope **A**:
`{"error":false,"data":{"total":0,"unread":0,"read":0,"clicked":0},"message":null}`.

**Four counters, not two.** `NotificationStats` models only `total` and
`unread`; `read` and `clicked` are free and currently discarded. This is the
**one endpoint in the family the app parses correctly** (it uses `unwrapObject`).

### 8.3 Notification mutations

| Route | Method | Success body | Notes |
|---|---|---|---|
| `/notifications/mark-all-read` | POST | `{error:false, data:{marked_count:int}, message:"Marked {n} notifications as read"}` | Bulk UPDATE — does **not** fire per-row `markAsRead()`, so it does not increment the parent's `read_count`. Harmless to the app. |
| `/notifications/{id}/read` | POST | `{error:false, data:null, message:"Notification marked as read"}` **(source-derived)** | `{id}` must be **numeric** and is the **recipient row id**. Idempotent. |
| `/notifications/{id}/clicked` | POST | `{error:false, data:null, message:"Notification marked as clicked"}` **(source-derived)** | **⚠️ Spelling is `/clicked`, not `/click`.** **Completely absent from the app** — no constant, no method. It is the *correct* call for the tap handler, because `markAsClicked()` sets `clicked_at` **and cascades to `markAsRead()`**. |
| `/notifications/{id}` | DELETE | `{error:false, data:null, message:"Notification deleted successfully"}` **(source-derived)** | Deletes only the recipient row, not the parent. |

`data` is **`null`** on all of these — do not try to parse a notification back out.

**Scoping**: `forUser('customer', <bearer id>)`. Another customer's id yields
**404, not 403**: `{"error":true,"data":null,"message":"Notification not found"}`
(**LIVE VERIFIED**). A non-numeric id yields a *different* 404 body:
bare `{"message":"The route … could not be found."}`.

**⛔ `GET /api/v1/notifications/{id}` DOES NOT EXIST.** `/notifications/{id}`
routes **DELETE only**. There is no single-notification fetch; the list is the
only read path. (The app is already correct here.)

**Dead code note**: every controller contains an `if (!$user) return
setMessage('Unauthorized')->setCode(401)` branch, but the `auth:sanctum`
middleware intercepts first, so the message is always **`Unauthenticated.`**
Do not string-match on "Unauthorized" for auth failures on these routes.

### 8.4 `POST /api/v1/device-tokens` — public, and an IDOR

**Auth**: **`X-API-KEY` only.** Declared outside the sanctum group
(`vendor/botble/api/routes/api.php`, comment `// Device token management (public
endpoints)`). **A bearer is accepted but completely IGNORED** — the controller
never calls `$request->user()`.

| Field | Rules |
|---|---|
| `token` | **required**, string, max 255 — the FCM registration token |
| `platform` | nullable, `in:android,ios` — **lowercase only** (`web` and `ANDROID` both 422) |
| `app_version` | nullable, max 50 |
| `device_id` | nullable, max 255 |
| `user_type` | nullable, max 50 — **must be the literal `"customer"`** |
| `user_id` | nullable, integer, min 1 — **the customer id from `GET /me`** |

**🔴 CRITICAL UNDOCUMENTED REQUIREMENT**: ownership is **entirely
client-declared**. Omit `user_type`/`user_id` and the row is stored with NULLs
and **can never be targeted by a per-customer push** — push silently never
works. This is simultaneously the requirement that makes push work **and** an
IDOR (§1.7 item 1).

Unknown keys (`device_type`, `os_version`, `device_name`, `fcm_token`,
`customer_id`, `id`) are silently dropped.

**Success — HTTP 200, not 201**, envelope **A**:
`data = {id, token, platform, is_active(always true), created_at, updated_at}`.
**It deliberately does NOT echo `app_version`, `device_id`, `user_type` or
`user_id`** even though they are stored — you cannot confirm the association
from this response, only via `GET /device-tokens`.

**UPSERT keyed on the unique `token` column**: re-POSTing returns the same row
id and bumps `updated_at`/`last_used_at`. On update each optional field uses
`$data[k] ?? $existing`, so **sending `platform:null` does NOT clear it**
(verified live). `is_active` is forced true on every store, so this call also
**silently reactivates a previously deactivated token**.

**Errors** — envelope **F**, with **custom** messages: `Device token is
required` / `must be a string` / `must not exceed 255 characters`; `Platform
must be either android or ios`; `User ID must be greater than 0` / `must be an
integer`; `User type must not exceed 50 characters`; `App version must not
exceed 50 characters`; `Device ID must not exceed 255 characters` — **all
verified live**. Multi-error `message` is the first error plus `(and N more
errors)`. 401 → envelope **G**. Wrong verb → 404.
**Source-only, not triggered**: `500 {error:true, data:null, message:"Failed to
register device token: <exception>"}` — leaks the raw exception text.

### 8.5 Device-token read/update/delete

| Route | Method | Auth | Notes |
|---|---|---|---|
| `/device-tokens` | GET | **bearer** | Envelope **A**, `data` a **bare ARRAY with NO pagination** at all. Scoped to `customer`+bearer id, filtered `is_active=true`, ordered `last_used_at desc`. Item: `{id, token, platform, app_version, device_id, last_used_at, created_at}` — **no `is_active`, no `updated_at`, no `user_type`/`user_id`**. Empty = real `[]`. **This is the only way to confirm a push registration actually bound to the signed-in customer.** |
| `/device-tokens/{id}` | PUT | bearer | Reads **only** `platform`, `app_version`, `device_id`. `token` and `is_active` in the body are **silently ignored** (a `HIJACK_ATTEMPT` token was rejected). **NO VALIDATION AT ALL** — `platform:"ZZZ_NOT_A_PLATFORM"` was accepted and persisted, unlike POST. Response field set **differs from the GET index**: adds `is_active` and `updated_at`, **drops `created_at`** — do not share one model class without making `created_at` nullable. **In practice you never need PUT** — re-POSTing is a simpler upsert that also refreshes `last_used_at` *and* validates `platform`. |
| `/device-tokens/{id}` | DELETE | bearer | `{error:false, data:null, message:"Device token deleted successfully"}`. Awkward for mobile: the app knows its FCM token string, not the server row id. |
| `/device-tokens/by-token` | DELETE | bearer | **Use this instead.** Body `{token: "<fcm token>"}` — a **DELETE with a JSON body** (Dio supports it; some stacks strip it). Matched before `/{id}` because `{id}` is numeric-constrained. **This is the correct sign-out hook**: on logout, delete by token so the device stops receiving the previous customer's pushes. 422 here uses **default Laravel wording** (`The token field is required.`), unlike POST's custom messages. |
| `/device-tokens/{id}/deactivate` | POST | bearer | `{error:false, data:null, message:"Device token deactivated successfully"}`. **Verified end-to-end**: afterwards `GET` no longer lists it and `PUT` 404s (update applies the `active()` scope; destroy and deactivate do not) — but **DELETE still works**. **Deactivation is NOT durable**: any subsequent POST with the same token forces `is_active` back to true. A weak "mute" at best. |

All 404-on-not-owned: `{"error":true,"data":null,"message":"Device token not
found"}` (**LIVE VERIFIED**). Non-numeric id → bare `{message}` route-not-found.

> **BLOCKED — is FCM actually configured on this deployment?**
> `PushNotificationService` reads `setting('fcm_project_id')` and
> `setting('fcm_service_account_path')`, which are admin-panel settings not
> readable over the API. **If unset, registering device tokens is inert and no
> push will ever be delivered regardless of a correct app integration.**
> *To unblock: check Admin → Settings → API.*
>
> **UNVERIFIED — multi-page `data.pagination`** (`last_page > 1`,
> `has_more:true`). Only a single empty page ever existed.

---

## 9. Consolidated blocked / unverified register

Nothing below can be implemented honestly today. **Do not guess field names or
ship UI that depends on these.**

| # | What | Why blocked | To unblock |
|---|---|---|---|
| B1 | `POST /ecommerce/reviews` body + 422 contract | Sanctum runs before validation; no bearer obtainable without a real SMS | A test-customer bearer, **or** the `ReviewRequest`/`ReviewController` `rules()` source |
| B2 | `GET`/`DELETE /ecommerce/reviews` authenticated shapes; `data.user_review`, `has_reviewed:true` | Same | Same |
| B3 | A genuinely successful coupon application (non-zero discount) | No valid code exists on dev; no API to discover one (4× 404) | Admin creates a test discount and shares the code |
| B4 | Whether apply-success preserves a **non-empty** cart | Only ever observed on empty carts | Same as B3 |
| B5 | OTP send/verify/resend **success** payloads; `expires_in`; the "not enabled" wording | Requires dispatching a real SMS at real cost | A team-owned consenting registered phone, **or** read-only `OtpController.php` |
| B6 | `/register`, `/login`, `/me`, `/logout` **2xx** bodies | No test customer; creating one was out of scope | A disposable dev test customer's credentials, or a pasted payload |
| B7 | ~~`pickup_postcode` for `check-serviceability`~~ **DOWNGRADED — not blocked.** Derived as **311001** from 62 real orders and readable live at `cart_options.store.zip_code`; 14 of 18 reconstructible orders explained (§4.5) | Still no settings route (8× 404), so the last ~5 % is unclosed | One SQL read of the `ecommerce_store_zip_code` settings row (§4.5), or Admin → Ecommerce → Settings → General |
| B8 | ~~Multi-item parcel aggregation rule~~ **CLOSED.** The server does it: `GET /ecommerce/cart/{id}` returns `package_dimensions` + `total_weight` (§4.2) | — | — |
| B9 | ~~Whether `shipping_charge` is the amount actually billed~~ **CLOSED — it is not.** check-pincode prices from 110001, checkout from 311001 (§4.4) | — | — |
| B10 | Populated `/cross-sale` item shape | All 4 products return `[]` | Add one cross-sale relation in admin |
| B11 | Reviews `per_page` cap and default | Only 3 reviews exist across 4 products | Seed >100 reviews, or read the `paginate()` default |
| B12 | Categories list `per_page` cap | Only 21 rows exist — cannot distinguish "no cap" from "cap > 21". **Do not record "no cap" as a contract.** | A >1000-row table, or backend confirms the controller |
| B13 | Descendant aggregation **depth** (grandchildren) and reproducibility on a second branch | Tree is 2 levels; only branch 17→40 has products | Backend creates a 3-level chain and assigns a product under a child of 18/21/22 |
| B14 | Notification item shape (source-derived only); the runtime type of `data` | Zero notifications exist backend-wide | Admin sends one test push to the bearer's customer |
| B15 | Whether FCM is configured at all | Admin-panel settings not API-readable | Check Admin → Settings → API |
| B16 | Product 118's category assignment | No product→categories mapping exists in the API | Backend confirms in admin, or adds `categories` to the product resource |
| B17 | The trigger for `check-pincode`'s "Service temporarily unavailable" | Not reproducible in 12+40 probes | Backend greps the plugin / shares the error log |
| B18 | Whether a bearer changes any response in the **categories** family | No customer token held during that run | A test-customer bearer |
| B19 | `POST /ecommerce/checkout/place-order` — exists or not | The two verified docs disagree (§1.3) | Re-probe both paths with one bearer |

---

## 10. Open items for the backend team

**Defects to fix**

1. **Coupon apply/remove failure paths destroy the cart** (§7.4) — the highest-severity server bug found. Blocks shipping any coupon UI.
2. **`POST /device-tokens` IDOR** (§1.7 item 1).
3. **500s on unvalidated pagination input** — `reviews?per_page=-1`, `product-categories?per_page=abc`.
4. **`/products/{slug}/reviews` serves `status:"pending"` reviews to anonymous callers** (§3.3), which makes the review count disagree with the product header.
5. **`/ecommerce/brands/{id}/products` does not filter** (§2.5).
6. **404 leaks the Eloquent model class name** (§2.4).
7. **No throttling** on `/otp/send` (SMS-bombing / cost), `/login`, `/email/check`, `/password/forgot`.
8. **`/email/check` discloses the customer's full name** (§6.3).
9. **`/products/{slug}/reviews` re-encodes a base64 avatar per request** (§3.3) — uncacheable, ~4 KB per review, non-deterministic bodies.

**Missing capabilities the app needs**

10. **A stable machine-readable `code` field on error bodies** (§5.4) — the app is currently forced to string-match English prose.
11. **Pagination metadata on `/products/{slug}/reviews`** — the total count exists only inside a localized English sentence.
12. **A star-count / rating breakdown** — does not exist anywhere; a histogram currently needs 5 calls plus regex.
13. **A route to complete a password reset** (§6.4) — the flow cannot finish in-app.
14. **The store's `pickup_postcode` in a public settings endpoint** (B7). The
    app now derives it (**311001**, §4.5) and reads the live origin off
    `cart_options.store.zip_code`, so this is no longer blocking — but the
    derivation carries 4 unexplained orders out of 18 and would go away entirely
    if `store_zip_code` came back on the cart response next to
    `package_dimensions`. **The narrow ask:** what is
    `ecommerce_store_zip_code` in the `settings` table on dev and on production?
15. **`shipping_option` on `OrderResource` / `OrderDetailResource`** — the field
    the order was priced by is not returned, so mobile-priced and web-priced
    orders cannot be told apart during rollout (`BACKEND_BUGS.md` finding 12).
16. **A loud failure when `(shipping_method, shipping_option)` does not resolve.**
    The web throws; the mobile API writes `shipping_amount = 0.00` and reports
    success (§4.5, `BACKEND_BUGS.md` finding 9). Silent zero is the dangerous
    behaviour.
17. **Align `/logistics/check-pincode` with checkout's origin**, or drop its
    `shipping_charge`. Today the two price from different warehouses (§4.4).
18. **`categories` on the product resource** — there is no product→category mapping anywhere (B16).
19. **A way to discover valid coupon codes**, or at least one seeded test coupon on dev (B3).
20. **Confirm `fast2sms_otp_login` on PRODUCTION** — only dev was probed.
21. **A disposable test customer** (phone + email + password + a pre-issued bearer). This single item unblocks B1, B2, B5, B6, B14 and B18 — **six of the nineteen blockers.**

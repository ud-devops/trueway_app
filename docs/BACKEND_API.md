# Backend & API

## Backend

- **Server:** `https://dev.truewayerp.com` — a **Botble** e-commerce platform on
  **Laravel** (this is the "truewayerp" ERP/storefront). `dev.` is the staging
  host; production is expected at `truewayerp.com` (confirm with the backend team).
- **API base:** `/api/v1`
- **Auth header:** every request sends **`X-API-KEY: <key>`**.
  - Dev key: `<API_KEY>` — ask the backend team, or read it out of your own
    build's `--dart-define`. It is deliberately **not** written down here.
  - ⚠️ There is exactly **one** key and every install shares it. It is currently
    a **dev fallback compiled into `AppConfig.apiKey`**, so it is trivially
    extractable from any shipped APK — and because it is global, extracting it
    from one device compromises it for every device. For production, inject it
    via `--dart-define=API_KEY=...` and ideally proxy through a thin server so
    the mobile binary never carries it. See [KNOWN_ISSUES.md](KNOWN_ISSUES.md).
- **Images:** served from `${origin}/storage/...`. `AppConfig.resolveImage()`
  turns relative paths into absolute URLs.
- **CORS:** the API returns `Access-Control-Allow-Origin: *` (handy for web dev).

All of these live in
[`lib/core/config/app_config.dart`](../lib/core/config/app_config.dart) and
[`lib/core/network/`](../lib/core/network/).

## Confirmed public endpoints (implemented)

| Method | Path | Used by | Notes |
|---|---|---|---|
| GET | `/simple-sliders` | `slidersProvider` | Home banner carousels (`data[].items[]`) |
| GET | `/ads` | `adsProvider` | Home ad banners |
| GET | `/ecommerce/products` | products/home/search | **Laravel-paginated** (`data`,`links`,`meta`); params: `page`, `per_page`, `search`, `sort` (`price_asc`/`price_desc`/`name_asc`/`date_desc`), category/brand filters |
| GET | `/ecommerce/products/{slug}` | product detail (deep link) | Single product by slug |
| GET | `/ecommerce/brands` | `brandsProvider` | Brand list |
| GET | `/categories` | `categoriesProvider` | ⚠️ **NOT** under `/ecommerce` |

**Real sample responses** are saved in [`../_recovered/api-samples/`](../_recovered/api-samples/)
(`products.json`, `sliders.json`, `ads.json`, `brands.json`, `categories2.json`).
Use them to see exact field shapes; the `data/models/*.dart` `fromJson` methods
mirror them.

### Product shape (abridged, from live data)
```jsonc
{
  "id": 118, "slug": "...", "name": "...", "sku": "TRW3215",
  "price": 943.95, "price_formatted": "₹943.95",
  "original_price": 1199.10, "original_price_formatted": "₹1,199.10",
  "description": "<html spec table>", "content": "<html about>",
  "quantity": 93, "is_out_of_stock": false, "stock_status_label": "In stock",
  "reviews_avg": 5, "reviews_count": 1,
  "images": ["https://.../storage/products/..."], "image_url": "...",
  "image_with_sizes": { "medium": [...], "thumb": [...] },
  "product_options": [],            // ← empty on public API (variants live behind auth?)
  "videos": [], "store": { "id":10, "name":"Trueway Farms", "zip_code":"311001" }
}
```
Prices are inclusive of GST. Discount % = `(original-price)/original`.

### Third-party
- **Pincode autofill:** `https://api.postalpincode.in/pincode/{pin}` (public,
  used on checkout to fill city/state). Not part of the Trueway backend.

## Pending / authenticated endpoints (NOT yet wired)

The paths below are **stubbed by name** in
[`lib/core/network/api_endpoints.dart`](../lib/core/network/api_endpoints.dart)
(inferred from the original app's recovered class names) but the **real
request/response contracts are unknown**. Confirm each against live traffic
before implementing (see [HANDOFF.md](HANDOFF.md) §4).

| Feature | Likely path(s) | Needed for |
|---|---|---|
| Send OTP | `POST /auth/send-otp` | Mobile login |
| Verify OTP | `POST /auth/verify-otp` (returns bearer token) | Mobile login |
| Resend OTP | `POST /auth/resend-otp` | Mobile login |
| Cart sync | `?` | Server-side cart (optional; local cart works today) |
| Place order | `?` `/orders` | Checkout → returns Razorpay order data |
| Order list / track | `?` `/orders`, `/order-status`, `/order-details/{id}` | Orders tab |
| Wishlist | `?` | Wishlist feature |
| Addresses | `?` `/profile/address*` | Address book |
| Coupons (real) | `?` | Replace the demo coupon map |

Once you capture these, add a bearer-token interceptor to `ApiClient` (store the
token from verify-OTP in `SharedPreferences`) and create the matching
repositories (`AuthRepository`, `OrderRepository`, …) following the existing
`CatalogRepository` pattern.

## Payments (Razorpay)

`razorpay_flutter` is a dependency but **not yet imported/used**. Per the original
app's recovered strings, **Razorpay `key_id` + order data come from the
authenticated checkout API response** (they are _not_ hardcoded). So Razorpay
cannot be wired until OTP auth + the place-order endpoint are done:
1. `POST` the order → backend returns `{ razorpay_key_id, razorpay_order_id, amount, ... }`.
2. Open Razorpay checkout with those options.
3. On success, `POST` the `razorpay_payment_id`/`signature` back to confirm.

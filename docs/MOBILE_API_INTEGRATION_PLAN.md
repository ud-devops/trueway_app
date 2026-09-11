# Mobile API Integration Plan

Derived from the backend source at `trueway_ecom` (Botble/Laravel) and verified
live against `https://dev.truewayerp.com/api/v1`.

Every endpoint below was probed. Where behaviour differs from what you'd expect
from the route file, the **live** behaviour wins and is called out.

**Last reviewed against the code: 2026-08-11** — `flutter test` 1672 passing.

---

## 0. Status at a glance

Sections A–J1 are **built and under test**. What remains is release hygiene
(Section K) and a short list of endpoints nobody has needed yet.

| Section | What | Status |
|---|---|---|
| A | Catalogue corrections — categories, filtering, tree | ✅ done |
| B | Home sections — carousels, sliders, ads, flash sales | ✅ done |
| C | Pincode serviceability | ✅ done |
| D | Authentication — OTP + email/password + registration | ✅ done |
| E | Server-side cart | ✅ done, **plus** mirror-and-rebuild recovery |
| F | Server-side coupons | ✅ done |
| G | Addresses | ✅ done |
| H | Checkout + Razorpay | ✅ done — gateway wired, payment verified server-side |
| I | Orders — history, detail, cancel, invoice, **returns UI** | ✅ done |
| J | Wishlist, **reviews (read + write)**, compare | ✅ done |
| J1 | Product variations — picker, pack sheet, variation cart lines | ✅ done |
| J2 | Profile CRUD — details, avatar, password | ✅ done |
| K | Cleanup + release readiness | 🟡 **partly — origin resolved; key + deep links + crash reporting open** |

### What is genuinely left

| # | Item | Where |
|---|---|---|
| 1 | 🟡 **The API key is a live credential in source control.** The *origin* is correct — `dev.truewayerp.com` is the live store, confirmed 2026-08-06 — but `X-API-KEY` is enforced, so the committed key grants production access. Accepted risk; rotate + `--dart-define` when convenient. | §K3 |
| 2 | 🟡 Deep links declared in `go_router` but no Android intent filters, so `/product/:slug` links do not open the app | §K4 |
| 3 | 🟡 Cancellation reasons are DB-driven with no endpoint — the app hardcodes 5 and an admin can change them silently | §K7 |
| 4 | ⬜ Endpoints deliberately not integrated, each with a reason | §1.1 |
| 5 | 🟡 Two client-side workarounds that a backend field would delete | §J1 |
| 6 | 🔴 Backend bug 0 (`Cart::restore()` destroys the cart on any refused mutation) is still open — the app now *recovers* from it, but it is a server fix | docs/BACKEND_BUGS.md |

### Ask the backend team for three fields

Each removes real client complexity rather than adding polish:

| Field | On | Removes |
|---|---|---|
| `parent_id` | cart line | `ServerCartState.variationLines` bookkeeping, and the "tile shows ADD after a restart" gap |
| `is_variable` (or `variations_count`) | `AvailableProductResource` | the two-request catalogue scan that finds variable products |
| — | fix `Cart::restore()` | the entire mirror-and-rebuild subsystem |

Four more, specific to the profile endpoints, are listed at the end of §J2 —
including a `unique` rule on `phone`, without which a mistyped number locks a
customer out of OTP sign-in.

---

## 0.1 The four findings this plan started from — all resolved

| # | Finding | Resolution |
|---|---|---|
| 1 | **The app called the wrong categories endpoint.** `/api/v1/categories` is the **blog** plugin's list and returns 4 junk rows — *Dummy, Yoga, Organic farming, Ecommerce*. Real shop categories live at `/ecommerce/product-categories` (**21 rows**, `parent_id` hierarchy). | ✅ Fixed in Section A. The blog constant is deleted, not just unused. |
| 2 | ~~**`categories[]=` does not filter, even with correct IDs.**~~ **This was wrong.** `ProductCategoryController::products` merges the category *and its children* into the parameter, so `?categories[]=17` returns 0 because 17 is a parent whose products live in its children. Leaf ids filter correctly. | ✅ Category browsing uses the path route either way, and it now carries facet filters — §J3. |
| 3 | **OTP routes are `/api/v1/otp/*`, not `/api/v1/auth/*`.** The app's constants 404'd. | ✅ Fixed in Section D. |
| 4 | ~~**There is no registration endpoint.**~~ **This was wrong** — it came from probing `/register` with GET. `POST /api/v1/register` exists and works. | ✅ Corrected. New users sign up in-app; see §D4. |

Also note: `setting('fast2sms_otp_login')` must be ON in admin or `send` returns
422 *"OTP login is not enabled"*.

---

## 1. Full endpoint inventory

"In app" below means **a screen renders it** — verified by grepping from
`lib/presentation` down to the repository, not just `ApiEndpoints.*` against
`lib/`.

> ⚠ The weaker check bit three times. Returns, review-writing and flash sales
> were each marked ✅ because a *repository* method existed and called the
> endpoint — while **no screen called the repository**, so the feature did not
> exist for a customer. A repository method with no caller is not an
> integration. All three are now genuinely wired.

### Public — no auth
| Endpoint | Method | Status | In app |
|---|---|---|---|
| `/ecommerce/products` | GET | ✅ | ✅ |
| `/ecommerce/products/{slug}` | GET | ✅ | ✅ + variation block |
| `/ecommerce/products/{slug}/related` | GET | ✅ | ✅ "You may also like" |
| `/ecommerce/products/{slug}/cross-sale` | GET | ✅ **empty on this store** | ✅ rail hides itself |
| `/ecommerce/products/{slug}/reviews` | GET | ✅ | ✅ |
| `/ecommerce/product-variation/{id}` | GET | ✅ | ✅ |
| `/ecommerce/product-categories` | GET | ✅ 21 rows | ✅ |
| `/ecommerce/product-categories/{slug}` | GET | ✅ | ⬜ |
| `/ecommerce/product-categories/{id}/products` | GET | ✅ | ✅ the working filter |
| `/ecommerce/brands` | GET | ✅ | ✅ |
| `/ecommerce/brands/{id}/products` | GET | ✅ | ✅ |
| `/ecommerce/filters` | GET | ✅ | ✅ category filter sheet + the variable-product scan |
| `/ecommerce/flash-sales` | GET | ✅ **empty on this store** | ✅ home rail, hidden when empty |
| `/ecommerce/countries` · `/currencies` | GET | ✅ | ⬜ geo uses its own source |
| `/ecommerce/top-products-group` | GET | ✅ | ✅ |
| `/simple-sliders` · `/ads` | GET | ✅ | ✅ |
| `/otp/send` · `/otp/verify` · `/otp/resend` | POST | ✅ | ✅ |
| `/logistics/check-pincode` · `/check-serviceability` | POST | ✅ | ✅ |
| `/ecommerce/cart` (+ `/{id}`) | GET/POST/PUT/DELETE | ✅ | ✅ |
| `/ecommerce/cart/refresh` | POST | ⛔ unreachable | n/a — see §E3 |
| `/ecommerce/coupon/apply` · `/coupon/remove` | POST | ✅ | ✅ |
| `/ecommerce/wishlist/{id}` · `/compare/{id}` | GET/POST/DELETE | ✅ | ✅ |
| `/ecommerce/orders/tracking` | POST | ✅ | ✅ guest tracking |
| `/ecommerce/checkout/taxes/calculate` | POST | ✅ | ⬜ cart already returns tax |

### Authenticated — `Authorization: Bearer <sanctum token>`
| Endpoint | Method | Purpose | In app |
|---|---|---|---|
| `/ecommerce/orders` · `/orders/{id}` | GET | Order history + detail | ✅ |
| `/ecommerce/orders/{id}/cancel` | POST | Cancel | ✅ |
| `/ecommerce/orders/{id}/invoice` | GET | Invoice | ✅ |
| `/ecommerce/orders/{id}/invoice/download` | GET | Invoice PDF | ✅ bytes → share sheet |
| `/ecommerce/orders/{id}/confirm-delivery` | POST | Confirm receipt | ✅ |
| `/ecommerce/addresses` | GET/POST/PUT/DELETE | Address book | ✅ |
| `/ecommerce/reviews` | GET/POST/DELETE | Reviews — my list, write, delete | ✅ |
| `/ecommerce/order-returns` (+ `/upload-media`, `/{id}/resubmit`) | GET/POST | Returns | ✅ |
| `/ecommerce/checkout/cart/{cart_id}` | POST | **Place order** | ✅ |
| `/ecommerce/checkout/confirm-payment` | POST | **Verify Razorpay** | ✅ |
| `/ecommerce/products/{id}/notify-me` (+ `/status`) | POST/GET | Back-in-stock | ✅ |
| `/register` · `/login` · `/me` · `/logout` · `/email/check` · `/password/forgot` | — | Account | ✅ |
| `/me` | PUT | Edit profile | ✅ profile screen — **name + dob only**; email and phone are locked, see §J2 |
| `/update/avatar` | POST | Profile photo (multipart) | ✅ profile screen |
| `/update/password` | PUT | Change password | ✅ change-password screen |
| `/settings` | GET/PUT | User preferences | ⬜ **every key is inert server-side** — §J2 |
| `/notifications` (+ read, stats) · `/device-tokens` | — | Notifications | ✅ list; ⬜ push tokens |

`X-API-KEY` is enforced on everything (401 without it) and is **in addition to**
the bearer token.

⬜ rows are not gaps in the plan — nothing in the product needs them yet. They
are listed so a future feature does not re-probe what has already been probed.

## 1.1 Deliberately **not** integrated, and why

Each of these was probed or read in the backend source and then left alone on
purpose. Recorded so nobody spends an afternoon rediscovering it.

| Endpoint | Why not |
|---|---|
| `POST /ecommerce/checkout/taxes/calculate` | The cart response already carries `discounted_tax_amount`, and checkout already renders it. Calling this would be a **second answer to a question the server has answered**, and the two could disagree. That is the exact class of bug this plan was written to remove. |
| `GET /ecommerce/countries` · `/currencies` · `/currencies/current` | The store is INR-only and ships within India; `countries` returns 2 rows. Address geography comes from the geo repository, which the address form already uses. No consumer. |
| `GET /ecommerce/product-categories/{slug}` | Category browsing is keyed on id via `/product-categories/{id}/products`, which works. A slug lookup would be a second path to the same screen. |
| `GET /ecommerce/brands/{slug}` | Same — `brands` + `brands/{id}/products` already cover it. |
| `POST /device-tokens` | Push notifications need Firebase/FCM: a dependency, a platform config, and a key. That is a product decision, not a wiring task. The in-app notification **list** is integrated; only push delivery is not. |
| `GET /ecommerce/orders/shiprocket-tracking/{id}` | **The route is commented out** in `platform/plugins/ecommerce/routes/api.php:111`. It does not exist to be called. |
| `GET /ecommerce/orders/{id}/invoice` | Returns a link to a **session-guarded** web route; a bearer token gets redirected to the storefront login. `/invoice/download` is used instead. |
| `GET` · `PUT /settings` | Both routes are deployed and work, but **nothing on the server reads what they store.** `notification_enabled` appears in exactly three files — the controller, its FormRequest and `UserResource` — and no push-sending code consults it, so a "Notifications" switch here would mute nothing. `currency`/`language`/`timezone` are single-valued for an INR, India-only, English store; `biometric_enabled` has no implementation on either side; and `theme` is already owned locally by `themeModeProvider`. Wiring any of them would be a control that lies. Revisit if the backend starts honouring `notification_enabled`. |

---

## 2. Ordering of work — *historical; this chain has been walked*

Kept for the dependency reasoning, which still explains why things are shaped the
way they are. Sections were ordered so nothing was ever blocked by something
unbuilt: **A → B → C independent, D onwards a chain.**

```
A. Catalogue corrections   ─┐
B. Home sections            ├─ no auth, no cart  → ship independently
C. Pincode serviceability  ─┘

D. Auth (OTP + token)  →  E. Server cart  →  F. Coupons
                                           →  G. Addresses
                                           →  H. Checkout + Razorpay  →  I. Orders
J. Wishlist / reviews / variants  (after D)
```

---

## SECTION A — Catalogue corrections ✅ DONE

**Highest value, lowest risk. Do this first.** Three live bugs, all in the data layer.

### A1. Point categories at the ecommerce plugin
- `lib/core/network/api_endpoints.dart` — replace
  `categories = '/categories'` with
  `productCategories = '/ecommerce/product-categories'`.
- Add `productsByCategory(int id) => '/ecommerce/product-categories/$id/products'`.
- **Delete the blog `/categories` path entirely** so nobody reaches for it again.

### A2. Rewrite `Category.fromJson`
Product categories carry fields the blog ones don't. Confirm against a live
payload before mapping — at minimum `id`, `name`, `slug`, `parent_id`,
`image`/`image_url`. Add `parentId` to the model.

### A3. Fix category filtering
`CatalogRepository.products(categoryId:)` currently sends `categories[]` — proven
non-functional. Replace with a dedicated call:
```dart
Future<PaginatedResponse<Product>> productsByCategory(int categoryId, {int page = 1, int perPage = 20})
```
hitting `/ecommerce/product-categories/{id}/products`. Route `ProductQuery.categoryId`
through this instead of the products endpoint.

### A4. Category tree
21 categories with `parent_id` (0 = root). The home rail should show **roots
only**; the Categories screen can show root → children. Build the tree in the
repository, not the widget.

### A5. Brand filtering (already correct)
`brands[]=` **is** honoured (real id → 4 results, bogus → 0). Keep it. Optionally
switch to `/ecommerce/brands/{id}/products` for consistency with categories.

### A6. Surface brands in the UI
`brandsProvider` exists and is consumed by no screen. Either add a brand filter
row or delete the provider — don't leave it dangling.

**Acceptance:** every category in the rail returns products; tapping a category
shows a non-empty grid; search returns filtered results (the `q` fix is already in).

---

## SECTION B — Home sections ✅ DONE

`GET /ecommerce/top-products-group` returns four ready-made carousels:
`top_selling` (3), `trending` (4), `recently_added` (4), `top_rated` (2).

1. `HomeSections` model — four `List<Product>` fields, each parsed with the
   existing `Product.fromJson`.
2. `homeSectionsProvider` (FutureProvider), one call.
3. Render as four horizontal carousels on the home screen, replacing/augmenting
   the single "Fresh picks" grid.

Also available and unused: `/ecommerce/flash-sales`, `/ecommerce/filters`.

**Acceptance:** home makes **one** call for all four sections, not four.

### B1 — Flash sales ✅ DONE, against an unobserved shape

The store had never run a sale, so this was source-derived for a while. **A real
sale was configured and captured on 2026-08-11**, and the contract below is now
observed.

```json
{ "id": 3, "name": "…", "end_date": "2026-08-15 20:00:00",
  "expired": false, "products": [ /* AvailableProductResource + pivot */ ] }
```

Three things in that shape are easy to get wrong:

| Field | The trap |
|---|---|
| `sale_percent` | **Not a discount.** It is `($pivot->sold / $pivot->quantity) * 100` — how much of the allocation has gone. Rendering it as a saving advertises "80% OFF" on a sale that is merely 80% sold out. The card shows it as a progress bar; the *discount* comes from `price` vs `original_price`. |
| `price` | `FlashSaleProductResource` **overrides** the parent's `price`. It used to publish the **raw pivot**, bypassing `ProductPrice` — so the sale price arrived *tax-exclusive* while every other price in the API is tax-inclusive, showing the customer 5% under what the cart charges. **Fixed on the server 2026-08-11** — see the verification below. |
| `end_date` | `Y-m-d H:i:s` with **no offset**, while `config/app.php` sets `'timezone' => 'UTC'`. Parsed as device-local it would run 5h30m early on an IST phone — the countdown hits zero while the sale is still on. Parsed as UTC, converted to local. |

The endpoint already filters `wherePublished()->notExpired()->started()`, so it
only ever returns running sales; `liveFlashSales()` additionally drops any with
no products, which would render an empty countdown.

`keys[]` filters by **id**, not by slug, despite the parameter name and the
controller's own `["winter-sale"]` example (`whereIn('id', $keys)`).

#### Verifying the tax fix

Captured 2026-08-11 with a live sale on product 118:

| Source | Figure |
|---|---|
| Cart line `price` (ex-tax) — **this is the raw pivot** | `666` |
| `666 × 1.05` (`tax_rate: 5`) | `699.30` |
| Flash endpoint `price` | `699.30` ✅ |
| Catalogue `/products/{slug}` `price` | `699.30` ✅ |
| Cart `order_total` | `699.30` ✅ |

Before the fix the flash endpoint reported `666`. All three now agree, and
`original_price` (`1199.10`) is tax-inclusive too, so the discount badge is
computed from one convention rather than two.

> ⚠ **The fix is on the deployed server but NOT in git.** All nine remote
> branches of `trueway_ecom` still carry `'price' => $pivot->price` (checked
> after `git fetch --all`). A deploy from git would silently revert it and put
> the app back to under-quoting by the tax rate. Ask the backend team to commit
> it. `flash_sale_test.dart → 'the captured payload'` pins the corrected
> figures so a regression fails the suite rather than reaching a customer.

**The price needs no special handling anywhere else.**
`ProductFlashSalePriceService` sits in the `ProductPriceService` pipeline behind
`front_sale_price`, so a product on a live sale reports its **sale price from
every product endpoint** — listing, detail and cart alike. The pivot override in
`FlashSaleProductResource` yields the same figure; it is belt-and-braces, not a
second source of truth. The handler requires `quantity > sold`, so the price
reverts everywhere the moment the allocation is exhausted.

**The rail uses the ordinary `ProductCard`**, with one addition: a stock line
(progress bar + "N left") under the name, and ADD refusing once the allocation
is gone — a *second* stock system on top of `is_out_of_stock`. It was briefly a
bespoke card, which read as a different kind of product sitting among the other
home rails.

**The section draws nothing when there is no sale** — no heading, no skeleton.
Given the live answer is always empty, absent is the common case.

---

## SECTION C — Pincode serviceability ✅ DONE

Replace the third-party `api.postalpincode.in` autofill with the real
serviceability check.

- `POST /logistics/check-pincode` — param is **`pin_code`** (not `pincode`), and
  it also requires product information; confirm the exact payload with the
  backend team before wiring.
- `POST /logistics/check-serviceability` for cart-level checks.

Response: `{success, status, message, deliverable}`. Use `deliverable` to block
checkout for non-serviceable pincodes.

> Keep `postalpincode.in` for city/state **autofill** — the logistics endpoint
> answers "can we deliver", not "what city is this".

---

## SECTION D — Authentication (OTP + email/password) ✅ DONE

> **Status: code complete, awaiting a test customer for end-to-end verification.**
> Contracts were verified against the live API with safe probes (unregistered
> number / missing fields), so no SMS was sent. What has *not* been exercised is
> a real OTP round-trip — that needs a customer record (see D4).
>
> Delivered:
> - `lib/core/network/api_endpoints.dart` — corrected `/otp/*` paths
> - `lib/data/models/customer.dart` — `Customer`, `OtpChallenge`, `AuthSession`
> - `lib/data/repositories/auth_repository.dart` — send/verify/resend/logout/validate
> - `lib/presentation/providers/auth_provider.dart` — `AuthState` + `AuthNotifier`
> - `lib/presentation/screens/auth/mobile_login_screen.dart` — real two-step flow
> - `lib/core/network/api_client.dart` — `onUnauthorized` 401 hook
> - `splash_screen.dart` — session restore on launch
> - `account_screen.dart` / `orders_screen.dart` — auth-aware states
> - 31 unit tests (`test/data/auth_repository_test.dart`, `customer_test.dart`)


### D1. Fix the paths
```dart
static const String sendOtp   = '/otp/send';
static const String verifyOtp = '/otp/verify';
static const String resendOtp = '/otp/resend';
```

### D2. Contracts (exact)
**`POST /otp/send`** → `{ "phone": "9876543210" }`
```json
{ "error": false,
  "data": { "message": "...", "phone": "98******10", "customer_id": 1, "expires_in": 300 },
  "message": "OTP sent successfully" }
```
`customer_id` **must be retained** — verify requires it.
422 → *"Phone number not found!"* (unregistered) or *"OTP login is not enabled."*

**`POST /otp/verify`** → `{ "customer_id": 1, "phone": "...", "otp": "123456" }`
(`otp` must be exactly 6 chars; `customer_id` must exist)
```json
{ "error": false,
  "data": { "token": "1|aF5s7p3…", "customer": { "id", "name", "email", "phone", "avatar" } },
  "message": "Login successful!" }
```

**`POST /otp/resend`** → `{ "customer_id": 1, "phone": "..." }`

OTP expires in **5 minutes**; sending invalidates all previous unused OTPs.

### D3. Flutter work
- `AuthRepository` — `sendOtp`, `verifyOtp`, `resendOtp`.
- `Customer` model.
- `authProvider` (`StateNotifier<AuthState>`): `signedOut | otpSent | authenticated`,
  holding `customerId`, masked phone, and the customer.
- Persist the token via the existing `ApiClient.saveToken` — the bearer
  interceptor is **already written and working**, it just never had a token.
- Replace the fake `_verify` in `mobile_login_screen.dart` (currently accepts any
  6 digits). Add a 5-minute countdown + resend button.
- 401 handling: on `ApiException.isUnauthorized`, clear the token and bounce to login.

### D4. New-user signup ✅ RESOLVED — registration exists

An earlier revision of this doc claimed there was no mobile registration
endpoint. That was wrong: the probe used GET, which this Laravel setup 404s.
The `botble/api` package provides a full auth surface at `/api/v1`, and
`EcommerceServiceProvider` rebinds its model to `Customer` with the `customer`
guard — so these operate on shop customers, the same records the OTP endpoints
resolve by phone.

| Endpoint | Method | Notes |
|---|---|---|
| `/register` | POST | `name` (or `first_name`+`last_name`), `email` (unique, 6–60), `password` (min 6, **`confirmed`** → send `password_confirmation`), `phone` (nullable server-side) |
| `/login` | POST | `email` + `password` → **token only**, no customer |
| `/me` | GET | The authenticated customer |
| `/logout` | GET | Revokes **all** tokens for the customer |
| `/email/check` | POST | `{exists: bool}` — pre-flight for the register form |
| `/password/forgot` | POST | Emails a reset link |
| `/notifications`, `/device-tokens` | — | Push-notification infrastructure, unused |

**Implemented flow:**

```
Phone → /otp/send ──422 "Phone number not found!"──▶ Register screen
                                                          │
                                              POST /register (no token)
                                                          │
                                              POST /login → /me → token
```

Two sign-in methods are live in the app: **phone + OTP** and **email +
password**, switchable on the login screen.

**Watch out for:**
1. `phone` is nullable in `RegisterRequest` but the app always sends it — OTP
   login resolves customers by phone, so a customer registered without one can
   never use the phone flow.
2. **`phone` has no uniqueness rule** (only `email` does). Two customers can
   share a number and `OtpController::send` takes `->first()`. Add a unique
   constraint server-side before launch.
3. `/login` enforces `confirmed_at`; OTP login does **not**. With email
   verification enabled, a new customer can sign in by OTP but not by password.
4. Registration returns no token, so sign-in is always a second call.

**Acceptance:** real OTP arrives by SMS; token persists across restart;
`/ecommerce/orders` returns 200 instead of 401.

---

## SECTION E — Server-side cart ✅ DONE

> **How it shipped.** The local cart is gone — `cart_provider.dart` and
> `CartItem` are deleted, and `ServerCartNotifier` renders only carts the server
> just serialized. Nothing is applied optimistically, every failure is followed
> by a re-read, and money is never computed client-side.
>
> **Beyond the original plan:** because backend finding 0 destroys the cart on
> *any* refused mutation, the app also keeps a **mirror** of every server cart
> on disk (lines + coupon) and replays it into the same cart id after a refusal
> (`CartRepository.rebuild`). The mirror is only ever built from a cart the
> server returned, so it cannot invent a line. `ServerCartState.itemsLost` and
> `recoveryMessage` report the cases where a rebuild could not put everything
> back — a successful rebuild is deliberately invisible, since from the
> customer's side nothing happened.
>
> That subsystem exists solely to survive a server bug and should be **deleted
> the day `Cart::restore()` is fixed**.

*The original brief, kept because the contract below is still the reference:*

The app's cart is local (`SharedPreferences`, `CartNotifier`). The backend has a
full cart with server-computed pricing. **The server must become authoritative** —
otherwise checkout totals and cart totals diverge again, exactly like the coupon
bug already fixed.

### E1. Endpoints
| Action | Call | Body |
|---|---|---|
| Create/add | `POST /ecommerce/cart` | `{product_id, qty}` (+ `options` if required) |
| Add to existing | `POST /ecommerce/cart/{cartId}` | `{product_id, qty}` |
| Update qty | `PUT /ecommerce/cart/{cartId}` | `{product_id, qty}` |
| Remove | `DELETE /ecommerce/cart/{cartId}` | `{product_id}` |
| Fetch | `GET /ecommerce/cart/{cartId}` | — |
| Bulk sync | `POST /ecommerce/cart/refresh` | `{products:[{product_id, quantity}]}` |

`cartId` is a **UUID the server generates on first `POST /cart`**. Persist it in
`SharedPreferences` — losing it loses the cart.

### E2. Response — this replaces your local math
`getDataForResponse()` returns:
`cart_items[]`, `count`, `raw_sub_total`, `raw_total`, `promotion_discount_amount`,
`coupon_discount_amount`, `applied_coupon_code`, `discounted_sub_total`,
`discounted_tax_amount`, `order_total` — each with a `*_formatted` twin — plus
weight/volume and `package_dimensions`.

> **Migrate, don't duplicate.** `OrderSummary` should be built **from this
> response**, not recomputed. Keep the class as the render model, replace
> `OrderSummary.from(...)` with `OrderSummary.fromCartResponse(json)`. Its unit
> tests then cover parsing rather than arithmetic. Server GST/discount handling
> differs from the local approximation — expect totals to shift slightly, and
> treat the server as correct.

### E3. Migration of existing local carts ⚠ the bulk endpoint does not exist

`POST /ecommerce/cart/refresh` is **unreachable**. It is declared *after*
`POST /cart/{id}` and Laravel matches in registration order, so the request binds
`{id} = "refresh"` and creates a cart literally named `refresh`.

Items therefore migrate **one at a time**. `_migrateLegacyLocalCart()` walks the
old `cart_items_v1` key, creating the cart on the first item and adding the rest,
and clears the legacy key in a `finally` — leaving it would re-run the migration
next launch and duplicate whatever got through.

### E4. Errors to handle
`store` returns `error: true` for out-of-stock and *"Maximum quantity is :max!"*.
Surface these instead of optimistically updating.

### E5. Offline
Server cart means no offline mutation. Either queue actions or disable cart
buttons when offline — **decide explicitly**, don't let it fail silently.

**Acceptance:** cart survives restart via `cartId`; totals come only from the
server; out-of-stock is rejected with the server's message.

---

## SECTION F — Server-side coupons ✅ DONE

`POST /ecommerce/coupon/apply` `{coupon_code}` · `POST /ecommerce/coupon/remove`
Both return the **full cart data** — re-render from the response.

Delete `kCoupons` from `core/pricing/order_pricing.dart`. The hardcoded
`FRESH10`/`ORGANIC15`/`WELCOME50` are readable from the APK and applied
client-side; real validation is server-side. Keep the dialog UI, swap the logic.
Show the server's error message for invalid codes.

**Acceptance:** a real admin coupon applies; a fake code is rejected by the
server; `FRESH10` no longer works client-side.

---

## SECTION G — Addresses ✅ DONE

`GET/POST/PUT/DELETE /ecommerce/addresses`.
Fields (from `CheckoutRequest`): `name*`, `email`, `phone`, `address*`, `city*`,
`state`, `district`, `country*`, `zip_code`, `other_city`.

Build an address book screen + picker; replace the free-text checkout form with
"select saved address / add new". Wire the "Saved addresses" tile in
`account_screen.dart` (currently routes to `/login`).

---

## SECTION H — Checkout + Razorpay ✅ DONE

Re-add `razorpay_flutter: ^1.4.5` and the ProGuard keep rules already stubbed in
`android/app/proguard-rules.pro`.

### H1. Place the order
`POST /ecommerce/checkout/cart/{cartId}` (auth) —
```jsonc
{ "address": { "name","address","city","country", /* + optional */ },
  "payment_method": "razorpay",   // or "cod"
  "shipping_amount": 0, "notes": "" }
```
`payment_method` ∈ `cod, razorpay, pay_online, online, credit_card, paypal, bank_transfer`.

Response (Razorpay branch):
```jsonc
{ "success": true, "data": {
    "order_id", "order_token", "order_status", "payment_status",
    "subtotal","tax_amount","shipping_amount","discount_amount","total_amount",
    "is_finished": false,
    "razorpay": { "razorpay_order_id", "razorpay_key_id", "amount" /* paise */, "currency" } } }
```
COD returns the same shape without `razorpay` and is immediately final.

### H2. Pay
Open the Razorpay SDK with `razorpay_key_id`, `razorpay_order_id`, `amount`
(already in paise — **do not multiply again**).

### H3. Verify — mandatory
`POST /ecommerce/checkout/confirm-payment` (auth) —
`{order_id, razorpay_payment_id, razorpay_order_id, razorpay_signature}`.
The server verifies the signature and only then marks the order paid.

> **The order is NOT complete until this returns 200.** Never show the success
> screen on the SDK callback alone. 422 = invalid signature. Handle app-kill
> mid-payment by re-checking order status on next launch.

### H4. Replace the fake
`_placeOrder` in `checkout_screen.dart` currently waits 600 ms and shows success
for an order that does not exist. It must not survive this section.

**Acceptance:** a real order appears in admin; Razorpay test payment completes
and verifies; a tampered signature is rejected; COD works; success screen only
after confirmation.

---

## SECTION I — Orders ✅ DONE

`GET /ecommerce/orders` (list), `/orders/{id}` (detail),
`POST /orders/{id}/cancel`, `/orders/{id}/invoice`, `/orders/{id}/confirm-delivery`.
Public tracking: `POST /ecommerce/orders/tracking`.

### I1 — Returns ✅ DONE

The data layer was built first and sat unused for a while: the repository and
models were complete and correct, but **no screen called them**, so the feature
did not exist for a customer. The UI is now in place —
`return_request_screen.dart`, `returns_screen.dart`, `return_detail_screen.dart`
and `evidence_picker.dart`, behind `/order/:id/return`, `/returns` and
`/returns/:id`.

Everything the backend guide warns about is handled, and each was verified
against `OrderReturnController` rather than taken on trust:

| Trap | Handling |
|---|---|
| Submit **cannot accept files** — it reads `media_images` with `$request->input()`, so attachments are silently dropped | Evidence goes to `/order-returns/upload-media` first; the resulting **URLs** are what the draft carries. Pinned by `return_submit_test.dart`. |
| The upload endpoint takes one `type` per call | Images and videos are two separate calls |
| `is_return` is checked with `isset()` — `0`/`false` still returns the item | Unwanted items are **omitted** from the array; the draft always sends `true` |
| Per-item media keys are `media_images`/`media_videos` | Correct keys; `images`/`videos` would be ignored |
| Resubmit identifies items by a `return_item_id` **field**, not the array key | `ReturnResubmitItemDraft.returnItemId`, from `items[].id` — not `order_item_id` |
| Partial return is on, so per-item `reason` **and** `qty` are required | The form demands both before it will submit |
| `customer_comment` min 50 | Enforced client-side, with a live character count, so the customer is not told to rewrite after a round trip |
| — | **Evidence is required by this shop, not by the API.** `OrderReturnRequest` has no media rules at all; a photo-less return validates server-side. `_hasEvidence` on the form is a deliberate business rule and is the one line to relax if that policy changes. |
| `return_reasons[].label` is `""` for every row | Labels are the app's, matching the server's own wording; unknown tokens are humanised rather than shown as slugs |
| `product_image` is a raw storage path | Prefixed via `resolveOrderMedia` |
| The submit response has **no relations** — `items`, `latest_history`, `admin_feedback` are absent keys | The screen re-reads `GET /order-returns/{id}` instead of parsing the submit response |

**Not built, because the API cannot support it:** there is no `progress` object
and no `histories` timeline (`latest_history` alone carries no description and no
reason), and the return's own `code` is never serialised. The screen shows a
status pill and identifies the request by its **order** code. `admin_feedback` is
populated only while the status is `resubmit`, so a *canceled* return genuinely
cannot tell the customer why — a backend gap, recorded in the asks below.

**New dependency:** `image_picker`, needed because evidence upload wants real
file paths off the device. Gallery picking needs no Android permission (it uses
the system photo picker) and there is no `ios/` target in this project.

---

## SECTION J — Wishlist, reviews, compare ✅ DONE

- **Wishlist** — `GET/POST/DELETE /ecommerce/wishlist/{id}`, same UUID-identifier
  pattern as cart. The heart icon on `ProductCard` is currently decorative.
- **Reviews** — `GET /ecommerce/products/{slug}/reviews` (public),
  `GET/POST/DELETE /ecommerce/reviews` (auth). See §J2.
- **Variants** — see the verified contract below. `ProductOption` and
  `ProductOptionValue` are already parsed and rendered nowhere, and they are
  **not** the variation mechanism. Note `POST /cart` **requires** `options`
  when a product has required options.

### J2 — Reviews, read *and* write ✅ DONE

The read path shipped long ago; the **write path was the same shape of gap as
returns** — `create`, `myReviews` and `delete` existed on the repository and
nothing called them. Now wired: `write_review_screen.dart`,
`my_reviews_screen.dart`, and the providers in `review_provider.dart`, behind
`/product/:id/review` and `/reviews`.

**Media travels differently from returns, and this is the thing to keep
straight.** `ReviewController` reads uploads from `$request->file()`, so files go
**with** the create call as multipart — there is no upload-first step and no
separate media endpoint. `POST /order-returns` is the opposite. The repository
already switched body types correctly; the test pins that no upload call is made.

Rules taken from `API\ReviewRequest`, which is **stricter than the return
validator on every axis**:

| | Reviews | Returns |
|---|---|---|
| images | max 6, 2 MB, `jpg,jpeg,png` | max 10, 5 MB, `jpg,jpeg,png,webp` |
| videos | max 2, 10 MB, `mp4,mov`, **≤30 s** | max 10, 50 MB, `mp4,mov,avi,webm` |

`EvidencePicker` therefore takes an `EvidenceLimits` rather than owning
constants — quoting the wrong limit sends a customer to resize a photo that was
never too big. The 30-second cap is `MaxVideoDurationRule` and cannot be checked
client-side without a decoder, so it is **stated** in the UI and left to the
server.

Two comment rules are regex-based and enforced client-side, because neither is
guessable from a status code: `not_regex:/<[^>]*>/i` rejects anything resembling
an HTML tag (so `I paid <10 for this> pack` fails), and
`not_regex:/[\x{0400}-\x{04FF}]/u` blocks Cyrillic as spam.

#### The "To review" tab has no endpoint behind it

`ReviewController` exposes `index`, `store` and `destroy` — **nothing answers
"what could I review?"**. So the tab is assembled client-side:

1. every review this customer has written (`per_page=100`, not paged — paging
   would leave something reviewed long ago still showing as "to review");
2. their **completed** orders;
3. **one detail call per order**, because an order list row carries
   `products_count` and image URLs but *no product ids*.

Step 3 is the cost: N requests for N orders, capped at 10. Degrades rather than
fails — if the reviewed lookup breaks the tab over-offers (the server refuses a
duplicate with its own message), and one unreadable order does not lose the
others.

**Two backend changes would collapse this into one call:** a
`reviewable-products` endpoint, or simply `product_id` on the order list row.

**No purchase is required** — `ReviewRequest` only checks the product exists —
so "Write a review" appears on every product, not just bought ones. Reviews are
created as `pending`, so the success message says "awaiting approval" rather
than implying it is live, and `my_reviews_screen` badges pending rows.

---

## SECTION J1 — Product variations ✅ DONE

The backend team supplied a written guide for this. It describes the flow
correctly but gives no field names, and the two endpoints do **not** share a
serializer — so building from the prose alone produces wrong prices. What
follows was captured live on 2026-08-03 against `dev.truewayerp.com` and checked
against `ProductController@show` / `@getProductVariation`.

### Live state

Two of the four catalogue products are variable, both on one attribute set:

```
Pack Size (set 6, display_layout "price-box")
  21  1.85 KG (Pack of 1)   ₹493.50   was ₹571.20    1850 g
  22  5 KG (Pack of 1)      ₹921.50   was ₹1,296.75  5000 g   ← default
  23  5 KG (Pack of 2)      ₹921.50   was ₹1,296.75  5000 g
```

### `GET /ecommerce/products/{slug}` — extra top-level keys

Alongside `data`, the envelope carries four siblings (not nested under `data`):

| Key | Contents |
|---|---|
| `default_product_variation` | `id, sku, quantity, is_out_of_stock, stock_status_label, price, price_formatted, original_price, original_price_formatted, image_with_sizes, weight, height, wide, length, image_url` |
| `attribute_sets[]` | `id, title, slug, order, display_layout, attributes[]` |
| `attribute_sets[].attributes[]` | `id, title, slug, color, image, order, **price, original_price, weight, height, wide, length**` |
| `unavailable_attribute_ids[]` | Attribute ids that cannot be selected |
| `selected_attributes[]` | Current selection, each with its nested `attribute_set` |

**Each attribute carries its own price and weight.** The selector can therefore
show per-option pricing with no extra request — only the *commit* needs one.

### `GET /ecommerce/product-variation/{id}?attributes[]=…`

`id` is the **parent** product id; `attributes[]` are attribute ids.

> ⚠️ **The price fields are named differently and mean different things.**
> `/products/{slug}` is serialized by `AvailableProductResource`;
> `/product-variation/{id}` by `ProductVariationResource`, which exposes raw
> columns.

| | `/products/{slug}` | `/product-variation/{id}` |
|---|---|---|
| selling price | `price` = 921.501 | **`sale_price`** = 493.5 |
| formatted selling | `price_formatted` | **`formatted_sale_price`** |
| MRP | `original_price` = 1296.75 | `original_price` = 571.2 |
| formatted MRP | `original_price_formatted` | **`formatted_original_price`** |
| `price` means | selling price | **the MRP** |

Feeding this response to `Product.fromJson` yields empty formatted strings and
**the MRP shown as the selling price**. It needs its own parser, where the
effective price is `sale_price` when > 0, else `price`.

### Corrections to the written guide

1. The guide says a request with no `attributes` returns **400**. It returns
   **200 with the base product** — verified. Treat "no attributes" as a no-op,
   not an error.
2. `default_product_variation` arrived with `image_with_sizes: null`,
   `weight/height/wide/length: null` and `image_url` pointing at
   `core/base/images/placeholder.png`. **Fall back to the parent's images and to
   the selected attribute's `weight`** — the per-attribute values are populated
   even when the default variation's are not.
3. `product_options` / `variation_attributes` on the product payload are a
   *separate* feature (add-on options) and are empty on every live product. They
   are not how variations are modelled.

### The cart ✅ resolved

Section E landed, so the cart is server-side and carries variation ids. Verified
live on 2026-08-03:

```
POST /ecommerce/cart {"product_id":122,"qty":1}
  -> line { id: 122, variation_attributes: "(Pack Size: 1.85 KG (Pack of 1))",
            price: 470, weight: 1850 }
```

Three things follow:

1. **Post the variation id, not the parent's.** Posting 120 gets you the
   *default* variation (121), silently — the customer's pick is discarded.
2. **The line id is the variation id.** `PUT`/`DELETE` match on it, so a stepper
   must use `ServerCartItem.lineId`, never the parent product id. Passing the
   parent adds a duplicate line on `PUT` and 404s on `DELETE` — which wipes the
   cart (finding 0).
3. **Cart price is ex-tax; catalogue price is inc-tax.** The line reads 470
   against the catalogue's ₹493.50, because 470 × 1.05 = 493.50 = `order_total`.
   Same split as simple products; show `lineTotal`/`orderTotal` when comparing.

### Further corrections, from the live resolve payload

The resolve endpoint returns considerably more than the doc above recorded, and
several fields remove work from the client:

| Field | Value | Use |
|---|---|---|
| `image_with_sizes` | **populated** (origin/thumb/medium/product-thumb) | Swap the gallery on selection. Unlike `default_product_variation`, where it is null. |
| `display_price` / `display_sale_price` | `"₹571.20"` / `"₹493.50"` | Render directly; no client formatting. |
| `sale_percentage` | `"-13%"` | The discount badge, server-computed. |
| `success_message` | `"98 products available"` | Server-authored stock line — show verbatim. |
| `error_message` / `warning_message` | null when fine | Show verbatim when set. |

⚠ **`selected_attributes` has two different shapes under one key.** On
`/products/{slug}` each entry nests a full `attribute_set` object; on
`/product-variation/{id}` it is flat (`id, slug, set_slug, set_id`). A single
parser for both silently yields empty set titles.

⚠ **`default_product_variation` uses a third price convention again** — the
ordinary catalogue one. `price` is the selling price, there is no `sale_price`
key at all, and the labels are `price_formatted` / `original_price_formatted`.
One parser can serve both by keying off whether `sale_price` is present.

### Status: implemented ✅

`ProductVariation` / `ProductVariationOptions` (models), `productDetail()` +
`resolveVariation()` (repository), `variationProvider` (selection state),
`VariationSelector` (UI), and the detail screen reads price, MRP, SKU, stock,
images and the cart id through the selected variation.

### The grid tile ✅ — solved with the attribute filter

The catalogue **list** payload gives no signal that a product is variable.
Confirmed against `AvailableProductResource` itself, not just observed: it emits
`product_options` (add-on options — a different feature, empty on every live
product) and exposes `variation_attributes` only for rows that *are* variations.
Products 118 (simple) and 120 (variable) differ in nothing but price and
dimensions.

**The filter answers what the resource cannot.** Only variable products carry
attributes, so asking for products matching every attribute value in the
catalogue returns exactly the variable set. Verified live:

```
GET /ecommerce/filters
  -> attributes[]: set 3 "Weight" {11,16}, set 6 "Pack Size" {21,22,23}

GET /ecommerce/products?attributes[]=21&attributes[]=22&attributes[]=23
  -> [111, 120]      // precisely the two variable products
```

Two requests for the whole catalogue, once per session — `variableProductIdsProvider`.
A tile therefore knows on first paint, and only the products that scan names
then cost a detail read to count their packs. A known-simple product costs
nothing at all, not even before an add.

Dio serialises `{'attributes[]': [21,22,23]}` as
`attributes%5B%5D=21&attributes%5B%5D=22&…`, which is the form probed above.

Still outstanding, and much smaller: the cart line comes back under the
*variation* id with nothing linking it to the parent, so
`ServerCartState.variationLines` records what the server answered — "you asked
for 120 and line 121 grew". That map is per-session; after a restart a tile
whose variation is already in the basket shows ADD rather than a stepper until
it is added again.

**Backend fields that would simplify this:** `is_variable` / `variations_count`
on `AvailableProductResource` (removes the two-request scan), and `parent_id` on
the cart line (removes `variationLines`).

### The pack sheet

`showVariantSheet` renders one row per option from
`attribute_sets[].attributes` — price, MRP, discount badge and pack size all
arrive with the product detail, so the sheet opens with **no** further request.
Only committing needs one: the variation id is not in that payload and is
resolved at ADD time.

It handles a **single** attribute set. With two or more, a variation is a
*combination* that a flat list would misrepresent, so those products open the
detail screen and its full picker instead (`canShowVariantSheet`).

### Also found: the pickup store *is* on the cart line

`cart_options.store` carries `{id, slug, name, zip_code}`. An earlier note here
said the store was unreachable from the cart; that was wrong — the probe looked
at `options` (the chosen-options list) rather than `cart_options` (the bag).
Rung 2 of `getPickupPostcode()` is therefore implementable client-side. It
changes no rate today because the store zip and `kDefaultPickupPinCode` are both
`311001`.

---

## SECTION J2 — Profile CRUD ✅ DONE

Served by `Botble\Api\Http\Controllers\ProfileController`, routed in
**`vendor/botble/api/routes/api.php`** — *not* the ecommerce plugin, which has no
profile routes at all. All six are inside `auth:sanctum` under the `api/v1`
prefix. Verified deployed on 2026-08-11 (each answers 401 unauthenticated;
`/me-nope` answers 404, so the 401s are real routing, not a catch-all).

| Route | Verb | In app |
|---|---|---|
| `/me` | GET | ✅ already existed — `AuthRepository.fetchProfile` |
| `/me` | PUT | ✅ `ProfileRepository.updateProfile` → profile screen |
| `/update/avatar` | POST | ✅ multipart, field `avatar` |
| `/update/password` | PUT | ✅ change-password screen |
| `/settings` | GET/PUT | ⬜ deliberately — see §1.1 |

**Screens:** `/profile` (`ProfileScreen`), reachable from the Account tab's
header and its "My profile" tile; `/profile/password`
(`ChangePasswordScreen`), reachable from the Account tab's "Change password"
tile.

**Editable on the profile screen: name and date of birth only.** Email and phone
are rendered locked — see "Editing the phone is a footgun" below; the email is
the password-reset channel and there is no verification step for either. A save
therefore sends `name` and, when it changed, `dob`, and never mentions the other
two.

### The editable set is smaller than the validator suggests

`updateProfile` validates `first_name`, `last_name`, `gender` and `description`
— **none of which exist**. `ec_customers` is
`id, name, email, password, avatar, dob, phone, remember_token, timestamps`
(+ `confirmed_at`, `status`, `private_notes`, `locked_until`), and
`Customer::$fillable` is `name, email, password, avatar, phone, status,
locked_until, private_notes`. So:

| Field | Validated | Persists | Why |
|---|---|---|---|
| `name` | ✅ | ✅ | fillable + column |
| `email` | ✅ | ✅ | fillable + column, `unique` |
| `phone` | ✅ | ✅ | fillable + column, **no uniqueness rule** |
| `dob` | ✅ | ✅ | column; set directly after `fill()`, which bypasses `$fillable` |
| `first_name` · `last_name` · `gender` · `description` | ✅ | ❌ | no column, not fillable — `fill()` discards them silently (strict mode is off, so no exception) and `UserResource` echoes them back as null |

The app therefore offers exactly four inputs. Adding a gender picker would show
the customer an edit that never lands.

### Four traps, each pinned by a test

1. **`nullable` writes nulls.** An explicit `"email": null` passes validation,
   survives `validated()`, and `fill()` writes it — and `ec_customers.email` was
   made nullable in 2024. Same for `phone`, which is how the customer signs in.
   Every field is **omitted** from the body unless it changed;
   `ProfileRepository` never sends a null. Laravel's
   `ConvertEmptyStringsToNull` means `""` is the same hazard, so a cleared box
   is treated as "leave it alone" and the helper text says so.
2. **`dob` is read ISO and written `dd-MM-yyyy`.** The rule is
   `date_format:` . `BaseHelper::getDateFormat()`, and this deployment sets
   `CMS_DATE_FORMAT="d-m-Y"` in `.env`. `Customer.apiDob` owns the write format.
   `dob` also **cannot be cleared** — the controller applies it under
   `if (! empty($data['dob']))`, so an empty value is a no-op.

   ⚠ **The read side caused a real off-by-one: saving the 28th displayed the
   27th.** `UserResource` hands the `date`-cast Carbon straight to the encoder,
   so it serialises through `Carbon::jsonSerialize()` → `toIso8601ZuluString`,
   which is **midnight in the store's timezone expressed in UTC**. Botble sets
   `app.timezone` from the admin `time_zone` setting at boot
   (`BaseServiceProvider:308,346`), so on an India store 28 Aug leaves as
   `2026-08-27T18:30:00.000000Z` — and truncating that to its UTC calendar day
   gives the 27th.

   A date-only value carried as an instant is midnight *somewhere*, so
   `Customer._parseDob` recovers the intended day by **rounding the instant to
   the nearest midnight** rather than truncating. Exact for store offsets from
   UTC−11 to UTC+12. A bare `YYYY-MM-DD` is read literally, and that is what
   `Customer.toJson` writes, so the locally cached session cannot drift with the
   device's timezone either.
3. **`avatar_url` is never null.** With no uploaded image it falls back to
   `customer_default_avatar`, and failing that to
   `Botble\Base\Supports\Avatar::toBase64()` → `toDataUri()`, i.e. a
   multi-kilobyte `data:image/jpeg;base64,…`. No image widget here can decode
   one and it would be persisted into SharedPreferences on every sign-in, so
   `Customer.fromJson` keeps only absolute `http(s)` URLs and the app draws its
   own initials otherwise.

   It is also a **thumbnail** — `RvMedia::getImageUrl($avatar, 'thumb')`, 150×150
   by default — which is unreadable full screen. The original is reachable
   though: that call's only effect on the path is to insert the configured size
   before the extension (`RvMedia.php:219-226`), so
   `users/asha-150x150.jpg` → `users/asha.jpg` addresses the uploaded file.
   `Customer.avatarOriginal` does that, and the viewer keeps the thumbnail as a
   fallback because the transform is a derivation, not a promise — a file
   genuinely named `…-150x150.jpg` would resolve to nothing.

   **Backend ask:** send `image_with_sizes` (`origin` + `thumb`) on
   `UserResource` the way the catalogue resources already do, and this
   derivation goes away.
4. **A wrong current password is 403, not 401.** `ApiClient.onUnauthorized`
   fires only on 401, so the session correctly survives a failed attempt.

### Editing the phone is a footgun the server does not guard

`PUT /me` puts **no `unique` rule on `phone`**, and `OtpController::send`
resolves a number with `Customer::where('phone', …)->first()` — lowest id wins.
A customer who typos into a number that already belongs to someone else can
never sign in by OTP again, and the new number is never verified.

**The app does not offer the edit.** The phone field is rendered locked, which
removes the failure mode entirely rather than warning about it — the app has no
way to check whether a number is already taken (no endpoint exposes that), so a
warning would have been the most it could do. Email is locked for the same
reason: it is the password-reset channel and equally unverified. A genuine
change goes through support until the backend adds uniqueness and a
verification step.

### No delete

There is no account-deletion route anywhere in the API surface, so the "D" of
CRUD does not exist server-side. If app-store policy starts requiring in-app
account deletion, that is a backend task first.

### Ask the backend team

| Ask | Why |
|---|---|
| Honour `notification_enabled` when sending pushes | Would make `GET/PUT /settings` worth surfacing; today it stores a preference nothing reads |
| Add `unique` to `phone` on `updateProfile` | Removes the OTP-lockout footgun above |
| Return field-keyed `errors` from `ProfileController` instead of one concatenated `message` | Every other validated endpoint does; without it the app cannot attach a server error to the box that caused it, so it duplicates the rules client-side |
| Drop `first_name`/`last_name`/`gender`/`description` from the validator, or add the columns | Right now the API advertises fields it throws away |

---

## SECTION J3 — Category facet filters ✅ DONE

`GET /ecommerce/filters` (optionally `?categories[]=<id>`) returns the facets;
the listing route accepts them as query parameters.

**The key finding:** `ProductCategoryController::products` merges the category
and its children into `categories` and hands the request to the **same**
`GetProductService` the flat product list uses. So every filter that works on
`/ecommerce/products` works on `/product-categories/{id}/products` too — no
separate contract to discover.

`GetProductService` reads: `q`, `brands`, `categories`, `tags`, `collections`,
`collection`, `attributes`, `discounts`, `ratings`, `min_price`, `max_price`,
`price_ranges`, `sort-by`, `num`/`per-page`, `page`. `parseFilterParams` accepts
either `tags[]=1&tags[]=2` or `tags=1,2`.

### Verified live, category 17, 2026-08-11 (baseline 5 products)

| Param | Result | Shipped |
|---|---|---|
| `attributes[]=22` | 2 | ✅ Weight, Pack Size chips |
| `tags[]=15` | 2 | ✅ "Good for", with counts |
| `brands[]=8` | works | ✅ but hidden — the store has exactly **1** brand |
| `min_price` / `max_price` | ⚠ filters a different price | ❌ see below |
| `sort-by` | pre-existing | unchanged |

Store facets: 21 categories, **1** brand, 3 tags, 2 attribute sets,
`max_price` 4444, and `price_ranges` **empty** — the server originates none.

### Price is deliberately not offered

`max_price=900` returns a product listed at **₹943.95**, and `max_price=800`
drops one listed at ₹838.95 that reappears at 878. The bounds match neither the
displayed price, nor ex-tax (÷1.05), nor `original_price`. A rupee slider would
visibly contradict the prices beside it, so it is left out until the server
agrees with itself — evidence in `docs/BACKEND_BUGS.md` §16.

### In-stock is client-side, on purpose

`GetProductService` passes `include_out_of_stock_products: true` unconditionally
and there is no stock parameter, so the toggle filters the page that came back.
It is therefore excluded from `ProductQuery` — sending it would be a filter the
server ignores — and it disables the infinite-scroll footer, because paging is
server-driven and a locally-filtered page cannot ask for "more of the same".

### Where it lives

`showProductFilterSheet` (`product_filter_sheet.dart`) over
`categoryFiltersProvider`, wired into `CategoryBrowseScreen`. Facets go into
`ProductQuery` — whose equality had to learn about them, or applying a filter
would silently re-use the previous list.

---

## SECTION J4 — Review flow, reworked to match the website ✅ DONE

The backend reworked the review endpoints on **2026-08-12** so the API behaves
like the web storefront. Every claim below was re-verified live that day before
any app code moved.

### What the server changed, and what the app does now

| # | Change | App |
|---|---|---|
| 1 | Bearer token now personalises the two *public* review endpoints | **Already correct** — `ApiClient` attaches it to every request unconditionally |
| 2 | Unapproved reviews are no longer public | Counts read `review_summary.reviews_count`, never `reviews.length` |
| 3 | `has_reviewed` actually works | No client-side guess remains |
| 4 | All `POST /reviews` failures are 422 with an `errors` map; business blocks add `reason` | `ApiException.reason` carries the code; one handler |
| 5 | `reply` on the review object | Rendered in a tinted box with an Admin badge |
| 6 | `is_approved` | Dimmed row + "Waiting for approval" |
| 7 | `review_eligibility` | Gates the entry point — no more writing a review and *then* being refused |
| 8 | `review_settings` | Drives the picker; the hardcoded limits are gone |
| 9 | `review_summary` | Average, five bars, and the media strip |
| 10 | `reviews_pagination` | Replaced a heuristic that scraped the total from an English sentence |
| 11 | `GET reviews/products-to-review` | Replaced a three-call derivation |

### The two that removed real client complexity

**`products-to-review`.** The "Waiting for your review" tab used to be
assembled from three reads: every review the customer had written, their
completed orders, then **one detail call per order**, because a list row
carries no product ids. N+2 requests, capped at ten orders — so the answer was
simply wrong for anyone with a longer history, and it could not know about the
post-delivery waiting period at all, so it offered products the server would
then refuse. It is one call now.

**`reviews_pagination`.** `isLastPage` was inferred from a short page plus a
total parsed out of `"2 review(s) for \"Product\""`. That could not distinguish
"last page" from "exactly a full page with nothing behind it". The block is
authoritative; the old inference is kept only for a deployment that predates it.

### Two deliberate departures from the integration note

**Inline avatars are drawn as initials, not decoded.** The note asks that the
image loader accept `data:` URIs, and `AppNetworkImage` now does — a `data:`
URI handed to `CachedNetworkImage` goes to Dio, which needs a host, so it used
to render the fallback leaf.

But the review list does **not** use it. An inline avatar measured 45–69% of the
whole response body and is re-encoded per request (the same review came back at
2927, 3259, 3835 and 4003 bytes across identical calls), so nothing downstream
can cache it. The app draws initials from `user_name` instead, which shows the
same information for no bytes. The decoder stays for the one-off cases and so
the shared widget is correct for any caller.

**The per-star tally is not shown.** `star_distribution` sends a `count`
alongside `percent`, and on 2026-08-12 that count was **100 for a product with
exactly one review**, on every product probed — the field is carrying the
percentage. Only `percent` is used, for the bar width. Rendering the count would
tell a customer there are 100 reviews when there is one. **Backend ask:** make
`count` a count, or drop it.

### Reason codes and what the app does with each

| Code | Entry point |
|---|---|
| `login_required` | Offered, routes to sign-in — the customer can act on it |
| `already_reviewed` | Hidden; their own review is pinned above instead |
| `purchase_required` · `review_disabled` | Hidden entirely — no action is available |
| `review_delay` | Disabled, with the server's message |

---

## SECTION I1 — Order history timeline ✅ DONE

`GET /ecommerce/orders/{id}` gained three keys on **2026-08-12**: `histories`,
`cancellation_reason` and `cancellation_reason_message`. Purely additive — the
app defaults all three, so a list row (which never carries them) and any
response cached before the change both still parse.

The **list** endpoint deliberately omits `histories`, mirroring the website,
whose list page shows no timeline.

### What could and could not be verified

This endpoint is behind `auth:sanctum` and no customer token was available, so
it could not be called directly. Two things were checked instead:

* **The local backend checkout predates the change.** `OrderController::show()`
  reads `->with(['products', 'shipment', 'payment', 'billingAddress'])` — no
  histories — and `OrderDetailResource` has no `getHistoryData()`. Same
  situation as the flash-sale tax fix: deployed, not in this git tree.
* **The row shape is live**, confirmed through the *public*
  `POST /ecommerce/orders/tracking`, which returns the same history rows.
  Order 286 came back with four, each carrying `id`, `action: {value, label}`,
  `description` and an offset `created_at`.

### Two things that probe turned up

**`%user_name%` is real.** The tracking endpoint's descriptions arrive
**unresolved** — captured verbatim: `"Order was verified by %user_name%"`. The
integration note warned about this and the capture confirms it. Only the
authenticated detail endpoint's rows are fit to display, and the timeline widget
says so where someone might be tempted to reuse it.

**Two spellings for the cancellation message.** The detail endpoint sends
`cancellation_reason_message`; the tracking payload for order 286 sends
`cancellation_reason_description`. The model reads **both**, so neither resource
has to change for this to work.

### Ordering

Rendered exactly as received. The detail endpoint sends `id DESC`; the app does
not re-sort, because a client-side rule would disagree with the website the
first time two rows shared a timestamp. Worth knowing: the tracking endpoint
returns the same rows **oldest first**, so "the order received" is a per-endpoint
fact rather than an API-wide one — pinned by a test.

### What is shown

| Field | Rendered as |
|---|---|
| `description` | The row text — plain, already resolved server-side |
| `created_at` | Below it, converted to device local time |
| `is_system` | Cog or person marker. **Not** colour-coded by action, matching web |
| `action.value` | Logic only — never displayed |
| `action.label` | Ignored. No translations exist, so it falls back to the raw code |
| `refund_amount_formatted` | A note on refund rows: the description rounds ₹1,493.97 to "₹1,494" |
| `cancellation_reason_message` | A warning line beside the status |

An empty `histories` hides the whole section rather than drawing an empty card.

### Still not exposed — do not plan UI on it

Shipment `tracking_id` / `tracking_link`, and ShipRocket live tracking, whose
route is still commented out at
`platform/plugins/ecommerce/routes/api.php:111`. Ask the backend before
designing a live-tracking screen.

---

## SECTION K — Cleanup + release readiness 🟡 PARTLY DONE

| # | Item | Status |
|---|---|---|
| 1 | Remove the `core/pricing` coupon table and client arithmetic | ✅ `kCoupons`, `Coupon`, `gstRate` and `OrderSummary.from` are deleted; `OrderSummary.fromServerCart` only *reports* |
| 2 | Delete the `/categories` (blog) endpoint constant | ✅ gone from `api_endpoints.dart` |
| 3 | **Production origin + API key** | 🔴 **not done — do this before any release** |
| 4 | Deep links | 🟡 routes exist in `go_router`, no Android intent filters |
| 5 | Crash reporting before payments ship | ⬜ not started — and payments *have* shipped |

### K3 — the origin ✅ RESOLVED · the key 🟡 accepted risk

**The origin was never wrong.** `dev.truewayerp.com` **is** the live store —
the `dev.` prefix is historical, not a staging marker (confirmed by the client
2026-08-06). Probed the same day:

| Host | Root | `/api/v1/ecommerce/products` |
|---|---|---|
| `dev.truewayerp.com` | — | `200`, real Botble API, real products |
| `truewayerp.com` | `403` | `404`, serves an unrelated site |

So there is no second host to move to, and `BUILD_AND_RUN.md` — which told you
to build against `https://truewayerp.com` — was wrong. Corrected.

Earlier revisions of this document called this "pointing at dev" and treated it
as a release blocker. It is not. Withdrawn.

**What remains is only the key.** `X-API-KEY` is enforced on every route, so the
string in `app_config.dart` is a live production credential readable by anyone
with this repository or a decompiler on the APK. The client accepts this for
now. Two improvements, in order of effort:

1. Move it to `--dart-define` from CI secrets and drop the default — **and
   rotate it**, since the current value must be assumed compromised.
2. A thin server-side proxy that injects the key, so the binary never carries
   one. The only fix that survives someone unpacking the APK.

`AppConfig.usesSourceControlledKey` reports which a given build is using.
Deliberately **not** enforced: the default *is* the real key, so failing the
build on it would break a correct release.

### K6 — the invoice ✅ DONE, via the download route

There are two invoice routes and **only one is usable from the app**.

`GET /orders/{id}/invoice` returns a *link*:

```php
// InvoiceHelper::getInvoiceUrl()
return route('customer.invoices.generate_invoice', $invoice->id) . '?type=print';
```

That is a **customer web route** behind session auth (`routes/customer.php`) —
not signed, no token — so opening it with a bearer token lands on the storefront
login page. `OrderRepository.invoiceUrl()` is kept, documented as unusable, for a
future WebView that holds a real web session.

`GET /orders/{id}/invoice/download` is a proper sanctum route returning the PDF
bytes, and that is what the app uses (`OrderRepository.downloadInvoice`). Three
things it has to get right:

| Concern | Handling |
|---|---|
| The body is **binary**, not JSON | `ApiClient.getBytes` sets `ResponseType.bytes`, so no interceptor tries to decode a PDF. The `error: true` check is a no-op on a byte list, so it cannot misfire either. |
| The PDF is **re-rendered by dompdf on every request** — no cache, ~10 s cold | 60 s receive timeout, a spinner on the button and a "Preparing your invoice…" note. The app-wide timeout would have reported a network failure for a working endpoint. |
| The invoice code is **unrelated to the order** — order 131 is invoice `INV-97` | The filename comes from `Content-Disposition`, never composed from the order id. Falls back to `invoice-order-{id}.pdf`, which claims no invoice number the app cannot know. |

No new dependency: `share_plus` was already present, and `XFile.fromData` +
`fileNameOverrides` hand the bytes to the platform share sheet without writing
to app storage.

The button is gated on `is_invoice_available`, so a cancelled order — which
never has an invoice row — shows no button rather than one that 404s.

### K7 — the cancellation reason list is hardcoded 🟡

`CancelOrderRequest` validates against `ec_order_reasons`, which is
**admin-editable at runtime**, and there is **no endpoint that exposes it**. So
the app ships a hardcoded list and an admin change silently breaks the picker.

This already bit once. `2026_07_11_000000_remove_unused_cancellation_reasons`
deletes five rows — `out-of-stock`, `payment-issues`, `not-as-described`,
`customer-requested`, `unforeseen-circumstances` — while **keeping their enum
constants and translations** so historical orders still render a label. The app
was offering four of them, and each was a dropdown entry that always failed with
a 422. Fixed; pinned by `test/presentation/cancellation_reasons_test.dart`.

⚠ **One unresolved discrepancy.** The seed migration creates **six**
customer-selectable rows, including `technical-issues`. The backend team's
integration guide reports **five** verified live. The app ships the five, because
offering a retired token is a dead option while omitting a live one only sends
that customer to "Another reason". Worth a one-line confirmation from the backend.

---

## Definition of done — where it stands

| Criterion | Status |
|---|---|
| `flutter analyze` clean | ✅ clean |
| `flutter test` green | ✅ **1513 passing** (was 73 when this plan was written) |
| Manually exercised against `dev.truewayerp.com` | ✅ every contract in this doc was probed live |
| Server errors surfaced through `ApiException` | ✅ server wording shown verbatim; only unactionable text is substituted |
| No client-side recomputation of anything the server returns | ✅ totals, tax, discounts, parcel dimensions and stock all come from the server |

## Open questions for the backend team

**Answered:**
1. ~~Is there a mobile registration endpoint?~~ → **Yes**, `POST /register`. §D4.
2. ~~Is `fast2sms_otp_login` enabled?~~ → Yes on dev. **Confirm for production.**
3. ~~Exact payload for `check-pincode`~~ → documented in §C.
4. ~~Should `categories[]=` be fixed server-side?~~ → app uses
   `/product-categories/{id}/products`; the query param is still broken but no
   longer on the critical path.
5. ~~Are shipping rates server-calculated?~~ → quoted per destination via
   `check-serviceability`; the app forwards the cart's own
   `package_dimensions`/`total_weight` and never invents a rate.

**Still open — these are the asks:**

| # | Ask | Why it matters |
|---|---|---|
| 1 | **Fix `Cart::restore()`** so a refused mutation stops destroying the whole cart (BACKEND_BUGS finding 0) | Deletes the entire mirror-and-rebuild subsystem in the app |
| 2 | Add **`parent_id`** to the cart line | A variation's line has no link to its parent, so the app keeps a session map to know which tile a line belongs to |
| 3 | Add **`is_variable`** (or `variations_count`) to `AvailableProductResource` | A listing row cannot say whether a product has packs; the app spends two extra requests per session scanning the attribute filter to find out |
| 4 | Include the **store block** on the cart, or confirm `cart_options.store` is stable | It is rung 2 of `getPickupPostcode()`; the app defaults to `311001` today, which is only correct while there is one store |
| 5 | Razorpay **production** keys | Dev keys are wired; production is not |
| 7 | Populate **`admin_feedback` for canceled returns** | It is set only while the status is `resubmit`, so a customer whose return was rejected is never told why |
| 8 | An **endpoint that lists cancellation reasons** | `ec_order_reasons` is admin-editable with no API to read it, so the app hardcodes the list and an admin change silently breaks the picker |
| 6 | `GET /ecommerce/checkout/cart/{id}` **empties the cart** (BACKEND_BUGS finding 1) | The app avoids the route entirely; it should not be a trap |

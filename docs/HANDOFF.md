# Developer Handoff — Trueway Farms Mobile App

_Last updated: 2026-07-29_

This is the entry point for any developer taking over the project. Read it fully
before touching code — it will save you days.

---

## 1. What this app is

A native **Flutter** e-commerce app for **Trueway Farms** (Trueway Organic Pvt
Ltd, Bhilwara, Rajasthan), an organic-grocery brand (wheat, millets, sugar,
spices, etc.). The app is a storefront client for the company's existing
**Botble/Laravel** e-commerce backend at `https://dev.truewayerp.com`.

Customers can: browse the catalogue (home feed, categories, brands, search),
view product details, manage a cart, and go through a checkout flow.

## 2. Important origin story (read this)

**The original app's source code was lost.** Only a shipped APK
(`app-release (1).apk`, a debug build from ~April 2026) survived. This project
is a **clean-room rebuild**:

- The original was a **Flutter** app. Flutter AOT-compiles Dart to native machine
  code (`libapp.so`), which **cannot be decompiled back to source**. So the code
  here was **rewritten from scratch**, not recovered.
- The original build was **not obfuscated**, so its structure (file tree, class
  names, dependency list, brand assets) and the **live API contract** were
  recovered by extracting strings from the binary. Those artefacts are preserved
  in [`../_recovered/`](../_recovered/) — `blueprint.json` (the original
  136-file tree) and `api-samples/` (real API responses). **Use these as a spec
  reference**, especially when wiring the pending authed endpoints.
- The recovered **API key** (see [BACKEND_API.md](BACKEND_API.md)) is Niraj's
  own key and tested-valid against the live backend.

The rebuilt app deliberately deviates from the original in two ways: (1) plain
immutable Dart models with hand-written `fromJson` instead of `freezed`/codegen
(fewer moving parts), and (2) a **new premium UI** based on the "Ashop" shopping
kit recoloured to the Trueway green brand.

## 3. Current state — what works vs what's stubbed

### ✅ Working end-to-end (on live data)
- **Splash → Home** — location bar, search, hero slider (live `simple-sliders`),
  offer cards, category rail (live `categories`), ad banner (live `ads`),
  "Fresh picks" product grid (live `ecommerce/products`).
- **Categories** — left-rail catalogue with working **Sort** (API `sort` param)
  and an in-stock **Filter**; infinite scroll / pagination.
- **Product detail** — gallery, HTML description/spec rendering, stock status,
  price, trust badges, add-to-cart / buy-now.
- **Search** — live product search.
- **Cart** — add/remove/quantity, **persisted** to `SharedPreferences`, correct
  bill math (item total, product discount, GST-incl, delivery), **working demo
  coupons** (`FRESH10`, `ORGANIC15`, `WELCOME50`), Add-GSTIN field, free-delivery
  threshold.
- **Checkout** — address form with **live pincode autofill**
  (`api.postalpincode.in`) → order-success screen with confetti.
- **Account** — profile menu, dark-mode toggle, About/Contact (webview), share.

### 🟡 Stubbed — UI built, backend NOT wired (your work starts here)
| Feature | State | Why |
|---|---|---|
| **OTP login** | UI screen exists (`mobile_login_screen.dart`) | Authed API contract for send/verify OTP was never recovered |
| **Razorpay payment** | Checkout confirms **locally** then clears cart | Razorpay config comes from the authed checkout API response (not hardcoded); needs auth first |
| **Product variants / pack sizes** | Not built | Original had a "Select Variant" bottom sheet; the public products API returns empty `product_options` |
| **Wishlist** | Heart on cards is **local/visual only** (no persistence) | Needs a wishlist provider + authed wishlist API |
| **Order history / Track Order** | `orders_screen.dart` shows an empty state | Needs authed `/orders` endpoints |
| **Address book** | Checkout uses a one-off form | Needs authed address CRUD |

See [ROADMAP.md](ROADMAP.md) for how to implement each.

## 4. The single biggest blocker for the next phase

**Everything customer-account-related is gated on authentication**, and the
**authenticated API contract was never reverse-engineered** (the recovered
binary only exposed the *public* catalogue endpoints). To move forward you need
the real request/response shapes for: send/verify OTP, cart sync, order
placement + Razorpay init, order list/track, wishlist, and addresses.

**How to get them (recommended):** capture live traffic from the original app or
the web storefront while logged in — e.g. proxy the app through **mitmproxy /
Charles / Proxyman**, or inspect the web app's network tab at
`https://dev.truewayerp.com`. The endpoint *names* are already stubbed in
[`lib/core/network/api_endpoints.dart`](../lib/core/network/api_endpoints.dart)
(`/auth/send-otp`, etc.) — confirm/correct them against real traffic. The
backend team (Botble/Laravel) can also just hand you the API docs.

## 5. How to continue — suggested order

1. **Read** [ARCHITECTURE.md](ARCHITECTURE.md) and skim the `lib/` tree (only 48
   files; it's small and consistent).
2. **Build & run** it once (see [BUILD_AND_RUN.md](BUILD_AND_RUN.md)) to confirm
   your environment.
3. **Capture the authed API** (section 4) — this unblocks everything else.
4. Implement in this order (highest value first):
   **OTP auth → cart/order sync → Razorpay checkout → order history →
   wishlist → variants**. Details in [ROADMAP.md](ROADMAP.md).
5. Before shipping: fix the security items in [KNOWN_ISSUES.md](KNOWN_ISSUES.md)
   (hardcoded API key), add real app icons/splash, and set up a proper CI signing
   pipeline.

## 6. Ownership & credentials

- Code + brand: **Trueway Organic Pvt Ltd**. Built by Uminber Designs (Niraj).
- **Release signing keystore** lives at `android/app/trueway-release.jks`
  (credentials in `android/key.properties`). **Do not lose it** — the same key is
  required for every future Play Store update. Details in
  [BUILD_AND_RUN.md](BUILD_AND_RUN.md).
- Backend access / API keys: request from the Trueway backend team.

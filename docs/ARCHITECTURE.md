# Architecture

The app follows a pragmatic **Clean Architecture** split with **Riverpod** for
state/DI and **go_router** for navigation. It's still small (109 Dart files under
`lib/`, 53 under `test/`) and consistent — once you understand one feature you
understand them all.

```
┌───────────────────────── presentation/ ─────────────────────────┐
│  screens/            widgets/           providers/     router/    │
│  (ConsumerWidget)    (ProductCard…)     (Riverpod)     (go_router)│
└───────────────▲───────────────────────────▲─────────────────────┘
                │ watch/read                 │ provider graph
┌───────────────┴───────────────────────────┴─────────────────────┐
│                          data/repositories/                       │
│                    CatalogRepository (maps API → models)          │
└───────────────▲──────────────────────────────────────────────────┘
                │
┌───────────────┴──────────────────────────────────────────────────┐
│   core/network/ApiClient (Dio)  →  core/config/AppConfig          │
│   models in data/models/ (fromJson)  ·  errors/ApiException        │
└───────────────────────────────────────────────────────────────────┘
```

## Layers

### `core/` — foundation (no feature logic)
- **`config/app_config.dart`** — single source of truth for backend `origin`,
  `apiBase`, `apiKey` (+ `X-API-KEY` header name), timeouts, image URL resolution.
  All overridable at build time via `--dart-define` (see BUILD_AND_RUN).
- **`network/api_client.dart`** — a configured **Dio** instance: base URL,
  injects the `X-API-KEY` + `Accept: application/json` headers, timeouts, and maps
  failures to `ApiException`.
- **`network/api_endpoints.dart`** — all endpoint path constants.
- **`network/api_response.dart`** — helpers for the Laravel envelope
  (`data`/`links`/`meta`, `error`/`message`) incl. pagination.
- **`errors/api_exception.dart`** — typed error with a user-facing `message`.
- **`design_system/`** — `AppColors`, `AppTypography` (Poppins via google_fonts),
  `AppSpacing`/`AppRadius`/`AppShadows`, `AppTheme` (light+dark), `AppIcons`
  (Material Symbols). See [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md).
- **`utils/`** — `price_utils` (₹ formatting, discount %), `json_utils`
  (null-safe `asInt/asString/asDouble/…` — the models depend on these),
  `responsive` (grid columns / gutters by width).

### `data/` — models + repository
- **`models/`** — plain immutable classes with `factory X.fromJson(Map)`. No
  codegen. `Product` is the richest (variants/options/videos/store fields ready
  for later). `CartItem` is the local cart line.
- **`repositories/catalog_repository.dart`** — the **only** place that calls the
  catalogue API. Methods: `products(...)`, `productBySlug(...)`, `categories()`,
  `brands()`, `sliders()`, `ads()`. Returns models (or a small paginated result).
  **When you add authed features, add repositories the same way** (e.g.
  `AuthRepository`, `OrderRepository`, `WishlistRepository`).

### `presentation/` — UI + state
- **`providers/`** — Riverpod graph:
  - `core_providers.dart` — DI roots: `sharedPreferencesProvider` (overridden in
    `main`), `apiClientProvider`, `catalogRepositoryProvider`.
  - `home_providers.dart` — `FutureProvider`s: `slidersProvider`, `adsProvider`,
    `categoriesProvider`, `brandsProvider`, `featuredProductsProvider`.
  - `products_provider.dart` — `productsProvider` is a
    `StateNotifierProvider.family<…, ProductQuery>` with pagination
    (`load/loadMore/refresh`). `ProductQuery{search, categoryId, brandId, sort}`
    has value equality so the family caches correctly.
  - `cart_provider.dart` — `cartProvider` (StateNotifier) persists to
    `SharedPreferences`; exposes `add/remove/increment/decrement/clear` and
    derived totals; `cartCountProvider` for the nav badge.
  - `theme_provider.dart` — light/dark mode (persisted).
- **`router/app_router.dart`** — go_router. Routes: `/splash`, `/` (shell with
  bottom nav), `/products`, `/product/:slug`, `/cart`, `/checkout`,
  `/order-success`, `/search`, `/login`, `/web`. Product objects are passed via
  `extra` to skip a refetch; deep links fall back to `productBySlug`.
- **`screens/`** — one folder per area. `main_navigation_screen.dart` is the
  bottom-nav shell (Home/Category/Cart/Orders/Account) using a Material 3
  `NavigationBar`.
- **`widgets/`** — shared: `ProductCard`, `SectionHeader`, `QuantityStepper`/
  `AddToCartControl`, `HomeSliderCarousel`, `AppNetworkImage` (cached, with
  placeholder/error), `state_views.dart` (`LoadingView`/`AppErrorView`/
  `EmptyView` — reuse these for consistent states).

## Request lifecycle (example: home product grid)

```
HomeScreen (ConsumerWidget)
  └ ref.watch(featuredProductsProvider)              // presentation
        └ catalogRepositoryProvider.products(perPage:20)  // data
              └ ApiClient.get('/ecommerce/products?...')  // core/network
                    └ Dio → GET dev.truewayerp.com/api/v1/... (+ X-API-KEY)
              ← Product.fromJson(...) list
        ← AsyncValue<List<Product>>
  → .when(loading/error/data) → LoadingView / AppErrorView / grid of ProductCard
```

Errors bubble up as `ApiException`; every screen renders `AppErrorView` with a
retry that invalidates the provider. Follow this same pattern for new features.

## Shipping and checkout — the one flow with money in it

Worth stating separately because it is the only place a wrong value costs the
business real rupees, and because this contract has already been corrected more
than once. Treat every line below as citing source you should re-check.

```
cart (server)                        →  package_dimensions, total_weight,
  GET /ecommerce/cart/{id}              order_total, cart_options.store.zip_code
        │
        ▼
LogisticsRepository                  →  POST /logistics/check-serviceability
  9 client-computed fields:             pickup = pickupPinCodeFromCart(cart),
  parcel from the cart, declared_value    i.e. cart_options.store.zip_code
  = the cart's own order_total            (fallback kDefaultPickupPinCode='311001')
        │  List<CourierOption>, each with a rate id and a billedPrice
        ▼
the customer taps one                →  shippingChoiceProvider.select(query, option)
  NOTHING is preselected                 (until then every money provider is null)
        │
        ▼
shippingOptionKeyProvider            →  "shiprocket_<rateId>"
shippingChargeProvider               →  CourierOption.billedPrice (a SUM, not `rate`)
        │
        ▼
CheckoutRepository.placeOrder        →  POST /ecommerce/checkout/cart/{id}
  { shipping_method: "shiprocket",       ...and NO shipping_amount
    shipping_option: "shiprocket_…" }
        │  PlacedOrder
        ▼
reconcile shippingAmount / totalAmount against what was shown, THEN Razorpay
```

Five rules this layout encodes:

1. **The server prices shipping, not the app.** `shipping_amount` is deliberately
   absent from the request — its absence is what activates server pricing
   (`API/CheckoutController.php:425` sets `$useClientShippingAmount =
   $request->has('shipping_amount')`; `:445` skips the server's own pricing when
   that is true). Re-adding it, even as `null`, silently switches the order back
   onto the client-trusted branch.
2. **`shipping_option` carries Shiprocket's rate `id`, not `courier_company_id`.**
   Picking the wrong id is not an error — the server's lookup misses and the
   order ships for ₹0.00 in silence.
3. **The quoted price is a sum of four components, not the row's `rate`.**
   `CourierOption.billedPrice` = `freight_charge + coverage_charges +
   other_charges`, plus `cod_charges` when the quote was fetched with `cod: 1`.
   That reproduces `ShipRocketService.php:1874-1885`'s `$totalCost`, which `:1894`
   stores as the rate entry's `price` and `API/CheckoutController.php:446` reads
   as the order's shipping amount (`:462` adds it to the total). `rate` is parsed
   and kept because every capture refers to it, but it is **used nowhere for
   money**. `rate` happens to equal the sum on any row where coverage and other
   charges are both zero — that is coincidence, not agreement, and it stops
   holding at roughly ₹2,500 of basket value. Full derivation and the live ₹49.00
   step: `VERIFIED_API_CONTRACT.md` §4.5.
4. **No courier is preselected.** `selectedShippingProvider` is null until the
   customer taps a row *for this exact `ShippingQuery`*, and `shippingCharge` /
   `shippingMethod` / `shippingOptionKey` are null with it. Null means "no
   delivery option chosen" — never zero, never free. Place order stays disabled
   and the cart shows a "Subtotal", not a "To pay", until a row is tapped.
5. **The order exists before the app learns what shipping cost.** So the
   reconciliation step between `placeOrder` and the payment sheet is load-bearing,
   not polish. Its tolerance is `TotalDivergence.tolerance = 0.005`
   (`checkout_provider.dart:625`) — half a paise, i.e. floating-point dust only.

**The pickup postcode is read, not hardcoded — verified in source, not aspirational.**
`ServerCartItem.storeZipCode` (`server_cart.dart:254`) parses
`cart_options.store.zip_code`; `pickupPinCodeFromCart(cart)`
(`shipping_provider.dart:152-162`) resolves the basket's lines to one postcode,
rejecting a value that fails the six-digit rule and falling back when the basket
spans two stores that disagree. The **live path** is
`checkoutParcelProvider` → `CheckoutParcel.pickupPinCode`
(`checkout_provider.dart:226`) → `CheckoutParcel.toQuery` (`:147-156`).
`ShippingQuery.fromCart` (`shipping_provider.dart:263-287`) does the same thing
in one step and is exercised by tests, but **no screen calls it** — if you are
tracing the runtime value, follow `CheckoutParcel`. `ShippingQuery`'s plain
constructor still defaults `pickupPinCode` to `kDefaultPickupPinCode`
(`:205`), so a query built by hand rather than from a cart gets the fallback.

Where the rest of the code lives: `lib/data/models/shipping_quote.dart`
(`CourierOption`, `billedPrice`), `lib/presentation/providers/shipping_provider.dart`
(`kDefaultPickupPinCode`, the four selection providers),
`lib/data/repositories/logistics_repository.dart`.

Full contract, backend line numbers, and how the pickup postcode was determined:
`docs/VERIFIED_API_CONTRACT.md` §4.5. Open app-side gaps: `docs/KNOWN_ISSUES.md`.

## Conventions
- **State:** prefer `FutureProvider` for read-only fetches; `StateNotifier` for
  mutable state (cart, paginated lists). Keep API calls in repositories only.
- **Navigation:** `context.push('/route')`; pass heavy objects via `extra`.
- **Styling:** never hardcode colors/sizes — use `AppColors`/`AppSpacing`/
  `AppTypography`/`AppIcons`. Lints enforce trailing commas + single quotes.
- **New feature checklist:** model(s) → repository method → provider → screen →
  route → reuse `state_views` for loading/error/empty.

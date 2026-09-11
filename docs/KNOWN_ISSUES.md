# Known Issues, Gotchas & Security

## ✅ Fixed in the last review pass

These were open when this doc was first written and have since been addressed.
Listed so nobody re-reports them.

| Was | Now |
|---|---|
| **Cart and checkout disagreed on the total.** Cart computed `subtotal − coupon + delivery`; checkout computed `subtotal + delivery`, and the coupon lived in `_CartScreenState` so it was lost on navigation. A customer quoted ₹450 was charged ₹500. | All order money math lives in `core/pricing/order_pricing.dart` (`OrderSummary`). Coupon/GSTIN moved to `checkoutProvider`, and both screens render `orderSummaryProvider`. Covered by a regression test. |
| **Checkout took no money and created no order.** `_placeOrder` waited 600 ms, cleared the cart and showed the success screen — an order confirmation for an order that did not exist. | Real. `_placeOrder` calls `checkoutFlowProvider.placeOrder` → `POST /ecommerce/checkout/cart/{id}`, and the success route now carries the server's own order id (`/order-success/{orderId}`). Razorpay handoff + `confirm-payment` remain blocked on test keys — `BLOCKED_WORK.md` §1. |
| **11 unused dependencies**, two of which (`sqflite`, `video_player`) require Dart ≥3.12 and made `flutter pub get` fail outright on older toolchains. | Removed. `pubspec.yaml` documents exactly which to re-add per feature. |
| **`Product.inStock` was dead logic** — `!isOutOfStock && quantity > 0 \|\| (!isOutOfStock)` reduces to `!isOutOfStock`. | Simplified to `!isOutOfStock` with a comment explaining why quantity can't refine it. Behaviour unchanged. |
| **`productBySlug` fetched 100 products** and linear-scanned on every deep link; anything past item 100 was "not found". | Searches on the slug's words first, then a bounded 5-page scan. |
| **Dark-mode toggle did nothing** (161 hardcoded `AppColors.*`, zero `Theme.of(context)`). | Toggle removed; app pinned to light. `AppTheme.dark` kept and documented — re-enable once screens read `ColorScheme`/`TextTheme`. |
| **No tests, no `flutter_test`.** | **1290 tests across 50 files, all passing** at the time of writing (2026-08-04) — pricing, JSON coercion, validators, models, cart state, and widget tests for the cart, checkout and shipping selector. The count moves every week; run `flutter test` for the current figure rather than citing this one. |
| **Release build had R8 and resource shrinking off.** | Both enabled, with `android/app/proguard-rules.pro`. |
| **GSTIN accepted any 15+ characters** (`AAAAAAAAAAAAAAA` passed). | Real format validation in `core/utils/validators.dart`, alongside mobile/pincode. |
| `ApiClient` awaited `SharedPreferences.getInstance()` on **every request**. | Injected once via `sharedPreferencesProvider`. |
| Two `TextEditingController`s leaked on every cart dialog open. | Single shared prompt helper that disposes its controller. |
| `flutter analyze`: 31 lint infos. | Clean — `No issues found!` across `lib/` and `test/`, re-run 2026-08-04. Keep it that way: run `flutter analyze` (which covers `test/`, not just `lib/`) before calling any change done. |

## 🔒 Security (fix before public release)

1. **Hardcoded API key.** `AppConfig.apiKey` ships a dev `X-API-KEY`
   (`8pfF…MLp`) as a fallback. Anyone can extract it from the APK and hit the
   backend. **Mitigate:** inject via `--dart-define=API_KEY=...` for prod, rotate
   the dev key, and ideally proxy API calls through a thin server so the key never
   lives in the client. (This same weakness existed in the original app.)
2. **Signing secrets in-repo.** `android/key.properties` + `trueway-release.jks`
   currently sit in the project. Before pushing to any shared/public repo, move
   them to CI secrets / a vault and add them to `.gitignore` (a `.gitignore` is
   included that already excludes them).
3. **Backend is on a `dev.` host** with permissive CORS (`*`). Point production
   builds at the production origin and confirm the backend locks down CORS +
   rate-limits the API-key endpoints.
4. **No cert pinning / minimal input validation** on the client. Add as needed.

## ⚙️ Build & tooling gotchas

- **Kotlin is applied explicitly now — don't "tidy it away."** The app module's
  `kotlin { compilerOptions { … } }` block and `share_plus`'s build script both
  need the Kotlin Gradle Plugin, but nothing in this project applied it. It
  worked only because the (unused) `fluttertoast` dependency applied KGP as a
  side effect, which the Flutter Gradle Plugin then propagated. Removing that
  dependency broke the Android build with `Unresolved reference
  'compilerOptions'`, then `Extension of type 'KotlinAndroidProjectExtension'
  does not exist`. KGP is now applied in `android/build.gradle.kts`
  (all library modules) and `android/app/build.gradle.kts`.
- **`android.builtInKotlin` must stay `false`** on this toolchain. Setting it
  `true` (the AGP 9 default) fails because `shared_preferences_android` 2.4.23
  applies `kotlin-android` itself, which AGP 9 rejects. The fixed version
  (2.4.27) requires a newer Flutter than this project targets — revisit when the
  Flutter version is bumped.

- **`phosphor_flutter` is incompatible with Flutter 3.44.** It `extends
  IconData`, which is now a `final` class → the build fails with _"The class
  'IconData' can't be extended…"_. Crucially, **`flutter analyze` does NOT catch
  this** (it skips package internals) — only `flutter build`/`run` does. The app
  uses **`material_symbols_icons`** instead. **Don't re-add phosphor.**
- **Icon tree-shaking false alarm.** Release builds log _"MaterialSymbolsRounded.ttf
  tree-shaken … 100% reduction"_. This is misleading — the used icons **do
  render** in the release build. No action needed. (If icons ever actually go
  missing, build with `--no-tree-shake-icons`.)
- **Windows loopback build failure.** On the original Windows machine, Android
  builds fail with _"Unable to establish loopback connection"_ unless the temp dir
  is redirected — see [BUILD_AND_RUN.md](BUILD_AND_RUN.md). Not an issue on
  mac/Linux/clean CI.
- **Release-over-debug install fails** (signature mismatch). `adb uninstall
  com.trueway.trueway_farms` before installing a release APK on a device that had
  a debug build.
- **`flutter_inappwebview` was removed** in favour of the official
  `webview_flutter`: inappwebview_android 6.x uses a ProGuard file that the newer
  Android Gradle Plugin rejects at evaluation time.

## 📱 Runtime notes

- **Emulator API timeouts.** Software-GPU Android emulators intermittently fail to
  reach `dev.truewayerp.com` (the app then shows the styled _"Connection timed
  out → Try again"_ state). This is emulator networking, **not an app bug** — real
  devices load fine. If testing on an emulator, prefer one with reliable network,
  and allocate ≥3.5 GB RAM / 4 cores (low specs cause SystemUI ANRs / crashes).
- **`google_fonts` (Poppins) fetches at runtime** → first launch needs network for
  fonts, and there's a brief fallback flash. Bundle Poppins locally to fix.
- **The unused dependencies have been removed** (see the Fixed table above).
  `sqflite` and `video_player` require Dart ≥3.12, so keeping them "for later"
  broke `flutter pub get` on every older toolchain. `pubspec.yaml` lists which
  package to re-add for which feature.

## 🚚 Shipping & delivery pricing

**The contract is settled — do not re-litigate it.** The app sends
`shipping_method: "shiprocket"` + `shipping_option: "shiprocket_<rateId>"` and
**not** `shipping_amount`; the server prices the order. Omitting the field is
what activates server pricing (`API/CheckoutController.php:425` sets
`$useClientShippingAmount = $request->has('shipping_amount')`; `:445` skips the
server's own pricing when that is true). The app still reproduces the price —
`CourierOption.billedPrice` — to quote the customer and to reconcile the total
that comes back. Full contract, backend citations and the pickup-postcode
investigation: `docs/VERIFIED_API_CONTRACT.md` §4.5.

**Two things also settled in the same round:** the quoted price is
`freight_charge + coverage_charges + other_charges` (+ `cod_charges` on COD), not
the row's `rate`; and **no courier is preselected** — the customer picks, on the
cart and at checkout.

### ✅ Closed in this round — kept so nobody re-reports them

1. ~~**The app displays `rate`.**~~ — **FIXED.** The server bills
   `freight_charge + coverage_charges + other_charges` (+ `cod_charges` when the
   quote was fetched with `cod: 1`), and never reads `rate`:
   `ShipRocketService.php:1874-1877` reads the four components, `:1880` and `:1883`
   sum them, `:1884-1885` adds the COD term, `:1894` stores the result as the rate
   entry's `price`, and `API/CheckoutController.php:446` reads that as the order's
   shipping amount with `:462` adding it to the total.
   `CourierOption.billedPrice` (`shipping_quote.dart:465-469`) now reproduces that
   term for term, `billedPriceFormatted` is the only price string shown to a
   customer, and `rateFormatted` was **deleted** so nothing can regress to it.
   `rate` is still parsed — every capture refers to it and it is a cheap
   cross-check — but is used nowhere for money.

   The live step, probed 2026-08-04 on pickup 311001 → delivery 382415, 5.0 kg,
   `qc_check` 0, `cod` 0, varying only `declared_value`: at **2400** every row has
   `coverage_charges: 0` and `rate` equals the sum; at **2500** every row has
   `coverage_charges: 49.00`, so `rate` is **₹49.00 low**. `declared_value` is the
   basket's own `order_total`, so every basket at ~₹2,500+ crossed it. Real order
   275 was billed ₹802.12 against a ₹741.32 quote — ₹49.00 of that gap is the
   coverage line (the residual ₹11.80 is rate-card drift, **not**
   `other_charges`; an order stores `shipping_amount` as one number and never
   breaks it down). Real order 266 (COD) was billed ₹326.31, which contains
   ₹48.35 of `cod_charges`.

   **`rate` agreeing with the sum on small baskets is coincidence, not
   agreement** — `rate` is `freight_charge` on a prepaid quote and
   `freight_charge + cod_charges` on a COD one, and never carries coverage or
   other charges. Summing the components reproduces `rate` on the agreeing rows
   and is the server's own figure on the diverging ones.
2. ~~**The pickup pincode is hardcoded.**~~ — **FIXED.**
   `ServerCartItem.storeZipCode` (`server_cart.dart:254`) parses
   `cart_options.store.zip_code`; `pickupPinCodeFromCart`
   (`shipping_provider.dart:154-164`) resolves the basket to one postcode;
   `checkoutParcelProvider` (`checkout_provider.dart:230`) is the live path.
   `kDefaultPickupPinCode` keeps its value `'311001'` but is now the documented
   **fallback** — for an empty cart, a line with no store block, a store zip that
   fails the six-digit rule, or a basket spanning two stores that disagree. **Do
   not change it to 110001, and do not use an Ahmedabad pincode** — 382415 is a
   *delivery* pincode and quotes 45–70 % low.

   ⚠ Not fully closed backend-side: the app reads rung 2 of
   `ShipRocketService::getPickupPostcode()` (`:1715-1745`), but the server tries
   rung 1 (`get_ecommerce_setting('store_zip_code')`) first, and rung 1 has no
   public route. `BLOCKED_WORK.md` §3.
3. ~~**A courier was preselected.**~~ — **REMOVED, by product decision.**
   `CourierOption.best` and `ShippingRates.best` are deleted;
   `selectedShippingProvider` is null until the customer taps a row *for this
   exact `ShippingQuery`*, and `shippingChargeProvider` / `shippingMethodProvider`
   / `shippingOptionKeyProvider` are null with it. The old rule was fastest-first
   with cheapest as tie-break, which on a live quote picked Blue Dart Air at
   ₹1,284.15 over Xpressbees Surface at ₹324.30 two days later. The comment
   claiming it mirrored the web was wrong: that rule is
   `PinCodeDeliveryService::findBestCourier` (`:157-177`), which serves the
   **product page's** pincode widget, not checkout. `sortBest` / `byBestFirst`
   survive as display order only. Details and what the web actually does:
   `VERIFIED_API_CONTRACT.md` §4.5.

What is still open on the app side:

1. **Null shipping means "not chosen" — never zero, never free.** All four
   selection providers are null together in seven situations: nothing chosen yet;
   the standing choice was made for a different `ShippingQuery`; the quote is
   loading; the quote failed; the pincode is unserviceable; the chosen courier
   dropped out of the re-fetched list; and (for `shippingOptionKeyProvider` only)
   the chosen row carried no rate id. **Never coalesce to 0, never
   `?? options.first`.** Render a prompt, keep the total labelled "Subtotal"
   rather than "To pay", and keep Place order disabled with a reason. Free
   shipping is a separate, real state: `shippingChargeProvider == 0.0`.
2. **The cart's courier list is a functional placeholder, not a designed empty
   state.** `_ChooseRow` in `delivery_location_bar.dart:763` works but was not
   designed, and with the list open by default the cart card is ~4 rows taller on
   first render — the height problem collapse-by-default existed to solve. Whoever
   owns the cart layout should decide: stays open, opens on scroll-into-view, or a
   compact variant.
3. **Reconcile with a tolerance — and keep it tight.** Shiprocket's rate card
   moved by ₹5–10 + GST between 2026-07-06 and 2026-07-16 (orders 264/268 and
   269/271: identical parcel days apart, ₹741.32 vs ₹753.12), so `==` would have
   flagged 13 of 18 real orders. **An earlier revision of this list recommended
   ±2 % or ±₹15. That is withdrawn.** That drift was between orders placed *days*
   apart; within one checkout session the app and the server quote seconds apart
   from the same warehouse, so once the formula is right there is no legitimate
   drift to absorb — and a ₹15 band would have swallowed exactly the ₹49.00
   coverage error above, plus up to ₹15 of silent overcharge per order. What ships
   is `TotalDivergence.tolerance = 0.005` (`checkout_provider.dart:742`) and
   `PlacedOrder.totalMatches` (`placed_order.dart:313`), both half a paise — wide
   enough only for floating-point dust. A wide band belongs in an **ops** report
   over historical orders, never in the sheet that asks a customer to approve a
   price.
4. **`/logistics/check-pincode`'s `shipping_charge` is not a price.** It is
   quoted from 110001 (`PinCodeDeliveryService::getPickupPostcode()` `:145`,
   `setting('logistics_pickup_postcode', '110001')` `:148`) while checkout prices
   from 311001 — a different warehouse, a different plugin, a different settings
   key (`BACKEND_BUGS.md` finding 13). Use it for deliverability + ETA only.
   ~~`lib/core/pricing/order_pricing.dart:57-58` still names it as a source for
   the delivery figure and still says "the rate of the courier the
   customer selected"~~ — **doc corrected 2026-08-04.** The doc on
   `OrderSummary.delivery` (`order_pricing.dart:48-66`) now names
   `check-serviceability` as the only source and `CourierOption.billedPrice` as
   the figure, and says explicitly that it is neither `rate` nor a
   `check-pincode` number. The same correction was applied to
   `checkoutSummaryProvider` (`checkout_provider.dart:74-84`), which described
   its `delivery` parameter the same wrong way. No code changed — both were
   comment-only defects.
5. **A miss is silent and reads as ₹0.00.** A `shipping_option` the server's
   re-quote does not contain resolves to null and the order ships free, with no
   error anywhere. That is why checkout must compare the returned total against
   the shown total before opening the payment sheet.
6. **`ShippingRates.only` is still unadopted — delete it.** Re-verified
   2026-08-04: **zero callers in `lib/`.** It reports arity ("there is exactly
   one option") so a caller could say so **without selecting it**, but nobody
   ever did, and `options.length == 1 ? options.first : null` is one keystroke
   from being the auto-select this module exists to prevent — the same shape as
   the deleted `CourierOption.best` / `ShippingRates.best`.
   It was **not** deleted in this pass only because
   `test/presentation/shipping_selector_test.dart:423-424,434` asserts on it and
   that file was out of scope. Deleting the getter and those three expectations
   is one small coordinated change. Until then it carries a loud doc
   (`shipping_provider.dart:438-460`) saying it must never gain a `lib/` caller.
7. **`codQuoted` is only ever set by `listFrom(body, cod:)`,** which
   `LogisticsRepository.serviceability(cod:)` calls with the request's own flag.
   Anything constructing a `CourierOption` outside `listFrom` — currently only
   tests — must set it explicitly, or a COD row is priced as prepaid and is short
   by `cod_charges` (₹45–70 on the live lane).

## 🧩 Product / scope notes

- **OTP login end-to-end has never run against real SMS.** The code path is real
  — `_verifyOtp` calls `authProvider.verifyOtp` → `POST /otp/verify` — but no
  authorised test number exists, so only the error paths are exercised. See
  `BLOCKED_WORK.md` §4. (The older note here claimed `_verify` never called the
  backend; that has not been true since the auth work landed.)
- **No `ios/` directory** — iOS does not build at all (not merely "untested").
  Run `flutter create --platforms=ios .` to add it.
- **Not under git** — initialise version control (see ROADMAP §9). The
  `.gitignore` correctly excludes `key.properties` and `*.jks`, but with no repo
  nothing is actually enforcing that.
- **Launcher icon + splash** are Flutter defaults.
- ~~**"Deliver to · Ahmedabad · 382415"** static placeholder~~ — **removed.** The
  header now reads a real delivery location; see
  `delivery_location_provider.dart:182`.
- ~~**Coupons** are a hardcoded client-side demo~~ — **removed.** Coupons go
  through `POST /coupon/apply` and the app renders the server's
  `applied_coupon_code` / discount. ⚠ Every *failure* path of apply and remove
  still destroys the cart server-side (`BACKEND_BUGS.md` finding 0), which is why
  the repository re-reads after each call.
- **GST is added on top, not included.** `OrderSummary.gstIncluded` carries the
  cart's own `discounted_tax_amount` and is a **misnomer kept for its two call
  sites** (`order_pricing.dart:69-86`): 899.00 + 44.95 = 943.95, verified live on
  order 282. Both `cart_screen.dart:432` and `checkout_screen.dart:965` render it
  as a plain "GST" row, which is the correct label — it is the *field name* that
  lies, not the UI. Any UI labelling that row "incl." would tell the customer the
  rows above already contain it, and the bill would then visibly fail to sum.
  Renaming the field to `gstAdded` touches those two screens; the arithmetic is
  settled and is not what is pending.
- **No deep links.** `go_router` defines `/product/:slug` etc., but the Android
  manifest has no intent filters, so none of it is reachable from outside.
- **No crash reporting or analytics.**
- **Dark mode is off.** See the Fixed table — the theme exists, the screens
  need migrating to `ColorScheme`/`TextTheme`.

## 🧾 Provenance (for context)

This is a rebuild — the original source was lost and Flutter binaries can't be
decompiled. The original was a **debug-signed** build with **no git history** and
the default `com.example.ecom` package id (a contractor's throwaway build,
templated from the "Ashop" UI kit). The recovered blueprint + live API samples in
[`../_recovered/`](../_recovered/) are the closest thing to original-source
reference — keep them.

# Roadmap & Implementation Guide

Pending work, in recommended order. Each item lists **where** to work and **how**
to approach it. Everything account-related depends on first capturing the authed
API (see [HANDOFF.md](HANDOFF.md) §4).

Legend: 🔴 blocked on authed API · 🟡 partially built · 🟢 self-contained

---

## 1. 🔴 OTP authentication  *(unblocks everything below)*
- **Files:** `presentation/screens/auth/mobile_login_screen.dart` (UI exists),
  `core/network/api_endpoints.dart` (`/auth/send-otp|verify-otp|resend-otp`
  stubbed).
- **Do:**
  1. Capture the real send/verify OTP request+response from live traffic.
  2. Add `AuthRepository` (mirror `CatalogRepository`) + models
     (`SendOtpResponse`, `VerifyOtpResponse`, `UserModel`) — names recovered in
     `_recovered/blueprint.json`.
  3. On verify success, store the **bearer token** in `SharedPreferences`; add an
     `authProvider`/`StateNotifier` exposing auth state + `UserModel`.
  4. Add a **bearer-token interceptor** to `ApiClient` (attach `Authorization:
     Bearer <token>` when present).
  5. Gate the account/orders/wishlist/address screens on auth; wire the "Sign in"
     buttons in `account_screen.dart`.

## 2. 🔴 Order placement + Razorpay checkout
- **Files:** `presentation/screens/checkout/checkout_screen.dart` (currently
  confirms locally then `clear()`s the cart), `razorpay_flutter` (dep, unused).
- **Do:**
  1. `OrderRepository.placeOrder(...)` → backend returns
     `{ razorpay_key_id, razorpay_order_id, amount, order_id }`.
  2. Import `razorpay_flutter`, open checkout with those options, handle
     success/failure/wallet callbacks.
  3. On success `POST` `razorpay_payment_id` + `signature` to confirm; then go to
     `order-success` (already built, with confetti) showing the real order id.
- **Note:** Razorpay keys are **not** hardcoded — they come from the order API.
  Android is set up; iOS needs extra Razorpay config.

## 3. 🔴 Order history & tracking
- **Files:** `presentation/screens/orders/orders_screen.dart` (empty state today).
- **Do:** `OrderRepository.orders()/orderDetails(id)/track(id)`; list + detail +
  status timeline screens. Recovered model names: `Order`, `OrderItem`,
  `OrderHistory`, `OrderInvoiceLinks`. (`OrderTracking` was removed with guest tracking.)

## 4. 🔴 Address book
- **Files:** new `presentation/screens/profile/address_screen.dart` +
  `add_address_screen.dart` (existed in the original; not rebuilt).
- **Do:** authed address CRUD; the checkout already has pincode autofill logic to
  reuse. Wire "Saved addresses" in `account_screen.dart` and a "Deliver to"
  selector in cart/checkout.

## 5. 🔴 Wishlist (persistent)
- **Files:** `presentation/widgets/product_card.dart` — the heart is currently a
  **local visual toggle only** (`_WishlistHeart`).
- **Do:** add `WishlistRepository` + `wishlistProvider` (StateNotifier, backed by
  authed API, cached locally); make the heart read/write it; build a Wishlist
  screen (consider adding it as a nav destination or under Account).

## 6. 🟡 Product variants / pack sizes
- **Context:** the original had a "Select Variant → Pack Size" bottom sheet; the
  public products API returns empty `product_options`, so variants likely live
  behind auth or a detail endpoint. `Product` already carries
  `options`/`ProductOption`/`ProductOptionValue` fields.
- **Do:** confirm where variant data comes from, then build a variant bottom sheet
  that adjusts price/selection and feeds the cart.

## 7. 🟢 Real coupons (replace demo)
- **Files:** `presentation/screens/cart/cart_screen.dart` — `_coupons` map is a
  **hardcoded demo** (`FRESH10`/`ORGANIC15`/`WELCOME50`).
- **Do:** replace with a backend coupon-validate call once available.

## 8. 🟢 Polish before release (no backend needed)
- **App icon + splash:** still Flutter defaults → add `flutter_launcher_icons` +
  `flutter_native_splash` with the Trueway logo.
- **Location bar:** the "Deliver to · Ahmedabad" text on home is a static
  placeholder → wire to the selected address once the address book exists.
- **Bundle Poppins** locally (google_fonts fetches at runtime) for offline/first-
  paint performance.
- **Push notifications:** not present (the original had none either) — add FCM if
  the business wants order updates.
- **Analytics/crash reporting:** none wired — add Firebase Crashlytics/Analytics
  if desired.
- **Tests:** there are currently no tests. Add unit tests for `price_utils`,
  `cart_provider`, and model `fromJson`, plus a few widget/golden tests.
- **Security:** move the API key off-device — see [KNOWN_ISSUES.md](KNOWN_ISSUES.md).

## 9. 🟢 Housekeeping
- The project is **not under version control** — run `git init`, add a `.gitignore`
  that **excludes `android/key.properties` and `*.jks`**, and push to the team
  repo.
- Set up CI (build + analyze + test; inject signing + API key as secrets).

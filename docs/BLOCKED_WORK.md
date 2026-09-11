# Blocked work

Features that cannot be completed or verified from the app side, kept separate
from the integration work so the rest can ship.

Each entry states what is blocked, what is blocking it, exactly what would
unblock it, and how much is already built.

---

## 1. Checkout + Razorpay payment

**Blocked by:** no Razorpay test credentials.

**Status:** not started. `checkout_screen.dart` still contains the fake:

```dart
await Future<void>.delayed(const Duration(milliseconds: 600));
context.pushReplacement('/order-success');
```

That shows a success screen for an order that was never created. It is the single
most dishonest thing in the app and it must not survive this section.

**To unblock, we need:**

1. A Razorpay **test** key id and secret, with Razorpay enabled as a payment
   method in the Botble admin.
2. Confirmation that placing test orders against `dev.truewayerp.com` is
   acceptable — the flow cannot be verified without creating real order rows.

**What can be built before then:** the request/response models and the repository
call for `POST /ecommerce/checkout/cart/{cartId}`, since the contract is known
from `CheckoutController::mobileCheckout()`. What cannot be built is the SDK
handoff and `confirm-payment` verification, because a signature that the server
will accept can only be produced by a real Razorpay transaction.

**Non-negotiable when it is built:** the success screen must appear only after
`POST /ecommerce/checkout/confirm-payment` returns 200. Never on the SDK callback
alone — the server verifies the signature and only then marks the order paid.
An app-kill mid-payment must re-check order status on next launch.

**Related defect:** the checkout endpoint *accepts* a client-supplied
`shipping_amount` and would use it for the order total and the Razorpay charge.
**The app does not send it** — it sends `shipping_method: "shiprocket"` +
`shipping_option: "shiprocket_<rateId>"` and lets the server price the order,
which is the same contract the web uses. Omitting the field is what activates
server pricing (`API/CheckoutController.php:425`). The server-side leak stays
open for other clients: `BACKEND_BUGS.md` finding 6. Contract:
`VERIFIED_API_CONTRACT.md` §4.5.

**What this means for the Razorpay work:** the shipping figure is not known
until `POST /checkout/cart/{id}` returns. `PlacedOrder.shippingAmount` and
`totalAmount` are the first news the app gets of it, and the order already exists
by then. So the reconciliation step — compare the returned total against the
total the customer was shown, and let them decline before the payment sheet
opens — is not optional polish; it is the only place a mispriced order can be
caught. `PlacedOrder.totalMatches` exists for exactly this.

---

## 2. Server-side cart go-live

**Blocked by:** `BACKEND_BUGS.md` finding 0 — `Cart::restore()` deletes the
stored cart, so any failed mutation destroys the customer's basket.

**Status:** the data layer is being built. It is deliberately **not** wired to the
UI. The app continues to use the local `SharedPreferences` cart.

**Why not just ship it:** a customer with six items who tries to add a seventh
that is out of stock loses all six. Verified live. No amount of client code can
recover items the server has already deleted — the client can only re-fetch and
show the damage.

**To unblock:** in `platform/plugins/ecommerce/src/Cart/Cart.php`

1. `restore()` should not `delete()` the row.
2. `store()` should upsert (`updateOrInsert` on `identifier`) rather than throw
   when the row exists.

Both are small. Patching individual controllers works too but leaves the next
early return to reintroduce the bug.

**What is built anyway:** `CartRepository` treats every failed mutation as
"cart state unknown" and re-fetches. That is correct behaviour regardless, and
it means the switch-over is a provider change rather than a rewrite.

---

## 3. ~~Logistics / pincode serviceability~~ — UNBLOCKED

**This entry is kept only so nobody re-reports it.** The dev Shiprocket token was
expired when this doc was written; it works now. Both routes return live courier
data, and the feature is built and wired through `LogisticsRepository`.

Verified again on 2026-08-04: `POST /logistics/check-serviceability`
(311001 → 382415, 15.2 kg) returned 4 real courier rows with live rates and ETDs.
`"Service temporarily unavailable"` did not reproduce in 12 consecutive probes.

**What is real and current** — see `VERIFIED_API_CONTRACT.md` §4:

- `check-serviceability` needs 9 client-computed fields, and the app can now
  supply all 9: the parcel comes from the cart's own `package_dimensions` +
  `total_weight`, `declared_value` is the cart's `order_total`, and the pickup
  postcode is read from `cart_options.store.zip_code` (live `311001`) with
  `kDefaultPickupPinCode` as the fallback. **Implemented, verified in source:**
  `ServerCartItem.storeZipCode` (`server_cart.dart:254`) parses it,
  `pickupPinCodeFromCart` (`shipping_provider.dart:154-164`) resolves it, and
  `checkoutParcelProvider` (`checkout_provider.dart:230`) is what the live
  screens use.
- `check-pincode` needs only `{pin_code, product_id}` and is the right call for a
  yes/no deliverability answer — but **its `shipping_charge` is priced from a
  different warehouse** (110001, not 311001) and must never be shown as a price.
  `BACKEND_BUGS.md` finding 13.
- Every upstream Shiprocket error on `check-serviceability` arrives as **HTTP
  200** with no courier list. That is an outage to retry, not "we don't deliver
  there"; `LogisticsRepository` separates the two.

**Still open, but not blocking:** `store_zip_code` has no public route, so the
311001 pickup is derived rather than read — strong evidence, 14 of 18
reconstructible orders explained, 4 unexplained. One SQL read closes it
(`BACKEND_BUGS.md` finding 11).

**What "the app tracks the cart's live store zip" does and does not buy —
corrected.** An earlier draft of this entry claimed a store move would be picked
up automatically "either way". That overstates it. The app reads **rung 2** of the
server's chain. The server's `ShipRocketService::getPickupPostcode()` (`:1715-1745`)
tries **rung 1 first**:

1. `origin.zip_code` — `EcommerceHelper::getOriginAddress()` `:1102,:1114`, i.e.
   `get_ecommerce_setting('store_zip_code')`;
2. `getStorePostcodeFromCartItems()` `:1753` — the marketplace store row, which is
   the `cart_options.store.zip_code` the app now reads;
3. `get_ecommerce_setting('shiprocket_default_pickup_postcode')` `:1735`.

So the app follows the store row, and the server follows the store row **only when
rung 1 is unset**. Both are ecommerce settings with no public route, so the app
cannot see rung 1 or rung 3 at all. Today the two agree because rung 1 is believed
empty and the store row is 311001 — but if rung 1 is ever set to a different
postcode, the app will quote one lane while the server bills another, and the
checkout divergence sheet (`TotalDivergence.tolerance = 0.005`) will fire on every
order. That is the residual risk the SQL read closes; the app-side work is done.

---

## 4. OTP login end-to-end

**Blocked by:** no test phone number authorised for real SMS.

**Status:** code complete since the earlier auth work. Contracts were verified
with safe probes (unregistered numbers, missing fields), so the error paths are
exercised. What has never run is a real OTP round-trip.

**To unblock:** a phone number we are authorised to send OTPs to, and
`setting('fast2sms_otp_login')` enabled in admin. Without the setting,
`/otp/send` returns 422 "OTP login is not enabled."

Email + password login **is** verified working and is currently the reliable
sign-in path.

---

## 5. Push notifications

**Blocked by:** a suspected backend defect — a probe reported that
`POST /device-tokens` returns 200 and persists a row, but `GET /device-tokens`
returns an empty list immediately afterwards. Not independently reproduced.

**Status:** not started. `notification_repository.dart` exists for in-app
notifications and has its own bug (see below).

**To unblock:** confirm the device-token round-trip works, and supply FCM
credentials.

---

## 6. iOS build

**Blocked by:** there is no `ios/` directory in the project.

**To unblock:** run `flutter create --platforms=ios .`, then an Apple developer
account, signing certificates and provisioning profiles. None of the integration
work is iOS-specific, but the app cannot be built for iOS at all today.

---

## 7. End-to-end proof of the order bill — **partially unblocked 2026-08-04**

**Was blocked by:** `BACKEND_BUGS.md` finding 14 — `sub_total` and `payment_fee`
were absent from both order resources, so the bill could not be made to add up.

**Server side is now unblocked.** Re-probed live today: `sub_total`,
`sub_total_formatted`, `payment_fee` and `payment_fee_formatted` are present on
**both** `GET /ecommerce/orders` and `GET /ecommerce/orders/{id}`. The identity
holds on the four representative orders on the test account:

```
order 282   899.00 + 44.95 + 324.30 +  0.00 = 1268.25 = amount   fee-free, taxed, shipped
order  14   477.00 +  0.00 +   0.00 + 10.00 =  487.00 = amount   fee-only
order  15   577.00 +  0.00 +   0.00 + 10.00 =  587.00 = amount   fee-only
order  17  7500.00 +  0.00 +   0.00 + 10.00 = 7510.00 = amount   fee-only, large
order  52   425.00 − 44.63 + 21.25 + 306.54 =  708.16 vs 708.17   ₹0.01 SERVER rounding
```

**Still blocked:** *client-side* proof. The app parses all four fields
(`Order.serverSubTotal`, `Order.paymentFee`, `Order.hasFullBreakdown`,
`Order.breakdownReconciles`) and `order_detail_screen.dart` renders the
breakdown, but **no end-to-end run has confirmed the screen renders correctly**
for each shape above — in particular order 52, where `breakdownReconciles` is
false by one paisa and the screen must say so rather than silently print a total
the rows do not sum to.

**To unblock:** run the app against the test account and inspect order detail
for 282, 14 and 52. This needs no credentials the team does not already have —
it is unblocked work that simply has not been done.

**Do not "fix" order 52 client-side.** The ₹0.01 is a genuine server rounding
artifact (`discounted_tax_amount` rounded to 2dp against a ₹44.63 discount that
scales the tax base). A bill that absorbs it quietly is worse than one that
flags it.

**Related, still open:** `shipping_option` is still absent from both order
resources (`BACKEND_BUGS.md` finding 12), so a mobile-priced order still cannot
be told from a web-priced one after the fact. That blocks rollout auditing, not
the bill.

---

## Not blocked — proceeding now

For contrast, these are being implemented against verified contracts:

| Section | Feature | Verified against |
|---|---|---|
| B | Home carousels, filters, brands | `/top-products-group` — full product shape confirmed |
| E | Server cart data layer | `CartController.php` + live probes (not wired to UI, see 2) |
| F | Server-side coupons | `/coupon/apply` + `/coupon/remove` |
| G | Address book | 6 real addresses on the test account |
| I | Order history, detail, returns | 90 real orders across 9 pages. Guest tracking was later removed from the product — no anonymous order path remains. |
| J | Wishlist, reviews | wishlist works anonymously; 2 real reviews |

---

## Summary for the client

Two things need someone other than the app developer:

1. **Razorpay test keys** — blocks the entire purchase flow, which is the point
   of the app.
2. **The `Cart::restore()` fix** — two lines; blocks the server cart from being
   safe to enable.

~~3. Shiprocket token renewal~~ — **done, no longer blocking.** Serviceability
and courier rates are live.

One five-minute answer would remove the last uncertainty from the shipping price,
though nothing is waiting on it: **what is `ecommerce_store_zip_code` in the
`settings` table?** (Admin → Ecommerce → Settings → General.) The app reads the
live store zip off the cart — rung 2 of the server's chain — and derives 311001
independently from 62 real orders; but the server checks the
`ecommerce_store_zip_code` setting **before** the store row, and no route exposes
it. An empty value confirms 311001 and the app and server agree by construction.
Any other value wins server-side and the app is quoting the wrong lane.

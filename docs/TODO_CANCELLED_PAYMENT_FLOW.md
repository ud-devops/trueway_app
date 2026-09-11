# TODO — cancelled-payment flow: interim behaviour and the permanent fix

**Status: INTERIM behaviour is live** (shipped 2026-08-14, before the client
meeting). This file is the record of what was changed, what it deliberately
gives up, and how the permanent version should be built. Do not delete it until
the permanent version ships.

---

## 1. What the interim behaviour is

When the customer dismisses the Razorpay sheet (`PaymentCancelled` from the
SDK):

1. The journal record is written as `PendingOrderStage.settled` — the app
   stops tracking the order entirely.
2. The flow state becomes the one-shot `CheckoutPhase.cancelledBackToCart`.
3. The checkout screen sees that transition, resets the flow to `idle`, and
   pops back to the **cart screen**.
4. The next "Place order" runs a completely fresh checkout POST and creates a
   **new order** for whatever the basket holds at that moment.

The customer never sees `paymentIncomplete`, never sees "Retry payment",
never sees "Start a new order". Cancel → cart → checkout again → new order.

### Where the code is

| Piece | File | Marker |
|---|---|---|
| The `PaymentCancelled` case | `lib/presentation/providers/checkout_provider.dart` | `⚠ TEMPORARY BEHAVIOUR` comment |
| The `cancelledBackToCart` phase | same file, `CheckoutPhase` enum | `TEMPORARY` doc comment |
| The pop-back listener | `lib/presentation/screens/checkout/checkout_screen.dart`, `ref.listen` in `build` | `TEMPORARY` comment |

### Why it is SAFE enough to ship

- `PaymentCancelled` is the SDK's own report that the sheet closed without a
  payment — the same evidence `PendingOrder.sheetNeverOpened` rests on. Money
  provably did not move on this path, so dropping the record does not lose a
  paid order.
- The abandoned order is harmless server-side: `status: pending`,
  `is_finished: 0`, payment `PENDING` → **invisible to the customer** (both
  order reads filter `is_finished = 1`) and it never dispatches.
- Stock was never decremented for it (that only happens at
  `processOrder`, after a confirmed payment), so nothing is reserved.

### Addendum (same day): stuck `paymentOpened` records are abandoned too

A journal record left at `paymentOpened` with **no payment triple** (app
killed/hot-reloaded while the sheet was up) used to park checkout at
`verifying` — "Order N created. We're checking whether the payment went
through" — **forever**, with no way out (seen live on order 304). Interim
decision extends to it:

- `CheckoutFlowNotifier._rehydrated`: such a record is settled and the flow
  starts blank.
- `PendingOrderRecoveryNotifier._reconcile`: same, but deliberately **after**
  the payment lookup, so an order that somehow finalised still lands on the
  `paid` branch. Records **with** a triple are untouched — those can actually
  be finished.

⚠ Permanent-solution note: this knowingly drops the safety rule "a sheet that
was open may have taken money" for the no-triple case. A customer whose UPI
debit succeeded but whose callback died gets no warning banner any more — the
order stays unfinished server-side and becomes a support case. Restore that
protection in 4b (the abandon endpoint makes it moot for genuine cancels).

## 2. What the interim behaviour deliberately gives up

These are real losses. They are acceptable for a demo, not forever.

1. **Retry-same-order is gone.** Before: a dismissed sheet could be reopened
   for the *same* Razorpay order (`retryPayment`) — no duplicate order row, no
   second coupon burn. Now every cancel-and-retry creates a fresh order row,
   a fresh Razorpay order, and (see 3) a fresh coupon use.
2. **Abandoned rows pile up in the admin panel.** Every cancelled sheet leaves
   a permanent `pending / unfinished` order row, its OrderProducts, its
   shipment row and its addresses. Customer never sees them; the admin does.
3. **A coupon can be burned per attempt.** `mobileCheckout` calls
   `Discount::afterOrderPlaced($couponCode)` (increments `total_used`) at
   order-creation time, NOT at payment time. Cancel + re-checkout with the
   same coupon = `total_used` incremented again. A limited-use coupon can be
   exhausted by cancels. (This was partially true before too — "Start a new
   order" had the same cost — but now it is the *default* path, not an opt-in.)
4. **`PaymentFailed` (named provider failure, e.g. insufficient funds) still
   goes to `paymentIncomplete`** — only a *cancel* takes the new path. So the
   "old" screen is still reachable; it is just no longer reachable by the
   common cancel route. This asymmetry is intentional (a declined card wants a
   retry with a different method, not a bounce to the cart) but worth
   re-deciding properly.

## 3. Why we could NOT do the obvious thing (delete/cancel the order)

Checked in backend source, recorded in `BACKEND_BUGS.md` §22:

- There is **no** `DELETE /orders/{id}` route at all.
- `POST /orders/{id}/cancel` exists, but `OrderHelper::cancelOrder`
  unconditionally **credits stock back** (`$product->quantity += qty`) — and
  an unfinished order never took stock (decrement only happens in
  `processOrder` after payment confirms). Calling cancel on an abandoned order
  would silently **inflate inventory** on every cancelled payment.
- `Order::canBeCanceled()` does not check `is_finished`, so nothing server-side
  stops that call from succeeding.

## 4. The PERMANENT solution (do this after the client meeting)

Two halves — one backend, one app. The backend half is the real fix.

### 4a. Backend (send `BACKEND_BUGS.md` §22 with this)

Either of these makes the flow clean; the first is better:

1. **Add an "abandon unfinished order" endpoint** — e.g.
   `POST /orders/{id}/abandon`, auth'd, guarded by
   `user_id == auth && !is_finished && payment.status == PENDING`, which:
   - sets order `status: CANCELED` (or deletes the row outright — it was never
     visible to anyone);
   - cancels the pending `Payment` row;
   - decrements the coupon's `total_used` if a coupon was on the order
     (`Discount::afterOrderCancelled` already exists and does exactly this);
   - does **NOT** touch stock (nothing was taken).
2. **Or** fix `cancelOrder`/`canBeCanceled` to gate the restock loop on
   `is_finished`, after which the app can safely call the existing
   `POST /orders/{id}/cancel` on a dismissed sheet.

Also worth asking regardless: move the coupon `total_used++` from
order-creation to payment-confirmation, so cancels stop burning coupons.

### 4b. App (once 4a exists)

In `checkout_provider.dart`, `PaymentCancelled` case:

1. Call the new abandon/cancel endpoint for `opening.orderId`.
   - On success: settle the journal, `cancelledBackToCart` exactly as today.
   - On failure (network, 4xx): still settle + pop (today's behaviour) — the
     order is invisible either way; the abandon call is cleanup, not
     correctness. Log it.
2. Delete the `⚠ TEMPORARY` markers here and in `checkout_screen.dart`, and
   the `TEMPORARY` note on `CheckoutPhase.cancelledBackToCart` — the phase
   itself stays, it is the right shape.
3. **Decide `PaymentFailed`**: probably route named provider failures through
   the same abandon+pop path for consistency, keeping only the
   unknown-outcome codes (`incompleteSuccess`, `orderMismatch`, `noResponse`)
   on the verify/support path. Product call, make it consciously.
4. Re-evaluate what is then dead code and remove it if truly unreachable:
   `retryPayment`, `canRetryPayment`, `startOver`/`canStartOver`, the
   `_startOver` dialog, the `_cartChangedHint` panel, and their tests.
   ⚠ `startOver` is still reachable today from `unresolved` (checkout POST
   never answered) — that path must survive in some form.

### 4c. Tests to restore/adjust

The interim change reworked these; the permanent version should revisit:

- `checkout_screen_test.dart`: the cancelled-sheet tests now expect a pop back
  to the cart (no order bill, no start-over). When 4b lands, add: the abandon
  endpoint is called with the right order id; a failed abandon still pops.
- The old `paymentIncomplete`-after-cancel tests were rewritten, and the
  "unpaid order explains that anything added since is not on it" hint test now
  covers only the `PaymentFailed` route — after 4b step 3, it may go entirely.

## 5. Quick verification script for the interim behaviour

1. Cart me item daalo → checkout → Place order → Razorpay sheet khulti hai.
2. Sheet band karo (back/cross).
3. **Expect:** seedha cart screen par wapas; koi "Start a new order" nahi,
   koi order panel nahi.
4. Cart me ek aur item daalo → checkout → naya total dikhta hai → Place order.
5. **Expect:** naya order, naye total ke saath; Razorpay sheet naye amount par.
6. My orders me sirf *paid* orders dikhte hain — abandoned wale kabhi nahi.

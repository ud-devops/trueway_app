# Backend defects found during mobile API integration

Found while verifying every endpoint against `https://dev.truewayerp.com/api/v1`
for the Flutter client. **These are server-side issues — the mobile app cannot
fix them.** Two cause silent data loss for the customer.

Each entry has a copy-pasteable reproduction. Replace `<API_KEY>` with the mobile
key and `<BEARER>` with a customer token.

Findings are split by how strongly they are evidenced:

- **Confirmed** — reproduced directly, with a control where one was needed.
- **Reported, not reproduced** — surfaced by an automated probe but *not*
  independently confirmed, usually because confirming it would require placing a
  real order. Treated as a question for the backend team, not an accusation.

---

## 0. CONFIRMED · ROOT CAUSE — `Cart::restore()` deletes the stored cart, so any code path that returns without `store()` destroys it

**Severity: critical. This one defect produces findings 1, 2 and 3 and every
cart-wipe symptom below.**

`platform/plugins/ecommerce/src/Cart/Cart.php`:

```php
public function restore(string $identifier): void
{
    // ... loads the serialized content into the session ...

    $this->getConnection()->table($this->getTableName())
        ->where('identifier', $identifier)->delete();   // <-- DELETES THE ROW
}
```

`restore()` is a **move, not a copy**. It loads the cart into the session and
deletes the persisted row. `store()` is what puts it back — and it is written to
insert, throwing `CartAlreadyStoredException` if the row still exists, which is
why `restore()` deletes first.

The consequence: **every early return between `restore()` and `store()`
permanently destroys the customer's cart.** The happy paths all pair them
correctly. The error paths do not.

### Confirmed unpaired paths

| File | Path | Trigger |
|---|---|---|
| `CheckoutController::process()` | never calls `store()` at all | any `GET /checkout/cart/{id}` |
| `CartController::store()` | out-of-stock / max-quantity / missing-options early returns | adding an item over stock |
| `CartController::update()` | `return ... 'Product is out of stock', 400` | raising qty over stock |
| `CartController::destroy()` | `if (! $rowId) return ... 404` | removing an item not in the cart |
| `WishlistController::destroy()` | same shape | removing a product not on the list |

### Reproduction — a failed add destroys an unrelated basket

```bash
C=$(curl -s "${H[@]}" -X POST -d '{"product_id":118,"qty":1}' $API/ecommerce/cart | jq -r .id)
curl -s "${H[@]}" -X POST -d '{"product_id":120,"qty":1}' $API/ecommerce/cart/$C > /dev/null
curl -s "${H[@]}" $API/ecommerce/cart/$C | jq '{count, lines:(.cart_items|length)}'
#   -> { "count": 2, "lines": 2 }

# Try to add an out-of-stock quantity of a THIRD product
curl -s "${H[@]}" -X POST -d '{"product_id":118,"qty":99999}' $API/ecommerce/cart/$C
#   -> {"error":true,"data":null,"message":"Maximum quantity is 93!"}

curl -s "${H[@]}" $API/ecommerce/cart/$C | jq '{count, lines:(.cart_items|length)}'
#   -> { "count": 0, "lines": 0 }      <-- both unrelated items are gone
```

A customer with six items who tries to add a seventh that is out of stock loses
all six. This is, in commercial terms, the most damaging defect in the API.

### Recommended fix

Make the persistence non-destructive rather than patching each call site:

1. `restore()` should **not** delete the row.
2. `store()` should **upsert** (`updateOrInsert` on `identifier`) instead of
   throwing when the row exists.

Patching call sites individually — wrapping each controller in `try/finally` —
works but leaves the next early return to reintroduce the bug.

### Client-side mitigation now in the app

Until this is fixed, the Flutter cart repository treats **every** failed mutation
as "cart state unknown": it re-fetches after any error and never optimistically
updates local state. That limits the damage to a visible empty cart rather than a
wrong one, but it cannot recover the lost items.

---

## 1. CONFIRMED · `GET /ecommerce/checkout/cart/{cartId}` empties the cart

**Severity: high — silent customer data loss.**

A read request destroys the resource it reads. Any client that fetches a checkout
summary before rendering a review screen — the obvious implementation — wipes the
customer's basket.

### Reproduction

```bash
API=https://dev.truewayerp.com/api/v1
H=(-H "X-API-KEY: <API_KEY>" -H "Accept: application/json" -H "Content-Type: application/json")

# 1. Create a cart with 2 units
CART=$(curl -s "${H[@]}" -X POST -d '{"product_id":118,"qty":2}' $API/ecommerce/cart | jq -r .id)

# 2. Confirm it has contents
curl -s "${H[@]}" $API/ecommerce/cart/$CART | jq '{count, items: (.cart_items|length)}'
#    -> { "count": 2, "items": 1 }

# 3. A plain GET of the checkout summary
curl -s "${H[@]}" -H "Authorization: Bearer <BEARER>" \
     -o /dev/null -w '%{http_code}\n' $API/ecommerce/checkout/cart/$CART
#    -> 200

# 4. The cart is now empty
curl -s "${H[@]}" $API/ecommerce/cart/$CART | jq '{count, items: (.cart_items|length)}'
#    -> { "count": 0, "items": 0 }
```

### Control

A second cart created identically and left untouched still reported
`count: 2, items: 1` after the same elapsed time, so this is caused by the
checkout GET and not by cart expiry.

### Root cause — confirmed in source

`CheckoutController::process()` restores the cart but never persists it back:

```php
// platform/plugins/ecommerce/src/Http/Controllers/API/CheckoutController.php
public function process(string $id)
{
    Cart::instance('cart')->restore($id);      // <-- loads it
    $cartContent = Cart::instance('cart')->content();
    // ... builds the response ...
    // NO Cart::instance('cart')->store($id);  <-- never written back
}
```

Every other method that touches a stored cart pairs the two.
`CartController::index()` is the correct pattern:

```php
public function index(string $id)
{
    Cart::instance('cart')->restore($id);
    Cart::instance('cart')->store($id);        // <-- the line that is missing
    ...
}
```

`CartController::store()`, `update()` and `destroy()` all call `store($identifier)`
before returning. Only `CheckoutController::process()` omits it — and that is
precisely the endpoint that loses the cart.

### Fix

Add `Cart::instance('cart')->store($id);` after the `restore($id)` in
`CheckoutController::process()`.

### Expected

`GET` is required to be safe and idempotent. Reading a checkout summary must not
mutate the cart.

### Mobile workaround in place

The app derives its order summary from `GET /ecommerce/cart/{cartId}`, which
returns the same pricing block, and never calls the checkout GET. This is
documented in the cart repository so nobody "fixes" it back.

---

## 2. CONFIRMED · `DELETE /ecommerce/wishlist/{id}` wipes the whole list when the product is not in it

**Severity: high — silent customer data loss.**

Deleting a valid product that is not a member of the list returns `404` — which
tells the client nothing happened — and empties the entire wishlist.

### Reproduction

```bash
# 1. Wishlist containing only product 118
WID=$(curl -s "${H[@]}" -X POST -d '{"product_id":118}' $API/ecommerce/wishlist | jq -r .id)
curl -s "${H[@]}" $API/ecommerce/wishlist/$WID | jq '.data.count'
#    -> 1

# 2. Delete product 119 — a valid product, but NOT in this wishlist
curl -s "${H[@]}" -X DELETE -d '{"product_id":119}' \
     -o /dev/null -w '%{http_code}\n' $API/ecommerce/wishlist/$WID
#    -> 404

# 3. Wishlist is now empty
curl -s "${H[@]}" $API/ecommerce/wishlist/$WID | jq '.data.count'
#    -> 0
```

Note the distinction: `product_id: 999999` (not a real product) correctly returns
`422 "The selected product id is invalid."` and does no damage. The destructive
path needs a *real* product that is *absent from the list*.

### Expected

A no-op delete should leave the list untouched, and should arguably return `204`
or `200` rather than `404`.

---

## 3. CONFIRMED · Business-rule failures return HTTP 200

**Severity: medium — high risk of incorrect client behaviour.**

Failures are split across two channels with different status codes:

| Failure | Status | Body |
|---|---|---|
| Unparseable input | `422` | `{"message":"The selected product id is invalid.","errors":{…}}` |
| Rule evaluated and rejected | **`200`** | `{"error":true,"data":null,"message":"Maximum quantity is 93!"}` |

```bash
curl -s "${H[@]}" -X POST -d '{"product_id":118,"qty":99999}' -w '\nHTTP %{http_code}\n' $API/ecommerce/cart
# {"error":true,"data":null,"message":"Maximum quantity is 93!"}
# HTTP 200

curl -s "${H[@]}" -X POST -d '{"product_id":999999,"qty":1}' -w '\nHTTP %{http_code}\n' $API/ecommerce/cart
# {"message":"The selected product id is invalid.", ...}
# HTTP 422
```

Every mainstream HTTP client — Dio, Retrofit, Axios, `fetch` — treats `200` as
success. Out-of-stock therefore reads as "added to cart" unless each caller
remembers to inspect the envelope.

### Expected

`409 Conflict` or `422` for a rejected business rule. Not a blocker if the
contract stays as-is, but it must be documented, because it is invisible.

### Handled in the app

`ApiClient` now inspects every 2xx body for `error: true` and raises the same
`ApiException` a non-2xx would produce, so repositories can keep treating a
returned response as success. Covered by
`test/core/api_client_business_error_test.dart`.

---

## 4. CONFIRMED · `error` changes type between branches

On success and on business failure, `error` is a **boolean**. On the API-key
rejection branch it is the **string** `"Unauthorized"`:

```json
{"message":"Invalid or missing API key. Please provide a valid X-API-KEY header.","error":"Unauthorized"}
```

Any strongly-typed client that decodes `error` as `bool` throws on that branch —
i.e. exactly when authentication is misconfigured and you most need a clean error.

### Expected

Keep `error` boolean everywhere and put the reason in `message`.

---

## 5. CONFIRMED · `/ecommerce/checkout/taxes/calculate` computes from client-supplied prices

**Severity: needs a backend decision — see the caveat.**

The endpoint echoes whatever price the caller sends, with no catalogue lookup.
Product 118 costs ₹899:

```bash
curl -s "${H[@]}" -X POST -d '{"products":[{"id":118,"price":899,"quantity":1}]}' \
     $API/ecommerce/checkout/taxes/calculate
# ... "subtotal":899,  "tax_amount":44.95,  "total":943.95

curl -s "${H[@]}" -X POST -d '{"products":[{"id":118,"price":1,"quantity":1}]}' \
     $API/ecommerce/checkout/taxes/calculate
# ... "subtotal":1,    "tax_amount":0.05,   "total":1.05
```

### Caveat — this may be fine

If this endpoint is only a stateless calculator ("what is the tax on these
numbers?") and order totals are always taken from the server-side cart, there is
no exploit: `GET /ecommerce/cart/{id}` prices product 118 at ₹899 from the
catalogue, independent of anything the client sends.

**The question for the backend team is narrow: does any order-creating path ever
trust a total derived from this endpoint?** If not, this is a naming/documentation
issue. If so, it is a price-tampering vulnerability.

The mobile app takes all totals from the cart response and does not call this
endpoint.

---

## 6. CONFIRMED IN SOURCE · `shipping_amount` is taken from the client and used for the order total and the Razorpay charge

**Severity: medium — revenue leak. Deliberate, but exploitable.**

`CheckoutController::mobileCheckout()` uses the client's value when present:

```php
// Client may send shipping_amount (e.g. selected courier rate from shipping API).
// If present, it is used for order total + Razorpay; ...
$useClientShippingAmount = $request->has('shipping_amount');
...
$shippingAmount = max(0, (float) $request->input('shipping_amount'));
...
'shipping_amount' => (float) $shippingAmount,   // written to the order
```

The comment shows this is intentional — the courier rate is fetched client-side
from the shipping API, so the client is the one that knows it.

> **The mobile app does not use this branch and never has, in shipped code.** It
> sends `shipping_method: "shiprocket"` + `shipping_option: "shiprocket_<rateId>"`
> and **omits `shipping_amount` entirely**, which is exactly what leaves
> `$useClientShippingAmount` false and lets the server price the order (`:425`,
> `:445-446`). See `VERIFIED_API_CONTRACT.md` §4.5. This finding therefore stays
> open as a **server-side** revenue leak — any other client can still exploit it —
> but nothing in this app depends on it, and re-adding the field would silently
> switch the app back onto the client-trusted branch.

**The exposure is bounded but real.** `max(0, …)` blocks negative values, and
line-item prices come from the server-side cart, so an order cannot be made free.
But any client can send `"shipping_amount": 0` and pay nothing for delivery, on an
order that is otherwise legitimate. On the observed data — 62 of 90 orders ship
via ShipRocket with amounts up to ₹330 — that is a straightforward loss per order.

### Recommended fix

Re-derive the shipping cost server-side from the chosen `shipping_method` and
`shipping_option` and ignore the client's number, or accept the client's quote
only after validating it against a server-issued quote token.

### Correction to an earlier claim

An automated probe originally flagged this as unconfirmed and I reported it that
way. Reading the source settles it: the behaviour is real and intentional. Note
this is a *different and lesser* issue than the one in finding 5 — product prices
are never client-trusted, only the shipping line is.

---

## 7. REPORTED, NOT REPRODUCED · `POST /device-tokens` persists but `GET /device-tokens` returns empty

A probe reported that a token POSTed successfully (HTTP 200, row id returned) is
absent from a subsequent GET. If accurate, push notification registration cannot
be verified or de-registered, which blocks push as a feature.

---

## 7b. CONFIRMED IN SOURCE · `POST /ecommerce/cart/refresh` is unreachable — route ordering

**Severity: medium — a declared endpoint that silently does the wrong thing.**

`platform/plugins/ecommerce/routes/api.php`:

```php
Route::post('cart', [CartController::class, 'store']);
Route::post('cart/{id}', [CartController::class, 'store']);      // line 84
...
Route::post('cart/refresh', [CartController::class, 'refresh']); // line 89 — never reached
```

Laravel matches in registration order, so `POST cart/refresh` binds
`{id} = "refresh"` and hits `store()`. It does not 404 — it **creates a cart whose
identifier is the literal string `"refresh"`**, then fails validation because the
body has `products[]` rather than `product_id`/`qty`.

```bash
curl -s "${H[@]}" -X POST -d '{"products":[{"product_id":118,"quantity":1}]}' \
     $API/ecommerce/cart/refresh
#   -> 422 errors.product_id ["The product id field is required."]
```

`CartController::refresh()` is dead code as routed.

### Fix

Move the `cart/refresh` declaration **above** `cart/{id}`, or constrain the
parameter: `->where('id', '[0-9a-f-]{36}')`.

### Consequence for the app

The plan's Section E3 assumed a bulk-sync call to migrate existing local carts to
the server in one request. There is no such endpoint, so migration has to add
items one at a time — and given finding 0, each of those adds can fail
destructively. The migration is therefore deferred until finding 0 is fixed.

---

## 8. Data-quality issues (not bugs, but they shape the client)

These are all confirmed and each forces defensive handling in the app.

| # | Finding | Consequence |
|---|---|---|
| 8.1 | `user_avatar` and `/me` `avatar` are returned as inline base64 `data:` URIs, ~3.9 KB per review, and **re-encoded per request** (3,259–4,003 bytes across 5 identical calls) | Uncacheable; 45–69% of a reviews payload is avatar bytes. Needs a URL, not an embedded image. |
| 8.2 | `GET /ecommerce/products/{slug}/reviews` has **no pagination metadata** — no `meta`, `total` or `last_page`. The only count is inside an English sentence in `message`: `"2 review(s) for \"Product Name\""` | A client must regex-parse prose to paginate. |
| 8.3 | Order `code` uses **two incompatible formats** in one list: `SF10000277` (id ≥ 61) and `#SF-10000016` (id ≤ 57) | Prefixing `#` in the UI renders `##SF-10000016`. |
| 8.4 | `status_html`, `payment_status_html`, `shipping_status_html` serialize to `{}` on every order, or `""` on 7 of 90 | Dead fields that force a union type. Should be removed or populated. |
| 8.5 | Address `state` and `city` hold **numeric ids on some rows and free text on others** (`"11"` / `"Madhya Pradesh"`), and there is **no `/states` or `/cities` endpoint** to resolve the ids | The client cannot render a stored address reliably, nor build a correct picker. |
| 8.6 | `POST /ecommerce/addresses` requires `{name, phone}`; `PUT` on the same resource requires `{name, email, phone, country, state, city, address}`, and `max` differs (191 vs 255) | An address that can be created cannot be edited without adding fields. |
| 8.7 | Address `phone` enforces `^[6-9][0-9]{9}$`, but checkout's `address.phone` is `max:20` free text | A phone that passes checkout is rejected by the address book. |
| 8.8 | `country`/`state`/`city` have no `exists` rule — `country: "ZZ-NOT-A-COUNTRY"` is accepted | Garbage addresses are storable. |
| 8.9 | `GET /ecommerce/orders?per_page=-5` returns **HTTP 500** | Should be a 422. |
| 8.10 | `meta.links[]` ellipsis entries omit the `page` key entirely | A non-optional decoder crashes at `per_page=1`. |

---

## 9. CONFIRMED IN SOURCE · `shipping_method: "default"` can never resolve a price — `Arr::get($filtered, null)` returns the whole map

This is the defect behind "mobile orders ship free". It is **not** caused by missing
shipping rules, and it is worth correcting because the conclusion drawn from it —
that mobile cannot charge shipping at all — is wrong.

`HandleShippingFeeService::execute()` builds a grouped map, then:

```php
// HandleShippingFeeService.php:68
$response = Arr::get($filtered, $option);   // $option is null when the caller sent no shipping_option
// :70
return $response ? [$response] : [];
```

`Arr::get()` with a null key returns the **entire array**
(`vendor/laravel/framework/src/Illuminate/Collections/Arr.php:486-488`). So the
result is one level too deep:

```
[ [3 => ['name' => 'Local Pickup', 'price' => 0.00],
   2 => ['name' => 'Flat Rate',    'price' => 20.00]] ]
```

`CheckoutController.php:443` takes `Arr::first(...)` of that, and `:446`
`Arr::get($shippingMethod, 'price', 0)` finds no `price` key at that level and
falls through to its `0` default. `:490` persists `shipping_amount = 0.00`.

**The answer is 0.00 whether or not shipping rules exist**, which is why the
"`ec_shippings` = 0" explanation reached the right number by the wrong route.
(For the record the real table is `ec_shipping`, singular, and the only on-disk
dump — `database.sql:2749`, Sep 2025 — has 1 row in it and 3 in
`ec_shipping_rules`.)

### What actually works

`("shiprocket", "shiprocket_<rateId>")` resolves correctly — it is the exact pair
the **web** checkout POSTs:

| step | source | key |
|---|---|---|
| group | `logistics/HookServiceProvider.php:59` `$result['shiprocket'] = $serviceabilityRates` | `"shiprocket"` |
| group lookup | `HandleShippingFeeService.php:58` `Arr::get($result, $method, [])` | selected by `shipping_method` |
| member | `ShipRocketService.php:1889` `'shiprocket_' . $rateId`, where `:1870` `$rateId = Arr::get($courier, 'id')` | `"shiprocket_1016317372"` |
| member lookup | `HandleShippingFeeService.php:68` `Arr::get($filtered, $option)` | selected by `shipping_option` |
| price | `ShipRocketService.php:1894` `'price' => $totalCost` | read by `CheckoutController.php:445-446` |

Note `$rateId` is Shiprocket's **rate `id`**, not `courier_company_id`. Verified
stable across repeated identical calls, and it changes when the delivery pincode
changes.

And note what `$totalCost` is. `ShipRocketService.php` reads four components with
`(float) Arr::get($courier, …, 0)` — `:1874` `freight_charge`, `:1875`
`coverage_charges`, `:1876` `cod_charges`, `:1877` `other_charges` — then `:1880`
`$baseShippingCost = freight + coverage`, `:1883` `$totalCost = base + other`, and
`:1884-1885` adds `cod_charges` only when `isCodOrder($originalData)` (a property
of the **request**, not the row). `:1894` stores that as the entry's `price`, and
`API/CheckoutController.php:446` reads it as the order's shipping amount with
`:462` adding it to the total. It **never reads the row's `rate` field**.

Live 2026-08-04, pickup 311001 → delivery 382415, 5.0 kg 20×7×49, `qc_check` 0,
`cod` 0, varying only `declared_value`: at **2400** every row had
`coverage_charges: 0` and `rate` equalled the sum (Xpressbees Surface 5kg, 272.06
both ways); at **2500** every row had `coverage_charges: 49.00`, so the server
billed **321.06** where `rate` said 272.06 — **₹49.00 low**. The same step
reproduces at 10 kg (`declared_value` 314 → 741.32 both ways; 3108 → billed
790.32 vs `rate` 741.32). Any client that displays `rate` under-quotes by exactly
the coverage line, and `declared_value` is the basket's own `order_total`, so the
gap opens on every basket past roughly ₹2,500.

`rate` matching the sum on small baskets is **coincidence**: `rate` is
`freight_charge` on a prepaid quote and `freight_charge + cod_charges` on a COD
one, and it never carries `coverage_charges` or `other_charges`. Real order 275
(`declared_value` 3108) was billed **802.12** against a 741.32 quote — 49.00 of
that gap is the coverage line, the residual 11.80 is the uniform rate-card drift
described in finding 11, **not** `other_charges` (an order record stores
`shipping_amount` as one number and never breaks it into components, so no order
can evidence a particular component). `other_charges` has been zero on every row
of every capture; it is in the formula at `:1877`/`:1883` and must be summed
regardless, because the day it stops being zero nothing announces the change.

The mobile app was fixed to sum the components (`CourierOption.billedPrice`); this
note stays because the shape of the payload — a prominent `rate` field that is
right most of the time — invites the same mistake from any other client.

### Live orders confirm shipping is being charged today

`GET /ecommerce/orders?per_page=20` on the test account: **18 of the last 20**
carry `shipping_method: "shiprocket"` with amounts ₹147.36, ₹272.06, ₹326.31,
₹330.20, ₹340.36, ₹521.82, ₹741.32, ₹753.12, ₹802.xx …

Order 277 reconciles exactly: `sub_total 899.00 + tax_amount 44.95 + shipping_amount 330.20 = amount 1274.15`.

### Fix

Pass the option through, or short-circuit when it is null:

```php
$response = $option === null ? null : Arr::get($filtered, $option);
```

Better still, make the miss **loud**. The web throws a `ValidationException` in
this situation (`PublicCheckoutController.php:743-750`); the mobile API degrades
silently to a free-shipping order. Silent zero is the dangerous behaviour, not
the missing rule.

---

## 10. CONFIRMED IN SOURCE · A free-shipping coupon zeroes shipping **after** the client override

```php
// CheckoutController.php:455
if ($useClientShippingAmount) { $shippingAmount = max(0, (float) $request->input('shipping_amount')); }
// :459
$shippingAmount = Arr::get($sessionData, 'is_free_shipping') ? 0 : $shippingAmount;
```

Correct precedence, but it means the order total can legitimately come back
**lower** than any figure the client displayed. Any client that shows a total
before calling checkout must re-read `data.total_amount` rather than assume its
own arithmetic held. Worth stating explicitly in the integration guide.

---

## 11. `store_zip_code` is not exposed, and it decides whether the rate is right

**Still true, still not exposed — but no longer blocking.** The value was derived
from live data instead. Recording both halves so nobody re-runs the work.

### The chain

`ShipRocketService::getPickupPostcode()` (`:1715`) resolves the pickup postcode in
three steps:

1. `origin.zip_code` — `EcommerceHelper::getOriginAddress()` `:1102,1114`, i.e.
   `get_ecommerce_setting('store_zip_code')` → the settings row
   `ecommerce_store_zip_code`;
2. failing that, `getStorePostcodeFromCartItems()` `:1753` — the **marketplace
   store** row for the first cart product, whose `zip_code` is live **`311001`**;
3. failing that, `get_ecommerce_setting('shiprocket_default_pickup_postcode')`
   `:1735`.

**No public route returns step 1.** `/ecommerce/settings` returns only user
prefs; `/ecommerce/store`, `/ecommerce/shipping-settings`,
`/ecommerce/store-locators`, `/ecommerce/warehouse`, `/site-info`,
`/general-settings`, `/marketplace/stores` all 404.

### What the derivation found: **311001** (Bhilwara), confidence strong

Reconstructed 62 real shiprocket orders and re-quoted each against
`check-serviceability` varying only `pickup_postcode` — 4 named candidates, then
35 pincodes spanning India. **5 orders match to the paisa at 311001 and nowhere
else**; 9 more match a uniform rate-card revision; **0 match from any Gujarat
pincode** (382415 and 380049 quote 45–70 % low, so the store's Ahmedabad-area
*delivery* region is decisively excluded). 4 of 18 are unexplained at every
candidate and are reported as misses. Full method, evidence and caveats:
`VERIFIED_API_CONTRACT.md` §4.5.

Note step 2 means **311001 is also what the server falls back to structurally**
when `store_zip_code` is unset — the marketplace store row and the derived value
agree.

### What the app now does — step 2 only

**The app has stopped hardcoding the pickup postcode.** It reads **step 2** off
the cart: `ServerCartItem.storeZipCode` parses
`cart_items[*].cart_options.store.zip_code`, `pickupPinCodeFromCart` resolves the
basket to one postcode, and `checkoutParcelProvider` feeds it to
`check-serviceability`. `kDefaultPickupPinCode` keeps its value `'311001'` but is
now only the fallback — empty cart, no store block, a zip failing the six-digit
rule, or a basket spanning two stores that disagree.

**Steps 1 and 3 remain unreachable from any client.** Both are ecommerce settings
with no public route, and the server checks **step 1 before step 2**. So the app
and the server agree only while `store_zip_code` is unset. If it is ever set to
something other than 311001, the app quotes one lane and the order is billed from
another, on every order — and the app's checkout divergence sheet (tolerance
`0.005`) will fire each time. This is the one open backend dependency in the
shipping price.

### Ask — now narrow enough to answer in one line

```sql
SELECT value FROM settings WHERE `key` = 'ecommerce_store_zip_code';
```

(or Admin → Ecommerce → Settings → General). Empty confirms 311001 via the
fallback chain and confirms the app is on the right lane. **Any other value wins**
server-side — and the fix then is *not* to edit `kDefaultPickupPinCode`, which is
only the empty-cart fallback now.

**The durable fix, and the actual ask:** return the resolved pickup postcode on
the cart response next to `package_dimensions`, or expose a read-only settings
endpoint carrying `store_zip_code` and `shiprocket_default_pickup_postcode`. Then
no client has to derive, guess or fall back at all.

---

## 12. `shipping_option` is absent from both order resources — **STILL OPEN**

> **Re-verified live 2026-08-04: still missing from both routes.** The same pass
> that closed finding 14 (`sub_total` / `payment_fee` are now exposed on
> `GET /ecommerce/orders` and `GET /ecommerce/orders/{id}`) did **not** add
> `shipping_option`. It is absent from all 91 orders on the list route and from
> every detail response probed. This ask stays open and is unchanged below.

`OrderResource.php:45-47` and `OrderDetailResource.php:32-34` expose
`shipping_amount`, `shipping_amount_formatted` and `shipping_method` — but never
`shipping_option`.

Consequence: an order that shows `shipping_method: "shiprocket"` does not say
**which rate** priced it, or whether the client supplied the number or the server
computed it — the two branches at `CheckoutController.php:425` are
indistinguishable after the fact. That blocks exactly the reconciliation you want
while rolling mobile checkout out, and it is what makes a silent ₹0.00 (finding 9)
un-auditable from the API. Adding the field is a one-line change.

---

## 13. `/logistics/check-pincode` prices from a different warehouse than checkout

**Severity: medium — a rupee figure on a customer-facing screen that no order
will ever match.**

Two plugins, two settings keys, two defaults, and neither reads the other:

| | resolves pickup from | value today |
|---|---|---|
| `check-pincode` | `PinCodeDeliveryService::getPickupPostcode()` `:145-148` → `setting('logistics_pickup_postcode', '110001')` | **110001** (Delhi) |
| checkout + `check-serviceability` | `EcommerceHelper::getOriginAddress()` `:1102,1114` → `get_ecommerce_setting('store_zip_code')`, then the marketplace store's zip | **311001** (Bhilwara) |

Confirmed empirically as well as from source: check-pincode's exact parcel was
replayed through `check-serviceability` across 8 candidate pickups, and for
products 117 and 119 its (courier, `rate`, `etd`) triple reproduced **only at
110001**.

So `check-pincode`'s `shipping_charge` is a real number from a real courier — for
a warehouse the customer will not be billed against.

**Fix:** point `PinCodeDeliveryService` at the same origin as checkout, or drop
`shipping_charge` from its response so nobody can display it.

**Client mitigation in place:** the app uses check-pincode for the yes/no
deliverability answer only, and takes every rupee figure from
`check-serviceability`.

---

## 14. ~~`sub_total` and `payment_fee` are missing from both order resources, so an order bill cannot be shown~~ — **RESOLVED**

> **RESOLVED server-side, verified live 2026-08-04.** All four fields are now
> present on **both** order routes. Re-probed on the test account today:
>
> ```
> GET /ecommerce/orders          (OrderResource)        n=91
>   keys now include: sub_total, sub_total_formatted,
>                     payment_fee, payment_fee_formatted
> GET /ecommerce/orders/{id}     (OrderDetailResource)  same four, plus
>                     discount_amount
>
> order 282   sub 899.00  + tax 44.95 + ship 324.30 + fee  0.00 = 1268.25 = amount  OK
> order  14   sub 477.00  + tax  0.00 + ship   0.00 + fee 10.00 =  487.00 = amount  OK
> order  15   sub 577.00  + tax  0.00 + ship   0.00 + fee 10.00 =  587.00 = amount  OK
> order  17   sub 7500.00 + tax  0.00 + ship   0.00 + fee 10.00 = 7510.00 = amount  OK
> ```
>
> The three ₹10.00 gaps below are closed: each was the invisible `payment_fee`,
> and it is now visible and correct.
>
> **One gap is not closed, and is not a client bug.** Order 52 still computes
> `max(425.00 − 44.63, 0) + 21.25 + 306.54 + 0.00 = 708.16` against
> `amount 708.17` — a ₹0.01 **server-side** rounding artifact, because
> `discounted_tax_amount` is rounded to 2dp against a discount that scales the
> tax base. It must not be papered over client-side; a bill that silently
> absorbs a penny is a bill that will silently absorb a rupee.
>
> **Two residues worth noting, neither blocking:**
> - `discount_amount` is exposed by `OrderDetailResource` but **not** by
>   `OrderResource`, so the list route still cannot reconcile a discounted order
>   on its own. Detail can.
> - Finding **12 (`shipping_option`) is still open** — re-verified absent from
>   both routes in the same probe. The one-pass fix suggested below only
>   happened for half of it.
>
> Original report retained below.

**Severity: medium — the app cannot render a bill that adds up, and on 3 real
orders it is short by ₹10.00 each.**

Both columns already exist and are already fillable. Only the API resources omit
them:

| column | migration | `Order::$fillable` | in the API |
|---|---|---|---|
| `sub_total` | `2020_03_05_041139_create_ecommerce_tables.php:202` | yes (`Order.php:41`) | **no** |
| `payment_fee` | `2025_04_12_000001_add_payment_fee_to_ec_orders_table.php:12` | yes (`Order.php:37`) | **no** |

The documented identity is:

```
amount = max(sub_total − discount_amount, 0) + tax_amount + shipping_amount + payment_fee
```

The client is handed four of those six terms. With no `sub_total` it must infer
one from `Σ products[].total`, and with no `payment_fee` the last term is simply
invisible.

### Measured across all 90 orders on the test account

Computing `Σ products[].total − discount_amount + tax_amount + shipping_amount`
and comparing to `amount`:

```
86 of 90 reconcile exactly

order 14  #SF-10000014   lines 477.00   computed  477.00   actual  487.00   GAP +10.00
order 15  #SF-10000015   lines 577.00   computed  577.00   actual  587.00   GAP +10.00
order 17  #SF-10000017   lines 7500.00  computed 7500.00   actual 7510.00   GAP +10.00
order 52  #SF-10000052   lines 425.00   computed  708.16   actual  708.17   GAP  +0.01
```

The three ₹10.00 gaps are the invisible `payment_fee` term. Order 52's ₹0.01 is
the discount/tax scaling rounding — `discounted_tax_amount` is rounded to 2dp
against a ₹44.63 discount, which `Σ lines` cannot reproduce.

That the other 86 reconcile is luck, not correctness: `Σ products[].total`
happens to equal `sub_total` only while nothing unusual occurred. Per the money
model, `ec_orders.discount_amount` stores the **unclamped** discount while
`sub_total` is floored at zero before the tax is scaled — so an over-large coupon
breaks the inference outright.

### Fix — four lines, no migration

In **both** `OrderResource.php` and `OrderDetailResource.php`:

```php
'sub_total' => $this->sub_total,
'sub_total_formatted' => format_price($this->sub_total),
'payment_fee' => $this->payment_fee,
'payment_fee_formatted' => format_price($this->payment_fee),
```

Same call as finding 12 (`shipping_option`), same two files — worth doing in one
pass. **Done for these four fields on 2026-08-04; not done for
`shipping_option`, which remains open as finding 12.**

### Client state today

**Updated 2026-08-04.** The app parses all four fields
(`Order.serverSubTotal`, `Order.paymentFee`, `Order.hasFullBreakdown`,
`Order.breakdownReconciles`) and the order-detail bill renders the full
breakdown rather than omitting the subtotal row. The three ₹10.00 discrepancies
are gone.

What is still outstanding is **client-side proof**, not server data: no
end-to-end check has confirmed the detail screen renders the breakdown correctly
for all four shapes (fee-only, tax+shipping, discounted, and the ₹0.01
non-reconciling order 52). See `BLOCKED_WORK.md`.

---

## 15. CONFIRMED · `max_cart_quantity` is not enforced on `PUT`, and the `POST` refusal quotes the wrong number

**Severity: high — an order can be placed for more units than the product allows.**

Both halves verified live on 2026-08-11 against product **125**, which the same
API reports as `max_cart_quantity: 3`, `quantity: 85558`.

### 15a — `PUT /ecommerce/cart/{id}` ignores the cap entirely

```bash
CART=$(curl -s "${H[@]}" -X POST -d '{"product_id":125,"qty":1}' $API/ecommerce/cart | jq -r .id)

curl -s "${H[@]}" -X PUT -d '{"product_id":125,"qty":3}'  $API/ecommerce/cart/$CART   # -> qty 3   OK
curl -s "${H[@]}" -X PUT -d '{"product_id":125,"qty":4}'  $API/ecommerce/cart/$CART   # -> qty 4   OK  <-- over the cap
curl -s "${H[@]}" -X PUT -d '{"product_id":125,"qty":50}' $API/ecommerce/cart/$CART   # -> qty 50  OK  <-- 16x the cap
```

The last response is a normal cart body — HTTP 200, no `error`, `count: 50` —
and the line it returns still states `"max_cart_quantity": 3` beside a quantity
of 50.

`POST /ecommerce/cart` *does* check. `PUT` does not, and `PUT` is the verb a
quantity stepper uses.

**Consequence:** nothing server-side stops an over-limit basket from reaching
checkout. Until this is fixed the mobile client's own cap is the only thing
enforcing `maximum_order_quantity` at all, and any other client — or a replayed
request — bypasses it.

### 15b — the `POST` refusal names the stock level, not the cap

```bash
curl -s "${H[@]}" -X POST -d '{"product_id":125,"qty":99999}' $API/ecommerce/cart/$CART
# {"error":true,"data":null,"message":"Maximum quantity is 85558!"}
```

`85558` is `quantity`. The cap is `3`, and the very same payload says so. So the
one sentence a client could show the customer contradicts the field the client
was told to trust.

This is why the app does **not** forward this message. It builds its own from
`max_cart_quantity` — showing the server's would tell a customer they may buy
85,558 of something limited to 3.

### Fix

1. Apply the same `max_cart_quantity` check in `CartController::update()` that
   `store()` already performs.
2. Build both messages from `$product->max_cart_quantity` rather than
   `$product->quantity`.

Worth doing together: (2) alone would still let `PUT` through silently, and (1)
alone would start refusing with a number that names the wrong limit.

### Client state today

The app caps both steppers at `max_cart_quantity` and floors them at
`min_cart_quantity`, and explains the stop in its own words. That is a guard,
not a fix — it protects this client only.

---

### RE-VERIFIED 2026-08-11 — partly fixed, two holes remain

**15b is fixed.** The refusal now names the cap:

```
Sorry, you can only order a maximum of 3 units of Trueway Farms Organic
Finger Millet (ragi) 1.85 Kg at a time. Please adjust the quantity and try again.
```

**15a is fixed for the update path.** With a fresh cart per attempt on product
125 (`max_cart_quantity: 3`):

```
PUT qty=2    -> accepted
PUT qty=3    -> accepted
PUT qty=4    -> 422 refused
PUT qty=50   -> 422 refused
PUT qty=999  -> 422 refused
```

#### ❌ Hole A — `PUT` bypasses the check when the product is not already in the cart

`PUT` **adds** a line when `product_id` is absent from the cart (documented in
the integration guide), and that branch is not checked:

```bash
CART=$(… POST product 118 …)                       # cart holds 118 only
curl -s "${H[@]}" -X PUT -d '{"product_id":125,"qty":50}' $API/ecommerce/cart/$CART
# -> 200. Cart now holds product 125 at qty 50, and the line it returns
#    still says "max_cart_quantity": 3
```

One request, no refusal, cap exceeded 16×. The same check `update()` now runs
for an existing line needs to run on the add branch too.

#### ❌ Hole B — the refusal destroys the cart

This is finding 0 again, and the new check **widened** it: before, `PUT` never
refused for quantity, so this path could not wipe.

```bash
CART=$(… POST product 125 qty 1 …)
curl -s "${H[@]}" -X PUT -d '{"product_id":125,"qty":99}' $API/ecommerce/cart/$CART   # 422
curl -s "${H[@]}" $API/ecommerce/cart/$CART | jq .count
# -> 0        the customer's item is gone
```

The new `return` sits between `Cart::restore()` and `Cart::store()`, so adding
it added one more way to lose a basket. Wrapping the controller in
`try/finally`, or making `restore()` non-destructive as finding 0 recommends,
fixes this and every sibling at once.

#### A note on the envelope

The refusal is a **third** response shape for this API:

```json
HTTP 422
{"error": "Sorry, you can only order a maximum of 3 units …"}
```

`error` carries the **message** here, where the cart's business failures use
`{"error": true, "message": "…"}` and validation uses `{"message", "errors"}`.
The app reads all three, but a fourth client would reasonably miss this one.
Worth converging on one shape.

---

## Priority

| Priority | Items |
|---|---|
| Fix before launch | 1, 2 — both silently destroy customer data; **9** — silent ₹0.00 shipping |
| Answer before launch | 5, 6 — confirm no order path trusts a client-supplied price; **11** — one SQL read on `ecommerce_store_zip_code` |
| Fix or document | 3, 4, 10, **12** (still open — same two files as the resolved 14), **13**, 8.5, 8.6, 8.7 — each forces defensive client code |
| Backlog | 7, 8.1–8.4, 8.8–8.10 |
| ✅ Resolved | **14** — `sub_total` / `payment_fee` now live on both order resources, verified 2026-08-04 |

### Correction to the mobile integration guide

**Do not edit `docs/MOBILE_API_INTEGRATION_PLAN.md` — it is the backend team's
document.** Contradictions with what we verified are recorded here instead.

The plan doc states that shipping is `0.00` on every mobile order, that
`check-serviceability` is display-only, and that no
`(shipping_method, shipping_option)` pair can resolve. **All three are wrong**, and
finding 9 plus the live order data above show why:

- the `0.00` is real but is a *bug with a two-line fix*, not a property of mobile
  checkout — `Arr::get($filtered, null)` returning the whole array;
- `("shiprocket", "shiprocket_<rateId>")` resolves correctly and is the exact pair
  the **web** checkout POSTs;
- 62 of 90 live orders carry `shipping_method: "shiprocket"` with a non-zero
  amount, so shipping is demonstrably being charged today.

It also asks (open question 5) whether the app sends `shipping_amount`. **It does
not, and that is settled.** The app sends `shipping_method` + `shipping_option`
only. Omitting `shipping_amount` is precisely what activates server pricing
(`CheckoutController.php:425`, `:445-446`); sending it — even as `null` — would
switch the order back onto the client-trusted branch (`$request->has()` is true
for an explicit `null`, and `API/CheckoutRequest.php:79` is
`['nullable','numeric','min:0']`, so a null passes validation and still flips the
switch). The field remains client-trusted with no ceiling (finding 6), which is
why the app declines to use it.

The backend's own API description says the same thing —
`API/CheckoutRequest.php:188`:

> *"Shipping fee from client (e.g. selected courier rate). If omitted, server
> calculates from `shipping_option` when shipping is available."*

Two further status updates against the plan doc, neither of which is a
contradiction — both are items it left open and the app has since closed:

- its note that "rung 2 of `getPickupPostcode()` is therefore implementable
  client-side" is now **implemented**: the app reads
  `cart_items[*].cart_options.store.zip_code` and only falls back to a constant.
  Rungs 1 and 3 remain unreachable — see finding 11;
- the courier price the app quotes is the **sum** of `freight_charge`,
  `coverage_charges` and `other_charges` (plus `cod_charges` on a COD quote), not
  the row's `rate`. Any other client reading that payload should do the same —
  see finding 9.

Full contract: `VERIFIED_API_CONTRACT.md` §4.5.

---

## 15. CONFIRMED IN SOURCE · `PUT /me` lets two customers share a phone number, and OTP sign-in then picks one of them

`ProfileController::updateProfile` validates `phone` as
`['nullable', 'string', ...BaseHelper::getPhoneValidationRule(true)]` —
format only. **There is no `unique` rule**, unlike `email` two lines below it,
which carries `unique:ec_customers,email,{id}`.

`OtpController::send` then resolves a login by number:

```php
// platform/plugins/uminber/src/Http/Controllers/API/OtpController.php:57
$customer = Customer::where('phone', $request->input('phone'))->first();
```

`->first()` means the lowest id wins. So a customer who changes their number to
one that already belongs to another account:

- can no longer sign in by OTP — the code goes to the *other* customer;
- has no way back, because OTP is the primary sign-in for the mobile app and
  `/password/forgot` needs an email they may not have set;
- and the new number was never verified, so a typo has the same effect.

Nothing warns about this server-side; the write succeeds with a 200.

### Fix

Add `Rule::unique(ApiHelper::getTable(), 'phone')->ignore($userId)` alongside the
existing format rules, matching how `email` is already handled in the same
validator. A verification step on the new number would be better still, but
uniqueness alone removes the lockout.

### Client-side mitigation now in the app

The profile screen renders the phone **locked** — it is displayed but not
editable. A warning was the most the app could offer (no endpoint exposes
whether a number is already taken), and a warning the customer can click through
still ends in a lockout. Email is locked alongside it: same absence of
verification, and it is the password-reset channel. A genuine change goes
through support until this is fixed.

### Related, same controller, lower severity

- **Four validated fields do not exist.** `first_name`, `last_name`, `gender`
  and `description` are validated, then dropped by `fill()` — `ec_customers` has
  no such columns and `Customer::$fillable` does not list them. `UserResource`
  reads them straight back as null. Either add the columns or stop advertising
  the fields.
- **422s carry no field map.** The controller answers
  `setError()->setCode(422)->setMessage('Data invalid! ' . implode(' ', $errors))`
  — one concatenated string, no `errors` object. Every other validated endpoint
  on this API returns field-keyed errors, so a client cannot attach "the email
  has already been taken" to the email box and has to re-implement the rules
  locally to get useful messages.
- **`dob` cannot be cleared.** It is applied under
  `if (! empty($data['dob']))`, so once set there is no route that unsets it.
- **`dob` is a date sent as an instant, and it reads back a day early.**
  `UserResource` hands the `date`-cast Carbon to the encoder, which serialises
  midnight *in the store's timezone* as UTC. With `time_zone` set to
  `Asia/Kolkata`, a birthday of 28 Aug 2026 goes out as
  `2026-08-27T18:30:00.000000Z`; any client that reads the UTC calendar day off
  it shows the 27th. Sending `dob` as a bare `Y-m-d` string would remove the
  ambiguity for every consumer. The app works around it by rounding the instant
  to the nearest midnight.

---

## 16. CONFIRMED · `min_price` / `max_price` filter on a price the API never shows

**Severity: medium — any price filter built on it looks broken.**

`GetProductService` passes `min_price`/`max_price` straight through to the
product query, but the column they compare against is not the `price` that
`AvailableProductResource` returns.

### Reproduction

```bash
API=https://dev.truewayerp.com/api/v1
H=(-H "Accept: application/json" -H "X-API-KEY: <API_KEY>")

curl -s "${H[@]}" "$API/ecommerce/products?per_page=20&max_price=900"   | jq '[.data[].price]'
#   -> [313.95, 943.95, 838.95, 921.501]
#              ^^^^^^ listed at 943.95, returned under "max 900"

curl -s "${H[@]}" "$API/ecommerce/products?per_page=20&max_price=800"   | jq '[.data[].price]'
#   -> [313.95]
#      838.95 is absent, though it appears at max_price=878
```

The boundaries do not line up with the displayed price, with the displayed price
÷ 1.05 (ex-tax), or with `original_price`. Whatever column is being compared,
a customer choosing "under ₹900" would be shown a ₹943.95 product.

### Also, sorting puts one product at the wrong end

`sort-by=price_asc` returns `4199.58, 313.95, 838.95, 921.501, 943.95, 3108` —
ascending apart from product **123**, which leads on `price_asc` and trails on
`price_desc`. That is the signature of a null sort key: 123 has no row in
`products_with_final_price`. `min_price=1000` also drops it, though it is listed
at ₹4,199.58.

The remaining order is correct, and ties (products 111 and 120 share
`original_price` 1296.75) are unordered between themselves, which is fine.

### Fix

Filter and sort on the same figure the product resource reports, and make sure
every published product has a `products_with_final_price` row.

### Client-side position

The app's category filter deliberately **omits price** and ships the facets that
were each verified to work — attributes, tags, brands. A rupee slider is a
half-hour of work once the bounds agree with the prices on screen.

### ~~Two more filter params the service reads but nothing honours~~ — **my error**

An earlier revision of this finding claimed `ratings` and `discounts` were
inert. **They are not.** They take *prefixed tokens*, and I had probed them with
bare numbers:

```bash
# what I sent first — parses, matches nothing, returns everything
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&ratings[]=4"          # 6 of 6
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&discounts[]=50"       # 6 of 6

# what the repository actually matches
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&ratings[]=rating_4"   # 2
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&discounts[]=on_sale"  # 5
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&discounts[]=discount_40" # 0
```

`ProductRepository::filterProducts` matches with
`str_starts_with($filter, 'rating_')` and `str_starts_with($filter, 'discount_')`,
plus the literal `on_sale`. A bare number falls through every branch, so the
filter is a silent no-op rather than an error.

Both are now shipped in the app's category filter.

**The one real gap:** `FilterResource` drops the `discount_ranges` and
`rating_ranges` its own controller computes, so a client cannot *discover* the
vocabulary — the app hardcodes `rating_4`, `rating_3`, `on_sale`,
`discount_10`, `discount_25` from reading the source. Emitting those two keys
would let the ranges be configured in admin instead.

### `collections` filters correctly but cannot be labelled

This one *works*:

```bash
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&collections[]=1" | jq '[.data[].id]'
#   -> [119, 118, 111, 120]     (6 without it)
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&collections[]=3" | jq '[.data[].id]'
#   -> [125, 123]
```

But there is **no way to learn what collection 1 and 3 are called**:
`/product-collections` and `/collections` are both 404, and `FilterResource`
drops the `$collections` its own controller already computes. A filter reading
"Collection 1" is not something to put in front of a customer.

**One-line fix:** add `'collections' => $collections` to `FilterResource`,
beside `brands` and `tags`. The data is already in scope. The app would pick it
up immediately — the sheet renders whatever facets come back.

### Not a defect, worth recording

`categories[]` is not broken after all. `ProductCategoryController::products`
merges the category **and its children** into the parameter, which is why
`?categories[]=17` returns 0 while `/product-categories/17/products` returns 5 —
17 is a parent and its products live in its children. Passing leaf ids works.

---

## 17. CONFIRMED IN SOURCE · A billing address is silently discarded unless `billing_address_enabled` is on — and turning it on 422s every client that does not send the flag

**Severity: high — one admin toggle either loses data quietly or breaks
checkout outright, and neither is visible from the API.**

Two halves, and they pull in opposite directions.

### (a) With the setting OFF, the billing address is thrown away under a 200

`CheckoutController::mobileCheckout` accepts `billing_address` and stores it on
the session data (lines 573–587), then hands it to
`OrderHelper::checkAndCreateOrderAddress`, which calls:

```php
protected function storeOrderBillingAddress(array $data, array $sessionData = []): void
{
    if (! EcommerceHelperFacade::isBillingAddressEnabled()) {
        return;                                   // <-- silent
    }
```

and `isBillingAddressEnabled()` is
`get_ecommerce_setting('billing_address_enabled', '0')` — **default off**. So a
client that sends a complete billing address gets HTTP 200, a real order, and no
`OrderAddress` row of type `BILLING`. Nothing in the response says so, and no
endpoint exposes the setting, so a client cannot discover it either.

The same function has a second silent drop, which applies even when the setting
is on:

```php
$validator = Validator::make($billingAddressData, $rules);
if ($validator->fails()) {
    return;                                       // <-- also silent
}
```

`$rules` is the **full** `getCustomerAddressValidationRules()` — required name,
state, city, address, phone and zip_code. A billing address that passes
`CheckoutRequest` but trips these is dropped after the order has been written.
The app now refuses client-side against the identical rule set so this cannot
happen from here, but any other client will hit it.

### (b) With the setting ON, omitting one flag makes the whole billing address required

`CheckoutRequest::rules()` — the class the mobile endpoint **shares** with the
web checkout:

```php
if (EcommerceHelper::isBillingAddressEnabled()) {
    $rules['billing_address_same_as_shipping_address'] = 'nullable|' . Rule::in(['0', '1']);
    if (! $this->input('billing_address_same_as_shipping_address') || …) {
        $rules['billing_address'] = 'array';
        $rules = array_merge($rules,
            EcommerceHelper::getCustomerAddressValidationRules('billing_address.'));
    }
```

`! $this->input(...)` is true when the key is absent. So the moment the shop
enables billing addresses, **every request that does not send the flag 422s**
with `billing_address.name is required` and friends — against a form that has no
billing name in it. The web posts the flag because its form has the checkbox;
an API client that never knew about it does not.

### What the app does about it

`CheckoutRepository.placeOrder` now sends
`billing_address_same_as_shipping_address` on **every** request — `"1"` when the
invoice goes to the delivery address, `"0"` alongside a `billing_address` when it
does not. The literal strings, because the rule is `Rule::in(['0', '1'])` and a
JSON boolean would miss both members. Pinned by
`test/data/checkout_request_test.dart` → *billing address*.

That makes the app safe under either setting. It does not fix (a): if the shop
wants billing addresses to actually be stored, **`billing_address_enabled` has
to be turned on in admin**, and there is no way for the app to check.

### Asks

1. Turn on **Settings → Ecommerce → Billing address** (or confirm it is on), so
   the address the app sends is stored rather than dropped.
2. Expose the two checkout toggles read-only so a client can stop showing a
   field the server will ignore — `billing_address_enabled` and
   `display_tax_fields_at_checkout_page`. Anywhere already-public would do; the
   app has no settings endpoint to read today.
3. Make both silent `return`s in `storeOrderBillingAddress` say something. A
   billing address that could not be stored should come back in the response,
   not disappear under a 200.

---

## 18. Tax information has the same invisible gate

**Severity: low — the default is favourable, so this is a note rather than a
break.**

```php
if (
    EcommerceHelper::isDisplayTaxFieldsAtCheckoutPage() &&
    $request->boolean('with_tax_information') &&
    $request->has('tax_information')
) {
    $order->taxInformation()->create($request->input('tax_information'));
}
```

`isDisplayTaxFieldsAtCheckoutPage()` is
`get_ecommerce_setting('display_tax_fields_at_checkout_page', true)` — **default
on**, so the block normally lands. But if the shop ever turns it off, the GST
details the customer typed are dropped exactly as silently as the billing
address above, and the app cannot tell.

Note also that `create()` takes the block wholesale, so all four columns
(`company_name`, `company_address`, `company_tax_code`, `company_email`) must be
sent together — which is why the app's cart collects all four rather than a bare
GSTIN. Same ask as (2) above: expose the toggle.

---

## 17. CONFIRMED · `star_distribution[].count` is a percentage, not a count

**Severity: low, but it would put a wrong number in front of customers.**

`GET /ecommerce/products/{slug}/reviews` returns a `review_summary` whose
`star_distribution` carries both a `count` and a `percent`. The `count` is the
percentage.

### Reproduction

```bash
API=https://dev.truewayerp.com/api/v1
H=(-H "Accept: application/json" -H "X-API-KEY: <API_KEY>")

curl -s "${H[@]}" "$API/ecommerce/products/trueway-farms-organic-desi-khand-brown-khandsari/reviews"   | jq '.data.review_summary | {reviews_count, star_distribution}'
```

```json
{
  "reviews_count": 1,
  "star_distribution": [
    { "star": 5, "count": 100, "percent": 100 },
    { "star": 4, "count": 0, "percent": 0 }
  ]
}
```

One review, and the 5★ row claims 100. The same holds on
`trueway-farms-organic-sona-moti-wheat-sonamoti-gehu-5kg-pack`, also a
one-review product — so it is not a data artefact of one row.

### Fix

Set `count` to the number of reviews at that rating. `percent` is already
correct and is what a bar width needs; `count` is what a "(12)" label beside the
bar would need.

### Client-side position

The app parses **only** `percent` and shows no per-star tally. A bar is drawn
with no number beside it. Rendering `count` would tell a customer there are 100
reviews when there is one.

---

## 19. CONFIRMED · An "other" city is rendered as the literal word "other"

Probed live 2026-08-12 on a throwaway account; every row created was deleted
afterwards.

`POST /ecommerce/addresses` with the documented escape hatch:

```bash
-d '{"name":"Probe","phone":"9812345670","state":"11","address":"1 Lane",
     "zip_code":"382415","city":"other","other_city":"Tiny Village"}'
```

The row is created, and comes back as:

```json
{"state":"11","state_name":"Gujarat",
 "city":"other","city_name":"other","other_city":"Tiny Village",
 "full_address":"1 Lane, other, Gujarat, 382415"}
```

`other_city` is stored correctly and then **never used**. Both rendered fields —
`city_name` and `full_address` — say `other`, which is not a place. A customer
in an unlisted town sees "other" where their town should be, on the address
card, on the order, and on anything printed from `full_address`.

The conditional validation is right (`city: "other"` without `other_city` is a
clean 422, *"The other city field is required when city is other."*) — it is
only the rendering that drops the value.

### Fix

Wherever `LocationTrait` resolves `city_name`, return `other_city` when the
column holds the sentinel, and build `full_address` from the resolved name. One
place, and it fixes both fields plus the order address.

### Client-side position

The app substitutes it back: `Address.cityName` and `Address.displayAddress`
replace a whole `other` segment with `other_city`, and `OrderContact.streetLine`
does the same for `shipping_info`. Both are narrow — only a row whose `city` is
the sentinel, only a whole comma-separated segment, so a street called "Other
Lane" survives. The substitution can be deleted the day the server does it.

---

## 20. `city` is accepted without any validation at all

Same probe session. `state` gained an `exists` rule — good, and the app now
posts ids because of it:

```
state: "9999"     -> 422 "The selected state is invalid."
state: "Gujarat"  -> 422 "The selected state is invalid."
```

`city` did not:

```
city: "999999"    -> 201, and reads back as city_name: "999999"
city: "Ahmedabad" -> 201, stored as a name
city: "1"         -> 201, beside state 11 — city 1 is "Bamboo Flat",
                    in the Andaman and Nicobar Islands
```

So a typo, a stale id, or a city from the wrong state is stored silently and
rendered back verbatim. The last case is the interesting one: nothing checks
that the city belongs to the state, so an address can name two places at once
and still look complete on screen.

Not urgent — the app's picker only ever offers cities of the chosen state, and
clears the city when the state changes — but the endpoint is open to any client.
An `exists` rule scoped to the state (with the `other` sentinel exempted) would
close it.

### Note on the paths

The instruction doc gives the two new lookup routes as `GET /states` and
`GET /cities`. Both are **404** live. The deployed paths are
`/api/v1/ecommerce/states` and `/api/v1/ecommerce/cities?state=<id>`.

---

## 21. UNCONFIRMED — a Razorpay order can be finalized without a completed payment

Raised by the app's own maintainer: cancelling the Razorpay sheet immediately
after opening it was reported to still leave the order "placed" with the
payment showing complete. Live probing (2026-08-13, throwaway account, disposable order left permanently
pending/unfinished — never confirmed, so it is invisible to the customer and
harmless to leave) rules out the simplest explanation and finds a real hole
instead — but could not reproduce the report end-to-end, because that needs a
real Razorpay SDK interaction this probe cannot drive. Recorded as a code-level
finding for the backend team to judge, not a confirmed live repro.

### What is confirmed NOT the cause

A cart was checked out with `payment_method: razorpay` and **no
`confirm-payment` call was ever made** — the app's own client refuses to send
one on a cancelled sheet (verified in `checkout_provider.dart`; see below).
That order:

```
POST checkout/cart/{id}  -> order_id 292, status: pending, payment_status: pending, is_finished: false
GET  ecommerce/orders/292            -> 404
GET  ecommerce/orders (list)         -> 292 absent
```

So the create step itself never marks anything paid, and an order nobody
confirmed is invisible to the customer exactly as designed. Also confirmed:
`razorpay_key_id` returned is `rzp_test_...` — **this backend is on Razorpay
TEST MODE**, where most test UPI/card flows resolve to a genuine success in one
tap. A customer who dismisses a screen a beat later may be dismissing the
success confirmation, not cancelling a live payment — worth ruling out before
chasing this further. (The app now logs which `PaymentResult` the SDK actually
returned, debug builds only, to make that distinguishable next time.)

### What IS a real hole, found reading the source

`CheckoutController::mobileCheckout` — the Razorpay branch — sets the order's
`payment_id` to the newly-created payment **the moment the order is created**,
while that payment is still `PENDING`:

```php
// API/CheckoutController.php:673-685
$payment = Payment::create([
    'order_id' => $order->id,
    ...
    'status' => PaymentStatusEnum::PENDING,
    'charge_id' => null,
]);
$order->payment_id = $payment->id;   // set before any money has moved
$order->save();
```

`OrderHelper::processOrder` (`Supports/OrderHelper.php:68`) is the only gate
between "an order exists" and "the order is finished" (`is_finished = true`,
`OrderPlacedEvent` dispatched, stock decremented). Its skip condition:

```php
// Supports/OrderHelper.php:99-104
if (
    (float) $order->amount
    && (is_plugin_active('payment') && ! empty(PaymentMethods::methods()) && ! $order->payment_id)
) {
    continue;   // only skips when there is NO payment_id at all
}
```

It checks whether `payment_id` is **set**, never whether the payment it points
at is **completed**. Because `mobileCheckout` already set `payment_id` on a
still-pending payment, this guard cannot do its one job for a Razorpay order —
anything that calls `processOrder` for this order finalizes it regardless of
whether the payment ever completed.

The other half: `HookServiceProvider.php:346-368` listens for
`PAYMENT_ACTION_PAYMENT_PROCESSED` and calls `OrderHelper::processOrder`
**unconditionally** — it never inspects `$data['status']`:

```php
add_action(PAYMENT_ACTION_PAYMENT_PROCESSED, function (array $data): void {
    ...
    foreach ($orders as $order) { ... PaymentHelper::storeLocalPayment($data); }
    OrderHelper::processOrder($orders->pluck('id')->all(), $data['charge_id']);
}, 123);
```

And `confirmRazorpayPayment` (`API/CheckoutController.php:941-955`) fires that
same action with `status: PENDING` — not `COMPLETED` — whenever Razorpay's own
`order.fetch()` reports anything other than `'paid'` (e.g. `'attempted'`, which
Razorpay uses for an authorized-but-not-yet-captured or since-reversed
attempt):

```php
$status = $razorpayOrderArr['status'] === 'paid'
    ? PaymentStatusEnum::COMPLETED
    : PaymentStatusEnum::PENDING;

do_action(PAYMENT_ACTION_PAYMENT_PROCESSED, [..., 'status' => $status, ...]);
```

Chained together: **any** call to `confirmRazorpayPayment` that reaches a
verified signature — which only happens after a genuine SDK success callback —
finalizes the order even on the `status: PENDING` branch, because nothing
downstream re-checks `$data['status']` before calling `processOrder`. The app
only calls `confirmRazorpayPayment` after `EVENT_PAYMENT_SUCCESS`, so the
narrow window this needs is Razorpay reporting `order.status: 'attempted'`
rather than `'paid'` at the moment `confirmRazorpayPayment` fetches it — a
timing race between the SDK's success callback and Razorpay's own order
finalization, not something either app or backend controls directly.

### Separately — `storeLocalPayment` cannot find the original payment row

`PaymentHelper::storeLocalPayment` (`Supports/PaymentHelper.php:58-67`) matches
the existing row by `charge_id`:

```php
if ($chargeId) {
    $payment = Payment::query()->where('charge_id', $chargeId)->whereIn('order_id', $orderIds)->first();
}
```

The row `mobileCheckout` created has `charge_id: null`; `confirmRazorpayPayment`
passes the **new** `razorpay_payment_id` as `charge_id`. `null` never equals a
non-null string, so this lookup always misses and `storeLocalPayment` falls
through to creating a **second** `Payment` row for the same order rather than
updating the first — the original PENDING row is orphaned, not corrected.
`processOrder`'s own charge_id lookup (`Supports/OrderHelper.php:78-93`) then
re-points `order->payment_id` at the new row, so the order ends up pointing at
the right (completed) payment in the confirmed-success case — but a duplicate
PENDING `Payment` row is left behind on every Razorpay order, confirmed or not.

### Asks

1. Set `$order->payment_id` only when the payment is actually completed —
   not at order-creation time — or change the `processOrder` skip condition to
   check the payment's `status`, not merely its presence.
2. Have the `PAYMENT_ACTION_PAYMENT_PROCESSED` listener in
   `HookServiceProvider.php:346` skip `processOrder` (and any "order placed"
   side effects) when `$data['status']` is not `COMPLETED`.
3. Fix `storeLocalPayment`'s match to also look up the order's *existing*
   payment row by `order_id` when `charge_id` is null, so it updates in place
   instead of creating a duplicate.

### Client-side position

No client-side fix is possible or needed here — the app already refuses to
call `confirmRazorpayPayment` on anything but a verified `PaymentSuccess`
triple (`razorpay_gateway.dart`), and treats confirm-payment's own 200 as
advisory rather than proof (`checkout_provider.dart`'s `_confirm`/`_reconcile`
re-read `GET /orders/{id}` before ever showing a success screen). If this hole
is real, it is entirely inside `processOrder`'s skip condition and the hook
that calls it without checking status.

---

## 22. `/orders/{id}/cancel` would over-credit stock on an order that was never finalized

Raised while evaluating a feature request ("delete the order and let the
customer start a clean checkout" after a Razorpay sheet is dismissed). Found
reading the source; **not triggered by anything the app does today** — the app
never calls this endpoint on an unfinished order — but it would be if that
feature were built the obvious way, so it is recorded before anyone reaches
for it.

### The mismatch

Stock is only ever decremented by `OrderHelper::decreaseProductQuantity`
(`Supports/OrderHelper.php:194`), called from exactly one place —
`OrderHelper::processOrder` (`:112-115`), which for a Razorpay order only runs
after `confirmRazorpayPayment` verifies a real signature. A checkout that never
reaches that point — sheet opened and dismissed, app killed mid-sheet, a
customer who simply never returns — has an `Order` row, real `OrderProduct`
rows with real quantities (`API/CheckoutController.php:591-635`, written
unconditionally at order-creation time), and **stock that was never touched**.

`OrderHelper::cancelOrder` (`Supports/OrderHelper.php:1095-1135`) does not know
that. Its job is "undo a *placed* order", and it always credits stock back:

```php
foreach ($order->products as $orderProduct) {
    $product = $orderProduct->product;
    $product->quantity += $orderProduct->qty;   // assumes it was decremented
    $product->save();
    ...
}
```

`Order::canBeCanceled()` (`Models/Order.php:189-207`) does not gate on
`is_finished` either — an order at `status: pending` with no shipment, or one
whose shipment is still `pending`/`not_approved`/`approved`, satisfies it
regardless of whether it was ever confirmed. So `POST /orders/{id}/cancel` on
an order abandoned before payment would **succeed** and add stock the order
never took.

### Asks

Gate the restock loop (or `canBeCanceled`, for cancellation generally) on
`$order->is_finished` — an order that never finished never took stock, and has
nothing to give back.

### Client-side position

The app does not call this endpoint on an unfinished order and will not until
the above is fixed. See `checkout_provider.dart` / `checkout_screen.dart`: a
cancelled Razorpay sheet leaves the order exactly where the server put it —
pending, unpaid, invisible to `GET /orders` (both routes filter
`is_finished = 1`) — and a customer who wants to check out an updated cart
uses "Start a new order," which places a genuinely new order without touching
the old row at all.

---

## The cart cannot report the saving the website advertises

`GET`/`POST /api/v1/ecommerce/cart` — **app cannot show "Saved ₹114"**

The web cart prints a saving on every basket:

```
Items total   [Saved ₹114.00]   ~~₹544.00~~  ₹430.00
```

That figure is MRP − selling price. Every product in this catalogue is marked
down — product 129 lists at ₹313.95 against a selling price of ₹208.95 — so the
web cart shows a saving on essentially every order. The app shows ₹0.00,
because nothing in the cart payload can produce that number.

**Why not.** Two candidate fields, and neither works:

* `raw_sub_total` is **not** the MRP total. `Cart::rawSubTotal()`
  (`platform/plugins/ecommerce/src/Cart/Cart.php:335`) is
  `Σ qty × cartItem->price`, and the price a line carries is the one being
  charged. Live, a cart holding one unit of product 129 reports
  `raw_sub_total: 199` — the selling price ex-tax.
* `promotion_discount_amount` is the promotions **module's** discount, and it
  is `0` here: the markdown is already inside the price the cart charges, and
  the promotions plugin is not being used.

`CartItemResource` does emit a per-line `original_price`, which is exactly the
field needed — but it reads `Arr::get($this->options, 'original_price')`, and
**nothing in the cart write path ever sets that option**. Live, every line
comes back:

```json
"price": 199, "original_price": null, "original_price_formatted": "₹0.00"
```

**The ask.** Populate `original_price` in the cart item's options when the item
is added, the way `OrderController.php:2318` already does for orders:

```php
'original_price' => $product->price,   // the MRP, ex-tax, to match `price`
```

Ex-tax, to match the `price` beside it. The app can then show the same saving
the website does, per line and summed, without doing any arithmetic of its own.

**Why the app will not work around it.** The catalogue's `original_price` is
tax-**inclusive** (₹313.95) while the cart is tax-exclusive (₹199). Subtracting
one from the other would invent a saving matching neither figure the customer
can see, so the app leaves the row out until the server can answer.

Verified live 2026-09-02.

---

## Method

Every endpoint was probed live. Write endpoints were probed with deliberately
invalid bodies to harvest `422` field lists without creating data. No orders were
placed, no OTP was sent, and no existing order, address, review or return was
modified or deleted. Findings 1 and 2 were reproduced against throwaway
anonymous carts and wishlists, finding 1 with a control.

Findings 11 and 13 additionally used a read-only reconstruction of 62 historical
orders: `GET /ecommerce/orders` + `GET /ecommerce/orders/{id}` for the recorded
amounts and parcels, disposable anonymous carts to re-derive
`package_dimensions` / `total_weight` / `order_total`, and repeated
`POST /logistics/check-serviceability` sweeps varying only `pickup_postcode`.
`check-serviceability` and `check-pincode` are quote endpoints — they create
nothing. Method and evidence in `VERIFIED_API_CONTRACT.md` §4.5.

# Backend patch — three fields on the order resources

Ready to apply. **No migration, no new query, no behaviour change** — every value
already exists on the model; these lines only serialize it.

Both files live at
`platform/plugins/ecommerce/src/Http/Resources/API/`.

Line numbers are from the current live code (verified 2026-08-05, after the
`sub_total` / `payment_fee` change was merged).

---

## 1. `shipping_option` — both files

**Why:** an order records `shipping_method: "shiprocket"` but never says *which
rate* priced it. After the fact, `CheckoutController.php:425`'s two branches —
server-priced vs client-supplied — are indistinguishable, so there is no way to
audit a mobile order or to prove a ₹0.00 shipping order came from the
`Arr::get($filtered, null)` defect (`BACKEND_BUGS.md` finding 9) rather than from
a real quote.

The column exists and is fillable (`Order.php:35`).

### `OrderResource.php` — after line 51
### `OrderDetailResource.php` — after line 38

```php
            'shipping_method' => $this->shipping_method,
            'shipping_option' => $this->shipping_option,          // <-- ADD
```

---

## 2. `discount_amount` — `OrderResource.php` only

**Why:** the detail route exposes it (`OrderDetailResource.php:67-68`); the list
route does not. So the list row cannot reconcile a discounted order on its own —
order 52 carries a ₹44.63 discount that is simply invisible there, and the app
has to refuse to render a subtotal rather than print one that does not add up.

### `OrderResource.php` — alongside the other money fields (after line 46)

```php
            'payment_fee_formatted' => format_price($this->payment_fee),
            'discount_amount' => $this->discount_amount,                        // <-- ADD
            'discount_amount_formatted' => format_price($this->discount_amount), // <-- ADD
```

---

## 3. `city_name` / `state_name` in `shipping_info` — both files

**Why:** this is the one a customer sees. `ec_order_addresses.state` and `.city`
store **numeric ids** (`SelectLocationField` posts `$item->getKey()`), so the app
currently receives `"11"` and `"574"` and shows nothing rather than print an id
as a place name. **City and state are therefore missing from the delivery
address on every order screen.**

`country` is already resolved this way in the same block, so this is finishing a
pattern rather than starting one. `LocationTrait` supplies both accessors, and
they fall back to the raw value when it is already a name — rows are mixed
(`"Madhya Pradesh"` and `"11"` both occur), so the fallback matters.

### `OrderResource.php` lines 59-61 → and `OrderDetailResource.php` lines 46-48

```php
                'city' => $this->address->city,            // BEFORE
                'state' => $this->address->state,
                'country' => $this->address->country_name,
```

```php
                'city' => $this->address->city_name,       // AFTER
                'state' => $this->address->state_name,
                'country' => $this->address->country_name,
```

Apply the same change to the `billing_info` block just below it
(`OrderResource.php:70-71`, `OrderDetailResource.php:57-58`).

---

## The app needs no change for any of this

- `shipping_option` and `discount_amount` — parsed on arrival, ignored while
  absent.
- `city_name` / `state_name` — `OrderContact` reads `city`/`state` by name, so
  resolved values flow straight through to the screen.

Nothing regresses if the patch is delayed; the app already handles every field
being missing.

## How to verify after deploying

```bash
API=https://dev.truewayerp.com/api/v1
TOK=…   # POST /login

curl -s -H "X-API-KEY: <API_KEY>" -H "Authorization: Bearer $TOK" \
     -H "Accept: application/json" "$API/ecommerce/orders/282" \
  | jq '{shipping_option, discount_amount, city: .data.shipping_info.city,
         state: .data.shipping_info.state}'
```

Expect `shipping_option` non-null on a shiprocket order, and `city`/`state` as
names rather than `"574"` / `"11"`.

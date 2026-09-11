# Backend patch — per-product cart quantity limits

**Goal:** let the app stop a customer at the same quantity the server would, so
an over-limit tap never reaches the API.

**Status:** nothing has been changed in the app. The limits are not enforceable
client-side today — see below.

---

## The short version

Botble already computes both numbers. They are simply not serialized.

`platform/plugins/ecommerce/src/Models/Product.php:860-877`

```php
protected function minCartQuantity(): Attribute
{
    return Attribute::get(fn () => $this->minimum_order_quantity ?: 1);
}

protected function maxCartQuantity(): Attribute
{
    return Attribute::get(function () {
        if ($this->maximum_order_quantity) {
            return $this->maximum_order_quantity;
        }
        return $this->with_storehouse_management ? $this->quantity : 1000;
    });
}
```

**Please expose these two accessors** rather than the three raw columns. They
already encode the branching, so the app does not have to reimplement a rule
that can drift.

---

## The change — two lines

In `platform/plugins/ecommerce/src/Http/Resources/API/ProductResource.php`
(and the detail resource, if they are separate):

```php
            'quantity' => $this->quantity,
            'min_cart_quantity' => $this->min_cart_quantity,      // <-- ADD
            'max_cart_quantity' => $this->max_cart_quantity,      // <-- ADD
```

Both are already `int`-cast on the model (`Product.php:99-100`).

---

## Why the app cannot derive this itself

The product payload today carries `quantity` and `is_out_of_stock`, and nothing
else about limits:

```
quantity                          85558
is_out_of_stock                   false
minimum_order_quantity            ABSENT
maximum_order_quantity            ABSENT
with_storehouse_management        ABSENT
```

`quantity` alone cannot stand in for the cap, and this is already known to the
app — `lib/data/models/product_model.dart:191` records it:

> `quantity` cannot refine it: products with untracked inventory also report
> `quantity: 0` while remaining purchasable, so the client has no way to tell.

That is exactly the `with_storehouse_management` branch above. Without the flag
the app cannot tell "0 in stock" from "stock not tracked", so capping at
`quantity` would block orders for perfectly purchasable products.

---

## Why this is worth doing beyond tidiness

An over-limit add does not merely fail — on this backend it **destroys the
cart**. `Cart::restore()` deletes the stored row before the mutation runs, and
the max-quantity branch returns before `store()` puts it back, so a customer
with six items who tries to add a seventh over the limit loses all six. That is
`BACKEND_BUGS.md` finding 0, still open.

The app already rebuilds from its local mirror when this happens, but the
rebuild is a round trip the customer sees. Knowing the cap up front means the
"+" button simply stops, and the destructive path is never entered.

---

## What the app will do once the fields land

- the quantity stepper on the product page and in the cart stops at
  `max_cart_quantity` and will not go below `min_cart_quantity`;
- the first add uses `min_cart_quantity` rather than 1, which is what a product
  sold only in packs of 6 needs;
- the cap is shown ("max 5 per order") rather than discovered by being refused.

Nothing is guessed: with the fields absent the stepper keeps today's behaviour
and lets the server decide.

## Verifying after deploy

```bash
curl -s -H "X-API-KEY: <API_KEY>" -H "Accept: application/json" \
     "https://dev.truewayerp.com/api/v1/ecommerce/products?per-page=12" \
  | jq '.data[] | {name, quantity, min_cart_quantity, max_cart_quantity}'
```

Expect `min_cart_quantity` ≥ 1 on every row, and `max_cart_quantity` to be
either the configured maximum, the tracked stock, or `1000`.

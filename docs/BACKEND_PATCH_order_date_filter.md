# Backend patch — date filter on `GET /api/v1/ecommerce/orders`

**Ask:** two optional query parameters, `from_date` and `to_date`, on the
customer order list.

**Why:** the app now offers "This month / Last month / This year / Last year /
Custom range" on the orders screen. The endpoint cannot do it, so the app reads
the customer's **entire** order history and filters it on the device. That works
today because the busiest account has 94 orders. It stops working the moment an
account has a few thousand.

The app is already written to switch over. When this ships, one constant flips
and the client-side pass is deleted — no other change, no new release blocker.

---

## 1. What exists today

`OrderController::index` supports three filters:

```php
if ($request->has('status') && $request->input('status')) { … }
if ($request->has('shipping_status') && $request->input('shipping_status')) { … }
if ($request->has('payment_status') && $request->input('payment_status')) { … }
```

All three work — verified live against `dev.truewayerp.com` on 2026-08-11:

| Query | Rows |
|---|---|
| *(none)* | 94 |
| `?status=completed` | 27 |
| `?status=pending` | 2 |
| `?status=canceled` | 10 |

There is **no date filter**, under any name. Seven were tried:

```bash
API=https://dev.truewayerp.com/api/v1
H=(-H "Accept: application/json" -H "X-API-KEY: <API_KEY>" -H "Authorization: Bearer <TOKEN>")

curl -s "${H[@]}" "$API/ecommerce/orders?per_page=100"                                  # 94
curl -s "${H[@]}" "$API/ecommerce/orders?per_page=100&from_date=2026-08-01&to_date=2026-08-31"    # 94
curl -s "${H[@]}" "$API/ecommerce/orders?per_page=100&start_date=2026-08-01&end_date=2026-08-31"  # 94
curl -s "${H[@]}" "$API/ecommerce/orders?per_page=100&date_from=2026-08-01&date_to=2026-08-31"    # 94
curl -s "${H[@]}" "$API/ecommerce/orders?per_page=100&year=2025"                                  # 94
curl -s "${H[@]}" "$API/ecommerce/orders?per_page=100&year=2025&month=1"                          # 94
curl -s "${H[@]}" "$API/ecommerce/orders?per_page=100&created_at=2020-01-01"                      # 94
curl -s "${H[@]}" "$API/ecommerce/orders?per_page=100&from=2026-08-01&to=2026-08-31"              # 94
```

Every one returns the whole history. Note they are **not rejected** — no 400, no
422, no warning — so a client that sends `?year=2025` has no way to discover it
did nothing. That silence is worth fixing on its own.

---

## 2. The patch

In `platform/plugins/ecommerce/src/Http/Controllers/API/OrderController.php`,
inside `index()`, directly **after** the three existing filter blocks and
**before** `$orders = $query->latest()`:

```php
// Filter by order date (inclusive, whole days, store timezone)
if ($fromDate = $request->input('from_date')) {
    $query->whereDate('ec_orders.created_at', '>=', $fromDate);
}

if ($toDate = $request->input('to_date')) {
    $query->whereDate('ec_orders.created_at', '<=', $toDate);
}
```

That is the whole change. `whereDate` compares the date part only, so
`to_date=2026-08-31` includes an order placed at 21:47 on the 31st — which is
the reading a customer expects and the one the app already uses locally.

### Contract

| Parameter | Format | Meaning |
|---|---|---|
| `from_date` | `YYYY-MM-DD` | Orders placed **on or after** this day. |
| `to_date` | `YYYY-MM-DD` | Orders placed **on or before** this day. |

- Both optional and independent — either alone is valid ("everything since
  1 April", "everything up to 31 March").
- Both inclusive.
- They combine with `status`, `shipping_status`, `payment_status` and with
  `page` / `per_page` exactly as those already combine with each other.
- Table-qualify `ec_orders.created_at`: `index()` already joins through
  `whereHas('shipment')` and `whereHas('payment')`, and an unqualified
  `created_at` can become ambiguous.

### Please also validate

Right now an unknown filter value is silently ignored, which is how this gap
stayed invisible. Rejecting a malformed date is a small addition and saves the
next client the same day of confusion:

```php
$request->validate([
    'from_date' => ['nullable', 'date_format:Y-m-d'],
    'to_date'   => ['nullable', 'date_format:Y-m-d', 'after_or_equal:from_date'],
]);
```

### Timezone

`whereDate` compares against the database's stored value. Orders come back as
`2026-08-11T21:47:04+05:30`, so as long as the app sends days computed in IST —
it does — the two agree. Nothing to change unless the store timezone moves.

---

## 3. How to check it worked

The test account's history, grouped by month (live, 2026-08-11):

```
2025-07  5    2025-10  5    2025-12  11   2026-02  4    2026-04  2    2026-06  1    2026-08  4
2025-08  2    2025-11  12   2026-01  2    2026-03  28   2026-05  5    2026-07  13
                                              2025 total: 35    2026 total: 59
```

So, after the patch:

```bash
# a single month
curl -s "${H[@]}" "$API/ecommerce/orders?per_page=100&from_date=2026-03-01&to_date=2026-03-31" \
  | jq '.meta.total'      # expect 28

# a whole year
curl -s "${H[@]}" "$API/ecommerce/orders?per_page=100&from_date=2025-01-01&to_date=2025-12-31" \
  | jq '.meta.total'      # expect 35

# combined with a status the endpoint already supports
curl -s "${H[@]}" "$API/ecommerce/orders?per_page=100&from_date=2025-01-01&to_date=2025-12-31&status=completed" \
  | jq '.meta.total'      # expect <= 27

# open-ended
curl -s "${H[@]}" "$API/ecommerce/orders?per_page=100&from_date=2026-01-01" | jq '.meta.total'   # expect 59

# the boundary that matters — 11 Aug has an order placed at 21:47
curl -s "${H[@]}" "$API/ecommerce/orders?per_page=100&from_date=2026-08-11&to_date=2026-08-11" \
  | jq '[.data[].created_at]'   # must NOT be empty
```

`meta.total` is the assertion to watch: it must count the **filtered** set, not
the whole history. That falls out of applying the filter to the query before
`paginate()`, which the patch above does.

---

## 4. What the app does on the day this ships

One line in `lib/data/repositories/order_repository.dart`:

```dart
static const bool serverFiltersByDate = false;   // -> true
```

The request is already built — `from_date` / `to_date` are sent from
`DateRange.startDay` / `.endDay` in the `serverFiltersByDate` branch, so nothing
new has to be written. Flipping it also makes `_ordersInDateRange` (the local
pass) dead code, and it should be deleted with the flip.

Please tell us when it is on dev and we will verify against the numbers above
before the flag flips.

---

## 5. Not blocking, but related

Two other things on the same endpoint that the app works around:

- **`shipping_option` is absent** from both order resources — see
  `BACKEND_BUGS.md` finding 12.
- **Unknown filter values are accepted silently.** `?status=cancelled` (two Ls)
  returns HTTP 200 with `total: 0`, which a client cannot tell apart from "you
  have no cancelled orders". The validation suggested in §2 would fix the same
  class of problem for dates; extending it to `status` would be welcome.

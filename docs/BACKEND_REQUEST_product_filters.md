# Backend request — product filters

> **✅ CLOSED — 2026-08-12.** All four requests shipped. Verified live the same
> day, and the app now ships every filter below:
>
> | # | Request | Verified |
> |---|---|---|
> | 1 | Collections facet | `filters.collections` → "New Arrival" (4), "Special Offer" (2) |
> | 2 | Price filter | `max_price=900` → only ₹445.20; `sort-by=price_asc` monotonic |
> | 3 | Discount / rating ranges | `discount_ranges`, `rating_ranges` present, tokens as `id` |
> | 4 | `in_stock=1` | accepted, combines with other filters — **see caveat** |
>
> `max_price` now reports **4200**, the ceiling of the dearest product at
> ₹4,199.58, instead of the old 4444.
>
> **One caveat on #4.** It could not be *proven* to filter: every product in
> this catalogue is currently in stock, so a filtered and an unfiltered request
> return the same six rows. The app sends `in_stock=1` and re-enabled paging on
> the strength of it, but also keeps sweeping the returned page, so a customer
> who asked to hide sold-out products never sees one either way. Worth a second
> look once something in the catalogue actually goes out of stock.
>
> The original request follows, unchanged, for the record.

---

For the Trueway Farms mobile app's category filter sheet.

Every claim below was probed live against `https://dev.truewayerp.com/api/v1` on
**2026-08-11**, with the store's real 6-product catalogue. Reproduction commands
are included so nothing has to be taken on trust.

```bash
API=https://dev.truewayerp.com/api/v1
H=(-H "Accept: application/json" -H "X-API-KEY: <MOBILE_API_KEY>")
```

---

## Summary

| Filter | Works today? | App status | Needs backend work |
|---|---|---|---|
| Attributes (Weight, Pack Size) | ✅ | shipped | — |
| Tags | ✅ | shipped | — |
| Ratings | ✅ | shipped | 🟡 small — expose the ranges |
| Discounts / offers | ✅ | shipped | 🟡 small — expose the ranges |
| Brands | ✅ | hidden (store has 1 brand) | — |
| Categories | ✅ | the screen's left rail does this | — |
| **Collections** | ✅ **filters correctly** | ❌ **cannot ship** | 🔴 **one line — see #1** |
| **Price (min/max)** | ⚠️ **filters the wrong price** | ❌ **cannot ship** | 🔴 **see #2** |
| In stock | ❌ no such parameter | client-side only | 🟢 optional — see #3 |

**Two things block a filter the app is otherwise ready to show.** #1 is a
one-line change. #2 is a real bug worth fixing regardless of the app.

---

## 1. 🔴 `collections` filters correctly but its names are unreachable

**One-line fix. Highest value for the effort.**

The filter itself works:

```bash
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30" | jq '[.data[].id]'
#   -> [125, 119, 118, 111, 123, 120]        (6 products)

curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&collections[]=1" | jq '[.data[].id]'
#   -> [119, 118, 111, 120]

curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&collections[]=3" | jq '[.data[].id]'
#   -> [125, 123]
```

But there is no way to learn what collections 1 and 3 are **called**:

```bash
curl -s -o /dev/null -w "%{http_code}\n" "${H[@]}" "$API/product-collections"            # 404
curl -s -o /dev/null -w "%{http_code}\n" "${H[@]}" "$API/collections"                    # 404
curl -s -o /dev/null -w "%{http_code}\n" "${H[@]}" "$API/ecommerce/product-collections"  # 404

curl -s "${H[@]}" "$API/ecommerce/filters" | jq '.data | keys'
#   -> ["attributes","brands","categories","current_category_id",
#       "current_filter_categories","max_price","price_ranges","tags"]
#      no "collections"
```

A filter labelled "Collection 1" is not something to put in front of a customer,
so the app leaves it out entirely.

### The fix

`FilterController::getFilters` **already computes** the collections — it is in
scope and then thrown away:

`platform/plugins/ecommerce/src/Http/Controllers/API/FilterController.php`

```php
$filterData = [
    'categories'      => $categories ?? collect(),
    'brands'          => $brands ?? collect(),
    'tags'            => $tags ?? collect(),
    'collections'     => $collections ?? collect(),   // <-- passed in
    'discount_ranges' => $discountRanges ?? collect(),
    'rating_ranges'   => $ratingRanges ?? collect(),
    ...
];
```

`FilterResource` simply never emits it.

`platform/plugins/ecommerce/src/Http/Resources/API/FilterResource.php` — add
alongside the existing `brands` / `tags` blocks:

```php
'collections' => ($data['collections'] ?? collect())->map(function ($collection) {
    return [
        'id'             => $collection->id,
        'name'           => $collection->name,
        'slug'           => $collection->slugable->key ?? '',
        'products_count' => $collection->products_count ?? 0,
    ];
})->values(),
```

### Expected result

```bash
curl -s "${H[@]}" "$API/ecommerce/filters" | jq '.data.collections'
#   -> [ { "id": 1, "name": "…", "slug": "…", "products_count": 4 }, … ]
```

**No app change is needed.** The filter sheet renders whatever facets come back,
so collections will appear as soon as this ships.

---

## 2. 🔴 `min_price` / `max_price` filter on a price the API never returns

**This is a genuine bug, not just an app inconvenience** — the website's own
price filter will be wrong in the same way.

```bash
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&max_price=900" | jq '[.data[].price]'
#   -> [313.95, 943.95, 838.95, 921.501]
#               ^^^^^^ listed at 943.95, returned under "max 900"

curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&max_price=800" | jq '[.data[].price]'
#   -> [313.95]
#      838.95 is missing here but present at max_price=878
```

The boundaries match **none** of: the `price` the product resource returns, that
price ÷ 1.05 (ex-tax), or `original_price`.

### `price_ranges` has the same fault

The other price parameter shape is affected identically, so there is no way
around it client-side:

```bash
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&price_ranges[0][from]=0&price_ranges[0][to]=900"   | jq '[.data[].price]'
#   -> [445.2, 943.95, 921.501, 921.501]
#              ^^^^^^  ^^^^^^^ both above 900

curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&price_ranges[0][from]=1000&price_ranges[0][to]=5000"   | jq '[.data[].price]'
#   -> [3108]        4199.58 is missing — the same null-key product
```

`GET /ecommerce/filters` also returns `price_ranges: []` — the server originates
none, so even a range picker has nothing to populate itself with.

### Related: one product has a null sort key

```bash
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&sort-by=price_asc" | jq '[.data[].price]'
#   -> [4199.58, 313.95, 838.95, 921.501, 943.95, 3108]
#       ^^^^^^^ product 123 leads on ASC and trails on DESC
```

That is the signature of a null: product **123** appears to have no row in
`products_with_final_price`. `min_price=1000` also drops it, though it is listed
at ₹4,199.58. The rest of the ordering is correct.

### Ask

1. Filter and sort on the **same figure the product resource reports**, so a
   customer choosing "under ₹900" never sees ₹943.95.
2. Make sure every published product has a `products_with_final_price` row —
   product 123 is the one to look at.

Until then the app ships **no price filter**. It is roughly half a day of app
work to add once the bounds agree with the prices on screen.

---

## 3. 🟡 Expose the rating and discount ranges

**These filters already work** — the app ships them today. This is about making
them configurable instead of hardcoded.

The catch is that they take **prefixed tokens**, not numbers. This cost real
debugging time, because a bare number parses fine and then silently matches
nothing:

```bash
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&ratings[]=4"             | jq '.data|length'  # 6  (no-op)
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&ratings[]=rating_4"      | jq '.data|length'  # 2  ✅
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&discounts[]=on_sale"     | jq '.data|length'  # 5  ✅
curl -s "${H[@]}" "$API/ecommerce/products?per_page=30&discounts[]=discount_40" | jq '.data|length'  # 0  ✅
```

`ProductRepository::filterProducts` matches with
`str_starts_with($filter, 'rating_')`, `str_starts_with($filter, 'discount_')`
and the literal `'on_sale'`.

`FilterController` computes `$discountRanges` and `$ratingRanges`, and
`FilterResource` drops both — the same omission as `collections` in #1. So the
app **hardcodes** `rating_4`, `rating_3`, `on_sale`, `discount_10`,
`discount_25`, read out of the PHP source.

### Ask

Add `discount_ranges` and `rating_ranges` to `FilterResource` in the same commit
as #1. Then the ranges become an admin setting rather than a constant in the
mobile app, and the app will use whatever is configured.

---

## 4. 🟢 Optional: an in-stock parameter

`GetProductService` passes `include_out_of_stock_products: true`
unconditionally, and there is no parameter to change it. The app's "In stock
only" toggle therefore filters **the page that came back**, which has two
visible costs:

* infinite scroll has to be disabled while it is on — the server cannot be asked
  for "more products that are in stock";
* a page of 20 can come back with 3 rows after filtering.

An `in_stock=1` parameter (or `include_out_of_stock_products=0`) would make it a
real filter. Low priority — the toggle works, it just does not paginate.

---

## 5. ℹ️ For the record — not a bug

`?categories[]=17` returning 0 products while
`/product-categories/17/products` returns 5 is **correct**.
`ProductCategoryController::products` merges the category *and its children*
into the parameter, and 17 is a parent whose products live in its children.
Passing leaf ids filters correctly. Our own notes had this recorded as a defect;
that was wrong.

---

## Suggested order

1. **#1 + #3 together** — both are additions to `FilterResource`, one commit,
   maybe 20 minutes. Unlocks the collections filter with no app release needed.
2. **#2** — the price bug. Worth fixing for the website too.
3. **#4** — whenever convenient.

Questions about any of this: the app-side notes, with the same evidence, are in
`docs/BACKEND_BUGS.md` §16 and `docs/MOBILE_API_INTEGRATION_PLAN.md` §J3.

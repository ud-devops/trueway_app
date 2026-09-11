# Backend patch — a product count on the category list

**Goal:** let the app hide categories that have nothing to sell, without firing
one request per category from the home screen.

**Status:** nothing has been changed in the app. The filter is not written and
will not be until this field exists — a client-side count would cost 10 extra
requests on every home load and every pull-to-refresh.

---

## Why the app cannot do this on its own

| Where a count could come from | Reality |
|---|---|
| `GET /ecommerce/product-categories` | Returns `id, name, icon, icon_image, is_featured, parent_id, slug, image_with_sizes`. **No count.** |
| `GET /ecommerce/products` | Product rows carry no category ids at all, so the app cannot derive it. |
| `GET /ecommerce/product-categories/{id}/products` | Works, but it is **one request per category** — 10 on this catalogue — and the smallest page this API accepts is 12 full product objects. |

---

## The change — two lines

### 1. `ProductCategoryController@index`

`platform/plugins/ecommerce/src/Http/Controllers/API/ProductCategoryController.php:32`

```php
        $categories = ProductCategory::query()
            ->wherePublished()
            ->withCount('products')            // <-- ADD
            ->orderBy('order')->latest()
```

### 2. `API/ProductCategoryResource`

`platform/plugins/ecommerce/src/Http/Resources/API/ProductCategoryResource.php`

```php
            'parent_id' => $this->parent_id,
            'slug' => $this->slug,
            'products_count' => $this->products_count,        // <-- ADD
```

⚠ There are **two** files named `ProductCategoryResource.php`. The one to edit is
under `Http/Resources/**API**/` — the other serves the web theme.

---

## The question worth deciding while you are in there

`withCount('products')` counts products attached to **that category only**. On
this catalogue that is not the whole story:

```
Wheat & Wheat Flour      5 direct    + 3 in its child "Sona Moti Wheat"   = 8
Millets                  0 direct    + 0 across 2 children                = 0
Spices & Herbs           0 direct    + 0 across 3 children                = 0
```

So a parent whose products all live on its children would report `0` and the app
would hide a category that is actually full. That is not hypothetical — it is
already how `Sona Moti Wheat` is stocked.

**Please make the count include descendants**, or add a second field
(`products_count_with_children`) so the app can tell the two apart. Botble's
`ProductCategoryHelper` already resolves a category's child ids for the storefront;
the same list can feed the count.

---

## While you are in this controller — an unrelated inconsistency

Two ways to ask for one category's products disagree:

```
GET /ecommerce/product-categories/17/products   -> meta.total = 5
GET /ecommerce/products?categories[]=17         -> meta.total = 2
```

Same category, same catalogue, two answers. The app uses the path route. Worth a
look, but it does not block this change.

Also note `?category_id=17` and `?category=17` are both **silently ignored** —
they return all 6 products rather than 422ing. A client that guesses the
parameter name gets an unfiltered list that looks like a working filter.

---

## What the app will do once the field lands

`categoriesProvider` already nests the flat list through `Category.buildTree()`,
so the home strip renders roots only. The filter becomes one `where` on that
result — no new request, no new endpoint.

## Verifying after deploy

```bash
curl -s -H "X-API-KEY: <API_KEY>" -H "Accept: application/json" \
     "https://dev.truewayerp.com/api/v1/ecommerce/product-categories" \
  | jq '.data[] | {name, parent_id, products_count}'
```

On today's catalogue, expect a non-zero count on **Wheat & Wheat Flour** (8 if
descendants are included, 5 if not) and `0` on the other nine parents.

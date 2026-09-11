# Verified API Contract — Authenticated Surface

Base URL: `https://dev.truewayerp.com/api/v1`

Every contract below was exercised live against the dev backend as customer 16
(4 independent probe runs: address book, wishlist/compare, checkout, profile).
Where a success path could not be reached without destroying or creating real
data, it is marked **UNVERIFIED** with the exact steps needed to close it.

**Credentials are never written into this document.** All examples use
`<BEARER_TOKEN>` (Sanctum personal access token) and `<API_KEY>`
(the `X-API-KEY` value). Do not paste real values into this file.

This document supersedes `docs/MOBILE_API_INTEGRATION_PLAN.md` wherever the two
disagree. The plan doc was written from the backend *route file*; this one is
written from *observed responses*.

---

## 0. Traps and corrections — read this before writing any code

These are the findings that break a naive implementation silently — the code
compiles, the tests pass, and the feature is dead in production.

### 0.1 Corrections to `docs/MOBILE_API_INTEGRATION_PLAN.md`

| Plan doc | Reality | Where |
|---|---|---|
| §1 line 51: `/ecommerce/wishlist/{id}` · `/compare/{id}` — `GET/POST/DELETE` | Correct for the `{id}` form, but the **bare** `/ecommerce/wishlist` is **POST-only**. `GET /ecommerce/wishlist` returns HTTP **404** with `"The GET method is not supported for route api/v1/ecommerce/wishlist. Supported methods: POST."` There is no way to list wishlists. | §3.1 |
| §J: "Wishlist — same UUID-identifier pattern as cart" | True, and worse than implied: the wishlist is **fully anonymous**. The bearer token is *ignored*, not merely optional. Two consecutive authenticated `POST`s from the same account minted two different UUIDs. There is **no account-bound wishlist** anywhere on this API. | §3.0 |
| §J implies wishlist/compare/cart can share the identifier pattern | They share the identifier **keyspace**. Using one identifier for two list types **destroys both**. The app must store three separate identifiers. | §3.0 |
| §G lines 347–348: address fields "from `CheckoutRequest`": `name*, email, phone, address*, city*, state, district, country*, zip_code, other_city` | Wrong on five counts. The address book does **not** use `CheckoutRequest`'s rules. `district`/`other_city` are checkout-only and silently ignored by the address book. `is_default` (the whole point of an address book) is missing from the list. The read-only `full_address` is missing. And there is no single required set — POST, PUT and checkout each require a **different** set. | §1.0 |
| §1 line 62: `/ecommerce/addresses` — `GET/POST/PUT/DELETE` | Implies a symmetric REST resource. There is **no `GET /ecommerce/addresses/{id}`** and **no `PATCH`**. Collection = `GET, HEAD, POST`. Item = `PUT, DELETE` only. | §1.3 |
| §H1 line 364: checkout body `{"address": {...}}` | Correct on required sub-fields. But a saved-address **reference is not accepted** — neither `{"address":{"id":16}}` nor top-level `{"address_id":16}`. The picker must inline the full address every time. | §2.2 |
| §H1: `payment_method` is shown as part of the required body | `payment_method` is **nullable**. An order passes validation with no payment method at all. | §2.2 |
| §H1: only `address` documented | There is a second, undocumented key `shipping_address` with an identical sub-schema; either one satisfies the requirement. | §2.2 |
| §D4 line 243: "`/logout` — Revokes **all** tokens for the customer" | **UNSUPPORTED.** Nothing in any probe establishes this. The same unverified claim is repeated in `lib/data/repositories/auth_repository.dart:199` as though settled. See §4.3 for how to verify. | §4.3 |
| §D4 line 246: "`/notifications`, `/device-tokens` — Push-notification infrastructure, unused" | Both exist and are **partly broken server-side** (device tokens are orphaned; the app's notification parser can never return a row). Neither is safe to treat as ready. | §4.4, §4.5 |
| Open question 5: "Are shipping rates server-calculated, or does the app send `shipping_amount`?" | **Answered: SERVER-CALCULATED, and the app does NOT send `shipping_amount`.** The app sends `shipping_method: "shiprocket"` + `shipping_option: "shiprocket_<rateId>"` and omits the amount. `API/CheckoutController.php:425` sets `$useClientShippingAmount = $request->has('shipping_amount')` and `:445` skips the server's own pricing when that is true — so **omitting the field is what turns server pricing on**. The rate list does exist: `POST /logistics/check-serviceability` (`VERIFIED_API_CONTRACT.md` §4.2). The field's `nullable\|numeric\|min:0` rules are still a real server-side tampering hole for *other* clients — that is a security finding, not this app's contract. See §5.1. | §5.1 |

### 0.2 Traps that silently break a naive implementation

1. **`GET /ecommerce/checkout/cart/{cartId}` EMPTIES THE CART.** Reading the
   checkout summary is destructive. Isolated and reproduced three times with
   controls: plain `GET /ecommerce/cart/{id}` and 422-ing checkout `POST`s leave
   the cart intact; this one `GET` takes `count` from 1 to 0 and every
   subsequent call 404s. The obvious mobile flow — open checkout screen (GET),
   fill the address form, submit (POST) — **cannot work**. It also requires no
   auth, so anyone holding a `cartId` can empty that cart. See §2.3.

2. **`DELETE /ecommerce/wishlist/{id}` with a product that is not in the list
   WIPES THE WHOLE LIST.** Returns 404 *and* clears it. Reproduced three times
   (3 items → 0, 1 item → 0, compare 1 item → 0). A stale client list is exactly
   when you would fire a redundant delete. **Do not ship DELETE on these routes**
   — the `POST /{identifier}` toggle removes present items with a safe (422)
   failure mode. See §3.4.

3. **Wishlist / compare / cart share one storage keyspace per identifier and
   mutually destroy each other.** A compare list under identifier `X`, then
   `GET /ecommerce/wishlist/X` → the compare list is now empty. Verified in both
   directions, and against a real server cart. Store `cart_identifier`,
   `wishlist_identifier` and `compare_identifier` separately and never cross
   them. See §3.0.

4. **`GET /me`'s `avatar` is a ~3 KB base64 JPEG regenerated with a RANDOM
   background colour on every request.** Five consecutive calls gave five
   different SHA-1s. It is 85–95% of the entire 4.1–4.4 KB `/me` response, can
   never be cached or diffed, and the app persists it to `SharedPreferences`
   (`auth_provider.dart:300`) on every profile refresh — a genuinely different
   4 KB write each time — while rendering `customer.initials` instead. Drop
   `avatar` from the persisted `Customer`. See §4.1.

5. **The app's notification list is hard-wired empty.**
   `lib/data/repositories/notification_repository.dart:30` calls
   `unwrapList(res.data, …)`, which returns `const []` unless `body['data']` is a
   List. The server returns `data` as an **object**
   `{notifications:[…], pagination:{…}, unread_count:int}`. The list can never
   contain a row, for any customer, ever. Must read
   `res.data['data']['notifications']`. Invisible today only because the test
   account has zero notifications. See §4.4.

6. **`error` is sometimes a bool and sometimes a string.** Six distinct
   envelopes exist across this API (§6). Critically:
   `{"error":true,…}` on a bearer 401 but `{"message":…,"error":"Unauthorized"}`
   on an API-key 401. Any interceptor doing `json['error'] as bool` or
   `body['error'] == true` crashes or misreads on the API-key path.

7. **Method-not-allowed is served as HTTP 404, not 405** — with the 405 text in
   the body. A `404` handler that assumes "not found" will mis-handle every
   wrong-verb call.

8. **`Accept: application/json` is load-bearing.** Without it, an auth failure
   returns **302 + text/html** redirecting to `/login`. Dio follows redirects by
   default and hands your JSON decoder an HTML page — surfacing as a
   200-with-HTML, not a 401, so `onUnauthorized` never fires. Set the header
   globally (`api_client.dart:24` already does) and disable redirect-following.

9. **`POST /ecommerce/checkout/taxes/calculate` trusts a client-supplied
   `price`.** `id:118` alone → total 1199.10; the same call with `price:1` →
   total 1.05; `price:-500` → total −525 rendered as a positive `"Rs500.00"` in
   `price_formatted`. The endpoint is public (no bearer). See §5.2.

10. **`data.items` on wishlist/compare flips TYPE with emptiness** — a JSON
    object keyed by rowId when `count > 0`, an empty **array** `[]` when
    `count == 0` (PHP `json_encode` artefact). A `Map<String,dynamic>` cast
    crashes on the empty case.

11. ~~**`state` and `city` on addresses are unresolvable numeric ids.**~~
    **SUPERSEDED 2026-08-12 — the backend shipped both halves.** The columns
    still store `state: "11"`, `city: "574"`, but `AddressResource` now sends
    `state_name`/`city_name` beside them, and **`/ecommerce/states` and
    `/ecommerce/cities?state=<id>` exist** (they did not when this was written;
    the backend's own note gives them without the `/ecommerce` prefix, and those
    paths are 404). Nothing needs resolving client-side any more. See §1.0.

12. **`dob` does not round-trip.** `GET /me` returns
    `"2000-04-27T18:30:00.000000Z"`; `PUT /me` enforces `date_format:d-m-Y`.
    Feeding the value straight back is a 422.

13. **`PUT /me` is not patch-able and its 422 has no `errors` map.** Every call
    must resend `name` (or `first_name`+`last_name`), and all field messages are
    concatenated into one `message` string — per-field error attribution on a
    form is impossible without string matching. See §4.2.

14. **`POST /device-tokens` is not behind auth**, and every token it writes is
    orphaned — `GET /device-tokens` always returns `[]`, `PUT`/`DELETE` on the
    returned id always 404. Push registration currently cannot work. See §4.5.

15. ~~**`POST /ecommerce/addresses` accepts unknown keys silently.**~~
    **RESOLVED 2026-08-12.** `landmark`, `district` and `other_city` are now
    real, validated (`max:120`) and persisted — confirmed by reading a created
    row back. An invented key is still silently dropped, so the caution stands
    for anything outside the documented set.

---

## 1. Family: Address book — `/ecommerce/addresses`

### 1.0 The write contract — re-probed live 2026-08-12

**POST and PUT now agree.** The old three-way split is gone; the headline
consequence it carried — a row created through the lenient POST rules could
*never be edited*, because PUT 422'd on five fields POST let you omit — is gone
with it. Both verbs were re-probed by sending an empty body:

```
POST /ecommerce/addresses  {}  -> name, phone, state, city, address, zip_code
PUT  /ecommerce/addresses/{id} {}  -> name, phone, state, city, address, zip_code
```

| Field | address book (POST = PUT) | checkout `address.*` |
|---|---|---|
| `name` | **required**, max 191 | **required**, max 255 |
| `phone` | **required**, `^[6-9][0-9]{9}$`, as a **string** | optional, **max:20 only** |
| `email` | optional, email, max 60 | optional, email, max 255 |
| `address` | **required**, max 191 | **required**, max **500** |
| `state` | **required**, and **`exists`** — see below | optional, max 120 |
| `city` | **required**, **not validated at all** | **required**, max 120 |
| `zip_code` | **required**, max 20 | optional, max 20 |
| `landmark` | optional, max 120 | optional, no rule |
| `district` | optional, max 120 | optional, max 120 |
| `other_city` | **required when `city == "other"`**, max 120 | optional, max 120 |
| `is_default` | optional, `boolean` | n/a |
| `country` | **ignored** — server fills it | **required**, max 120 |

#### `state` must be an id; a name is a 422

```
state: "11"              -> 201
state: "Gujarat"         -> 422 "The selected state is invalid."
state: "9999"            -> 422 "The selected state is invalid."
```

This is a **breaking change for legacy rows**: three of the twenty-nine live
addresses store a state *name* (row 50 holds `"Madhya Pradesh"`), and those rows
can no longer be PUT as they stand — including by "set as default", which is a
full PUT. They have to be edited and their state re-picked first.

#### `city` is not validated at all

`city: "999999"`, `city: "Ahmedabad"` and a city id belonging to a *different*
state are all accepted and stored verbatim. See `BACKEND_BUGS.md` §20.

#### `country` is not sent

The store ships to one country and the server fills `country_id` from its own
setting; anything sent is ignored (a row POSTed with `country: "India"` comes
back with the same `country_id: "IN"` as one POSTed without). Sending the
rendered **name**, which is what this app used to do, overwrote the stored id.

#### The read shape — 18 keys, identical on list, create and update

```
id, name, is_default, phone, email,
country, country_id, country_name,
state, state_name, district,
city, city_name, other_city,
address, landmark, zip_code, full_address
```

`country`/`country_name` are rendered names; `country_id` is the ISO code.
`state_name`/`city_name` are resolved by `LocationTrait` and fall back to the
stored value when it cannot be resolved — so they are *usually* names, not
*always*.

⚠ For an other-city row, `city_name` and `full_address` both render the literal
word `other` rather than `other_city`. See `BACKEND_BUGS.md` §19.

### 1.0a Lookups — `/ecommerce/states`, `/ecommerce/cities`

```
GET /ecommerce/states?country=IN   -> 36 rows, ~1.1 KB
GET /ecommerce/cities?state=11     -> 306 rows
```

Envelope `{error, data: [{id, name}], message}` on both. `?country=` makes no
difference on `states` (single-country store); `?state=` really does filter on
`cities`.

⚠ **The paths carry the `/ecommerce` prefix.** `GET /states` and `GET /cities`
— as the backend's note gives them — are both 404.

⚠ The cities list ends with `{"id": "other", "name": "Other"}`, whose `id` is a
**String**. An unconditional int parse throws on it, and dropping it as noise
removes the only escape hatch a customer with an unlisted town has.

### 1.0b PIN autofill — there is no store endpoint for it

The address form fills state, city and district in from the PIN code. **None of
that data comes from this backend**, because none of it exists here:

| Probed | Result |
|---|---|
| `POST /logistics/check-pincode` | 200, but the body is `{deliverable, estimated_delivery_days, shipping_charge, courier_name, cod_available}` — **no state, city or district at all** |
| `GET /ecommerce/districts`, `?state=11`, `/districts` | 404 |
| `GET /ecommerce/pincode/{pin}`, `/zip/{pin}`, `/postcode/{pin}` | 404 |
| `GET /ecommerce/cities?state=11&district=1` | 200, and the `district` parameter is **ignored** — 306 rows either way |

So the app calls India Post's public service directly
(`GET https://api.postalpincode.in/pincode/{pin}`, no key), in
`PincodeRepository`, on its own Dio with the bearer token and `X-API-KEY`
explicitly stripped. What it returns is **matched against this backend's own
`states`/`cities` lists** and dropped when it does not match — the app never
posts a name or an id the store did not give it.

Matching notes, probed against the live lists:

* State names match exactly for all 36 rows ("Madhya Pradesh", "Gujarat",
  "Delhi").
* The **District** is the city candidate that works: Gwalior → city 1579,
  Ahmedabad → 574, Central Delhi → 504. `Block` mostly does not — 382415 reports
  `Block: "Ahmadabad City"` and there is no such city row.
* One PIN can span two districts (110001 → "Central Delhi" and "New Delhi"),
  which is why the form offers a district picker instead of filling one in.

**If the backend ever adds a lookup** — ideally
`GET /ecommerce/pincode/{pin}` returning `state` (id), `city` (id) and
`district` (name) — swapping to it is one repository and no UI change, and it
would remove the third-party dependency and the name-matching entirely.

**Client rule set:** require `name`, `phone`, `address`, `state`, `city`,
`zip_code`; post `state`/`city` as **ids chosen from the lists above**; send
`other_city` only when `city == "other"`; never send `country`.

> **`email` is optional, and the app no longer asks for it.** This document
> previously said checkout refuses an address with none. **That was wrong** and
> was never probed — it was repeated into `CheckoutAddressRules`, `AddressDraft`
> and the address form. Corrected against the backend source and the live
> database (2026-08-18):
>
> * `CheckoutRequest` marks `address.email` / `shipping_address.email`
>   `nullable`; `EcommerceHelper`'s address rules are
>   `['email','nullable','max:60','min:6']`. An email-less address passes the
>   live validator.
> * `address.email` is required on the **web** only for guests
>   (`CheckoutRequest:100-101`), and `ecommerce_enable_guest_checkout = 0`.
> * Registration only makes email optional when
>   `ecommerce_login_option == 'phone'`; this store runs `email_or_phone`, so
>   all 26 customers have one and all 34 addresses carry one.
> * Order mail: `$order->user->email ?: $order->address->email`
>   (`OrderHelper:320`), inside try/catch — the **account** is the real channel.
>
> The app still sends the account's email with an address so an existing value
> survives an edit; `AddressController` saves `validated()` and fills nothing
> in.

### 1.1 `GET /ecommerce/addresses`

**Request**

```
GET /ecommerce/addresses?page=1
X-API-KEY: <API_KEY>            (required)
Accept: application/json        (required)
Authorization: Bearer <BEARER_TOKEN>   (required)
```

No body.

**Pagination**

- `page` — int, honoured. `page=0` and `page=-1` both coerce to page 1.
- `per_page` — **accepted and silently ignored**. `per_page=2` and `per_page=abc`
  both returned all 6 rows with `meta.per_page = 10`. Page size is hard-coded
  at 10 and cannot be changed.
- Page beyond `last_page` → **HTTP 200** with `data: []` and
  `meta.from`/`meta.to` = `null`. Not a 404.
- `is_default`, `search`, `sort` are accepted and ignored.

**Response envelope — HYBRID** (carries `data`/`links`/`meta` *and*
`error`/`message` simultaneously; this pattern appears nowhere else in the API):

```jsonc
{
  "data":  [ /* Address[] */ ],
  "links": { "first": "string", "last": "string",
             "prev": "string|null", "next": "string|null" },
  "meta":  { "current_page": 0, "from": 0,        // int|null
             "last_page": 0,
             "links": [{ "url": "string|null", "label": "string",
                         "page": 0, "active": false }],
             "path": "string", "per_page": 10,    // always 10
             "to": 0, "total": 0 },
  "error": false,
  "message": null
}
```

**Address object — exactly 11 fields, no more:**

| Field | Type | Notes |
|---|---|---|
| `id` | int | |
| `name` | string | |
| `is_default` | **int** `1`\|`0` | INT on read, `boolean` on write |
| `phone` | string | bare 10 digits, no country code |
| `email` | string | nullability **UNVERIFIED** (all 6 rows populated) |
| `country` | string | the **name** (`"India"`), never the code `"IN"` |
| `state` | string | mixed: `"11"` (id) or `"Madhya Pradesh"` (name) |
| `city` | string | mixed: `"574"` (id) or `"Gwalior"` (name) |
| `address` | string | street line only |
| `zip_code` | string | string, not int |
| `full_address` | string | read-only, server-rendered composite |

Absent: `created_at`, `updated_at`, `customer_id`, `district`, `other_city`,
`country_code`, `state_name`, `city_name`.

Ordering (6/6 rows observed): `is_default DESC, id DESC`.

**`full_address` contains a segment present in no readable field.** Address 16:
`address` = `"306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad"` but
`full_address` = `"306, …, Ahmedabad, sda etasd, Ahmedabad, Gujarat, 382415"`.
Address 45 has an extra `"near palican paradise"`. Most likely `district` —
**UNVERIFIED**. The server *does* resolve numeric ids internally: row 16 has
`state:"11"`, `city:"574"` yet `full_address` reads `"…, Ahmedabad, Gujarat, …"`.

**Errors**

| Status | Body |
|---|---|
| 401 | `{"error":true,"data":null,"message":"Unauthenticated."}` — missing/invalid bearer |
| 401 | `{"message":"Invalid or missing API key. Please provide a valid X-API-KEY header.","error":"Unauthorized"}` — `error` is a **STRING** here |
| 302 | `text/html` redirect to `/login` when `Accept` omitted **and** auth fails |

### 1.2 `POST /ecommerce/addresses`

> ⚠ **The rule list below is the pre-2026-08-12 contract and is now wrong** —
> POST gained four required fields and lost `country`. Kept for the response
> shapes, the error table and the `handleDefaultAddress` behaviour, all of which
> still hold. **§1.0 is the authority on what is required.**

**Request** — headers as above plus `Content-Type: application/json`
(`application/x-www-form-urlencoded` also accepted). Body is **flat JSON**;
sending `{"address":{…}}` yields `"The address must be a string."`

```
name        REQUIRED | string | max:191
phone       REQUIRED | string | numeric | digits:10 | regex ^[6-9][0-9]{9}$
email       optional | email
address     optional | string | max:191
country     optional | string | max:120   <- FREE TEXT, no exists/in rule
state       optional | string | max:120   <- FREE TEXT
city        optional | string | max:120   <- FREE TEXT
zip_code    optional | string | max:20    <- no numeric rule
is_default  optional | nullable | boolean
```

Only `name` and `phone` are required — an empty body returns exactly two errors.

**`phone` evidence** (every probe kept `email` invalid as a guard so nothing
could be created):

- PASS: `"9876543210"`, `"6000000000"`, `"7000000000"`, `"8000000000"`, `"9000000000"`
- FAIL "format is invalid": `"4000000000"`, `"1234567890"`, `"0123456789"`, `"5555555555"`
- FAIL `"must be 10 digits"` + `"format is invalid"`: `"987654321"` (9 digits), `"+919876543210"` (E.164)
- FAIL `"must be a number"` + `"must be 10 digits"` + `"format is invalid"`: `"987-654-3210"`
- FAIL `"The phone must be a string."`: the same value sent as a JSON **integer** rather than a quoted string

Landlines and E.164 (`+91…`) are rejected outright.

**`is_default` accepted:** `true`, `false`, `1`, `0`, `"1"`, `"0"`, `null`.
**Rejected:** `"true"`, `"false"`, `"yes"`, `2` → *"The is default field must be
true or false."*

**`country`/`state`/`city` are free text** — `country:"ZZ-NOT-A-COUNTRY"`,
`state:"999999"`, `city:"999999"` produced **no error**.

**Response — 422 is a bare Laravel validation object with NO `error` key:**

```jsonc
{ "message": "<first message> (and N more errors)",
  "errors":  { "<field>": ["<msg>", …] } }
```

> **UNVERIFIED — success (2xx) shape.** Creating an address was forbidden by the
> probe safety rules. Do **not** assume it echoes the created Address or uses the
> `{data,links,meta,error,message}` hybrid.
> **To verify:** one real `POST` from a disposable staging account, capturing the
> full body and status.

> **UNVERIFIED — `is_default` write semantics.** Whether the server demotes the
> previous default is unproven. Observable only: exactly one of six rows has
> `is_default = 1` and it sorts first — consistent with, but not proof of,
> server-side demotion. If it does not demote, the app must issue a second `PUT`
> or the list renders two defaults.
> **To verify:** create/update an address with `is_default:true` on a disposable
> account, then re-list and count rows with `is_default == 1`.

### 1.3 `PUT /ecommerce/addresses/{id}`

> ⚠ **Same caveat as §1.2** — PUT no longer requires `email` or `country`, and
> `state` is now `exists`-validated. **§1.0 is the authority.**

**The rules are NOT the same as POST.** This is a **full replace** — there is no
partial/patch semantics.

```
name        REQUIRED | string | max:255   <- 255, not 191
email       REQUIRED | email              <- REQUIRED here, optional on POST
phone       REQUIRED | string | numeric | digits:10 | ^[6-9][0-9]{9}$
country     REQUIRED | string | max:120   <- REQUIRED here
state       REQUIRED | string | max:120   <- REQUIRED here
city        REQUIRED | string | max:120   <- REQUIRED here
address     REQUIRED | string | max:255   <- REQUIRED here; 255 not 191
zip_code    optional | string | max:20
is_default  optional | nullable | boolean
```

An empty body on an owned id returns **seven** required errors.

**Request-pipeline ordering, verified:** route-model binding (404) →
authorization gate (403) → validation (422). An empty body against a
non-existent id returns 404, never 422.

**Errors**

| Status | Body | Meaning |
|---|---|---|
| 422 | bare `{message, errors}` | validation |
| 404 | `{"message":"No query results for model [Botble\\Ecommerce\\Models\\Address] 99999999"}` | id does not exist (leaks the Eloquent class) |
| 403 | `{"message":"This action is unauthorized."}` | id exists, belongs to another customer (confirmed on id 30) |
| 404 | `"The PATCH method is not supported for route api/v1/ecommerce/addresses/16. Supported methods: PUT, DELETE."` | **no PATCH** |
| 404 | `"The GET method is not supported for route api/v1/ecommerce/addresses/16. Supported methods: PUT, DELETE."` | **no show-one endpoint** |

> **Route table, authoritative** (from Laravel's own method-not-allowed text):
> collection = `GET, HEAD, POST`; item = `PUT, DELETE`.
> To refresh one address after an edit you must **re-fetch the whole list**.

> **UNVERIFIED — success (2xx) shape.** Same reason and same fix as §1.2.

**Minor security:** the 404-vs-403 split is an enumeration oracle — any
authenticated customer can map which address ids exist globally. Worth reporting
to the backend team; not app-blocking.

### 1.4 `DELETE /ecommerce/addresses/{id}`

No body. Same auth headers. Only the error path was exercised.

- 404 non-existent id → `{"message":"No query results for model [Botble\\Ecommerce\\Models\\Address] {id}"}`
- 404 on the collection route → `"…Supported methods: GET, HEAD, POST."`

> **UNVERIFIED — success shape, and the 403 gate.** The 403 ownership gate is
> proven for `PUT` only; `DELETE` was deliberately **not** sent against another
> customer's id (30) because a missing gate would have destroyed real data.
> **To verify:** on a disposable account, create two addresses, delete one and
> capture the 2xx body; separately, have a second disposable account attempt
> `DELETE` on the first account's id and confirm 403.

> **UNVERIFIED — deleting the default address.** Does the server promote another
> row, or leave the customer with zero defaults? Must be answered before wiring a
> delete button.

### 1.5 `GET /ecommerce/countries`

Public-ish: `X-API-KEY` + `Accept` required; works with or without a bearer.
Query params ignored.

**Envelope — `error-data-message`:**

```jsonc
{ "error": false,
  "data": [ { "name": "string", "code": "string|int" } ],
  "message": null }
```

The **entire** live payload is two entries:

```json
[ { "name": "Select country...", "code": 0 },
  { "name": "India",             "code": "IN" } ]
```

`code` is **polymorphic** — the integer `0` for the placeholder, the string
`"IN"` for the real row. A Dart model declaring `String code` throws on element 0.

**Critical binding note — now moot for the address book.** Stored addresses
render `country = "India"` (the NAME) and `country_id = "IN"`, but the write
side **ignores whatever you send** and fills it server-side, so nothing needs
picking. This section survives only for the checkout body, which still carries a
`country` field.

### 1.6 ~~`GET /ecommerce/states` / `/ecommerce/cities` — **DO NOT EXIST**~~

**SUPERSEDED 2026-08-12 — both routes now exist.** The eight 404s recorded here
were real at the time; the backend shipped the lookups afterwards. Full contract
in **§1.0a**, and the short version is:

```
GET /ecommerce/states?country=IN   -> {"error":false,"data":[{"id":11,"name":"Gujarat"},…]}
GET /ecommerce/cities?state=11     -> same envelope, 306 rows, last row id "other"
```

Everything this section concluded is therefore reversed:

* a state/city dropdown **is** buildable, and is now mandatory rather than
  optional — `state` is `exists`-validated and a plain name is a 422, so the
  old advice to "write plain names for new addresses" would make every new
  address unsaveable;
* `city`/`state` are still write-back tokens, but they are **ids** and the row
  now carries `state_name`/`city_name` beside them, so `full_address` is no
  longer the only resolved text;
* `GET /ecommerce/orders/277`'s `shipping_info` gained `landmark`, `district`,
  `other_city` and `full_address`. The order screens read `full_address` when it
  is there and compose the line themselves when it is not (the public tracking
  route still serves raw ids into the same shape).

---

## 2. Family: Checkout — `/ecommerce/checkout/*`

### 2.1 `POST /ecommerce/cart` (anonymous — context only)

Included because checkout needs a `cartId`. No bearer needed.
Body `{"product_id": int, "qty": int}`.

Response is a **bare object, no envelope**: `{id: uuid, cart_items: {<rowId>:{…}},
count, total_weight, …, package_dimensions:{…}, raw_sub_total, raw_total,
promotion_discount_amount, coupon_discount_amount, applied_coupon_code,
discounted_sub_total, discounted_tax_amount, order_total, status: bool,
content:{…}}` — each money field with a `*_formatted` twin.

`GET /ecommerce/cart/{id}` is **safe** (non-destructive) — verified three times.

### 2.2 `POST /ecommerce/checkout/cart/{cartId}` — place order

**Auth required.** Headers: `X-API-KEY`, `Accept: application/json` (mandatory),
`Authorization: Bearer <BEARER_TOKEN>`. Accepts both `application/json` and
`application/x-www-form-urlencoded` (`address[name]=…` produced byte-identical
validation output).

**Complete validated field set — nine top-level fields:**

| Field | Rules |
|---|---|
| `address` | array, `required_without:shipping_address` |
| `shipping_address` | array, `required_without:address` — **identical sub-schema** |
| `billing_address` | nullable array, **no sub-field rules at all** (`{}` and `{"zzz":1}` both pass) |
| `payment_method` | **nullable** (NOT required), `in: cod, razorpay, pay_online, online, credit_card, paypal, bank_transfer` |
| `shipping_method` | nullable string, **no max, no enum** (accepted `"__BAD__"` and 300 chars) |
| `shipping_option` | nullable string, no max, no enum |
| `shipping_amount` | nullable numeric, `min:0`, **no max** (`99999999999` accepted) — ⚠ **do not send it**, see below |
| `currency` | nullable string, max:3 |
| `charge_id` | nullable string, max:255 |

⚠ **`shipping_amount` is a mode switch, not an optional hint.**
`API/CheckoutController.php:425` reads `$request->has('shipping_amount')`, so
sending the key **at all — including as `null`** — disables the server's own
shipping pricing (`:445`) and makes `:455` use whatever the client sent. The app
sends `shipping_method: "shiprocket"` + `shipping_option: "shiprocket_<rateId>"`
and **omits** `shipping_amount`, which is what makes the server price the order.
See §5.1 and `VERIFIED_API_CONTRACT.md` §4.5.

**`address.*` / `shipping_address.*` sub-schema:**

| Field | Rules |
|---|---|
| `name` | required_with parent, string, max **255** |
| `address` | required_with parent, string, max **500** |
| `city` | required_with parent, string, max 120 |
| `country` | required_with parent, string, max 120 — **no ISO validation**, `"__BAD__"` accepted |
| `email` | nullable, email, max 255 |
| `phone` | nullable, **max:20 only** — no format check, `"@@@@"` passes |
| `state` | nullable, string, max 120 |
| `zip_code` | nullable, string, max 20 |

**Not in the validator at all** (accepted with any type, produce no error, so
ignored or blindly discarded): `coupon_code`, `description`, `amount`,
`sub_total`, `tax_amount`, `discount_amount`, `order_note`, `note`,
`transaction_id`, `customer_id`, `created_account`, `payment_type`,
`marketplace`, `shipping`, `order_id`, `address_id`, and any top-level
`name`/`email`/`phone`/`city`/`state`/`zip_code`/`country`.

**Coupons are not a checkout field** — they must be applied via the separate
cart-coupon endpoints before checkout.

**No saved-address shortcut.** `{"address":{"id":16}}` and top-level
`{"address_id":16}` both still return all four *"required when address is
present"* errors. The full address must be inlined on every checkout.

**Minimal body that would pass validation** (deliberately **not** sent — it would
place a real order):

```json
{"address":{"name":"…","address":"…","city":"…","country":"…"}}
```

`payment_method` is not needed to pass validation.

**Response — 422 is bare (no `error` key):**

```jsonc
{ "message": "Either address or shipping_address is required. (and 1 more error)",
  "errors": { "address": ["Either address or shipping_address is required."],
              "shipping_address": ["Either address or shipping_address is required."] } }
```

Error keys use **dot notation** — `"address.name"`, `"shipping_address.phone"`.
A Dart error mapper keyed on flat field names will not match.

**Message-text rendering is inconsistent — never parse `message`, always key off
`errors{}`:** `"The address.state must be a string."` but
`"The address.zip code must be a string."` (underscore stripped) but
`"The email must be a valid email address."` (prefix dropped entirely) under key
`address.email`.

**Error cases**

| Trigger | Result |
|---|---|
| `{}` | 422, `address` + `shipping_address` both *"Either address or shipping_address is required."* |
| `{"address":{}}` | same — an empty object counts as **absent** |
| `address:"foo"` | *"The address must be an array."* + 4 sub-field required errors |
| `address:{"zzz":1}` | the 4 sub-field required errors only |
| `payment_method:"not_a_method"` | *"The payment method must be one of: cod, razorpay, pay_online, online, credit_card, paypal, bank_transfer."* |
| `shipping_amount:"abc"` | *"The shipping amount must be a number."* |
| `shipping_amount:-999` | *"The shipping amount must be at least 0."* (`0`, `0.01`, `"0"`, `99999999999` all pass) |
| `currency:"__BAD__"` | *"…must not be greater than 3 characters."* |
| no/bad bearer | 401 `{"error":true,"data":null,"message":"Unauthenticated."}` |
| missing `X-API-KEY` | 401 `{"message":"Invalid or missing API key…","error":"Unauthorized"}` |
| no `Accept` + no bearer | **302** text/html redirect to `/login` |
| `PUT`/`DELETE` on this path | **404** (not 405) |

**Validation runs BEFORE cart resolution.** A nonexistent uuid and the non-uuid
string `"notauuid"` both returned the ordinary address-required 422. A 422 from
checkout tells you **nothing** about whether your `cartId` is valid.

**`payment_method` enum is wider than what is offered.** The validator accepts 7
values; `GET checkout` advertises only 4 (`cod`, `razorpay`, `pay_online`,
`online`). `credit_card`/`paypal`/`bank_transfer` validate but are never offered
and have no confirm path (§2.5 is hard-coded to Razorpay). All 7 behave
identically at the validation layer — there are **no** conditional per-method
rules.

> **UNVERIFIED — success (2xx) shape.** The minimal passing body is one field
> short of what was probed; submitting it would place a real order on the live
> account. The plan doc §H1 asserts a `{success, data:{order_id, order_token, …,
> razorpay:{…}}}` shape — that is **from the route file, not from a response**.
> **To verify:** one real checkout on a disposable staging account, capturing
> whether the 2xx returns the order code, a Razorpay payment intent, or a
> redirect URL.

> **UNVERIFIED — cart-not-found and empty-cart error shapes.** Unreachable
> because body validation short-circuits first. The destructive GET (§2.3) gives
> a cheap way to produce an empty cart on demand for whoever captures this.

### 2.3 `GET /ecommerce/checkout/cart/{cartId}` — **DESTRUCTIVE**

**No auth required** — verified anonymously. Undocumented in the plan doc; found
by accident.

> ### ⚠ THIS GET EMPTIES THE CART
> Isolated and reproduced three times, with controls:
> create cart → plain `GET /ecommerce/cart/{id}` ×3 (count stays 1) →
> `POST` checkout with a 422 body (count stays 1) →
> `GET /ecommerce/checkout/cart/{id}` returns **200 with count 1** →
> **cart is now count 0**, and every subsequent call 404s.
>
> Treat as **single-shot**: call once, cache the response, never call it twice —
> or avoid it entirely and build the checkout screen from `POST /ecommerce/cart`
> output. Since it needs no auth, anyone holding a `cartId` can empty that cart.

**Response**

```jsonc
{ "success": true,
  "data": {
    "cart_id": "uuid",
    "cart_items": { "<rowId>": { /* same item shape as POST /ecommerce/cart */ } },
    "count": 0,
    "financial_summary": {
      "subtotal": 0, "subtotal_formatted": "string",
      "tax_amount": 0, "tax_amount_formatted": "string",
      "raw_total": 0, "raw_total_formatted": "string",
      "promotion_discount_amount": 0, "promotion_discount_amount_formatted": "string",
      "coupon_discount_amount": 0, "coupon_discount_amount_formatted": "string",
      "applied_coupon_code": null,
      "shipping_amount": 0, "shipping_amount_formatted": "string",
      "total": 0, "total_formatted": "string" },
    "available_payment_methods": [ { "value": "string", "label": "string" } ],
    "available_shipping_methods": [ { "value": "string", "label": "string" } ] } }
```

Live: 4 payment methods (`cod`/Cash on Delivery, `razorpay`/Razorpay,
`pay_online`/Pay Online, `online`/Online Payment) and **1** shipping method
(`default`/Default Shipping).

**Errors:** 404 `{"success":false,"message":"Cart not found or empty",
"errors":{"cart":["Cart is empty or expired"]}}` — same for an emptied cart, a
nonexistent uuid, and a non-uuid string. `PUT`/`DELETE` → 404 (not 405).

**Image inconsistency:** for the same item, `POST /ecommerce/cart` returns an
**absolute URL** in `image` and the full-size file in `image_url`; this GET
returns a **relative path** in `image` and the `-150x150` thumbnail in
`image_url`. One item renderer across both screens will show broken or low-res
images on one of them.

### 2.4 `POST /ecommerce/checkout/taxes/calculate`

**No auth required** — identical 200 with and without a bearer. Public.

**Request**

```jsonc
{ "products": [ { "id": 118,          // REQUIRED, must exist (exists: rule confirmed)
                  "quantity": 1,      // REQUIRED, integer, min:1
                  "price": 1142 } ] } // OPTIONAL and COMPLETELY UNVALIDATED
```

**The request key is `id`; the response key is `product_id`.** Sending
`product_id` fails with *"The products.0.id field is required."*

**Response — data-only, no `error` key, no links/meta:**

```jsonc
{ "data": {
    "items": [ { "product_id": 0, "price": 0, "price_formatted": "string",
                 "quantity": 0, "tax_rate": 0,
                 "tax_amount": 0, "tax_amount_formatted": "string",
                 "subtotal": 0, "subtotal_formatted": "string",
                 "total": 0, "total_formatted": "string" } ],
    "totals": { "sub_total": 0, "sub_total_formatted": "string",
                "tax_amount": 0, "tax_amount_formatted": "string",
                "total": 0, "total_formatted": "string" } } }
```

No pagination.

**Errors:** 422 for missing/invalid `products`, `products:[]` (empty array counts
as absent), missing `id`/`quantity`, `quantity` non-integer or `< 1`, and
`"The selected products.0.id is invalid."` for a nonexistent id.
**500 `{"message":"Server Error"}`** when `price` is a non-numeric string —
unhandled exception, no validation guard. `GET` → 404 (not 405).

See §5.2 for the price-trust security finding.

**Note:** this endpoint prices product 118 at **1142** while
`POST /ecommerce/cart` prices the same SKU at **899**. Two different price bases.

### 2.5 `POST /ecommerce/checkout/confirm-payment`

**Auth required.** All four fields required:

```
order_id             integer  REQUIRED
razorpay_payment_id  string   REQUIRED
razorpay_order_id    string   REQUIRED
razorpay_signature   string   REQUIRED
```

No other field produced a validation error (`charge_id`, `status`, `amount`,
`payment_method` all silently ignored).

**Hard-coded to Razorpay** — the three `razorpay_*` fields are unconditionally
required, so there is **no confirm path** for `cod`/`paypal`/`bank_transfer`/
`credit_card` even though the checkout validator accepts those `payment_method`
values.

**Response:** 422 bare `{message, errors:{field:[…]}}`.
Errors: 401 `{"error":true,"data":null,"message":"Unauthenticated."}`;
302 HTML to `/login` without `Accept` and without a bearer; `GET` → 404.

> **UNVERIFIED — success shape, and whether `order_id` carries an `exists:` rule
> or an OWNERSHIP check.** Reaching that layer requires a well-formed body, which
> the probe rules put off-limits. **This is worth attention: if there is no
> ownership check, `order_id` is an IDOR candidate.**
> **To verify:** read the controller, or place + confirm one real payment on a
> disposable account and then attempt confirm with another customer's `order_id`.

### 2.6 `POST /ecommerce/checkout/place-order` — **DOES NOT EXIST**

404 when authenticated:
`{"message":"The route api/v1/ecommerce/checkout/place-order could not be found."}`

An earlier probe recorded 401 for this path only because auth middleware fires
before route resolution. **A 401 is not evidence a route exists** — always
re-probe with a valid bearer.

Order placement happens through `POST /ecommerce/checkout/cart/{cartId}`.

---

## 3. Family: Wishlist & Compare — `/ecommerce/wishlist/*`, `/ecommerce/compare/*`

### 3.0 What these actually are

Not an account feature. These are anonymous, **identifier-keyed session bags**.

- **No bearer needed — and the bearer is IGNORED.** Verified three ways:
  the flow works with only `X-API-KEY`; `Authorization: Bearer garbage` returns
  200 with correct data (a `auth:sanctum` route would 401); and two consecutive
  POSTs with a **valid** bearer for customer 16 returned two **different** UUIDs.
- **There is no account-scoped wishlist route.** `GET /me/wishlist`,
  `/customers/wishlist`, `/ecommerce/wishlists`, `/wishlist`,
  `/ecommerce/customers/wishlist` all 404.
- **Consequence:** the wishlist will **not** sync with the website and logging
  out/in changes nothing. The heart icon is anonymous device state.
- **Zero access control.** Anyone with the API key who guesses an identifier can
  read *and* mutate that list. `GET /ecommerce/wishlist/00000000-0000-0000-0000-000000000000`
  returns 200, not 403. The UUID is the only secret — do **not** derive it from
  the customer id or email.

> ### ⚠ SHARED KEYSPACE — wishlist, compare and cart destroy each other
> Verified in both directions and against a real server cart:
> compare list `[118,119]` under identifier `X` → `GET /ecommerce/wishlist/X` →
> compare list is now `count 0`. In one case a compare POST on a wishlist
> identifier left **both** lists at 0. A real cart holding product 118 was
> emptied by `POST /ecommerce/wishlist/{that cart id}`.
>
> **MANDATORY:** store three distinct identifiers — `cart_identifier`,
> `wishlist_identifier`, `compare_identifier` — and never cross them.

**Route surface, authoritative** (leaked by Laravel's method-not-allowed text):

| Path | Methods |
|---|---|
| `/ecommerce/wishlist` | **POST only** |
| `/ecommerce/wishlist/{identifier}` | GET, HEAD, POST, DELETE |
| `/ecommerce/compare` | **POST only** |
| `/ecommerce/compare/{identifier}` | GET, HEAD, POST, DELETE |
| `/ecommerce/cart/{identifier}` | GET, HEAD, POST, PUT, DELETE |

There is **no third path segment** for any of them —
`/ecommerce/wishlist/{id}/{productId}` 404s.

### 3.1 `POST /ecommerce/wishlist` — mints a NEW identifier

**Request**

```
POST /ecommerce/wishlist
X-API-KEY: <API_KEY>                (REQUIRED)
Content-Type: application/json      (REQUIRED when sending a JSON body)
Accept: application/json            (OPTIONAL on this route — 200 verified without it)

{"product_id": 118}
```

`product_id` also accepts the numeric string `"118"`.
`application/x-www-form-urlencoded` and query-string `?product_id=118` both work.

**Response**

```jsonc
{ "id": "uuid",          // NEWLY MINTED every call — never reused, never tied to the customer
  "message": "Added product <name> successfully!",
  "data": { "count": 0, "added": true, "items": {} } }
```

> **IDENTITY TRAP:** this route **always** mints a fresh UUID. Sending
> `{"id":"<existing-uuid>","product_id":119}` in the body is silently ignored —
> it returns a brand-new UUID with `count 1`, orphaning the original list. The
> identifier is only honoured in the **URL path**.
>
> Call this **once ever**, persist the returned `id` — or skip it entirely and
> generate your own identifier client-side (verified working with the literal
> string `not-a-uuid-12345`).

**`data.items` — the type flips with emptiness:** a JSON **object** keyed by a
32-char md5 `rowId` when `count > 0`, an empty **array** `[]` when `count == 0`.
Parse as `dynamic` and branch: `items is Map ? items.values.toList() : <dynamic>[]`.

**Item fields:** `id:int`, `rowId:string`, `name:string`, `sku:string`,
`description:string` (raw HTML, several KB), `slug:string`,
`with_storehouse_management:bool`, `quantity:int`, `is_out_of_stock:bool`,
`stock_status_label:string`, `stock_status_html:string`, `price:float`,
`price_formatted:string`, `original_price:float`,
`original_price_formatted:string`, `total_taxes_percentage:int`,
`reviews_avg:number`, `reviews_count:int`, `image_with_sizes:null`,
`weight:int`, `height:int`, `wide:int`, `length:int`, `image_url:string`
(150×150 thumb), `is_variation:int` (**0/1, not bool**), `original_product_id:int`,
`product_options:array`, `store_id:int`,
`store:{id:int, name:string, slug:string, logo:string}`.

**UI quirks:** `name` has the store name appended —
`"…(khandsari) (Trueway Farms)"`. `image_url` is the 150×150 thumbnail only and
falls back to `/vendor/core/core/base/images/placeholder.png`.
`price`/`original_price` are floats with artefacts (`921.501`).

**Errors**

| Status | Body | Safe? |
|---|---|---|
| 422 | `{"message":"The product id field is required.","errors":{"product_id":[…]}}` | **SAFE** |
| 422 | `{"message":"The selected product id is invalid.","errors":{…}}` (999999, 0, −1, `"abc"`) | **SAFE** |
| 500 | `{"message":"Server Error"}` — `product_id` sent as an array | **DESTRUCTIVE** — wipes the list |
| 401 | `{"message":"Invalid or missing API key…","error":"Unauthorized"}` | |
| 404 | `"The GET method is not supported for route api/v1/ecommerce/wishlist. Supported methods: POST."` | |

**Rule of thumb: 422 = safe · 404-not-found = destructive · 500 = destructive.**

### 3.2 `POST /ecommerce/wishlist/{identifier}` — **TOGGLE** (use this)

`{identifier}` is an arbitrary opaque string — **not validated, not required to
exist, not required to be a UUID**. Verified with `probe-del-test-001` and
`AbC_123-XYZ.%20test`.

Body `{"product_id": int}`. Unknown extra body fields are accepted and ignored.

**Response is identical to §3.1 except `id` ECHOES your identifier.**

> **This is a TOGGLE, not an add** — exactly what a heart icon wants.
> POST product 119 when absent → `data.added = true`,
> *"Added product X successfully!"*.
> POST 119 again → `data.added = **false**`,
> *"Removed product X from wishlist successfully!"*, and the item is gone.
>
> Drive the heart purely off `data.added` and re-render from `data.items`; never
> optimistically assume "added". **A double-tap or a retry after a network
> timeout will un-favourite the product** — debounce, and treat a retried POST as
> potentially undoing the first.

**`product_id` accepts a VARIATION id, not just a parent id.** Posting 116 (a
variation of parent 111) succeeded and stored it as a separate row — producing a
duplicate-looking entry alongside the parent. **Always send the parent product id.**

### 3.3 `GET /ecommerce/wishlist/{identifier}`

`X-API-KEY` required; `Accept` optional; no bearer; no body.

**No pagination** — `per_page`/`page` are accepted and silently ignored; the full
list always comes back, each item carrying a multi-KB raw HTML `description`. A
20-item wishlist is a heavy mobile payload and there is no field-selection param.

```jsonc
{ "id": "string",                    // echoes the identifier
  "data": { "count": 0, "items": {} } }
```

**No `message` key and no `data.added` on GET** — those exist only on POST/DELETE.

**No 404 for unknown identifiers** — a never-used identifier returns 200 with
`{"id":"<what you passed>","data":{"count":0,"items":[]}}`.
An empty identifier (trailing slash) → 301 redirect to HTML.

**This GET is destructive across list types** — see §3.0.

### 3.4 `DELETE /ecommerce/wishlist/{identifier}` — **DO NOT SHIP**

Body `{"product_id": int}` required; `?product_id=118` works identically (use the
query form if your HTTP client strips DELETE bodies — Dart's `http` package and
some Dio configs do).

Success response: `{id, message, data:{count, items}}` — **no `data.added`**
(asymmetric with the POST toggle).

> ### ⚠ SERVER BUG, REPRODUCED THREE TIMES
> `DELETE` with a `product_id` **not** in the list returns
> `404 {"error":"Product not found in wishlist"}` **and wipes the entire list.**
> - 3 items → 0
> - 1 item → 0
> - compare 1 item → 0
>
> A stale client list is precisely when you would fire a redundant delete.
>
> **MITIGATION: do not use DELETE at all.** `POST /{identifier}` is a toggle that
> removes a present item in the same call, and its failure mode (422) is
> non-destructive.

Note the 404 body is a **third envelope shape**: bare `{"error": "<string>"}` —
`error` is a **STRING** here where it is a **boolean** elsewhere. Any shared
parser doing `if (json['error'] == true)` or `json['error'] as bool`
mis-handles or crashes.

### 3.5 Compare — `/ecommerce/compare`, `/ecommerce/compare/{identifier}`

**Byte-for-byte the same contract as wishlist**, with three differences:

1. Message wording includes *"to compare list"* / *"from compare list"*.
2. The 404 body reads `{"error":"Product not found in compare list"}`.
3. Items are a **superset** of wishlist items, adding:
   - `brand: string`
   - `categories: **string**` — comma-joined names, and an **empty string `""`**
     when the product has none. **Not an array** — a real parsing trap.
   - `attributes: array` — empty in every sample
   - `product_conditions: array` — empty in every sample
   - `variations: array` of full variation objects:
     `{id:int, slug, name, sku, description, content:null, quantity:int,
     is_out_of_stock:bool, stock_status_label, stock_status_html, price:float,
     price_formatted, original_price:float, original_price_formatted,
     reviews_avg:null, reviews_count:null, images:array, images_thumb:array,
     image_with_sizes:null, weight, height, wide, length, image_url, videos:array,
     product_conditions:array, variation_attributes:string
     (e.g. "(Pack Size: 5 KG (Pack of 1))"), store:{id, slug, name, zip_code}}`

All the same bugs apply: shared keyspace, destructive DELETE-miss, destructive
500 on array `product_id`, no auth.

### 3.6 Persistence and reliability

- **No cookies** — no `Set-Cookie` in any response header. The path identifier is
  the entire key.
- An identifier created ~1 hour earlier still resolved with its item intact.
- **Transient latency observed:** one batch of four sequential compare POSTs hung
  past 120 s with no response; identical calls retried individually all returned
  200 in under a second. The app needs a real request timeout — but note that
  **a retried POST toggle will UNDO the previous one if the first request
  actually landed.**

> **UNVERIFIED — identifier TTL/expiry.** Only proven to survive ~1 hour. Botble
> typically stores this in the session/cache driver, so it can expire. Treat a
> suddenly-empty list as possible expiry, not user intent.
> **To verify:** ask the backend owner which cache/session driver and TTL backs
> `Cart::instance('wishlist')`, or seed an identifier and re-read it after 24 h
> and 7 days.

> **UNVERIFIED — maximum compare-list size.** The store has only 4 published
> products so no cap could be exercised. Botble normally enforces a comparison
> limit; the error shape when it is hit is unknown. Handle defensively.
> **To verify:** seed 5+ products in the catalogue and add them one at a time.

> **UNVERIFIED — element shapes** for compare `attributes` and
> `product_conditions` (empty for all four products), non-null
> `image_with_sizes`, and non-empty `product_options`.

**Recommendation:** the app's cart is already 100% local
(`lib/presentation/providers/cart_provider.dart`, key `cart_items_v1`, never
calls `/ecommerce/cart`). A **local-first wishlist mirroring that pattern**
avoids all three destructive server bugs and loses nothing — the server offers no
account binding either.

---

## 4. Family: Profile, Notifications, Device Tokens

### 4.1 `GET /me`

**Request:** `X-API-KEY` (mandatory), `Accept: application/json` (mandatory),
`Authorization: Bearer <BEARER_TOKEN>`. No params have any effect. No body.

**Envelope — `error-data-message`:**

```jsonc
{ "error": false,
  "data": {
    "id": 0,
    "email": "string",
    "name": "string",          // SINGLE field — no first_name/last_name on read
    "phone": "string",         // bare 10 digits, no country code
    "avatar": "string",        // data:image/jpeg;base64 URI — see below
    "dob": "string|null",      // ISO-8601 with microseconds + Z
    "gender": "string|null",
    "description": "string|null",
    "settings": { "biometric_enabled": false, "notification_enabled": false,
                  "language": "string", "currency": "string",
                  "theme": "string", "timezone": "string" } },
  "message": null }
```

Live values worth knowing: `settings.currency = "USD"` (**not INR**),
`theme = "light"`, `language = "en"`, `timezone = "UTC"`, `gender = null`.

**Fields that do NOT exist:** `created_at`, `updated_at`, `first_name`,
`last_name`, `avatar_url`, `is_verified`, `confirmed_at`, `addresses`,
`orders_count`.

> ### ⚠ THE AVATAR PROBLEM
> `avatar` is a `data:image/jpeg;base64` **URI, not a URL**, and it is
> **regenerated with a random background colour on every single request**.
>
> Measured over 5 calls: data-URI length 3687 / 3891 / 3939 / 4003 / 3959 chars;
> decoded 2746 / 2899 / 2935 / 2985 / 2950 bytes; JPEG 250×250. The SHA-1 of the
> decoded bytes **differs every time**. Decoding two of them shows a generated
> initials placeholder — the letter "S" on solid orange, then on solid purple.
> The customer has no uploaded avatar; the server renders a fresh laravolt-style
> avatar per request.
>
> **Consequences:** 85–95% of the 4.1–4.4 KB `/me` response is a throwaway image;
> it can never be cached or diffed; if rendered, the colour flickers on every
> refresh; and `auth_provider.dart:300` `jsonEncode`s it into `SharedPreferences`
> on every profile refresh — a genuinely different 4 KB write each time — while
> `account_screen.dart:63` draws `customer.initials` instead.
>
> **Fix:** drop `avatar` from the persisted `Customer`, or ignore the field
> entirely and keep the local initials.

**Errors**

| Status | Body |
|---|---|
| 401 | `{"error":true,"data":null,"message":"Unauthenticated."}` — no/bogus/revoked bearer |
| 401 | `{"message":"Invalid or missing API key…","error":"Unauthorized"}` — `error` is a **STRING** |
| 302 | `text/html` → `/login` — only when `Accept` omitted **and** auth fails. With a valid bearer the response is JSON even without `Accept`. |
| 404 | `"The POST method is not supported for route api/v1/me. Supported methods: GET, HEAD, PUT."` |

### 4.2 `PUT /me` — the profile-update endpoint

Discovered via `OPTIONS /me` → `Allow: GET,HEAD,PUT`. **There is no `POST /me`,
no `/profile`, no `/update-profile`, no `/me/avatar`** — all 404.

**Rules** (all verified by forcing 422s; validation runs before any write, so
nothing was mutated):

| Field | Rules |
|---|---|
| name | Send **either** `name` (max:120) **or both** `first_name` + `last_name` (each min:2). Exact message: *"The first name field is required when name is not present. The last name field is required when name is not present. The name field is required when first name is not present."* |
| `phone` | numeric + `digits:10` + regex — accepts a leading 6/7/8/9, rejects 0–5, i.e. `^[6-9][0-9]{9}$` |
| `dob` | `date_format:d-m-Y` **and** `max:20`. `"27-04-2000"` passes; `"2000-04-27"` and the ISO string `GET /me` returns both **FAIL** |
| `gender` | `in:male,female,other` — **lowercase only** (`"Male"`, `"M"` rejected) |
| `description` | string |
| `email` | email + max:60 (the account's own current email produced no error, so any unique rule ignores self) |
| `avatar` | **no validation error for any value** (int, array, data-URI all pass) — unvalidated or silently dropped |

**Ignored keys (no rules at all):** `password`, `settings`, `language`, `theme`,
`currency`, `timezone`, `biometric_enabled`, `notification_enabled`.

> **NOT PATCH-ABLE.** To change only the phone you must resend the name. And
> `GET /me` returns a single `name` with no first/last, so a first/last form must
> split it client-side.

**422 response — CRITICAL TRAP, there is NO `errors` map:**

```jsonc
{ "error": true, "data": null,
  "message": "Data invalid! <msg> <msg> <msg>.." }
```

Note the literal `"Data invalid! "` prefix and the doubled full stop. Every field
message is flattened into one string — **per-field error attribution on an
edit-profile form is impossible without string matching.**

> **UNVERIFIED — the 200 shape, whether the update persists, and whether `avatar`
> is writable.** Never called with a valid body; that would have modified the
> live account. There is no separate avatar-upload endpoint (all candidates
> 404), so an edit-profile screen may not be able to set a picture at all.
> **To verify:** one real `PUT /me` on a disposable account with a valid body,
> then `GET /me` to confirm persistence; and a `PUT` with `avatar` set to a
> data-URI followed by `GET /me` to see whether the returned avatar changed.

### 4.3 `GET /logout`

**Verified:** the route exists, is `auth:sanctum`-guarded, and `OPTIONS /logout`
returns `Allow: GET,HEAD`. It is a **GET** — unusual for a state-changing call,
which means any prefetch or link-preview that hits it signs the user out.

- 401 with a bogus bearer: `{"error":true,"data":null,"message":"Unauthenticated."}`
- 404 for POST: `"…Supported methods: GET, HEAD."`

> **UNVERIFIED — the success response shape, and MOST IMPORTANTLY whether it
> revokes ALL of the customer's tokens or only the current one.**
> `docs/MOBILE_API_INTEGRATION_PLAN.md:243` asserts *"Revokes **all** tokens for
> the customer"* and `lib/data/repositories/auth_repository.dart:199` repeats it
> in a doc comment as though established. **Nothing supports this claim.**
> The route was deliberately not called — it would revoke the shared probe token.
> **To verify:** mint a second token via `POST /login`, call `GET /logout` with
> the first, then check whether the **second** still authenticates against
> `GET /me`. Do this when no other work depends on the shared token.

**App bug:** `lib/presentation/providers/auth_provider.dart:287` calls
`_repo.logout()` and then `_clearPersisted()`, which calls `_repo.logout()`
**again** — `GET /logout` fires twice per sign-out. It also fires from
`onUnauthorized()`, i.e. immediately after a 401, where it can only 401 again.

### 4.4 `GET /notifications`

**Request:** headers as `GET /me`. Query: `page` (int, default 1),
`per_page` (int, default 20).

**Pagination edge cases, all verified:**

| Input | Result |
|---|---|
| `per_page=5` | 5 |
| `per_page=1000` | capped at **50** |
| `per_page=abc` | **50** (PHP loose comparison — *not* a 422) |
| `per_page=0` | **15** (Laravel's default, not 0) |
| `per_page=-1` | passed straight through as −1 |
| `page=99` past the end | `current_page: 99`, empty array, no error |
| `page=abc` | `current_page: 1` |

`unread_only` / `is_read` / `type` / `limit` are accepted without error but their
filtering effect is **UNVERIFIED** (the account has 0 notifications).

**Response — `data` is an OBJECT, not an array:**

```jsonc
{ "error": false,
  "data": {
    "notifications": [ /* … */ ],
    "pagination": { "current_page": 0, "last_page": 0, "per_page": 0,
                    "total": 0, "has_more": false },
    "unread_count": 0 },
  "message": null }
```

Pagination is a **bespoke `pagination` object nested inside `data`** — there is
no top-level `links`/`meta`, so `PaginatedResponse.fromJson` in
`lib/core/network/api_response.dart` does not fit this endpoint either.

> ### ⚠ APP BUG — SHIPS BROKEN
> `lib/data/repositories/notification_repository.dart:30` does
> `unwrapList(res.data, AppNotification.fromJson)`. `unwrapList` returns
> `const []` unless `body['data']` is a `List`. Here it is a `Map`.
> **The notification list is hard-wired empty for every customer, forever.**
> `NotificationsScreen` will always show the "Nothing new" empty state.
>
> **Fix:** read `res.data['data']['notifications']`.
>
> The same method also discards `pagination` (so it can never page — `page`/
> `per_page` are sent but `has_more` is never read) and `unread_count` (which
> comes free on the list call, yet `notificationStatsProvider` makes a second
> round-trip to `/notifications/stats` for the same number).

**Errors:** 401 (both envelopes), 302 HTML when `Accept` omitted and auth fails,
404 for POST (`Allow: GET,HEAD`).

> **UNVERIFIED — the entire notification ITEM shape.** The account has zero rows
> and none can be created (there is no `POST /notifications` — `Allow: GET,HEAD`).
> Every field `lib/data/models/app_notification.dart:8-13` assumes — `id`,
> `notification_id`, `title`, `message`, `is_read`, `is_clicked`, `type`,
> `action_url`, `image_url`, `sent_at`, `read_at`, `created_at` — is documented
> there as fact but is **unconfirmed**. The only indirect support is
> `/notifications/stats` exposing `read` and `clicked` counters, implying per-row
> `is_read`/`is_clicked` exist. Every `_iconFor()` type string (`'order'`,
> `'promotion'`, `'offer'`, `'delivery'`) is a guess.
> **To verify:** someone with admin/DB access sends this customer one test
> notification, then re-run `GET /notifications`.

### 4.5 `GET /notifications/stats`

No params, no body. `Allow: GET,HEAD`.

```jsonc
{ "error": false,
  "data": { "total": 0, "unread": 0, "read": 0, "clicked": 0 },
  "message": null }
```

**Four** counters, not two. The app's `NotificationStats.fromJson` reads only
`total` and `unread` — those two are correct and the `unwrapObject` path works
here. Path in `notification_repository.dart:34` is **CORRECT**.

Note the same `unread` number is available as `data.unread_count` on
`GET /notifications`, so the badge needs no second round-trip.

### 4.6 `POST /notifications/{id}/read`

Headers as `GET /me`; no body required. `{id}` **must be numeric** —
`/notifications/abc/read` → `{"message":"The route … could not be found."}`.
`OPTIONS` → `Allow: POST` only.

- 404 (verified, ids 0/1/999999): `{"error":true,"data":null,"message":"Notification not found"}`
- An id belonging to another customer is **indistinguishable** from an unknown id
- 401 (route is auth-guarded); 404 for GET

Path in `api_endpoints.dart:60` is **CORRECT**. The app treating a failure here
as non-fatal (`notifications_screen.dart:104`) is the right call.

> **UNVERIFIED — the 200 shape** (does it return the updated notification or just
> a message?). **To verify:** needs one real notification on the account.

### 4.7 `POST /notifications/mark-all-read`

Empty JSON body `{}` accepted; no fields required. `Allow: POST` only.

```jsonc
{ "error": false,
  "data": { "marked_count": 0 },
  "message": "Marked 0 notifications as read" }
```

Called live — a guaranteed no-op (`total=0`/`unread=0` before and after,
`marked_count: 0`). Nothing was mutated.

Path in `api_endpoints.dart:57` is **CORRECT**. The app ignores the response
entirely (`notification_repository.dart:44` returns `Future<void>`), throwing
away `marked_count` — the natural thing to show in a snackbar.

### 4.8 `DELETE /notifications/{id}`

No body. `{id}` numeric. `OPTIONS /notifications/1` → `Allow: DELETE` only —
**there is no `GET /notifications/{id}` detail endpoint.**

404 (verified, id 999999): `{"error":true,"data":null,"message":"Notification not found"}`.
401 without a bearer. 404 for GET.

Path in `api_endpoints.dart:61` is **CORRECT**. `NotificationRepository.delete()`
exists but nothing in the UI calls it — `notifications_screen.dart` has no
swipe-to-dismiss.

> **UNVERIFIED — the 200 shape.** No rows exist; existing rows must not be
> deleted. **To verify:** needs a disposable notification row.

### 4.9 `GET /device-tokens`

Headers as `GET /me`. No params have any observable effect (`platform`,
`is_active`, `per_page` all ignored). `OPTIONS` → `Allow: GET,HEAD,POST`.

```jsonc
{ "error": false, "data": [], "message": null }
```

`data` is a **bare array** here (unlike `/notifications`).

> ### ⚠ SERVER BUG — BLOCKS PUSH ENTIRELY
> This list is **permanently empty**. It returned `[]` on every call, **including
> one second after a `POST /device-tokens` that returned 200 with a persisted row
> (id 2, `is_active: true`) using the identical bearer.** `PUT` and `DELETE` on
> that same id both return 404 *"Device token not found"*.
>
> The read/update/delete side is scoped to a customer association that the POST
> path never writes. Registered tokens are orphaned and the backend can never
> target a customer with a push.

401 with no bearer (this route **is** guarded, unlike POST). 302 HTML when
`Accept` omitted and auth fails.

> **UNVERIFIED — the populated item shape from this endpoint.** The POST response
> suggests `{id, token, platform, is_active, created_at, updated_at}`.

### 4.10 `POST /device-tokens` — push registration

**Request**

```
POST /device-tokens
X-API-KEY: <API_KEY>
Accept: application/json
Content-Type: application/json

{"token": "<FCM or APNs token>", "platform": "android"}
```

| Field | Rules |
|---|---|
| `token` | **REQUIRED**, must be a string; empty string and `null` rejected |
| `platform` | OPTIONAL/nullable, `"android"` or `"ios"` only. Omitting stores `null`. `"web"` and anything else rejected. `platform:""` is treated as absent and passes. |
| `is_active` | **IGNORED** in the body — always comes back `true` |

Unknown extra keys (`device_id`, `device_name`, `app_version`, `os_version`) are
accepted and **silently discarded** — not stored, not returned. A push
registration needs exactly two things: the token string and `"android"`/`"ios"`.

**Response**

```jsonc
{ "error": false,
  "data": { "id": 0, "token": "string",
            "platform": "android|ios|null",
            "is_active": true,
            "created_at": "2026-08-01T07:39:55.000000Z",
            "updated_at": "…" },
  "message": "Device token registered successfully" }
```

It is an **upsert keyed on `token`** — posting the same token repeatedly returns
the same `id` with `created_at` unchanged, `updated_at` bumped, and `platform`
overwritten. **No `customer_id`/`user_id` is present in the response.**

**422 uses a DIFFERENT envelope** — no `error` key, Laravel-standard `errors` map
(unlike `PUT /me`, which flattens into `message`):

```jsonc
{ "message": "Device token is required",
  "errors": { "token": ["Device token is required"] } }
```

Also: *"Device token must be a string"* (token as int/array),
*"Platform must be either android or ios"*.

> ### ⚠ SECURITY — `POST /device-tokens` IS NOT BEHIND `auth:sanctum`
> With **no `Authorization` header at all**, and with a deliberately bogus
> bearer, it still returns the 422 validation error rather than 401 — proof the
> request reaches the FormRequest, i.e. no auth middleware runs. `GET`/`PUT`/
> `DELETE` on the same resource correctly 401.
>
> Anyone holding the client-shipped `X-API-KEY` can insert `device_tokens` rows.
> This is also almost certainly the **root cause of the orphaning** in §4.9: the
> controller cannot resolve a customer, so it stores none, and the
> customer-scoped read/update/delete never match.

> **UNVERIFIED — max `token` length.** Testing it would create another
> undeletable orphan row. Standard FCM (~152–163 chars) and APNs (64 hex) tokens
> are almost certainly fine, but that is an assumption.
> **To verify:** after the orphaning bug is fixed (so rows can be cleaned up),
> POST tokens of 256 / 512 / 1024 chars.

### 4.11 `PUT /device-tokens/{id}` and `DELETE /device-tokens/{id}` — effectively dead

`{id}` must be **numeric** — the path takes the row id, not the token string
(`/device-tokens/abc` → route-not-found).
`OPTIONS /device-tokens/1` → `Allow: PUT,DELETE`.

**404 for EVERY id tried, including the id the same session's POST had just
returned:** `{"error":true,"data":null,"message":"Device token not found"}`.
Bodies `{}`, `{"is_active":false}`, `{"is_active":"maybe"}` all 404 — validation
never even ran. 401 with no bearer (these routes **are** guarded).

You cannot learn a valid id (`GET` returns `[]`) and the id `POST` hands you does
not work.

**There is no unregister-by-token-string variant** — `OPTIONS /device-tokens` is
`GET,HEAD,POST` only, so `DELETE /device-tokens` with a body is not routable.
**On sign-out the app has no working way to unregister the device**, so push
would keep firing to a signed-out handset once the orphaning bug is fixed.

> **UNVERIFIED — request contract and 200 shape for both.** Unreachable.
> Presumed intent is toggling `is_active`.
> **To verify:** the backend must first fix the customer association so
> `GET /device-tokens` returns rows.

### 4.12 `GET /settings` and `PUT /settings` — undocumented, work fine

Neither appears in `api_endpoints.dart` or any doc; found by probing.
`OPTIONS /settings` → `Allow: GET,HEAD,PUT`.

**`GET /settings`**

```jsonc
{ "error": false,
  "data": { "biometric_enabled": false, "notification_enabled": false,
            "language": "string", "currency": "string",
            "theme": "string", "timezone": "string" },
  "message": null }
```

Byte-identical to the `settings` sub-object already embedded in `GET /me` —
redundant for a client that already calls `/me`.

`notification_enabled` is the natural **server-side push opt-out** for the
account screen.

**`PUT /settings`** — all fields optional; a **true partial update** (a body with
only an unknown key returned 200 with `"settings":[]` and both `GET /settings`
and `GET /me` confirmed nothing changed).

| Field | Rules |
|---|---|
| `biometric_enabled` | boolean — *"Biometric enabled must be true or false."* |
| `notification_enabled` | boolean |
| `language` | string |
| `currency` | string |
| `timezone` | string |
| `theme` | `in:light,dark,auto` — *"Theme must be one of: light, dark, auto."* (the app's `theme_provider` has a matching light/dark/system triple) |

**200:**

```jsonc
{ "error": false,
  "data": { "message": "Settings updated successfully!",
            "settings": [] },   // the applied subset; [] when empty
  "message": "Settings updated successfully!" }   // message DUPLICATED inside data
```

**422 — a FOURTH distinct error shape: `data` is an ARRAY of single-key objects:**

```jsonc
{ "error": true,
  "data": [ { "biometric_enabled": "Biometric enabled must be true or false." },
            { "notification_enabled": "…" },
            { "language": "…" } ],
  "message": "The given data is invalid" }
```

> **UNVERIFIED — persisted-value behaviour.** Only a no-op body and an
> all-invalid body were sent; no setting was changed. The 200 envelope is
> confirmed, but that a real value round-trips is not.
> **To verify:** `PUT /settings {"theme":"dark"}` on a disposable account, then
> `GET /settings`.

### 4.13 Routes confirmed ABSENT

404 on both `OPTIONS` and `GET`:

`/profile` · `/update-profile` · `/update_profile` · `/customer/profile` ·
`/me/profile` · `/me/update` · `/profile/update` · `/change-password` ·
`/password/change` · `/me/password` · `/me/avatar` · `/avatar` ·
`/me/upload-avatar` · `/upload` · `/media/upload` · `/customers/me` · `/account` ·
`/delete-account` · `/account/delete` · `/me/delete` · `/notification-settings` ·
`/push` · `/push-tokens` · `/fcm-token` · `/notifications/unread-count` ·
`/notifications/count` · `/notifications/{id}/click`

**There is no avatar upload, no password change, and no account deletion
endpoint.**

---

## 5. Security findings

### 5.1 `shipping_amount` is an accepted client override — but the app does not use it, and the server prices by default

**Corrected 2026-08-04 by a source read of
`platform/plugins/ecommerce/src/Http/Controllers/API/CheckoutController.php`.**
An earlier revision of this section concluded *"the app sends it"* and answered
plan-doc open question 5 that way. That was an inference from probe data, and it
was **wrong**. The correct answer is below; the security half of the finding
survives intact.

**What the controller actually does — read, not inferred:**

```php
// :425  the switch
$useClientShippingAmount = $request->has('shipping_amount');
// :445-451  server pricing, skipped entirely when the client supplied a number
if (! $useClientShippingAmount && $shippingMethod) {
    $shippingAmount = Arr::get($shippingMethod, 'price', 0);      // :446
    if (get_shipping_setting('free_ship', $shippingMethodInput)) { // :448
        $shippingAmount = 0;
    }
}
// :454-456  the client's number wins when it was sent
if ($useClientShippingAmount) {
    $shippingAmount = max(0, (float) $request->input('shipping_amount'));
}
// :462
$orderAmount += (float) $shippingAmount;
```

So **omitting `shipping_amount` is what activates server pricing**, and sending it
— *even as `null`*, because the switch is `has()`, not a truthiness test —
switches the order onto the client-trusted branch. `$shippingMethod` is resolved
from `shipping_method` + `shipping_option` by
`HandleShippingFeeService::execute()` (`:58` group lookup, `:68` member lookup),
and its `price` is the Shiprocket entry's `$totalCost`
(`ShipRocketService.php:1894`).

**This app omits the field.** It sends `shipping_method: "shiprocket"` +
`shipping_option: "shiprocket_<rateId>"` only. That is the same pair the web
checkout POSTs. Full contract: `VERIFIED_API_CONTRACT.md` §4.5.

**Corrections to the old evidence chain:**

- Point 5 stands, and now has an explanation: real order 277's `shipping_amount
  "330.20"` with `shipping_method {value:"shiprocket"}` came from the **server's
  own** `handle_shipping_fee` pricing, not from a request body.
- Point 6 was wrong. A shipping-quote endpoint **does** exist — it is just in a
  different plugin under a different prefix, which is why the `/ecommerce/*`
  candidates all 404: **`POST /logistics/check-serviceability`**, plus
  `POST /logistics/check-pincode`. See `VERIFIED_API_CONTRACT.md` §4.
- Points 1–4 are unchanged and still directly observed.

**The security finding survives, and is unchanged in severity.** `shipping_amount`
is still `nullable|numeric|min:0` with **no max** and no cross-check against
anything server-computed, and `shipping_method` is still free-text with no enum
(`"__BAD__"` and 300 chars both accepted). Any client that *does* send
`shipping_amount: 0` gets a ₹0 shipping line on an order that should carry ~₹330,
and `:455`'s `max(0, …)` only floors it. This app not exercising the hole does not
close it — see `BACKEND_BUGS.md` finding 6.

> **UNVERIFIED — the persisted value on the client branch.** The `:454-456` branch
> is read from source but has never been exercised, because doing so means placing
> a real order with a tampered amount. Nothing in this app reaches it.

### 5.2 `taxes/calculate` trusts a client-supplied price — CONFIRMED

Not inferred. `POST /ecommerce/checkout/taxes/calculate` takes a client-supplied
per-item `price` and echoes it straight into subtotal/tax/total with no
validation and no comparison to the catalogue price:

| Request | Result |
|---|---|
| `{"id":118,"quantity":1}` | price 1142, total 1199.10 |
| `{"id":118,"quantity":1,"price":1}` | subtotal 1, tax 0.05, **total 1.05** |
| `{"id":118,"quantity":1,"price":0}` | all zeros |
| `{"id":118,"quantity":1,"price":-500}` | subtotal −500, tax −25, **total −525** — and `price_formatted` renders **`"Rs500.00"` WITHOUT the minus sign**, so a negative total displays as positive in any UI that trusts `*_formatted` |

`tax_rate` is **not** overridable (sent `tax_rate:0`, server kept 5).
`price` is not even type-checked — `price:"abc"` → HTTP **500**.
**The endpoint is fully public — no bearer required.**

> **UNVERIFIED — blast radius.** Whether the mobile app or the order pipeline
> consumes these numbers is unknown. The price-trust is proven; what depends on
> it is not. **To verify:** read the checkout controller and grep the app for
> consumers of this endpoint.

### 5.3 Other security notes

- **`POST /device-tokens` has no auth** (§4.10) — anyone with the shipped API key
  can write rows.
- **Wishlist/compare have zero access control** (§3.0) — the identifier is the
  only secret, and it is guessable.
- **`GET /ecommerce/checkout/cart/{cartId}` needs no auth and is destructive**
  (§2.3) — anyone holding a `cartId` can empty that cart.
- **Address 404-vs-403 enumeration oracle** (§1.3) — any authenticated customer
  can map which address ids exist globally; the 404 body also leaks the ORM class
  path `Botble\Ecommerce\Models\Address`.
- **`confirm-payment` ownership check on `order_id` is UNVERIFIED** (§2.5) — an
  IDOR candidate.
- The `X-API-KEY` is shipped in the client and is a live credential (plan doc
  §K3 already flags rotating it).

---

## 6. Cross-cutting: response envelopes

**Six mutually incompatible envelopes exist.** A single typed interceptor cannot
handle them all.

| # | Shape | Where |
|---|---|---|
| 1 | `{error: false, data: …, message: null}` | `/me`, `/settings`, `/notifications*`, `/device-tokens`, `/ecommerce/countries` |
| 2 | **Hybrid** `{data, links, meta, error: false, message: null}` | `GET /ecommerce/addresses` **only** |
| 3 | `{message, errors: {field: [msg]}}` — **no `error` key** | most 422s: addresses, checkout, taxes, confirm-payment, device-tokens, wishlist |
| 4 | `{message}` bare | 404 route-not-found, 403, method-not-allowed |
| 5 | `{error: true, data: null, message: "Unauthenticated."}` — `error` is a **BOOL** | bearer 401 |
| 6 | `{message: "Invalid or missing API key…", error: "Unauthorized"}` — `error` is a **STRING** | API-key 401 |

Plus three more one-offs:

- `{"error": "Product not found in wishlist"}` — `error` is a **string**, no
  `message` key (wishlist/compare DELETE-miss)
- `{"error": true, "data": null, "message": "Data invalid! <all msgs>.."}` —
  flattened, **no `errors` map** (`PUT /me` 422)
- `{"error": true, "data": [{field: msg}, …], "message": "The given data is invalid"}` —
  `data` is an **array of single-key objects** (`PUT /settings` 422)
- `{success: bool, data: {…}}` / `{success:false, message, errors}` — checkout GET
- Bare object, no envelope at all — `POST /ecommerce/cart`
- `{data: {…}}` only — `taxes/calculate`

**Rule for the Dio interceptor:** never cast `error`; test
`json['error'] == true` only after confirming the value is a bool, and branch on
HTTP status first. Never parse `message` for field attribution — always key off
`errors{}` where it exists.

---

## 7. Cross-cutting: HTTP behaviour

| Behaviour | Detail |
|---|---|
| **Method-not-allowed = HTTP 404** | Not 405. The body carries the 405 text and the authoritative verb list. A `404` handler must not assume "not found". |
| **`Accept: application/json` is mandatory** | Without it, an auth failure returns 302 + text/html to `/login`. Dio follows redirects → your decoder gets HTML, surfacing as 200-with-HTML, not 401. `api_client.dart:24` sets it globally (correct); also disable redirect-following. |
| **`X-API-KEY` is enforced everywhere** | 401 without it, in addition to the bearer. |
| **`Content-Type: application/json` is required for JSON bodies** | Omit it and Laravel does not parse the body, producing a misleading *"The product id field is required."* `application/x-www-form-urlencoded` works as an alternative on checkout, addresses and wishlist. |
| **Route discovery** | `OPTIONS <path>` returns 200 + an `Allow:` header for every existing route and 404 for non-existent ones — **without auth and without executing anything**. `curl -X OPTIONS` is a zero-risk route/verb map. A wrong-verb GET also leaks the verb list in the 404 body. A made-up verb does **not** work — the Hostinger edge rejects it with a 400 HTML page before Laravel sees it. |
| **A 401 is not evidence a route exists** | Auth middleware fires before route resolution, so unauthenticated requests to any nonexistent path under the auth group return 401. Always re-probe with a valid bearer. |

## 8. Cross-cutting: pagination

There is **no single pagination contract**.

| Endpoint | Contract |
|---|---|
| `GET /ecommerce/addresses` | `page` only. `per_page` accepted and **silently ignored** — hard-coded to 10. Overflow page → 200 with `data: []`, `from`/`to` null. Standard Laravel `links`/`meta`. |
| `GET /notifications` | `page` + `per_page`. Caps at 50; `abc` → 50; `0` → 15; `-1` passed through. **Bespoke `pagination` object nested inside `data`** — not `links`/`meta`. |
| `GET /ecommerce/wishlist/{id}`, `/compare/{id}` | **No pagination at all.** `page`/`per_page` accepted and ignored; the full list always returns, each item carrying multi-KB raw HTML. |
| `GET /device-tokens` | No pagination; `data` is a bare array (always empty today). |
| `POST /ecommerce/checkout/taxes/calculate` | No pagination. |

`PaginatedResponse.fromJson` in `lib/core/network/api_response.dart` fits **only**
the addresses endpoint.

---

## 9. Open items for the backend team

1. **Fix the wishlist/compare `DELETE`-miss data loss** — a 404 must not empty
   the list (§3.4).
2. **Fix the `product_id`-as-array 500** — it also empties the list (§3.1).
3. **Fix `GET /ecommerce/checkout/cart/{cartId}` emptying the cart** (§2.3).
4. **Separate the wishlist / compare / cart storage keyspaces** (§3.0).
5. **Put `POST /device-tokens` behind `auth:sanctum`** and write the customer
   association so `GET`/`PUT`/`DELETE /device-tokens` work (§4.9, §4.10).
6. **Add a delete-by-token route** so sign-out can unregister a device (§4.11).
7. ~~**Confirm whether `shipping_amount` is trusted on write**~~ — **answered by a
   source read.** It is trusted: `CheckoutController.php:425` switches on
   `$request->has('shipping_amount')` and `:455` takes `max(0, (float) …)` with
   no cross-check. Remaining ask: **drop the client override entirely and always
   price from `shipping_method` + `shipping_option`** — the branch at `:445` is
   already the correct one and is what this app relies on (§5.1).
8. **Validate `price` on `taxes/calculate`** or remove the field (§5.2).
9. **Add `/ecommerce/states` and `/ecommerce/cities` lookup endpoints** — without
   them the address book cannot render legacy rows or offer pickers (§1.6).
10. **Reconcile the POST/PUT address rules** — same columns, different required
    sets and different max lengths (§1.0).
11. **Stop returning a randomly-coloured base64 avatar on `GET /me`** — return a
    URL, or `null` when there is no uploaded avatar (§4.1).
12. **Confirm `GET /logout` semantics** — all tokens or one? (§4.3)
13. **Confirm `confirm-payment` checks `order_id` ownership** (§2.5).
14. **Clean up orphan `device_tokens` row id 2** (`token:
    "probe-fake-token-do-not-use"`, created 2026-08-01T07:39:55Z). It was created
    unintentionally during probing and **cannot be removed through the API** —
    `DELETE`/`PUT` 404, and `is_active:false` is ignored. It is an inert token FCM
    will reject, but it needs a DB/admin cleanup. It is also the evidence for
    finding 5.
15. **Confirm the wishlist identifier TTL** and the compare-list size cap (§3.6).

## 10. Verification debt — everything still UNVERIFIED

All of these need a **disposable staging account** (or a controller code read);
none can be closed against the live customer-16 account.

| Item | § | What is needed |
|---|---|---|
| `POST /ecommerce/addresses` 2xx shape | 1.2 | One real create |
| `PUT /ecommerce/addresses/{id}` 2xx shape | 1.3 | One real update |
| `DELETE /ecommerce/addresses/{id}` 2xx shape + 403 gate | 1.4 | One real delete + a cross-account delete attempt |
| `is_default` promotion / delete-the-default behaviour | 1.2 | Create with `is_default:true`, re-list |
| The hidden `full_address` segment (probably `district`) | 1.1 | Read the Address model's accessor, or PUT all 11 fields and diff `full_address` |
| `email` nullability on Address | 1.1 | Create an address without an email |
| `POST /ecommerce/checkout/cart/{cartId}` 2xx shape | 2.2 | One real order |
| Checkout empty-cart / cart-not-found errors | 2.2 | A valid body against an emptied cart |
| ~~Whether `shipping_amount` persists as sent~~ | 5.1 | **CLOSED by controller code read** (`:425`, `:445`, `:455`). It is trusted when sent; the app does not send it. |
| `confirm-payment` 2xx shape + `order_id` ownership | 2.5 | One real payment + a cross-account attempt |
| `taxes/calculate` blast radius | 5.2 | Controller read + app grep |
| Wishlist identifier TTL | 3.6 | Backend owner: which cache driver + TTL |
| Compare-list max size and its error shape | 3.6 | Seed 5+ products |
| Compare `attributes` / `product_conditions` element shapes | 3.6 | A product that has them |
| `image_with_sizes` non-null / `product_options` non-empty shapes | 3.1 | A product that has them |
| `PUT /me` 2xx shape, persistence, `avatar` writability | 4.2 | One real profile update |
| `GET /logout` 2xx shape and all-vs-one token revocation | 4.3 | Mint a second token, logout with the first, test the second |
| Notification ITEM field inventory (all 12 fields) | 4.4 | Admin sends one test notification |
| `/notifications` `unread_only`/`type` filter effect | 4.4 | Same |
| `POST /notifications/{id}/read` and `DELETE /notifications/{id}` 2xx shapes | 4.6, 4.8 | Same |
| `PUT`/`DELETE /device-tokens/{id}` contracts and 2xx shapes | 4.11 | Backend must fix the customer association first |
| `device_tokens.token` max length | 4.10 | After the orphaning fix, so rows can be cleaned up |
| `PUT /settings` persisted-value behaviour | 4.12 | `PUT {"theme":"dark"}` then `GET` |

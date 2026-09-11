/// Every backend path the app calls.
///
/// Verified two ways: probed live against `dev.truewayerp.com`, and read off the
/// Laravel route files in the `trueway_ecom` backend
/// (`platform/plugins/*/routes/api.php`). Where the two disagreed, live
/// behaviour won and the reason is noted on the constant.
///
/// See `docs/BACKEND_BUGS.md` for defects the client has to work around.
class ApiEndpoints {
  ApiEndpoints._();

  // ===========================================================================
  // Catalogue — public, X-API-KEY only
  // ===========================================================================

  static const String products = '/ecommerce/products';

  static String productBySlug(String slug) => '/ecommerce/products/$slug';

  /// Related products.
  ///
  /// Returns a **reduced** product shape — 17 keys against the list's 28. It
  /// omits sku, description, content, images, videos, weight, dimensions and
  /// product_options, so every one of those must be nullable in `Product`.
  /// Takes a slug; a numeric id 404s.
  static String relatedProducts(String slug) =>
      '/ecommerce/products/$slug/related';

  static String crossSaleProducts(String slug) =>
      '/ecommerce/products/$slug/cross-sale';

  /// Public reviews for a product.
  ///
  /// Supports `page`, `per_page` and `star`, but returns **no pagination
  /// metadata** — no meta, total or last_page. The only count is embedded in an
  /// English sentence in `message` ("2 review(s) for ..."), which is not worth
  /// parsing. Page until a short page comes back instead.
  static String productReviews(String slug) =>
      '/ecommerce/products/$slug/reviews';

  /// Shop categories.
  ///
  /// NOT `/categories` — that is the **blog** plugin's list and returns rows
  /// like "Dummy" and "Yoga". Filtering products by those ids matched nothing,
  /// which is why every category once showed as empty.
  static const String productCategories = '/ecommerce/product-categories';

  static String productCategory(String slug) =>
      '/ecommerce/product-categories/$slug';

  /// Products in a category.
  ///
  /// The `categories[]` query parameter on [products] is accepted but does not
  /// filter — verified live, 0 rows for every id. This path-based route works.
  static String productsInCategory(int categoryId) =>
      '/ecommerce/product-categories/$categoryId/products';

  static const String brands = '/ecommerce/brands';

  static String brand(String slug) => '/ecommerce/brands/$slug';

  /// Unlike categories, `brands[]=` on [products] *does* filter correctly.
  /// This route exists for symmetry; either is fine.
  static String productsInBrand(int brandId) =>
      '/ecommerce/brands/$brandId/products';

  /// Available filter facets.
  ///
  /// Advertises category facets that [products] will not actually honour — see
  /// [productsInCategory]. Treat category entries here as navigation, not as
  /// query parameters.
  static const String filters = '/ecommerce/filters';

  static const String flashSales = '/ecommerce/flash-sales';

  /// Variation detail for a variable product.
  static String productVariation(int variationId) =>
      '/ecommerce/product-variation/$variationId';

  /// Four home carousels in one call: top_selling, trending, recently_added,
  /// top_rated. Served by the `uminber` plugin, so it has no `/ecommerce`
  /// prefix. Carousel items use the **full** product shape, so
  /// `Product.fromJson` is reusable here (unlike [relatedProducts]).
  static const String topProductsGroup = '/top-products-group';

  // ===========================================================================
  // CMS + geo — public
  // ===========================================================================

  static const String sliders = '/simple-sliders';
  static const String ads = '/ads';
  static const String countries = '/ecommerce/countries';
  static const String currencies = '/ecommerce/currencies';
  static const String currentCurrency = '/ecommerce/currencies/current';

  // ===========================================================================
  // Geo lookup — states and cities, for the address pickers
  // ===========================================================================
  //
  // These replace the two `/ajax/…` **web** routes on the site origin that this
  // app used to call. Those needed their own Dio (different base URL, no API
  // key, `Accept: application/json` or a 302 to the storefront, two different
  // envelopes, `country_id`/`state_id` parameter names, and placeholder rows).
  // The routes below are ordinary `/api/v1` endpoints: same base, same key,
  // same envelope, and they go through [ApiClient] like everything else.
  //
  // ⚠ The backend's own note gives these as `GET /states` and `GET /cities`.
  // Both are **404** live — the deployed paths carry the `/ecommerce` prefix,
  // verified 2026-08-12.
  //
  // Neither offers HTTP caching, so any caching is client-side.

  /// `GET /ecommerce/states` — every state, for the address form's picker.
  ///
  /// Envelope: `{"error":false,"data":[{"id":11,"name":"Gujarat"},…]}`. 36 rows
  /// for this single-country store, ~1.1 KB. Ids are `states.id` and are the
  /// value `state` must be posted as — see [addresses].
  ///
  /// [geoCountryParam] is accepted but makes no difference here (`?country=IN`
  /// and no parameter at all return the identical 36 rows), because the shop
  /// ships in one country. Sent anyway, so a second country cannot silently
  /// widen the list.
  static const String states = '/ecommerce/states';

  /// `GET /ecommerce/cities?state=11` — the cities of one state.
  ///
  /// Same envelope. 306 rows for Gujarat.
  ///
  /// ⚠ The list ends with a sentinel `{"id":"other","name":"Other"}` whose `id`
  /// is the **String** `"other"`, not an int — an unconditional int cast throws.
  /// It is a real option rather than noise: posting `city: "other"` is how a
  /// customer whose town is not listed names it, and it then **requires**
  /// `other_city`. See [GeoOption.isOther].
  ///
  /// Unlike the old web route, `state` here really does filter — omitting it or
  /// passing an unknown id does not silently return the whole national table.
  static const String cities = '/ecommerce/cities';

  /// The country filter on [states]. The ISO code, not the numeric id.
  static const String geoCountryParam = 'country';

  /// The state filter on [cities]. A bare `states.id`.
  static const String geoStateParam = 'state';

  // ===========================================================================
  // Cart — public, anonymous. See docs/BACKEND_BUGS.md finding 0.
  // ===========================================================================
  //
  // The cart is identified only by an opaque id in the path. No bearer token is
  // involved — any holder of the id can read and write it — which is what lets a
  // guest cart survive login unchanged.
  //
  // ⚠ Every mutation below can destroy the whole cart when it fails, because
  // `Cart::restore()` deletes the stored row and the controller's error paths
  // return without calling `store()`. After ANY failure the client must re-fetch
  // and assume the cart may be empty. Never optimistically update local state.

  /// Creates a NEW cart and returns its generated id.
  static const String cartCreate = '/ecommerce/cart';

  /// Add to / read / update / remove a line in an existing cart.
  ///
  /// PUT and DELETE take **`product_id`**, not the `row_id` the response is
  /// keyed by. Two traps:
  ///   * For a variable product the created line's `id` is the **variation** id
  ///     (posting 111 yields a line with id 116). DELETE must send that line id
  ///     — sending the original id hits the "not in cart" path, which 404s *and
  ///     wipes the cart*.
  ///   * PUT is an **upsert**: if the product is absent it adds it rather than
  ///     failing, and it does not resolve variations, so it can duplicate a
  ///     variable product.
  static String cart(String cartId) => '/ecommerce/cart/$cartId';

  /// Bulk sync — **unreachable, do not use**.
  ///
  /// `POST cart/refresh` is declared in the routes file but *after*
  /// `POST cart/{id}`, and Laravel matches in registration order. The request
  /// therefore binds `{id} = "refresh"` and creates a cart literally called
  /// "refresh". Kept here only so nobody re-adds it believing it works; the
  /// local-cart migration has to add items one at a time.
  static const String cartRefreshUnreachable = '/ecommerce/cart/refresh';

  static const String couponApply = '/ecommerce/coupon/apply';
  static const String couponRemove = '/ecommerce/coupon/remove';

  /// `GET coupons` — the coupons an admin marked visible at checkout, already
  /// filtered to active and not-used-up.
  ///
  /// Read-only, and **verified read-only**: every other route that takes a cart
  /// id runs `Cart::restore()`, which loads the row by deleting it, so a
  /// refusal anywhere else destroys the basket. This one does not — a fresh
  /// 2-item cart survived four consecutive calls with `count` still 2. It is
  /// therefore safe to re-fetch on every cart change, which is exactly what
  /// eligibility requires.
  ///
  /// Send `cart_id` or the rows come back with no `is_eligible` at all.
  static const String coupons = '/ecommerce/coupons';

  // ===========================================================================
  // Wishlist + compare — public, anonymous, same identifier pattern as the cart
  // ===========================================================================
  //
  // POST with no id mints an identifier; persist it like the cart id.
  // ⚠ DELETE of a valid product that is not on the list 404s *and wipes the
  // whole list* — same root cause as the cart.

  static const String wishlistCreate = '/ecommerce/wishlist';
  static String wishlist(String identifier) =>
      '/ecommerce/wishlist/$identifier';

  static const String compareCreate = '/ecommerce/compare';
  static String compare(String identifier) => '/ecommerce/compare/$identifier';

  // ===========================================================================
  // Auth
  // ===========================================================================

  // Phone + OTP, served by the `uminber` plugin (prefix `api/v1/otp`).
  static const String sendOtp = '/otp/send';
  static const String verifyOtp = '/otp/verify';
  static const String resendOtp = '/otp/resend';

  // Email + password, served by `botble/api`. The ecommerce plugin rebinds that
  // package's model to `Customer`, so these operate on shop customers — the same
  // records the OTP endpoints resolve by phone.
  static const String register = '/register';
  static const String login = '/login';

  /// Revokes **all** of the customer's tokens, not just this device's.
  static const String logout = '/logout';
  static const String profile = '/me';
  static const String checkEmail = '/email/check';
  static const String forgotPassword = '/password/forgot';

  // ===========================================================================
  // Profile — bearer required (`botble/api` ProfileController)
  // ===========================================================================

  /// `PUT /me` — same path as [profile], different verb. Named separately so a
  /// reader of the call site can tell a read from a write.
  static const String updateProfile = '/me';

  /// `POST /update/avatar` — multipart, field name `avatar`.
  static const String updateAvatar = '/update/avatar';

  /// `PUT /update/password` — `{ old_password, password }`.
  static const String updatePassword = '/update/password';

  // ===========================================================================
  // Orders — bearer required
  // ===========================================================================

  static const String orders = '/ecommerce/orders';
  static String order(int id) => '/ecommerce/orders/$id';
  static String cancelOrder(int id) => '/ecommerce/orders/$id/cancel';
  static String confirmDelivery(int id) =>
      '/ecommerce/orders/$id/confirm-delivery';
  static String orderInvoice(int id) => '/ecommerce/orders/$id/invoice';
  static String orderInvoiceDownload(int id) =>
      '/ecommerce/orders/$id/invoice/download';


  static String shiprocketTracking(String shipmentId) =>
      '/ecommerce/orders/shiprocket-tracking/$shipmentId';

  // ---- Returns ----
  static const String orderReturns = '/ecommerce/order-returns';
  static String orderReturn(int id) => '/ecommerce/order-returns/$id';
  static String returnsForOrder(int orderId) =>
      '/ecommerce/orders/$orderId/returns';
  static const String orderReturnUploadMedia =
      '/ecommerce/order-returns/upload-media';
  static String resubmitReturn(int id) =>
      '/ecommerce/order-returns/$id/resubmit';

  // ===========================================================================
  // Addresses — bearer required
  // ===========================================================================
  //
  // POST and PUT now share one rule set (re-probed live 2026-08-12; the old
  // asymmetry — POST needing only {name, phone} while PUT demanded seven
  // fields — is gone, and with it the risk of creating a row that could never
  // be edited):
  //
  //   required : name, phone, state, city, address, zip_code
  //   optional : email, landmark, district, other_city, is_default
  //   ignored  : country — the server fills it from the single-country setting
  //
  // ⚠ `state` is now validated with `exists`. It must be a bare `states.id`
  // from [states]; a NAME is rejected ("The selected state is invalid."), which
  // is why the form posts ids and never what the customer reads.
  //
  // ⚠ `city` is NOT validated. A bogus id is stored verbatim and then rendered
  // verbatim (`city_name: "999999"`), so the client is the only thing keeping
  // it to a real row of [cities]. The one special value is `"other"`, which
  // makes `other_city` required.
  //
  // Read shape (18 keys, identical on list, create and update): the write
  // fields plus `country_id`, `country_name`, `state_name`, `city_name` and
  // `full_address`.
  //
  // There is no GET-one route — read the collection and filter client-side.

  static const String addresses = '/ecommerce/addresses';
  static String address(int id) => '/ecommerce/addresses/$id';

  // ===========================================================================
  // Reviews — bearer required for writes
  // ===========================================================================

  static const String reviews = '/ecommerce/reviews';
  static String review(int id) => '/ecommerce/reviews/$id';

  /// Whether this customer may review a product, without pulling the whole
  /// review list. Public, but personalised when a bearer token is attached.
  static String reviewEligibility(String slug) =>
      '/ecommerce/products/$slug/review-eligibility';

  /// Products the customer bought on a completed order and has not reviewed.
  ///
  /// Replaces a client-side derivation that read every review, then every
  /// completed order, then a detail call per order — three round-trip classes
  /// to answer a question the server can answer in one.
  static const String productsToReview =
      '/ecommerce/reviews/products-to-review';

  // ===========================================================================
  // Notifications — bearer required
  // ===========================================================================

  static const String notifications = '/notifications';
  static const String notificationStats = '/notifications/stats';
  static const String markAllNotificationsRead = '/notifications/mark-all-read';

  /// [id] is the recipient row id, not the push-notification id.
  static String markNotificationRead(int id) => '/notifications/$id/read';

  /// What a *tap* should call, not [markNotificationRead].
  ///
  /// `markAsClicked()` stamps `clicked_at` **and cascades to `markAsRead()`**,
  /// so this records the open and the read in one round trip. Marking read
  /// alone leaves the store's click-through figures permanently at zero.
  ///
  /// ⚠ The spelling is `/clicked`, not `/click` — the latter 404s. Probed live:
  /// `OPTIONS` answers `Allow: POST`, and an unauthenticated POST answers
  /// `{"error":true,"message":"Unauthenticated."}`, so the route exists and is
  /// bearer-guarded like the rest of this block.
  static String markNotificationClicked(int id) => '/notifications/$id/clicked';

  static String notification(int id) => '/notifications/$id';

  // ===========================================================================
  // Stock notifications
  // ===========================================================================

  static String notifyMe(int productId) =>
      '/ecommerce/products/$productId/notify-me';
  static String notifyMeStatus(int productId) =>
      '/ecommerce/products/$productId/notify-me/status';

  // ===========================================================================
  // Checkout — LIVE. These two create and finalise REAL orders.
  // ===========================================================================
  //
  // Both are wired: `CheckoutRepository.placeOrder` POSTs [checkoutCart] and
  // `CheckoutRepository.confirmPayment` POSTs [confirmPayment], driven by
  // `CheckoutFlowNotifier`. Never call either against a live server to "see
  // what it returns" — the first one bills the customer.

  /// `POST /checkout/cart/{cart_id}` — creates the order. Bearer required.
  ///
  /// ⚠ **NOT idempotent, and not retryable.** The controller runs no
  /// transaction and the server does not de-duplicate: every POST with the same
  /// cart id mints another order, another Razorpay order and another coupon
  /// use. The `ec_cart` row survives checkout, so the same id will happily do
  /// this again. A transport failure must be reconciled against
  /// `GET /orders`, never repeated — that is what `CheckoutOutcomeUnknown` in
  /// `CheckoutRepository` exists to force.
  ///
  /// ⚠ `GET` on this same path (the `process` action) **EMPTIES the cart** — it
  /// restores without storing. There is deliberately no constant for the GET.
  /// Build order summaries from [cart] instead, which returns the same pricing
  /// block.
  static String checkoutCart(String cartId) =>
      '/ecommerce/checkout/cart/$cartId';

  /// `POST /checkout/confirm-payment` — hands the Razorpay triple back and
  /// finalises the order. Bearer required.
  ///
  /// ⚠ HTTP 200 does **not** mean paid: the server finalises the order either
  /// way and reports `payment_status: "pending"` when the money did not land.
  /// Gate any receipt on `GET /orders/{id}` instead. Replaying a triple that
  /// was already accepted 422s on the server's replay guard.
  static const String confirmPayment = '/ecommerce/checkout/confirm-payment';

  /// Defined for completeness — **nothing in the app calls this**.
  ///
  /// ⚠ Computes purely from client-supplied prices with no catalogue lookup.
  /// Never use its output as an order total — take totals from [cart].
  static const String calculateTaxes = '/ecommerce/checkout/taxes/calculate';

  // ===========================================================================
  // Logistics — LIVE, and the source of the shipping charge on every order
  // ===========================================================================
  //
  // All three are wired through `LogisticsRepository`. The courier the customer
  // picks out of [checkServiceability] supplies the **`shipping_option`** sent
  // to [checkoutCart] — `"shiprocket_<rateId>"`, built from that row's own `id`
  // — and the server prices the order from it. The app does **not** send
  // `shipping_amount`; omitting it is what activates server pricing
  // (`API/CheckoutController.php:425`). So a wrong answer here is still a wrong
  // bill, but by a different route: a rate id the server cannot find in the
  // table it rebuilds resolves to null and the order ships for 0.00, silently.
  // See `CheckoutRepository.placeOrder` for the full contract.
  //
  // ⚠ These proxy Shiprocket. When the upstream token is missing or expired the
  // failure arrives as "Service temporarily unavailable" — as a 422 on
  // [checkPincode] and as an HTTP **200** carrying no courier list on
  // [checkServiceability]. Both are outages to retry, not "we don't deliver
  // there"; `LogisticsRepository` separates the two.

  /// Per-product deliverability. **Its `shipping_charge` is not the checkout
  /// price — it is quoted from a different warehouse.**
  ///
  /// `PinCodeDeliveryService::getPickupPostcode()` (`:145-148`) reads
  /// `setting('logistics_pickup_postcode', '110001')`, a setting unrelated to
  /// the one checkout uses. Replaying this endpoint's exact parcel through
  /// [checkServiceability] across 8 pickup pincodes reproduced its
  /// (courier, rate, etd) triple **only at 110001** — so it really does price
  /// from Delhi, while checkout prices from 311001. Use it for the yes/no
  /// deliverability answer; take any rupee figure from [checkServiceability].
  static const String checkPincode = '/logistics/check-pincode';

  /// The rate card checkout is priced against. Nine client-computed fields; no
  /// cart id, no product id.
  ///
  /// The displayable price of a row is `freight_charge + coverage_charges +
  /// other_charges` (+ `cod_charges` on a COD order), which is how the server
  /// builds its own `price` (`ShipRocketService.php:1874-1894`) — **not** the
  /// row's `rate` field. Live 2026-08-04, 311001→382415, 15.2 kg: at
  /// `declared_value` 314 the two agree; at 3108 every row carries
  /// `coverage_charges: 49.00` that `rate` omits.
  static const String checkServiceability = '/logistics/check-serviceability';

  static const String batchCheckPincodes = '/logistics/batch-check-pincodes';
}

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/errors/api_exception.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/utils/json_utils.dart';
import '../models/coupon.dart';
import '../models/server_cart.dart';

/// Outcome of a cart mutation, carrying the server's true state either way.
///
/// A mutation that fails is not a no-op on this backend, so "it threw, keep the
/// old cart" is wrong. Every method returns one of these instead of throwing:
/// [error] says whether the operation was refused, [cart] says what the cart
/// actually contains now.
///
/// To detect a wipe, diff [cart] against the state held before the call —
/// the repository deliberately keeps no state of its own to diff against.
class CartMutationResult {
  const CartMutationResult({this.cart, this.error, this.refreshError});

  /// The cart as the server reports it *after* the attempt. Null only when the
  /// re-read also failed (see [refreshError]), or when creating a cart failed
  /// before an id existed.
  final ServerCart? cart;

  /// Why the mutation was refused. Null on success.
  ///
  /// A business refusal ("Maximum quantity is 93!") arrives as HTTP 200 with
  /// `error: true`; ApiClient already turns that into an ApiException with
  /// [ApiErrorKind.businessRule], so it lands here like any other failure.
  final ApiException? error;

  /// Set when the post-failure re-read *also* failed. [cart] is null and the
  /// cart's contents are genuinely unknown — offer a retry, do not guess.
  final ApiException? refreshError;

  /// Whether the *operation* was accepted. It does **not** promise [cart] is
  /// non-null: a successful DELETE whose follow-up read failed is a success
  /// with an unknown cart. Check [isCartKnown] (or [isResolved]) before
  /// rendering, never `isSuccess` then `cart!`.
  bool get isSuccess => error == null;

  /// False when the cart's true contents could not be established.
  bool get isCartKnown => cart != null;

  /// The only combination that lets a caller both report success and redraw
  /// from [cart] without a null check.
  bool get isResolved => isSuccess && isCartKnown;

  /// The message to show. The server's own wording is always preferred — it
  /// names the actual constraint.
  String? get message => error?.message;
}

// ===========================================================================
// The authoritative local mirror
// ===========================================================================

/// One line of the local mirror: what the app knows the customer asked for.
///
/// [productId] is the **line** id — the id `POST /ecommerce/cart/{id}` has to
/// be given to reproduce this exact line. For a variable product that is the
/// **variation** id, never the parent: the server resolves a parent to the
/// *default* variation (`CartController::store` → `$product->defaultVariation`),
/// so mirroring the parent would silently substitute a different pack size on
/// every rebuild. Reading it back off the cart line the server returned is what
/// makes that impossible — a line's `id` is always the variation.
class CartMirrorLine {
  const CartMirrorLine({
    required this.productId,
    required this.qty,
    this.options = const {},
  });

  factory CartMirrorLine.of(ServerCartItem item) => CartMirrorLine(
        productId: item.lineId.value,
        qty: item.quantity,
        options: item.optionsPayload,
      );

  factory CartMirrorLine.fromJson(Map<String, dynamic> json) => CartMirrorLine(
        productId: asInt(json['product_id']),
        qty: asInt(json['qty'], 1),
        options: asMap(json['options']),
      );

  /// The variation id for a variable product, the product id for a simple one.
  final int productId;

  /// Units. Always >= 1 — the mirror is built from lines the server returned,
  /// and a line with no units is not a line.
  final int qty;

  /// The chosen product options, in the shape the POST body accepts. Empty for
  /// every product in this catalogue; see [ServerCartItem.optionsPayload].
  final Map<String, dynamic> options;

  Map<String, dynamic> toJson() => {
        'product_id': productId,
        'qty': qty,
        if (options.isNotEmpty) 'options': options,
      };

  @override
  bool operator ==(Object other) =>
      other is CartMirrorLine &&
      other.productId == productId &&
      other.qty == qty;

  @override
  int get hashCode => Object.hash(productId, qty);

  @override
  String toString() => 'CartMirrorLine($productId x$qty)';
}

/// The app's own record of the cart, kept because the server's copy can vanish.
///
/// `Cart::restore()` deletes the stored row as it loads it and every controller
/// error path returns before `store()` writes it back, so **any** refusal can
/// leave the customer with an empty basket they did not empty. The mirror is
/// what a rebuild is driven from: it names the lines to re-POST to the same
/// cart id, and the coupon to re-apply afterwards.
///
/// It is written from a cart the server just serialized — never from local
/// arithmetic — so it can only ever describe a state the server itself
/// reported. It is deliberately *not* refreshed from a plain read: a read that
/// comes back empty is exactly what a wipe looks like, and adopting it would
/// destroy the only record of what was lost.
class CartMirror {
  const CartMirror({
    required this.cartId,
    this.lines = const [],
    this.couponCode,
  });

  /// Snapshots a cart the server just returned.
  factory CartMirror.of(ServerCart cart, {String? cartId}) {
    final code = (cart.appliedCouponCode ?? '').trim();
    return CartMirror(
      cartId: cartId ?? cart.id,
      lines: [for (final item in cart.items) CartMirrorLine.of(item)],
      couponCode: code.isEmpty ? null : code,
    );
  }

  factory CartMirror.fromJson(Map<String, dynamic> json) => CartMirror(
        cartId: asString(json['cart_id']),
        lines: [
          for (final line in asMapList(json['lines'])) CartMirrorLine.fromJson(line),
        ],
        couponCode: asStringOrNull(json['coupon_code']),
      );

  /// The cart these lines belong to. A mirror is only ever replayed into the
  /// cart id it was captured from — the coupon lives on the first line of *that*
  /// cart, and a rebuild into a different id would strand it.
  final String cartId;

  final List<CartMirrorLine> lines;

  /// The coupon the server reported as applied, or null.
  ///
  /// It survives to checkout only by being stamped on the first cart item's
  /// options (`CouponController::apply`), so a rebuild loses it and it has to be
  /// re-applied to the same cart id.
  final String? couponCode;

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;

  /// Mirrored lines [cart] does not hold in full — the lines a rebuild owes.
  List<CartMirrorLine> missingFrom(ServerCart? cart) {
    if (cart == null) return lines;
    final held = {for (final item in cart.items) item.lineId.value: item.quantity};
    return [
      for (final line in lines)
        if ((held[line.productId] ?? 0) < line.qty) line,
    ];
  }

  /// True when a coupon was applied and [cart] no longer carries it.
  bool couponMissingFrom(ServerCart? cart) =>
      couponCode != null && cart?.appliedCouponCode != couponCode;

  /// True when [cart] is short of anything this mirror recorded.
  bool describesMoreThan(ServerCart? cart) =>
      missingFrom(cart).isNotEmpty || couponMissingFrom(cart);

  /// The same mirror with [productId] and/or the coupon taken out.
  ///
  /// A refused `DELETE` is the case this exists for. "Cart item not found" 404s
  /// *and* wipes the cart, and it means the line was not there — so the mirror
  /// is the stale one, and rebuilding from it would resurrect the very line the
  /// customer asked to remove. The mirror follows the intent, not the failure.
  CartMirror without({int? productId, bool coupon = false}) => CartMirror(
        cartId: cartId,
        lines: [
          for (final line in lines)
            if (line.productId != productId) line,
        ],
        couponCode: coupon ? null : couponCode,
      );

  Map<String, dynamic> toJson() => {
        'cart_id': cartId,
        'lines': [for (final line in lines) line.toJson()],
        if (couponCode != null) 'coupon_code': couponCode,
      };

  String encode() => jsonEncode(toJson());

  /// Decodes a persisted mirror, or returns null for anything unusable.
  /// A corrupt mirror must never be fatal — it is a recovery aid, not state.
  static CartMirror? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final mirror = CartMirror.fromJson(Map<String, dynamic>.from(decoded));
      return mirror.cartId.isEmpty ? null : mirror;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'CartMirror($cartId, ${lines.length} lines, coupon: $couponCode)';
}

/// What a rebuild achieved. Never silently discarded: a customer whose basket
/// could not be put back has to be told, not shown an empty cart.
class CartRebuildOutcome {
  const CartRebuildOutcome({
    this.cart,
    this.linesRestored = 0,
    this.linesLost = 0,
    this.couponRestored = false,
    this.couponLost = false,
    this.refusal,
    this.readError,
  });

  /// The cart as it stands after the rebuild. Null when the final read failed,
  /// which is the one case where the contents are genuinely unknowable.
  final ServerCart? cart;

  /// Mirrored lines the cart holds in full afterwards, whether they survived
  /// the wipe or were re-posted.
  final int linesRestored;

  /// Mirrored lines still short afterwards — items the customer has lost.
  final int linesLost;

  /// The coupon was re-applied to the rebuilt cart.
  final bool couponRestored;

  /// A coupon was on the cart and could not be put back. The lines are still
  /// there (a refused coupon wipes the cart, so they were restored a second
  /// time); only the discount is gone.
  final bool couponLost;

  /// The first refusal met while re-posting a line — usually the real reason
  /// an item could not come back ("Product X is out of stock!").
  final ApiException? refusal;

  /// The final read failed, so [cart] is null.
  final ApiException? readError;

  bool get isComplete => linesLost == 0 && !couponLost && readError == null;

  bool get cartKnown => cart != null;

  /// A sentence for the customer, or null when nothing was lost.
  String? get lossMessage {
    if (isComplete) return null;
    if (readError != null) {
      return 'Your basket could not be checked. Pull to refresh.';
    }
    final parts = <String>[];
    if (linesLost == 1) {
      parts.add('1 item could not be restored');
    } else if (linesLost > 1) {
      parts.add('$linesLost items could not be restored');
    }
    if (couponLost) parts.add('the coupon was removed');
    if (parts.isEmpty) return null;
    final detail = refusal?.message;
    final sentence = '${parts.join(' and ')}.';
    return detail == null || detail.isEmpty
        ? 'Your basket was rebuilt, but $sentence'
        : 'Your basket was rebuilt, but $sentence $detail';
  }

  @override
  String toString() => 'CartRebuildOutcome(restored: $linesRestored, '
      'lost: $linesLost, coupon: $couponRestored/$couponLost)';
}

/// The result of one pass over the mirror's lines.
class _RestorePass {
  const _RestorePass(this.refused, this.firstRefusal);

  /// Lines the server would not take back, by product id. They are skipped on
  /// every later pass — retrying one is what would wipe the cart again.
  final Map<int, ApiException> refused;

  final ApiException? firstRefusal;
}

/// The server-side cart.
///
/// ## Read this before changing anything here
///
/// `Cart::restore()` in the backend **deletes** the stored cart row as it loads
/// it into the session; `store()` is what writes it back. Every controller
/// error path between the two returns without calling `store()`, so a failed
/// mutation destroys the entire cart — not just the line it refused. Verified
/// live: a 2-item cart plus one over-stock add leaves an empty cart. See
/// docs/BACKEND_BUGS.md finding 0 for the source and a reproduction.
///
/// Four rules follow, and they are the reason this class looks the way it does:
///
///  1. **Never** return a locally-mutated cart. The only trustworthy cart is one
///     the server just serialized.
///  2. After **any** failure, re-read `GET /ecommerce/cart/{id}` and hand the
///     caller the real state alongside the error. That read is safe — `index()`
///     is the one action that pairs `restore()` with `store()`.
///  3. Mutations return [CartMutationResult] rather than throwing, so a caller
///     cannot handle the error without also being handed the surviving cart.
///  4. Every call for one cart id is **serialised** ([_serialised]). `store()`
///     inserts a row keyed by `(identifier, instance)` and throws
///     `CartAlreadyStoredException` — a 500 — when one already exists, so two
///     requests interleaving between `restore()` and `store()` lose the cart or
///     500. `GET` is a writer here too (`index()` restores and re-stores), so it
///     queues with the rest.
///
/// What the client cannot do is stop the wipe. What it can do is put the cart
/// back: [rebuild] re-POSTs a [CartMirror] into the same cart id and re-applies
/// the coupon. The mirror itself is owned by whoever owns cart persistence —
/// this repository holds no state.
///
/// Also note `GET /ecommerce/checkout/cart/{id}` empties the cart (finding 1),
/// so order summaries are built from [fetch], which returns the same pricing
/// block. There is deliberately no method here that calls it.
///
/// ⚠ `POST /ecommerce/cart/refresh` is **never** called from anywhere in this
/// class. It is declared after `POST /cart/{id}` and Laravel matches in
/// registration order, so the request binds `{id} = "refresh"` and reads and
/// writes a cart literally named "refresh" — a bucket shared by every user of
/// the app. [_cartPath] asserts no request can be built for it.
class CartRepository {
  CartRepository(this._api);

  final ApiClient _api;

  /// One chained future per cart id — the single-flight queue. Entries are
  /// dropped as they drain, so this does not grow with cart ids seen.
  final Map<String, Future<void>> _queue = {};

  /// Key for calls that have no cart id yet, i.e. [createCart].
  static const String _mintingKey = ' new-cart';

  /// Runs [action] after every call already queued for [key], and makes the
  /// next one wait for it.
  ///
  /// A chained future is all this needs: the chain never carries an error (the
  /// `finally` completes it either way), so a failed call cannot deadlock the
  /// queue behind it.
  Future<T> _serialised<T>(String key, Future<T> Function() action) async {
    final ahead = _queue[key];
    final mine = Completer<void>();
    _queue[key] = mine.future;

    if (ahead != null) await ahead;

    try {
      return await action();
    } finally {
      if (identical(_queue[key], mine.future)) _queue.remove(key);
      mine.complete();
    }
  }

  /// The one place a cart path is built, so the dead `/cart/refresh` route
  /// cannot be reached even by accident.
  String _cartPath(String cartId) {
    assert(
      cartId.isNotEmpty && cartId != 'refresh',
      'POST /ecommerce/cart/refresh is a dead route that writes into a cart '
      'shared by every user — never address a cart called "refresh"',
    );
    return ApiEndpoints.cart(cartId);
  }

  /// Reads a cart. Safe and idempotent, unlike every other cart route.
  ///
  /// An unknown or expired id is not an error: the server mints an empty cart
  /// for it and returns 200. Callers therefore cannot distinguish "expired" from
  /// "emptied", which is another reason to persist the id and treat an empty
  /// result as authoritative.
  ///
  /// Queued with the mutations: `index()` also restores and re-stores the row,
  /// so a read racing a write is the same `CartAlreadyStoredException` 500.
  Future<ServerCart> fetch(String cartId) =>
      _serialised(cartId, () => _read(cartId));

  /// [fetch] without the queue, for use by code that already holds it.
  Future<ServerCart> _read(String cartId) async {
    final res = await _api.get(_cartPath(cartId));
    final cart = ServerCart.tryFrom(res.data, fallbackId: cartId);
    if (cart == null) {
      throw ApiException.local(
        'The cart could not be read. Please try again.',
        developerDetail: 'GET ${ApiEndpoints.cart(cartId)} '
            'returned a body with no cart_items: ${res.data}',
      );
    }
    return cart;
  }

  /// Creates a new cart around a first item and returns it, id included.
  ///
  /// Persist `result.cart!.id` immediately — it is the only handle to the cart
  /// and the server issues no other way to find it again. On failure there is no
  /// id yet, so [CartMutationResult.cart] is null and nothing was created.
  Future<CartMutationResult> createCart({
    required int productId,
    int qty = 1,
  }) async {
    _requirePositive(qty);
    return _serialised(_mintingKey, () async {
      try {
        final res = await _api.post(
          ApiEndpoints.cartCreate,
          data: {'product_id': productId, 'qty': qty},
        );
        final cart = ServerCart.tryFrom(res.data);
        if (cart == null || cart.id.isEmpty) {
          return CartMutationResult(
            error: ApiException.local(
              'The cart could not be created. Please try again.',
              developerDetail: 'POST ${ApiEndpoints.cartCreate} returned '
                  'no usable cart id: ${res.data}',
            ),
          );
        }
        return CartMutationResult(cart: cart);
      } on ApiException catch (e) {
        return CartMutationResult(error: e);
      }
    });
  }

  /// Adds [qty] more of [productId] to an existing cart.
  ///
  /// POST **increments** — it adds to whatever is already on the line rather
  /// than setting it. Use [setQuantity] for a stepper.
  ///
  /// [productId] is a catalogue id here, not a [CartLineId]: this is the one
  /// mutation that resolves a variable product to its default variation, so the
  /// created line's id will differ from what was sent.
  Future<CartMutationResult> addItem({
    required String cartId,
    required int productId,
    int qty = 1,
  }) async {
    _requirePositive(qty);
    return _serialised(
      cartId,
      () => _mutate(
        cartId,
        () => _api.post(
          _cartPath(cartId),
          data: {'product_id': productId, 'qty': qty},
        ),
      ),
    );
  }

  /// Sets a line to exactly [qty] units.
  ///
  /// Takes a [CartLineId] because PUT matches on the *line* id — passing a
  /// parent product id for a variable product silently adds a second, duplicate
  /// line rather than updating the existing one (PUT is an upsert and does not
  /// resolve variations; verified: `PUT {product_id: 111}` on a cart already
  /// holding line 116 produced both).
  ///
  /// [qty] must be at least 1. The server does not treat 0 as "remove": qty 0
  /// left the line sitting at 1 unit and qty -1 silently deleted it, so neither
  /// is a usable way to empty a line — call [removeItem].
  ///
  /// A qty below 1 is a caller bug, not a server refusal, so it yields an
  /// `ArgumentError` rather than a [CartMutationResult]. It arrives as a failed
  /// future like every other error from this class — `async` deliberately, so a
  /// `.catchError` chain or an unawaited call cannot have it thrown at the
  /// calling frame instead.
  Future<CartMutationResult> setQuantity({
    required String cartId,
    required CartLineId line,
    required int qty,
  }) async {
    _requirePositive(qty);
    return _serialised(
      cartId,
      () => _mutate(
        cartId,
        () => _api.put(
          _cartPath(cartId),
          data: {'product_id': line.value, 'qty': qty},
        ),
      ),
    );
  }

  /// Removes a line.
  ///
  /// [line] must be the id of a line that is actually in the cart. Removing a
  /// valid product that is *not* in the cart returns 404 **and wipes the whole
  /// cart** — the single most damaging thing this app can trigger. Always take
  /// the id from [ServerCartItem.lineId] of a cart you just read.
  ///
  /// A successful DELETE returns the bare JSON string
  /// `"Cart item removed successfully"` and no cart, so this always re-reads.
  Future<CartMutationResult> removeItem({
    required String cartId,
    required CartLineId line,
  }) =>
      _serialised(
        cartId,
        () => _mutate(
          cartId,
          () => _api.delete(
            _cartPath(cartId),
            data: {'product_id': line.value},
          ),
        ),
      );

  /// The coupons the shop is advertising, judged against [cartId].
  ///
  /// **Not queued and not wrapped in [_mutate].** Both exist because every
  /// other cart route destroys the cart on the way in; this one was checked
  /// against a live 2-item cart four times running and left `count` at 2. So it
  /// needs neither the single-flight queue nor a rebuild on failure, and it can
  /// be re-fetched freely — which eligibility requires, since it is computed
  /// against the current basket total and flips when a quantity changes.
  ///
  /// [cartId] is optional but should always be supplied. Without it the list is
  /// identical minus every `is_eligible`, so nothing can tell a usable coupon
  /// from one the basket has not reached.
  ///
  /// An unrecognised id is **not** an error: the server answers 200 with the
  /// full list and `is_eligible: null` (verified live). That is the same
  /// "unknown" the missing-key case means, and [Coupon.canApply] treats both as
  /// offerable rather than greying out every card.
  ///
  /// Throws [ApiException] like any other read — the sheet renders that as a
  /// retry, never as an empty list, because "no coupons" and "we could not ask"
  /// are different sentences.
  Future<List<Coupon>> availableCoupons({String? cartId}) async {
    final id = cartId?.trim() ?? '';
    final res = await _api.get(
      ApiEndpoints.coupons,
      query: {if (id.isNotEmpty) 'cart_id': id},
    );

    final body = res.data;
    if (body is! Map) return const [];

    // Same `{error, data, message}` envelope as apply/remove, and the same rule:
    // a refusal is HTTP 200 with `error: true`, so the status code proves
    // nothing. This route is documented as always succeeding — the check is
    // here so that if it ever does refuse, it is not read as "no coupons".
    if (body['error'] == true) {
      throw ApiException.local(
        asString(body['message'], 'Coupons could not be loaded.'),
        developerDetail: 'GET ${ApiEndpoints.coupons} returned error:true — $body',
      );
    }
    return Coupon.listFrom(body['data']);
  }

  /// Applies a coupon to the cart.
  ///
  /// The cart is identified by a `cart_id` in the **body**, not in the path —
  /// `ApplyCouponRequest` requires it, and putting the id in the path 404s.
  ///
  /// A rejected code ("This coupon is invalid or expired!") destroys the cart
  /// exactly like a failed add: `apply()` restores the cart, then returns on the
  /// error branch without storing it. Confirmed against a captured 3-item cart
  /// that was empty after one bad code.
  ///
  /// The response body is deliberately ignored. It carries a cart, but a reduced
  /// one — raw `Cart` content with no formatted prices or image URLs — and it
  /// reported `applied_coupon_code: null` immediately after saying
  /// `Applied coupon "FRESH10" successfully!`. The re-read is authoritative.
  Future<CartMutationResult> applyCoupon({
    required String cartId,
    required String code,
  }) =>
      _serialised(
        cartId,
        () => _mutate(
          cartId,
          () => _api.post(
            ApiEndpoints.couponApply,
            data: {'coupon_code': code, 'cart_id': cartId},
          ),
          trustResponseBody: false,
        ),
      );

  /// Removes the applied coupon.
  ///
  /// Same body-carried `cart_id`. Two refusals are routine and both are
  /// destructive: "Cart is empty" and "No coupon code found" (returned whenever
  /// no line carries a `coupon_code` option), each returning after `restore()`
  /// without a `store()`.
  Future<CartMutationResult> removeCoupon({required String cartId}) =>
      _serialised(
        cartId,
        () => _mutate(
          cartId,
          () => _api.post(
            ApiEndpoints.couponRemove,
            data: {'cart_id': cartId},
          ),
          trustResponseBody: false,
        ),
      );

  // ---- rebuilding after a wipe -------------------------------------------

  /// Puts a destroyed cart back: re-POSTs every mirrored line into the **same**
  /// cart id, in order, then re-applies the coupon.
  ///
  /// Call this after **any** cart or coupon failure — including HTTP 200 with
  /// `"error": true`, which is how this backend reports every business refusal.
  /// The cart id is reused rather than a new one minted because a coupon, a
  /// checkout and a shipping quote are all bound to it, and because the server
  /// happily re-creates a row under an id whose row it just deleted.
  ///
  /// Only the shortfall is posted. `POST` accumulates, so re-posting a line the
  /// wipe did not take would double it; [survivor] (the cart already read after
  /// the failure) is the baseline, and is re-read here when it is not supplied.
  ///
  /// Each re-POST can itself be refused, and a refusal wipes the cart *again* —
  /// so a line the server will not take back is recorded and skipped, and the
  /// pass restarts from a fresh read. Bounded to three passes: a customer
  /// waiting on recovery is not owed an unbounded retry loop.
  Future<CartRebuildOutcome> rebuild({
    required String cartId,
    required List<CartMirrorLine> lines,
    String? couponCode,
    ServerCart? survivor,
  }) =>
      _serialised(
        cartId,
        () => _rebuild(cartId, lines, couponCode, survivor),
      );

  Future<CartRebuildOutcome> _rebuild(
    String cartId,
    List<CartMirrorLine> lines,
    String? couponCode,
    ServerCart? survivor,
  ) async {
    if (lines.isEmpty) return const CartRebuildOutcome();

    var pass = await _restoreLines(cartId, lines, survivor, const {});

    final code = (couponCode ?? '').trim();
    var couponRestored = false;
    var couponLost = false;

    if (code.isNotEmpty && pass.refused.length < lines.length) {
      try {
        await _api.post(
          ApiEndpoints.couponApply,
          data: {'coupon_code': code, 'cart_id': cartId},
        );
        couponRestored = true;
      } on ApiException {
        // A refused coupon is itself one of the wipe paths, so the lines just
        // put back are gone again. Restore them once more and continue without
        // the discount: losing a coupon is recoverable, losing the basket while
        // trying to recover the basket is not.
        couponLost = true;
        pass = await _restoreLines(cartId, lines, null, pass.refused);
      }
    }

    ServerCart? cart;
    ApiException? readError;
    try {
      cart = await _read(cartId);
    } on ApiException catch (e) {
      readError = e;
    }

    // Counted off the server's own answer rather than off what was posted —
    // the only number worth reporting is what the customer actually has.
    var lost = lines.length;
    if (cart != null) {
      final held = {for (final item in cart.items) item.lineId.value: item.quantity};
      lost = 0;
      for (final line in lines) {
        if ((held[line.productId] ?? 0) < line.qty) lost++;
      }
    }

    // Same rule for the coupon: the apply endpoint has been seen answering
    // `applied_coupon_code: null` in the same breath as "Applied coupon
    // successfully", so the re-read decides, not the response that claimed it.
    final couponMissing =
        code.isNotEmpty && cart != null && cart.appliedCouponCode != code;

    return CartRebuildOutcome(
      cart: cart,
      linesRestored: lines.length - lost,
      linesLost: lost,
      couponRestored: couponRestored && !couponMissing,
      couponLost: couponLost || couponMissing,
      refusal: pass.firstRefusal,
      readError: readError,
    );
  }

  /// One or more passes of re-POSTing [lines], skipping anything the server has
  /// already refused this rebuild.
  Future<_RestorePass> _restoreLines(
    String cartId,
    List<CartMirrorLine> lines,
    ServerCart? survivor,
    Map<int, ApiException> alreadyRefused,
  ) async {
    final refused = Map<int, ApiException>.of(alreadyRefused);
    ApiException? firstRefusal =
        alreadyRefused.isEmpty ? null : alreadyRefused.values.first;

    var baseline = survivor;

    for (var attempt = 0; attempt < 3; attempt++) {
      final ServerCart current;
      if (baseline != null) {
        current = baseline;
      } else {
        try {
          current = await _read(cartId);
        } on ApiException {
          // Nothing can be reconciled without a baseline; posting blind would
          // duplicate the lines the wipe left alone.
          break;
        }
      }

      final held = {
        for (final item in current.items) item.lineId.value: item.quantity,
      };

      ApiException? wiped;
      for (final line in lines) {
        if (refused.containsKey(line.productId)) continue;
        final delta = line.qty - (held[line.productId] ?? 0);
        if (delta < 1) continue;

        try {
          await _api.post(
            _cartPath(cartId),
            data: {
              'product_id': line.productId,
              'qty': delta,
              if (line.options.isNotEmpty) 'options': line.options,
            },
          );
          held[line.productId] = line.qty;
        } on ApiException catch (e) {
          refused[line.productId] = e;
          firstRefusal ??= e;
          wiped = e;
          break;
        }
      }

      if (wiped == null) break;
      // The refusal took the cart with it, so everything restored so far is
      // gone. Start again from what the server actually holds now.
      baseline = null;
    }

    return _RestorePass(refused, firstRefusal);
  }

  // ---- plumbing -----------------------------------------------------------

  /// Guards the two quantities the server mishandles instead of rejecting.
  ///
  /// `PUT /cart/{id}` has no `min:1` rule: qty 0 silently leaves the line at one
  /// unit and a **negative** qty deletes it. `POST` does validate `min:1`, but a
  /// 422 there is a wipe like any other refusal, so neither call is allowed to
  /// carry a quantity below 1. Removing a line is [removeItem]'s job.
  void _requirePositive(int qty) {
    if (qty < 1) {
      throw ArgumentError.value(
        qty,
        'qty',
        'must be >= 1; use removeItem() to delete a line',
      );
    }
  }

  /// Runs a mutation and resolves the cart's true state afterwards.
  ///
  /// [trustResponseBody] is false for endpoints whose own response cannot be
  /// used to render the cart; when a mutation succeeds and its body does carry a
  /// full cart, that body is the same serialization [fetch] would return, so the
  /// extra round trip is skipped.
  ///
  /// Always called with the cart's queue slot already held, so it uses [_read]
  /// rather than [fetch].
  Future<CartMutationResult> _mutate(
    String cartId,
    Future<Response<dynamic>> Function() call, {
    bool trustResponseBody = true,
  }) async {
    try {
      final res = await call();
      if (trustResponseBody) {
        final cart = ServerCart.tryFrom(res.data, fallbackId: cartId);
        if (cart != null) return CartMutationResult(cart: cart);
      }
      // No cart in the body (DELETE, or an endpoint we do not trust) — read it.
      try {
        return CartMutationResult(cart: await _read(cartId));
      } on ApiException catch (refresh) {
        return CartMutationResult(refreshError: refresh);
      }
    } on ApiException catch (e) {
      return _afterFailure(cartId, e);
    }
  }

  /// The whole point of this class: a refused mutation may have emptied the
  /// cart, so the caller gets the surviving cart with the error.
  ///
  /// The surviving cart is what a rebuild is diffed against; the rebuild itself
  /// is driven by the caller, which owns the mirror.
  Future<CartMutationResult> _afterFailure(
    String cartId,
    ApiException error,
  ) async {
    try {
      return CartMutationResult(cart: await _read(cartId), error: error);
    } on ApiException catch (refresh) {
      return CartMutationResult(error: error, refreshError: refresh);
    }
  }
}

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/errors/api_exception.dart';
import '../../core/errors/error_presenter.dart';
import '../../core/utils/json_utils.dart';
import '../../data/models/coupon.dart';
import '../../data/models/product_model.dart';
import '../../data/models/server_cart.dart';
import '../../data/repositories/cart_repository.dart';
import 'core_providers.dart';

/// The cart, as the server reports it.
///
/// ## Why there is no local mutation anywhere in this file
///
/// `Cart::restore()` on the backend deletes the stored cart row as it loads it,
/// and every controller error path returns before `store()` writes it back. A
/// refused mutation therefore destroys the **whole** cart, not just the line it
/// rejected (docs/BACKEND_BUGS.md finding 0). So:
///
///  * nothing is applied optimistically — the UI only ever renders a cart the
///    server just serialized;
///  * after a failure the repository re-reads and hands back the surviving
///    cart, which is what gets stored, even though the operation failed;
///  * if that re-read also fails the cart is genuinely unknown, and this state
///    says so ([contentsUnknown]) rather than showing a stale total.
///
/// ## And why there is nevertheless a local *mirror*
///
/// Rendering the surviving cart is honest but not enough: the customer did not
/// empty their basket, the server did, and telling them so while showing an
/// empty screen is a lost order. So every cart the server serializes is also
/// written to disk as a [CartMirror] — the lines (variation id, quantity, any
/// chosen options) and the applied coupon. On any refusal the mirror is replayed
/// into the **same** cart id and the coupon re-applied
/// ([CartRepository.rebuild]). The mirror is only ever built from a cart the
/// server just returned, so it can never invent a line. A plain read is allowed
/// to *widen* it and never to shrink it: adopting an empty read would erase the
/// record of what to put back, but refusing reads outright left every install
/// that upgraded holding a server cart id with no mirror at all — and so
/// nothing to rebuild from on its first refusal.
///
/// Money is never computed here. Subtotal, discounts, tax and order total all
/// come from the cart payload.
class ServerCartState {
  const ServerCartState({
    this.cart,
    this.loading = true,
    this.busy = false,
    this.busyLine,
    this.error,
    this.contentsUnknown = false,
    this.variationLines = const {},
    this.rebuild,
    this.recoveryMessage,
  });

  /// Null until the first read completes, or when the contents are unknown.
  final ServerCart? cart;

  /// First load in flight.
  final bool loading;

  /// A mutation is in flight. The UI should disable steppers rather than let a
  /// second request race the first — concurrent writes to this backend are how
  /// a cart gets wiped.
  ///
  /// This is a **global** fact and belongs only to global controls — Checkout,
  /// Clear cart, the coupon field. A per-item control must ask [isBusyLine]
  /// instead; driving one stepper's appearance off this flag is what made every
  /// tile on screen react to a tap on one of them.
  final bool busy;

  /// The line the in-flight mutation is writing, when it is writing one.
  ///
  /// Null for a mutation with no single line to blame: adding a product (which
  /// has no line until the server answers), a coupon, a clear. Those are
  /// exactly the cases where no per-item control should be reacting anyway.
  final int? busyLine;

  /// The last failure, kept until the next action. Carries the server's own
  /// wording.
  final ApiException? error;

  /// A mutation failed *and* the follow-up read failed. Totals are unknowable;
  /// show a retry, never a number.
  final bool contentsUnknown;

  /// What the last rebuild achieved, or null when the last action needed none.
  ///
  /// Set whenever a refusal was found to have destroyed the cart. Read
  /// [CartRebuildOutcome.isComplete] before drawing anything reassuring: an
  /// incomplete rebuild means the customer has genuinely lost items, and
  /// [recoveryMessage] says which.
  final CartRebuildOutcome? rebuild;

  /// A sentence about the rebuild, or null when nothing was lost.
  ///
  /// Only set when items or the coupon could not be put back — a successful
  /// rebuild is invisible on purpose, because from the customer's point of view
  /// nothing happened to their basket.
  final String? recoveryMessage;

  /// The server cart was destroyed by the last refusal and rebuilt from the
  /// mirror.
  bool get wasRebuilt => rebuild != null;

  /// The rebuild ran and could not put everything back. The cart on screen is
  /// short of items the customer chose — never present it as their own doing.
  bool get itemsLost => rebuild != null && !rebuild!.isComplete;

  /// Catalogue product id → the cart line the server resolved it to.
  ///
  /// Only variable products appear here, and only after one has been added in
  /// this session. `POST {product_id: 120}` comes back as line **121** — the
  /// default variation — and nothing in the payload links 121 back to 120:
  /// the line carries no parent id, and `product_type` is null. The catalogue
  /// list rows give no hint either; a simple product and a variable one have
  /// byte-identical field sets, so a grid tile cannot tell them apart.
  ///
  /// So this is not inference. It records what the server answered: *"you
  /// asked for 120 and line 121 grew."* Without it a variable product added
  /// from a grid leaves its tile still showing ADD, and tapping again silently
  /// buys a second one.
  ///
  /// Deliberately **not persisted**: it describes one session's adds. After a
  /// restart the tile shows ADD again for a variable product already in the
  /// basket — a smaller wrong than persisting a mapping that a stock change on
  /// the server could invalidate. The real fix is a `parent_id` on the cart
  /// line; see followUps.
  final Map<int, int> variationLines;

  List<ServerCartItem> get items => cart?.items ?? const [];

  /// Total units, not lines.
  int get count => cart?.count ?? 0;

  bool get isEmpty => items.isEmpty;

  /// True once a cart has actually been read from the server.
  bool get isReady => !loading && cart != null;

  String? get appliedCouponCode => cart?.appliedCouponCode;

  /// Units of one line, or 0. Takes a [CartLineId] because that is what the
  /// server matches on — see the type's own doc for why a product id will not
  /// do for variable products.
  int quantityOf(CartLineId line) => cart?.quantityOf(line) ?? 0;

  /// The cart line a catalogue product currently occupies, or null.
  ///
  /// For a simple product the line id *is* the product id. For a variable one
  /// it is the variation the server picked, which is only knowable from
  /// [variationLines]. Steppers must drive **this** — passing a parent id to
  /// `PUT` adds a duplicate line, and to `DELETE` 404s, which wipes the cart.
  CartLineId? lineForProduct(int productId) {
    const direct = CartLineId.forSimpleProduct;
    if (cart?.lineFor(direct(productId)) != null) return direct(productId);

    final resolved = variationLines[productId];
    if (resolved == null) return null;
    final line = direct(resolved);
    return cart?.lineFor(line) != null ? line : null;
  }

  /// Units of a catalogue product, for widgets that only hold a [Product].
  ///
  /// Resolves through [variationLines] so a variable product added from a grid
  /// shows its stepper rather than another ADD button. Returns 0 for a variable
  /// product that was added in an earlier session — see [variationLines].
  int quantityOfProduct(int productId) {
    final line = lineForProduct(productId);
    return line == null ? 0 : quantityOf(line);
  }

  /// Whether [line] is the one currently being written.
  ///
  /// The per-item counterpart of [busy]: a stepper, an item row, a product
  /// tile. False the moment the write finishes, and false for every other line
  /// throughout — which is the whole point.
  bool isBusyLine(CartLineId line) => busy && busyLine == line.value;

  ServerCartState copyWith({
    ServerCart? cart,
    bool? loading,
    bool? busy,
    int? busyLine,
    ApiException? error,
    bool? contentsUnknown,
    Map<int, int>? variationLines,
    CartRebuildOutcome? rebuild,
    String? recoveryMessage,
    bool clearError = false,
    bool clearCart = false,
    bool clearRebuild = false,
    bool clearBusyLine = false,
  }) =>
      ServerCartState(
        cart: clearCart ? null : (cart ?? this.cart),
        loading: loading ?? this.loading,
        busy: busy ?? this.busy,
        busyLine: clearBusyLine ? null : (busyLine ?? this.busyLine),
        error: clearError ? null : (error ?? this.error),
        contentsUnknown: contentsUnknown ?? this.contentsUnknown,
        variationLines: variationLines ?? this.variationLines,
        rebuild: clearRebuild ? null : (rebuild ?? this.rebuild),
        recoveryMessage:
            clearRebuild ? null : (recoveryMessage ?? this.recoveryMessage),
      );
}

class ServerCartNotifier extends StateNotifier<ServerCartState> {
  ServerCartNotifier(this._ref, {this.namespace = ''})
      : super(const ServerCartState()) {
    _restore();
  }

  final Ref _ref;

  /// Which cart this instance is. Empty is the customer's basket.
  ///
  /// Two carts exist at once: the basket the customer fills over days, and the
  /// throwaway one "Buy now" creates for a single product. They are separate on
  /// the server too — `POST /cart` with no id mints a fresh uuid
  /// (`CartController::store`, verified live) — so the only thing keeping them
  /// apart on this side is that each remembers its own id and its own rebuild
  /// mirror. Sharing those keys would have the shortcut quietly overwrite the
  /// basket's handle, which is the one thing this class exists to protect.
  final String namespace;

  /// The handle on the server cart. Without it the cart is unreachable — the
  /// server issues no other way to find it again.
  String get _cartIdKey => 'server_cart_id_v1$namespace';

  /// The mirror: what the server last told us the cart holds.
  ///
  /// Not a cache. Nothing is ever *rendered* from it — the UI still only draws a
  /// cart the server just serialized, because a cached copy would go stale the
  /// moment stock or a price moved. It exists for one job: naming the lines to
  /// re-POST when a refusal destroys the cart, which is otherwise unrecoverable.
  String get _mirrorKey => 'server_cart_mirror_v1$namespace';

  CartRepository get _repo => _ref.read(cartRepositoryProvider);

  SharedPreferences get _prefs => _ref.read(sharedPreferencesProvider);

  String? get _storedId => _prefs.getString(_cartIdKey);

  Future<void> _storeId(String id) => _prefs.setString(_cartIdKey, id);

  Future<void> _forgetId() => _prefs.remove(_cartIdKey);

  // ---- the mirror --------------------------------------------------------

  /// The mirror for [cartId], or null when there is none for that cart.
  ///
  /// Scoped to the id because a mirror is only ever replayed into the cart it
  /// was captured from: the coupon is stamped on that cart's first line, and the
  /// checkout, the shipping quote and the discount all hang off the same id.
  CartMirror? _mirrorFor(String cartId) {
    final mirror = CartMirror.tryDecode(_prefs.getString(_mirrorKey));
    return mirror != null && mirror.cartId == cartId ? mirror : null;
  }

  Future<void> _writeMirror(CartMirror mirror) =>
      _prefs.setString(_mirrorKey, mirror.encode());

  /// Records a cart the server just returned, after an operation it accepted.
  ///
  /// This is the authoritative write: the mutation succeeded, so the cart that
  /// came back is the whole truth and replaces the mirror outright — including
  /// dropping a line the customer just removed.
  Future<void> _mirrorCart(String cartId, ServerCart cart) =>
      _writeMirror(CartMirror.of(cart, cartId: cartId));

  /// Widens the mirror to cover a cart that was merely **read**.
  ///
  /// The mirror used to be written only after a successful mutation, and the
  /// reason given was sound: a read that comes back empty is indistinguishable
  /// from a wipe, so *adopting* one would erase the record of what to put back.
  /// But the conclusion drawn from it was too strong. An install that upgrades
  /// while already holding a `server_cart_id_v1` has no mirror at all, so its
  /// very first refusal has nothing to rebuild from — and that basket is lost
  /// for real, which is the exact outcome the mirror exists to prevent.
  ///
  /// So a read may **add** lines, units and a coupon to the mirror and may not
  /// take any away. The mirror is therefore never emptier than the cart the
  /// server last showed us, a wipe still cannot shrink it, and the upgrading
  /// install is covered from its first refresh onwards.
  Future<void> _seedMirrorFromRead(String cartId, ServerCart cart) async {
    final widened = _widen(
      _mirrorFor(cartId),
      CartMirror.of(cart, cartId: cartId),
    );
    if (widened == null) return;
    await _writeMirror(widened);
  }

  /// [fresh] merged into [held] so that no line, unit or coupon is ever lost.
  ///
  /// Returns null when [held] already covers everything [fresh] describes —
  /// which is the common case, and skipping the write keeps a pull-to-refresh
  /// from touching disk on every pull.
  static CartMirror? _widen(CartMirror? held, CartMirror fresh) {
    if (held == null) {
      // Nothing to seed from an empty cart: `_rebuildAfterWipe` bails on an
      // empty mirror anyway, so writing one would only add noise to prefs.
      return fresh.isEmpty && fresh.couponCode == null ? null : fresh;
    }

    final unseen = {for (final line in held.lines) line.productId: line};
    final lines = <CartMirrorLine>[];
    var grew = false;

    for (final line in fresh.lines) {
      final was = unseen.remove(line.productId);
      if (was == null || was.qty < line.qty) {
        grew = true;
        lines.add(line);
      } else {
        lines.add(was);
      }
    }

    // Lines the read did not return are kept exactly as they were: a cart that
    // comes back short is what a wipe looks like, and dropping them here would
    // throw away the only record of what to restore.
    for (final line in held.lines) {
      if (unseen.containsKey(line.productId)) lines.add(line);
    }

    final coupon = fresh.couponCode ?? held.couponCode;
    if (coupon != held.couponCode) grew = true;

    return grew
        ? CartMirror(cartId: fresh.cartId, lines: lines, couponCode: coupon)
        : null;
  }

  Future<void> _forgetMirror() => _prefs.remove(_mirrorKey);

  // ---- lifecycle ---------------------------------------------------------

  Future<void> _restore() async {
    final id = _storedId;
    if (id == null || id.isEmpty) {
      // No server cart yet. An upgrading install may still hold a cart from the
      // old local implementation, which is worth moving across before the user
      // notices it vanish.
      await _migrateLegacyLocalCart();
      if (_storedId == null) {
        // Nothing to migrate. Not an error, and not worth a request — a cart is
        // created on the first add.
        if (mounted) state = const ServerCartState(loading: false);
        return;
      }
    }
    await refresh();
  }

  /// Legacy key written by the pre-server cart.
  static const _legacyKey = 'cart_items_v1';

  /// Moves a pre-existing local cart onto the server, once.
  ///
  /// `POST /ecommerce/cart/refresh` — the bulk endpoint that exists for exactly
  /// this — is unreachable: it is declared after `POST /cart/{id}` and Laravel
  /// matches in registration order, so the request binds `{id} = "refresh"` and
  /// creates a cart named "refresh". Items therefore go across one at a time.
  ///
  /// ## Why this holds [ServerCartState.busy] across the whole loop
  ///
  /// This is a cart mutation like any other, and the most damaging one in the
  /// app: its first item **mints the cart**. `CartRepository` serialises
  /// `createCart` on its own `_mintingKey` queue rather than on a cart id —
  /// there is no id yet to queue on — so the repository queue cannot help here.
  /// A tap on a product tile while this loop is running finds `_storedId` still
  /// null, queues its own `createCart` behind the migration's, and mints a
  /// **second** cart; whichever `_storeId` lands last silently orphans the
  /// other one, and an orphaned cart is unreachable forever because the server
  /// issues no way to look a cart up again.
  ///
  /// So the migration claims `busy` before its first request and holds it until
  /// the last, which is the same single-flight discipline [_run] applies to
  /// every other mutation — a concurrent tap is dropped rather than raced,
  /// exactly as a second stepper tap already is, and the UI already disables
  /// its steppers while `busy` is set.
  ///
  /// The legacy key is cleared whatever happens. Leaving it would re-run the
  /// migration on the next launch and duplicate whatever did get through, and a
  /// cart the customer can see on the server is a better outcome than one they
  /// cannot.
  Future<void> _migrateLegacyLocalCart() async {
    final prefs = _ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(_legacyKey);
    if (raw == null || raw.isEmpty) return;

    // Unreachable from the constructor, where nothing has run yet — but a
    // migration that ran *alongside* a mutation is the whole bug, so it refuses
    // rather than assumes. The legacy key deliberately survives that refusal:
    // the next launch retries it against a quiet notifier.
    if (state.busy) return;
    state = state.copyWith(busy: true);

    try {
      final decoded = jsonDecode(raw);
      final lines = decoded is List
          ? decoded.whereType<Map>().toList()
          : const <Map>[];

      for (final line in lines) {
        final productId = asInt(line['product_id']);
        final qty = asInt(line['quantity'], 1);
        if (productId <= 0 || qty <= 0) continue;

        final id = _storedId;
        final result = id == null || id.isEmpty
            ? await _repo.createCart(productId: productId, qty: qty)
            : await _repo.addItem(cartId: id, productId: productId, qty: qty);

        if (result.isResolved) {
          await _storeId(result.cart!.id);
        } else if (result.error != null) {
          // A refusal here may have wiped whatever migrated so far. Stop rather
          // than compound it; the surviving cart is re-read below.
          ErrorLog.capture(
            result.error!,
            context: 'cart.migrateLegacy',
          );
          break;
        }
      }
    } catch (e, s) {
      ErrorLog.capture(e, stackTrace: s, context: 'cart.migrateLegacy');
    } finally {
      await prefs.remove(_legacyKey);
      // Released before the `refresh()` that follows, so a tap arriving during
      // that read is served rather than dropped — the cart id is stored by
      // then, so it can no longer mint a second cart.
      if (mounted) state = state.copyWith(busy: false);
    }
  }

  /// Re-reads the cart. Safe to call at any time — `GET` is the one cart route
  /// that does not destroy it.
  ///
  /// Safe, but not concurrency-free: `index()` also does `restore()` then
  /// `store()`, so a read landing between another call's restore and store is
  /// the `CartAlreadyStoredException` race. The repository queues this behind
  /// any write already in flight for the same id, which is why this does not
  /// (and must not) refuse to run while [ServerCartState.busy] — refusing would
  /// leave a pull-to-refresh silently doing nothing.
  ///
  /// What comes back **widens** the mirror and can never shrink it
  /// ([_seedMirrorFromRead]). A read that returns an empty cart is exactly what
  /// a wipe looks like and there is no way to tell the two apart from a single
  /// GET — so it is not adopted — but a read that shows *more* than the mirror
  /// knows about is the only chance an upgrading install ever gets to record a
  /// basket it did not create.
  Future<void> refresh() async {
    final id = _storedId;
    if (id == null || id.isEmpty) {
      state = const ServerCartState(loading: false);
      return;
    }

    state = state.copyWith(loading: true, clearError: true);
    try {
      final cart = await _repo.fetch(id);
      if (!mounted) return;
      await _seedMirrorFromRead(id, cart);
      if (!mounted) return;
      state = ServerCartState(
        cart: cart,
        loading: false,
        busy: state.busy,
        // Both survive the read: the mapping still names lines the server just
        // returned, and a rebuild the customer has not acknowledged is not
        // undone by a refresh.
        variationLines: state.variationLines,
        rebuild: state.rebuild,
        recoveryMessage: state.recoveryMessage,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      // Already logged by ApiClient.
      state = ServerCartState(
        loading: false,
        busy: state.busy,
        error: e,
        contentsUnknown: true,
        variationLines: state.variationLines,
      );
    }
  }

  // ---- mutations ---------------------------------------------------------

  /// Adds [quantity] of [product], creating the cart if this is the first item.
  ///
  /// Returns the server's message on refusal ("Maximum quantity is 93!"), or
  /// null on success, so the caller can surface it verbatim.
  ///
  /// ⚠ **Not for a variable product.** This posts the product's own id, and the
  /// server answers a parent id by resolving it to the *default* variation —
  /// so the customer's chosen pack is silently discarded. Screens that hold a
  /// selection must call [addProductId] with the variation's id.
  Future<String?> add(Product product, {int quantity = 1}) =>
      addProductId(product.id, quantity: quantity);

  /// Adds [quantity] of the product with [productId].
  ///
  /// [productId] is a **catalogue** id, not a [CartLineId]: this is the one
  /// mutation that resolves a variable product to a variation, so the line that
  /// comes back may carry a different id than the one sent. For a chosen
  /// variation, pass that variation's id and the line comes back matching it.
  Future<String?> addProductId(int productId, {int quantity = 1}) async {
    if (quantity < 1) {
      // Never let this reach the wire. `POST` validates `min:1`, and its 422 is
      // a wipe like any other refusal — so a caller's off-by-one would cost the
      // customer their basket rather than just failing.
      return _reject(
        'That quantity is not available.',
        detail: 'addProductId($productId) called with quantity $quantity',
      );
    }

    final before = state.cart;

    final message = await _run(() async {
      final id = _storedId;
      if (id == null || id.isEmpty) {
        final result = await _repo.createCart(
          productId: productId,
          qty: quantity,
        );
        // Persist before anything else: without the id the cart is
        // unreachable, and the server offers no way to find it again.
        if (result.isResolved) await _storeId(result.cart!.id);
        return result;
      }
      return _repo.addItem(cartId: id, productId: productId, qty: quantity);
    });

    if (mounted) _learnVariationLine(productId, before, state.cart);
    return message;
  }

  /// Starts a "Buy now": a cart holding one unit of [productId] and nothing
  /// else.
  ///
  /// Only ever called on the **buy-now** instance. It abandons whatever the
  /// last "Buy now" left — id and mirror both — and lets [addProductId] mint a
  /// fresh cart server-side, so two taps in a row cannot stack two products on
  /// the checkout screen.
  ///
  /// The customer's basket is a different instance with different storage, and
  /// nothing here can reach it. That is the whole point: the shortcut must not
  /// carry the basket to checkout, and it must not empty it either.
  ///
  /// The abandoned server-side cart row is left where it is. Deleting it would
  /// mean a DELETE against a cart this app is no longer tracking, and on this
  /// backend a refused delete takes the whole cart with it — an orphaned row
  /// nobody can reach is the cheaper outcome.
  ///
  /// Returns the server's refusal, or null on success — the same contract as
  /// [addProductId], because that is what it is underneath.
  Future<String?> startBuyNow(int productId) async {
    await forget();
    return addProductId(productId);
  }

  /// Records which line the server resolved [requestedId] to.
  ///
  /// Adding a variable product's parent id yields a line under the *default
  /// variation's* id, and nothing in the response links the two. Diffing the
  /// cart across the add recovers it from the server's own answer: the line
  /// that grew is the line the request created.
  ///
  /// Does nothing for a simple product, where a line under the requested id
  /// already exists and no mapping is needed.
  void _learnVariationLine(int requestedId, ServerCart? before, ServerCart? after) {
    if (after == null) return;
    if (after.lineFor(CartLineId.forSimpleProduct(requestedId)) != null) return;

    final was = <int, int>{
      for (final item in before?.items ?? const <ServerCartItem>[])
        item.lineId.value: item.quantity,
    };

    for (final item in after.items) {
      if (item.quantity > (was[item.lineId.value] ?? 0)) {
        state = state.copyWith(
          variationLines: {...state.variationLines, requestedId: item.lineId.value},
        );
        return;
      }
    }
  }

  /// Sets a line to exactly [quantity]. Below 1, removes it — the server does
  /// not treat 0 as a delete.
  Future<String?> setQuantity(CartLineId line, int quantity) {
    if (quantity < 1) return remove(line);
    return _run(
      () async {
        final id = _requireId();
        if (id == null) return null;
        return _repo.setQuantity(cartId: id, line: line, qty: quantity);
      },
      busyLine: line.value,
    );
  }

  Future<String?> increment(CartLineId line) =>
      setQuantity(line, quantityOfLine(line) + 1);

  Future<String?> decrement(CartLineId line) =>
      setQuantity(line, quantityOfLine(line) - 1);

  int quantityOfLine(CartLineId line) => state.quantityOf(line);

  /// Removes a line.
  ///
  /// [line] must come from a cart that was actually read — removing something
  /// not in the cart 404s *and wipes the cart*. That 404 also proves the line
  /// was already gone, so it is dropped from the mirror rather than rebuilt:
  /// see [_run]'s `dropsLine`.
  Future<String?> remove(CartLineId line) => _run(
        () async {
          final id = _requireId();
          if (id == null) return null;
          return _repo.removeItem(cartId: id, line: line);
        },
        dropsLine: line.value,
        busyLine: line.value,
      );

  /// Applies a coupon server-side. The discount, and whether it grants free
  /// shipping, are the server's to decide.
  Future<String?> applyCoupon(String code) => _run(() async {
        final id = _requireId();
        if (id == null) return null;
        return _repo.applyCoupon(cartId: id, code: code);
      });

  /// Removes the applied coupon.
  ///
  /// "No coupon code found" and "Cart is empty" are both routine refusals here
  /// and both destroy the cart. Either way the customer asked for the discount
  /// off, so the rebuild that follows must not put it back — hence
  /// `dropsCoupon`.
  Future<String?> removeCoupon() => _run(
        () async {
          final id = _requireId();
          if (id == null) return null;
          return _repo.removeCoupon(cartId: id);
        },
        dropsCoupon: true,
      );

  /// Empties the cart by removing every line it currently holds.
  ///
  /// There is no bulk-clear route. Lines are removed one at a time from a cart
  /// that was just read, and the loop stops on the first refusal so a wipe is
  /// not compounded.
  Future<String?> clear() async {
    final lines = [for (final item in state.items) item.lineId];
    for (final line in lines) {
      final message = await remove(line);
      if (message != null) return message;
    }
    return null;
  }

  /// Drops the local handle on the cart.
  ///
  /// Used after an order is placed: the server has consumed the cart, so the id
  /// no longer refers to anything worth reading. The mirror goes with it — a
  /// mirror outliving its cart id would try to rebuild a basket the customer has
  /// already paid for.
  Future<void> forget() async {
    await _forgetId();
    await _forgetMirror();
    if (mounted) state = const ServerCartState(loading: false);
  }

  // ---- plumbing ----------------------------------------------------------

  /// Refuses an action locally, without a request, and reports it like any
  /// server refusal so the caller has one thing to show.
  String _reject(String message, {String? detail}) {
    final error = ApiException.local(message, developerDetail: detail);
    ErrorLog.capture(error, context: 'cart.reject');
    if (mounted) state = state.copyWith(busy: false, error: error);
    return message;
  }

  String? _requireId() {
    final id = _storedId;
    if (id != null && id.isNotEmpty) return id;
    state = state.copyWith(
      busy: false,
      error: ApiException.local(
        'Your cart is no longer available. Please add the item again.',
        developerDetail: 'cart mutation attempted with no stored cart id',
      ),
    );
    return null;
  }

  /// Runs one mutation, records the result in the mirror, and puts the cart back
  /// if the mutation destroyed it.
  ///
  /// The result's cart is stored **whether or not the operation succeeded** —
  /// that is the whole point of the repository re-reading after a failure. A
  /// refusal that also emptied the cart has to be reflected, or the UI would go
  /// on showing lines the server has already deleted.
  ///
  /// What is new is what happens next: a refusal is *assumed* to have destroyed
  /// the cart, so the mirror is diffed against whatever survived and anything
  /// missing is re-POSTed to the same id ([_rebuildAfterWipe]). The refusal is
  /// still reported — the customer asked for something and did not get it — but
  /// they do not also lose the basket they already had.
  ///
  /// [dropsLine] and [dropsCoupon] describe what the action was *for*, so a
  /// refusal cannot make the rebuild undo it: a refused DELETE must not put the
  /// line back, and a refused coupon removal must not put the coupon back.
  /// [busyLine] names the line this write is for, so that only the control
  /// showing that line goes inert. Leave it null for a mutation that is not
  /// about one line — an add, a coupon, a clear.
  Future<String?> _run(
    Future<CartMutationResult?> Function() action, {
    int? dropsLine,
    bool dropsCoupon = false,
    int? busyLine,
  }) async {
    if (state.busy) {
      // Dropped rather than queued *at this level* on purpose: two taps on a
      // stepper are one intent, and replaying the second against a cart the
      // first has already changed sets the wrong quantity. The genuine
      // serialisation — the one that stops `store()` racing itself — is the
      // per-cart-id queue inside CartRepository, which covers reads too.
      return null;
    }
    state = state.copyWith(
      busy: true,
      busyLine: busyLine,
      clearBusyLine: busyLine == null,
      clearError: true,
      clearRebuild: true,
    );

    try {
      final result = await action();
      if (!mounted) return null;
      if (result == null) return state.error?.message;

      final id = _storedId;

      if (result.isResolved && id != null && id.isNotEmpty) {
        // The one place the mirror is written: a cart the server just
        // serialized, after an operation it accepted.
        await _mirrorCart(id, result.cart!);
        if (!mounted) return null;
      }

      final outcome = result.isSuccess
          ? null
          : await _rebuildAfterWipe(
              id,
              result.cart,
              dropsLine: dropsLine,
              dropsCoupon: dropsCoupon,
            );
      if (!mounted) return null;

      final cart = outcome?.cart ?? result.cart;
      final loss = outcome?.lossMessage;

      if (cart != null) {
        state = ServerCartState(
          cart: cart,
          loading: false,
          error: result.error,
          // Survives the mutation: it maps catalogue ids to lines, and the
          // lines it names are still the ones the server just returned.
          variationLines: state.variationLines,
          rebuild: outcome,
          recoveryMessage: loss,
        );
      } else {
        // Mutation failed and every read since failed too — the contents are
        // genuinely unknown. Showing the previous cart here would be a guess,
        // and showing an empty one would be a lie.
        state = ServerCartState(
          loading: false,
          error: result.error ?? result.refreshError ?? outcome?.readError,
          contentsUnknown: true,
          variationLines: state.variationLines,
          rebuild: outcome,
          recoveryMessage: loss,
        );
      }

      final message = result.error?.message;
      if (loss == null) return message;
      return message == null || message.isEmpty ? loss : '$message $loss';
    } catch (e, s) {
      ErrorLog.capture(e, stackTrace: s, context: 'cart.mutate');
      if (!mounted) return null;
      final error = ErrorPresenter.resolve(e);
      state = state.copyWith(
        busy: false,
        clearBusyLine: true,
        error: error,
      );
      return error.message;
    }
  }

  /// Puts the cart back after a refusal destroyed it.
  ///
  /// Runs on **any** failure — a 4xx, a 500, or the HTTP 200 + `"error": true`
  /// this backend reports every business rule with — because all of them return
  /// from the controller between `restore()` (which deletes the stored row) and
  /// `store()`. There is no response that tells the app whether this particular
  /// refusal wiped the cart, so the mirror is compared against what survived and
  /// the answer is read off that instead of guessed.
  ///
  /// Returns null when there is nothing to do: no mirror for this cart, or the
  /// surviving cart already holds everything the mirror recorded — which is the
  /// common case for the handful of refusals that leave the cart intact.
  Future<CartRebuildOutcome?> _rebuildAfterWipe(
    String? cartId,
    ServerCart? survivor, {
    int? dropsLine,
    bool dropsCoupon = false,
  }) async {
    if (cartId == null || cartId.isEmpty) return null;

    var mirror = _mirrorFor(cartId);
    if (mirror == null) return null;

    if (dropsLine != null || dropsCoupon) {
      // The action was a removal. It failed, but it still says what the customer
      // wanted, and the most likely reason a DELETE fails is that the line was
      // already gone — so the mirror is what is stale here, not the server.
      final trimmed = mirror.without(productId: dropsLine, coupon: dropsCoupon);
      if (trimmed.lines.length != mirror.lines.length ||
          trimmed.couponCode != mirror.couponCode) {
        mirror = trimmed;
        await _writeMirror(mirror);
        if (!mounted) return null;
      }
    }

    if (mirror.isEmpty) return null;
    if (!mirror.describesMoreThan(survivor)) return null;

    CartRebuildOutcome outcome;
    try {
      outcome = await _repo.rebuild(
        cartId: cartId,
        lines: mirror.lines,
        couponCode: mirror.couponCode,
        survivor: survivor,
      );
    } catch (e, s) {
      // A rebuild is recovery, and recovery that throws would turn a lost cart
      // into a crash. Report it as a rebuild that could not run.
      ErrorLog.capture(e, stackTrace: s, context: 'cart.rebuild');
      return CartRebuildOutcome(
        cart: survivor,
        linesLost: mirror.missingFrom(survivor).length,
        couponLost: mirror.couponMissingFrom(survivor),
        readError: ErrorPresenter.resolve(e),
      );
    }

    // Re-mirror from the rebuilt cart so a line the server will not take back
    // (out of stock since it was added) is not retried on every later failure.
    // Only when the cart is actually known: a mirror rewritten from a guess
    // would drop items that are still there.
    if (outcome.cart != null) {
      await _mirrorCart(cartId, outcome.cart!);
    }
    return outcome;
  }
}

// `cartRepositoryProvider` lives in core_providers.dart alongside every other
// repository. Declaring a second one here would compile — same type, same body —
// but it would be a *different* provider, so a test overriding one would leave
// the other reaching for a real ApiClient.

final serverCartProvider =
    StateNotifierProvider<ServerCartNotifier, ServerCartState>(
  (ref) => ServerCartNotifier(ref),
);

/// The throwaway cart "Buy now" checks out.
///
/// A second, independent basket: its own server cart id, its own rebuild
/// mirror, its own contents. Nothing outside the Buy-now flow reads it — the
/// cart tab, the nav badge and every product tile stay on [serverCartProvider],
/// so the customer's own basket is neither shown nor touched while a Buy now is
/// in progress.
final buyNowCartProvider =
    StateNotifierProvider<ServerCartNotifier, ServerCartState>(
  (ref) => ServerCartNotifier(ref, namespace: '_buy_now'),
);

/// Which cart the checkout screen is spending.
enum CheckoutCart {
  /// The customer's basket — the ordinary path, from the cart tab.
  basket,

  /// The single product a "Buy now" put in the throwaway cart.
  buyNow,
}

/// Set before opening checkout, and put back when leaving it.
///
/// Deliberately a plain [StateProvider] rather than a `ProviderScope` override
/// around the route. Scoping would re-create every provider that reads it
/// *inside* that scope, and `checkoutFlowProvider` is documented as needing to
/// outlive the screen — it has to survive a rebuild while the Razorpay sheet is
/// up, and a fresh instance mid-payment loses the order the customer is paying
/// for. A flag two screens set explicitly is duller and cannot do that.
///
/// Reset in two places, so a missed one cannot strand the app: the checkout
/// screen puts it back when it is disposed, and the cart screen puts it back
/// whenever it is opened.
final checkoutCartProvider =
    StateProvider<CheckoutCart>((ref) => CheckoutCart.basket);

/// The cart checkout is spending, whichever that is.
///
/// Every checkout-side read goes through here rather than naming
/// [serverCartProvider]. The cart tab does not: it is always the basket, and
/// making it follow this flag is how a Buy now would end up showing the wrong
/// contents on the screen the customer keeps their shopping in.
final activeCartProvider = Provider<ServerCartState>(
  (ref) => ref.watch(
    ref.watch(checkoutCartProvider) == CheckoutCart.buyNow
        ? buyNowCartProvider
        : serverCartProvider,
  ),
);

/// The notifier behind [activeCartProvider], for the writes checkout makes —
/// the Items section's steppers, and `forget()` once an order is paid.
final activeCartNotifierProvider = Provider<ServerCartNotifier>(
  (ref) => ref.watch(
    ref.watch(checkoutCartProvider) == CheckoutCart.buyNow
        ? buyNowCartProvider.notifier
        : serverCartProvider.notifier,
  ),
);

/// Badge count for the bottom nav.
final cartCountProvider =
    Provider<int>((ref) => ref.watch(serverCartProvider).count);

/// What the coupon list depends on, and nothing else.
///
/// Eligibility is computed server-side against the live basket, so the list has
/// to be re-fetched whenever the basket changes — but *only* then. Watching
/// [serverCartProvider] whole would re-fetch on every `busy` flip, which is
/// twice per tap of a quantity stepper.
///
/// The applied code is in here on purpose: applying or removing a coupon is
/// exactly when the sheet's "Applied / Remove" row has to move.
typedef CartCouponKey = ({String? cartId, int count, String total, String? applied});

final _couponKeyProvider = Provider<CartCouponKey>(
  (ref) => ref.watch(
    serverCartProvider.select(
      (s) => (
        cartId: s.cart?.id,
        count: s.count,
        // The formatted total, not the raw double: it is the figure the
        // minimum-order check is stated against, and comparing strings avoids
        // a float that differs in the last place counting as a change.
        total: s.cart?.orderTotal.display ?? '',
        applied: s.appliedCouponCode,
      ),
    ),
  ),
);

/// The coupons worth showing for the current basket.
///
/// `autoDispose` because it is only ever read by the coupon sheet: leaving it
/// alive would keep re-fetching in the background for a sheet nobody has open.
///
/// An error is left as an error rather than degraded to an empty list — "no
/// coupons right now" and "we could not ask" are different sentences, and only
/// one of them deserves a Retry.
final availableCouponsProvider =
    FutureProvider.autoDispose<List<Coupon>>((ref) async {
  final key = ref.watch(_couponKeyProvider);
  return ref
      .read(cartRepositoryProvider)
      .availableCoupons(cartId: key.cartId);
});

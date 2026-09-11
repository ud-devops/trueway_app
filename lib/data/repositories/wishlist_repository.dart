import 'package:shared_preferences/shared_preferences.dart';

import '../../core/errors/api_exception.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/utils/json_utils.dart';
import '../models/product_model.dart';

/// One row of a wishlist / compare list.
///
/// The server keys `data.items` by an opaque `rowId` and repeats it inside the
/// value, so the entry carries it explicitly — it is the only stable handle on a
/// line, and it is *not* the product id.
class WishlistEntry {
  const WishlistEntry({
    required this.rowId,
    required this.product,
    required this.originalProductId,
    required this.isVariation,
    this.variationAttributes,
  });

  final String rowId;
  final Product product;

  /// The parent product when [product] is a variation.
  ///
  /// Variation rows come back with `slug: ""` (verified: product 117 on a live
  /// wishlist), so a tap cannot route by slug. Route by this id instead.
  final int originalProductId;

  final bool isVariation;

  /// Pre-rendered variant label, e.g. `(Pack Size: 1.85 KG (Pack of 1))`.
  ///
  /// Sent only for variation rows, and as a ready-made string rather than the
  /// attribute list the catalogue endpoints use — there is nothing to format,
  /// only to display. Null on simple products.
  final String? variationAttributes;

  /// The id to send back as `product_id` on a mutation.
  ///
  /// The server matches lines on `item->id`, which is the id it stored — the
  /// variation id for a variable product, not the parent. Always echo
  /// [Product.id]; sending [originalProductId] hits the "not in wishlist"
  /// branch, which 404s *and wipes the list*.
  int get mutationId => product.id;

  static WishlistEntry? _tryParse(String rowId, dynamic raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    // WishlistItemResource returns a bare `[]` (so, `{}` after the Map guard
    // above, or a JSON array) when the product row has since been deleted from
    // the catalogue. Those ghost lines still count towards `data.count`.
    if (json['id'] == null) return null;
    final product = Product.fromJson(json);
    return WishlistEntry(
      rowId: asString(json['rowId'], rowId),
      product: product,
      originalProductId: asInt(json['original_product_id'], product.id),
      isVariation: asBool(json['is_variation']),
      variationAttributes: asStringOrNull(json['variation_attributes']),
    );
  }
}

/// The whole list as the server last described it.
class WishlistSnapshot {
  const WishlistSnapshot({
    required this.id,
    required this.entries,
    required this.serverCount,
    this.added,
    this.message,
  });

  const WishlistSnapshot.empty([this.id])
      : entries = const [],
        serverCount = 0,
        added = null,
        message = null;

  /// The identifier this list lives under. Null only before the first POST.
  final String? id;

  final List<WishlistEntry> entries;

  /// `data.count` verbatim. Prefer [count]: the server counts stored rows,
  /// including ones whose product has been deleted and which therefore parse to
  /// nothing, so the two can disagree.
  final int serverCount;

  /// `data.added` — present only on the POST (toggle) response. True when the
  /// product was put on the list, false when the same call took it off.
  final bool? added;

  final String? message;

  int get count => entries.length;
  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;

  Set<int> get productIds => {
        for (final e in entries) ...{e.product.id, e.originalProductId},
      };

  /// Matches on the variation id *and* the parent id, so a heart on a product
  /// card lights up even though the list stored the variation.
  bool contains(int productId) => productIds.contains(productId);

  /// The line a mutation for [productId] must target.
  ///
  /// An exact line-id match always wins over a parent match: a list can hold
  /// both parent 111 and its variation 117 (verified live), and both rows
  /// answer to 111 via [WishlistEntry.originalProductId]. Matching in entry
  /// order would then remove whichever happened to be stored first.
  WishlistEntry? entryFor(int productId) {
    for (final e in entries) {
      if (e.product.id == productId) return e;
    }
    for (final e in entries) {
      if (e.originalProductId == productId) return e;
    }
    return null;
  }

  /// Parses the `{id, data:{count, items, added?}, message?}` envelope.
  ///
  /// Note `items` lives under `data`, unlike the cart where lines sit at the top
  /// level, and that it is a **map keyed by rowId when populated but a JSON
  /// array when empty** — PHP's `[]` serialises as `[]`, not `{}`. Both shapes
  /// are handled here so callers never see the difference.
  factory WishlistSnapshot.fromJson(dynamic body, {String? fallbackId}) {
    final root = asMap(body);
    final data = asMap(root['data']);
    final rawItems = data['items'];

    final entries = <WishlistEntry>[];
    if (rawItems is Map) {
      for (final entry in rawItems.entries) {
        final parsed = WishlistEntry._tryParse('${entry.key}', entry.value);
        if (parsed != null) entries.add(parsed);
      }
    } else if (rawItems is List) {
      for (final item in rawItems) {
        final parsed = WishlistEntry._tryParse('', item);
        if (parsed != null) entries.add(parsed);
      }
    }

    return WishlistSnapshot(
      id: asStringOrNull(root['id']) ?? fallbackId,
      entries: entries,
      serverCount: asInt(data['count'], entries.length),
      added: data['added'] is bool ? data['added'] as bool : null,
      message: asStringOrNull(root['message']),
    );
  }
}

/// Wishlist and compare, which are byte-identical contracts.
///
/// Both are served by controllers that differ only in the `Cart` instance name
/// (`WishlistController` vs `CompareController` in the ecommerce plugin) — same
/// envelope, same toggle semantics, same failure modes. Compare's item resource
/// adds `brand`/`categories`/`attributes`/`variations`, which [Product] ignores.
///
/// ## Anonymity
///
/// Identified solely by an opaque id in the path; the bearer token is never
/// consulted. A signed-out visitor can keep a real wishlist, and it survives
/// login untouched — so the heart on a product card must not gate on auth.
///
/// ## The two traps
///
/// 1. **POST is a toggle, not an add.** Posting a product already on the list
///    *removes* it (verified live: POST 118 twice -> `count: 0`,
///    `added: false`). [add] and [remove] therefore state an intent and
///    self-correct from `data.added`; [toggle] is the raw call.
/// 2. **A failed mutation can wipe the entire list.** Every handler opens with
///    `Cart::restore($identifier)`, which *deletes* the stored row, and only
///    re-`store()`s on the way out. Any path that returns or throws in between
///    leaves nothing behind. Verified live for DELETE: list `[118]`,
///    `DELETE product_id=119` -> 404, next GET -> `count: 0`. The same hole is
///    in POST — `if (! $product) return 404`, plus every uncaught error in the
///    body (`$product->original_product->store` 500s for a variation whose
///    parent is gone). So **no mutation here assumes failure was inert**: both
///    [toggle] and [removeViaDelete] re-read the list before rethrowing, and
///    drop [latest] entirely if that read also fails.
///    [remove] additionally avoids DELETE's *success*-path miss by using the
///    toggle, which stores on every exit; [removeViaDelete] exists for parity
///    but nothing should prefer it.
class WishlistRepository {
  WishlistRepository(ApiClient api, SharedPreferences prefs)
      : _api = api,
        _prefs = prefs;

  final ApiClient _api;
  final SharedPreferences _prefs;

  /// Endpoint pair + storage key, so [CompareRepository] can reuse everything.
  String get _createPath => ApiEndpoints.wishlistCreate;
  String _listPath(String id) => ApiEndpoints.wishlist(id);
  String get _storageKey => 'wishlist_id';

  /// Last authoritative server state. Refreshed on every call, including the
  /// failure paths — after a failed mutation this is the only trustworthy
  /// description of the list.
  WishlistSnapshot? get latest => _latest;
  WishlistSnapshot? _latest;

  String? get identifier {
    final id = _prefs.getString(_storageKey);
    return (id == null || id.isEmpty) ? null : id;
  }

  /// Reads the persisted list.
  ///
  /// Returns an empty snapshot without any request when no identifier has been
  /// minted yet — there is no list-wide GET to fall back on
  /// (`GET /ecommerce/wishlist` 404s: "Supported methods: POST").
  Future<WishlistSnapshot> refresh() async {
    final id = identifier;
    if (id == null) return _remember(const WishlistSnapshot.empty());
    final res = await _api.get(_listPath(id));
    return _remember(WishlistSnapshot.fromJson(res.data, fallbackId: id));
  }

  Future<bool> contains(int productId) async {
    final snapshot = _latest ?? await refresh();
    return snapshot.contains(productId);
  }

  /// The raw POST: adds the product if absent, removes it if present.
  ///
  /// Mints and persists an identifier on the first call. Prefer [add] / [remove]
  /// unless the caller genuinely wants "flip whatever state this is in".
  Future<WishlistSnapshot> toggle(int productId) async {
    final id = identifier;
    try {
      final res = await _api.post(
        id == null ? _createPath : _listPath(id),
        data: {'product_id': productId},
      );
      final snapshot = WishlistSnapshot.fromJson(res.data, fallbackId: id);
      await _persistId(snapshot.id);
      return _remember(snapshot);
    } on ApiException {
      // POST is destructive on failure too, not just DELETE. `store()` calls
      // `Cart::restore($identifier)` — which deletes the stored row — before it
      // does anything else, and only re-`store()`s on the way out. Its
      // `if (! $product) return 404` branch, and *any* exception raised in
      // between (e.g. `$product->original_product->store` on a variation whose
      // parent is gone, which 500s), therefore leave the list destroyed.
      // Never assume a failed mutation left the list untouched.
      await _resync(id);
      rethrow;
    }
  }

  /// Re-reads the list after a failed mutation, discarding the cache.
  ///
  /// If the re-read fails too, [latest] becomes null — "unknown" — rather than
  /// keeping a snapshot that describes a list the server may have just deleted.
  /// A stale snapshot is worse than none: the UI renders from it.
  Future<void> _resync(String? id) async {
    if (id == null) {
      // Nothing was ever stored under an identifier we know, so there is
      // nothing to read back.
      _latest = null;
      return;
    }
    try {
      await refresh();
    } on ApiException {
      _latest = null;
    }
  }

  /// Ensures the product is on the list.
  Future<WishlistSnapshot> add(int productId) =>
      _intend(productId, present: true);

  /// Ensures the product is off the list.
  ///
  /// Routed through the toggle rather than DELETE — see the class docs; DELETE's
  /// miss path destroys the list.
  Future<WishlistSnapshot> remove(int productId) =>
      _intend(productId, present: false);

  /// Drives the toggle towards a stated end state.
  ///
  /// The cached snapshot can be stale (the list is shared by identifier, not by
  /// device), so rather than trusting it the toggle's own `data.added` is
  /// checked and one corrective toggle is issued if it moved the wrong way.
  /// Bounded at two requests; it cannot loop.
  ///
  /// [productId] may be a *parent* id — [WishlistSnapshot.contains] matches
  /// parents on purpose so a product card's heart lights up for a wishlisted
  /// variation — so it is translated to the id the server actually stored
  /// before anything is sent. Posting the parent instead would not remove the
  /// variation: the server would not match it and would ADD the parent as a
  /// second row, and the correction would then only undo that, leaving the
  /// variation on the list while `remove()` reported success.
  Future<WishlistSnapshot> _intend(int productId, {required bool present}) async {
    final known = _latest ?? await refresh();
    if (known.contains(productId) == present) return known;

    final target = known.entryFor(productId)?.mutationId ?? productId;

    var snapshot = await toggle(target);
    if (snapshot.added != null && snapshot.added != present) {
      snapshot = await toggle(target);
    }
    return snapshot;
  }

  /// Empties the list one product at a time.
  ///
  /// There is no bulk-clear route. Removal order is fixed by [refresh] so a
  /// mid-way failure leaves a comprehensible partial state; the failing
  /// [toggle] has already re-read the list, so [latest] is accurate when the
  /// error surfaces.
  ///
  /// Rows whose catalogue product has been deleted cannot be cleared — they
  /// parse to nothing, so there is no id to send, and no id the server would
  /// accept if there were. Check [WishlistSnapshot.serverCount] afterwards if
  /// "is it really empty now" matters.
  Future<WishlistSnapshot> clear() async {
    var snapshot = await refresh();
    for (final entry in List<WishlistEntry>.of(snapshot.entries)) {
      snapshot = await remove(entry.mutationId);
    }
    return snapshot;
  }

  /// `DELETE /ecommerce/wishlist/{id}` — **destructive on failure.**
  ///
  /// Kept only because the route exists and a caller may need its exact
  /// semantics. Guarded by a presence check and, if the call fails anyway,
  /// re-fetched before the error propagates so [latest] is never a guess. The
  /// re-fetch failing is swallowed deliberately — the original failure is the
  /// one worth reporting — but it drops the cache, because a snapshot the
  /// server may have just deleted is worse than no snapshot at all.
  ///
  /// The presence check resolves the line, not just its existence:
  /// `contains(parentId)` is true for a wishlisted *variation*, and sending the
  /// parent id is exactly the "not in wishlist" miss that 404s and wipes.
  Future<WishlistSnapshot> removeViaDelete(int productId) async {
    final id = identifier;
    if (id == null) return _remember(const WishlistSnapshot.empty());

    final known = _latest ?? await refresh();
    final entry = known.entryFor(productId);
    if (entry == null) return known;

    try {
      final res = await _api.delete(
        _listPath(id),
        data: {'product_id': entry.mutationId},
      );
      return _remember(WishlistSnapshot.fromJson(res.data, fallbackId: id));
    } on ApiException {
      await _resync(id);
      rethrow;
    }
  }

  /// Forgets the local identifier. The server-side list is untouched — nothing
  /// deletes it, and anyone holding the id can still read it.
  Future<void> forget() async {
    _latest = null;
    await _prefs.remove(_storageKey);
  }

  WishlistSnapshot _remember(WishlistSnapshot snapshot) {
    _latest = snapshot;
    return snapshot;
  }

  /// Stores the identifier only on the mint, never on later calls.
  ///
  /// The controller does `$identifier = $id ?: Str::uuid()`, so once we have an
  /// id every response just echoes it back. Rebinding on each response would
  /// mean a single odd echo silently repointed the customer at a different
  /// list, losing theirs with no error anywhere.
  Future<void> _persistId(String? id) async {
    if (id == null || id.isEmpty || identifier != null) return;
    await _prefs.setString(_storageKey, id);
  }
}

/// Compare list. Identical contract to the wishlist, different storage key so
/// the two identifiers cannot collide.
class CompareRepository extends WishlistRepository {
  CompareRepository(super.api, super.prefs);

  @override
  String get _createPath => ApiEndpoints.compareCreate;

  @override
  String _listPath(String id) => ApiEndpoints.compare(id);

  @override
  String get _storageKey => 'compare_id';
}

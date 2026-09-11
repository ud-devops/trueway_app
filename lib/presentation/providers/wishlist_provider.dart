import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/product_model.dart';
import '../../data/repositories/wishlist_repository.dart';
import 'core_providers.dart';

/// What the app believes the saved list contains.
///
/// [snapshot] is deliberately nullable and means three different things:
///
///   * non-null — the server described the list and we are rendering its word;
///   * null while [loading] — nothing has come back yet;
///   * null while not loading — **unknown**. A mutation failed and the
///     re-read the repository issued failed too, so the list may have been
///     destroyed server-side (see [WishlistRepository]'s class docs). Rendering
///     the pre-mutation list here would show hearts for items that no longer
///     exist, which is the exact lie this state exists to avoid.
class WishlistState {
  const WishlistState({
    this.snapshot,
    this.loading = false,
    this.error,
    this.pending = const {},
  });

  final WishlistSnapshot? snapshot;
  final bool loading;

  /// The last failure, from a load *or* a mutation. Kept on the state as well
  /// as thrown to the caller: after a failed mutation the list may be stale or
  /// gone, and the screen has to say so — a snackbar that has already faded is
  /// not a state.
  ///
  /// Typed [Object], not `ApiException`. Only the *transport* is guaranteed to
  /// throw `ApiException`; parsing the envelope afterwards, or a failing
  /// `SharedPreferences` write, throws whatever it likes. Narrowing here is what
  /// let those escape the notifier's catch and leave [loading]/[pending] stuck
  /// on forever — a heart frozen as a spinner that refuses every further tap.
  /// `AppErrorView`, `InlineErrorStrip` and `showErrorSnack` all take `Object?`
  /// and route it through `ErrorPresenter`, so nothing downstream needs the
  /// narrower type.
  final Object? error;

  /// Product ids with a mutation in flight. The heart shows a spinner for
  /// these and refuses a second tap: the toggle endpoint flips state, so two
  /// taps racing each other land back where they started.
  final Set<int> pending;

  bool get isKnown => snapshot != null;
  List<WishlistEntry> get entries => snapshot?.entries ?? const [];
  int get count => entries.length;

  /// The saved products, in the order the server listed them.
  List<Product> get products => [for (final e in entries) e.product];

  bool get isEmpty => !loading && error == null && entries.isEmpty;

  /// Rows the server counts but that parsed to nothing — their catalogue
  /// product has been deleted. They cannot be rendered and cannot be removed
  /// (there is no id left to send), so the screen admits they are there rather
  /// than quietly disagreeing with the customer's own count.
  int get unavailableCount {
    final ghosts = (snapshot?.serverCount ?? 0) - count;
    return ghosts > 0 ? ghosts : 0;
  }

  /// True when [productId] is saved. Matches variations against their parent —
  /// see [WishlistSnapshot.contains] — so a card for a variable product lights
  /// up when one of its variations is on the list.
  bool contains(int productId) => snapshot?.contains(productId) ?? false;

  bool isBusy(int productId) => pending.contains(productId);

  WishlistState copyWith({
    WishlistSnapshot? snapshot,
    bool clearSnapshot = false,
    bool? loading,
    Object? error,
    bool clearError = false,
    Set<int>? pending,
  }) =>
      WishlistState(
        snapshot: clearSnapshot ? null : (snapshot ?? this.snapshot),
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        pending: pending ?? this.pending,
      );
}

/// Drives the anonymous wishlist.
///
/// ## Why there is no auth gate
///
/// The wishlist endpoints identify a list purely by an opaque id in the path;
/// the bearer token is never read. A signed-out visitor keeps a real wishlist
/// and it survives login untouched, so the heart on a product card works for
/// everyone. The identifier itself is persisted by [WishlistRepository].
///
/// ## Why nothing here is optimistic
///
/// Every mutation on this API opens with `Cart::restore()`, which *deletes* the
/// stored row, and only re-stores on the way out — so a failure can leave the
/// list empty rather than unchanged (verified live: a DELETE for a product not
/// on the list 404s and wipes everything). The repository re-reads the list on
/// every failure path; this notifier adopts whatever that read produced, up to
/// and including "unknown". Flipping the heart first and keeping it flipped
/// would tell the customer an item is saved on a list the server has just
/// emptied.
class WishlistNotifier extends StateNotifier<WishlistState> {
  WishlistNotifier(this._repo) : super(const WishlistState(loading: true)) {
    load();
  }

  final WishlistRepository _repo;

  /// Reads the list.
  ///
  /// Costs no request until an identifier has been minted — the repository
  /// answers a fresh install with an empty snapshot — so watching this provider
  /// from a product card is free for first-time visitors.
  Future<void> load() async {
    if (!mounted) return;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final snapshot = await _repo.refresh();
      if (!mounted) return;
      state = WishlistState(snapshot: snapshot, pending: state.pending);
    } catch (e) {
      // Catches everything, not just ApiException: the repository parses the
      // envelope after the client has returned, and a malformed payload throws
      // a plain TypeError. Letting that past this catch left `loading` true for
      // the rest of the session — a permanent grid skeleton with no error and
      // no way back.
      if (!mounted) return;
      // `latest` is whatever the repository could still vouch for — null when a
      // read has never succeeded, which is the honest answer: we do not know
      // what is on the list.
      state = WishlistState(
        snapshot: _repo.latest,
        error: e,
        pending: state.pending,
      );
    }
  }

  Future<void> refresh() => load();

  /// Saves [productId] if it is not saved, removes it if it is.
  ///
  /// Returns whether the product is on the list **according to the server's
  /// reply**, not according to the intent — the toggle can disagree if another
  /// device changed the list first, and the caller's confirmation message has to
  /// match what actually happened.
  ///
  /// Rethrows the [ApiException] after reconciling, so the caller can show the
  /// server's own message. The state is correct by the time it throws.
  Future<bool> toggle(int productId) async {
    if (state.isBusy(productId)) return state.contains(productId);

    // Intent is derived once, from the state the customer actually tapped on.
    // The repository turns it into at most two requests and self-corrects from
    // `data.added`, so a stale local view cannot produce a wrong end state.
    final wanted = !state.contains(productId);
    return _mutate(
      productId,
      () => wanted ? _repo.add(productId) : _repo.remove(productId),
    );
  }

  /// Ensures [productId] is off the list. Idempotent — removing something
  /// already absent is a no-op, never a DELETE that could wipe the list.
  Future<bool> remove(int productId) =>
      _mutate(productId, () => _repo.remove(productId));

  Future<bool> _mutate(
    int productId,
    Future<WishlistSnapshot> Function() action,
  ) async {
    state = state.copyWith(
      pending: {...state.pending, productId},
      clearError: true,
    );
    try {
      final snapshot = await action();
      if (!mounted) return snapshot.contains(productId);
      state = WishlistState(snapshot: snapshot, pending: _idle(productId));
      return snapshot.contains(productId);
    } catch (e) {
      // Deliberately unbounded. `pending` drives the heart's spinner and its
      // refusal to accept a second tap; a throw that skipped this clause left
      // the control spinning forever and permanently dead.
      if (!mounted) rethrow;
      // Adopt the repository's re-read rather than the state we started from.
      // It may be null — the list's fate is genuinely unknown — and that has to
      // reach the UI as "unknown", not as the old list.
      state = WishlistState(
        snapshot: _repo.latest,
        error: e,
        pending: _idle(productId),
      );
      rethrow;
    }
  }

  Set<int> _idle(int productId) => {...state.pending}..remove(productId);

  /// Empties the list, one product at a time — there is no bulk-clear route.
  ///
  /// A mid-way failure leaves a real partial list, which the repository has
  /// already re-read, so the state stays truthful either way.
  Future<void> clear() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final snapshot = await _repo.clear();
      if (!mounted) return;
      state = WishlistState(snapshot: snapshot, pending: state.pending);
    } catch (e) {
      // As in [load] and [_mutate]: `loading` must come down for *any* throw,
      // or the screen keeps its blocking overlay for good.
      if (!mounted) rethrow;
      state = WishlistState(
        snapshot: _repo.latest,
        error: e,
        pending: state.pending,
      );
      rethrow;
    }
  }
}

/// Not `autoDispose`: every product card watches this, and dropping it when the
/// last card leaves the tree would re-fetch the list on every navigation.
final wishlistProvider =
    StateNotifierProvider<WishlistNotifier, WishlistState>(
  (ref) => WishlistNotifier(ref.watch(wishlistRepositoryProvider)),
);

/// Saved-item count, for a badge or an account tile.
final wishlistCountProvider =
    Provider<int>((ref) => ref.watch(wishlistProvider.select((s) => s.count)));

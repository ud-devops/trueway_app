import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/errors/api_exception.dart';
import '../../data/models/address.dart';
import '../../data/repositories/address_repository.dart';
import '../../data/repositories/geo_repository.dart';
import '../../data/repositories/pincode_repository.dart';
import 'core_providers.dart';

/// What the app believes the customer's address book contains.
///
/// The book is read eagerly and in full ([AddressRepository.all] walks the
/// pages), so there is no `hasMore`/`loadingMore` pair here — a partial address
/// book is actively harmful, and `per_page` is ignored by the server anyway.
class AddressBookState {
  const AddressBookState({
    this.addresses = const [],
    this.loading = true,
    this.refreshing = false,
    this.error,
    this.pending = const {},
  });

  /// Server order: `orderByDesc('is_default')->latest()`, i.e. the default row
  /// first and the newest after it. Never re-sorted locally — the order the
  /// server chose is the one checkout will preselect from.
  final List<Address> addresses;

  /// A read with nothing on screen behind it. The screen shows skeletons.
  final bool loading;

  /// A read happening *behind* an existing list — pull-to-refresh, or the
  /// re-read that follows every write. The rows stay on screen.
  final bool refreshing;

  /// The last failure from a read. Kept on the state rather than only thrown,
  /// because a failed refresh leaves rows on screen that may now be stale and
  /// the screen has to admit that. Write failures are *not* stored here: they
  /// are rethrown to the caller, which owns the form and the snackbar.
  final ApiException? error;

  /// Address ids with a mutation in flight. Set-default and delete both take a
  /// visible moment (each is a write followed by a full re-read), and a second
  /// tap on the same row would issue a second write against a row the first one
  /// may already have deleted.
  final Set<int> pending;

  bool get isEmpty => !loading && error == null && addresses.isEmpty;

  bool isBusy(int id) => pending.contains(id);

  /// The row the server actually flagged, or null.
  ///
  /// Deliberately does **not** fall back to `addresses.first` the way
  /// [AddressRepository.defaultAddress] does: this is used to decide whether to
  /// paint a "Default" badge, and a book with no default is genuinely reachable
  /// (see the repository's notes on `handleDefaultAddress`). Badging a guess
  /// would tell the customer the server said something it never said.
  Address? get defaultAddress {
    for (final a in addresses) {
      if (a.isDefault) return a;
    }
    return null;
  }

  AddressBookState copyWith({
    List<Address>? addresses,
    bool? loading,
    bool? refreshing,
    ApiException? error,
    bool clearError = false,
    Set<int>? pending,
  }) =>
      AddressBookState(
        addresses: addresses ?? this.addresses,
        loading: loading ?? this.loading,
        refreshing: refreshing ?? this.refreshing,
        error: clearError ? null : (error ?? this.error),
        pending: pending ?? this.pending,
      );
}

/// Reads and mutates the customer address book.
///
/// ## Why every write is followed by a full re-read
///
/// The create/update response shape is unverified — the controller builds an
/// `AddressResource` from an in-memory model, and
/// [AddressRepository.create]/[AddressRepository.update] return **null** rather
/// than throwing when the body is not what the docblock promised. Trusting that
/// body would leave the list showing whatever the app guessed.
///
/// Worse, a write mutates rows it did not name: `handleDefaultAddress` clears
/// `is_default` on every *other* row when a draft carries `is_default: true`,
/// `store()` force-promotes the customer's first address whatever the draft
/// asked for, and `destroy()` promotes the newest survivor when the default is
/// deleted. Patching the one returned row into local state therefore leaves two
/// rows wearing a "Default" badge, or none. Re-reading is the only correct
/// answer, and the book is at most a handful of rows.
class AddressBookNotifier extends StateNotifier<AddressBookState> {
  AddressBookNotifier(this._repo) : super(const AddressBookState()) {
    load();
  }

  final AddressRepository _repo;

  /// Full read. Shows skeletons when there is nothing on screen yet.
  Future<void> load() => _read(background: false);

  /// Re-read behind whatever is currently on screen — pull-to-refresh.
  ///
  /// Always a background read, including when the book is empty: the empty
  /// state is pull-to-refreshable too, and swapping a settled "No saved
  /// addresses" for skeletons on every pull makes the screen flicker between
  /// two answers to the same question.
  Future<void> refresh() => _read(background: true);

  Future<void> _read({required bool background}) async {
    if (!mounted) return;
    state = state.copyWith(
      loading: !background,
      refreshing: background,
      clearError: true,
    );
    try {
      final rows = await _repo.all();
      if (!mounted) return;
      state = state.copyWith(
        addresses: rows,
        loading: false,
        refreshing: false,
        clearError: true,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      // Already logged by ApiClient. The rows we had are kept: a failed refresh
      // must not blank a list the customer is looking at, and the screen pairs
      // them with an inline strip saying the refresh failed.
      state = state.copyWith(loading: false, refreshing: false, error: e);
    }
  }

  /// Creates an address, then re-reads the book.
  ///
  /// Returns whatever the server echoed back, which may legitimately be null —
  /// see [AddressRepository.create]. Callers must not depend on it; the created
  /// row is in [state] by the time this completes.
  ///
  /// Rethrows the [ApiException] — including the *local* validation failure the
  /// repository raises before sending — so the form can map `fieldErrors` back
  /// onto its inputs.
  Future<Address?> create(AddressDraft draft) async {
    final created = await _repo.create(draft);
    await _rereadAfterWrite();
    return created;
  }

  /// Updates an address, then re-reads the book. See [create] for the return
  /// value and the rethrow contract.
  Future<Address?> update(int id, AddressDraft draft) async {
    final saved = await _repo.update(id, draft);
    await _rereadAfterWrite();
    return saved;
  }

  /// Promotes [address] to default.
  ///
  /// This is a full PUT — there is no PATCH and no dedicated route — so a row
  /// stored through the server's lenient POST rules (no email, no city) fails
  /// local validation and throws before any request is sent. That is the honest
  /// outcome: the server would have 422'd identically. The screen turns it into
  /// "complete this address first" rather than showing "Enter an email address"
  /// with no context.
  /// Returns **false** when a mutation was already in flight for this row and
  /// nothing was sent. The caller must not report success for a write that
  /// never happened — an early return that looks identical to a completed one
  /// is how a screen ends up saying "Default address updated." for a request it
  /// silently dropped.
  Future<bool> setDefault(Address address) async {
    if (state.isBusy(address.id)) return false;
    _markPending(address.id);
    try {
      await _repo.setDefault(address);
      await _rereadAfterWrite();
      return true;
    } finally {
      _clearPending(address.id);
    }
  }

  /// Deletes an address.
  ///
  /// Deleting the default silently promotes the newest survivor, which is why
  /// this re-reads rather than removing the row locally.
  ///
  /// `ran` is false when a mutation was already in flight for this row: no
  /// DELETE was sent, the address is still there, and the caller must stay
  /// quiet. `message` is the server's own sentence ("Address deleted
  /// successfully") when it gave one — see [AddressRepository.delete].
  Future<({bool ran, String? message})> delete(int id) async {
    if (state.isBusy(id)) return (ran: false, message: null);
    _markPending(id);
    try {
      final message = await _repo.delete(id);
      await _rereadAfterWrite();
      return (ran: true, message: message);
    } finally {
      _clearPending(id);
    }
  }

  /// The re-read that follows a successful write.
  ///
  /// A failure here is **not** rethrown: the write already landed, and failing
  /// the call would make the form report "couldn't save" for an address the
  /// server has stored. It surfaces as [AddressBookState.error] instead, so the
  /// list says it is showing stale rows.
  Future<void> _rereadAfterWrite() async {
    if (!mounted) return;
    state = state.copyWith(refreshing: true, clearError: true);
    try {
      final rows = await _repo.all();
      if (!mounted) return;
      state = state.copyWith(
        addresses: rows,
        loading: false,
        refreshing: false,
        clearError: true,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      state = state.copyWith(refreshing: false, error: e);
    }
  }

  /// Marks a row busy.
  ///
  /// Deliberately does **not** clear [AddressBookState.error]. That error is
  /// the record of a failed *read* — the reason the screen is showing a
  /// stale-data strip over rows that may no longer match the server. Wiping it
  /// here removed the strip the instant the customer tapped Delete or Set as
  /// default, and if the write then failed nothing ever put it back: the list
  /// went on showing rows it had already admitted might be wrong, silently.
  /// The strip is cleared by [_rereadAfterWrite], i.e. only once a read has
  /// actually succeeded.
  void _markPending(int id) {
    if (!mounted) return;
    state = state.copyWith(pending: {...state.pending, id});
  }

  void _clearPending(int id) {
    if (!mounted) return;
    state = state.copyWith(pending: {...state.pending}..remove(id));
  }
}

/// The state and city lists that back the address form's pickers.
///
/// Deliberately **not** autoDispose: the whole point is that the cache outlives
/// the screen, so reopening the form answers from memory rather than refetching
/// 36 states and 306 cities.
///
/// Override with `GeoRepository.offline()` in a widget test to keep the lookup
/// entirely off the network; the pickers then report that they could not load,
/// which is the same thing a failed lookup does.
final geoRepositoryProvider = Provider<GeoRepository>((ref) {
  // The disk copy is an optimisation, not a dependency: it saves one 1.1 KB
  // request on a cold start. `sharedPreferencesProvider` throws until main()
  // overrides it, and a test that only wants the address book should not have
  // to know that — so a missing store degrades to a memory-only cache rather
  // than taking the whole screen down with it.
  SharedPreferences? prefs;
  try {
    prefs = ref.watch(sharedPreferencesProvider);
  } catch (_) {
    prefs = null;
  }
  return GeoRepository(client: ref.watch(apiClientProvider), prefs: prefs);
});

/// PIN code -> state, district, candidate city names.
///
/// Declared here rather than in `core_providers.dart` because it is **not**
/// built on [ApiClient]: it calls India Post's public service, on a different
/// host, and must never be handed the customer's bearer token or the store's
/// API key. See [PincodeRepository] for why the backend cannot answer this.
///
/// Not autoDispose, so the answers survive the form being closed and reopened.
///
/// Override with `PincodeRepository.offline()` in a widget test to keep the
/// lookup off the network; the form then simply does not autofill, which is
/// what a failed lookup also does.
final pincodeRepositoryProvider =
    Provider<PincodeRepository>((ref) => PincodeRepository());

/// The customer's address book.
///
/// autoDispose so that signing out, or switching accounts, cannot leave one
/// customer's addresses on screen for the next: the notifier is rebuilt — and
/// re-reads — the next time a screen asks for it. Screens that push a child
/// route which writes to the book (the form) keep it alive by watching
/// `addressBookProvider.notifier`, so the post-write re-read cannot be
/// cancelled halfway by a disposal.
///
/// The geo resolver is *not* autoDispose, so a rebuild here costs no extra
/// lookups: the second read of the book resolves entirely from its cache.
final addressBookProvider =
    StateNotifierProvider.autoDispose<AddressBookNotifier, AddressBookState>(
  (ref) => AddressBookNotifier(ref.watch(addressRepositoryProvider)),
);

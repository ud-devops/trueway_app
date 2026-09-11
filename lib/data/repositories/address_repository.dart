import '../../core/errors/api_exception.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_response.dart';
import '../models/address.dart';

/// The customer address book. Every route here needs a bearer token; a missing
/// or revoked one surfaces as an ApiException with [ApiErrorKind.unauthorized]
/// and ApiClient signs the user out.
class AddressRepository {
  AddressRepository(this._api);

  final ApiClient _api;

  /// Server page size. `paginate(10)` is hardcoded in AddressController and
  /// `per_page` is silently ignored — verified live: `?per_page=2` still
  /// returned 6 rows with `meta.per_page: 10`. Do not add a perPage argument;
  /// it would be a lie.
  static const int pageSize = 10;

  /// Safety valve for [all]. 20 pages is 200 addresses — far past anything real,
  /// but bounded, so a server that ever stopped advancing `last_page` cannot
  /// spin this forever.
  static const int _maxPages = 20;

  /// One page, newest first with the default address pinned to the top
  /// (`orderByDesc('is_default')->latest()`).
  ///
  /// The envelope is the authed hybrid: `{data, links, meta, error, message}`.
  /// [PaginatedResponse] reads only `data`/`links`/`meta`, and the `error:true`
  /// case never reaches here — ApiClient has already thrown.
  Future<PaginatedResponse<Address>> page({int page = 1}) async {
    final res = await _api.get(
      ApiEndpoints.addresses,
      query: {'page': page},
    );
    final body = res.data;
    if (body is Map<String, dynamic>) {
      final data = body['data'];
      // PaginatedResponse.fromJson does `json['data'] as List?`, which is a
      // TypeError the moment `data` is anything else. This backend flips
      // collection fields between array and object shapes elsewhere
      // (`cart_items` is a map when populated and `[]` when empty), so the cast
      // is only made after the shape has been checked.
      if (data == null || data is List) {
        return PaginatedResponse.fromJson(body, Address.fromJson);
      }
      if (data is Map && data['id'] != null) {
        final one = Address.fromJson(Map<String, dynamic>.from(data));
        return PaginatedResponse(items: [one], meta: PaginationMeta.single(1));
      }
      return PaginatedResponse(items: const [], meta: PaginationMeta.single(0));
    }
    final items = unwrapList(body, Address.fromJson);
    return PaginatedResponse(
      items: items,
      meta: PaginationMeta.single(items.length),
    );
  }

  /// Every address, pages walked eagerly.
  ///
  /// The address book is the one list where partial data is actively harmful —
  /// a checkout picker that stops at 10 silently hides the address the customer
  /// wants — and nobody has 200 of them, so paging lazily buys nothing.
  ///
  /// Two things this deliberately does NOT do:
  ///
  ///   * It does not ask the *server* which page comes next. Following
  ///     `meta.current_page + 1` means a server that echoes `current_page: 1`
  ///     for every request is asked for page 2 forever — 20 identical
  ///     responses, 20 duplicated rows in the returned list, and no error.
  ///     A local counter cannot get stuck.
  ///   * It does not trust the pages to be disjoint. The server orders by
  ///     `orderByDesc('is_default')->latest()`, and `latest()` is `created_at`
  ///     only — rows sharing a timestamp (an import, or two saves in the same
  ///     second) have no total order, so consecutive LIMIT/OFFSET queries can
  ///     return the same row twice and skip another. Deduplicating on `id` is
  ///     the cheap half of that fix; the skipped row is unrecoverable from here.
  Future<List<Address>> all() async {
    final items = <Address>[];
    final seen = <int>{};
    for (var pageNumber = 1; pageNumber <= _maxPages; pageNumber++) {
      final res = await page(page: pageNumber);
      var added = 0;
      for (final address in res.items) {
        if (seen.add(address.id)) {
          items.add(address);
          added++;
        }
      }
      // A page that repeats what we already have means the server is not
      // advancing; continuing would just burn requests.
      if (!res.hasMore || res.items.isEmpty || added == 0) break;
    }
    return items;
  }

  /// Fetch one address by id.
  ///
  /// There is deliberately no HTTP call for a single address: `GET
  /// /ecommerce/addresses/{id}` is not registered in the routes file (only
  /// index/store/update/destroy are), and the controller's `show()` method is
  /// unreachable. So this reads the collection and filters. Returns null when
  /// the id is not in the customer's book.
  Future<Address?> find(int id) async {
    final list = await all();
    for (final a in list) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// The address to preselect at checkout — the flagged row, or a guess.
  ///
  /// ⚠ A book with **no** default is genuinely reachable, so the fallback is
  /// not theoretical. The server forces the first address to be default and
  /// promotes the newest survivor when the default is deleted, but it never
  /// re-promotes on *update*: `AddressController::update` writes whatever
  /// `is_default` the request carried and `handleDefaultAddress` only ever
  /// clears the other rows. One PUT with `is_default: false` on the default row
  /// leaves the customer with none. (That is why [AddressDraft.isDefault]
  /// defaults to null/"don't touch".)
  ///
  /// When nothing is flagged this returns the first row, which — given
  /// `orderByDesc('is_default')->latest()` — is simply the newest address. That
  /// is a guess, and a checkout screen that shows it as the customer's chosen
  /// default is showing something the server never said. Use
  /// [isExplicitDefault] to tell the two apart before labelling it.
  Future<Address?> defaultAddress() async {
    final list = await all();
    if (list.isEmpty) return null;
    for (final a in list) {
      if (a.isDefault) return a;
    }
    return list.first;
  }

  /// Whether [address] is flagged by the server rather than picked by
  /// [defaultAddress]'s fallback.
  bool isExplicitDefault(Address? address) => address?.isDefault ?? false;

  /// Create an address.
  ///
  /// The draft is validated locally against the union of the POST and PUT rules
  /// (see [AddressDraft.validationErrors]) — POST alone would accept a row with
  /// no email or city that no later PUT could ever save.
  Future<Address?> create(AddressDraft draft) async {
    _assertValid(draft);
    final res = await _api.post(ApiEndpoints.addresses, data: draft.toJson());
    return _parseWriteResult(res.data);
  }

  /// Update an address.
  ///
  /// ⚠ Only the returned row is trustworthy afterwards; **re-read the list**.
  /// A draft carrying `is_default: true` makes the server clear the flag on
  /// every *other* row (`handleDefaultAddress`), so any Address held elsewhere
  /// in memory now has a stale `isDefault` and two rows will render a "Default"
  /// badge. The same applies to [create] — `store()` forces `is_default` true
  /// when it is the customer's first address, whatever the draft asked for.
  ///
  /// Note PUT is *not* a full replace despite requiring seven fields: only the
  /// nine validated keys are written, so `landmark`, `district` and
  /// `other_city` — columns the API never exposes but `full_address` does
  /// render — survive untouched.
  Future<Address?> update(int id, AddressDraft draft) async {
    _assertValid(draft);
    final res = await _api.put(ApiEndpoints.address(id), data: draft.toJson());
    return _parseWriteResult(res.data);
  }

  /// Make [address] the default.
  ///
  /// The whole row is echoed back because PUT requires seven fields — there is
  /// no PATCH and no dedicated set-default route. If the stored row predates
  /// this app it may fail local validation (an address saved through the
  /// lenient POST rules can have no email); that surfaces as a validation
  /// ApiException naming the missing field, which is the honest outcome — the
  /// server would have 422'd identically.
  ///
  /// Every other address is demoted server-side, so re-read the list rather
  /// than patching the returned row into local state.
  Future<Address?> setDefault(Address address) =>
      update(address.id, address.toDraft().copyWith(isDefault: true));

  /// Delete an address.
  ///
  /// Returns the server's message ("Address deleted successfully"). Deleting
  /// the default silently promotes the newest remaining address, so callers
  /// must re-read the list rather than patching local state.
  Future<String?> delete(int id) async {
    final res = await _api.delete(ApiEndpoints.address(id));
    final body = res.data;
    if (body is Map && body['message'] is String) {
      return body['message'] as String;
    }
    return null;
  }

  void _assertValid(AddressDraft draft) {
    final errors = draft.validationErrors();
    if (errors.isEmpty) return;
    throw ApiException(
      errors.values.first,
      kind: ApiErrorKind.validation,
      fieldErrors: {for (final e in errors.entries) e.key: [e.value]},
      developerDetail: 'rejected before sending: ${errors.keys.join(', ')}',
    );
  }

  /// Parse the body of a create/update.
  ///
  /// ⚠ UNVERIFIED. Creating addresses was out of scope for probing, so the
  /// only evidence for this shape is the controller
  /// (`httpResponse()->setData(new AddressResource($address))`, i.e.
  /// `{error:false, data:{...}, message:null}`) and its docblock. It is parsed
  /// defensively and returns **null** rather than throwing if the body is not
  /// the expected object — the write itself already succeeded at that point, so
  /// failing the call over an unrecognised body would be wrong. Callers should
  /// treat a null return as "saved, now re-read the list".
  ///
  /// One known divergence from the read shape: the controller assigns a PHP
  /// bool to `is_default` before serializing, so this body may carry
  /// `true`/`false` where the list route sends 1/0. [Address.fromJson] handles
  /// both.
  Address? _parseWriteResult(dynamic body) {
    final data = (body is Map && body.containsKey('data')) ? body['data'] : body;
    if (data is! Map) return null;
    final map = Map<String, dynamic>.from(data);
    if (map['id'] == null) return null;
    return Address.fromJson(map);
  }
}

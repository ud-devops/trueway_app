import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/validation/address_rules.dart';
import '../../data/models/address.dart';
import 'checkout_provider.dart';
import 'core_providers.dart';
import 'shipping_provider.dart';

/// Where the customer wants this order shipped, app-wide.
///
/// ## Why this is global rather than a checkout field
///
/// Shipping is quoted per destination by Shiprocket, so nothing can show a real
/// total until a destination is known. Asking for it only at checkout means the
/// cart has to say "shipping calculated later", and the customer discovers the
/// real amount at the last step — which is the single biggest driver of cart
/// abandonment in retail.
///
/// ## Why it is an *address*, not a typed pincode
///
/// It used to be a bare 6-digit pincode the customer typed into the cart's
/// sheet. That field has been removed: it sat directly above the customer's own
/// saved addresses, each of which already carries a pincode, so the two controls
/// answered the same question and could disagree — a customer could type 382415,
/// then check out to an address in 474010, and the cart's "To pay" was a figure
/// nobody would be charged.
///
/// So the selection *is* a saved address. The cart and checkout choose from the
/// same book through the same sheet, this is what both of them store, and the
/// pincode is read off the chosen row rather than typed a second time.
///
/// The cost of that is real and deliberate: `GET /ecommerce/addresses` is
/// bearer-only, so a **signed-out** customer has no book to choose from and
/// therefore no shipping quote on the cart. The cart still works — it shows a
/// subtotal and never invents a charge — and the card offers signing in.
@immutable
class DeliveryLocation {
  const DeliveryLocation({
    required this.addressId,
    required this.pinCode,
    this.name = '',
    this.line = '',
  });

  /// The saved address row this is. The id checkout starts from, so a customer
  /// who picked address B on the cart does not land on checkout addressed to
  /// their default.
  final int addressId;

  /// Six digits. Read off the address and validated before it is ever stored,
  /// so nothing downstream has to re-check it before spending a quote.
  final String pinCode;

  /// The row's label, e.g. "Gwalior home". Cached alongside the id so the card
  /// can name the destination on a cold start, before the address book read
  /// that confirms it has come back.
  final String name;

  /// The row's resolved one-line address — [Address.displayAddress], which is
  /// the only string that resolves the numeric state/city ids some rows store.
  final String line;

  /// What names the destination on a card. Falls back to the pincode for a row
  /// saved without a name.
  String get display => name.trim().isEmpty ? pinCode : name.trim();

  @override
  bool operator ==(Object other) =>
      other is DeliveryLocation &&
      other.addressId == addressId &&
      other.pinCode == pinCode &&
      other.name == name &&
      other.line == line;

  @override
  int get hashCode => Object.hash(addressId, pinCode, name, line);
}

class DeliveryLocationNotifier extends StateNotifier<DeliveryLocation?> {
  DeliveryLocationNotifier(this._prefs) : super(_read(_prefs)) {
    _dropLegacyPin();
  }

  final SharedPreferences _prefs;

  static const _idKey = 'delivery_address_id';
  static const _pinKey = 'delivery_address_pin';
  static const _nameKey = 'delivery_address_name';
  static const _lineKey = 'delivery_address_line';

  /// The keys the typed-pincode version of this feature wrote. Nothing reads
  /// them any more — an install upgrading from that build starts with no
  /// selection and adopts the default address instead — so they are removed
  /// rather than left behind as state nobody owns.
  static const _legacyKeys = ['delivery_pin_code', 'delivery_label'];

  /// Six digits, and Indian pincodes never start with 0.
  ///
  /// [CheckoutAddressRules.zipPattern] rather than a local copy: a stored
  /// selection this accepts must be one the address picker and
  /// [ShippingQuery.hasValidPinCode] also accept, or the app restores a
  /// destination it then refuses to quote.
  static bool isValidPin(String value) =>
      CheckoutAddressRules.zipPattern.hasMatch(value.trim());

  static DeliveryLocation? _read(SharedPreferences prefs) {
    final id = prefs.getInt(_idKey);
    final pin = prefs.getString(_pinKey);
    // Both halves or nothing: an id with no usable pincode cannot be quoted,
    // and a pincode with no id is the old typed-pin state.
    if (id == null || pin == null || !isValidPin(pin)) return null;
    return DeliveryLocation(
      addressId: id,
      pinCode: pin,
      name: prefs.getString(_nameKey) ?? '',
      line: prefs.getString(_lineKey) ?? '',
    );
  }

  void _dropLegacyPin() {
    for (final key in _legacyKeys) {
      if (_prefs.containsKey(key)) _prefs.remove(key);
    }
  }

  /// Ships this order to [address], and returns whether it could.
  ///
  /// **False** means the row has no usable pincode — the server's `zip_code`
  /// rule is only `nullable|max:20`, so a PIN-less address is a real thing in
  /// the book — and the selection is left untouched. The caller has to say so;
  /// silently accepting it would leave the cart addressed to a row nothing can
  /// be quoted for.
  ///
  /// Deliberately does not check serviceability: that is a network call, and the
  /// customer should see their choice land immediately with the quote resolving
  /// after. The undeliverable case is presented by whatever renders the quote.
  Future<bool> select(Address address) async {
    final pin = address.zipCode.trim();
    if (!isValidPin(pin)) return false;
    await _store(
      DeliveryLocation(
        addressId: address.id,
        pinCode: pin,
        name: address.name.trim(),
        line: address.displayAddress,
      ),
    );
    return true;
  }

  /// Reconciles the stored selection against a freshly-read address book.
  ///
  /// Three things this fixes, all of them reachable:
  ///
  ///   * the chosen row was **edited** elsewhere (the web, the profile screen)
  ///     and now has a different pincode — the cart would go on quoting the old
  ///     one, because the id it stores did not change;
  ///   * the chosen row was **deleted** — the cart would keep naming an address
  ///     that no longer exists while checkout silently fell back to the default,
  ///     so the two screens would price two different destinations;
  ///   * **nothing is chosen yet** — see [_adoptDefault].
  Future<void> syncWith(List<Address> rows) async {
    final current = state;
    if (current != null) {
      for (final row in rows) {
        if (row.id != current.addressId) continue;
        // Same row, possibly edited: re-store it. `_store` is a no-op when
        // nothing actually changed, so this cannot loop a rebuild.
        if (await select(row)) return;
        break; // the edit removed its PIN code.
      }
      await clear();
    }
    await _adoptDefault(rows);
  }

  /// Opens the cart on the customer's own default address.
  ///
  /// The previous version of this file refused to default at all, because what
  /// it would have defaulted *to* was a hardcoded "Ahmedabad · 382415" that was
  /// wrong for every customer outside Ahmedabad. This is a different thing: it
  /// adopts the row the **server** flagged, which is exactly the row checkout's
  /// address picker preselects. Not adopting it is what would create a
  /// disagreement — a cart quoting nothing while checkout quotes the default.
  ///
  /// Falls through to the first row with a usable pincode when the book has no
  /// flagged default, which is reachable: the server never re-promotes on
  /// update.
  Future<void> _adoptDefault(List<Address> rows) async {
    for (final row in rows) {
      if (row.isDefault && await select(row)) return;
    }
    for (final row in rows) {
      if (await select(row)) return;
    }
  }

  Future<void> _store(DeliveryLocation next) async {
    if (state == next) return;
    state = next;
    await _prefs.setInt(_idKey, next.addressId);
    await _prefs.setString(_pinKey, next.pinCode);
    await _prefs.setString(_nameKey, next.name);
    await _prefs.setString(_lineKey, next.line);
  }

  Future<void> clear() async {
    if (state == null) return;
    state = null;
    await _prefs.remove(_idKey);
    await _prefs.remove(_pinKey);
    await _prefs.remove(_nameKey);
    await _prefs.remove(_lineKey);
  }
}

/// Null until the customer has an address this order can ship to.
///
/// Persisted, so the choice survives a restart, and reconciled against the
/// address book on every read — see [DeliveryLocationNotifier.syncWith].
final deliveryLocationProvider =
    StateNotifierProvider<DeliveryLocationNotifier, DeliveryLocation?>(
  (ref) => DeliveryLocationNotifier(ref.watch(sharedPreferencesProvider)),
);

/// The saved address id the whole app is shipping to, or null.
///
/// This is the handle checkout seeds its picker from: the cart and checkout must
/// open on the *same* row, and without it a customer who picked address B on the
/// cart landed on a checkout addressed to their default.
final selectedDeliveryAddressIdProvider =
    Provider<int?>((ref) => ref.watch(deliveryLocationProvider)?.addressId);

/// The courier charge for the current basket at the current delivery location,
/// or null when it is not yet knowable.
///
/// Null covers four genuinely different situations, and the cart must not print
/// a number in any of them:
///   * signed out, so there is no address book and no destination
///   * no address chosen yet
///   * the basket has not been weighed yet
///   * the quote is still in flight, failed, or came back undeliverable
///
/// Feed it into `checkoutSummaryProvider` to get a bill whose shipping line and
/// total are the server's, never this app's.
final cartDeliveryChargeProvider = Provider.autoDispose<double?>((ref) {
  final location = ref.watch(deliveryLocationProvider);
  if (location == null) return null;

  final parcel = ref.watch(checkoutParcelProvider).valueOrNull;
  if (parcel == null) return null;

  // `shippingChargeProvider` is the customer's own pick for exactly this
  // parcel-and-pincode, or null. There is no fallback courier: `CourierOption
  // .best` and `ShippingRates.best` are gone, and nothing is preselected here or
  // anywhere else. So an unanswered cart returns null and the cart bill asks for
  // a delivery option — it does not quote the fastest, the cheapest or the first
  // row.
  //
  // That is what keeps the cart and checkout on one figure: both read this same
  // provider, so a courier pinned on checkout shows here and an unpinned cart
  // shows nothing on either screen, rather than the two printing different "To
  // pay" totals for one order.
  //
  // Null also survives an undeliverable pincode rather than collapsing to 0 —
  // free shipping and no shipping are not the same thing.
  return ref.watch(shippingChargeProvider(parcel.toQuery(location.pinCode)));
});

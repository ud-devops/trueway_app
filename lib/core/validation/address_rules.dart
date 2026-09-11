/// The WEB checkout's address rules, enforced client-side.
///
/// ## Why this file exists
///
/// `POST /api/v1/ecommerce/checkout/cart/{cart_id}` validates the shipping
/// address far more loosely than the web checkout does, and then **never
/// re-validates it**: because the controller sets `created_order_id` before
/// calling `checkAndCreateOrderAddress`, `OrderHelper::createOrderAddress`
/// takes its `firstOrNew -> fill -> save` branch and returns before it ever
/// builds `getCustomerAddressValidationRules()`. Whatever fits the lenient
/// `CheckoutRequest` rules is persisted verbatim.
///
/// The gap, rule by rule (mobile API -> web checkout):
///
/// | field      | mobile API                | web checkout        |
/// |------------|---------------------------|---------------------|
/// | `name`     | `required_with`, `max:255`| min 3, max 120      |
/// | `address`  | `required_with`, `max:500`| max 120             |
/// | `city`     | `required_with`, `max:120`| required, max 120   |
/// | `state`    | **`nullable`**, `max:120` | **REQUIRED**        |
/// | `zip_code` | **`nullable`**, `max:20`  | **REQUIRED**, a PIN |
/// | `phone`    | `nullable`, `max:20`      | `^[6-9][0-9]{9}$`   |
/// | `email`    | `nullable`, `max:255`     | valid, 6-60         |
/// | `country`  | `required_with`, `max:120`| required, max 120   |
///
/// Every one of those differences produces an order that cannot be dispatched:
/// a missing `state` stops shipping-rule matching, a missing or malformed
/// `zip_code` stops Shiprocket serviceability (and yields a zero shipping
/// quote on an order that costs real money to ship), a missing phone means the
/// courier cannot call, and a 500-character street line overflows the label.
///
/// So the app is the only gate. These rules are deliberately **stricter than
/// the endpoint they guard**, which can never cause a 422 — it only refuses an
/// order the shop could not fulfil anyway.
///
/// ## Contract
///
/// Pure Dart. No Flutter, no models, no providers, no imports at all — so it is
/// unit-testable on its own and safe to import from a repository, a widget, a
/// notifier or an isolate. Every entry point returns **per-field messages keyed
/// by the server's own field names** (`zip_code`, not `zipCode`), so a caller
/// can merge them straight into an `ApiException.fieldErrors` bag without
/// translating.
///
/// Keep this API additive. The checkout repository imports it.
library;

/// The server's field names, as they appear inside the checkout body's
/// `address` object and in a 422's `errors` bag (minus the `address.` prefix).
///
/// Use these rather than string literals so a rename is a compile error.
abstract final class AddressField {
  static const String name = 'name';
  static const String phone = 'phone';
  static const String email = 'email';
  static const String address = 'address';
  static const String city = 'city';
  static const String state = 'state';
  static const String zipCode = 'zip_code';
  static const String country = 'country';

  /// Optional address parts. These carry **no checkout rule** — the server's
  /// only constraint is `max:120` each, and `AddressDraft` enforces that — but
  /// the names are declared here so a form keying its inputs and its server
  /// error bag by [AddressField] does not have to fall back to string
  /// literals for three of them.
  ///
  /// Deliberately absent from [all], which is the set [validate] governs.
  static const String landmark = 'landmark';
  static const String district = 'district';
  static const String otherCity = 'other_city';

  /// Every field these rules govern, in the order a form presents them.
  static const List<String> all = [
    name,
    phone,
    email,
    address,
    city,
    state,
    zipCode,
    country,
  ];
}

/// The rules themselves.
///
/// Two ways in:
///
/// * one field at a time — [nameError], [phoneError], … — for a `TextFormField`
///   validator that has to paint one message under one box;
/// * the whole address at once — [validate] / [validateJson] — for a submit
///   gate, a repository pre-flight, or a list row deciding whether it can be
///   delivered to.
///
/// ```dart
/// // Live validation on one field.
/// validator: (_) => CheckoutAddressRules.nameError(_name.text),
///
/// // Submit gate / repository pre-flight.
/// final problems = CheckoutAddressRules.validateJson(address.toJson());
/// if (problems.isNotEmpty) { /* do not POST */ }
/// ```
abstract final class CheckoutAddressRules {
  // ---- limits -------------------------------------------------------------

  /// `name` is `min:3` on the web checkout. The mobile API allows 1.
  static const int nameMin = 3;
  static const int nameMax = 120;

  /// **120, not 500.** The mobile API's `max:500` is the single most misleading
  /// number in the contract: a street line the API accepts can be rejected by
  /// every downstream label printer.
  static const int addressMax = 120;

  static const int cityMax = 120;
  static const int stateMax = 120;
  static const int countryMax = 120;

  /// The one country this store ships to.
  ///
  /// The app stopped *collecting* a country when the address endpoints stopped
  /// accepting one — the server fills `country_id` itself from its
  /// single-country setting. But the checkout body still carries the field, and
  /// these rules still describe that body, so callers that hold a write shape
  /// with no country supply this rather than each inventing its own literal.
  static const String shipsToCountry = 'India';

  /// The same country as the **location tables** know it.
  ///
  /// `GET /ecommerce/countries` returns `{"name": "India", "code": "IN"}` and
  /// the states route accepts `IN` or the numeric `1` — the name `India`
  /// matches neither (`?country_id=India` answers with the placeholder row and
  /// nothing else).
  ///
  /// That distinction is invisible until something validates a country, and
  /// exactly one thing does: the **billing** address. See
  /// `CheckoutAddress.toJson`.
  static const String shipsToCountryCode = 'IN';

  /// `email` is `min:6|max:60` on the web checkout (the mobile API says 255).
  static const int emailMin = 6;
  static const int emailMax = 60;

  /// `phone` is exactly ten digits — not "up to", not "at least".
  static const int phoneDigits = 10;

  /// An Indian PIN code is exactly six digits and never starts with 0.
  static const int zipDigits = 6;

  // ---- patterns -----------------------------------------------------------

  /// `^[6-9][0-9]{9}$` — the web checkout's rule verbatim. A landline (1-5) and
  /// a `+91`-prefixed number both fail, which is intended: this is the number
  /// the courier dials.
  ///
  /// **The only copy in the app.** `validators.dart`'s `isValidMobile` reads
  /// this constant rather than restating the pattern, and `AddressDraft`'s
  /// phone rule goes through `isValidMobile`. Do not paste the literal
  /// anywhere; a second copy is a second thing to forget to change.
  static final RegExp phonePattern = RegExp(r'^[6-9][0-9]{9}$');

  /// `^[1-9][0-9]{5}$`. The leading-zero exclusion is load-bearing rather than
  /// cosmetic: Shiprocket serviceability is keyed on the PIN, and "012345" is
  /// not a PIN, so the quote comes back empty and the order ships for ₹0.
  ///
  /// **The only copy in the app.** It had drifted into four files — here,
  /// `validators.dart`'s `isValidPincode`, `ShippingQuery.hasValidPinCode` and
  /// `DeliveryLocationNotifier.isValidPin`. All three of those now read this
  /// constant. That matters because these are not independent checks: the
  /// picker decides an address is deliverable, `ShippingQuery` decides the
  /// pincode is worth quoting, and `DeliveryLocationNotifier` decides a stored
  /// selection is still usable — one of them disagreeing is a checkout that
  /// asks for rates it will not accept, or accepts an address it cannot rate.
  static final RegExp zipPattern = RegExp(r'^[1-9][0-9]{5}$');

  /// Pragmatic shape check: something, `@`, a host with at least one dot, no
  /// whitespace. Deliberately permissive about the local part — the length
  /// bounds are the rule that actually bites, and rejecting an address the
  /// backend would accept is worse than letting one through to a 422.
  static final RegExp emailPattern =
      RegExp(r'^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$');

  /// What to show wherever an address is *chosen* for delivery and fails these
  /// rules. One sentence, one place, so the sheet, the picker and the cart card
  /// cannot describe the same row three different ways.
  static const String undeliverableMessage =
      'Cannot be delivered to - please complete this address';

  // ---- per-field ----------------------------------------------------------

  /// Required, 3-120 characters. Returns null when the value passes.
  static String? nameError(String? value) {
    final v = _trim(value);
    if (v.isEmpty) return 'Enter a name';
    if (v.length < nameMin) {
      return 'Name is too short (at least $nameMin characters)';
    }
    if (v.length > nameMax) return 'Name is too long (max $nameMax characters)';
    return null;
  }

  /// Required, exactly ten digits matching `^[6-9][0-9]{9}$`.
  static String? phoneError(String? value) {
    final v = _trim(value);
    if (v.isEmpty) return 'Enter a mobile number';
    if (!phonePattern.hasMatch(v)) {
      return 'Enter a 10-digit Indian mobile number starting 6-9';
    }
    return null;
  }

  /// **Optional.** 6-60 characters and email-shaped *when present*.
  ///
  /// This used to be required, on the claim that "checkout refuses an address
  /// with no email". That claim was wrong, and it had been repeated through
  /// this file, `AddressDraft`, the form and the contract doc without anyone
  /// probing it. The backend team checked the source and the live database:
  ///
  ///  * `CheckoutRequest` marks `address.email` / `shipping_address.email`
  ///    `nullable`, and `EcommerceHelper`'s address rules are
  ///    `['email','nullable','max:60','min:6']` — an email-less address passes
  ///    the live validator;
  ///  * `email` is only required at *registration* when
  ///    `ecommerce_login_option == 'phone'`. This store runs `email_or_phone`,
  ///    so every one of its 26 customers has one;
  ///  * order mail uses `$order->user->email ?: $order->address->email` — the
  ///    **account** first, the address only as a fallback, inside a
  ///    try/catch — so a row without one is not unusable.
  ///
  /// The app no longer collects an address email at all (order mail goes to the
  /// account), so the only job left here is to reject a malformed one if some
  /// other path ever supplies it.
  static String? emailError(String? value) {
    final v = _trim(value);
    if (v.isEmpty) return null;
    if (v.length < emailMin) {
      return 'Email is too short (at least $emailMin characters)';
    }
    if (v.length > emailMax) {
      return 'Email is too long (max $emailMax characters)';
    }
    if (!emailPattern.hasMatch(v)) return 'Enter a valid email address';
    return null;
  }

  /// Required, max **120** — the web cap, not the API's 500.
  static String? addressError(String? value) {
    final v = _trim(value);
    if (v.isEmpty) return 'Enter the street address';
    if (v.length > addressMax) {
      return 'Address is too long (max $addressMax characters)';
    }
    return null;
  }

  /// Required, max 120.
  static String? cityError(String? value) {
    final v = _trim(value);
    if (v.isEmpty) return 'Enter the city';
    if (v.length > cityMax) return 'City is too long (max $cityMax characters)';
    return null;
  }

  /// Required, max 120.
  ///
  /// The mobile API says `nullable`; it drives shipping-rule matching, so a
  /// blank one is an order nobody can rate.
  static String? stateError(String? value) {
    final v = _trim(value);
    if (v.isEmpty) return 'Enter the state';
    if (v.length > stateMax) {
      return 'State is too long (max $stateMax characters)';
    }
    return null;
  }

  /// Required, six digits, never leading zero.
  ///
  /// The mobile API says `nullable|max:20`, which is exactly why PIN-less rows
  /// already exist in real address books.
  static String? zipCodeError(String? value) {
    final v = _trim(value);
    if (v.isEmpty) return 'Enter the $zipDigits-digit PIN code';
    if (v.startsWith('0')) return 'A PIN code cannot start with 0';
    if (!zipPattern.hasMatch(v)) {
      return 'Enter a valid $zipDigits-digit PIN code';
    }
    return null;
  }

  /// Required, max 120.
  static String? countryError(String? value) {
    final v = _trim(value);
    if (v.isEmpty) return 'Enter the country';
    if (v.length > countryMax) {
      return 'Country is too long (max $countryMax characters)';
    }
    return null;
  }

  // ---- whole address ------------------------------------------------------

  /// Every violation, keyed by [AddressField]. Empty means the address is
  /// safe to check out with.
  ///
  /// Named parameters rather than a positional record so adding a field later
  /// cannot silently reorder an existing caller's arguments.
  static Map<String, String> validate({
    String? name,
    String? phone,
    String? email,
    String? address,
    String? city,
    String? state,
    String? zipCode,
    String? country,
  }) {
    final errors = <String, String>{};
    void put(String field, String? message) {
      if (message != null) errors[field] = message;
    }

    put(AddressField.name, nameError(name));
    put(AddressField.phone, phoneError(phone));
    put(AddressField.email, emailError(email));
    put(AddressField.address, addressError(address));
    put(AddressField.city, cityError(city));
    put(AddressField.state, stateError(state));
    put(AddressField.zipCode, zipCodeError(zipCode));
    put(AddressField.country, countryError(country));
    return errors;
  }

  /// [validate], reading the wire shape — the same map the checkout body's
  /// `address` object uses, and the same one `Address.toJson()` and
  /// `AddressDraft.toJson()` produce.
  ///
  /// Extra keys (`id`, `is_default`, `full_address`, `district`, `landmark`)
  /// are ignored, and a null map is reported as every field missing rather than
  /// as "fine" — "no address at all" must never read as valid.
  static Map<String, String> validateJson(Map<String, dynamic>? json) {
    final j = json ?? const <String, dynamic>{};
    return validate(
      name: _read(j, AddressField.name),
      phone: _read(j, AddressField.phone),
      email: _read(j, AddressField.email),
      address: _read(j, AddressField.address),
      city: _read(j, AddressField.city),
      state: _read(j, AddressField.state),
      zipCode: _read(j, AddressField.zipCode),
      country: _read(j, AddressField.country),
    );
  }

  /// True when nothing is wrong. Sugar over [validate].
  static bool isValid({
    String? name,
    String? phone,
    String? email,
    String? address,
    String? city,
    String? state,
    String? zipCode,
    String? country,
  }) =>
      validate(
        name: name,
        phone: phone,
        email: email,
        address: address,
        city: city,
        state: state,
        zipCode: zipCode,
        country: country,
      ).isEmpty;

  /// True when nothing is wrong with the wire shape. Sugar over [validateJson].
  static bool isValidJson(Map<String, dynamic>? json) =>
      validateJson(json).isEmpty;

  /// The first problem in [AddressField.all] order, or null.
  ///
  /// For a one-line summary on a card that has no room for eight messages.
  /// Iterating the declared order rather than the map's insertion order keeps
  /// the sentence stable no matter how the errors were assembled.
  static String? firstProblem(Map<String, String> errors) {
    for (final field in AddressField.all) {
      final message = errors[field];
      if (message != null) return message;
    }
    return null;
  }

  // ---- internals ----------------------------------------------------------

  static String _trim(String? value) => value?.trim() ?? '';

  /// Reads one key, tolerating the non-String values a decoded JSON body can
  /// carry — `zip_code` in particular arrives as a number often enough that
  /// casting would be a crash rather than a validation failure.
  static String? _read(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is String) return value;
    return value.toString();
  }
}

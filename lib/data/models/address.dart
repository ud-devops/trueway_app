import '../../core/utils/json_utils.dart';
import '../../core/utils/validators.dart';
import '../../core/validation/address_rules.dart';
import '../repositories/geo_repository.dart' show GeoOption;

/// A saved customer address, exactly as `AddressResource` serializes it.
///
/// ## The read shape — 18 keys, verified live 2026-08-12
///
/// ```
/// id, name, is_default, phone, email,
/// country, country_id, country_name,
/// state, state_name, district,
/// city, city_name, other_city,
/// address, landmark, zip_code, full_address
/// ```
///
/// Identical on the list route and on the create/update responses.
///
/// ## Ids are stored, names are sent alongside
///
/// [state] and [city] hold the raw foreign keys ("11", "574") — that is the
/// backend's own convention, and `state` is now validated with `exists`, so it
/// is the only thing the server will accept. The names are no longer something
/// the app has to resolve: `state_name` and `city_name` arrive with every row.
/// This class keeps both, renders [stateName]/[cityName], and round-trips
/// [state]/[city].
///
/// (The client-side geo *resolution overlay* this class used to carry is gone.
/// The server answers the question now, and a second answer computed here could
/// only ever disagree with it.)
///
/// ## The "other city" hole
///
/// A customer whose town is not in the `cities` table picks "Other" and types
/// it: the row then holds `city: "other"` with the real name in [otherCity].
/// The server does **not** substitute it back — live, such a row returns
/// `city_name: "other"` and `full_address: "1 Lane, other, Gujarat, 382415"`.
/// Printing either verbatim shows the customer the word "other" where their
/// town should be, so [cityName] and [displayAddress] put [otherCity] back.
/// See `docs/BACKEND_BUGS.md`.
class Address {
  const Address({
    required this.id,
    required this.name,
    required this.isDefault,
    required this.phone,
    required this.email,
    required this.state,
    required this.city,
    required this.address,
    required this.zipCode,
    required this.fullAddress,
    this.stateNameRaw = '',
    this.cityNameRaw = '',
    this.district = '',
    this.otherCity = '',
    this.landmark = '',
    this.countryId = '',
    this.countryName = '',
  });

  final int id;
  final String name;

  /// `is_default` arrives as an int (1/0) on the list route because the column
  /// is read straight off the row. The create/update responses build the
  /// resource from an in-memory model where the controller has just assigned a
  /// PHP bool, so `true`/`false` is also possible — [asBool] absorbs both.
  final bool isDefault;

  final String phone;
  final String email;

  /// The `states.id` this row stores, as a string ("11").
  ///
  /// This is what must be posted back. A **name** is rejected by both POST and
  /// PUT ("The selected state is invalid."), so it is also the only value that
  /// can be round-tripped.
  final String state;

  /// The `cities.id` ("574"), or the literal `"other"` — see [otherCity].
  ///
  /// Unlike [state], nothing on the server validates this: a bogus id is stored
  /// and echoed back verbatim. The picker is the only guard.
  final String city;

  /// `state_name`, resolved server-side. Empty on a row cached before the
  /// server started sending it.
  final String stateNameRaw;

  /// `city_name`, resolved server-side. Reads `"other"` for an other-city row.
  final String cityNameRaw;

  /// Free text, optional, max 120. Not part of any lookup table.
  final String district;

  /// The town the customer typed because it was not in the list. Non-empty only
  /// when [city] is `"other"`, which the server enforces the other way round:
  /// posting `city: "other"` without this is a 422.
  final String otherCity;

  /// Free text, optional, max 120. The server folds it into [fullAddress]
  /// between the street line and the city.
  final String landmark;

  /// `country_id` — the ISO code ("IN"), filled in by the server.
  final String countryId;

  /// `country_name` ("India"). Display only; the shop ships in one country and
  /// nothing is ever posted back.
  final String countryName;

  /// The street line the customer typed.
  final String address;

  final String zipCode;

  /// Server-rendered, read-only, and the only field that carries every segment
  /// in the right order. Never send it back. See [displayAddress] for the one
  /// substitution the app makes on it.
  final String fullAddress;

  factory Address.fromJson(Map<String, dynamic> j) => Address(
        id: asInt(j['id']),
        name: asString(j['name']),
        isDefault: asBool(j['is_default']),
        phone: asString(j['phone']),
        email: asString(j['email']),
        state: asString(j['state']),
        city: asString(j['city']),
        stateNameRaw: asString(j['state_name']),
        cityNameRaw: asString(j['city_name']),
        district: asString(j['district']),
        otherCity: asString(j['other_city']),
        landmark: asString(j['landmark']),
        countryId: asString(j['country_id']),
        // `country` is the rendered name on this resource
        // (`getCountryNameById`), which is what `country_name` also holds.
        // Either will do; neither is ever posted back.
        countryName: asString(j['country_name']).isNotEmpty
            ? asString(j['country_name'])
            : asString(j['country']),
        address: asString(j['address']),
        zipCode: asString(j['zip_code']),
        fullAddress: asString(j['full_address']),
      );

  /// For local caching only — the server's own read shape, so a cached row
  /// rehydrates through [Address.fromJson] with nothing lost. It is also what
  /// `CheckoutAddressRules.validateJson` reads. Dropped again by
  /// [AddressDraft.toJson], which is the *write* shape.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'is_default': isDefault ? 1 : 0,
        'phone': phone,
        'email': email,
        // The rendered name, as `AddressResource` emits it. Kept in the READ
        // shape (this map) even though the write shape drops it — a cached row
        // must rehydrate into the same object, and
        // `CheckoutAddressRules.validateJson` reads this key.
        'country': countryName,
        'country_id': countryId,
        'country_name': countryName,
        'state': state,
        'state_name': stateNameRaw,
        'district': district,
        'city': city,
        'city_name': cityNameRaw,
        'other_city': otherCity,
        'address': address,
        'landmark': landmark,
        'zip_code': zipCode,
        'full_address': fullAddress,
      };

  static final RegExp _numericId = RegExp(r'^\d+$');

  /// True when this row uses the "not in the list" escape hatch.
  bool get isOtherCity => city.trim().toLowerCase() == GeoOption.otherId;

  /// The state to show: the server's name, falling back to the stored token.
  ///
  /// The fallback only bites on a row cached before `state_name` existed, or
  /// one whose `states` row was deleted — showing "11" is ugly, showing nothing
  /// reads as a missing address.
  String get stateName => _shown(stateNameRaw, state);

  /// The city to show.
  ///
  /// [otherCity] wins for an other-city row, because the server's own
  /// `city_name` is the literal string "other" there.
  String get cityName {
    if (isOtherCity && otherCity.trim().isNotEmpty) return otherCity.trim();
    return _shown(cityNameRaw, city);
  }

  static String _shown(String resolved, String raw) {
    final r = resolved.trim();
    return r.isEmpty ? raw : r;
  }

  /// A value only if it reads as a place. A bare id becomes empty, so a caller
  /// can drop it rather than print it mid-sentence.
  static String _nameOrNothing(String shown) =>
      _numericId.hasMatch(shown) ? '' : shown;

  /// The one string that is always safe to show.
  ///
  /// Prefers the server's own `full_address`, which resolves the ids and orders
  /// the segments — including the landmark, which sits between the street line
  /// and the city.
  ///
  /// The single exception is an other-city row, where the server writes the
  /// literal word "other" in the city slot. That segment is swapped for
  /// [otherCity]; everything else is left exactly as the server rendered it.
  String get displayAddress {
    final full = fullAddress.trim();
    if (full.isNotEmpty) return _withOtherCity(full);
    return [
      address,
      landmark,
      _nameOrNothing(cityName),
      _nameOrNothing(stateName),
      zipCode,
      countryName,
    ].map((e) => e.trim()).where((e) => e.isNotEmpty).join(', ');
  }

  /// Replaces the server's literal `other` segment with the town the customer
  /// typed. Applied only to an other-city row that actually carries a name, and
  /// only to a **whole** segment, so a street called "Other Lane" survives.
  String _withOtherCity(String full) {
    final replacement = otherCity.trim();
    if (!isOtherCity || replacement.isEmpty) return full;
    var replaced = false;
    final parts = [
      for (final part in full.split(',')) part.trim(),
    ];
    for (var i = 0; i < parts.length; i++) {
      if (!replaced && parts[i].toLowerCase() == GeoOption.otherId) {
        parts[i] = replacement;
        replaced = true;
      }
    }
    return replaced ? parts.where((p) => p.isNotEmpty).join(', ') : full;
  }

  /// Everything in [displayAddress] after the street line, for two-line cards.
  ///
  /// Strips the known prefix rather than assuming the remainder's structure,
  /// because `full_address` carries segments the street line does not.
  String get regionLine {
    final full = displayAddress;
    final street = address.trim();
    if (street.isNotEmpty && full.startsWith(street)) {
      return full.substring(street.length).replaceFirst(RegExp(r'^[,\s]+'), '');
    }
    return full;
  }

  /// Everything a customer might type when hunting for this address.
  ///
  /// Built from the **shown** values, never the stored ones. `state` and `city`
  /// hold opaque geo ids — `"11"`, `"574"` — while the card reads "Gujarat"
  /// and "Ahmedabad", so a search over the raw fields would find nothing for
  /// the very words on screen. [displayAddress] already resolves them (and puts
  /// the town back for an other-city row), which is why it is the spine of this
  /// string rather than a hand-assembled list.
  ///
  /// The recipient's name and phone are in here too: an address book is
  /// usually "mum's place" and "the office", and the phone is how a customer
  /// tells two addresses at the same house apart.
  String get searchHaystack => [
        name,
        phone,
        email,
        displayAddress,
        // Not always inside `full_address` — the server omits an empty one,
        // and a cached row may predate the field.
        landmark,
        district,
        zipCode,
      ].map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).join(' ');

  /// Whether this address answers [query].
  ///
  /// Every whitespace-separated term has to appear somewhere, in any order, so
  /// "ahmedabad 382415" and "382415 ahmedabad" both find the same row while
  /// "ahmedabad 400001" finds neither. A single blob-contains would fail the
  /// first of those, which is how people actually type an address.
  ///
  /// A blank query matches everything — the caller shows the whole book rather
  /// than an empty screen.
  bool matches(String query) {
    final terms = query.toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((t) => t.isEmpty);
    if (terms.isEmpty) return true;

    final haystack = searchHaystack;
    return terms.every(haystack.contains);
  }

  /// Seed for the edit form.
  ///
  /// `full_address`, `state_name`, `city_name` and the country fields are
  /// deliberately not carried over: they are server-rendered, the write side
  /// has no such fields, and anything sent would be dropped. [state] and [city]
  /// carry the **stored ids**, which is what the pickers select by and what the
  /// server requires.
  AddressDraft toDraft() => AddressDraft(
        name: name,
        phone: phone,
        email: email,
        state: state,
        city: city,
        otherCity: otherCity,
        district: district,
        landmark: landmark,
        address: address,
        zipCode: zipCode,
        isDefault: isDefault,
      );

  Address copyWith({bool? isDefault}) => Address(
        id: id,
        name: name,
        isDefault: isDefault ?? this.isDefault,
        phone: phone,
        email: email,
        state: state,
        city: city,
        stateNameRaw: stateNameRaw,
        cityNameRaw: cityNameRaw,
        district: district,
        otherCity: otherCity,
        landmark: landmark,
        countryId: countryId,
        countryName: countryName,
        address: address,
        zipCode: zipCode,
        fullAddress: fullAddress,
      );

  /// Full-field equality, matching `Customer`.
  ///
  /// Comparing on [id] alone looked tidier but is a trap: `setDefault` changes
  /// nothing *but* [isDefault], so an id-only `==` reports the before and after
  /// rows as equal. Any `listEquals`, `Set`, `distinct()` or Riverpod
  /// `updateShouldNotify` comparison would then suppress the rebuild that shows
  /// the moved "Default" badge. Use [isSameRow] when identity is what you want.
  @override
  bool operator ==(Object other) =>
      other is Address &&
      other.id == id &&
      other.name == name &&
      other.isDefault == isDefault &&
      other.phone == phone &&
      other.email == email &&
      other.state == state &&
      other.city == city &&
      other.stateNameRaw == stateNameRaw &&
      other.cityNameRaw == cityNameRaw &&
      other.district == district &&
      other.otherCity == otherCity &&
      other.landmark == landmark &&
      other.countryId == countryId &&
      other.countryName == countryName &&
      other.address == address &&
      other.zipCode == zipCode &&
      other.fullAddress == fullAddress;

  @override
  int get hashCode => Object.hashAll([
        id,
        name,
        isDefault,
        phone,
        email,
        state,
        city,
        stateNameRaw,
        cityNameRaw,
        district,
        otherCity,
        landmark,
        countryId,
        countryName,
        address,
        zipCode,
        fullAddress,
      ]);

  /// Same server row, regardless of how its fields have since changed.
  bool isSameRow(Address other) => other.id == id;
}

/// The write shape for POST and PUT `/ecommerce/addresses`.
///
/// ## One rule set, both verbs
///
/// The two FormRequests used to disagree — POST needed only `{name, phone}`
/// while PUT demanded seven fields — which meant a row created through POST
/// could be uneditable forever. They now agree, re-probed live 2026-08-12 by
/// sending an empty body to each:
///
/// ```
/// POST {} -> name, phone, state, city, address, zip_code
/// PUT  {} -> name, phone, state, city, address, zip_code   (identical)
/// ```
///
/// So [validationErrors] is the whole contract; there is no longer a
/// `postOnlyErrors` counterpart to reconcile.
///
/// ## `country` is not sent
///
/// The store ships in one country and the server fills `country_id` itself.
/// Anything sent is ignored — verified: a row POSTed with `country: "India"`
/// comes back with the same `country_id: "IN"` as one POSTed without it. It was
/// previously sent as the *name*, which destroyed the stored id.
class AddressDraft {
  const AddressDraft({
    this.name = '',
    this.phone = '',
    this.email = '',
    this.state = '',
    this.city = '',
    this.otherCity = '',
    this.district = '',
    this.landmark = '',
    this.address = '',
    this.zipCode = '',
    this.isDefault,
  });

  final String name;
  final String phone;

  /// Optional — `nullable|email|max:60` server-side, and optional here too.
  ///
  /// Order mail goes to the **account's** address: `OrderHelper` reads
  /// `$order->user->email ?: $order->address->email`, so this is only a
  /// fallback. Nothing in the app asks the customer for it any more; it carries
  /// whatever the row already had, or the signed-in customer's own address.
  final String email;

  /// A bare `states.id`. Validated with `exists` server-side — a name is a 422.
  final String state;

  /// A `cities.id`, or the literal `"other"`.
  final String city;

  /// Required when, and only sent when, [city] is `"other"`.
  final String otherCity;

  final String district;
  final String landmark;
  final String address;
  final String zipCode;

  /// Tri-state on purpose: `null` means **"leave the server's flag alone"**.
  ///
  /// `is_default` is `nullable|boolean`, so omitting the key is legal and
  /// Laravel's `validated()` then excludes it from `$address->update(...)`.
  ///
  /// Defaulting this to `false` meant every PUT asserted "not default". An edit
  /// form that saved the customer's *current* default therefore demoted it, and
  /// nothing on the server re-promotes on update — `handleDefaultAddress` only
  /// ever clears the *other* rows. The book was left with no default at all and
  /// the next checkout silently preselected the newest address.
  ///
  /// Set it explicitly only when the customer actually operated the control.
  final bool? isDefault;

  AddressDraft copyWith({
    String? name,
    String? phone,
    String? email,
    String? state,
    String? city,
    String? otherCity,
    String? district,
    String? landmark,
    String? address,
    String? zipCode,
    bool? isDefault,
  }) =>
      AddressDraft(
        name: name ?? this.name,
        phone: phone ?? this.phone,
        email: email ?? this.email,
        state: state ?? this.state,
        city: city ?? this.city,
        otherCity: otherCity ?? this.otherCity,
        district: district ?? this.district,
        landmark: landmark ?? this.landmark,
        address: address ?? this.address,
        zipCode: zipCode ?? this.zipCode,
        isDefault: isDefault ?? this.isDefault,
      );

  /// `name` and `address` are `max:191`.
  static const int maxTextLength = 191;

  /// `state`, `city`, `district`, `landmark` and `other_city` are all
  /// `max:120` — the last three confirmed by the server's own message ("The
  /// landmark must not be greater than 120 characters.").
  static const int maxRegionLength = 120;

  static const int maxEmailLength = 60;
  static const int maxZipLength = 20;

  /// True when [city] is the "not in the list" sentinel.
  bool get isOtherCity => city.trim().toLowerCase() == GeoOption.otherId;

  /// Field name -> message, empty when the draft will pass the server's rules.
  ///
  /// Keys match the server's field names so a form can merge these with an
  /// ApiException `fieldErrors` bag without translating.
  Map<String, String> validationErrors() {
    final errors = <String, String>{};

    void required(String field, String value, String missing, int max) {
      final v = value.trim();
      if (v.isEmpty) {
        errors[field] = missing;
      } else if (v.length > max) {
        errors[field] = 'Too long (max $max characters)';
      }
    }

    required('name', name, 'Enter a name', maxTextLength);
    required('address', address, 'Enter the street address', maxTextLength);

    final phoneError = _phoneError(phone);
    if (phoneError != null) errors['phone'] = phoneError;

    // Optional here too — see [email]. Only a *malformed* one is an error;
    // a blank one is what the server, and now this app, accept.
    final trimmedEmail = email.trim();
    if (trimmedEmail.isEmpty) {
      // nothing to check
    } else if (trimmedEmail.length > maxEmailLength) {
      errors['email'] = 'Email is too long (max $maxEmailLength characters)';
    } else if (!isValidEmail(trimmedEmail)) {
      errors['email'] = 'Enter a valid email address';
    }

    // `state` is `exists`-validated, so "any non-empty string" is not enough:
    // a name reaches the server as a 422 that names no field the customer can
    // see. Requiring an id here is what makes the picker load-bearing.
    final trimmedState = state.trim();
    if (trimmedState.isEmpty) {
      errors['state'] = 'Choose a state';
    } else if (!Address._numericId.hasMatch(trimmedState)) {
      errors['state'] = 'Choose a state from the list';
    }

    final trimmedCity = city.trim();
    if (trimmedCity.isEmpty) {
      errors['city'] = 'Choose a city';
    } else if (trimmedCity.length > maxRegionLength) {
      errors['city'] = 'Too long (max $maxRegionLength characters)';
    }

    // The server's own conditional rule: "The other city field is required
    // when city is other."
    final trimmedOther = otherCity.trim();
    if (isOtherCity && trimmedOther.isEmpty) {
      errors['other_city'] = 'Enter your city or town';
    } else if (trimmedOther.length > maxRegionLength) {
      errors['other_city'] = 'Too long (max $maxRegionLength characters)';
    }

    if (district.trim().length > maxRegionLength) {
      errors['district'] = 'Too long (max $maxRegionLength characters)';
    }
    if (landmark.trim().length > maxRegionLength) {
      errors['landmark'] = 'Too long (max $maxRegionLength characters)';
    }

    // `zip_code` is now `required` — it used to be nullable, which is exactly
    // how PIN-less rows nobody can quote shipping for got into real books.
    final trimmedZip = zipCode.trim();
    if (trimmedZip.isEmpty) {
      errors['zip_code'] = 'Enter the PIN code';
    } else if (trimmedZip.length > maxZipLength) {
      errors['zip_code'] = 'Too long (max $maxZipLength characters)';
    }

    return errors;
  }

  bool get isValid => validationErrors().isEmpty;

  /// The phone rule is the strictest thing in this contract:
  /// `string|numeric|digits:10|regex:/^[6-9][0-9]{9}$/`. Verified live — a JSON
  /// integer is rejected ("The phone must be a string"), and so is
  /// "+919876543210" and any landline starting 1-5.
  static String? _phoneError(String value) {
    final v = value.trim();
    if (v.isEmpty) return 'Enter a mobile number';
    if (!isValidMobile(v)) {
      return 'Enter a 10-digit Indian mobile number starting 6-9';
    }
    return null;
  }

  /// Request body for both POST and PUT.
  ///
  /// Three things are load-bearing:
  ///   * `phone` is sent as a String. A JSON number 422s.
  ///   * `is_default` is sent only when [isDefault] is non-null — omitting it
  ///     preserves the server's current flag. The `boolean` validator accepts
  ///     true/false/1/0/"1"/"0"; "true" and "yes" are a 422.
  ///   * `other_city` is sent **only** for an other-city row. Sending it beside
  ///     a real city id would store a town name the address does not use.
  ///
  /// `country` is absent by design — see the class doc.
  Map<String, dynamic> toJson() => {
        'name': name.trim(),
        'phone': phone.trim(),
        'email': email.trim(),
        'state': state.trim(),
        'city': city.trim(),
        'address': address.trim(),
        'zip_code': zipCode.trim(),
        'district': district.trim(),
        'landmark': landmark.trim(),
        if (isOtherCity) 'other_city': otherCity.trim(),
        if (isDefault != null) 'is_default': isDefault,
      };

  /// [toJson], with a country stitched back in for [CheckoutAddressRules].
  ///
  /// [toJson] is the address-book **write** shape, and it has no `country` key
  /// because the endpoint stopped accepting one — the server fills it and
  /// ignores anything sent. [CheckoutAddressRules] still asks for one, because
  /// it describes the **checkout** body, which does carry the field.
  ///
  /// Every caller that runs a draft through those rules — deciding whether an
  /// address is complete enough to check out with, or explaining why it is
  /// not — must go through this rather than [toJson] directly. Skipping it is
  /// exactly how a perfectly complete address once got reported as
  /// "Enter the country": the one field this app never collects and the
  /// server never asks for.
  Map<String, dynamic> toCheckoutJson() => {
        ...toJson(),
        AddressField.country: CheckoutAddressRules.shipsToCountry,
      };
}

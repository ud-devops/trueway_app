import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/validation/address_rules.dart';

/// The WEB checkout's address rules — the ones the mobile API does not enforce.
///
/// Every boundary is pinned from both sides (the last accepted value and the
/// first rejected one), because every one of these limits is a place where the
/// server is *looser* than the app: a rule that quietly relaxes here produces a
/// row the address book stores happily and an order nobody can dispatch.
///
/// Pure unit tests. Nothing here builds a widget or touches a provider — that
/// is the point of keeping the rules in their own file.

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

String _chars(int n) => 'a' * n;

/// A valid email of exactly [length] characters.
///
/// `@example.com` is 12 characters, so the local part carries the remainder.
/// Built rather than hard-coded so the 60/61 pair cannot drift apart from a
/// typo in one of them.
String _emailOfLength(int length) {
  const domain = '@example.com';
  return _chars(length - domain.length) + domain;
}

/// Everything a checkout address needs, all of it legal.
const _valid = (
  name: 'Suraj Ojha',
  phone: '9876543210',
  email: 'suraj.ojha@uminber.in',
  address: '306, Jahnavi Arcade, S.P. Ring Road, Odhav',
  city: 'Ahmedabad',
  state: 'Gujarat',
  zipCode: '382415',
  country: 'India',
);

Map<String, String> _validateWith({
  String? name,
  String? phone,
  String? email,
  String? address,
  String? city,
  String? state,
  String? zipCode,
  String? country,
}) =>
    CheckoutAddressRules.validate(
      name: name ?? _valid.name,
      phone: phone ?? _valid.phone,
      email: email ?? _valid.email,
      address: address ?? _valid.address,
      city: city ?? _valid.city,
      state: state ?? _valid.state,
      zipCode: zipCode ?? _valid.zipCode,
      country: country ?? _valid.country,
    );

/// The wire shape the checkout body's `address` object uses.
Map<String, dynamic> _json({
  String? name,
  String? phone,
  String? email,
  String? address,
  String? city,
  String? state,
  String? zipCode,
  String? country,
}) =>
    {
      'name': name ?? _valid.name,
      'phone': phone ?? _valid.phone,
      'email': email ?? _valid.email,
      'address': address ?? _valid.address,
      'city': city ?? _valid.city,
      'state': state ?? _valid.state,
      'zip_code': zipCode ?? _valid.zipCode,
      'country': country ?? _valid.country,
    };

void main() {
  // -------------------------------------------------------------------------
  // name — required, min 3, max 120
  // -------------------------------------------------------------------------

  group('name', () {
    test('is required', () {
      expect(CheckoutAddressRules.nameError(null), 'Enter a name');
      expect(CheckoutAddressRules.nameError(''), 'Enter a name');
      // Whitespace is not a name; the server would store it and the courier
      // would have nobody to ask for.
      expect(CheckoutAddressRules.nameError('   '), 'Enter a name');
    });

    test('rejects 2 characters and accepts 3 — the min:3 boundary', () {
      // The mobile API has no minimum at all, so this is the app's rule alone.
      expect(CheckoutAddressRules.nameError(_chars(2)), isNotNull);
      expect(CheckoutAddressRules.nameError(_chars(3)), isNull);
    });

    test('accepts 120 characters and rejects 121 — the max:120 boundary', () {
      expect(CheckoutAddressRules.nameError(_chars(120)), isNull);
      expect(CheckoutAddressRules.nameError(_chars(121)), isNotNull);
    });

    test('measures the trimmed value, not the typed one', () {
      // " ab " is four characters typed and two that count.
      expect(CheckoutAddressRules.nameError(' ab '), isNotNull);
      expect(CheckoutAddressRules.nameError(' abc '), isNull);
      expect(CheckoutAddressRules.nameError(' ${_chars(120)} '), isNull);
    });

    test('says which way it is wrong', () {
      expect(CheckoutAddressRules.nameError('Jo'), contains('short'));
      expect(CheckoutAddressRules.nameError(_chars(121)), contains('long'));
    });
  });

  // -------------------------------------------------------------------------
  // address — required, max 120 (NOT the API's 500)
  // -------------------------------------------------------------------------

  group('address', () {
    test('is required', () {
      expect(
        CheckoutAddressRules.addressError(null),
        'Enter the street address',
      );
      expect(CheckoutAddressRules.addressError('  '), isNotNull);
    });

    test('accepts 120 characters and rejects 121', () {
      expect(CheckoutAddressRules.addressError(_chars(120)), isNull);
      expect(CheckoutAddressRules.addressError(_chars(121)), isNotNull);
    });

    test('caps at 120, not at the mobile API\'s 500', () {
      // The single most misleading number in the mobile contract: a 200-char
      // street line is accepted by `POST /checkout/cart/{id}` and cannot be
      // printed on a label.
      expect(CheckoutAddressRules.addressMax, 120);
      expect(CheckoutAddressRules.addressError(_chars(200)), isNotNull);
    });

    test('a single character is enough — there is no minimum', () {
      expect(CheckoutAddressRules.addressError('7'), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // city / state / country — required, max 120
  // -------------------------------------------------------------------------

  group('city', () {
    test('is required', () {
      expect(CheckoutAddressRules.cityError(null), 'Enter the city');
      expect(CheckoutAddressRules.cityError(' '), isNotNull);
    });

    test('accepts 120 characters and rejects 121', () {
      expect(CheckoutAddressRules.cityError(_chars(120)), isNull);
      expect(CheckoutAddressRules.cityError(_chars(121)), isNotNull);
    });
  });

  group('state', () {
    test('is REQUIRED even though the mobile API says nullable', () {
      // It drives shipping-rule matching. A blank one is an order nobody can
      // rate, and the server will not complain.
      expect(CheckoutAddressRules.stateError(null), 'Enter the state');
      expect(CheckoutAddressRules.stateError(''), isNotNull);
      expect(CheckoutAddressRules.stateError('   '), isNotNull);
    });

    test('accepts 120 characters and rejects 121', () {
      expect(CheckoutAddressRules.stateError(_chars(120)), isNull);
      expect(CheckoutAddressRules.stateError(_chars(121)), isNotNull);
    });

    test('accepts the numeric id real rows actually store', () {
      // `GET /ecommerce/addresses` returns state as "11" as often as
      // "Madhya Pradesh". Both round-trip; neither is a violation.
      expect(CheckoutAddressRules.stateError('11'), isNull);
    });
  });

  group('country', () {
    test('is required', () {
      expect(CheckoutAddressRules.countryError(null), 'Enter the country');
      expect(CheckoutAddressRules.countryError(''), isNotNull);
    });

    test('accepts 120 characters and rejects 121', () {
      expect(CheckoutAddressRules.countryError(_chars(120)), isNull);
      expect(CheckoutAddressRules.countryError(_chars(121)), isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // phone — required, exactly 10 digits, ^[6-9][0-9]{9}$
  // -------------------------------------------------------------------------

  group('phone', () {
    test('is required', () {
      expect(CheckoutAddressRules.phoneError(null), 'Enter a mobile number');
      expect(CheckoutAddressRules.phoneError(''), isNotNull);
    });

    test('rejects a number starting 5 and accepts the same one starting 6', () {
      // The boundary of the ^[6-9] rule, both sides, same nine trailing digits.
      expect(CheckoutAddressRules.phoneError('5876543210'), isNotNull);
      expect(CheckoutAddressRules.phoneError('6876543210'), isNull);
    });

    test('accepts every leading digit 6-9 and rejects 0-5', () {
      for (final lead in ['6', '7', '8', '9']) {
        expect(
          CheckoutAddressRules.phoneError('${lead}876543210'),
          isNull,
          reason: 'a real subscriber number starting $lead',
        );
      }
      for (final lead in ['0', '1', '2', '3', '4', '5']) {
        expect(
          CheckoutAddressRules.phoneError('${lead}876543210'),
          isNotNull,
          reason: 'a landline or short code starting $lead',
        );
      }
    });

    test('is exactly ten digits — not nine, not eleven', () {
      expect(CheckoutAddressRules.phoneError('987654321'), isNotNull);
      expect(CheckoutAddressRules.phoneError('9876543210'), isNull);
      expect(CheckoutAddressRules.phoneError('98765432100'), isNotNull);
    });

    test('rejects a country code and any punctuation', () {
      // The mobile API's rule is `max:20` free text, so all of these reach the
      // order today and none of them can be dialled by the courier.
      expect(CheckoutAddressRules.phoneError('+919876543210'), isNotNull);
      expect(CheckoutAddressRules.phoneError('98765 43210'), isNotNull);
      expect(CheckoutAddressRules.phoneError('98765-43210'), isNotNull);
    });

    test('trims before matching', () {
      expect(CheckoutAddressRules.phoneError(' 9876543210 '), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // zip_code — required, 6 digits, never leading zero
  // -------------------------------------------------------------------------

  group('zip_code', () {
    test('is REQUIRED even though the mobile API says nullable|max:20', () {
      // This is the rule that produces the undispatchable order: a PIN-less
      // address yields a zero shipping quote and an order nobody can ship.
      expect(
        CheckoutAddressRules.zipCodeError(null),
        'Enter the 6-digit PIN code',
      );
      expect(CheckoutAddressRules.zipCodeError(''), isNotNull);
      expect(CheckoutAddressRules.zipCodeError('   '), isNotNull);
    });

    test('rejects a PIN starting 0 and accepts the same one starting 1', () {
      expect(
        CheckoutAddressRules.zipCodeError('082415'),
        'A PIN code cannot start with 0',
      );
      expect(CheckoutAddressRules.zipCodeError('182415'), isNull);
    });

    test('is exactly six digits', () {
      expect(CheckoutAddressRules.zipCodeError('38241'), isNotNull);
      expect(CheckoutAddressRules.zipCodeError('382415'), isNull);
      expect(CheckoutAddressRules.zipCodeError('3824150'), isNotNull);
    });

    test('rejects anything that is not six digits', () {
      expect(CheckoutAddressRules.zipCodeError('38241A'), isNotNull);
      expect(CheckoutAddressRules.zipCodeError('382 415'), isNotNull);
      // `max:20` on the server: this is stored verbatim today.
      expect(CheckoutAddressRules.zipCodeError('Ahmedabad'), isNotNull);
    });

    test('trims before matching', () {
      expect(CheckoutAddressRules.zipCodeError(' 382415 '), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // email — valid, 6-60 characters
  // -------------------------------------------------------------------------

  group('email', () {
    // Optional, and the app no longer asks for one — order mail goes to the
    // account. The backend team disproved the old "checkout refuses an address
    // with no email" claim from the source and the live database:
    // `CheckoutRequest` marks the field `nullable`, and `EcommerceHelper`'s
    // rule is `['email','nullable','max:60','min:6']`.
    test('is optional', () {
      expect(CheckoutAddressRules.emailError(null), isNull);
      expect(CheckoutAddressRules.emailError(''), isNull);
      expect(CheckoutAddressRules.emailError('   '), isNull);
    });

    test('rejects 5 characters and accepts 6 — the min boundary', () {
      // Both are well-formed addresses; only the length differs.
      expect('a@b.c'.length, 5);
      expect('ab@b.c'.length, 6);
      expect(CheckoutAddressRules.emailError('a@b.c'), isNotNull);
      expect(CheckoutAddressRules.emailError('ab@b.c'), isNull);
    });

    test('accepts 60 characters and rejects 61 — the max boundary', () {
      expect(_emailOfLength(60).length, 60);
      expect(_emailOfLength(61).length, 61);
      expect(CheckoutAddressRules.emailError(_emailOfLength(60)), isNull);
      expect(CheckoutAddressRules.emailError(_emailOfLength(61)), isNotNull);
    });

    test('caps at 60, not at the mobile API\'s 255', () {
      expect(CheckoutAddressRules.emailMax, 60);
      expect(CheckoutAddressRules.emailError(_emailOfLength(200)), isNotNull);
    });

    test('rejects a malformed address of a legal length', () {
      // Long enough to clear the 6-character floor, so only the shape is wrong.
      expect(
        CheckoutAddressRules.emailError('not-an-email'),
        'Enter a valid email address',
      );
      expect(CheckoutAddressRules.emailError('missing@host'), isNotNull);
      expect(CheckoutAddressRules.emailError('two@@hosts.com'), isNotNull);
      expect(CheckoutAddressRules.emailError('spaces in@host.com'), isNotNull);
    });

    test('accepts the dotted local part real customers use', () {
      expect(CheckoutAddressRules.emailError('suraj.ojha@uminber.in'), isNull);
    });

    test('trims before measuring', () {
      expect(CheckoutAddressRules.emailError('  ab@b.c  '), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // The whole address
  // -------------------------------------------------------------------------

  group('validate', () {
    test('a complete address has no violations', () {
      expect(_validateWith(), isEmpty);
      expect(
        CheckoutAddressRules.isValid(
          name: _valid.name,
          phone: _valid.phone,
          email: _valid.email,
          address: _valid.address,
          city: _valid.city,
          state: _valid.state,
          zipCode: _valid.zipCode,
          country: _valid.country,
        ),
        isTrue,
      );
    });

    test('keys are the server\'s own field names', () {
      // So a caller can merge these straight into an ApiException fieldErrors
      // bag — and so a 422 on `address.zip_code` lands on the same input.
      final errors = CheckoutAddressRules.validate();
      // No `email`: it is optional, so a blank one is not an error to report.
      expect(
        errors.keys.toSet(),
        {
          'name',
          'phone',
          'address',
          'city',
          'state',
          'zip_code',
          'country',
        },
      );
      expect(AddressField.zipCode, 'zip_code');
    });

    test('reports every broken field at once, not just the first', () {
      final errors = CheckoutAddressRules.validate(
        name: 'Jo',
        phone: '5876543210',
        email: 'a@b.c',
        address: _chars(121),
        city: '',
        state: '',
        zipCode: '082415',
        country: '',
      );
      expect(errors, hasLength(8));
    });

    test('an address that only the mobile API would accept is rejected', () {
      // Exactly the row the server's own rules permit: no state, no PIN, a
      // one-character name, a 200-character street line and a landline.
      final errors = CheckoutAddressRules.validate(
        name: 'S',
        phone: '0123456789',
        email: 'suraj.ojha@uminber.in',
        address: _chars(200),
        city: 'Ahmedabad',
        state: '',
        zipCode: '',
        country: 'India',
      );
      expect(errors.keys.toSet(), {
        'name',
        'phone',
        'address',
        'state',
        'zip_code',
      });
    });

    test('one missing field is reported alone', () {
      expect(_validateWith(state: '').keys, ['state']);
      expect(_validateWith(zipCode: '').keys, ['zip_code']);
    });
  });

  group('validateJson', () {
    test('reads the checkout body\'s address shape', () {
      expect(CheckoutAddressRules.validateJson(_json()), isEmpty);
      expect(CheckoutAddressRules.isValidJson(_json()), isTrue);
    });

    test('flags the PIN-less row the address book really contains', () {
      final errors = CheckoutAddressRules.validateJson(_json(zipCode: ''));
      expect(errors.keys, ['zip_code']);
      expect(CheckoutAddressRules.isValidJson(_json(zipCode: '')), isFalse);
    });

    test('ignores the keys the read shape carries and the write shape does not',
        () {
      final row = _json()
        ..addAll({
          'id': 16,
          'is_default': 1,
          'full_address': '306, Jahnavi Arcade, Ahmedabad, Gujarat, 382415',
        });
      expect(CheckoutAddressRules.validateJson(row), isEmpty);
    });

    test('a null map is every field missing, never "fine"', () {
      // "No address at all" reading as valid is the failure mode that puts an
      // empty address on an order.
      // Seven, not eight — `email` is optional, so its absence is not a
      // problem. Everything else missing still is.
      expect(CheckoutAddressRules.validateJson(null), hasLength(7));
      expect(CheckoutAddressRules.isValidJson(null), isFalse);
      expect(CheckoutAddressRules.validateJson(const {}), hasLength(7));
    });

    test('tolerates a numeric zip_code rather than crashing on the cast', () {
      // A decoded JSON body can carry it either way, and a crash here would
      // read as "no address problems" to a caller that only catches nothing.
      final numeric = _json()..['zip_code'] = 382415;
      expect(CheckoutAddressRules.validateJson(numeric), isEmpty);

      final badNumeric = _json()..['zip_code'] = 38241;
      expect(CheckoutAddressRules.validateJson(badNumeric).keys, ['zip_code']);
    });

    test('a missing key and an empty string read the same', () {
      final absent = _json()..remove('state');
      expect(CheckoutAddressRules.validateJson(absent).keys, ['state']);
    });
  });

  group('firstProblem', () {
    test('follows the declared field order, not the map\'s', () {
      final errors = CheckoutAddressRules.validate(
        name: _valid.name,
        phone: '',
        email: _valid.email,
        address: _valid.address,
        city: '',
        state: _valid.state,
        zipCode: '',
        country: _valid.country,
      );
      // phone precedes city precedes zip_code in AddressField.all.
      expect(
        CheckoutAddressRules.firstProblem(errors),
        'Enter a mobile number',
      );
    });

    test('is null when nothing is wrong', () {
      expect(CheckoutAddressRules.firstProblem(_validateWith()), isNull);
    });
  });

  group('the shared refusal sentence', () {
    test('is one string, so no two screens can word it differently', () {
      expect(
        CheckoutAddressRules.undeliverableMessage,
        'Cannot be delivered to - please complete this address',
      );
    });
  });

  group('the published limits match the web checkout', () {
    test('are the numbers the rules actually apply', () {
      expect(CheckoutAddressRules.nameMin, 3);
      expect(CheckoutAddressRules.nameMax, 120);
      expect(CheckoutAddressRules.addressMax, 120);
      expect(CheckoutAddressRules.cityMax, 120);
      expect(CheckoutAddressRules.stateMax, 120);
      expect(CheckoutAddressRules.countryMax, 120);
      expect(CheckoutAddressRules.emailMin, 6);
      expect(CheckoutAddressRules.emailMax, 60);
      expect(CheckoutAddressRules.phoneDigits, 10);
      expect(CheckoutAddressRules.zipDigits, 6);
    });

    test('AddressField.all lists every governed field once', () {
      expect(AddressField.all, hasLength(8));
      expect(AddressField.all.toSet(), hasLength(8));

      // Every field `validate()` can complain about is one of them...
      final reported = CheckoutAddressRules.validate().keys.toSet();
      expect(AddressField.all.toSet().containsAll(reported), isTrue);

      // ...and the only governed field an empty address is *not* asked for is
      // the optional one.
      expect(
        AddressField.all.toSet().difference(reported),
        {AddressField.email},
      );
    });
  });
}

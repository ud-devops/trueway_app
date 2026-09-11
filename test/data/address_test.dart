import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/core/validation/address_rules.dart';
import 'package:trueway_farms/data/models/address.dart';
import 'package:trueway_farms/data/repositories/address_repository.dart';

/// Captured verbatim from `GET /ecommerce/addresses` (auth_addresses.json).
///
/// Worth reading before changing anything: rows 16/45 store `state:"11",
/// city:"574"` while row 50 stores `"Madhya Pradesh"/"Gwalior"` — the same
/// columns hold ids on some rows and names on others, and only `full_address`
/// resolves them. Note also the hybrid envelope: paginated `data/links/meta`
/// PLUS the `error`/`message` keys of the simple envelope.
const String _addressesPayload = '''
{"data":[{"id":16,"name":"Suraj ojha","is_default":1,"phone":"8305317276","email":"suraj.ojha@uminber.in","country":"India","state":"11","city":"574","address":"306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad","zip_code":"382415","full_address":"306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad, sda etasd, Ahmedabad, Gujarat, 382415"},{"id":57,"name":"Suraj ojha","is_default":0,"phone":"8305317276","email":"suraj.ojha@uminber.in","country":"India","state":"11","city":"Ahmadabad City","address":"306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad","zip_code":"382415","full_address":"306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad, Ahmadabad City, Gujarat, 382415"},{"id":50,"name":"Suraj ojha","is_default":0,"phone":"8305317276","email":"suraj.ojha@uminber.in","country":"India","state":"Madhya Pradesh","city":"Gwalior","address":"402, ganesh rivera","zip_code":"474010","full_address":"402, ganesh rivera, Gwalior, Madhya Pradesh, 474010"},{"id":45,"name":"Suraj ojha","is_default":0,"phone":"8305317276","email":"surajojha2804@gmail.com","country":"India","state":"11","city":"574","address":"401 ganesh rivera","zip_code":"382350","full_address":"401 ganesh rivera, near palican paradise, Ahmedabad, Gujarat, 382350"},{"id":42,"name":"Suraj ojha","is_default":0,"phone":"8305317276","email":"suraj.ojha@uminber.in","country":"India","state":"20","city":"Gwalior","address":"Shivani colony, Motijheel","zip_code":"474010","full_address":"Shivani colony, Motijheel, Gwalior, Madhya Pradesh, 474010"},{"id":39,"name":"Suraj ojha","is_default":0,"phone":"8305317276","email":"suraj.ojha@uminber.in","country":"India","state":"11","city":"574","address":"306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad","zip_code":"382415","full_address":"306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad, Ahmedabad, Gujarat, 382415"}],"links":{"first":"https://dev.truewayerp.com/api/v1/ecommerce/addresses?page=1","last":"https://dev.truewayerp.com/api/v1/ecommerce/addresses?page=1","prev":null,"next":null},"meta":{"current_page":1,"from":1,"last_page":1,"links":[{"url":null,"label":"&laquo; Previous","page":null,"active":false},{"url":"https://dev.truewayerp.com/api/v1/ecommerce/addresses?page=1","label":"1","page":1,"active":true},{"url":null,"label":"Next &raquo;","page":null,"active":false}],"path":"https://dev.truewayerp.com/api/v1/ecommerce/addresses","per_page":10,"to":6,"total":6},"error":false,"message":null}
''';

/// A customer with no saved addresses. `data` is an empty ARRAY (not `{}` or
/// null), and `meta.from`/`meta.to` go null.
const String _emptyPayload = '''
{"data":[],"links":{"first":"https://dev.truewayerp.com/api/v1/ecommerce/addresses?page=1","last":"https://dev.truewayerp.com/api/v1/ecommerce/addresses?page=1","prev":null,"next":null},"meta":{"current_page":1,"from":null,"last_page":1,"links":[],"path":"https://dev.truewayerp.com/api/v1/ecommerce/addresses","per_page":10,"to":null,"total":0},"error":false,"message":null}
''';

List<Map<String, dynamic>> _payloadRows() =>
    ((jsonDecode(_addressesPayload) as Map)['data'] as List)
        .cast<Map<String, dynamic>>();

// ---------------------------------------------------------------------------
// Fake transport — the same pattern as test/core/api_client_business_error_test
// ---------------------------------------------------------------------------

class _Canned {
  const _Canned(this.statusCode, this.body);
  final int statusCode;
  final Object? body;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responder);

  /// Keyed on "METHOD path?query" so pagination can be exercised.
  final _Canned Function(RequestOptions) responder;

  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final canned = responder(options);
    return ResponseBody.fromString(
      canned.body is String ? canned.body as String : jsonEncode(canned.body),
      canned.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<(AddressRepository, _FakeAdapter)> _repo(
  _Canned Function(RequestOptions) responder,
) async {
  SharedPreferences.setMockInitialValues({'auth_token': '1|test'});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(responder);
  final dio = Dio()..httpClientAdapter = adapter;
  return (AddressRepository(ApiClient(prefs: prefs, dio: dio)), adapter);
}

const AddressDraft _goodDraft = AddressDraft(
  name: 'Suraj Ojha',
  phone: '8305317276',
  email: 'suraj.ojha@uminber.in',
  state: '11',
  city: '574',
  address: '306, Jahnavi Arcade, Odhav',
  zipCode: '382415',
);

void main() {
  group('Address.fromJson — real captured rows', () {
    test('parses all 11 fields off the live payload', () {
      final a = Address.fromJson(_payloadRows().first);
      expect(a.id, 16);
      expect(a.name, 'Suraj ojha');
      expect(a.isDefault, isTrue);
      expect(a.phone, '8305317276');
      expect(a.email, 'suraj.ojha@uminber.in');
      expect(a.countryName, 'India');
      expect(a.state, '11');
      expect(a.city, '574');
      expect(a.address, '306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad');
      expect(a.zipCode, '382415');
      expect(
        a.fullAddress,
        '306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad, sda etasd, '
        'Ahmedabad, Gujarat, 382415',
      );
    });

    test('every captured row parses without throwing', () {
      final all = _payloadRows().map(Address.fromJson).toList();
      expect(all, hasLength(6));
      expect(all.map((a) => a.id), [16, 57, 50, 45, 42, 39]);
    });

    test('exactly one row is default, and it is first', () {
      final all = _payloadRows().map(Address.fromJson).toList();
      expect(all.where((a) => a.isDefault), hasLength(1));
      expect(all.first.isDefault, isTrue);
    });
  });

  group('is_default type instability', () {
    // Read gives ints; the create/update controller assigns a PHP bool before
    // serializing, so both must land on the same Dart value.
    test('accepts int 1/0', () {
      expect(Address.fromJson({'id': 1, 'is_default': 1}).isDefault, isTrue);
      expect(Address.fromJson({'id': 1, 'is_default': 0}).isDefault, isFalse);
    });

    test('accepts bool true/false', () {
      expect(Address.fromJson({'id': 1, 'is_default': true}).isDefault, isTrue);
      expect(Address.fromJson({'id': 1, 'is_default': false}).isDefault, isFalse);
    });

    test('accepts the string forms the boolean validator round-trips', () {
      expect(Address.fromJson({'id': 1, 'is_default': '1'}).isDefault, isTrue);
      expect(Address.fromJson({'id': 1, 'is_default': '0'}).isDefault, isFalse);
    });

    test('a missing key is not default', () {
      expect(Address.fromJson({'id': 1}).isDefault, isFalse);
    });
  });

  group('missing and null fields', () {
    test('an id-only object yields empty strings, never null', () {
      final a = Address.fromJson({'id': 99});
      expect(a.id, 99);
      expect(a.name, '');
      expect(a.email, '');
      expect(a.phone, '');
      expect(a.countryName, '');
      expect(a.state, '');
      expect(a.city, '');
      expect(a.address, '');
      expect(a.zipCode, '');
      expect(a.fullAddress, '');
    });

    test('explicit nulls behave like absent keys', () {
      final a = Address.fromJson({
        'id': 99,
        'name': null,
        'email': null,
        'phone': null,
        'country': null,
        'state': null,
        'city': null,
        'address': null,
        'zip_code': null,
        'full_address': null,
        'is_default': null,
      });
      expect(a.name, '');
      expect(a.isDefault, isFalse);
      expect(a.displayAddress, '');
    });

    // The column is nullable in the schema
    // (2021_11_03_..._nullable_phone_number_in_ec_customer_addresses).
    test('a null phone does not crash the model', () {
      expect(Address.fromJson({'id': 1, 'phone': null}).phone, '');
    });

    // zip_code is `nullable|string` but nothing stops a numeric column value
    // from serializing as a JSON number.
    test('a numeric zip_code coerces to a string', () {
      expect(Address.fromJson({'id': 1, 'zip_code': 382415}).zipCode, '382415');
    });

    test('a numeric id sent as a string still parses', () {
      expect(Address.fromJson({'id': '16'}).id, 16);
    });
  });

  group('ids and the names that come with them', () {
    // The columns hold foreign keys; the resource sends the resolved names
    // beside them. Nothing has to be looked up client-side any more.
    test('a row keeps the id and shows the name', () {
      final a = Address.fromJson({
        'id': 1,
        'state': '11',
        'state_name': 'Gujarat',
        'city': '574',
        'city_name': 'Ahmedabad',
      });

      expect(a.state, '11');
      expect(a.city, '574');
      expect(a.stateName, 'Gujarat');
      expect(a.cityName, 'Ahmedabad');
    });

    // Rows created through the website before the ids were enforced hold names
    // in the columns themselves. `LocationTrait` passes those through, so the
    // two agree and nothing special is needed.
    test('a row that stores names reads the same either way', () {
      final a = Address.fromJson({
        'id': 1,
        'state': 'Madhya Pradesh',
        'state_name': 'Madhya Pradesh',
        'city': 'Gwalior',
        'city_name': 'Gwalior',
      });

      expect(a.stateName, 'Madhya Pradesh');
      expect(a.cityName, 'Gwalior');
    });

    // A row cached before the server started sending the names, or one whose
    // `states` row was deleted. An id on screen is ugly; a blank line reads as
    // a missing address.
    test('falls back to the stored token when no name was sent', () {
      final a = Address.fromJson({'id': 1, 'state': '11', 'city': '574'});

      expect(a.stateName, '11');
      expect(a.cityName, '574');
    });

    test('the draft round-trips the ids, never the names', () {
      final draft = Address.fromJson({
        'id': 1,
        'state': '11',
        'state_name': 'Gujarat',
        'city': '574',
        'city_name': 'Ahmedabad',
      }).toDraft();

      // Sending "Gujarat" is a 422: `state` is `exists`-validated.
      expect(draft.state, '11');
      expect(draft.city, '574');
      expect(draft.toJson()['state'], '11');
      expect(draft.toJson()['city'], '574');
    });
  });

  group('the optional parts the app used to discard', () {
    test('landmark, district and other_city are read', () {
      final a = Address.fromJson({
        'id': 1,
        'landmark': 'near the water tank',
        'district': 'Ahmedabad district',
        'other_city': 'Tiny Village',
        'city': 'other',
      });

      expect(a.landmark, 'near the water tank');
      expect(a.district, 'Ahmedabad district');
      expect(a.otherCity, 'Tiny Village');
    });

    test('they survive a cache round trip', () {
      final a = Address.fromJson({
        'id': 1,
        'name': 'Asha',
        'state': '11',
        'state_name': 'Gujarat',
        'city': '574',
        'city_name': 'Ahmedabad',
        'landmark': 'near the water tank',
        'district': 'Ahmedabad district',
        'zip_code': '382415',
        'full_address': '1 Lane, near the water tank, Ahmedabad, Gujarat',
      });

      // Nine of the twenty-nine live rows carry a landmark the website stored.
      // Dropping it here is how saving from the app wiped it.
      expect(Address.fromJson(a.toJson()), a);
    });

    test('the draft carries them to the server', () {
      final body = Address.fromJson({
        'id': 1,
        'landmark': 'near the water tank',
        'district': 'Ahmedabad district',
      }).toDraft().toJson();

      expect(body['landmark'], 'near the water tank');
      expect(body['district'], 'Ahmedabad district');
    });
  });

  group('the "other city" hole', () {
    Address other({String otherCity = 'Tiny Village'}) => Address.fromJson({
          'id': 1,
          'state': '11',
          'state_name': 'Gujarat',
          'city': 'other',
          // What the server actually returns for such a row — the literal
          // word, not the town.
          'city_name': 'other',
          'other_city': otherCity,
          'address': '1 Lane',
          'zip_code': '382415',
          'full_address': '1 Lane, other, Gujarat, 382415',
        });

    test('is recognised', () {
      expect(other().isOtherCity, isTrue);
      expect(
        Address.fromJson({'id': 1, 'city': '574'}).isOtherCity,
        isFalse,
      );
    });

    test('shows the town, not the word "other"', () {
      expect(other().cityName, 'Tiny Village');
    });

    // Verified live: POST with `city: "other"` returns
    // `full_address: "1 Lane, other, Gujarat, 382415"`. Printing that verbatim
    // shows a customer "other" where their town should be.
    test('is substituted into the server-rendered line', () {
      expect(other().displayAddress, '1 Lane, Tiny Village, Gujarat, 382415');
    });

    test('leaves the line alone when there is no town to put back', () {
      expect(other(otherCity: '').displayAddress, '1 Lane, other, Gujarat, 382415');
    });

    // Only a whole segment is replaced, and only the first one.
    test('does not maul a street that contains the word', () {
      final a = Address.fromJson({
        'id': 1,
        'city': 'other',
        'other_city': 'Tiny Village',
        'address': 'Other Lane',
        'full_address': 'Other Lane, other, Gujarat, 382415',
      });

      expect(a.displayAddress, 'Other Lane, Tiny Village, Gujarat, 382415');
    });

    test('an ordinary row is never rewritten', () {
      final a = Address.fromJson({
        'id': 1,
        'city': '574',
        'city_name': 'Ahmedabad',
        'address': '1 Lane',
        'full_address': '1 Lane, Ahmedabad, Gujarat, 382415',
      });

      expect(a.displayAddress, '1 Lane, Ahmedabad, Gujarat, 382415');
    });
  });

  group('regionLine', () {
    test('strips the street prefix', () {
      final a = Address.fromJson(_payloadRows()[2]);
      expect(a.regionLine, 'Gwalior, Madhya Pradesh, 474010');
    });

    // full_address can carry segments the row does not expose (a landmark),
    // so the remainder must be taken verbatim, not reconstructed.
    test('keeps extra server-side segments the row does not have', () {
      final a = Address.fromJson(_payloadRows()[3]); // id 45
      expect(a.regionLine, 'near palican paradise, Ahmedabad, Gujarat, 382350');
    });

    test('falls back to the whole string when the prefix does not match', () {
      final a = Address.fromJson({
        'id': 1,
        'address': 'Something else entirely',
        'full_address': 'Gwalior, Madhya Pradesh',
      });
      expect(a.regionLine, 'Gwalior, Madhya Pradesh');
    });

    test('is empty when there is nothing but the street line', () {
      final a = Address.fromJson({'id': 1, 'address': 'X', 'full_address': 'X'});
      expect(a.regionLine, '');
    });
  });

  group('round-trip', () {
    test('toJson/fromJson preserves every field', () {
      final a = Address.fromJson(_payloadRows().first);
      final b = Address.fromJson(a.toJson());
      expect(b.id, a.id);
      expect(b.isDefault, a.isDefault);
      expect(b.state, a.state);
      expect(b.city, a.city);
      expect(b.fullAddress, a.fullAddress);
    });

    test('toDraft drops full_address, which PUT has no field for', () {
      final draft = Address.fromJson(_payloadRows().first).toDraft();
      expect(draft.toJson().containsKey('full_address'), isFalse);
      expect(draft.toJson().containsKey('id'), isFalse);
      expect(draft.state, '11');
      expect(draft.city, '574');
    });
  });

  group('AddressDraft.toJson wire types', () {
    test('phone is a String — a JSON number is rejected by the server', () {
      expect(_goodDraft.toJson()['phone'], isA<String>());
    });

    test('is_default is a JSON bool, never "true"', () {
      // Verified live: {"is_default":"true"} -> 422 "The is default field must
      // be true or false."; {"is_default":"1"} is accepted.
      expect(_goodDraft.copyWith(isDefault: true).toJson()['is_default'], true);
      expect(
        _goodDraft.copyWith(isDefault: true).toJson()['is_default'],
        isA<bool>(),
      );
      expect(
        _goodDraft.copyWith(isDefault: false).toJson()['is_default'],
        false,
      );
    });

    // `is_default` is ['boolean'] on PUT and ['nullable','boolean'] on POST —
    // neither is required, so an omitted key is legal and Laravel's validated()
    // excludes it from $address->update(), preserving the stored flag. Sending
    // a hardcoded false here demotes whatever the customer had chosen.
    test('is_default is omitted entirely when the draft does not assert it', () {
      expect(_goodDraft.isDefault, isNull);
      expect(_goodDraft.toJson().containsKey('is_default'), isFalse);
    });

    test('trims every text field', () {
      const d = AddressDraft(name: '  Asha  ', phone: ' 9876543210 ');
      expect(d.toJson()['name'], 'Asha');
      expect(d.toJson()['phone'], '9876543210');
    });

    test('sends the writable keys and nothing else', () {
      expect(
        _goodDraft.copyWith(isDefault: false).toJson().keys.toSet(),
        {
          'name',
          'phone',
          'email',
          'state',
          'city',
          'address',
          'zip_code',
          'district',
          'landmark',
          'is_default',
        },
      );
    });

    test('a draft seeded from a row carries that row\'s flag explicitly', () {
      final row = Address.fromJson(_payloadRows().first); // id 16, default
      expect(row.toDraft().isDefault, isTrue);
      expect(row.toDraft().toJson()['is_default'], true);
      final other = Address.fromJson(_payloadRows()[2]); // id 50, not default
      expect(other.toDraft().toJson()['is_default'], false);
    });
  });

  group('AddressDraft validation — the PUT rules applied at POST time', () {
    test('a complete draft is valid', () {
      expect(_goodDraft.validationErrors(), isEmpty);
      expect(_goodDraft.isValid, isTrue);
    });

    // POST and PUT now share one rule set — re-probed live by sending an empty
    // body to each, and both answer with the same six field names. The old
    // asymmetry (POST needing only {name, phone}) is what allowed a row to be
    // created that could never afterwards be edited.
    test('the six the server requires are the six this refuses without', () {
      const d = AddressDraft();

      expect(
        d.validationErrors().keys.toSet(),
        containsAll(['name', 'phone', 'state', 'city', 'address', 'zip_code']),
      );
    });

    // This used to assert the opposite, on the claim that "checkout refuses an
    // address with no email". The claim was wrong — verified against the
    // backend source and the live database: `CheckoutRequest` marks the field
    // `nullable`, the live validator passes an email-less address, and order
    // mail goes to `$order->user->email` first. The app no longer collects one.
    test('a blank email is accepted, like the server accepts it', () {
      expect(
        _goodDraft.copyWith(email: '').validationErrors(),
        isNot(contains('email')),
      );
    });

    // A malformed one is still worth catching, for any path that supplies it.
    test('a malformed email is still rejected', () {
      expect(
        _goodDraft.copyWith(email: 'not-an-email').validationErrors(),
        contains('email'),
      );
    });

    // `state` is `exists`-validated: "Gujarat" answers 422 "The selected state
    // is invalid." A form that let someone type it would be unsaveable, so the
    // draft refuses it before the request.
    test('a state NAME is refused, an id is accepted', () {
      expect(
        _goodDraft.copyWith(state: 'Gujarat').validationErrors(),
        contains('state'),
      );
      expect(_goodDraft.copyWith(state: '11').validationErrors(), isEmpty);
    });

    // Nothing validates `city` server-side — a bogus id is stored and rendered
    // back verbatim — so the picker is the only guard and the draft only
    // insists that something was chosen.
    test('a missing city is refused', () {
      expect(_goodDraft.copyWith(city: '').validationErrors(), contains('city'));
    });

    group('other_city', () {
      test('is required when the city is "other"', () {
        final d = _goodDraft.copyWith(city: 'other');

        expect(d.isOtherCity, isTrue);
        expect(d.validationErrors(), contains('other_city'));
        expect(
          d.copyWith(otherCity: 'Tiny Village').validationErrors(),
          isEmpty,
        );
      });

      test('is only sent for an other-city row', () {
        // Recording a town beside a real city id would name a place the
        // address is not in.
        expect(
          _goodDraft
              .copyWith(otherCity: 'Tiny Village')
              .toJson()
              .containsKey('other_city'),
          isFalse,
        );
        expect(
          _goodDraft
              .copyWith(city: 'other', otherCity: 'Tiny Village')
              .toJson()['other_city'],
          'Tiny Village',
        );
      });

      test('is capped at 120 like the rest', () {
        expect(
          _goodDraft
              .copyWith(city: 'other', otherCity: 'x' * 121)
              .validationErrors(),
          contains('other_city'),
        );
      });
    });

    test('landmark and district are optional but capped at 120', () {
      expect(_goodDraft.copyWith(landmark: 'x' * 120).validationErrors(), isEmpty);
      expect(
        _goodDraft.copyWith(landmark: 'x' * 121).validationErrors(),
        contains('landmark'),
      );
      expect(
        _goodDraft.copyWith(district: 'x' * 121).validationErrors(),
        contains('district'),
      );
    });

    // It used to be `nullable`, which is exactly how PIN-less rows nobody can
    // quote shipping for got into real address books.
    test('zip_code is required now', () {
      expect(
        _goodDraft.copyWith(zipCode: '').validationErrors(),
        contains('zip_code'),
      );
    });

    // The store ships in one country, the server fills `country_id` from its
    // own setting, and anything sent is ignored — verified by POSTing with and
    // without it and getting the same `country_id: "IN"` back. The app used to
    // send the rendered NAME, which destroyed the stored id.
    test('country is never sent', () {
      expect(_goodDraft.toJson().containsKey('country'), isFalse);
    });

    group('toCheckoutJson', () {
      // The regression this whole method exists to prevent: a shipped bug
      // where checkout's own rules ran straight against `toJson()`, which has
      // no `country` key, and reported an otherwise-complete address as
      // "Cannot be delivered to (Enter the country)" — for the one field this
      // app never collects and the server never asks for.
      test('a complete draft passes the checkout rules', () {
        expect(
          CheckoutAddressRules.isValidJson(_goodDraft.toCheckoutJson()),
          isTrue,
        );
      });

      test('adds the country the write shape omits', () {
        final json = _goodDraft.toCheckoutJson();

        expect(json['country'], CheckoutAddressRules.shipsToCountry);
        expect(json.containsKey('country'), isTrue);
      });

      test('carries every other field toJson would', () {
        final json = _goodDraft.toCheckoutJson();
        final base = _goodDraft.toJson();

        for (final key in base.keys) {
          expect(json[key], base[key], reason: 'key: $key');
        }
      });
    });

    for (final bad in const [
      ('', 'empty'),
      ('987654321', '9 digits'),
      ('98765432101', '11 digits'),
      ('5876543210', 'leading 5'),
      ('1234567890', 'landline'),
      ('+919876543210', 'with +91'),
      ('98765 43210', 'spaced'),
      ('abcdefghij', 'letters'),
    ]) {
      test('phone rejects ${bad.$2}', () {
        expect(
          _goodDraft.copyWith(phone: bad.$1).validationErrors(),
          contains('phone'),
        );
      });
    }

    for (final good in const ['6000000000', '7000000000', '8305317276', '9876543210']) {
      test('phone accepts $good', () {
        expect(
          _goodDraft.copyWith(phone: good).validationErrors().containsKey('phone'),
          isFalse,
        );
      });
    }

    test('enforces the tighter 191-char limit, not PUT\'s 255', () {
      final long = 'x' * 192;
      expect(
        _goodDraft.copyWith(address: long).validationErrors(),
        contains('address'),
      );
      expect(
        _goodDraft.copyWith(address: 'x' * 191).validationErrors().containsKey('address'),
        isFalse,
      );
    });

    test('caps region fields at 120', () {
      expect(
        _goodDraft.copyWith(city: 'x' * 121).validationErrors(),
        contains('city'),
      );
    });

    test('caps email at 60', () {
      expect(
        _goodDraft.copyWith(email: '${'x' * 55}@b.com').validationErrors(),
        contains('email'),
      );
    });

    test('caps zip_code at 20', () {
      expect(
        _goodDraft.copyWith(zipCode: '1' * 21).validationErrors(),
        contains('zip_code'),
      );
    });

    // `city` has no lookup rule server-side, so a value the app did not choose
    // from the list still passes. `state` does not — see above.
    test('accepts a city token the server has no lookup for', () {
      expect(_goodDraft.copyWith(city: 'ZZZ').validationErrors(), isEmpty);
    });
  });

  group('Address equality', () {
    // setDefault changes nothing but is_default; an id-only == would report the
    // before/after rows as equal and suppress the badge-moving rebuild.
    test('an is_default flip is not equal to the original', () {
      final a = Address.fromJson(_payloadRows()[2]);
      expect(a.copyWith(isDefault: true), isNot(equals(a)));
      expect(a.copyWith(isDefault: true).hashCode, isNot(a.hashCode));
    });

    test('identical field sets are equal', () {
      expect(
        Address.fromJson(_payloadRows().first),
        Address.fromJson(_payloadRows().first),
      );
    });

    test('isSameRow still compares identity only', () {
      final a = Address.fromJson(_payloadRows()[2]);
      expect(a.isSameRow(a.copyWith(isDefault: true)), isTrue);
    });
  });

  group('AddressRepository.page', () {
    test('parses the hybrid envelope and its meta', () async {
      final (repo, adapter) = await _repo(
        (_) => _Canned(200, jsonDecode(_addressesPayload)),
      );
      final res = await repo.page();
      expect(res.items, hasLength(6));
      expect(res.meta.total, 6);
      expect(res.meta.perPage, 10);
      expect(res.hasMore, isFalse);
      expect(adapter.requests.single.path, '/ecommerce/addresses');
    });

    test('sends page but never per_page — the server ignores it', () async {
      final (repo, adapter) = await _repo(
        (_) => _Canned(200, jsonDecode(_addressesPayload)),
      );
      await repo.page(page: 2);
      final query = adapter.requests.single.queryParameters;
      expect(query['page'], 2);
      expect(query.containsKey('per_page'), isFalse);
    });

    test('an empty book yields no items and no crash', () async {
      final (repo, _) = await _repo((_) => _Canned(200, jsonDecode(_emptyPayload)));
      final res = await repo.page();
      expect(res.items, isEmpty);
      expect(res.meta.total, 0);
      expect(res.meta.from, isNull);
      expect(res.hasMore, isFalse);
    });

    test('survives a body with no meta at all', () async {
      final (repo, _) = await _repo(
        (_) => const _Canned(200, {
          'error': false,
          'data': [
            {'id': 1, 'name': 'A', 'is_default': 1},
          ],
          'message': null,
        }),
      );
      final res = await repo.page();
      expect(res.items, hasLength(1));
      expect(res.meta.total, 1);
    });

    // PaginatedResponse.fromJson casts `json['data'] as List?`. This backend
    // flips collection fields between array and object shapes elsewhere
    // (cart_items is a map when populated, `[]` when empty), so an object here
    // must not become a TypeError.
    test('an object-shaped data field does not throw', () async {
      final (repo, _) = await _repo(
        (_) => const _Canned(200, {
          'error': false,
          'data': {'id': 16, 'city': 'Gwalior', 'is_default': 1},
          'message': null,
        }),
      );
      final res = await repo.page();
      expect(res.items.single.id, 16);
    });

    test('an unrecognised data shape yields an empty page, not a crash', () async {
      final (repo, _) = await _repo(
        (_) => const _Canned(200, {
          'error': false,
          'data': 'Address deleted successfully',
          'message': null,
        }),
      );
      expect((await repo.page()).items, isEmpty);
    });

    test('a bare list body still parses', () async {
      final (repo, _) = await _repo(
        (_) => const _Canned(200, [
          {'id': 7, 'name': 'A'},
        ]),
      );
      final res = await repo.page();
      expect(res.items.single.id, 7);
    });

    test('a 401 surfaces as unauthorized even though error is a String', () async {
      final (repo, _) = await _repo(
        (_) => const _Canned(401, {
          'message': 'Unauthenticated.',
          'error': 'Unauthorized',
        }),
      );
      try {
        await repo.page();
        fail('expected an ApiException');
      } on ApiException catch (e) {
        expect(e.kind, ApiErrorKind.unauthorized);
      }
    });
  });

  group('AddressRepository.all — pagination is fixed at 10/page', () {
    test('walks every page', () async {
      final (repo, adapter) = await _repo((options) {
        final page = int.parse(options.uri.queryParameters['page'] ?? '1');
        return _Canned(200, {
          'data': [
            {'id': page * 100, 'name': 'row $page'},
          ],
          'meta': {'current_page': page, 'last_page': 3, 'per_page': 10, 'total': 3},
          'error': false,
          'message': null,
        });
      });

      final all = await repo.all();
      expect(all.map((a) => a.id), [100, 200, 300]);
      expect(adapter.requests, hasLength(3));
    });

    test('stops after one request when there is one page', () async {
      final (repo, adapter) = await _repo(
        (_) => _Canned(200, jsonDecode(_addressesPayload)),
      );
      expect(await repo.all(), hasLength(6));
      expect(adapter.requests, hasLength(1));
    });

    // The old walker followed meta.current_page + 1. A server that pins
    // current_page at 1 (or a `latest()` tie that repeats a row across pages)
    // made it request the same page over and over and append the same row 20
    // times — no error, just a picker full of duplicates.
    test('never returns the same address twice', () async {
      final (repo, adapter) = await _repo(
        (_) => const _Canned(200, {
          'data': [
            {'id': 16, 'name': 'A'},
            {'id': 57, 'name': 'B'},
          ],
          'meta': {
            'current_page': 1,
            'last_page': 9999,
            'per_page': 10,
            'total': 2,
          },
          'error': false,
          'message': null,
        }),
      );
      final all = await repo.all();
      expect(all.map((a) => a.id), [16, 57]);
      // It must also notice that the page contributed nothing new and stop.
      expect(adapter.requests, hasLength(2));
    });

    test('asks for pages by a local counter, not the server-echoed one', () async {
      final (repo, adapter) = await _repo((options) {
        final page = int.parse(options.uri.queryParameters['page'] ?? '1');
        return _Canned(200, {
          'data': [
            if (page <= 3) {'id': page},
          ],
          // Deliberately wrong: current_page never advances, so following it
          // would re-request page 2 until the safety valve tripped.
          'meta': {
            'current_page': 1,
            'last_page': 9999,
            'per_page': 10,
            'total': 3,
          },
          'error': false,
          'message': null,
        });
      });
      final all = await repo.all();
      expect(all.map((a) => a.id), [1, 2, 3]);
      expect(
        adapter.requests.map((r) => r.uri.queryParameters['page']),
        ['1', '2', '3', '4'],
      );
    });

    test('is bounded when the server never stops advancing', () async {
      final (repo, adapter) = await _repo(
        (options) => _Canned(200, {
          'data': [
            {'id': int.parse(options.uri.queryParameters['page'] ?? '1')},
          ],
          'meta': {'current_page': 1, 'last_page': 9999, 'per_page': 10, 'total': 1},
          'error': false,
          'message': null,
        }),
      );
      await repo.all();
      expect(adapter.requests.length, lessThanOrEqualTo(20));
    });
  });

  group('AddressRepository.find — no GET-one route exists', () {
    test('filters the collection client-side', () async {
      final (repo, adapter) = await _repo(
        (_) => _Canned(200, jsonDecode(_addressesPayload)),
      );
      final found = await repo.find(50);
      expect(found?.city, 'Gwalior');
      // It must never hit /ecommerce/addresses/50 — that route is not registered.
      expect(adapter.requests.single.path, '/ecommerce/addresses');
    });

    test('returns null for an id the customer does not own', () async {
      final (repo, _) = await _repo((_) => _Canned(200, jsonDecode(_addressesPayload)));
      expect(await repo.find(999), isNull);
    });

    // An 11th address lands on page 2, which the test account never had.
    test('finds a row that is not on the first page', () async {
      final (repo, adapter) = await _repo((options) {
        final page = int.parse(options.uri.queryParameters['page'] ?? '1');
        return _Canned(200, {
          'data': [
            {'id': page == 1 ? 16 : 99, 'city': page == 1 ? 'A' : 'Indore'},
          ],
          'meta': {
            'current_page': page,
            'last_page': 2,
            'per_page': 10,
            'total': 2,
          },
          'error': false,
          'message': null,
        });
      });
      expect((await repo.find(99))?.city, 'Indore');
      expect(adapter.requests, hasLength(2));
    });
  });

  group('AddressRepository.defaultAddress', () {
    test('returns the flagged row', () async {
      final (repo, _) = await _repo((_) => _Canned(200, jsonDecode(_addressesPayload)));
      expect((await repo.defaultAddress())?.id, 16);
    });

    test('falls back to the first row when none is flagged', () async {
      final (repo, _) = await _repo(
        (_) => const _Canned(200, {
          'data': [
            {'id': 3, 'is_default': 0},
            {'id': 4, 'is_default': 0},
          ],
          'error': false,
        }),
      );
      expect((await repo.defaultAddress())?.id, 3);
    });

    test('returns null for an empty book', () async {
      final (repo, _) = await _repo((_) => _Canned(200, jsonDecode(_emptyPayload)));
      expect(await repo.defaultAddress(), isNull);
    });
  });

  group('AddressRepository writes', () {
    test('rejects an invalid draft before touching the network', () async {
      final (repo, adapter) = await _repo((_) => const _Canned(200, {}));
      try {
        await repo.create(const AddressDraft(name: 'A', phone: '123'));
        fail('expected an ApiException');
      } on ApiException catch (e) {
        expect(e.kind, ApiErrorKind.validation);
        expect(e.fieldErrors, contains('phone'));
      }
      expect(adapter.requests, isEmpty);
    });

    test('POSTs the draft body to the collection route', () async {
      final (repo, adapter) = await _repo(
        (_) => const _Canned(200, {
          'error': false,
          'data': {'id': 61, 'name': 'Suraj Ojha', 'is_default': true},
          'message': null,
        }),
      );
      final created = await repo.create(_goodDraft);
      expect(created?.id, 61);
      // The controller assigns a PHP bool here, unlike the list route's 1/0.
      expect(created?.isDefault, isTrue);
      expect(adapter.requests.single.method, 'POST');
      expect(adapter.requests.single.path, '/ecommerce/addresses');
      expect((adapter.requests.single.data as Map)['phone'], '8305317276');
    });

    test('PUTs to the id route', () async {
      final (repo, adapter) = await _repo(
        (_) => const _Canned(200, {
          'error': false,
          'data': {'id': 16, 'is_default': 1},
          'message': null,
        }),
      );
      expect((await repo.update(16, _goodDraft))?.id, 16);
      expect(adapter.requests.single.method, 'PUT');
      expect(adapter.requests.single.path, '/ecommerce/addresses/16');
    });

    // The write response shape is UNVERIFIED, so an unexpected body must not
    // throw — the row was already saved by then.
    test('returns null rather than throwing on an unrecognised body', () async {
      final (repo, _) = await _repo(
        (_) => const _Canned(200, {'error': false, 'data': null, 'message': null}),
      );
      expect(await repo.create(_goodDraft), isNull);
    });

    test('parses a bare object with no envelope', () async {
      final (repo, _) = await _repo(
        (_) => const _Canned(200, {'id': 62, 'name': 'X', 'is_default': 0}),
      );
      expect((await repo.create(_goodDraft))?.id, 62);
    });

    test('a 422 field bag reaches the caller intact', () async {
      final (repo, _) = await _repo(
        (_) => const _Canned(422, {
          'message': 'The phone format is invalid.',
          'errors': {
            'phone': ['The phone format is invalid.'],
          },
        }),
      );
      try {
        await repo.create(_goodDraft);
        fail('expected an ApiException');
      } on ApiException catch (e) {
        expect(e.kind, ApiErrorKind.validation);
        expect(e.fieldErrors?['phone'], ['The phone format is invalid.']);
      }
    });

    // There is no PATCH and no dedicated route, so the whole row goes back.
    test('setDefault re-sends the whole row', () async {
      final (repo, adapter) = await _repo(
        (_) => const _Canned(200, {'error': false, 'data': {'id': 45}}),
      );
      final row = Address.fromJson(_payloadRows()[3]); // id 45, not default
      await repo.setDefault(row);
      final body = adapter.requests.single.data as Map;
      expect(body['is_default'], true);
      expect(body['name'], 'Suraj ojha');
      expect(body['state'], '11', reason: 'the id, not "Gujarat"');
      expect(body['city'], '574');
      expect(body['address'], '401 ganesh rivera');
    });

    // Row 50 stores `state: "Madhya Pradesh"` — a name, which the website used
    // to allow and the server now rejects with "The selected state is
    // invalid." Refusing before sending produces the same outcome with a
    // message that names the field; the row has to be edited and its state
    // re-picked before it can be promoted.
    test('a legacy row that stores a state NAME is refused, not sent',
        () async {
      final (repo, adapter) = await _repo(
        (_) => const _Canned(200, {'error': false, 'data': {'id': 50}}),
      );
      final row = Address.fromJson(_payloadRows()[2]); // id 50

      await expectLater(
        repo.setDefault(row),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiErrorKind.validation)
              .having((e) => e.fieldErrors?.keys, 'fields', contains('state')),
        ),
      );
      expect(adapter.requests, isEmpty);
    });

    // Rows created through the lenient POST rules can lack an email, and no
    // PUT can ever save them. Failing locally with the field name is the same
    // answer the server would give, one round trip earlier.
    test('setDefault on an unpatchable legacy row reports the missing field', () async {
      final (repo, adapter) = await _repo((_) => const _Canned(200, {}));
      final row = Address.fromJson({'id': 9, 'name': 'A', 'phone': '9876543210'});
      try {
        await repo.setDefault(row);
        fail('expected an ApiException');
      } on ApiException catch (e) {
        // `address`, not `email`: a blank email is legal on this backend, so
        // the pre-flight no longer reports one. The street line is genuinely
        // required, and this row has none — which is what makes it unpatchable.
        expect(e.fieldErrors, contains('address'));
      }
      expect(adapter.requests, isEmpty);
    });

    test('delete returns the server message', () async {
      final (repo, adapter) = await _repo(
        (_) => const _Canned(200, {
          'error': false,
          'data': null,
          'message': 'Address deleted successfully',
        }),
      );
      expect(await repo.delete(39), 'Address deleted successfully');
      expect(adapter.requests.single.method, 'DELETE');
      expect(adapter.requests.single.path, '/ecommerce/addresses/39');
    });

    test('delete tolerates a message-less body', () async {
      final (repo, _) = await _repo((_) => const _Canned(200, {'error': false}));
      expect(await repo.delete(39), isNull);
    });

    // DELETE /ecommerce/cart answers with a bare JSON string. Nothing says this
    // route cannot do the same, and a bare String is not a Map.
    test('delete tolerates a bare-string body', () async {
      final (repo, _) = await _repo(
        (_) => const _Canned(200, '"Address deleted successfully"'),
      );
      expect(await repo.delete(39), isNull);
    });

    // A 200 carrying error:true is this backend's second failure channel;
    // ApiClient turns it into a businessRule ApiException before the repository
    // ever parses a row.
    test('a 200 with error:true is raised, not treated as a saved row', () async {
      final (repo, _) = await _repo(
        (_) => const _Canned(200, {
          'error': true,
          'data': null,
          'message': 'Address limit reached!',
        }),
      );
      try {
        await repo.create(_goodDraft);
        fail('expected an ApiException');
      } on ApiException catch (e) {
        expect(e.kind, ApiErrorKind.businessRule);
        expect(e.message, 'Address limit reached!');
      }
    });

    test('deleting an id that is not ours 404s', () async {
      final (repo, _) = await _repo(
        (_) => const _Canned(404, {'message': 'No query results for model.'}),
      );
      try {
        await repo.delete(1);
        fail('expected an ApiException');
      } on ApiException catch (e) {
        expect(e.kind, ApiErrorKind.notFound);
      }
    });
  });
}

/// Searching the address book.
///
/// The rule that makes or breaks this: `state` and `city` hold **opaque geo
/// ids** — `"11"` for Gujarat, `"574"` for Ahmedabad — while the card on screen
/// reads the resolved names. A search over the stored fields finds nothing for
/// the very words the customer is looking at, which is why [Address.matches]
/// runs over [Address.searchHaystack] and that is built from the shown values.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/address.dart';

/// A row in the shape the server actually returns: ids in `state`/`city`, names
/// alongside them, and a server-rendered `full_address`.
Address _address({
  int id = 16,
  String name = 'Suraj ojha',
  String phone = '8305317276',
  String street = '306, Jahnavi Arcade',
  String landmark = '',
  String cityName = 'Ahmedabad',
  String stateName = 'Gujarat',
  String zip = '382415',
}) =>
    Address.fromJson({
      'id': id,
      'name': name,
      'phone': phone,
      'email': 'suraj.ojha@uminber.in',
      // The opaque ids, exactly as stored.
      'state': '11',
      'city': '574',
      'state_name': stateName,
      'city_name': cityName,
      'address': street,
      'landmark': landmark,
      'zip_code': zip,
      'country': 'IN',
      'country_name': 'India',
      'full_address': [
        street,
        if (landmark.isNotEmpty) landmark,
        cityName,
        stateName,
        zip,
      ].join(', '),
      'is_default': 0,
    });

void main() {
  group('it searches what the card shows, not what is stored', () {
    test('the city name finds it — the stored value is "574"', () {
      final row = _address();

      expect(row.city, '574', reason: 'the premise');
      expect(row.matches('ahmedabad'), isTrue);
      // ...and the id itself is not what a customer would ever type.
      expect(row.matches('gujarat'), isTrue);
      expect(row.state, '11', reason: 'the premise');
    });

    test('an other-city row is found by the town the customer typed', () {
      // The server writes the literal word "other" in the city slot, and
      // `displayAddress` puts the real town back.
      final row = Address.fromJson({
        'id': 21,
        'name': 'Warehouse',
        'phone': '9812345670',
        'state': '11',
        'city': 'other',
        'state_name': 'Gujarat',
        'city_name': 'other',
        'other_city': 'Kadi',
        'address': 'Plot 4, GIDC',
        'zip_code': '382715',
        'country_name': 'India',
        'full_address': 'Plot 4, GIDC, other, Gujarat, 382715',
        'is_default': 0,
      });

      expect(row.matches('kadi'), isTrue);
    });
  });

  group('what a customer types', () {
    test('name, phone, street, landmark and PIN all find it', () {
      final row = _address(landmark: 'Near Odhav Circle');

      for (final query in [
        'suraj',
        '8305317276',
        'jahnavi',
        'odhav',
        '382415',
      ]) {
        expect(row.matches(query), isTrue, reason: query);
      }
    });

    test('case does not matter', () {
      expect(_address().matches('AHMEDABAD'), isTrue);
      expect(_address().matches('AhMeDaBaD'), isTrue);
    });

    test('several words match in any order', () {
      // How people actually type an address. A single blob-contains would fail
      // the first of these two.
      final row = _address();

      expect(row.matches('ahmedabad 382415'), isTrue);
      expect(row.matches('382415 ahmedabad'), isTrue);
      // ...and every term still has to be there.
      expect(row.matches('ahmedabad 400001'), isFalse);
    });

    test('a blank query is everything, not nothing', () {
      // The screen shows the whole book rather than an empty list.
      for (final blank in ['', '   ', '\t']) {
        expect(_address().matches(blank), isTrue, reason: '"$blank"');
      }
    });

    test('a word that is nowhere finds nothing', () {
      expect(_address().matches('mumbai'), isFalse);
      expect(_address().matches('zzzz'), isFalse);
    });
  });

  test('two addresses at one house are told apart by name and phone', () {
    // The everyday case for an address book: same street, different person.
    final mum = _address(id: 1, name: 'Mum', phone: '9876543210');
    final office = _address(id: 2, name: 'Office', phone: '9812345670');

    expect(mum.matches('mum'), isTrue);
    expect(office.matches('mum'), isFalse);
    expect(office.matches('9812345670'), isTrue);
    expect(mum.matches('9812345670'), isFalse);
  });
}

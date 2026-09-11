import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/order.dart';
import 'package:trueway_farms/data/repositories/checkout_repository.dart';

/// The three optional address parts — `landmark`, `district`, `other_city` —
/// as they travel from the address book, through checkout, onto the order.
///
/// They existed on the server all along and the app discarded them at every
/// step: the write shape omitted them, the checkout body omitted them, and the
/// order block never looked for them. Nine of the twenty-nine live address rows
/// carry a landmark the website stored, and saving from the app wiped it.

void main() {
  group('the checkout body', () {
    CheckoutAddress address({
      String landmark = '',
      String district = '',
      String otherCity = '',
      String city = '574',
    }) =>
        CheckoutAddress(
          name: 'Suraj ojha',
          email: 'suraj.ojha@uminber.in',
          phone: '9876543210',
          address: '306, Jahnavi Arcade',
          city: city,
          state: '11',
          zipCode: '382415',
          landmark: landmark,
          district: district,
          otherCity: otherCity,
        );

    test('carries the landmark the saved address holds', () {
      final body = address(landmark: 'opposite the bus stand').toJson();

      // Often the only reason the courier finds the door.
      expect(body['landmark'], 'opposite the bus stand');
    });

    test('carries the district', () {
      expect(address(district: 'Ahmedabad').toJson()['district'], 'Ahmedabad');
    });

    test('names the town when the city is the "other" sentinel', () {
      final body =
          address(city: 'other', otherCity: 'Tiny Village').toJson();

      expect(body['city'], 'other');
      expect(body['other_city'], 'Tiny Village');
    });

    // A manually-typed checkout address collects none of the three. Sending
    // them blank would overwrite whatever the order already had with "".
    test('omits the empty ones rather than sending blanks', () {
      final body = address().toJson();

      expect(body.containsKey('landmark'), isFalse);
      expect(body.containsKey('district'), isFalse);
      expect(body.containsKey('other_city'), isFalse);
    });

    // Checkout validates none of the three — `OrderAddress::$fillable` takes
    // `landmark` straight off the raw input — so an over-long value is a DB
    // error and a 500 *after* the order row has been written.
    test('caps them at the 120 the column holds', () {
      final body = address(landmark: 'x' * 500).toJson();

      expect((body['landmark'] as String).length, 120);
    });

    test('trims them, because the rules were checked against trimmed input',
        () {
      expect(
        address(landmark: '  near the gate  ').toJson()['landmark'],
        'near the gate',
      );
    });

    // The address endpoints stopped accepting one and the server fills
    // `country_id` itself, but the checkout body still carries the field.
    test('still sends a country, defaulted rather than collected', () {
      expect(address().toJson()['country'], 'India');
    });
  });

  group('the order address block', () {
    OrderContact contact(Map<String, dynamic> extra) => OrderContact.fromJson({
          'name': 'Suraj ojha',
          'address': '306, Jahnavi Arcade',
          'city': 'Ahmedabad',
          'state': 'Gujarat',
          'zip_code': '382415',
          ...extra,
        })!;

    test('reads the new keys', () {
      final c = contact({
        'landmark': 'near the water tank',
        'district': 'Ahmedabad district',
        'other_city': 'Tiny Village',
      });

      expect(c.landmark, 'near the water tank');
      expect(c.district, 'Ahmedabad district');
      expect(c.otherCity, 'Tiny Village');
    });

    test('an absent key is null, not a failure', () {
      final c = contact(const {});

      expect(c.district, isNull);
      expect(c.otherCity, isNull);
      expect(c.fullAddress, isNull);
    });

    // The server orders the segments the way the courier reads them, and it is
    // the same string the website prints.
    test('prefers the server-rendered line when there is one', () {
      final c = contact({
        'full_address': '306, Jahnavi Arcade, near the water tank, '
            'Ahmedabad, Gujarat, 382415',
      });

      expect(
        c.streetLine,
        '306, Jahnavi Arcade, near the water tank, Ahmedabad, Gujarat, 382415',
      );
    });

    // Every cached order, and the public tracking route.
    test('composes the line itself when the resource sent none', () {
      final c = contact({'landmark': 'near the water tank'});

      expect(
        c.streetLine,
        '306, Jahnavi Arcade, near the water tank, Ahmedabad, Gujarat, 382415',
      );
    });

    group('an other-city order', () {
      test('shows the town in place of the word "other"', () {
        final c = contact({
          'city': 'other',
          'other_city': 'Tiny Village',
          'full_address': '306, Jahnavi Arcade, other, Gujarat, 382415',
        });

        expect(
          c.streetLine,
          '306, Jahnavi Arcade, Tiny Village, Gujarat, 382415',
        );
      });

      test('does the same when composing the line itself', () {
        final c = contact({'city': 'other', 'other_city': 'Tiny Village'});

        expect(c.streetLine, contains('Tiny Village'));
        expect(c.streetLine, isNot(contains('other')));
      });

      test('leaves the line alone when no town was recorded', () {
        final c = contact({
          'city': 'other',
          'full_address': '306, Jahnavi Arcade, other, Gujarat, 382415',
        });

        expect(c.streetLine, contains('other'));
      });
    });

    // A geo id is still skipped when the line has to be composed — the
    // tracking route serves raw ids into this same class.
    test('a raw geo id is still kept out of a composed line', () {
      final c = OrderContact.fromJson({
        'address': '306, Jahnavi Arcade',
        'city': '574',
        'state': '11',
        'zip_code': '382415',
      })!;

      expect(c.streetLine, '306, Jahnavi Arcade, 382415');
    });
  });
}

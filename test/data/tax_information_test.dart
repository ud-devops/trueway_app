/// The GST invoice block, against the server's own rules.
///
/// The rules are not invented here — `CheckoutRequest::rules()` is shared by
/// the web checkout and `POST /checkout/cart/{id}`, so these are the same four
/// `required_if:with_tax_information,1` fields the website enforces:
///
/// | field              | server rule            |
/// |--------------------|------------------------|
/// | `company_name`     | string, min 3, max 120 |
/// | `company_address`  | string, min 3, max 255 |
/// | `company_tax_code` | string, min 3, max 20  |
/// | `company_email`    | `EmailRule`            |
///
/// What this file is really pinning is that **there is no partial block**. The
/// cart used to collect a GSTIN alone and send it nowhere; the row it now fills
/// (`ec_order_tax_information`) has four NOT NULL columns and is written with a
/// single `create()`, so three of four is a row no invoice can be raised from.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/tax_information.dart';

TaxInformation _complete({
  String name = 'Uminber India Pvt Ltd',
  String address = '306, Jahnavi Arcade, Ahmedabad',
  String taxCode = '27AAPFU0939F1Z5',
  String email = 'billing@uminber.in',
}) =>
    TaxInformation(
      companyName: name,
      companyAddress: address,
      companyTaxCode: taxCode,
      companyEmail: email,
    );

void main() {
  group('a complete block', () {
    test('passes and serialises to exactly the four columns', () {
      final info = _complete();

      expect(info.violations(), isEmpty);
      expect(info.isValid, isTrue);
      expect(info.isEmpty, isFalse);
      expect(info.toJson(), {
        'company_name': 'Uminber India Pvt Ltd',
        'company_address': '306, Jahnavi Arcade, Ahmedabad',
        'company_tax_code': '27AAPFU0939F1Z5',
        'company_email': 'billing@uminber.in',
      });
    });

    test('trims, and uppercases the GSTIN', () {
      // A customer typing a lower-case code must not be told it is invalid —
      // the pattern only matches upper case.
      final info = _complete(
        name: '  Uminber India Pvt Ltd  ',
        taxCode: ' 27aapfu0939f1z5 ',
        email: ' billing@uminber.in ',
      );

      expect(info.violations(), isEmpty);
      expect(info.companyTaxCode, '27AAPFU0939F1Z5');
      expect(info.companyName, 'Uminber India Pvt Ltd');
      expect(info.companyEmail, 'billing@uminber.in');
    });
  });

  group('there is no partial block', () {
    test('an empty block is empty, not valid', () {
      final info = TaxInformation.empty;

      expect(info.isEmpty, isTrue);
      // Empty is the ordinary case — the order goes out with no
      // `tax_information` at all — but it is not a *valid* block, and nothing
      // may attach it to an order.
      expect(info.isValid, isFalse);
      expect(info.violations(), hasLength(4));
    });

    test('every single missing field is caught on its own', () {
      final cases = {
        'company_name': _complete(name: ''),
        'company_address': _complete(address: ''),
        'company_tax_code': _complete(taxCode: ''),
        'company_email': _complete(email: ''),
      };

      cases.forEach((field, info) {
        final problems = info.violations();
        expect(problems.keys, [field], reason: field);
        expect(problems[field], isNotEmpty, reason: field);
      });
    });
  });

  group('the rules match the server, or beat it', () {
    test('names and addresses honour min 3 / max 120 / max 255', () {
      expect(_complete(name: 'ab').violations(), contains('company_name'));
      expect(_complete(name: 'abc').violations(), isEmpty);
      expect(_complete(name: 'a' * 120).violations(), isEmpty);
      expect(_complete(name: 'a' * 121).violations(), contains('company_name'));

      const addressField = 'company_address';
      expect(_complete(address: 'ab').violations(), contains(addressField));
      expect(_complete(address: 'a' * 255).violations(), isEmpty);
      expect(_complete(address: 'a' * 256).violations(), contains(addressField));
    });

    test('the GSTIN is checked as a GSTIN, not merely as 3-20 characters', () {
      // Stricter than `min:3|max:20`, which can never cause a 422 — it only
      // refuses a code that would produce an unusable invoice. `AAA` fits the
      // server rule and is not a GSTIN.
      for (final bad in [
        'AAA',
        'A' * 15,
        '27AAPFU0939F1Z',
        '27AAPFU0939F1Z55',
        '2AAPFU0939F1Z5X',
      ]) {
        expect(
          _complete(taxCode: bad).violations(),
          contains('company_tax_code'),
          reason: bad,
        );
      }
      // ...and a real one still fits the 20-wide column.
      expect('27AAPFU0939F1Z5'.length, lessThanOrEqualTo(20));
    });

    test('the email has to be one', () {
      for (final bad in ['nope', 'a@b', 'a b@c.com', '@uminber.in']) {
        expect(
          _complete(email: bad).violations(),
          contains('company_email'),
          reason: bad,
        );
      }
    });
  });

  group('reporting', () {
    test('firstProblem names the field nearest the top of the form', () {
      // Map order would report whichever `violations()` happened to insert
      // first; the form reads top-down, so the message has to as well.
      final problems = _complete(name: '', email: 'nope').violations();

      expect(problems.keys, containsAll(['company_name', 'company_email']));
      expect(TaxInformation.firstProblem(problems), 'Enter the company name');
    });

    test('firstProblem is null when there is nothing wrong', () {
      expect(TaxInformation.firstProblem(const {}), isNull);
    });
  });

  group('value semantics', () {
    test('two identical blocks are equal, and a changed field is not', () {
      expect(_complete(), _complete());
      expect(_complete().hashCode, _complete().hashCode);
      expect(_complete(), isNot(_complete(name: 'Someone Else Ltd')));
    });

    test('copyWith re-validates rather than trusting the source', () {
      final broken = _complete().copyWith(companyTaxCode: 'nope');

      expect(broken.violations(), contains('company_tax_code'));
      expect(broken.companyName, 'Uminber India Pvt Ltd');
    });
  });
}

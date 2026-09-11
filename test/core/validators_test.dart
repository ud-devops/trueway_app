import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/utils/validators.dart';

void main() {
  group('isValidGstin', () {
    test('accepts a well-formed GSTIN', () {
      expect(isValidGstin('27AAPFU0939F1ZV'), isTrue);
    });

    test('is case-insensitive on input', () {
      expect(isValidGstin('27aapfu0939f1zv'), isTrue);
    });

    test('rejects the wrong length', () {
      expect(isValidGstin('27AAPFU0939F1Z'), isFalse);
      expect(isValidGstin('27AAPFU0939F1ZVX'), isFalse);
    });

    test('rejects 15 characters of the wrong shape', () {
      // The old check was `length >= 15`, so this used to pass.
      expect(isValidGstin('AAAAAAAAAAAAAAA'), isFalse);
      expect(isValidGstin('123456789012345'), isFalse);
    });

    test('requires the literal Z in position 14', () {
      expect(isValidGstin('27AAPFU0939F1XV'), isFalse);
    });

    test('rejects null and empty', () {
      expect(isValidGstin(null), isFalse);
      expect(isValidGstin(''), isFalse);
    });
  });

  group('isValidMobile', () {
    test('accepts 10 digits starting 6-9', () {
      expect(isValidMobile('9876543210'), isTrue);
      expect(isValidMobile('6000000000'), isTrue);
    });
    test('rejects invalid leading digits', () {
      expect(isValidMobile('1234567890'), isFalse);
      expect(isValidMobile('5876543210'), isFalse);
    });
    test('rejects wrong lengths and non-digits', () {
      expect(isValidMobile('98765432'), isFalse);
      expect(isValidMobile('98765432101'), isFalse);
      expect(isValidMobile('98765abcde'), isFalse);
      expect(isValidMobile(null), isFalse);
    });
  });

  group('nameError', () {
    test('accepts ordinary names', () {
      for (final n in ['Asha', 'Asha Kumari', 'Ravi Kumar Singh']) {
        expect(nameError(n), isNull, reason: n);
      }
    });

    test('accepts apostrophes and hyphens found in real names', () {
      // Rejecting these would lock out legitimate customers.
      for (final n in ["D'Souza", 'Anne-Marie', "Mary-Jane O'Neill"]) {
        expect(nameError(n), isNull, reason: n);
      }
    });

    test('rejects digits', () {
      expect(nameError('Asha123'), isNotNull);
      expect(nameError('123'), isNotNull);
    });

    test('rejects symbols', () {
      for (final n in ['Asha@', 'Asha!', 'Asha_Kumari', 'Asha#1', '<script>']) {
        expect(nameError(n), isNotNull, reason: n);
      }
    });

    test('rejects a leading non-letter', () {
      expect(nameError("'Asha"), isNotNull);
      expect(nameError('-Asha'), isNotNull);
      expect(nameError(' '), isNotNull);
    });

    test('enforces the backend length bounds', () {
      expect(nameError('A'), isNotNull);
      expect(nameError('A' * 120), isNull);
      expect(nameError('A' * 121), isNotNull);
    });

    test('rejects empty and null', () {
      expect(nameError(''), isNotNull);
      expect(nameError(null), isNotNull);
    });

  });

  group('passwordError', () {
    test('accepts a password meeting every rule', () {
      for (final p in ['Passw0rd!', 'Str0ng#Pass', r'Aa1!aaaa', 'Abcdefg!']) {
        expect(passwordError(p), isNull, reason: p);
      }
    });

    test('requires the minimum length', () {
      expect(kMinPasswordLength, 8);
      expect(passwordError('Aa1!aaa'), contains('8 characters'));
    });

    test('requires an uppercase letter', () {
      expect(passwordError('password!'), contains('uppercase'));
    });

    test('requires a lowercase letter', () {
      expect(passwordError('PASSWORD!'), contains('lowercase'));
    });

    test('requires a special character', () {
      expect(passwordError('Password1'), contains('special'));
    });

    test('reports one problem at a time, in order', () {
      // Length first, so the customer isn't told about character classes
      // while the password is still too short.
      expect(passwordError('aB!'), contains('8 characters'));
    });

    test('rejects empty and null', () {
      expect(passwordError(''), isNotNull);
      expect(passwordError(null), isNotNull);
    });

    test('accepts a variety of special characters', () {
      for (final s in ['!', '@', '#', r'$', '%', '^', '&', '*', '?', '-', '_']) {
        expect(passwordError('Password$s'), isNull, reason: s);
      }
    });

    test('isValidPassword agrees with passwordError', () {
      expect(isValidPassword('Passw0rd!'), isTrue);
      expect(isValidPassword('weak'), isFalse);
    });
  });

  group('isValidEmail', () {
    test('accepts ordinary addresses', () {
      for (final e in [
        'asha@example.com',
        'ravi.kumar@trueway.co.in',
        'a_b+tag@sub.domain.org',
      ]) {
        expect(isValidEmail(e), isTrue, reason: e);
      }
    });

    test('rejects malformed addresses', () {
      for (final e in [
        'not-an-email',
        'missing@domain',
        '@example.com',
        'spaces in@example.com',
        'double@@example.com',
        '',
      ]) {
        expect(isValidEmail(e), isFalse, reason: e);
      }
    });

    test('enforces the backend length cap of 60', () {
      final long = '${'a' * 55}@example.com';
      expect(long.length > 60, isTrue);
      expect(isValidEmail(long), isFalse);
    });

    test('rejects null', () => expect(isValidEmail(null), isFalse));
  });

  group('isValidPincode', () {
    test('accepts 6 digits not starting with 0', () {
      expect(isValidPincode('382415'), isTrue);
    });
    test('rejects a leading zero', () => expect(isValidPincode('012345'), isFalse));
    test('rejects wrong lengths and non-digits', () {
      expect(isValidPincode('38241'), isFalse);
      expect(isValidPincode('3824155'), isFalse);
      expect(isValidPincode('38241a'), isFalse);
      expect(isValidPincode(null), isFalse);
    });
  });
}

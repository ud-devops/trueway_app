import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/customer.dart';

void main() {
  group('Customer.fromJson', () {
    // Shape from OtpController::verify -> data.customer
    test('parses the verify payload', () {
      final c = Customer.fromJson({
        'id': 1,
        'name': 'Suraj Ojha',
        'email': 'a@b.com',
        'phone': '9876543210',
        'avatar': 'https://x/y.png',
      });
      expect(c.id, 1);
      expect(c.name, 'Suraj Ojha');
      expect(c.email, 'a@b.com');
      expect(c.phone, '9876543210');
      expect(c.avatar, 'https://x/y.png');
    });

    test('accepts avatar_url as an alias', () {
      final c = Customer.fromJson({'id': 1, 'avatar_url': 'https://x/y.png'});
      expect(c.avatar, 'https://x/y.png');
    });

    test('tolerates missing optional fields', () {
      final c = Customer.fromJson({'id': 2});
      expect(c.name, '');
      expect(c.email, isNull);
      expect(c.phone, isNull);
    });

    test('round-trips through JSON for local persistence', () {
      final original = Customer(
        id: 7,
        name: 'Asha K',
        email: 'asha@example.com',
        phone: '9000000001',
        dob: DateTime(1990, 2, 9),
      );
      expect(Customer.fromJson(original.toJson()), original);
    });
  });

  // `Customer::avatarUrl` never returns null. With no uploaded image it falls
  // back to `customer_default_avatar`, and failing that to `Avatar::toBase64()`
  // — which is `toDataUri()`, i.e. a multi-kilobyte `data:image/jpeg;base64,…`
  // string. No image widget here can decode one, and it would be persisted into
  // SharedPreferences on every sign-in.
  group('Customer.avatar', () {
    test('keeps an absolute https URL', () {
      final c = Customer.fromJson({
        'id': 1,
        'avatar': 'https://cdn.example.com/users/asha.jpg',
      });
      expect(c.avatar, 'https://cdn.example.com/users/asha.jpg');
      expect(c.hasAvatar, isTrue);
    });

    test('drops the generated data-URI placeholder', () {
      final c = Customer.fromJson({
        'id': 1,
        'name': 'Asha Kumari',
        'avatar': 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD==',
      });
      expect(c.avatar, isNull);
      expect(c.hasAvatar, isFalse);
      // The app draws this instead, which is the whole point of dropping it.
      expect(c.initials, 'AK');
    });

    test('drops a relative path it could not load anyway', () {
      final c = Customer.fromJson({'id': 1, 'avatar': 'users/asha.jpg'});
      expect(c.avatar, isNull);
    });
  });

  // `avatar_url` is `RvMedia::getImageUrl($avatar, 'thumb')`, and that call only
  // inserts the configured size before the extension (`RvMedia.php:219-226`).
  // Removing it addresses the uploaded original, so the full-screen viewer is
  // not stuck on a 150-pixel thumbnail.
  group('Customer.avatarOriginal', () {
    String? originalOf(String avatar) =>
        Customer.fromJson({'id': 1, 'avatar': avatar}).avatarOriginal;

    test('strips the thumbnail size from the filename', () {
      expect(
        originalOf('https://cdn.example.com/users/asha-150x150.jpg'),
        'https://cdn.example.com/users/asha.jpg',
      );
    });

    // The size is settings-driven (`media_sizes_thumb_width`/`_height`), so it
    // is not always 150x150.
    test('handles any configured size', () {
      expect(
        originalOf('https://cdn.example.com/users/asha-400x400.png'),
        'https://cdn.example.com/users/asha.png',
      );
    });

    // With `media_enable_thumbnail_sizes` off, or a thumbnail that was never
    // generated, there is no suffix — the URL is already the original.
    test('leaves a URL with no size suffix alone', () {
      const url = 'https://cdn.example.com/users/asha.jpg';
      expect(originalOf(url), url);
    });

    // Only the filename carries the suffix. A directory that happens to look
    // like one must survive.
    test('does not strip a size out of the directory path', () {
      expect(
        originalOf('https://cdn.example.com/2024-1x1/users/asha-150x150.jpg'),
        'https://cdn.example.com/2024-1x1/users/asha.jpg',
      );
    });

    test('is null when there is no avatar', () {
      expect(const Customer(id: 1, name: 'A').avatarOriginal, isNull);
    });
  });

  group('Customer.dob', () {
    // `UserResource` sends a `date`-cast attribute, so it arrives ISO-8601.
    test('parses the ISO form the server returns', () {
      final c = Customer.fromJson({
        'id': 1,
        'dob': '1990-02-09T00:00:00.000000Z',
      });
      expect(c.dob, DateTime(1990, 2, 9));
    });

    // THE off-by-one. `Carbon::jsonSerialize()` emits midnight in the *store's*
    // timezone converted to UTC, and Botble sets `app.timezone` from the admin
    // `time_zone` setting. On an India store a birthday of the 28th leaves as
    // `…-27T18:30:00Z`, so reading the UTC calendar day off it saved and
    // displayed the 27th.
    test('reads an India-store birthday as the day the customer picked', () {
      final c = Customer.fromJson({
        'id': 1,
        'dob': '2026-08-27T18:30:00.000000Z',
      });
      expect(c.dob, DateTime(2026, 8, 28));
    });

    // Same value with the offset kept rather than converted, which is the other
    // shape Carbon can be configured to emit.
    test('reads the same birthday when the offset is kept', () {
      final c = Customer.fromJson({
        'id': 1,
        'dob': '2026-08-28T00:00:00.000+05:30',
      });
      expect(c.dob, DateTime(2026, 8, 28));
    });

    // Rounding to the nearest midnight has to work in both directions, or a
    // store west of Greenwich would gain the day the India store lost.
    test('reads a western-store birthday as the same day', () {
      final c = Customer.fromJson({
        'id': 1,
        'dob': '2026-08-28T08:00:00.000000Z', // midnight UTC-8
      });
      expect(c.dob, DateTime(2026, 8, 28));
    });

    test('also reads back the dd-MM-yyyy form the app sends', () {
      final c = Customer.fromJson({'id': 1, 'dob': '09-02-1990'});
      expect(c.dob, DateTime(1990, 2, 9));
    });

    // A bare date has no instant to reason about, and this is what [toJson]
    // writes — so the cached session cannot drift with the device's timezone.
    test('reads a bare calendar date literally', () {
      expect(
        Customer.fromJson({'id': 1, 'dob': '2026-08-28'}).dob,
        DateTime(2026, 8, 28),
      );
    });

    test('persists a bare calendar date, not an instant', () {
      final stored = Customer(id: 1, name: 'A', dob: DateTime(2026, 8, 28))
          .toJson()['dob'];
      expect(stored, '2026-08-28');
    });

    test('is null when absent or unparseable', () {
      expect(Customer.fromJson({'id': 1}).dob, isNull);
      expect(Customer.fromJson({'id': 1, 'dob': ''}).dob, isNull);
      expect(Customer.fromJson({'id': 1, 'dob': 'not a date'}).dob, isNull);
    });

    // The write format is `date_format:` . `BaseHelper::getDateFormat()`, and
    // this deployment sets `CMS_DATE_FORMAT="d-m-Y"`. Sending ISO is a 422.
    test('apiDob writes zero-padded dd-MM-yyyy', () {
      expect(Customer.apiDob(DateTime(1990, 2, 9)), '09-02-1990');
      expect(Customer.apiDob(DateTime(2001, 12, 31)), '31-12-2001');
    });
  });

  group('Customer.copyWith', () {
    const base = Customer(
      id: 7,
      name: 'Asha K',
      email: 'asha@example.com',
      phone: '9000000001',
      avatar: 'https://cdn.example.com/a.jpg',
    );

    test('replaces only what is named', () {
      final updated = base.copyWith(avatar: 'https://cdn.example.com/b.jpg');
      expect(updated.avatar, 'https://cdn.example.com/b.jpg');
      expect(updated.id, 7);
      expect(updated.name, 'Asha K');
      expect(updated.email, 'asha@example.com');
      expect(updated.phone, '9000000001');
    });

    // `null` means "leave it alone", so an upload whose response held only the
    // generated placeholder needs an explicit flag — otherwise the previous
    // photo stays on screen and the upload looks like it silently failed.
    test('needs clearAvatar to remove one, since null means unchanged', () {
      expect(base.copyWith(avatar: null).avatar, base.avatar);
      expect(base.copyWith(clearAvatar: true).avatar, isNull);
    });

    test('clearDob removes a stored birthday', () {
      final withDob = base.copyWith(dob: DateTime(1990, 2, 9));
      expect(withDob.copyWith(clearDob: true).dob, isNull);
    });
  });

  group('Customer.initials', () {
    test('uses first and last name', () {
      expect(const Customer(id: 1, name: 'Suraj Ojha').initials, 'SO');
    });
    test('handles a single name', () {
      expect(const Customer(id: 1, name: 'Suraj').initials, 'S');
    });
    test('ignores extra whitespace', () {
      expect(const Customer(id: 1, name: '  Asha   Kumari  ').initials, 'AK');
    });
    test('falls back for an empty name', () {
      expect(const Customer(id: 1, name: '').initials, '?');
    });
  });

  group('Customer.displayName', () {
    test('prefers the name', () {
      expect(
        const Customer(id: 1, name: 'Asha', phone: '9000000001').displayName,
        'Asha',
      );
    });
    test('falls back to the phone', () {
      expect(
        const Customer(id: 1, name: '  ', phone: '9000000001').displayName,
        '9000000001',
      );
    });
    test('falls back to Guest with neither', () {
      expect(const Customer(id: 1, name: '').displayName, 'Guest');
    });
  });

  group('OtpChallenge', () {
    // customer_id is required by /otp/verify — losing it makes the OTP
    // unverifiable, so it must survive parsing.
    test('keeps customer_id and the raw phone', () {
      final c = OtpChallenge.fromJson(
        {'phone': '98******10', 'customer_id': 42, 'expires_in': 300},
        rawPhone: '9876543210',
      );
      expect(c.customerId, 42);
      expect(c.maskedPhone, '98******10');
      expect(c.rawPhone, '9876543210');
      expect(c.validity, const Duration(minutes: 5));
    });

    test('defaults expiry to 300s when absent', () {
      final c = OtpChallenge.fromJson({'customer_id': 1}, rawPhone: '9876543210');
      expect(c.expiresIn, 300);
    });

    test('falls back to the raw phone when the server sends no mask', () {
      final c = OtpChallenge.fromJson({'customer_id': 1}, rawPhone: '9876543210');
      expect(c.maskedPhone, '9876543210');
    });
  });

  group('AuthSession', () {
    test('parses token and nested customer', () {
      final s = AuthSession.fromJson({
        'token': '1|abc123',
        'customer': {'id': 5, 'name': 'Asha', 'phone': '9000000001'},
      });
      expect(s.token, '1|abc123');
      expect(s.customer.id, 5);
      expect(s.customer.name, 'Asha');
    });

    test('survives a missing customer object', () {
      final s = AuthSession.fromJson({'token': '1|abc'});
      expect(s.token, '1|abc');
      expect(s.customer.id, 0);
    });
  });
}

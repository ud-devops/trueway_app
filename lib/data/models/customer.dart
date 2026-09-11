import '../../core/utils/json_utils.dart';

/// An authenticated shop customer.
///
/// Two endpoints produce this. `OtpController::verify` returns the short form
/// `data.customer = { id, name, email, phone, avatar }`; `GET /me` returns
/// `UserResource`, which adds `dob` (plus `gender`, `description` and a
/// `settings` map — see below for why those are ignored).
///
/// **Only `name`, `email`, `phone`, `dob` and `avatar` are real.** `ec_customers`
/// has no `gender`, `description`, `first_name` or `last_name` column, and
/// `Customer::$fillable` does not list them either, so `UserResource` emits them
/// as null and `ProfileController::updateProfile` validates then silently
/// discards them on `fill()`. Modelling them would promise an edit the server
/// cannot keep.
class Customer {
  const Customer({
    required this.id,
    required this.name,
    this.email,
    this.phone,
    this.avatar,
    this.dob,
  });

  final int id;
  final String name;
  final String? email;
  final String? phone;

  /// An `http(s)` URL, or null. Never a data URI — see [_avatarUrlOrNull].
  final String? avatar;

  /// Date of birth. Read as ISO-8601; **written back as `dd-MM-yyyy`** — the two
  /// formats differ, see [apiDob].
  final DateTime? dob;

  /// True when the server has a real uploaded image for this customer.
  bool get hasAvatar => avatar != null;

  /// The full-size original behind [avatar].
  ///
  /// [avatar] is `RvMedia::getImageUrl($avatar, 'thumb')`, and the only thing
  /// that call does to the path is insert the configured size before the
  /// extension — `users/asha.jpg` → `users/asha-150x150.jpg`
  /// (`RvMedia.php:219-226`). Dropping that suffix addresses the file the
  /// customer actually uploaded, so a full-screen view is not stuck showing a
  /// 150-pixel thumbnail.
  ///
  /// Equal to [avatar] when there is nothing to strip: a store with
  /// `media_enable_thumbnail_sizes` off, or a file whose thumbnail was never
  /// generated, has no suffix in the first place.
  ///
  /// **Best-effort — always keep [avatar] as a fallback.** This is derived
  /// because `UserResource` sends one URL and no `image_with_sizes.origin` like
  /// the catalogue resources do. A file genuinely uploaded as
  /// `photo-150x150.jpg` would resolve to a path that does not exist.
  String? get avatarOriginal =>
      avatar?.replaceFirst(RegExp(r'-\d+x\d+(?=\.[^./]+$)'), '');

  /// Initials for the avatar placeholder ("Suraj Ojha" -> "SO").
  String get initials {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final first = parts.first[0].toUpperCase();
    if (parts.length == 1) return first;
    return '$first${parts.last[0].toUpperCase()}';
  }

  /// Best available label for greeting the customer.
  String get displayName => name.trim().isNotEmpty ? name.trim() : (phone ?? 'Guest');

  factory Customer.fromJson(Map<String, dynamic> j) => Customer(
        id: asInt(j['id']),
        name: asString(j['name']),
        email: asStringOrNull(j['email']),
        phone: asStringOrNull(j['phone']),
        avatar: _avatarUrlOrNull(j['avatar'] ?? j['avatar_url']),
        dob: _parseDob(j['dob']),
      );

  /// [clearAvatar] and [clearDob] exist because `null` already means "leave
  /// this alone". Without them an upload whose response held only the
  /// generated placeholder would keep the previous photo on screen, which
  /// reads as an upload that silently failed.
  Customer copyWith({
    String? name,
    String? email,
    String? phone,
    String? avatar,
    DateTime? dob,
    bool clearAvatar = false,
    bool clearDob = false,
  }) =>
      Customer(
        id: id,
        name: name ?? this.name,
        email: email ?? this.email,
        phone: phone ?? this.phone,
        avatar: clearAvatar ? null : (avatar ?? this.avatar),
        dob: clearDob ? null : (dob ?? this.dob),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'phone': phone,
        'avatar': avatar,
        // A bare calendar date, not an instant: a birthday has no time and no
        // timezone, and writing one would make the cached session read back a
        // day early or late depending on where the device is.
        'dob': dob == null ? null : '${dob!.year.toString().padLeft(4, '0')}'
            '-${_two(dob!.month)}-${_two(dob!.day)}',
      };

  /// The server's `avatar_url` accessor never returns null: with no uploaded
  /// image it falls back to `customer_default_avatar`, and failing that to
  /// `Avatar::toBase64()`, which is `Botble\Base\Supports\Avatar::toDataUri()`
  /// — a multi-kilobyte `data:image/jpeg;base64,…` string.
  ///
  /// That placeholder must not reach the UI or SharedPreferences: no image
  /// widget here can decode a data URI, and persisting one bloats the cached
  /// session with an image the app already draws better itself ([initials]).
  /// Anything that is not an absolute http(s) URL is therefore "no avatar".
  static String? _avatarUrlOrNull(dynamic raw) {
    final value = asStringOrNull(raw);
    if (value == null) return null;
    return value.startsWith('http://') || value.startsWith('https://')
        ? value
        : null;
  }

  /// `UserResource` sends `dob` straight from a `date`-cast attribute, which
  /// json-encodes through `Carbon::jsonSerialize()` → `toIso8601ZuluString`.
  ///
  /// **That is midnight in the *store's* timezone, expressed in UTC** — and the
  /// store's timezone is whatever the admin `time_zone` setting says, applied
  /// over `app.timezone` at boot (`BaseServiceProvider`). For an India store a
  /// birthday of the 28th therefore arrives as `…-27T18:30:00.000000Z`, and
  /// reading the UTC calendar day off it lands a day early. That was a real bug:
  /// saving the 28th displayed the 27th.
  ///
  /// A date-only value carried as an instant is always midnight *somewhere*, so
  /// the intended day is recovered by rounding the instant to the nearest
  /// midnight rather than truncating it. Exact for store offsets from UTC−11 to
  /// UTC+12, which covers every timezone this store could plausibly be set to.
  ///
  /// The `dd-MM-yyyy` branch handles the format the app *sends* ([apiDob]), so
  /// a server that echoed a request value back verbatim would still be read.
  static DateTime? _parseDob(dynamic raw) {
    final value = asStringOrNull(raw);
    if (value == null) return null;

    // A bare calendar date carries no instant to reason about, so it is read
    // literally. This is what [toJson] writes, which keeps the locally cached
    // session immune to the device's timezone.
    final dateOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (dateOnly != null) {
      return DateTime(
        int.parse(dateOnly.group(1)!),
        int.parse(dateOnly.group(2)!),
        int.parse(dateOnly.group(3)!),
      );
    }

    final instant = DateTime.tryParse(value);
    if (instant != null) {
      final nearestDay = instant.toUtc().add(const Duration(hours: 12));
      return DateTime(nearestDay.year, nearestDay.month, nearestDay.day);
    }

    final match = RegExp(r'^(\d{2})-(\d{2})-(\d{4})$').firstMatch(value);
    if (match == null) return null;
    return DateTime(
      int.parse(match.group(3)!),
      int.parse(match.group(2)!),
      int.parse(match.group(1)!),
    );
  }

  /// A date in the format `PUT /me` demands.
  ///
  /// The rule is `date_format:` . `BaseHelper::getDateFormat()`, and this
  /// deployment sets `CMS_DATE_FORMAT="d-m-Y"` in `.env`. Sending ISO here is
  /// rejected with a 422, so the write format deliberately differs from the
  /// read format.
  static String apiDob(DateTime date) =>
      '${_two(date.day)}-${_two(date.month)}-${date.year}';

  static String _two(int n) => n.toString().padLeft(2, '0');

  @override
  bool operator ==(Object other) =>
      other is Customer &&
      other.id == id &&
      other.name == name &&
      other.email == email &&
      other.phone == phone &&
      other.avatar == avatar &&
      other.dob == dob;

  @override
  int get hashCode => Object.hash(id, name, email, phone, avatar, dob);
}

/// Result of `POST /otp/send` (and `/otp/resend`).
///
/// [customerId] is required by `/otp/verify` — losing it makes the OTP
/// unverifiable, so it is carried through the auth state.
class OtpChallenge {
  const OtpChallenge({
    required this.customerId,
    required this.maskedPhone,
    required this.rawPhone,
    required this.expiresIn,
  });

  final int customerId;

  /// Server-masked phone for display, e.g. `98******10`.
  final String maskedPhone;

  /// The number the user typed — `/otp/verify` needs it verbatim.
  final String rawPhone;

  /// Seconds until the OTP expires (server sends 300).
  final int expiresIn;

  Duration get validity => Duration(seconds: expiresIn);

  factory OtpChallenge.fromJson(Map<String, dynamic> j, {required String rawPhone}) =>
      OtpChallenge(
        customerId: asInt(j['customer_id']),
        maskedPhone: asString(j['phone'], rawPhone),
        rawPhone: rawPhone,
        expiresIn: asInt(j['expires_in'], 300),
      );
}

/// Result of `POST /otp/verify`.
class AuthSession {
  const AuthSession({required this.token, required this.customer});

  final String token;
  final Customer customer;

  factory AuthSession.fromJson(Map<String, dynamic> j) => AuthSession(
        token: asString(j['token']),
        customer: Customer.fromJson(asMap(j['customer'])),
      );
}

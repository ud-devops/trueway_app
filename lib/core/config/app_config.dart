/// Central runtime configuration.
///
/// ## Which backend is this?
///
/// `dev.truewayerp.com` is **the live store**, confirmed by the client
/// 2026-08-06 — the `dev.` prefix is historical, not a staging marker. Probed
/// the same day: it answers `/api/v1/ecommerce/products` with 200 and real
/// catalogue rows, while the bare `truewayerp.com` answers 403 at the root and
/// 404 on the API path, serving an unrelated site. There is no second host to
/// point at, so these defaults are correct rather than merely convenient.
///
/// ## The API key
///
/// `X-API-KEY` is enforced on every route, so [apiKey] is a **live credential
/// that is committed to this repository**. Anyone with the source can call the
/// production API with it. That is the client's accepted position for now; two
/// things would improve it, in order of effort:
///
///  1. Pass it at build time (`--dart-define=API_KEY=…`) and drop the default,
///     so it lives in CI secrets instead of source. Rotate it at the same time,
///     since the current value must be assumed compromised.
///  2. A thin server-side proxy that injects the key, so the binary never
///     carries one — the only fix that survives someone decompiling the APK.
library;

class AppConfig {
  AppConfig._();

  // ---- build-time overrides ------------------------------------------------
  //
  // Empty unless the build passed `--dart-define`. The defaults below are the
  // live values, so an override is only needed to point a build somewhere else
  // — a staging install, or a key held outside source control.

  static const String _originOverride = String.fromEnvironment('API_ORIGIN');
  static const String _baseOverride = String.fromEnvironment('API_BASE');
  static const String _keyOverride = String.fromEnvironment('API_KEY');

  /// The live backend. Named for the host, not for an environment — see the
  /// library doc for why `dev.` here does not mean a staging server.
  static const String defaultOrigin = 'https://dev.truewayerp.com';

  /// Live API key. See the library doc: this is in source control on purpose
  /// for now, and should be rotated the day it moves to `--dart-define`.
  static const String _defaultApiKey = '8pfFEfF09RBUZ5GXcimW3LrsZFCqFMLp';

  /// Backend origin (Botble/Laravel e-commerce).
  static const String origin =
      _originOverride != '' ? _originOverride : defaultOrigin;

  /// REST API base.
  static const String apiBase =
      _baseOverride != '' ? _baseOverride : '$origin/api/v1';

  /// Public storage base for images.
  static String get storageBase => '$origin/storage';

  /// App API key.
  static const String apiKey =
      _keyOverride != '' ? _keyOverride : _defaultApiKey;

  /// True when this build is carrying the API key baked into the source rather
  /// than one supplied at build time.
  ///
  /// Not enforced — the defaults are the real values, so blocking on this would
  /// break a correct build. It exists so a future CI check, or a debug overlay,
  /// can tell the two apart without re-deriving the logic.
  static const bool usesSourceControlledKey = _keyOverride == '';

  static const String apiKeyHeader = 'X-API-KEY';

  /// Third-party pincode lookup used for address autofill.
  static const String pincodeApi = 'https://api.postalpincode.in/pincode';

  static const Duration connectTimeout = Duration(seconds: 20);
  static const Duration receiveTimeout = Duration(seconds: 25);

  /// Resolve a possibly-relative storage path to an absolute URL.
  static String resolveImage(String? path) {
    if (path == null || path.isEmpty) return '';
    if (path.startsWith('http')) return path;
    final clean = path.startsWith('/') ? path.substring(1) : path;
    return '$origin/$clean';
  }

  /// The same, for a path stored **relative to the media disk**.
  ///
  /// Some resources hand back a URL and some hand back the raw column. The
  /// slider sends both in one object: `image` has been through
  /// `RvMedia::getImageUrl()` and arrives as
  /// `https://…/storage/./web1.webp`, while `tablet_image` and `mobile_image`
  /// are the untouched column values — `./tab1.webp`. [resolveImage] would put
  /// that at `https://…/./tab1.webp`, which 404s; the missing piece is the
  /// `/storage` segment the server already added to its sibling.
  ///
  /// Returns null rather than an empty string when there is nothing to
  /// resolve, so a caller can tell "no upload" from "a bad one" and fall back
  /// to the artwork that does exist.
  static String? resolveStorageImage(Object? raw) {
    final path = raw is String ? raw.trim() : null;
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;

    // `./x.webp` → `x.webp`, `/x.webp` → `x.webp`.
    var clean = path;
    while (clean.startsWith('./') || clean.startsWith('/')) {
      clean = clean.startsWith('./') ? clean.substring(2) : clean.substring(1);
    }
    if (clean.isEmpty) return null;

    // A value that already names the disk keeps it rather than gaining a
    // second copy — `storage/x.webp` must not become `/storage/storage/x.webp`.
    if (clean.startsWith('storage/')) return '$origin/$clean';
    return '$storageBase/$clean';
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/config/app_config.dart';

/// Backend configuration.
///
/// `dev.truewayerp.com` is **the live store** — the `dev.` prefix is historical,
/// not a staging marker (confirmed by the client 2026-08-06). The defaults here
/// are therefore the real values, not a placeholder someone forgot to replace,
/// and these tests exist so nobody "corrects" them by guessing.
void main() {
  group('defaults', () {
    // `flutter test` passes no --dart-define, so this is the un-overridden case
    // — which is also what a plain `flutter build` ships.
    test('point at the live backend', () {
      expect(AppConfig.origin, AppConfig.defaultOrigin);
      expect(AppConfig.origin, 'https://dev.truewayerp.com');
    });

    test('derive the API base from the origin', () {
      expect(AppConfig.apiBase, '${AppConfig.origin}/api/v1');
    });

    test('derive the storage base from the origin', () {
      expect(AppConfig.storageBase, '${AppConfig.origin}/storage');
    });

    test('carry an API key, which every route requires', () {
      // X-API-KEY is enforced ahead of auth: without it every request is 401.
      expect(AppConfig.apiKey, isNotEmpty);
    });
  });

  // Probed 2026-08-06: `dev.truewayerp.com/api/v1/ecommerce/products` answers
  // 200 with real catalogue rows, while `truewayerp.com` answers 403 at the
  // root and 404 on the API path, serving an unrelated site. Production is not
  // the dev host minus its subdomain, and an earlier BUILD_AND_RUN.md said it
  // was — this pins the correction.
  group('the host is not the bare domain', () {
    test('origin keeps its subdomain', () {
      expect(AppConfig.origin, isNot('https://truewayerp.com'));
      expect(AppConfig.origin, startsWith('https://dev.'));
    });
  });

  group('key provenance', () {
    // Not enforced anywhere — the default *is* the live key, so blocking on it
    // would break a correct build. The flag exists so CI or a debug overlay can
    // tell a source-controlled key from a build-time one.
    test('reports that the built-in key came from source', () {
      expect(AppConfig.usesSourceControlledKey, isTrue);
    });
  });
}

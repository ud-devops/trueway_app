# Build & Run

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| **Flutter SDK** | **3.44.8** stable (Dart 3.12) | Newer 3.44.x should be fine; a major bump may need dep updates |
| **JDK** | **17** | Required by the Android Gradle Plugin used here |
| **Android SDK** | Platform 34/35, build-tools 34+ | `compileSdk`/`targetSdk` follow Flutter defaults |
| Android device/emulator | API 24+ (`minSdk` = Flutter default) | For emulator notes see KNOWN_ISSUES |

```bash
flutter pub get          # restore packages
flutter analyze          # should be clean (only style-lint infos, no errors)
flutter run              # run on connected device/emulator
```

## Build APKs

```bash
# Debug (auto-signed with the local debug key, ~188 MB)
flutter build apk --debug
#   → build/app/outputs/flutter-apk/app-debug.apk

# Release (signed with the Trueway keystore, ~78 MB) — see signing below
flutter build apk --release --no-tree-shake-icons
#   → build/app/outputs/flutter-apk/app-release.apk

# Play Store upload — the SAME flag applies
flutter build appbundle --release --no-tree-shake-icons

# Optional: smaller per-ABI splits (arm64 is what most phones need)
flutter build apk --release --no-tree-shake-icons --split-per-abi
```

### ⚠ `--no-tree-shake-icons` is required, not optional

**Leave it off and icons disappear from the release build.** Observed on a real
APK: the bell on the home header, the "All" category chip, all four bottom-nav
icons except Cart, and the wishlist heart on unsaved products all rendered as
blank space. Debug builds looked perfect throughout, because debug ships the
whole font and only release shakes it.

What is happening: `AppIcons` is built on `material_symbols_icons`, whose fonts
are **variable** (`FILL`, `wght`, `GRAD`, `opsz` axes) and huge — 10.6 MB for
the Outlined family alone. The release build subsets that to ~48 KB, and the
subsetter drops glyphs it cannot prove are used. It misses two shapes this app
relies on:

* an `IconData` that reaches `Icon(...)` as a **variable** rather than as a
  literal — `_icon(AppIcons.home, active)` in `main_navigation_screen.dart`,
  `_circleAction(context, AppIcons.bell, …)` in `home_screen.dart`,
  `_Tab(icon: AppIcons.grid)` in `home_sticky_header.dart`;
* an icon drawn with a variable axis — `Icon(AppIcons.heart, fill: saved ? 1 : 0)`.

Measured, not assumed: a defaulted parameter (`EmptyView`'s old
`this.icon = Icons.inventory_2_outlined`) was absent from the subset, and moving
it to a static const field read from `build()` left the subset **byte-identical**
at 15,084 bytes. That default is now a required parameter for the same reason.

The flag costs **15.5 MB** (62.2 → 77.7 MB). The way to get that back is to move
`AppIcons` onto Flutter's built-in `Icons.*`, which is a static font and shakes
reliably — a design decision, not a bug fix, because the two icon families do
not look the same.

> Installing a **release** APK over a previously installed **debug** build fails
> with a signature mismatch ("app not installed"). `adb uninstall
> com.trueway.trueway_farms` first, then install the release APK.

## Release signing

Signing is wired in `android/app/build.gradle.kts`, which reads
`android/key.properties`:

```properties
# android/key.properties  (DO NOT commit to a public repo)
storePassword=Trueway@2026
keyPassword=Trueway@2026
keyAlias=trueway
storeFile=trueway-release.jks
```

The keystore is `android/app/trueway-release.jks`
(alias `trueway`, RSA-2048, 10000-day validity,
`CN=Trueway Farms, O=Trueway Organic Pvt Ltd, L=Bhilwara, ST=Rajasthan, C=IN`).

> 🔑 **CRITICAL:** keep this keystore + passwords safe and backed up. The **same
> key must sign every future update** once the app is on the Play Store. If it's
> lost you cannot update the listing. For a real pipeline, move these secrets out
> of the repo (CI secrets / a vault) and consider Play App Signing.

To regenerate a keystore (only if starting fresh — this breaks update continuity):
```bash
keytool -genkeypair -v -keystore android/app/trueway-release.jks \
  -alias trueway -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Trueway Farms, O=Trueway Organic Pvt Ltd, L=Bhilwara, ST=Rajasthan, C=IN"
```

## Runtime configuration (`--dart-define`)

**The defaults in `AppConfig` are the live values.** A plain
`flutter build apk --release` already ships against the correct backend — no
`--dart-define` is required.

```
origin   https://dev.truewayerp.com     ← the live store
apiBase  https://dev.truewayerp.com/api/v1
apiKey   baked into lib/core/config/app_config.dart
```

> ### `dev.` here does not mean staging
>
> An earlier version of this file told you to build against
> `https://truewayerp.com`. **That is wrong** — probed 2026-08-06:
>
> | Host | Root | `/api/v1/ecommerce/products` |
> |---|---|---|
> | `dev.truewayerp.com` | — | `200`, real Botble API, real products |
> | `truewayerp.com` | `403` | `404`, serves an unrelated site |
>
> The `dev.` prefix is historical. There is one backend and this is it.

Overrides exist for pointing a build somewhere else — a future staging install,
or a key kept outside source control:

```bash
flutter build apk --release \
  --dart-define=API_ORIGIN=https://<other-host> \
  --dart-define=API_KEY=<other-key>
```

`API_BASE` is derived as `<origin>/api/v1`; pass it only if a host puts the API
elsewhere.

### ⚠ The API key is a live credential in source control

`X-API-KEY` is enforced on every route, so the key in `app_config.dart` grants
access to the **production** API and is readable by anyone with this repository
or a decompiler on the APK. This is the client's accepted position for now.
Two improvements, in order of effort:

1. Move it to `--dart-define` from CI secrets and drop the default — **and
   rotate it**, since the current value must be assumed compromised.
2. A thin server-side proxy that injects the key, so the binary never carries
   one. This is the only fix that survives someone unpacking the APK.

`AppConfig.usesSourceControlledKey` reports which of the two a given build is
using. Nothing enforces it — the default *is* the real key, so failing the build
on it would break a correct release.

## Windows build-machine gotchas

The app was built on a Windows box where the Android build fails unless a temp
directory workaround is applied (a known Gradle/named-pipe issue on some Windows
setups — _"java.io.IOException: Unable to establish loopback connection"_):

1. `android/gradle.properties` already contains
   `-Djava.io.tmpdir=C:\T` inside `org.gradle.jvmargs`.
2. **`C:\T` must actually exist.** Gradle does not create it, and if it is
   missing the build burns ~16 minutes and then dies with a misleading service
   -wiring error whose real cause is the last line:
   ```
   Cannot create service of type BuildSessionActionExecutor ...
     > java.io.IOException: java.io.tmpdir is set to a directory that
       doesn't exist: C:\T
   ```
3. You **also** must export the temp env vars for the build shell (the client JVM
   reads them; the gradle.properties line alone is not enough):
   ```bash
   mkdir -p /c/T                 # <- step 2; do not skip
   export TMP=C:/T TEMP=C:/T
   flutter build apk --release
   ```

On macOS/Linux or a clean Windows CI, none of this is needed — remove/ignore it.

## Web & iOS

- **Web** compiles (`flutter build web`) and was used during development for fast
  UI iteration, but is **not a supported target** (Razorpay has no web impl; the
  CanvasKit renderer can't cross-origin-render the backend's `/storage/` images).
  Build web with `--no-tree-shake-icons`.
- **iOS** has not been configured (no signing, no `Info.plist` review). The Dart
  is platform-agnostic, but you'll need to set up the iOS host project, bundle
  ID, and Razorpay iOS setup before it runs.

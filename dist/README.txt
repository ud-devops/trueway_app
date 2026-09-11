Trueway Farms — installable build
=================================
File: Trueway-Farms-v1.0.0-release.apk  (signed release, Android)

Install on a phone:
  1. Copy the APK to the device (or `adb install Trueway-Farms-v1.0.0-release.apk`).
  2. Allow "install from unknown sources" if prompted.
  3. If an older build is present, uninstall it first (different signing key).

This build talks to the live backend (dev.truewayerp.com). Catalogue, cart and
checkout-form flows work; login/payment are stubbed (see ../docs/HANDOFF.md).

To build it yourself:  flutter build apk --release   (see ../docs/BUILD_AND_RUN.md)

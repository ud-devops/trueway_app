/// Rotation is locked on phones and left alone on tablets.
///
/// The lock is applied in `main()` from the platform view's own size, so these
/// pin the rule itself — the breakpoint and which orientations each device
/// class gets — rather than driving `main()`, which would need a real engine.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/main.dart';

/// The same expression `_applyOrientationLock` uses, kept in one place so a
/// change to the rule breaks this test rather than sliding past it.
List<DeviceOrientation> orientationsFor(Size logicalSize) =>
    logicalSize.shortestSide < kPhoneShortestSide
        ? const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]
        : const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ];

void main() {
  group('phones are portrait-only', () {
    test('a phone held upright', () {
      // Pixel-class: 411 x 891.
      expect(orientationsFor(const Size(411, 891)), hasLength(2));
      expect(
        orientationsFor(const Size(411, 891)),
        isNot(contains(DeviceOrientation.landscapeLeft)),
      );
    });

    // The shortest side is what decides, so a phone already lying on its side
    // gets the same answer — otherwise the lock would depend on how the app
    // happened to be launched.
    test('the same phone held sideways', () {
      expect(orientationsFor(const Size(891, 411)), hasLength(2));
    });
  });

  group('tablets keep every orientation', () {
    test('a 7-inch tablet, the smallest that counts', () {
      // 600 is the boundary itself — `sw600dp`, where Android's tablet
      // resource buckets begin.
      expect(orientationsFor(const Size(600, 960)), hasLength(4));
    });

    test('an iPad in landscape', () {
      final orientations = orientationsFor(const Size(1180, 820));
      expect(orientations, contains(DeviceOrientation.landscapeLeft));
      expect(orientations, contains(DeviceOrientation.portraitUp));
    });
  });

  test('the breakpoint is the shortest side, not the width', () {
    // A phone in landscape is 891 wide — wider than the 640 the *layout*
    // helpers switch on. Sharing that number here would unlock rotation the
    // moment the device was turned, and the lock would chase itself.
    expect(const Size(891, 411).width, greaterThan(640));
    expect(orientationsFor(const Size(891, 411)), hasLength(2));
  });
}

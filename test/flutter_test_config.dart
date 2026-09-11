import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// Runs once before every test file in the suite.
///
/// ## Why this exists
///
/// The type ramp is built with `GoogleFonts.poppins(...)`, and Poppins is
/// fetched at runtime rather than bundled as an asset (see the note in
/// docs/KNOWN_ISSUES.md). In a test environment google_fonts defaults
/// `allowRuntimeFetching` to false, and with no matching asset it then *throws*:
///
///     GoogleFonts.config.allowRuntimeFetching is false but font
///     Poppins-SemiBold was not found in the application assets.
///
/// Anything that builds a theme — `AppTheme.light`, and therefore most widget
/// tests — hits that. Re-enabling runtime fetching does not perform a real
/// network call: the test binding stubs HTTP so the request fails immediately
/// and google_fonts falls back to the default font, which is the behaviour
/// tests want. Text metrics come from the test font either way.
///
/// The real fix is to bundle Poppins in `pubspec.yaml`, which would also remove
/// the fallback-font flash on a cold offline launch. Until then, this keeps the
/// suite honest rather than having each test work around it.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = true;
  return testMain();
}

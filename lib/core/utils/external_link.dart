/// Handing a link to the device's own browser.
///
/// The shop's help and policy pages — About us, Contact us, Shipping &
/// delivery, Cancellation & returns, FAQ — are ordinary web pages with nothing
/// app-specific about them. Opening them in Chrome (or whatever the customer's
/// default is) gives them an address bar, their own bookmarks, reader mode,
/// text zoom and a share sheet, none of which an embedded WebView has.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [url] outside the app. Returns false when nothing could handle it.
typedef ExternalLauncher = Future<bool> Function(Uri url);

/// The real launcher, and the seam a test replaces.
///
/// A provider rather than a direct `launchUrl` call at the call site: the
/// plugin has no implementation under a widget test, so a screen that called it
/// straight could only be tested by stubbing a platform channel. Overriding
/// this is one line, and it also lets a test assert the *exact* URL that was
/// handed over — which is the part worth pinning, since a build pointed at
/// production must not send customers to the dev server.
final externalLauncherProvider = Provider<ExternalLauncher>(
  (ref) => openExternally,
);

/// Hands [url] to the device browser.
///
/// [LaunchMode.externalApplication] is explicit and load-bearing. The default,
/// `platformDefault`, opens Android links in a **Custom Tab** — an in-app
/// browser sheet, which is the very thing this replaced. External application
/// is what actually leaves the app and lands in Chrome.
///
/// Returns false rather than throwing when there is no browser, so the caller
/// can fall back instead of showing the customer a crash.
Future<bool> openExternally(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } on Object {
    // A device with no browser, a scheme nothing claims, or a platform with no
    // url_launcher implementation at all. All three are "it did not open".
    return false;
  }
}

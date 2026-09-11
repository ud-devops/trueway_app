import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/network/api_client.dart';
import '../../core/payments/payment_gateway.dart';
import '../../core/platform/invoice_opener.dart';
import '../../core/payments/razorpay_gateway.dart';
import '../../data/repositories/address_repository.dart';
import '../../data/repositories/cart_repository.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../data/repositories/checkout_repository.dart';
import '../../data/repositories/home_repository.dart';
import '../../data/repositories/logistics_repository.dart';
import '../../data/repositories/order_repository.dart';
import '../../data/repositories/review_repository.dart';
import '../../data/repositories/wishlist_repository.dart';

/// Overridden in main() once SharedPreferences has loaded.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider not initialised'),
);

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(prefs: ref.watch(sharedPreferencesProvider)),
);

final catalogRepositoryProvider = Provider<CatalogRepository>(
  (ref) => CatalogRepository(ref.watch(apiClientProvider)),
);

/// Home carousels, filters, brands — one call feeds four sections.
final homeRepositoryProvider = Provider<HomeRepository>(
  (ref) => HomeRepository(ref.watch(apiClientProvider)),
);

/// Order history, detail and returns. All signed-in only.
final orderRepositoryProvider = Provider<OrderRepository>(
  (ref) => OrderRepository(ref.watch(apiClientProvider)),
);

final addressRepositoryProvider = Provider<AddressRepository>(
  (ref) => AddressRepository(ref.watch(apiClientProvider)),
);

/// Saves a downloaded invoice and opens it in the device's PDF viewer.
///
/// A provider rather than a plain `const InvoiceOpener()` at the call site so a
/// widget test can substitute one: the real thing writes a file and fires a
/// platform intent, neither of which exists in a test binding.
final invoiceOpenerProvider = Provider<InvoiceOpener>(
  (ref) => const InvoiceOpener(),
);

/// Shiprocket serviceability, courier rates and pincode checks.
///
/// Registered here rather than next to the shipping providers so that the app
/// has exactly one instance: `shipping_provider.dart` declared its own while
/// this file had none, and two declarations of the same repository would have
/// meant two clients once anything else (the product page's "delivers by" line,
/// for instance) started using it.
final logisticsRepositoryProvider = Provider<LogisticsRepository>(
  (ref) => LogisticsRepository(ref.watch(apiClientProvider)),
);

final reviewRepositoryProvider = Provider<ReviewRepository>(
  (ref) => ReviewRepository(ref.watch(apiClientProvider)),
);

/// Wishlist. Needs [SharedPreferences] as well as the client because the
/// server identifies a list only by an opaque id it mints on first write —
/// lose the id and the list is unreachable, so the repository persists it.
final wishlistRepositoryProvider = Provider<WishlistRepository>(
  (ref) => WishlistRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  ),
);

final compareRepositoryProvider = Provider<CompareRepository>(
  (ref) => CompareRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  ),
);

/// The server-side cart.
///
/// Now drives the UI — see [serverCartProvider]. The local cart it replaced is
/// gone, along with the hardcoded coupon table and the client-side tax and
/// delivery arithmetic that went with it.
///
/// ⚠ This ships **ahead of** the backend fix in `docs/BACKEND_BUGS.md`
/// finding 0. `Cart::restore()` still deletes the stored row, so a refused
/// mutation can destroy the whole basket. What the client can do, it does:
/// writes are serialised, nothing is applied optimistically, and every failure
/// is followed by a re-read so the UI shows what actually survived. What it
/// cannot do is put back items the server has already dropped.
///
/// Unlike the wishlist, this repository holds no state and persists nothing —
/// the cart id belongs to whichever provider owns cart state, so that the
/// switch-over is one provider change rather than a rewrite.
final cartRepositoryProvider = Provider<CartRepository>(
  (ref) => CartRepository(ref.watch(apiClientProvider)),
);

/// `POST /checkout/cart/{id}` and `POST /checkout/confirm-payment`.
///
/// Holds no state, so a plain `Provider` like every other repository. The
/// optional `sleep` argument of the constructor is for tests driving
/// [CheckoutRepository.confirmPayment]'s backoff and is deliberately not wired
/// here.
///
/// ⚠ `placeOrder` is **not idempotent** — every call creates a real order, a
/// real Razorpay order and burns another coupon use. Nothing above this
/// provider may retry it; see the method's own doc.
final checkoutRepositoryProvider = Provider<CheckoutRepository>(
  (ref) => CheckoutRepository(ref.watch(apiClientProvider)),
);

/// The payment sheet.
///
/// Typed as the interface, not as [RazorpayGateway], so the checkout flow can
/// only reach the seam in `core/payments/payment_gateway.dart`. That is what
/// makes the flow unit-testable: a test overrides this provider with a fake
/// returning `PaymentSuccess(...)` or `PaymentCancelled()` and never touches a
/// platform channel. Swapping providers later is one line here.
///
/// Not a `ref.watch` of anything — the gateway takes no configuration. The
/// merchant key is not an app constant: it arrives per order, as
/// `data.razorpay.razorpay_key_id` from the checkout response, so nothing
/// secret lives in the client.
///
/// [PaymentGateway.dispose] holds the only reference to a sheet that is still
/// open, and completes it rather than leaving the caller's Future pending.
final paymentGatewayProvider = Provider<PaymentGateway>((ref) {
  final gateway = RazorpayGateway();
  ref.onDispose(gateway.dispose);
  return gateway;
});

import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../data/models/product_model.dart';
import '../providers/products_provider.dart';
import '../screens/auth/auth_widgets.dart';
import '../screens/auth/mobile_login_screen.dart';
import '../screens/auth/register_screen.dart';
import '../screens/cart/cart_screen.dart';
import '../screens/categories/category_browse_screen.dart';
import '../screens/checkout/checkout_screen.dart';
import '../screens/checkout/order_success_screen.dart';
import '../screens/common/webview_screen.dart';
import '../screens/main_navigation_screen.dart';
import '../screens/notifications/notifications_screen.dart';
import '../screens/orders/order_detail_screen.dart';
import '../screens/orders/order_summary_screen.dart';
import '../screens/orders/orders_screen.dart';
import '../screens/orders/return_detail_screen.dart';
import '../screens/orders/return_request_screen.dart';
import '../screens/orders/returns_screen.dart';
import '../screens/profile/account_screen.dart';
import '../screens/profile/address_book_screen.dart';
import '../screens/profile/change_password_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/wishlist/wishlist_screen.dart';
import '../screens/product/my_reviews_screen.dart';
import '../screens/product/product_detail_screen.dart';
import '../screens/product/products_screen.dart';
import '../screens/product/write_review_screen.dart';
import '../screens/search/search_screen.dart';
import '../screens/splash_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/splash',
  routes: [
    GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
    // The root is wrapped rather than the splash: the gate has to still be
    // mounted when its lookup returns, and splash routes away after ~1.4s.
    // It renders the navigation screen unchanged — all it adds is the
    // launch-time pass over the pending-order journal, which is the only way
    // an order abandoned between checkout and payment is ever found again
    // (`GET /orders` and `GET /orders/{id}` both filter `is_finished = 1`).
    GoRoute(
      path: '/',
      builder: (_, __) => const PendingOrderRecoveryGate(
        child: MainNavigationScreen(),
      ),
    ),
    GoRoute(
      path: '/products',
      builder: (_, state) {
        final q = state.uri.queryParameters;
        return ProductsScreen(
          title: q['title'] ?? 'Products',
          query: ProductQuery(
            categoryId: int.tryParse(q['category'] ?? ''),
            brandId: int.tryParse(q['brand'] ?? ''),
            search: q['search'],
          ),
        );
      },
    ),
    GoRoute(
      path: '/product/:slug',
      builder: (_, state) => ProductDetailScreen(
        slug: state.pathParameters['slug']!,
        initial: state.extra is Product ? state.extra as Product : null,
      ),
    ),
    GoRoute(path: '/cart', builder: (_, __) => const CartScreen()),
    GoRoute(path: '/checkout', builder: (_, __) => const CheckoutScreen()),
    // Carries the id in the path rather than in `extra` so it survives a
    // process restart and a deep link — the success screen's whole job is to
    // fetch `GET /orders/{id}`, and it has nothing to show without one.
    //
    // A non-numeric or missing id cannot address an order, so it falls back to
    // the orders list instead of rendering a receipt for order 0.
    GoRoute(
      path: '/order-success/:orderId',
      builder: (_, state) {
        final id = int.tryParse(state.pathParameters['orderId'] ?? '') ?? 0;
        if (id <= 0) return const OrdersScreen(showBack: true);
        return OrderSuccessScreen(orderId: id);
      },
    ),
    // The detail screen already existed and was only reachable by a
    // MaterialPageRoute pushed from the orders list. It needs a path now
    // because the success screen and the recovery SnackBar both link to it.
    // The order restated, for an order the invoice does not yet cover. Its own
    // route rather than a tab on the detail screen: it is the thing a customer
    // screenshots or shows at a doorstep, so it wants a clean page and a back
    // button of its own.
    GoRoute(
      path: '/order/:orderId/summary',
      builder: (_, state) {
        final id = int.tryParse(state.pathParameters['orderId'] ?? '') ?? 0;
        if (id <= 0) return const OrdersScreen(showBack: true);
        return OrderSummaryScreen(orderId: id);
      },
    ),
    GoRoute(
      path: '/order/:orderId',
      builder: (_, state) {
        final id = int.tryParse(state.pathParameters['orderId'] ?? '') ?? 0;
        if (id <= 0) return const OrdersScreen(showBack: true);
        return OrderDetailScreen(orderId: id);
      },
    ),
    GoRoute(path: '/search', builder: (_, __) => const SearchScreen()),
    GoRoute(path: '/login', builder: (_, __) => const MobileLoginScreen()),
    GoRoute(
      path: '/register',
      builder: (_, state) => RegisterScreen(
        prefill: state.extra is RegisterPrefill
            ? state.extra! as RegisterPrefill
            : null,
      ),
    ),
    // Pushed from the Account tab; the same screen also lives as a bottom-nav
    // tab, where it needs no back button.
    GoRoute(path: '/orders', builder: (_, __) => const OrdersScreen(showBack: true)),
    GoRoute(path: '/returns', builder: (_, __) => const ReturnsScreen()),
    GoRoute(path: '/reviews', builder: (_, __) => const MyReviewsScreen()),
    // Keyed on the product **id**, because `POST /ecommerce/reviews` takes
    // `product_id`. The name and slug ride along as query parameters so the
    // form can show what is being reviewed and refresh the right feed after.
    GoRoute(
      path: '/product/:productId/review',
      builder: (_, state) => WriteReviewScreen(
        productId: int.tryParse(state.pathParameters['productId'] ?? '') ?? 0,
        productName: state.uri.queryParameters['name'],
        productSlug: state.uri.queryParameters['slug'],
      ),
    ),
    GoRoute(
      path: '/returns/:returnId',
      builder: (_, state) => ReturnDetailScreen(
        returnId: int.tryParse(state.pathParameters['returnId'] ?? '') ?? 0,
      ),
    ),
    // Keyed on the *order*, because that is what a return is raised against and
    // what `GET /orders/{id}/returns` takes.
    GoRoute(
      path: '/order/:orderId/return',
      builder: (_, state) => ReturnRequestScreen(
        orderId: int.tryParse(state.pathParameters['orderId'] ?? '') ?? 0,
      ),
    ),
    GoRoute(
      path: '/notifications',
      builder: (_, __) => const NotificationsScreen(),
    ),
    GoRoute(path: '/account', builder: (_, __) => const AccountScreen(showBack: true)),
    // Every ProfileController route is behind `auth:sanctum`; the screen renders
    // a sign-in prompt rather than failing, so a deep link while signed out is
    // safe.
    GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
    GoRoute(
      path: '/profile/password',
      builder: (_, __) => const ChangePasswordScreen(),
    ),
    // The create/edit form deliberately has no route: it takes an Address
    // object and there is no GET /ecommerce/addresses/{id} to rebuild one from
    // (the server answers "Supported methods: PUT, DELETE"), so a deep link to
    // "edit address 16" could not be honoured. The book pushes it directly.
    GoRoute(path: '/addresses', builder: (_, __) => const AddressBookScreen()),

    // Not behind the auth gate: the wishlist API is anonymous (X-API-KEY only,
    // the bearer token is ignored), so a signed-out customer can save products
    // and still have them after signing in — the identifier is what carries the
    // list, not the session.
    GoRoute(path: '/wishlist', builder: (_, __) => const WishlistScreen()),
    // Opened from a tile on the Categories tab. A non-numeric or unknown id
    // still renders — the screen falls back to the first sibling in the tree
    // rather than showing an empty rail.
    GoRoute(
      path: '/category/:id',
      builder: (_, state) => CategoryBrowseScreen(
        categoryId: int.tryParse(state.pathParameters['id'] ?? '') ?? 0,
      ),
    ),
    GoRoute(
      path: '/web',
      builder: (_, state) => WebViewScreen(
        // `AppConfig.origin`, not a literal: this was hardcoded to the dev
        // server, so a build pointed elsewhere by `--dart-define=API_ORIGIN`
        // would still open the dev site whenever a `/web` link arrived without
        // a `url` parameter.
        url: state.uri.queryParameters['url'] ?? AppConfig.origin,
        title: state.uri.queryParameters['title'],
      ),
    ),
  ],
);

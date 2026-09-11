/// What the cart puts on screen when the server refuses something.
///
/// The distinction these pin: a **refused action** is transient and belongs
/// beside the control that was refused, while a **rebuilt basket** is a standing
/// fact about what is on screen and has to survive being read.
///
/// Getting that wrong was visible: a "+" tapped on the *home grid* surfaced as a
/// red panel at the top of the cart — two screens from the tap — quoting the
/// server's "…of Trueway Farms Organic Desi Khand Brown (khandsari) at a time.
/// Please adjust the quantity and try again.", and it stayed there after the
/// customer had understood and moved on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/data/repositories/cart_repository.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/server_cart_provider.dart';
import 'package:trueway_farms/presentation/screens/cart/cart_screen.dart';

import '../support/fake_cart_repository.dart';

const _line = FakeCartLine(
  id: 118,
  name: 'Trueway Farms Organic Desi Khand Brown (khandsari)',
  quantity: 2,
  unitPrice: 899,
);

/// The refusal the server sends for an over-limit quantity, verbatim.
ApiException _limitRefusal() => ApiException(
      'Sorry, you can only order a maximum of 2 units of Trueway Farms '
      'Organic Desi Khand Brown (khandsari) at a time. Please adjust the '
      'quantity and try again.',
      kind: ApiErrorKind.businessRule,
      statusCode: 422,
    );

Future<(ProviderContainer, FakeCartRepository)> _container() async {
  SharedPreferences.setMockInitialValues({'server_cart_id_v1': 'cart-test'});
  final prefs = await SharedPreferences.getInstance();
  final repo = FakeCartRepository(lines: const [_line]);

  return (
    ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        cartRepositoryProvider.overrideWithValue(repo),
        isAuthenticatedProvider.overrideWithValue(false),
      ],
    ),
    repo,
  );
}

Future<void> _showCart(WidgetTester tester, ProviderContainer c) async {
  // The cart is long and a ListView does not build what it cannot show.
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: CartScreen(showBack: false)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a refused action does NOT become a banner', (tester) async {
    final (c, repo) = await _container();
    addTearDown(c.dispose);
    await _showCart(tester, c);

    repo.nextError = _limitRefusal();
    await c.read(serverCartProvider.notifier).increment(
          c.read(serverCartProvider).items.first.lineId,
        );
    await tester.pumpAndSettle();

    // The heading the panel used to carry, and the server's sentence with it.
    expect(find.text("That didn't go through"), findsNothing);
    expect(find.textContaining('Please adjust the quantity'), findsNothing);
    expect(find.textContaining('at a time'), findsNothing);
  });

  testWidgets('a rebuilt basket still does', (tester) async {
    // The case the banner exists for: the customer did not do this, cannot see
    // it from the line items, and needs it to still be there when they check
    // the total.
    final (c, repo) = await _container();
    addTearDown(c.dispose);
    await _showCart(tester, c);

    // `itemsLost` is derived from the rebuild outcome, not set directly — a
    // lost line is a fact about what the rebuild managed, not a flag.
    c.read(serverCartProvider.notifier).state =
        c.read(serverCartProvider).copyWith(
              recoveryMessage: 'Your basket was rebuilt, but 1 item could not '
                  'be restored.',
              rebuild: const CartRebuildOutcome(linesRestored: 1, linesLost: 1),
            );
    await tester.pumpAndSettle();

    expect(find.text('Some items could not be put back'), findsOneWidget);
    expect(find.textContaining('1 item could not be restored'), findsOneWidget);
  });

  testWidgets('a clean cart carries no banner at all', (tester) async {
    final (c, repo) = await _container();
    addTearDown(c.dispose);
    await _showCart(tester, c);

    expect(find.text("That didn't go through"), findsNothing);
    expect(find.text('We rebuilt your basket'), findsNothing);
    expect(find.text('Some items could not be put back'), findsNothing);
    // Sanity: the cart really did render.
    expect(find.textContaining('Desi Khand Brown'), findsWidgets);
    expect(repo.calls, isNotEmpty);
  });
}

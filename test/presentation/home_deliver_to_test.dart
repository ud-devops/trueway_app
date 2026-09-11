/// The home header's "Deliver to" control.
///
/// What these pin, in one sentence each:
///
///   * it never shows an address the customer did not choose — this shipped as
///     the literal string `'Ahmedabad · 382415'`, so every customer in the
///     country was told the shop's own neighbourhood was theirs;
///   * it reads the SAME store the cart bill and the checkout picker read, so
///     the header cannot name one destination while the bill prices another;
///   * it is actually tappable. The caret was drawn from the first build with
///     no handler behind it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_icons.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/ad_model.dart';
import 'package:trueway_farms/data/models/address.dart';
import 'package:trueway_farms/data/models/app_notification.dart';
import 'package:trueway_farms/data/models/category_model.dart';
import 'package:trueway_farms/data/models/customer.dart';
import 'package:trueway_farms/data/models/home_sections.dart';
import 'package:trueway_farms/data/models/product_model.dart';
import 'package:trueway_farms/data/models/slider_model.dart';
import 'package:trueway_farms/data/repositories/address_repository.dart';
import 'package:trueway_farms/data/repositories/auth_repository.dart';
import 'package:trueway_farms/presentation/widgets/app_network_image.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/home_providers.dart';
import 'package:trueway_farms/presentation/providers/notification_provider.dart';
import 'package:trueway_farms/presentation/screens/home/home_screen.dart';

/// Restoring a session must make no request.
class _FakeAuthRepository implements AuthRepository {
  @override
  Future<bool> validateSession() async => true;

  /// Reached on the signed-out path too: a missing token makes [AuthNotifier]
  /// clear whatever else was persisted, which goes through the repository.
  @override
  Future<void> logout() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A book with whatever rows the test wants, so the chooser has something to
/// open onto.
class _FakeAddressRepository implements AddressRepository {
  _FakeAddressRepository(this.rows);

  final List<Address> rows;

  @override
  Future<List<Address>> all() async => rows;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

Address _address() => Address.fromJson({
      'id': 16,
      'name': 'Gwalior home',
      'phone': '9876543210',
      'address': '306, Ring Road',
      'city': 'Gwalior',
      'state': 'Madhya Pradesh',
      'country': 'India',
      'zip_code': '474010',
      'is_default': true,
    });

/// Pumps the real [HomeScreen] with every network-backed feed stubbed, so the
/// header is the only thing that can move.
Future<void> _pump(
  WidgetTester tester, {
  required bool signedIn,
  Map<String, Object> stored = const {},
  List<Address> book = const [],
  Customer? customer,
}) async {
  await tester.binding.setSurfaceSize(const Size(400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  // [AuthNotifier] restores from SharedPreferences in its constructor, so a
  // customer is seeded there rather than by overriding the notifier — a token
  // and a cached customer together are what "signed in" means.
  SharedPreferences.setMockInitialValues({
    ...stored,
    if (customer != null) ...{
      'auth_token': 'placeholder-not-a-real-token',
      'auth_customer_v1': jsonEncode(customer.toJson()),
    },
  });
  final prefs = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isAuthenticatedProvider.overrideWithValue(signedIn),
        addressRepositoryProvider
            .overrideWithValue(_FakeAddressRepository(book)),
        authRepositoryProvider.overrideWithValue(_FakeAuthRepository()),
        homeSectionsProvider.overrideWith(
          (ref) async => const HomeSections(
            trending: [],
            topSelling: [],
            recentlyAdded: [],
            topRated: [],
          ),
        ),
        slidersProvider.overrideWith((ref) async => const <HomeSlider>[]),
        adsProvider.overrideWith((ref) async => const <AdBanner>[]),
        categoriesProvider.overrideWith((ref) async => const <Category>[]),
        featuredProductsProvider.overrideWith((ref) async => const <Product>[]),
        // The home feed asks for flash sales too. Empty is the live answer on
        // this store, and it keeps the test off the network.
        flashSalesProvider.overrideWith((ref) async => const <FlashSale>[]),
        notificationStatsProvider
            .overrideWith((ref) async => const NotificationStats()),
      ],
      child: MaterialApp(theme: AppTheme.light, home: const HomeScreen()),
    ),
  );
  await tester.pump();
}

/// The stored shape of a chosen destination, as `DeliveryLocationNotifier`
/// persists it.
Map<String, Object> _chosen() => {
      'delivery_address_id': 16,
      'delivery_address_pin': '474010',
      'delivery_address_name': 'Gwalior home',
      'delivery_address_line': '306, Ring Road, Gwalior',
    };

void main() {
  testWidgets('shows the chosen address, not a hardcoded one', (tester) async {
    await _pump(tester, signedIn: true, stored: _chosen());

    expect(find.text('Gwalior home · 474010'), findsOneWidget);
    // The string this replaced. If it ever comes back, it comes back for every
    // customer at once.
    expect(find.textContaining('Ahmedabad'), findsNothing);
    expect(find.textContaining('382415'), findsNothing);
  });

  testWidgets('asks for an address rather than guessing one', (tester) async {
    await _pump(tester, signedIn: true);

    expect(find.text('Select delivery address'), findsOneWidget);
  });

  testWidgets('signed out, it names no place at all', (tester) async {
    // The address book is bearer-only, so there is nothing to read and nothing
    // honest to display. Naming a city here would be the original bug with a
    // different string in it.
    await _pump(tester, signedIn: false);

    expect(find.text('Sign in to set your address'), findsOneWidget);
  });

  testWidgets('the caret is not decoration — tapping opens the chooser',
      (tester) async {
    await _pump(tester, signedIn: true, book: [_address()]);

    await tester.tap(find.byKey(const Key('home-deliver-to')));
    await tester.pumpAndSettle();

    // The shared sheet, the same one the cart and checkout open.
    expect(find.text('Add a new address'), findsOneWidget);
  });

  testWidgets('signed out the tap still opens the sheet, never a dead tap',
      (tester) async {
    await _pump(tester, signedIn: false);

    await tester.tap(find.byKey(const Key('home-deliver-to')));
    await tester.pumpAndSettle();

    // The sheet explains why there is no book, rather than nothing happening.
    expect(find.text('Deliver to'), findsWidgets);
  });

  // The account button in the same header. It used to be a person glyph for
  // everyone, signed in or not.
  group('account button', () {
    testWidgets('signed out it stays a glyph — there is no one to picture',
        (tester) async {
      await _pump(tester, signedIn: false);

      expect(find.byIcon(AppIcons.user), findsOneWidget);
    });

    testWidgets('shows initials when the server holds no uploaded picture',
        (tester) async {
      // The server *does* send an avatar for these customers, but it is a
      // generated-initials PNG embedded as a base64 `data:` URI — several KB,
      // re-encoded per request, cacheable by nothing. `Customer.fromJson`
      // strips it, and these are the same initials without the payload.
      await _pump(
        tester,
        signedIn: true,
        customer: const Customer(
          id: 1,
          name: 'Suraj ojha',
          avatar: 'data:image/png;base64,iVBORw0KGgo=',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('SO'), findsOneWidget);
      expect(find.byIcon(AppIcons.user), findsNothing);
    });

    testWidgets('shows the picture when there is a real upload',
        (tester) async {
      await _pump(
        tester,
        signedIn: true,
        customer: const Customer(
          id: 1,
          name: 'Suraj ojha',
          avatar: 'https://dev.truewayerp.com/storage/users/suraj-150x150.jpg',
        ),
      );
      // Not `pumpAndSettle`: the image placeholder's spinner never stops under
      // a test binding, so it would time out rather than settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final image = tester.widget<AppNetworkImage>(
        find.descendant(
          of: find.byType(ClipOval),
          matching: find.byType(AppNetworkImage),
        ),
      );
      expect(image.url, endsWith('suraj-150x150.jpg'));
      expect(find.text('SO'), findsNothing);
    });
  });
}

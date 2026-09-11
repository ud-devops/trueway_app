import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/data/models/address.dart';
import 'package:trueway_farms/data/models/shipping_quote.dart';
import 'package:trueway_farms/data/repositories/address_repository.dart';
import 'package:trueway_farms/presentation/providers/address_provider.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/checkout_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/delivery_location_provider.dart';
import 'package:trueway_farms/presentation/providers/shipping_provider.dart';
import 'package:trueway_farms/presentation/widgets/delivery_location_bar.dart';

/// The cart's shipping block: the address it ships to, the sheet that chooses
/// it, and the courier options the customer now picks from *before* checkout.
///
/// Nothing here touches the network. [shippingRatesFetcherProvider] is the one
/// seam onto `LogisticsRepository`, [checkoutParcelProvider] the one seam onto
/// the catalogue, and [addressRepositoryProvider] the one seam onto the address
/// book; all three are overridden in every test, so no ApiClient — and therefore
/// no socket — is ever constructed.

// ---------------------------------------------------------------------------
// Fixtures — courier rows as `check-serviceability` sends them, with upstream's
// own types: estimated_delivery_days is the String "3", cod is the int 1/0.
// ---------------------------------------------------------------------------

CourierOption _courier({
  required int id,
  required String name,
  required num rate,
  required String days,
  String etd = '',
  int cod = 1,
}) =>
    CourierOption.fromJson({
      'courier_company_id': id,
      'courier_name': name,
      'rate': rate,
      'freight_charge': rate,
      'cod_charges': 0,
      'cod': cod,
      'estimated_delivery_days': days,
      'etd': etd,
      'city': 'DELHI',
      'delivery_performance': 5,
    });

/// Fastest *and* cheapest among the 3-day rows, so `findBestCourier` picks it.
final _blueDartSurface = _courier(
  id: 55,
  name: 'Blue Dart Surface',
  rate: 180.6,
  days: '3',
  etd: 'Aug 04, 2026',
);

final _dtdcAir = _courier(
  id: 196,
  name: 'DTDC Air 500gm',
  rate: 224.49,
  days: '3',
  etd: 'Aug 04, 2026',
);

/// Cheapest overall and therefore *not* the preselection — it is two days
/// slower, and speed outranks price in the web's rule.
final _indiaPost = _courier(
  id: 15123,
  name: 'India Post - Speed Post_2.0',
  rate: 106.2,
  days: '5',
  etd: 'Aug 06, 2026',
);

/// The same courier company as [_indiaPost], re-quoted dearer — what a second
/// serviceability call for the same parcel can legitimately come back with.
final _indiaPostDearer = _courier(
  id: 15123,
  name: 'India Post - Speed Post_2.0',
  rate: 149.9,
  days: '5',
  etd: 'Aug 06, 2026',
);

final _indiaPostPrepaid = _courier(
  id: 400,
  name: 'India Post Prepaid',
  rate: 108.56,
  days: '5',
  etd: 'Aug 06, 2026',
  cod: 0,
);

List<CourierOption> get _liveList => [
      _dtdcAir,
      _indiaPost,
      _indiaPostPrepaid,
      _blueDartSurface,
    ];

// ---------------------------------------------------------------------------
// Fixtures — address rows, copied from a captured GET /ecommerce/addresses.
// ---------------------------------------------------------------------------

Address _address({
  required int id,
  required String name,
  required String zip,
  bool isDefault = false,
  String line = '306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad',
}) =>
    Address.fromJson({
      'id': id,
      'name': name,
      // The list route sends 1/0, not true/false.
      'is_default': isDefault ? 1 : 0,
      'phone': '8305317276',
      'email': 'suraj.ojha@uminber.in',
      'country': 'India',
      'state': '11',
      'city': '574',
      'address': line,
      'zip_code': zip,
      'full_address': '$line, Ahmedabad, Gujarat, $zip',
    });

/// The account's server-flagged default.
final _home = _address(
  id: 16,
  name: 'Suraj ojha',
  zip: '382415',
  isDefault: true,
);

final _gwalior = _address(
  id: 50,
  name: 'Gwalior home',
  zip: '474010',
  line: '402, ganesh rivera',
);

/// A destination nothing services, for the refusal path.
final _nowhere = _address(id: 77, name: 'Nowhere', zip: '999999');

/// A row saved through the server's lenient rules: `zip_code` is only
/// `nullable|max:20`, so a PIN-less address is a real thing in the book.
final _noPin = _address(id: 61, name: 'No PIN', zip: '');

/// The packed box the cart API's `package_dimensions` block describes, in the
/// units `check-serviceability` wants: kilograms and centimetres.
const _parcel = CheckoutParcel(
  weightKg: 5,
  lengthCm: 19,
  breadthCm: 6,
  heightCm: 24,
  declaredValue: 1887.9,
  unweighedLines: 0,
);

/// The query the card builds for a pincode — the same one checkout builds,
/// because both go through [CheckoutParcel.toQuery].
ShippingQuery _queryFor(String pin) => _parcel.toQuery(pin);

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Records its calls, so a test can prove Retry re-fetches rather than
/// replaying a cached answer.
class _RecordingFetcher {
  _RecordingFetcher(this._answer);

  final Future<ShippingRates> Function(ShippingQuery) _answer;
  final List<ShippingQuery> calls = [];

  Future<ShippingRates> call(ShippingQuery query) {
    calls.add(query);
    return _answer(query);
  }
}

ShippingRatesFetcher _ready(List<CourierOption> options) =>
    (_) async => ShippingRates.fromCouriers(options);

class _FakeAddressRepository implements AddressRepository {
  _FakeAddressRepository({List<Address> rows = const [], this.error, this.delay})
      : rows = List.of(rows);

  List<Address> rows;
  ApiException? error;
  final Duration? delay;

  int reads = 0;

  @override
  Future<List<Address>> all() async {
    reads++;
    if (delay != null) await Future<void>.delayed(delay!);
    if (error != null) throw error!;
    return List.of(rows);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// The shape [DeliveryLocationNotifier] persists a chosen address as.
Map<String, Object> _persisted(Address address) => {
      'delivery_address_id': address.id,
      'delivery_address_pin': address.zipCode,
      'delivery_address_name': address.name,
      'delivery_address_line': address.displayAddress,
    };

Future<Widget> _host(
  Widget child, {
  required ShippingRatesFetcher fetcher,
  List<Address> book = const [],
  ApiException? bookError,
  Duration? bookDelay,
  Map<String, Object>? prefs,
  CheckoutParcel parcel = _parcel,
  Object? parcelError,
  Duration? parcelDelay,
  bool signedIn = true,
  _FakeAddressRepository? repo,
}) async {
  SharedPreferences.setMockInitialValues(prefs ?? <String, Object>{});
  final store = await SharedPreferences.getInstance();

  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(store),
      shippingRatesFetcherProvider.overrideWithValue(fetcher),
      addressRepositoryProvider.overrideWithValue(
        repo ??
            _FakeAddressRepository(
              rows: book,
              error: bookError,
              delay: bookDelay,
            ),
      ),
      checkoutParcelProvider.overrideWith((ref) async {
        if (parcelDelay != null) await Future<void>.delayed(parcelDelay);
        if (parcelError != null) throw parcelError;
        return parcel;
      }),
      isAuthenticatedProvider.overrideWithValue(signedIn),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      // The card is a fragment mounted inside the cart's ListView; anything that
      // needs bounded height blows up here rather than in production.
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    ),
  );
}

/// The bar, with sign-in stubbed: the real one pushes `/login` through
/// GoRouter, which this harness has no router for.
Widget _bar() => DeliveryLocationBar(onSignInRequested: () {});

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(DeliveryLocationBar)),
    );

/// The group value the radios are actually sharing.
int? _groupValue(WidgetTester tester) => RadioGroup.maybeOf<int>(
      tester.element(find.byType(Radio<int>).first),
    )?.groupValue;

/// Opens the shared chooser from the card.
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('Change'));
  await tester.pumpAndSettle();
}

void main() {
  // ------------------------------------------------------------------
  // Signed out: no address book, so no destination — and the removed pincode
  // field means there is no longer any way for them to conjure one.
  // ------------------------------------------------------------------
  group('signed out', () {
    testWidgets('offers sign-in, reads no address book, quotes nothing',
        (tester) async {
      final repo = _FakeAddressRepository(rows: [_home]);
      var quoted = false;

      await tester.pumpWidget(await _host(
        _bar(),
        signedIn: false,
        repo: repo,
        fetcher: (_) async {
          quoted = true;
          return ShippingRates.fromCouriers(_liveList);
        },
      ),);
      await tester.pumpAndSettle();

      expect(find.text('Sign in to choose a delivery address'), findsOneWidget);
      expect(find.byKey(const Key('cart-address-signin')), findsOneWidget);
      expect(
        repo.reads,
        0,
        reason: 'GET /ecommerce/addresses is bearer-only — reading it without a '
            'token 401s, which ApiClient turns into a forced sign-out',
      );
      expect(quoted, isFalse, reason: 'no destination, nothing to quote');
      // The cart stays usable: a subtotal, and no invented charge.
      expect(_containerOf(tester).read(cartDeliveryChargeProvider), isNull);
    });

    // The stored destination belongs to the account that chose it.
    testWidgets('drops a destination left over from a signed-in session',
        (tester) async {
      await tester.pumpWidget(await _host(
        _bar(),
        signedIn: false,
        prefs: _persisted(_gwalior),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      final container = _containerOf(tester);
      expect(container.read(deliveryLocationProvider), isNull);
      expect(container.read(cartDeliveryChargeProvider), isNull);
      expect(find.textContaining('Gwalior'), findsNothing);
    });
  });

  // ------------------------------------------------------------------
  // Request 1: the pincode field is gone, and one sheet serves both screens.
  // ------------------------------------------------------------------
  group('the shared address sheet', () {
    testWidgets('has no pincode field and no "Use this pincode" button',
        (tester) async {
      await tester.pumpWidget(await _host(
        _bar(),
        book: [_home, _gwalior],
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();
      await _openSheet(tester);

      expect(
        find.byType(TextField),
        findsNothing,
        reason: 'the address carries the pincode; asking for it twice let the '
            'two disagree',
      );
      expect(find.text('Use this pincode'), findsNothing);
      expect(find.text('Delivery pincode'), findsNothing);

      // What is left is the address book, plus the way to grow it.
      expect(find.byKey(const ValueKey('address-option-16')), findsOneWidget);
      expect(find.byKey(const ValueKey('address-option-50')), findsOneWidget);
      expect(find.byKey(const Key('address-picker-add')), findsOneWidget);
    });

    testWidgets('opens with the address in use already selected',
        (tester) async {
      await tester.pumpWidget(await _host(
        _bar(),
        book: [_home, _gwalior],
        prefs: _persisted(_gwalior),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();
      await _openSheet(tester);

      // Exactly one filled radio, and it is on the row the cart is using —
      // opening the sheet on the *default* would invite the customer to
      // re-confirm a choice they did not make.
      expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('address-option-50')),
          matching: find.byIcon(Icons.radio_button_checked_rounded),
        ),
        findsOneWidget,
      );
    });
  });

  // ------------------------------------------------------------------
  // Request 5: the destination is an address, and it is the one checkout
  // starts from.
  // ------------------------------------------------------------------
  group('address-driven destination', () {
    testWidgets('opens on the server-flagged default and quotes for its pincode',
        (tester) async {
      final seen = <String>[];
      await tester.pumpWidget(await _host(
        _bar(),
        book: [_gwalior, _home],
        fetcher: (q) async {
          seen.add(q.pinCode);
          return ShippingRates.fromCouriers(_liveList);
        },
      ),);
      await tester.pumpAndSettle();

      expect(find.text('Shipping to'), findsOneWidget);
      expect(find.text('Suraj ojha'), findsOneWidget);
      expect(
        seen,
        ['382415'],
        reason: 'the default row, not the first one in the list',
      );
      expect(
        _containerOf(tester).read(selectedDeliveryAddressIdProvider),
        _home.id,
      );
    });

    testWidgets('picking another address re-quotes and is what checkout starts '
        'from', (tester) async {
      final seen = <String>[];
      await tester.pumpWidget(await _host(
        _bar(),
        book: [_home, _gwalior],
        fetcher: (q) async {
          seen.add(q.pinCode);
          return ShippingRates.fromCouriers(_liveList);
        },
      ),);
      await tester.pumpAndSettle();
      expect(seen, ['382415']);

      await _openSheet(tester);
      await tester.tap(find.text('Gwalior home'));
      await tester.pumpAndSettle();

      expect(find.text('Gwalior home'), findsOneWidget);
      expect(
        seen,
        ['382415', '474010'],
        reason: 'the quote is a function of the destination, so it re-runs',
      );

      final container = _containerOf(tester);
      // The one assertion this whole request exists for: checkout seeds its
      // picker from here, so it cannot open on the default after the customer
      // chose something else on the cart.
      expect(container.read(selectedDeliveryAddressIdProvider), _gwalior.id);
      expect(container.read(deliveryLocationProvider)!.pinCode, '474010');
    });

    testWidgets('survives a restart', (tester) async {
      await tester.pumpWidget(await _host(
        _bar(),
        book: [_home, _gwalior],
        prefs: _persisted(_gwalior),
        // Slow book read, so the first frames are the cold-start ones.
        bookDelay: const Duration(milliseconds: 50),
        fetcher: _ready(_liveList),
      ),);
      await tester.pump();

      expect(
        find.text('Gwalior home'),
        findsOneWidget,
        reason: 'the choice is named from prefs before the book read lands',
      );

      await tester.pumpAndSettle();
      expect(
        _containerOf(tester).read(selectedDeliveryAddressIdProvider),
        _gwalior.id,
      );
    });

    // The chosen row can change under us: the web and the profile screen write
    // to the same book.
    testWidgets('follows an edit to the chosen address', (tester) async {
      final seen = <String>[];
      final moved = _address(id: 50, name: 'Gwalior home', zip: '452001');

      await tester.pumpWidget(await _host(
        _bar(),
        book: [_home, moved],
        prefs: _persisted(_gwalior), // stored with its old 474010
        fetcher: (q) async {
          seen.add(q.pinCode);
          return ShippingRates.fromCouriers(_liveList);
        },
      ),);
      await tester.pumpAndSettle();

      expect(_containerOf(tester).read(deliveryLocationProvider)!.pinCode,
          '452001',);
      // The cached 474010 is what the cold start quotes for — that is the point
      // of caching it — but the reconcile has to overtake it, because the id did
      // not change and nothing else would notice.
      expect(seen.first, '474010');
      expect(seen.last, '452001');
    });

    testWidgets('falls back to the default when the chosen address is deleted',
        (tester) async {
      await tester.pumpWidget(await _host(
        _bar(),
        book: [_home],
        prefs: _persisted(_gwalior),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      final container = _containerOf(tester);
      expect(container.read(selectedDeliveryAddressIdProvider), _home.id);
      expect(
        find.text('Gwalior home'),
        findsNothing,
        reason: 'the cart would otherwise name an address checkout cannot use',
      );
    });

    // The server's `zip_code` rule is only `nullable|max:20`.
    testWidgets('refuses an address with no PIN code and says why',
        (tester) async {
      await tester.pumpWidget(await _host(
        _bar(),
        book: [_home, _noPin],
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();
      await _openSheet(tester);

      await tester.tap(find.text('No PIN'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('has no PIN code'),
        findsOneWidget,
        reason: 'a silent no-op reads as a broken card',
      );
      expect(
        _containerOf(tester).read(selectedDeliveryAddressIdProvider),
        _home.id,
        reason: 'the destination that could be quoted is left alone',
      );
    });

    testWidgets('an empty book asks for a first address, and quotes nothing',
        (tester) async {
      var quoted = false;
      await tester.pumpWidget(await _host(
        _bar(),
        fetcher: (_) async {
          quoted = true;
          return ShippingRates.fromCouriers(_liveList);
        },
      ),);
      await tester.pumpAndSettle();

      expect(find.text('Add a shipping address'), findsOneWidget);
      expect(quoted, isFalse);
      expect(_containerOf(tester).read(cartDeliveryChargeProvider), isNull);
    });

    testWidgets('a failed book read is reported with a retry, not a charge',
        (tester) async {
      final repo = _FakeAddressRepository(
        rows: [_home],
        error: const ApiException(
          'Network unreachable',
          kind: ApiErrorKind.network,
        ),
      );
      await tester.pumpWidget(await _host(
        _bar(),
        repo: repo,
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      expect(find.textContaining('Network unreachable'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(_containerOf(tester).read(cartDeliveryChargeProvider), isNull);

      repo.error = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Suraj ojha'), findsOneWidget);
      // The book is back, so the quote can run — but a charge still waits on the
      // customer choosing a courier. "Retry succeeded" and "delivery priced"
      // are two different things.
      final container = _containerOf(tester);
      expect(container.read(cartDeliveryChargeProvider), isNull);

      container
          .read(shippingChoiceProvider.notifier)
          .select(_queryFor('382415'), _blueDartSurface);
      await tester.pumpAndSettle();
      expect(
        container.read(cartDeliveryChargeProvider),
        _blueDartSurface.billedPrice,
      );
    });

    // A failed *refresh* is not evidence that the address was deleted.
    testWidgets('keeps the destination when a later read fails',
        (tester) async {
      final repo = _FakeAddressRepository(rows: [_home, _gwalior]);
      await tester.pumpWidget(await _host(
        _bar(),
        repo: repo,
        prefs: _persisted(_gwalior),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      final container = _containerOf(tester);
      expect(container.read(selectedDeliveryAddressIdProvider), _gwalior.id);

      repo.error = const ApiException('boom', kind: ApiErrorKind.network);
      await container.read(addressBookProvider.notifier).refresh();
      await tester.pumpAndSettle();

      expect(
        container.read(selectedDeliveryAddressIdProvider),
        _gwalior.id,
        reason: 'clearing on a hiccup would drop the quote every time the '
            'network wobbled',
      );
    });
  });

  // ------------------------------------------------------------------
  // The three quote states that must never collapse into each other.
  // ------------------------------------------------------------------
  group('quote states', () {
    testWidgets('in flight: says it is checking, prints no number',
        (tester) async {
      final never = Completer<ShippingRates>();
      await tester.pumpWidget(await _host(
        _bar(),
        book: [_home],
        prefs: _persisted(_home),
        fetcher: (_) => never.future,
      ),);
      await tester.pump();
      await tester.pump();

      expect(find.text('Checking shipping…'), findsOneWidget);
      expect(find.textContaining("We don't deliver"), findsNothing);
      expect(find.textContaining('Retry'), findsNothing);
      expect(find.textContaining('180.60'), findsNothing);
      expect(find.textContaining('0.00'), findsNothing);

      never.complete(ShippingRates.unavailable());
      await tester.pumpAndSettle();
    });

    testWidgets('the cart is still being weighed reads as checking too',
        (tester) async {
      await tester.pumpWidget(await _host(
        _bar(),
        book: [_home],
        prefs: _persisted(_home),
        parcelDelay: const Duration(milliseconds: 50),
        fetcher: _ready(_liveList),
      ),);
      await tester.pump();

      expect(find.text('Checking shipping…'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('Checking shipping…'), findsNothing);
      expect(find.textContaining('Blue Dart Surface'), findsOneWidget);
    });

    testWidgets('failure: an error with a Retry that re-fetches',
        (tester) async {
      var fail = true;
      final fetcher = _RecordingFetcher((_) async {
        if (fail) {
          throw const ApiException(
            'Service temporarily unavailable',
            kind: ApiErrorKind.server,
            statusCode: 500,
          );
        }
        return ShippingRates.fromCouriers(_liveList);
      });

      await tester.pumpWidget(await _host(
        _bar(),
        book: [_home],
        fetcher: fetcher.call,
      ),);
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't check shipping"), findsOneWidget);
      expect(
        find.textContaining('Service temporarily unavailable'),
        findsOneWidget,
      );
      // A failure is not a refusal and it is not free.
      expect(find.textContaining("We don't deliver"), findsNothing);
      expect(find.textContaining('FREE'), findsNothing);
      expect(fetcher.calls, hasLength(1));

      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(fetcher.calls, hasLength(2));
      // The quote is back and the options are on offer — none of them chosen.
      expect(find.text('Choose a delivery option'), findsOneWidget);
      expect(find.byType(Radio<int>), findsNWidgets(_liveList.length));
    });

    testWidgets('a failure to weigh the cart is retryable too', (tester) async {
      await tester.pumpWidget(await _host(
        _bar(),
        book: [_home],
        parcelError: const ApiException(
          'Network unreachable',
          kind: ApiErrorKind.network,
        ),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't check shipping"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    // The state the block exists for. No delivery and free delivery are
    // different things.
    testWidgets('undeliverable: a refusal, never a zero and never FREE',
        (tester) async {
      await tester.pumpWidget(await _host(
        _bar(),
        book: [_nowhere],
        fetcher: (_) async => ShippingRates.unavailable(
          'No courier service available between 110001 and 999999',
        ),
      ),);
      await tester.pumpAndSettle();

      expect(find.text("We don't deliver to 999999 yet"), findsOneWidget);
      expect(
        find.textContaining('No courier service available'),
        findsOneWidget,
        reason: "the server's own explanation is shown verbatim",
      );
      expect(find.textContaining('FREE'), findsNothing);
      expect(find.textContaining('0.00'), findsNothing);
      expect(find.text('Checking shipping…'), findsNothing);
      expect(find.byType(Radio<int>), findsNothing);

      // And nothing may reach the bill as a charge.
      expect(_containerOf(tester).read(cartDeliveryChargeProvider), isNull);
    });

    testWidgets('an empty courier list refuses too', (tester) async {
      await tester.pumpWidget(await _host(
        _bar(),
        book: [_home],
        fetcher: (_) async => ShippingRates.fromCouriers(const []),
      ),);
      await tester.pumpAndSettle();

      expect(find.textContaining("We don't deliver to 382415"), findsOneWidget);
      expect(_containerOf(tester).read(cartDeliveryChargeProvider), isNull);
    });
  });

  // ------------------------------------------------------------------
  // The list, and the collapse that keeps it cart-sized.
  // ------------------------------------------------------------------
  group('courier options', () {
    Future<void> pumpList(
      WidgetTester tester, {
      ShippingRatesFetcher? fetcher,
      CheckoutParcel parcel = _parcel,
    }) async {
      await tester.pumpWidget(await _host(
        _bar(),
        book: [_home],
        parcel: parcel,
        fetcher: fetcher ?? _ready(_liveList),
      ),);
      await tester.pumpAndSettle();
    }

    // This block used to collapse onto `options.first` and present it — date,
    // courier and price — as though it had been chosen. It asks now.
    testWidgets('asks instead of collapsing onto a courier nobody picked',
        (tester) async {
      await pumpList(tester);

      expect(find.byKey(const Key('cart-choose-delivery')), findsOneWidget);
      expect(find.text('Choose a delivery option'), findsOneWidget);
      expect(find.textContaining('4 couriers deliver here'), findsOneWidget);
      // ...and says what the tap is *for*, because the bill below still reads
      // "Subtotal" and that needs explaining.
      expect(find.textContaining('pick one to see your total'), findsOneWidget);
      // No decision is implied: no "N more options", no price on the summary
      // row, and nothing is checked.
      expect(find.textContaining('more option'), findsNothing);
      expect(_groupValue(tester), isNull);
      expect(_containerOf(tester).read(cartDeliveryChargeProvider), isNull);

      // No collapse affordance either. It used to carry one, and it did
      // nothing: with no selection the list is forced open, so the tap flipped
      // a flag no branch could read. A dead control teaches the customer that
      // this is how the question gets dismissed.
      expect(
        find.descendant(
          of: find.byKey(const Key('cart-choose-delivery')),
          matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
        ),
        findsNothing,
      );

      // The list is up, so the choice can actually be made here on the cart.
      expect(find.byType(Radio<int>), findsNWidgets(_liveList.length));
      expect(find.text('India Post - Speed Post_2.0'), findsOneWidget);
      expect(find.text('Blue Dart Surface'), findsOneWidget);
    });

    testWidgets('one tap picks, and the summary replaces the question',
        (tester) async {
      await pumpList(tester);

      await tester.tap(find.text('Blue Dart Surface'));
      await tester.pumpAndSettle();

      expect(find.text('Choose a delivery option'), findsNothing);
      // The date leads, the courier is the footnote, the price is on the row.
      expect(find.text('Delivery by 04 Aug'), findsOneWidget);
      expect(find.textContaining('Blue Dart Surface'), findsOneWidget);
      expect(find.textContaining('180.60'), findsOneWidget);
      // ...and the alternatives are advertised rather than listed.
      expect(find.textContaining('3 more options'), findsOneWidget);
      expect(
        find.byType(Radio<int>),
        findsNothing,
        reason: 'four courier rows on a cart card is the address wall again',
      );
    });

    // The cart's rows used to append "· prepaid only" to every courier with
    // `cod: 0`, in warning yellow. Checkout's rows had already dropped that
    // wording (see `shipping_selector_test.dart`), so the two screens described
    // the same courier differently — and both halves of the note were untrue
    // anyway. This build is Razorpay-only: the checkout body hardcodes
    // `payment_method: "razorpay"`, COD is disabled server-side, and its API
    // path 500s *after* the order has been committed. There is no cash on
    // delivery to lose, and picking one of the unmarked rows would not hand it
    // back, which is exactly what the note implied.
    testWidgets('says nothing about cash on delivery, either way',
        (tester) async {
      await pumpList(tester);

      expect(
        find.textContaining('prepaid only'),
        findsNothing,
        reason: 'implies the other rows offer COD, and none of them do',
      );
      expect(find.textContaining('cash on delivery'), findsNothing);
      expect(find.textContaining('cash-on-delivery'), findsNothing);
      // The rows are still there, still named and still priced.
      expect(find.byType(Radio<int>), findsNWidgets(_liveList.length));
      expect(find.text('India Post - Speed Post_2.0'), findsOneWidget);
    });

    // The whole point of the slice: the cart's total is the one the customer
    // agreed to, and checkout reads the same choice.
    testWidgets('picking a courier writes the choice the cart and checkout '
        'both read', (tester) async {
      await pumpList(tester);

      final container = _containerOf(tester);
      final query = _queryFor('382415');
      // Before the tap the cart has a goods total and no delivery figure: the
      // list is up, nothing is chosen, and nothing is invented.
      expect(container.read(cartDeliveryChargeProvider), isNull);
      expect(container.read(selectedShippingProvider(query)), isNull);

      await tester.tap(find.text('India Post - Speed Post_2.0'));
      await tester.pumpAndSettle();

      final choice = container.read(shippingChoiceProvider);
      expect(choice, isNotNull);
      expect(choice!.option, _indiaPost);
      expect(
        choice.query,
        query,
        reason: 'the pick is pinned to this parcel and this address',
      );
      // Both surfaces resolve through selectedShippingProvider, so one order
      // cannot show two "To pay" figures.
      expect(container.read(selectedShippingProvider(query)), _indiaPost);
      expect(
        container.read(shippingChargeProvider(query)),
        _indiaPost.billedPrice,
      );
      expect(
        container.read(cartDeliveryChargeProvider),
        _indiaPost.billedPrice,
      );
    });

    // `ShippingChoice` stores the CourierOption *object* that was tapped, and
    // that object carries the rate quoted at that moment. `courierOptionsProvider`
    // is autoDispose, so leaving the cart and coming back re-quotes — and
    // Shiprocket re-prices. The pin has to mean "this courier", not "this price".
    testWidgets('a re-quote re-prices the pinned courier rather than keeping '
        'the rate it was pinned at', (tester) async {
      var dearer = false;
      await pumpList(
        tester,
        fetcher: (_) async => ShippingRates.fromCouriers(
          dearer ? [_blueDartSurface, _indiaPostDearer] : _liveList,
        ),
      );

      await tester.tap(find.text('India Post - Speed Post_2.0'));
      await tester.pumpAndSettle();

      final container = _containerOf(tester);
      final query = _queryFor('382415');
      expect(container.read(cartDeliveryChargeProvider), _indiaPost.rate);

      dearer = true;
      container.invalidate(courierOptionsProvider(query));
      await tester.pumpAndSettle();

      // Same courier, today's price — on the row and on the bill.
      expect(
        container.read(selectedShippingProvider(query)),
        _indiaPostDearer,
      );
      expect(
        container.read(cartDeliveryChargeProvider),
        _indiaPostDearer.rate,
      );
      expect(find.textContaining('149.90'), findsOneWidget);
      expect(
        find.textContaining('106.20'),
        findsNothing,
        reason: 'nobody would be charged the rate from the previous quote',
      );
    });

    testWidgets('a pinned courier that drops out of the list is unpicked, not '
        'quietly replaced', (tester) async {
      var gone = false;
      await pumpList(
        tester,
        fetcher: (_) async => ShippingRates.fromCouriers(
          gone ? [_blueDartSurface] : _liveList,
        ),
      );

      await tester.tap(find.text('India Post - Speed Post_2.0'));
      await tester.pumpAndSettle();

      final container = _containerOf(tester);
      final query = _queryFor('382415');

      gone = true;
      container.invalidate(courierOptionsProvider(query));
      await tester.pumpAndSettle();

      // The collapsed row used to say "the only option for this address" while
      // naming — and billing — a courier that is no longer on offer. It then
      // fell back to the app's own pick, which is the substitution this round
      // removed: the question reopens instead.
      expect(container.read(selectedShippingProvider(query)), isNull);
      expect(container.read(cartDeliveryChargeProvider), isNull);
      expect(find.textContaining('106.20'), findsNothing);
      expect(find.text('India Post - Speed Post_2.0'), findsNothing);
    });

    testWidgets('picking folds the list back to one row', (tester) async {
      await pumpList(tester);

      await tester.tap(find.text('India Post - Speed Post_2.0'));
      await tester.pumpAndSettle();

      expect(find.byType(Radio<int>), findsNothing);
      // Still "Delivery by": that is the arrival date, not the shipping charge.
      expect(find.text('Delivery by 06 Aug'), findsOneWidget);
      expect(find.textContaining('106.20'), findsOneWidget);
    });

    // A one-courier quote is still a decision. It used to be made for the
    // customer on the grounds that there was nothing to choose between — but
    // the tap is them accepting a delivery charge, not resolving an ambiguity.
    testWidgets('a single courier still has to be accepted', (tester) async {
      await pumpList(tester, fetcher: _ready([_blueDartSurface]));

      expect(find.text('Choose a delivery option'), findsOneWidget);
      expect(find.textContaining('1 courier delivers here'), findsOneWidget);
      expect(find.byType(Radio<int>), findsOneWidget);
      expect(_containerOf(tester).read(cartDeliveryChargeProvider), isNull);

      await tester.tap(find.text('Blue Dart Surface'));
      await tester.pumpAndSettle();

      // Now it collapses, and now there is genuinely nothing to change to.
      expect(find.textContaining('the only option'), findsOneWidget);
      expect(find.textContaining('more option'), findsNothing);
      expect(find.byType(Radio<int>), findsNothing);
      expect(
        _containerOf(tester).read(cartDeliveryChargeProvider),
        _blueDartSurface.billedPrice,
      );
    });

    // The card sits directly above the bill on the narrowest phone the app
    // supports, with a courier name, a date and a price competing for one row.
    testWidgets('lays out on a 320dp screen at the largest OS text scale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Not `MediaQuery(data: const MediaQueryData(...))` — that zeroes
      // `size` for everything below it, which is not what a large text scale
      // does on a device.
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await pumpList(tester);

      // The question, and the whole list under it, at 320dp / 1.6x.
      expect(tester.takeException(), isNull);
      expect(find.text('Choose a delivery option'), findsOneWidget);
      expect(find.byType(Radio<int>), findsNWidgets(_liveList.length));

      await tester.tap(find.text('Blue Dart Surface'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Delivery by 04 Aug'), findsOneWidget);
      // The row used to give the price its full ~170dp and ellipsize the
      // courier down to about 36dp — "D…" — so the customer using the
      // accessibility text size was the one who could not read what they were
      // being charged for.
      expect(
        tester.getSize(find.text('Delivery by 04 Aug')).width,
        greaterThan(120),
      );
    });

    // Merged, so a screen reader reads one option with its courier and price
    // instead of an unlabelled radio sitting next to three loose text nodes.
    testWidgets('each courier row is one labelled, selectable node',
        (tester) async {
      final handle = tester.ensureSemantics();

      await pumpList(tester);

      // One node, not an unlabelled radio beside three loose text nodes: the
      // courier, its estimate and its price are what the control is *for*.
      // Unchecked, because nothing is chosen — a screen reader must not
      // announce a selected courier the customer never selected.
      expect(
        tester.getSemantics(find.byType(Radio<int>).first),
        matchesSemantics(
          hasTapAction: true,
          hasFocusAction: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          isInMutuallyExclusiveGroup: true,
          hasCheckedState: true,
          label: 'Delivery by 04 Aug\nBlue Dart Surface\n₹180.60',
        ),
      );
      handle.dispose();
    });

    testWidgets('flags a quote built on an unweighed line', (tester) async {
      await pumpList(
        tester,
        parcel: const CheckoutParcel(
          weightKg: 0.1,
          lengthCm: 10,
          breadthCm: 10,
          heightCm: 10,
          declaredValue: 100,
          unweighedLines: 2,
        ),
      );

      expect(find.textContaining('No pack weight on record for 2 items'),
          findsOneWidget,);
    });
  });

  // ------------------------------------------------------------------
  // The bill row, which has to tell the same story as the card.
  // ------------------------------------------------------------------
  group('cartDeliveryStatusLabel', () {
    Widget statusLabel() => Consumer(
          builder: (_, ref, __) => Text(
            cartDeliveryStatusLabel(ref),
            textDirection: TextDirection.ltr,
          ),
        );

    testWidgets('signed out, it points at the sign-in the card offers',
        (tester) async {
      await tester.pumpWidget(await _host(
        Column(children: [_bar(), statusLabel()]),
        signedIn: false,
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      expect(find.text('Sign in to see shipping'), findsOneWidget);
      expect(
        find.text('Choose an address'),
        findsNothing,
        reason: 'signed out there is no control to choose one with',
      );
    });

    testWidgets('asks for an address when the book has none in use',
        (tester) async {
      await tester.pumpWidget(await _host(
        Column(children: [_bar(), statusLabel()]),
        fetcher: _ready(_liveList),
      ),);
      await tester.pumpAndSettle();

      expect(find.text('Choose an address'), findsOneWidget);
    });

    // The row used to read "At checkout" here, promising a resolution checkout
    // cannot produce either.
    testWidgets('admits the refusal instead of deferring it', (tester) async {
      await tester.pumpWidget(await _host(
        Column(children: [_bar(), statusLabel()]),
        book: [_nowhere],
        fetcher: (_) async => ShippingRates.unavailable('nope'),
      ),);
      await tester.pumpAndSettle();

      expect(find.text("We can't deliver here"), findsOneWidget);
      expect(find.textContaining('At checkout'), findsNothing);
    });

    testWidgets('separates a failed quote from a refusal', (tester) async {
      await tester.pumpWidget(await _host(
        Column(children: [_bar(), statusLabel()]),
        book: [_home],
        fetcher: (_) async => throw const ApiException(
          'Service temporarily unavailable',
          kind: ApiErrorKind.server,
          statusCode: 500,
        ),
      ),);
      await tester.pumpAndSettle();

      expect(find.text('Unavailable — retry above'), findsOneWidget);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/data/models/address.dart';
import 'package:trueway_farms/data/repositories/address_repository.dart';
import 'package:trueway_farms/presentation/providers/address_provider.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/delivery_location_provider.dart';
import 'package:trueway_farms/presentation/screens/profile/address_form_screen.dart';
import 'package:trueway_farms/presentation/widgets/address_choose_sheet.dart';
import 'package:trueway_farms/presentation/widgets/address_picker.dart';
import 'package:trueway_farms/presentation/widgets/skeletons.dart';
import 'package:trueway_farms/presentation/widgets/state_views.dart';

import '../support/fake_geo_repository.dart';
import '../support/fake_pincode_repository.dart';

/// The checkout address picker: it collapses to the one address the order is
/// going to, preselection still follows the server's default, manual entry
/// still works signed out, and the PIN code contract the shipping-rate call
/// depends on is unchanged.
///
/// Nothing here touches the network — [_FakeAddressRepository] stands in for
/// the real repository and `isAuthenticatedProvider` is overridden, so no
/// ApiClient (and therefore no Dio, no socket) is ever constructed.

// ---------------------------------------------------------------------------
// Fixtures — rows copied from a captured GET /ecommerce/addresses response.
// ---------------------------------------------------------------------------

Map<String, dynamic> _row({
  required int id,
  required int isDefault,
  String name = 'Suraj ojha',
  String state = '11',
  String city = '574',
  String zip = '382415',
  String address = '306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad',
  String fullAddress =
      '306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad, '
          'Ahmedabad, Gujarat, 382415',
}) =>
    {
      'id': id,
      'name': name,
      // The list route sends 1/0, not true/false.
      'is_default': isDefault,
      'phone': '8305317276',
      'email': 'suraj.ojha@uminber.in',
      'country': 'India',
      'state': state,
      'city': city,
      'address': address,
      'zip_code': zip,
      'full_address': fullAddress,
    };

/// id 16 is the account's real default and stores state/city as raw ids.
final _default = Address.fromJson(_row(id: 16, isDefault: 1));

final _gwalior = Address.fromJson(
  _row(
    id: 50,
    isDefault: 0,
    name: 'Gwalior home',
    state: 'Madhya Pradesh',
    city: 'Gwalior',
    zip: '474010',
    address: '402, ganesh rivera',
    fullAddress: '402, ganesh rivera, Gwalior, Madhya Pradesh, 474010',
  ),
);

/// A row saved through the server's lenient rules: `zip_code` is only
/// `nullable|max:20`, so a PIN-less address is a real thing in the book.
final _noPin = Address.fromJson(
  _row(
    id: 61,
    isDefault: 0,
    name: 'No PIN',
    zip: '',
    fullAddress: '306, Jahnavi Arcade, Ahmedabad, Gujarat',
  ),
);

/// The *other* lenient-rules row: a perfectly good PIN, no `state`.
///
/// `POST /ecommerce/addresses` requires only `{name, phone}`, so this saves
/// fine and then fails the checkout rules — which the picker used not to
/// notice, because it only ever checked the PIN.
final _noState = Address.fromJson(
  _row(
    id: 62,
    isDefault: 0,
    name: 'No state',
    state: '',
    fullAddress: '306, Jahnavi Arcade, Ahmedabad, 382415',
  ),
);

List<Address> get _book => [_default, _gwalior];

/// The account from the screenshot that motivated collapsing the picker: the
/// default plus four more, which the stacked list turned into a wall of cards.
List<Address> get _bigBook => [
      _default,
      _gwalior,
      Address.fromJson(
        _row(
          id: 51,
          isDefault: 0,
          name: 'Office',
          city: 'Ahmedabad',
          state: 'Gujarat',
          fullAddress: 'Office block, Ahmedabad, Gujarat, 382415',
        ),
      ),
      Address.fromJson(
        _row(
          id: 52,
          isDefault: 0,
          name: 'Parents',
          city: 'Indore',
          state: 'Madhya Pradesh',
          zip: '452001',
          fullAddress: '7, Vijay Nagar, Indore, Madhya Pradesh, 452001',
        ),
      ),
      Address.fromJson(
        _row(
          id: 53,
          isDefault: 0,
          name: 'Warehouse',
          city: 'Surat',
          state: 'Gujarat',
          zip: '395003',
          fullAddress: 'Plot 9, Surat, Gujarat, 395003',
        ),
      ),
    ];

// ---------------------------------------------------------------------------
// Fake repository
// ---------------------------------------------------------------------------

class _FakeAddressRepository implements AddressRepository {
  _FakeAddressRepository({
    List<Address> rows = const [],
    this.readError,
    this.delay,
  }) : rows = List.of(rows);

  List<Address> rows;
  ApiException? readError;
  final Duration? delay;

  int reads = 0;

  /// Ids passed to [delete], in order.
  final List<int> deleted = [];

  @override
  Future<List<Address>> all() async {
    reads++;
    if (delay != null) await Future<void>.delayed(delay!);
    if (readError != null) throw readError!;
    return List.of(rows);
  }

  @override
  Future<Address?> create(AddressDraft draft) async {
    // Mirrors the server: a created row lands in the book, and the first one
    // is force-promoted to default.
    final created = Address(
      id: 99,
      name: draft.name,
      isDefault: rows.isEmpty,
      phone: draft.phone,
      email: draft.email,
      state: draft.state,
      city: draft.city,
      address: draft.address,
      zipCode: draft.zipCode,
      fullAddress: '${draft.address}, ${draft.city}, ${draft.zipCode}',
    );
    rows = [...rows, created];
    return created;
  }

  @override
  Future<String?> delete(int id) async {
    deleted.add(id);
    rows = rows.where((row) => row.id != id).toList();
    return 'Address deleted successfully';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Records everything the picker told its parent.
class _Sink {
  final List<AddressSelection> emitted = [];

  AddressSelection? get last => emitted.isEmpty ? null : emitted.last;

  void call(AddressSelection s) => emitted.add(s);
}

Future<Widget> _wrap(
  Widget child, {
  required _FakeAddressRepository repo,
  bool signedIn = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      addressRepositoryProvider.overrideWithValue(repo),
      isAuthenticatedProvider.overrideWithValue(signedIn),
      // The address FORM this picker can push has State and City pickers
      // backed by `/ecommerce/states` and `/ecommerce/cities`. `offline()`
      // answers empty, which is the failure path — a form whose pickers cannot
      // open can never save — so this is a fake with the live rows in it.
      geoRepositoryProvider.overrideWithValue(FakeGeoRepository()),
      // The real one calls India Post. A test suite must not reach the public
      // internet, and the form's PIN autofill fires on any valid six digits.
      pincodeRepositoryProvider.overrideWithValue(FakePincodeRepository()),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      // The picker is a fragment: it is mounted inside somebody else's scroll
      // view, exactly as checkout will mount it. Anything that needs bounded
      // height (a Center, a nested scrollable) blows up here rather than in
      // production.
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    ),
  );
}

Future<Widget> _picker(
  _Sink sink, {
  required _FakeAddressRepository repo,
  bool signedIn = true,
  bool enabled = true,
  int? initialAddressId,
  AddressDraft? initialDraft,
}) =>
    _wrap(
      AddressPicker(
        onChanged: sink.call,
        enabled: enabled,
        initialAddressId: initialAddressId,
        initialDraft: initialDraft,
        onSignInRequested: () {},
      ),
      repo: repo,
      signedIn: signedIn,
    );

void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _usePhoneSurface(WidgetTester tester, {double width = 320}) {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Turns the OS text scale up the way the OS does.
///
/// Deliberately *not* `MediaQuery(data: const MediaQueryData(textScaler: ...))`:
/// that replaces the whole MediaQueryData, so `size` becomes `Size.zero` for
/// everything below it. The chooser sheet caps its list at 60% of the screen
/// height, so under that harness the list is 0dp tall and renders no rows at
/// all — a test asserting "no overflow" would then be asserting it about an
/// empty sheet. Scaling through the platform dispatcher leaves the rest of the
/// MediaQuery real.
void _useLargeText(WidgetTester tester, {double scale = 1.6}) {
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// A row inside the chooser sheet. Nothing renders these on checkout itself —
/// that is the point of the collapse.
Finder _option(int id) => find.byKey(ValueKey('address-option-$id'));

/// The one card checkout shows.
Finder get _card => find.byKey(const Key('address-picker-selected'));

Future<void> _openChooser(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('address-picker-change')));
  await tester.pumpAndSettle();
}

Future<void> _fillManual(
  WidgetTester tester, {
  String pin = '474010',
  String phone = '9876543210',
}) async {
  await tester.enterText(
    find.byKey(const Key('manual-address-name')),
    'Suraj ojha',
  );
  await tester.enterText(find.byKey(const Key('manual-address-phone')), phone);
  await tester.enterText(
    find.byKey(const Key('manual-address-street')),
    '402, ganesh rivera',
  );
  await tester.enterText(
    find.byKey(const Key('manual-address-city')),
    'Gwalior',
  );
  await tester.enterText(
    find.byKey(const Key('manual-address-state')),
    'Madhya Pradesh',
  );
  await tester.enterText(find.byKey(const Key('manual-address-zip')), pin);
  await tester.pumpAndSettle();
}

void main() {
  // -------------------------------------------------------------------------
  // Signed in — the collapsed card
  // -------------------------------------------------------------------------

  testWidgets('shows a skeleton while the book is being read', (tester) async {
    final repo = _FakeAddressRepository(
      rows: _book,
      delay: const Duration(milliseconds: 50),
    );
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pump();

    expect(find.byType(SkeletonBox), findsWidgets);
    expect(_card, findsNothing);
    // Nothing is claimed before anything is known.
    expect(sink.last?.address, isNull);

    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();
    expect(find.byType(SkeletonBox), findsNothing);
    expect(_card, findsOneWidget);
  });

  testWidgets('collapses a five-address book to one card', (tester) async {
    // The regression this whole slice exists for: five saved addresses used to
    // render as five stacked radio cards, pushing the bill and the order button
    // off the screen.
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _bigBook);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    expect(_card, findsOneWidget);
    // The selected one, and only the selected one.
    expect(find.text('Suraj ojha'), findsOneWidget);
    for (final other in ['Gwalior home', 'Office', 'Parents', 'Warehouse']) {
      expect(find.text(other), findsNothing, reason: '$other should be hidden');
    }
    // No row is on the page — they live behind Change.
    for (final id in [16, 50, 51, 52, 53]) {
      expect(_option(id), findsNothing);
    }
  });

  testWidgets('preselects the default address and reports its PIN code',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    expect(sink.last!.address!.id, 16);
    // The whole point of the callback: checkout can fetch rates without asking
    // the picker anything else.
    expect(sink.last!.pinCode, '382415');
    expect(sink.last!.isComplete, isTrue);
    expect(sink.last!.addressId, 16);

    // Only the server-flagged row wears the badge, and it is the one on screen.
    expect(find.text('Default'), findsOneWidget);
    expect(
      find.descendant(of: _card, matching: find.text('Default')),
      findsOneWidget,
    );

    // A complete row must show no "fix this address" notice at all — see the
    // regression test below for the bug this used to miss.
    expect(find.byKey(const Key('address-picker-no-pincode')), findsNothing);
  });

  // The gap the "preselects the default address" test above did not close:
  // `isComplete` and the visible notice card are computed on two SEPARATE
  // paths (`_selectionFor` vs `_savedProblem`), and only the first was ever
  // asserted here. `_savedProblem` used to validate `saved.toDraft().toJson()`
  // directly — the address-book write shape, which carries no `country` key
  // since the server started filling it — so a row that was complete in every
  // way still painted "Cannot be delivered to - please complete this address
  // (Enter the country)" on screen, permanently, for a field this app never
  // collects.
  testWidgets('a complete saved row shows no "fix this address" notice',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    expect(sink.last!.isComplete, isTrue);
    expect(find.textContaining('Cannot be delivered'), findsNothing);
    expect(find.textContaining('Enter the country'), findsNothing);
    expect(find.byType(AddressNoticeCard), findsNothing);
  });

  testWidgets('the collapsed card shows name, phone and the server-rendered '
      'address, never the raw region ids', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: _card, matching: find.text('Suraj ojha')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _card, matching: find.text('8305317276')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _card,
        matching: find.text(
          '306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad, '
          'Ahmedabad, Gujarat, 382415',
        ),
      ),
      findsOneWidget,
    );
    // Row 16 stores state "11" and city "574"; those must never reach a screen.
    expect(find.text('574'), findsNothing);
    expect(find.text('11'), findsNothing);
  });

  testWidgets('a rebuild does not re-notify the parent', (tester) async {
    // Load-bearing: every notification costs a shipping-rate round trip, and
    // AddressDraft has no `==`, so a naive selection compare fires every frame.
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();
    final settled = sink.emitted.length;

    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(sink.emitted.length, settled);
  });

  testWidgets('honours initialAddressId over the default', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(
      await _picker(sink, repo: repo, initialAddressId: 50),
    );
    await tester.pumpAndSettle();

    expect(sink.last!.address!.id, 50);
    expect(
      find.descendant(of: _card, matching: find.text('Gwalior home')),
      findsOneWidget,
    );
  });

  testWidgets('a book with no flagged default still preselects a row, but '
      'badges nothing', (tester) async {
    _useTallSurface(tester);
    // Reachable: the server never re-promotes on update, so one edit clearing
    // the flag leaves the book with no default at all.
    final repo = _FakeAddressRepository(rows: [_gwalior]);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    expect(sink.last!.address!.id, 50);
    expect(find.text('Default'), findsNothing);
  });

  testWidgets('a selected address with no PIN code is not reported as usable',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: [_noPin]);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    expect(sink.last!.address!.id, 61);
    // Rates cannot be quoted, so no half-answer is handed to checkout.
    expect(sink.last!.pinCode, '');
    expect(sink.last!.isComplete, isFalse);
    // The warning stays on checkout next to the card, not buried in the sheet.
    expect(find.byKey(const Key('address-picker-no-pincode')), findsOneWidget);
    expect(find.textContaining('no valid PIN code'), findsOneWidget);
  });

  // The gap this closed. `isComplete` gates the "Place order" button; the
  // checkout notifier and CheckoutRepository both refuse on
  // CheckoutAddressRules. When the picker validated with the *address book's*
  // rules instead, a row like this one reported complete, the button went live,
  // and the flow then refused it — a dead end with no explanation on screen.
  testWidgets('a saved row that fails the checkout rules is not complete, even '
      'with a perfectly good PIN', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: [_noState]);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    expect(sink.last!.address!.id, 62);
    expect(sink.last!.isComplete, isFalse);
    // The PIN is still reported: the destination is quotable even though the
    // address cannot be checked out with.
    expect(sink.last!.pinCode, '382415');
    // ...and the card says which rule is broken, not just "no PIN code".
    expect(find.textContaining('Enter the state'), findsOneWidget);
    expect(find.textContaining('no valid PIN code'), findsNothing);
  });

  testWidgets('a saved row that passes the address book but not checkout is '
      'still refused', (tester) async {
    _useTallSurface(tester);
    // 150 characters: legal for `POST /addresses` (max 191) and legal for
    // `AddressDraft.validationErrors`, but over the web checkout's 120.
    final longStreet = Address.fromJson(
      _row(id: 63, isDefault: 0, address: 'A' * 150),
    );
    final repo = _FakeAddressRepository(rows: [longStreet]);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    expect(sink.last!.isComplete, isFalse);
    expect(find.textContaining('Address is too long'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // The chooser sheet
  // -------------------------------------------------------------------------

  testWidgets('Change opens a sheet listing every saved address with the '
      'current one marked', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _bigBook);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    await _openChooser(tester);

    expect(find.byType(AddressChooseSheet), findsOneWidget);
    for (final id in [16, 50, 51, 52, 53]) {
      expect(_option(id), findsOneWidget);
    }
    expect(
      find.descendant(
        of: _option(16),
        matching: find.byIcon(Icons.radio_button_checked_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _option(50),
        matching: find.byIcon(Icons.radio_button_unchecked_rounded),
      ),
      findsOneWidget,
    );
    // Adding one is offered from inside the sheet.
    expect(find.byKey(const Key('address-picker-add')), findsOneWidget);
  });

  testWidgets('choosing another address closes the sheet, updates the card '
      'and re-reports the PIN', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();
    final before = sink.emitted.length;

    await _openChooser(tester);
    await tester.tap(_option(50));
    await tester.pumpAndSettle();

    expect(find.byType(AddressChooseSheet), findsNothing);
    expect(sink.emitted.length, greaterThan(before));
    expect(sink.last!.address!.id, 50);
    expect(sink.last!.pinCode, '474010');
    expect(
      find.descendant(of: _card, matching: find.text('Gwalior home')),
      findsOneWidget,
    );
    // The badge does not follow the selection — it follows the server's flag,
    // and row 50 has never been flagged.
    expect(find.text('Default'), findsNothing);
  });

  testWidgets('dismissing the sheet leaves the selection alone', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();
    final settled = sink.emitted.length;

    await _openChooser(tester);
    // Tap the scrim.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byType(AddressChooseSheet), findsNothing);
    expect(sink.emitted.length, settled);
    expect(sink.last!.address!.id, 16);
  });

  testWidgets('the sheet re-reads the book behind it and offers pull-to-refresh',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    await _openChooser(tester);
    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(_option(51), findsNothing);

    // A refresh landing while the sheet is open must reach the sheet: it
    // watches the book rather than holding a snapshot of it.
    repo.rows = _bigBook;
    await tester.runAsync(() async {
      await ProviderScope.containerOf(
        tester.element(find.byType(AddressPicker)),
      ).read(addressBookProvider.notifier).refresh();
    });
    await tester.pumpAndSettle();

    expect(_option(51), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // Signed in — the non-happy reads
  // -------------------------------------------------------------------------

  testWidgets('a failed read offers a retry that re-requests', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(
      readError: ApiException.local('Network unreachable'),
    );
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    expect(find.byType(InlineErrorStrip), findsOneWidget);
    expect(find.textContaining('Network unreachable'), findsOneWidget);
    expect(repo.reads, 1);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(repo.reads, 2);
  });

  testWidgets('a failed read still lets the customer type an address',
      (tester) async {
    // Checkout must not be taken down by one failing GET.
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(
      readError: ApiException.local('Network unreachable'),
    );
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('address-picker-manual')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('manual-address-zip')), findsOneWidget);
    await _fillManual(tester);

    expect(sink.last!.address, isNull);
    expect(sink.last!.draft!.city, 'Gwalior');
    expect(sink.last!.pinCode, '474010');
    expect(sink.last!.isComplete, isTrue);
  });

  testWidgets('a failed refresh keeps the card under a stale-data strip',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();
    expect(find.byType(InlineErrorStrip), findsNothing);

    repo.readError = ApiException.local('Gateway timeout');
    await tester.runAsync(() async {
      await ProviderScope.containerOf(
        tester.element(find.byType(AddressPicker)),
      ).read(addressBookProvider.notifier).refresh();
    });
    await tester.pumpAndSettle();

    // The address survives, but the picker admits it may be stale.
    expect(_card, findsOneWidget);
    expect(find.byType(InlineErrorStrip), findsOneWidget);
    expect(find.textContaining('Gateway timeout'), findsOneWidget);
  });

  testWidgets('an empty book offers to add one without blocking',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    // Nothing to collapse to, so the offer is on the page rather than behind a
    // Change button that would open an empty sheet.
    expect(find.byKey(const Key('address-picker-empty')), findsOneWidget);
    expect(_card, findsNothing);
    expect(sink.last!.isComplete, isFalse);
    expect(find.text('Add a new address'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // "Add a new address"
  // -------------------------------------------------------------------------

  testWidgets('adding an address from the sheet opens the real form and '
      'selects the result', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();
    expect(sink.last!.address!.id, 16);

    await _openChooser(tester);
    await tester.tap(find.byKey(const Key('address-picker-add')));
    await tester.pumpAndSettle();

    // The sheet is gone and the existing form — not a copy of it — is up, with
    // the same field keys and the same rules.
    expect(find.byType(AddressChooseSheet), findsNothing);
    expect(find.byKey(const Key('address-name')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('address-name')), 'New place');
    await tester.enterText(
      find.byKey(const Key('address-phone')),
      '9876543210',
    );
    await tester.enterText(
      find.byKey(const Key('address-street')),
      '11 New Street',
    );
    await pickGeo(
      tester,
      field: const Key('address-state'),
      option: 'Madhya Pradesh',
    );
    await pickGeo(tester, field: const Key('address-city'), option: 'Gwalior');
    await tester.enterText(find.byKey(const Key('address-zip')), '474011');
    await tester.pump();
    await tester.tap(find.text('Save address'));
    await tester.pumpAndSettle();

    // Back on the collapsed card, showing the new row — not the old default.
    expect(sink.last!.address!.id, 99);
    expect(sink.last!.pinCode, '474011');
    expect(
      find.descendant(of: _card, matching: find.text('New place')),
      findsOneWidget,
    );

    // …and it is the destination the whole app now ships to, not just this
    // screen's local pick. Without this write the cart goes on naming — and
    // quoting for — the previous address, and because checkout seeds
    // `initialAddressId` from `selectedDeliveryAddressIdProvider`, leaving
    // checkout and coming back silently reverted to that older row.
    final location = ProviderScope.containerOf(
      tester.element(find.byType(AddressPicker)),
    ).read(deliveryLocationProvider);
    expect(location?.addressId, 99);
    expect(location?.pinCode, '474011');

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('cancelling the form leaves the selection alone', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    await _openChooser(tester);
    await tester.tap(find.byKey(const Key('address-picker-add')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(sink.last!.address!.id, 16);
    expect(
      find.descendant(of: _card, matching: find.text('Suraj ojha')),
      findsOneWidget,
    );
  });

  testWidgets('adding the first address from an empty book still works',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add a new address'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('address-name')), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // Signed out
  // -------------------------------------------------------------------------

  testWidgets('signed out, the form is shown directly and the book is never '
      'read', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo, signedIn: false));
    await tester.pumpAndSettle();

    // The address routes are bearer-only; touching them without a token 401s
    // and ApiClient turns that into a forced sign-out.
    expect(repo.reads, 0);
    expect(find.byKey(const Key('manual-address-name')), findsOneWidget);
    // Nothing to collapse to, so nothing is collapsed.
    expect(_card, findsNothing);
    expect(find.byKey(const Key('address-picker-change')), findsNothing);
    // An offer, not a wall.
    expect(find.text('Sign in to use saved addresses'), findsOneWidget);
    expect(find.byKey(const Key('address-picker-signin')), findsOneWidget);
  });

  testWidgets('a signed-out draft reports its PIN only once it is valid',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo, signedIn: false));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('manual-address-zip')),
      '3824',
    );
    await tester.pumpAndSettle();
    // Half a PIN is not a PIN — a rate call on "3824" is a wasted round trip
    // at best and a wrong quote at worst.
    expect(sink.last!.pinCode, '');
    expect(sink.last!.isComplete, isFalse);

    await tester.enterText(
      find.byKey(const Key('manual-address-zip')),
      '382415',
    );
    await tester.pumpAndSettle();
    expect(sink.last!.pinCode, '382415');
    // Still incomplete: a PIN alone is not an address.
    expect(sink.last!.isComplete, isFalse);

    await _fillManual(tester, pin: '382415');
    expect(sink.last!.isComplete, isTrue);
    expect(sink.last!.draft!.phone, '9876543210');
    expect(sink.last!.effectiveDraft.toJson()['phone'], isA<String>());
  });

  // Same rules as the saved rows, and the same rules the notifier refuses on:
  // a street line the address book would happily store is still too long for
  // checkout, so the button must not go live for it.
  testWidgets('the signed-out form applies the checkout rules, not the address '
      "book's", (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo, signedIn: false));
    await tester.pumpAndSettle();

    await _fillManual(tester);
    expect(sink.last!.isComplete, isTrue);

    await tester.enterText(
      find.byKey(const Key('manual-address-street')),
      'A' * 150,
    );
    await tester.pumpAndSettle();

    expect(sink.last!.isComplete, isFalse);
    expect(find.textContaining('Address is too long'), findsOneWidget);
    // The destination has not changed, so rates are still fetchable.
    expect(sink.last!.pinCode, '474010');
  });

  testWidgets('the signed-out form rejects a two-character name', (tester) async {
    // `min:3` on the web checkout; the address endpoint allows 1.
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo, signedIn: false));
    await tester.pumpAndSettle();

    await _fillManual(tester);
    await tester.enterText(find.byKey(const Key('manual-address-name')), 'Jo');
    await tester.pumpAndSettle();

    expect(sink.last!.isComplete, isFalse);
    expect(find.textContaining('Name is too short'), findsOneWidget);
  });

  testWidgets('the signed-out form enforces the phone rule', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo, signedIn: false));
    await tester.pumpAndSettle();

    // Starts with 1 — the server's ^[6-9][0-9]{9}$ rule rejects it.
    await _fillManual(tester, phone: '1234567890');

    expect(
      find.text('Enter a 10-digit Indian mobile number starting 6-9'),
      findsOneWidget,
    );
    expect(sink.last!.isComplete, isFalse);
    // The PIN is still reported: rates depend on the destination, not on
    // whether the customer has typed a valid phone number yet.
    expect(sink.last!.pinCode, '474010');
  });

  testWidgets('a signed-out draft survives being seeded back in',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    final sink = _Sink();
    await tester.pumpWidget(
      await _picker(
        sink,
        repo: repo,
        signedIn: false,
        initialDraft: const AddressDraft(
          name: 'Suraj ojha',
          phone: '9876543210',
          email: 'suraj.ojha@uminber.in',
          state: 'Gujarat',
          city: 'Ahmedabad',
          address: '306, Jahnavi Arcade',
          zipCode: '382415',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('306, Jahnavi Arcade'), findsOneWidget);
    expect(sink.last!.pinCode, '382415');
    expect(sink.last!.isComplete, isTrue);
    // No red on a form the customer has not touched yet.
    expect(find.text('Enter a name'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // Disabled + layout
  // -------------------------------------------------------------------------

  testWidgets('disabled, the chooser cannot be opened', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo, enabled: false));
    await tester.pumpAndSettle();
    final settled = sink.emitted.length;

    await tester.tap(find.byKey(const Key('address-picker-change')));
    await tester.pumpAndSettle();
    // Tapping the card itself is dead too, not just the button.
    await tester.tap(_card, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(AddressChooseSheet), findsNothing);
    expect(sink.emitted.length, settled);
    expect(sink.last!.address!.id, 16);
  });

  testWidgets('the Change control clears the 44dp tap-target floor',
      (tester) async {
    _usePhoneSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    final size = tester.getSize(find.byKey(const Key('address-picker-change')));
    expect(size.height, greaterThanOrEqualTo(44));
  });

  testWidgets('lays out on a 320dp screen, in a parent scroll view',
      (tester) async {
    _usePhoneSurface(tester);
    final repo = _FakeAddressRepository(rows: _bigBook);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(_card, findsOneWidget);

    await _openChooser(tester);
    expect(tester.takeException(), isNull);
    expect(_option(16), findsOneWidget);
  });

  testWidgets('the collapsed card and the chooser survive the largest OS text '
      'scale', (tester) async {
    // A Row here reported a 152px overflow: the name, the "Default" pill and
    // the Change button do not fit on one line at 1.6x on a 320dp screen.
    _usePhoneSurface(tester);
    _useLargeText(tester);
    final repo = _FakeAddressRepository(rows: _bigBook);
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_card, findsOneWidget);

    await _openChooser(tester);
    expect(tester.takeException(), isNull);
    // The sheet is only "usable at 1.6x" if it still has addresses in it: the
    // list is capped at 60% of the screen, and a cap that comes out at zero
    // leaves a chooser that chooses nothing.
    expect(_option(16), findsOneWidget);
    expect(
      find.descendant(
        of: _option(16),
        matching: find.byIcon(Icons.radio_button_checked_rounded),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('address-picker-add')), findsOneWidget);
    // Five 1.6x rows do not fit in 60% of a 900dp screen, so the list has to be
    // the thing that scrolls rather than the thing that overflows. Driven
    // through the scroll position rather than a fling: a drag on a modal bottom
    // sheet's ListView competes with the sheet's own dismiss gesture.
    expect(tester.getSize(find.byType(ListView)).height, greaterThan(0));
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    expect(
      position.maxScrollExtent,
      greaterThan(0),
      reason: 'the rows are taller than the sheet, so they must scroll',
    );
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_option(53), findsOneWidget);
  });

  testWidgets('the signed-out form survives the largest OS text scale',
      (tester) async {
    _usePhoneSurface(tester, width: 360);
    _useLargeText(tester);
    final repo = _FakeAddressRepository();
    final sink = _Sink();
    await tester.pumpWidget(await _picker(sink, repo: repo, signedIn: false));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('manual-address-zip')), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // AddressSelection itself
  // -------------------------------------------------------------------------

  test('a saved selection round-trips the opaque region tokens', () {
    const selection = AddressSelection(pinCode: '382415', isComplete: true);
    expect(selection.address, isNull);

    final saved = AddressSelection(
      address: _default,
      pinCode: _default.zipCode,
      isComplete: true,
    );
    // "11"/"574" go back exactly as they came; the rendered names in
    // full_address must never be echoed into state/city.
    expect(saved.effectiveDraft.state, '11');
    expect(saved.effectiveDraft.city, '574');
    expect(saved.effectiveDraft.toJson().containsKey('full_address'), isFalse);
    // ...but the *display* uses the resolved string.
    expect(saved.displayLine, contains('Ahmedabad, Gujarat, 382415'));
  });

  test('two selections holding equal drafts compare equal', () {
    // AddressDraft has no `==`; without a field-wise compare the picker would
    // re-notify — and refetch rates — on every rebuild.
    const a = AddressSelection(
      draft: AddressDraft(name: 'A', phone: '9876543210', zipCode: '382415'),
      pinCode: '382415',
    );
    const b = AddressSelection(
      draft: AddressDraft(name: 'A', phone: '9876543210', zipCode: '382415'),
      pinCode: '382415',
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);

    const c = AddressSelection(
      draft: AddressDraft(name: 'B', phone: '9876543210', zipCode: '382415'),
      pinCode: '382415',
    );
    expect(a, isNot(c));
  });

  // A per-row menu on the chooser. Before it, the only way to fix or remove an
  // address was to leave checkout, open Account, find Saved addresses and hunt
  // for the row — including for the rows the sheet itself flags as
  // undeliverable, which are precisely the ones that need fixing.
  group('the chooser row menu', () {
    Finder menu(int id) => find.byKey(ValueKey('address-option-menu-$id'));

    testWidgets('every row has one', (tester) async {
      final repo = _FakeAddressRepository(rows: _book);
      final sink = _Sink();
      await tester.pumpWidget(await _picker(sink, repo: repo));
      await tester.pumpAndSettle();
      await _openChooser(tester);

      // _book is the default plus Gwalior.
      for (final id in [16, 50]) {
        expect(menu(id), findsOneWidget);
      }
    });

    // The row is a radio option, so the menu has to swallow its own tap —
    // otherwise opening it would silently change the delivery address.
    testWidgets('opening it does not select the row', (tester) async {
      final repo = _FakeAddressRepository(rows: _book);
      final sink = _Sink();
      await tester.pumpWidget(await _picker(sink, repo: repo));
      await tester.pumpAndSettle();
      await _openChooser(tester);
      final before = sink.emitted.length;

      await tester.tap(menu(50));
      await tester.pumpAndSettle();

      expect(find.text('Edit address'), findsOneWidget);
      expect(find.text('Delete address'), findsOneWidget);
      // Still open, and nothing was picked.
      expect(find.byType(AddressChooseSheet), findsOneWidget);
      expect(sink.emitted.length, before);
    });

    testWidgets('Edit opens the form for that row', (tester) async {
      final repo = _FakeAddressRepository(rows: _book);
      final sink = _Sink();
      await tester.pumpWidget(await _picker(sink, repo: repo));
      await tester.pumpAndSettle();
      await _openChooser(tester);

      await tester.tap(menu(50));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit address'));
      await tester.pumpAndSettle();

      // Pushed on the ROOT navigator: the sheet's own would put the form
      // behind it, and the customer would be looking at the sheet.
      expect(find.byType(AddressFormScreen), findsOneWidget);
      expect(find.text('Save changes'), findsOneWidget);
    });

    testWidgets('Delete asks first, then removes the row', (tester) async {
      final repo = _FakeAddressRepository(rows: _book);
      final sink = _Sink();
      await tester.pumpWidget(await _picker(sink, repo: repo));
      await tester.pumpAndSettle();
      await _openChooser(tester);

      await tester.tap(menu(50));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete address'));
      await tester.pumpAndSettle();

      // The same confirmation the address book shows — one implementation, so
      // a row cannot be deleted with a different warning depending on where it
      // was opened from.
      expect(find.text('Delete this address?'), findsOneWidget);
      expect(repo.deleted, isEmpty, reason: 'nothing before the customer says so');

      await tester.tap(find.widgetWithText(ElevatedButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(repo.deleted, [50]);
      expect(_option(50), findsNothing);
      expect(_option(16), findsOneWidget, reason: 'the rest of the book stays');
    });

    testWidgets('Cancel deletes nothing', (tester) async {
      final repo = _FakeAddressRepository(rows: _book);
      final sink = _Sink();
      await tester.pumpWidget(await _picker(sink, repo: repo));
      await tester.pumpAndSettle();
      await _openChooser(tester);

      await tester.tap(menu(50));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete address'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(repo.deleted, isEmpty);
      expect(_option(50), findsOneWidget);
    });
  });
}

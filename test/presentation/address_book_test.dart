import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/data/models/address.dart';
import 'package:trueway_farms/data/models/customer.dart';
import 'package:trueway_farms/data/repositories/address_repository.dart';
import 'package:trueway_farms/presentation/providers/address_provider.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/screens/profile/address_book_screen.dart';
import 'package:trueway_farms/presentation/screens/profile/address_form_screen.dart';
import 'package:trueway_farms/presentation/widgets/skeletons.dart';
import 'package:trueway_farms/presentation/widgets/state_views.dart';

import '../support/fake_geo_repository.dart';
import '../support/fake_pincode_repository.dart';

/// Address book slice: the four list states, the two mutations that need a
/// confirmation or a re-read, and the form's validation contract.
///
/// Nothing here touches the network — [_FakeAddressRepository] stands in for
/// the real repository through `addressRepositoryProvider`, and
/// `isAuthenticatedProvider` is overridden so no ApiClient session is needed.

// ---------------------------------------------------------------------------
// Fixtures — rows copied verbatim from a captured
// GET /ecommerce/addresses response, ids and all.
// ---------------------------------------------------------------------------

Map<String, dynamic> _row({
  required int id,
  required int isDefault,
  String state = '11',
  String city = '574',
  String stateName = 'Gujarat',
  String cityName = 'Ahmedabad',
  String email = 'suraj.ojha@uminber.in',
  String address = '306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad',
  String fullAddress =
      '306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad, '
          'Ahmedabad, Gujarat, 382415',
}) =>
    {
      'id': id,
      'name': 'Suraj ojha',
      // The list route sends 1/0, not true/false.
      'is_default': isDefault,
      'phone': '8305317276',
      'email': email,
      'country': 'India',
      'state': state,
      'state_name': stateName,
      'city': city,
      'city_name': cityName,
      'address': address,
      'zip_code': '382415',
      'full_address': fullAddress,
    };

/// id 16 is the account's real default and stores state/city as raw ids.
final _default = Address.fromJson(_row(id: 16, isDefault: 1));

/// id 57 stores a city *name* and an opaque state id.
final _secondary = Address.fromJson(
  _row(id: 57, isDefault: 0, city: 'Ahmadabad City', cityName: 'Ahmadabad City'),
);

/// id 50 stores names for both.
final _gwalior = Address.fromJson(
  _row(
    id: 50,
    isDefault: 0,
    state: 'Madhya Pradesh',
    city: 'Gwalior',
    address: '402, ganesh rivera',
    fullAddress: '402, ganesh rivera, Gwalior, Madhya Pradesh, 474010',
  ),
);

List<Address> get _book => [_default, _secondary, _gwalior];

// ---------------------------------------------------------------------------
// Fake repository
// ---------------------------------------------------------------------------

/// Implements the repository interface rather than subclassing it, so no
/// ApiClient (and therefore no Dio, no socket) is ever constructed.
class _FakeAddressRepository implements AddressRepository {
  _FakeAddressRepository({
    List<Address> rows = const [],
    this.readError,
    this.writeError,
    this.delay,
  }) : rows = List.of(rows);

  List<Address> rows;

  /// Thrown by [all]. Mutable so a test can make a *later* read fail.
  ApiException? readError;

  /// Thrown by create/update/setDefault/delete.
  ApiException? writeError;

  final Duration? delay;

  int reads = 0;
  final List<AddressDraft> created = [];
  final List<(int, AddressDraft)> updated = [];
  final List<int> defaulted = [];
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
    created.add(draft);
    if (writeError != null) throw writeError!;
    // The real POST body is unverified, so the repository may return null.
    return null;
  }

  @override
  Future<Address?> update(int id, AddressDraft draft) async {
    updated.add((id, draft));
    if (writeError != null) throw writeError!;
    return null;
  }

  @override
  Future<Address?> setDefault(Address address) async {
    defaulted.add(address.id);
    if (writeError != null) throw writeError!;
    // Mirrors handleDefaultAddress: every other row is demoted server-side.
    rows = [
      for (final r in rows) r.copyWith(isDefault: r.id == address.id),
    ];
    return null;
  }

  @override
  Future<String?> delete(int id) async {
    deleted.add(id);
    if (writeError != null) throw writeError!;
    rows = [for (final r in rows) if (r.id != id) r];
    return 'Address deleted successfully';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

Future<Widget> _wrap(
  Widget child, {
  required _FakeAddressRepository repo,
  bool signedIn = true,
  /// Seeded into the persisted session, which is what [AuthNotifier] restores
  /// from. A customer with an email is what hides the form's email field.
  Customer? customer,
}) async {
  SharedPreferences.setMockInitialValues(
    customer == null
        ? const <String, Object>{}
        : {
            'auth_token': 'placeholder-not-a-real-token',
            'auth_customer_v1': jsonEncode(customer.toJson()),
          },
  );
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      addressRepositoryProvider.overrideWithValue(repo),
      isAuthenticatedProvider.overrideWithValue(signedIn),
      // The form's State and City fields are pickers backed by
      // `/ecommerce/states` and `/ecommerce/cities`. A fake rather than
      // `offline()`, because `offline()` answers with empty lists — which is
      // the *failure* path, and a form whose pickers cannot open can never
      // save.
      geoRepositoryProvider.overrideWithValue(FakeGeoRepository()),
      // The real one calls India Post. A test suite must not reach the public
      // internet, and the form's PIN autofill fires on any valid six digits.
      pincodeRepositoryProvider.overrideWithValue(FakePincodeRepository()),
    ],
    child: MaterialApp(theme: AppTheme.light, home: child),
  );
}

/// A tall surface so the whole list / whole form is laid out — off-screen
/// slivers are never built, and `enterText` cannot reach a field that does not
/// exist.
///
/// ⚠ It is also 1000px WIDE, which is not a phone. Anything about horizontal
/// layout has to be asserted at [_usePhoneSurface] instead — testing only here
/// is how the address card's action row shipped overflowing by 152px.
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The narrowest screen the app supports, at the largest text scale a customer
/// can pick in the OS.
void _usePhoneSurface(WidgetTester tester, {double width = 320}) {
  tester.view.physicalSize = Size(width, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Lets a SnackBar's 4-second timer elapse. `testWidgets` fails the test if a
/// timer is still pending when the tree is torn down.
Future<void> _settleSnack(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// The form is pushed rather than mounted as `home` so that its `pop(true)` on
/// success has somewhere to go.
Widget _formHost({Address? address}) => Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(ctx).push<bool>(
              MaterialPageRoute<bool>(
                builder: (_) => AddressFormScreen(address: address),
              ),
            ),
            child: const Text('open form'),
          ),
        ),
      ),
    );

Future<void> _openForm(WidgetTester tester) async {
  await tester.tap(find.text('open form'));
  await tester.pumpAndSettle();
}

Finder _card(int id) => find.byKey(ValueKey('address-$id'));

/// Lets the PIN autofill run.
///
/// `pumpAndSettle` only advances the clock while frames are scheduled, so it
/// returns long before a 350ms debounce `Timer` fires — the lookup would never
/// happen and the assertions would all describe an un-autofilled form.
Future<void> _settlePinLookup(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Future<void> _fillValidForm(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('address-name')), 'Suraj ojha');
  await tester.enterText(
    find.byKey(const Key('address-phone')),
    '9876543210',
  );
  await tester.enterText(
    find.byKey(const Key('address-street')),
    '402, ganesh rivera',
  );
  // State first: choosing a state clears the city, because a city id only
  // means anything inside its own state.
  await pickGeo(
    tester,
    field: const Key('address-state'),
    option: 'Madhya Pradesh',
  );
  await pickGeo(tester, field: const Key('address-city'), option: 'Gwalior');
  await tester.enterText(find.byKey(const Key('address-zip')), '474010');
  // The PIN fills the district in, so let its lookup land before anything
  // asserts on the form.
  await _settlePinLookup(tester);
}

/// [_fillValidForm] without the email box, for the account that already has
/// one and therefore never sees the field.
Future<void> _fillFormWithoutEmail(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('address-name')), 'Suraj ojha');
  await tester.enterText(
    find.byKey(const Key('address-phone')),
    '9876543210',
  );
  await tester.enterText(
    find.byKey(const Key('address-street')),
    '402, ganesh rivera',
  );
  await pickGeo(
    tester,
    field: const Key('address-state'),
    option: 'Madhya Pradesh',
  );
  await pickGeo(tester, field: const Key('address-city'), option: 'Gwalior');
  await tester.enterText(find.byKey(const Key('address-zip')), '474010');
  await _settlePinLookup(tester);
}

void main() {
  // -------------------------------------------------------------------------
  // The four list states
  // -------------------------------------------------------------------------

  testWidgets('shows skeletons while the first read is in flight',
      (tester) async {
    final repo = _FakeAddressRepository(
      rows: _book,
      delay: const Duration(milliseconds: 50),
    );
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pump();

    expect(find.byType(SkeletonBox), findsWidgets);
    expect(find.text('Default'), findsNothing);

    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(SkeletonBox), findsNothing);
    expect(find.text('Default'), findsOneWidget);
  });

  testWidgets('a failed read shows a retryable error view that re-requests',
      (tester) async {
    final repo = _FakeAddressRepository(
      readError: ApiException.local('Network unreachable'),
    );
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.textContaining('Network unreachable'), findsOneWidget);
    expect(repo.reads, 1);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(repo.reads, 2);
    // Still failing, so the view stays rather than silently emptying.
    expect(find.byType(AppErrorView), findsOneWidget);
  });

  testWidgets('an empty book offers to add the first address', (tester) async {
    final repo = _FakeAddressRepository();
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EmptyView), findsOneWidget);
    expect(find.text('No saved addresses'), findsOneWidget);

    // Exactly one way in, and it is the bar at the bottom — the same control
    // that is there when the book is full. The empty state used to carry a
    // second button of its own, so an empty book offered the identical action
    // twice and a full one offered it once, in a different place.
    expect(find.text('Add an address'), findsNothing);
    expect(find.byKey(const Key('address-add')), findsOneWidget);

    await tester.tap(find.byKey(const Key('address-add')));
    await tester.pumpAndSettle();
    expect(find.text('Add a new address'), findsWidgets);
  });

  testWidgets('a populated book renders one card per row, badging only the '
      'server-flagged default', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(_card(16), findsOneWidget);
    expect(_card(57), findsOneWidget);
    expect(_card(50), findsOneWidget);

    expect(find.text('Default'), findsOneWidget);
    expect(
      find.descendant(of: _card(16), matching: find.text('Default')),
      findsOneWidget,
    );
    // The default row offers no "set as default"; the other two do.
    expect(find.text('Set as default'), findsNWidgets(2));

    // The server-rendered address is what gets shown — the raw "574"/"11" the
    // row actually stores must never reach the screen.
    expect(
      find.text(
        '306, Jahnavi Arcade, S.P. Ring Road, Odhav, Ahmedabad, '
        'Ahmedabad, Gujarat, 382415',
      ),
      findsNWidgets(2),
    );
    expect(find.text('574'), findsNothing);
  });

  testWidgets('signed out, the book asks for a sign-in instead of reading',
      (tester) async {
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo, signedIn: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign in to save addresses'), findsOneWidget);
    expect(repo.reads, 0);
  });

  // -------------------------------------------------------------------------
  // Mutations
  // -------------------------------------------------------------------------

  testWidgets('"Set as default" promotes the row and re-reads the book',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();
    expect(repo.reads, 1);

    await tester.tap(
      find.descendant(of: _card(57), matching: find.text('Set as default')),
    );
    await tester.pumpAndSettle();

    expect(repo.defaulted, [57]);
    // Re-read, not patched: the server demotes every other row, so local state
    // would otherwise show two badges.
    expect(repo.reads, 2);
    expect(
      find.descendant(of: _card(57), matching: find.text('Default')),
      findsOneWidget,
    );
    expect(find.text('Default'), findsOneWidget);

    await _settleSnack(tester);
  });

  testWidgets('delete asks first, then deletes and re-reads', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: _card(50), matching: find.text('Delete')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete this address?'), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete')),
    );
    await tester.pumpAndSettle();

    expect(repo.deleted, [50]);
    expect(repo.reads, 2);
    expect(_card(50), findsNothing);
    // The server's own sentence is shown, not a paraphrase.
    expect(find.text('Address deleted successfully'), findsOneWidget);

    await _settleSnack(tester);
  });

  testWidgets('promoting a row the server cannot accept names the real fix',
      (tester) async {
    _useTallSurface(tester);
    // A row saved through the lenient POST rules has no email, so the PUT that
    // promotion needs is rejected before it is sent.
    final repo = _FakeAddressRepository(
      rows: _book,
      writeError: const ApiException(
        'Enter an email address',
        kind: ApiErrorKind.validation,
        fieldErrors: {
          'email': ['Enter an email address'],
        },
      ),
    );
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: _card(57), matching: find.text('Set as default')),
    );
    await tester.pumpAndSettle();

    // No success claim, and no bare "Enter an email address" with no context.
    expect(find.textContaining('missing details the server needs'),
        findsOneWidget,);
    expect(find.text('Default address updated.'), findsNothing);
    // The badge did not move.
    expect(
      find.descendant(of: _card(16), matching: find.text('Default')),
      findsOneWidget,
    );

    await _settleSnack(tester);
  });

  testWidgets('a failed delete keeps the row and never claims success',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(
      rows: _book,
      writeError: const ApiException(
        'The server had a problem',
        kind: ApiErrorKind.server,
        statusCode: 500,
      ),
    );
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: _card(50), matching: find.text('Delete')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Delete'),),
    );
    await tester.pumpAndSettle();

    expect(find.text('Address deleted.'), findsNothing);
    expect(find.text('Address deleted successfully'), findsNothing);
    expect(find.textContaining('The server had a problem'), findsWidgets);
    // The row is still there, because it is still on the server.
    expect(_card(50), findsOneWidget);

    await _settleSnack(tester);
  });

  test('a mutation skipped because one is already in flight stays quiet',
      () async {
    // Guarded at the provider so the screen can never be handed a result that
    // is indistinguishable from a completed write.
    final repo = _FakeAddressRepository(rows: _book);
    final container = ProviderContainer(
      overrides: [addressRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    final sub = container.listen(addressBookProvider, (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    final notifier = container.read(addressBookProvider.notifier);
    final first = notifier.delete(50);
    // Issued while the first is still in flight.
    final second = await notifier.delete(50);
    expect(second.ran, isFalse);
    expect(second.message, isNull);

    expect((await first).ran, isTrue);
    expect(repo.deleted, [50]);
  });

  testWidgets('the empty book can be pulled to refresh', (tester) async {
    // Phone-sized on purpose: RefreshIndicator only arms once the drag passes
    // 25% of the viewport height, which a 3000px test surface never reaches.
    _usePhoneSurface(tester, width: 400);
    final repo = _FakeAddressRepository();
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();
    expect(find.byType(EmptyView), findsOneWidget);
    expect(repo.reads, 1);

    repo.rows = _book;
    await tester.drag(
      find.text('No saved addresses'),
      const Offset(0, 300),
      touchSlopY: 0,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(repo.reads, 2);
    // The empty view is never swapped for skeletons mid-pull.
    expect(find.byType(SkeletonBox), findsNothing);
    expect(_card(16), findsOneWidget);
  });

  testWidgets('cancelling the delete dialog deletes nothing', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: _card(50), matching: find.text('Delete')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(repo.deleted, isEmpty);
    expect(repo.reads, 1);
    expect(_card(50), findsOneWidget);
  });

  testWidgets('deleting the default warns that another row is promoted',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: _card(16), matching: find.text('Delete')),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('newest remaining address the default'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  // -------------------------------------------------------------------------
  // Layout on a real phone
  // -------------------------------------------------------------------------

  testWidgets('the card lays out on a 320dp screen without overflowing',
      (tester) async {
    _usePhoneSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();

    // Every action is still reachable — the fix must not have hidden one — and
    // nothing paints the overflow stripes on the way down the list.
    expect(tester.takeException(), isNull);
    expect(find.text('Set as default'), findsWidgets);
    expect(find.text('Edit'), findsWidgets);
    expect(find.text('Delete'), findsWidgets);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_card(50), findsOneWidget);
    expect(
      find.descendant(of: _card(50), matching: find.text('Set as default')),
      findsOneWidget,
    );
  });

  testWidgets('the card survives the largest OS text scale', (tester) async {
    _usePhoneSurface(tester, width: 360);
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
        child: await _wrap(const AddressBookScreen(), repo: repo),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('every action clears the 44dp tap-target floor', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();

    for (final label in ['Set as default', 'Edit', 'Delete']) {
      for (final element in find.text(label).evaluate()) {
        final button = find
            .ancestor(of: find.byWidget(element.widget), matching: find.byType(TextButton))
            .first;
        expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
      }
    }
  });

  testWidgets('a book with no default says so', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: [_secondary, _gwalior]);
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('No default address set'), findsOneWidget);
    expect(find.text('Default'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // The form
  // -------------------------------------------------------------------------

  testWidgets('an empty form refuses to save and explains the phone rule',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
    await tester.pumpAndSettle();
    await _openForm(tester);

    await tester.tap(find.text('Save address'));
    await tester.pumpAndSettle();

    expect(repo.created, isEmpty);
    expect(find.text('Enter a name'), findsOneWidget);
    expect(find.text('Enter a mobile number'), findsOneWidget);
    // No email complaint: the field is gone from this form — order mail goes
    // to the account — so an error about it would name something the customer
    // cannot see or fix.
    expect(find.text('Enter an email address'), findsNothing);
  });

  testWidgets('a landline is rejected client-side with the reason',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
    await tester.pumpAndSettle();
    await _openForm(tester);

    await _fillValidForm(tester);
    // Starts with 1, which the server's ^[6-9] rule rejects.
    await tester.enterText(
      find.byKey(const Key('address-phone')),
      '1234567890',
    );
    await tester.pump();
    await tester.tap(find.text('Save address'));
    await tester.pumpAndSettle();

    expect(repo.created, isEmpty);
    expect(
      find.text('Enter a 10-digit Indian mobile number starting 6-9'),
      findsOneWidget,
    );
  });

  testWidgets('a valid create sends a string phone and omits is_default',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
    await tester.pumpAndSettle();
    await _openForm(tester);

    await _fillValidForm(tester);
    await tester.tap(find.text('Save address'));
    await tester.pumpAndSettle();

    expect(repo.created, hasLength(1));
    final body = repo.created.single.toJson();
    expect(body['phone'], '9876543210');
    expect(body['phone'], isA<String>());
    expect(body['name'], 'Suraj ojha');
    expect(body['city'], '900', reason: 'the id, not the name');
    // The store ships in one country and the server fills it. Sending the
    // rendered name — which is what this used to do — overwrote the stored
    // country id with the literal string "India".
    expect(body.containsKey('country'), isFalse);
    // Untouched switch -> key absent, so the server's flag is left alone.
    expect(body.containsKey('is_default'), isFalse);

    // The write is followed by a re-read, and the form pops on success.
    expect(repo.reads, greaterThanOrEqualTo(2));
    expect(find.text('open form'), findsOneWidget);

    await _settleSnack(tester);
  });

  testWidgets('the default switch sends a JSON boolean, never a string',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
    await tester.pumpAndSettle();
    await _openForm(tester);

    await _fillValidForm(tester);
    await tester.tap(find.byKey(const Key('address-default-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save address'));
    await tester.pumpAndSettle();

    expect(repo.created.single.toJson()['is_default'], isTrue);
    expect(repo.created.single.toJson()['is_default'], isA<bool>());

    await _settleSnack(tester);
  });

  testWidgets('editing shows the region names and holds on to the ids',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      await _wrap(_formHost(address: _default), repo: repo),
    );
    await tester.pumpAndSettle();
    await _openForm(tester);

    // Prefilled from the row...
    expect(find.text('Suraj ojha'), findsOneWidget);
    expect(find.text('8305317276'), findsOneWidget);

    // ...including the two pickers, which read the NAMES the server sends
    // beside the ids. The row stores "11"/"574"; neither is ever shown, and
    // neither has to be looked up — `state_name`/`city_name` arrive with the
    // row itself, so there is nothing to resolve and nothing to wait for.
    expect(find.text('Gujarat'), findsWidgets);
    expect(find.text('Ahmedabad'), findsWidgets);
    expect(find.text('574'), findsNothing);
    expect(find.text('11'), findsNothing);

    // The server-rendered address is still offered as the reference copy.
    expect(find.textContaining('Ahmedabad, Gujarat, 382415'), findsOneWidget);

    // Editing the current default offers no demotion control.
    expect(find.byKey(const Key('address-default-switch')), findsNothing);
    expect(find.textContaining('This is your default address'), findsOneWidget);
  });

  testWidgets('saving without touching the pickers round-trips the stored ids',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      await _wrap(_formHost(address: _default), repo: repo),
    );
    await tester.pumpAndSettle();
    await _openForm(tester);

    // Touch nothing at all, then save.
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    // The whole point: the ids survive. Submitting "Gujarat"/"Ahmedabad" here
    // would look identical on screen and be rejected outright — `state` is
    // `exists`-validated and accepts only a bare `states.id`.
    final sent = repo.updated.single.$2.toJson();
    expect(sent['state'], '11');
    expect(sent['city'], '574');

    await _settleSnack(tester);
  });

  testWidgets('choosing a different state clears the city beneath it',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      await _wrap(_formHost(address: _default), repo: repo),
    );
    await tester.pumpAndSettle();
    await _openForm(tester);

    expect(find.text('Ahmedabad'), findsWidgets);

    await pickGeo(
      tester,
      field: const Key('address-state'),
      option: 'Madhya Pradesh',
    );

    // Nothing on the server checks that a city belongs to its state — a
    // Gujarat address happily stores a Delhi city id — so keeping the old
    // selection would produce an address nobody can deliver to, silently.
    expect(find.text('Ahmedabad'), findsNothing);
    expect(find.text('Select city'), findsOneWidget);

    // And it refuses to save in that state rather than sending a blank city.
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(repo.updated, isEmpty);

    await _settleSnack(tester);
  });

  testWidgets('"Other" reveals a town box, and both are sent', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
    await tester.pumpAndSettle();
    await _openForm(tester);

    await _fillValidForm(tester);
    await pickGeo(tester, field: const Key('address-city'), option: 'Other');

    // The box only exists once "Other" is chosen.
    final town = find.byKey(const Key('address-other-city'));
    expect(town, findsOneWidget);

    // Saving without it is refused here rather than at the server, which
    // answers "The other city field is required when city is other."
    await tester.tap(find.text('Save address'));
    await tester.pumpAndSettle();
    expect(repo.created, isEmpty);

    await tester.enterText(town, 'Bhitarwar');
    await tester.pump();
    await tester.tap(find.text('Save address'));
    await tester.pumpAndSettle();

    final body = repo.created.single.toJson();
    expect(body['city'], 'other');
    expect(body['other_city'], 'Bhitarwar');

    await _settleSnack(tester);
  });

  testWidgets('a real city sends no other_city', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
    await tester.pumpAndSettle();
    await _openForm(tester);

    await _fillValidForm(tester);
    await tester.tap(find.text('Save address'));
    await tester.pumpAndSettle();

    // Sending a town name beside a real city id would record a place this
    // address is not in.
    expect(repo.created.single.toJson().containsKey('other_city'), isFalse);
    expect(find.byKey(const Key('address-other-city')), findsNothing);

    await _settleSnack(tester);
  });

  testWidgets('the landmark and district are saved, not silently dropped',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository();
    await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
    await tester.pumpAndSettle();
    await _openForm(tester);

    await _fillValidForm(tester);
    await tester.enterText(
      find.byKey(const Key('address-landmark')),
      'opposite the bus stand',
    );
    await tester.pump();
    await tester.tap(find.text('Save address'));
    await tester.pumpAndSettle();

    // All three fields existed on the server all along and the app discarded
    // them — saving from the app wiped a landmark the website had stored.
    final body = repo.created.single.toJson();
    expect(body['landmark'], 'opposite the bus stand');
    // The district came from the PIN. It is posted as text; there is no
    // districts table on the server to hold an id.
    expect(body['district'], 'Gwalior');

    await _settleSnack(tester);
  });

  // -------------------------------------------------------------------------
  // PIN autofill
  //
  // The store has no PIN lookup of its own — `check-pincode` answers with a
  // courier and a price and no location at all — so this comes from India
  // Post's public service and is matched against the store's own lists. It is
  // convenience only: every field it fills stays editable.
  // -------------------------------------------------------------------------
  group('the PIN code fills the rest in', () {
    testWidgets('state, city and district all land', (tester) async {
      _useTallSurface(tester);
      final repo = _FakeAddressRepository();
      await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
      await tester.pumpAndSettle();
      await _openForm(tester);

      await tester.enterText(find.byKey(const Key('address-zip')), '474010');
      await _settlePinLookup(tester);

      expect(find.text('Madhya Pradesh'), findsOneWidget);
      expect(find.text('Gwalior'), findsWidgets);
    });

    testWidgets('and what lands is the store\'s own id, not a typed name',
        (tester) async {
      _useTallSurface(tester);
      final repo = _FakeAddressRepository();
      await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
      await tester.pumpAndSettle();
      await _openForm(tester);

      await tester.enterText(find.byKey(const Key('address-name')), 'Asha');
      await tester.enterText(
        find.byKey(const Key('address-phone')),
        '9876543210',
      );
      await tester.enterText(
        find.byKey(const Key('address-street')),
        '402, ganesh rivera',
      );
      await tester.enterText(find.byKey(const Key('address-zip')), '474010');
      await _settlePinLookup(tester);
      await tester.tap(find.text('Save address'));
      await tester.pumpAndSettle();

      // `state` is `exists`-validated: a name is a 422. An autofill that put
      // "Madhya Pradesh" in the draft would look right and save nothing.
      final body = repo.created.single.toJson();
      expect(body['state'], '20');
      expect(body['city'], '900');
      expect(body['district'], 'Gwalior');

      await _settleSnack(tester);
    });

    // India Post spells the block "Ahmadabad City" where the store's row is
    // "Ahmedabad". Matching the DISTRICT rather than the block is what makes
    // this land.
    testWidgets('matches across a spelling difference', (tester) async {
      _useTallSurface(tester);
      final repo = _FakeAddressRepository();
      await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
      await tester.pumpAndSettle();
      await _openForm(tester);

      await tester.enterText(find.byKey(const Key('address-zip')), '382415');
      await _settlePinLookup(tester);

      expect(find.text('Gujarat'), findsOneWidget);
      expect(find.text('Ahmedabad'), findsWidgets);
      expect(find.text('Ahmadabad City'), findsNothing);
    });

    // 110001 covers Central Delhi and New Delhi. Picking one would be a guess,
    // and a wrong district on a label is worse than an unfilled field.
    testWidgets('offers both districts rather than guessing', (tester) async {
      _useTallSurface(tester);
      final repo = _FakeAddressRepository();
      await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
      await tester.pumpAndSettle();
      await _openForm(tester);

      await tester.enterText(find.byKey(const Key('address-zip')), '110001');
      await _settlePinLookup(tester);

      expect(find.text('Delhi'), findsOneWidget);
      expect(find.text('Select district'), findsOneWidget);

      await pickGeo(
        tester,
        field: const Key('address-district'),
        option: 'Central Delhi',
      );
      expect(find.text('Select district'), findsNothing);
    });

    // The state name matched nothing in the store's list, so there is no id to
    // post and the field is left alone. An unmatched name in the draft would be
    // a 422 the customer cannot act on.
    testWidgets('leaves the state alone when the name matches nothing',
        (tester) async {
      _useTallSurface(tester);
      final repo = _FakeAddressRepository();
      await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
      await tester.pumpAndSettle();
      await _openForm(tester);

      await tester.enterText(find.byKey(const Key('address-zip')), '744101');
      await _settlePinLookup(tester);

      expect(find.text('Select state'), findsOneWidget);
      // The district still fills — it is free text and needs no match.
      expect(find.text('Nowhere'), findsOneWidget);
    });

    testWidgets('an unknown PIN changes nothing and says nothing',
        (tester) async {
      _useTallSurface(tester);
      final repo = _FakeAddressRepository();
      await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
      await tester.pumpAndSettle();
      await _openForm(tester);

      await tester.enterText(find.byKey(const Key('address-zip')), '999998');
      await _settlePinLookup(tester);

      expect(find.text('Select state'), findsOneWidget);
      // The District hint now says what is actually true: the PIN is there and
      // the lookup came back with nothing. It used to read "Enter a PIN code
      // first" on a form with 999998 sitting in the box.
      expect(find.text('No districts found for this PIN'), findsOneWidget);
      expect(find.text('Enter a PIN code first'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // The customer's own correction has to survive the lookup they triggered.
    testWidgets('a city the customer already chose is not overwritten',
        (tester) async {
      _useTallSurface(tester);
      final repo = _FakeAddressRepository();
      await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
      await tester.pumpAndSettle();
      await _openForm(tester);

      await pickGeo(
        tester,
        field: const Key('address-state'),
        option: 'Madhya Pradesh',
      );
      await pickGeo(tester, field: const Key('address-city'), option: 'Indore');
      await tester.enterText(find.byKey(const Key('address-zip')), '474010');
      await _settlePinLookup(tester);

      // The PIN says Gwalior; the customer said Indore. Same state, so nothing
      // is cleared, and the explicit choice wins.
      expect(find.text('Indore'), findsOneWidget);
    });

    // Opening the form to fix a typo in the street line must not re-stamp three
    // fields from the PIN that is already in the box — but it DOES have to
    // fetch the district list, which lives nowhere but the PIN lookup. Without
    // that fetch the District picker refused to open on an address that
    // plainly had a PIN in it.
    testWidgets('editing an existing row loads districts without re-stamping',
        (tester) async {
      _useTallSurface(tester);
      final repo = _FakeAddressRepository(rows: _book);
      await tester.pumpWidget(
        await _wrap(_formHost(address: _default), repo: repo),
      );
      await tester.pumpAndSettle();
      await _openForm(tester);
      await _settlePinLookup(tester);

      final fake = ProviderScope.containerOf(
        tester.element(find.byType(AddressFormScreen)),
      ).read(pincodeRepositoryProvider) as FakePincodeRepository;

      // Row 16 holds 382415. One lookup, for its districts.
      expect(fake.lookups, ['382415']);

      // And nothing the row already carried was touched by it.
      expect(find.text('Gujarat'), findsOneWidget);
      expect(find.text('Enter a PIN code first'), findsNothing);

      // The picker opens now, which is the whole point.
      await tester.tap(find.byKey(const Key('address-district')));
      await tester.pumpAndSettle();
      expect(find.text('Select district'), findsWidgets);
    });
  });

  testWidgets('an edit that never touches the switch omits is_default',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      await _wrap(_formHost(address: _default), repo: repo),
    );
    await tester.pumpAndSettle();
    await _openForm(tester);

    await tester.enterText(
      find.byKey(const Key('address-street')),
      '402, ganesh rivera',
    );
    await tester.pump();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(repo.updated, hasLength(1));
    final (id, draft) = repo.updated.single;
    expect(id, 16);
    // Sending is_default:false here would demote the customer's only default
    // and nothing on the server re-promotes on update.
    expect(draft.isDefault, isNull);
    expect(draft.toJson().containsKey('is_default'), isFalse);
    expect(draft.toJson()['city'], '574');
    // full_address is read-only and is never echoed back.
    expect(draft.toJson().containsKey('full_address'), isFalse);

    await _settleSnack(tester);
  });

  testWidgets('a server 422 lands under the field it names', (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(
      writeError: const ApiException(
        'The given data was invalid.',
        kind: ApiErrorKind.validation,
        statusCode: 422,
        fieldErrors: {
          'phone': ['The phone must be a string.'],
        },
      ),
    );
    await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
    await tester.pumpAndSettle();
    await _openForm(tester);

    await _fillValidForm(tester);
    await tester.tap(find.text('Save address'));
    await tester.pumpAndSettle();

    expect(find.text('The phone must be a string.'), findsWidgets);
    // The form stays put so the customer can fix it.
    expect(find.text('Save address'), findsOneWidget);

    await _settleSnack(tester);
  });

  testWidgets('editing a rejected field clears the server message',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(
      writeError: const ApiException(
        'The given data was invalid.',
        kind: ApiErrorKind.validation,
        statusCode: 422,
        fieldErrors: {
          'phone': ['The phone must be a string.'],
        },
      ),
    );
    await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
    await tester.pumpAndSettle();
    await _openForm(tester);

    await _fillValidForm(tester);
    await tester.tap(find.text('Save address'));
    await tester.pumpAndSettle();
    expect(find.text('The phone must be a string.'), findsWidgets);

    // The customer changes the phone. The complaint was about the *old* value,
    // so it must stop being painted under a field that no longer holds it —
    // otherwise a corrected field still reads as broken.
    await tester.enterText(
      find.byKey(const Key('address-phone')),
      '9998887776',
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('address-phone')),
        matching: find.text('The phone must be a string.'),
      ),
      findsNothing,
    );

    await _settleSnack(tester);
  });

  // -------------------------------------------------------------------------
  // Provider-level
  // -------------------------------------------------------------------------

  test('a failed refresh keeps the rows and reports the failure', () async {
    final repo = _FakeAddressRepository(rows: _book);
    final container = ProviderContainer(
      overrides: [addressRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);

    final sub = container.listen(addressBookProvider, (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(addressBookProvider).addresses, hasLength(3));

    repo.readError = ApiException.local('Gateway timeout');
    await container.read(addressBookProvider.notifier).refresh();

    final state = container.read(addressBookProvider);
    // The refresh failed; the addresses did not vanish. Blanking a list the
    // customer is looking at because a re-read timed out would be a lie in the
    // other direction.
    expect(state.addresses, hasLength(3));
    expect(state.error?.message, 'Gateway timeout');
    expect(state.loading, isFalse);
    expect(state.refreshing, isFalse);
  });

  testWidgets('a failed background refresh keeps the rows under a stale-data '
      'strip', (tester) async {
    // The headline claim of this screen, asserted where the customer sees it:
    // a failed re-read must not blank the list, and must not pass the old rows
    // off as current either.
    _usePhoneSurface(tester, width: 400);
    final repo = _FakeAddressRepository(rows: _book);
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();
    expect(find.byType(InlineErrorStrip), findsNothing);

    repo.readError = ApiException.local('Gateway timeout');
    await tester.drag(_card(16), const Offset(0, 300), touchSlopY: 0);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(repo.reads, 2);
    // Rows survive...
    expect(_card(16), findsOneWidget);
    // ...but the screen admits they may be stale rather than showing them as
    // if the read had succeeded.
    expect(find.byType(InlineErrorStrip), findsOneWidget);
    expect(find.textContaining('Gateway timeout'), findsOneWidget);
    expect(find.byType(AppErrorView), findsNothing);
  });

  testWidgets('deleting the only address does not promise a promotion',
      (tester) async {
    _useTallSurface(tester);
    // destroy() promotes the newest *survivor*. With one row there is none, so
    // the dialog must not claim another address becomes the default.
    final repo = _FakeAddressRepository(rows: [_default]);
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: _card(16), matching: find.text('Delete')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('newest remaining address'), findsNothing);
    expect(find.textContaining('only saved address'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('the first address is announced as the default, not offered as '
      'a switch', (tester) async {
    _useTallSurface(tester);
    // store() forces is_default on the customer's first address whatever the
    // request asked for, so a switch sitting in its off position would promise
    // the opposite of what the server is about to do.
    final repo = _FakeAddressRepository();
    await tester.pumpWidget(
      await _wrap(const AddressBookScreen(), repo: repo),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('address-add')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('address-default-switch')), findsNothing);
    expect(
      find.textContaining('This will be your default address'),
      findsOneWidget,
    );
  });

  testWidgets('a failed create never claims the address was saved',
      (tester) async {
    _useTallSurface(tester);
    final repo = _FakeAddressRepository(
      writeError: const ApiException(
        'The server had a problem',
        kind: ApiErrorKind.server,
        statusCode: 500,
      ),
    );
    await tester.pumpWidget(await _wrap(_formHost(), repo: repo));
    await tester.pumpAndSettle();
    await _openForm(tester);

    await _fillValidForm(tester);
    await tester.tap(find.text('Save address'));
    await tester.pumpAndSettle();

    expect(find.text('Address saved.'), findsNothing);
    expect(find.textContaining('The server had a problem'), findsWidgets);
    // Still on the form, with the details intact, rather than popped back to a
    // list that does not contain the address.
    expect(find.text('Save address'), findsOneWidget);
    expect(find.text('open form'), findsNothing);

    await _settleSnack(tester);
  });

  test('a failed write leaves the stale-data warning in place', () async {
    // The pending flag used to clear the read error, so tapping Delete removed
    // the "these rows may be stale" strip; if the write then failed nothing
    // put it back and the list went on showing rows it had already admitted
    // might be wrong.
    final repo = _FakeAddressRepository(rows: _book);
    final container = ProviderContainer(
      overrides: [addressRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    final sub = container.listen(addressBookProvider, (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    repo.readError = ApiException.local('Gateway timeout');
    await container.read(addressBookProvider.notifier).refresh();
    expect(container.read(addressBookProvider).error?.message, 'Gateway timeout');

    repo.writeError = const ApiException(
      'The server had a problem',
      kind: ApiErrorKind.server,
      statusCode: 500,
    );
    await expectLater(
      container.read(addressBookProvider.notifier).delete(50),
      throwsA(isA<ApiException>()),
    );

    final state = container.read(addressBookProvider);
    expect(state.addresses, hasLength(3));
    expect(state.pending, isEmpty);
    expect(state.error?.message, 'Gateway timeout');
  });

  test('a successful write clears the stale-data warning', () async {
    final repo = _FakeAddressRepository(rows: _book);
    final container = ProviderContainer(
      overrides: [addressRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    final sub = container.listen(addressBookProvider, (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    repo.readError = ApiException.local('Gateway timeout');
    await container.read(addressBookProvider.notifier).refresh();
    expect(container.read(addressBookProvider).error, isNotNull);

    repo.readError = null;
    final result = await container.read(addressBookProvider.notifier).delete(50);
    expect(result.ran, isTrue);
    final state = container.read(addressBookProvider);
    expect(state.error, isNull);
    expect(state.addresses, hasLength(2));
  });

  test('the default is the flagged row, never a guess', () async {
    final repo = _FakeAddressRepository(rows: [_secondary, _gwalior]);
    final container = ProviderContainer(
      overrides: [addressRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    final sub = container.listen(addressBookProvider, (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    // The repository's own defaultAddress() would return the first row here.
    expect(container.read(addressBookProvider).defaultAddress, isNull);
  });
  // -------------------------------------------------------------------------
  // Search
  //
  // The book is three rows in these tests and can be a dozen in real use. What
  // makes searching it non-trivial is that `state` and `city` hold **opaque geo
  // ids** — id 16 stores `"11"` and `"574"` while its card reads "Gujarat" and
  // "Ahmedabad" — so a filter over the stored fields would find nothing for the
  // words on screen. The model's own coverage is in
  // test/data/address_search_test.dart; these are about the screen.
  // -------------------------------------------------------------------------

  group('search', () {
    Future<void> pump(WidgetTester tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _wrap(
          const AddressBookScreen(),
          repo: _FakeAddressRepository(rows: _book),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> type(WidgetTester tester, String query) async {
      await tester.enterText(
        find.byKey(const Key('address-search-field')),
        query,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the field is there and nothing is filtered to begin with',
        (tester) async {
      await pump(tester);

      expect(find.byKey(const Key('address-search-field')), findsOneWidget);
      // No count line and no × until there is a query — controls that would do
      // nothing.
      expect(find.byKey(const Key('address-search-count')), findsNothing);
      expect(find.byKey(const Key('address-search-clear')), findsNothing);
      for (final id in [16, 57, 50]) {
        expect(_card(id), findsOneWidget, reason: '$id');
      }
    });

    testWidgets('a city name narrows the book, ids and all', (tester) async {
      // id 50 is the Gwalior row; the other two are Ahmedabad.
      await pump(tester);
      await type(tester, 'gwalior');

      expect(_card(50), findsOneWidget);
      expect(_card(16), findsNothing);
      expect(_card(57), findsNothing);
    });

    testWidgets('a stored geo id is NOT what the customer types', (tester) async {
      // The regression this guards: id 16 stores city "574", and searching the
      // stored value would be the only thing that worked.
      await pump(tester);
      await type(tester, 'ahmedabad');

      expect(_card(16), findsOneWidget, reason: 'stored as 574');
      expect(_card(50), findsNothing);
    });

    testWidgets('it says how much of the book is on screen', (tester) async {
      // "1 of 3" is the difference between a filtered book and a book that
      // lost rows.
      await pump(tester);
      await type(tester, 'gwalior');

      expect(find.text('1 of 3 addresses'), findsOneWidget);
    });

    testWidgets('a search that matches nothing says so, and offers the way out',
        (tester) async {
      // Not "No saved addresses" — that would be a false statement about an
      // account that has three.
      await pump(tester);
      await type(tester, 'mumbai');

      expect(find.byKey(const Key('address-search-empty')), findsOneWidget);
      expect(find.text('No saved addresses'), findsNothing);
      expect(find.text('0 of 3 addresses'), findsOneWidget);

      await tester.tap(find.byKey(const Key('address-search-clear-empty')));
      await tester.pumpAndSettle();

      for (final id in [16, 57, 50]) {
        expect(_card(id), findsOneWidget, reason: '$id');
      }
    });

    testWidgets('the clear button restores the whole book', (tester) async {
      await pump(tester);
      await type(tester, 'gwalior');
      expect(_card(16), findsNothing, reason: 'the premise');

      await tester.tap(find.byKey(const Key('address-search-clear')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('address-search-count')), findsNothing);
      for (final id in [16, 57, 50]) {
        expect(_card(id), findsOneWidget, reason: '$id');
      }
    });

    testWidgets('a filtered row can still be edited and deleted',
        (tester) async {
      // The cards are the real ones, not a read-only search result — the
      // actions have to survive being filtered to.
      await pump(tester);
      await type(tester, 'gwalior');

      expect(
        find.descendant(of: _card(50), matching: find.text('Edit')),
        findsOneWidget,
      );
    });
  });

  // The client asked for the email field to go, and it is gone for everyone:
  // order mail goes to the account's registered address, and there is no guest
  // checkout, so a per-address email only ever repeated what the account holds.
  group('email field', () {
    testWidgets('is not on the form', (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        await _wrap(
          const AddressFormScreen(),
          repo: _FakeAddressRepository(),
          customer: const Customer(
            id: 1,
            name: 'Asha Kumar',
            email: 'asha@example.com',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('address-email')), findsNothing);
      expect(find.text('Email address'), findsNothing);
    });

    testWidgets('the saved address still carries the account email',
        (tester) async {
      _useTallSurface(tester);
      final repo = _FakeAddressRepository();
      await tester.pumpWidget(
        await _wrap(
          const AddressFormScreen(),
          repo: repo,
          customer: const Customer(
            id: 1,
            name: 'Asha Kumar',
            email: 'asha@example.com',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _fillFormWithoutEmail(tester);
      await tester.tap(find.text('Save address'));
      await tester.pumpAndSettle();

      // The field is off screen, but the row the server stores still has an
      // address to mail — checkout reads it.
      expect(repo.created, isNotEmpty, reason: 'the save went through');
      expect(repo.created.last.email, 'asha@example.com');
    });

    // Nothing on screen can report an email problem, so nothing may block on
    // one either — that would be a save failing with no visible cause.
    testWidgets('a missing account email does not block the save',
        (tester) async {
      _useTallSurface(tester);
      final repo = _FakeAddressRepository();
      await tester.pumpWidget(
        await _wrap(const AddressFormScreen(), repo: repo),
      );
      await tester.pumpAndSettle();

      await _fillFormWithoutEmail(tester);
      await tester.tap(find.text('Save address'));
      await tester.pumpAndSettle();

      expect(repo.created, isNotEmpty);
      expect(repo.created.last.email, isEmpty);
    });
  });
}

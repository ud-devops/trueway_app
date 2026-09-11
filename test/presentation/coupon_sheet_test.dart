/// The coupon picker.
///
/// Two things it must never do, both of which the old one-field dialog did by
/// construction:
///
///   * **close on a refusal.** The point of showing a list is that a code the
///     server will not take leaves the customer looking at the other codes. The
///     dialog popped first and reported afterwards, so a rejected code meant
///     reopening it.
///   * **paraphrase the server.** "You are under ₹5,000.00 to apply the coupon,
///     you must add ₹3,157.00 more items to your cart" names the actual
///     constraint with figures computed against the live basket. Substituting
///     "This coupon isn't valid" loses the only useful half.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/data/models/coupon.dart';
import 'package:trueway_farms/presentation/providers/auth_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/server_cart_provider.dart';
import 'package:trueway_farms/presentation/widgets/coupon_sheet.dart';

import '../support/fake_cart_repository.dart';

const _line = FakeCartLine(
  id: 118,
  name: 'Trueway Farms Organic Sona Moti Wheat',
  quantity: 2,
  unitPrice: 899,
);

/// The live shape, `?cart_id=<real>`.
final _eligible = Coupon.fromJson(const {
  'code': 'HNHPQ2YWQJD0',
  'description': 'Cupan Code',
  'value': 50,
  'type_option': 'percentage',
  'value_formatted': '50%',
  'is_eligible': true,
});

final _tooSmall = Coupon.fromJson(const {
  'code': 'BIG5000',
  'value': 500,
  'type_option': 'amount',
  'value_formatted': '₹500.00',
  'target': 'minimum-order-amount',
  'min_order_price': 5000,
  'min_order_price_formatted': '₹5,000.00',
  'is_eligible': false,
  'amount_to_add': 3157,
  'amount_to_add_formatted': '₹3,157.00',
});

/// The refusal the server sends for a code it will not take, verbatim.
ApiException _badCode() => ApiException(
      'This coupon is invalid or expired!',
      kind: ApiErrorKind.businessRule,
      statusCode: 200,
    );

CouponSheetResult? _result;

Future<(ProviderContainer, FakeCartRepository)> _open(
  WidgetTester tester, {
  List<Coupon> coupons = const [],
  Object? couponsError,
}) async {
  _result = null;
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues({'server_cart_id_v1': 'cart-test'});
  final prefs = await SharedPreferences.getInstance();
  final repo = FakeCartRepository(lines: const [_line])
    ..coupons = coupons
    ..couponsError = couponsError;

  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      cartRepositoryProvider.overrideWithValue(repo),
      isAuthenticatedProvider.overrideWithValue(false),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                _result = await showCouponSheet(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  // Let the cart load before the sheet asks for its id.
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return (container, repo);
}

Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

void main() {
  group('the list', () {
    testWidgets('shows every advertised coupon with the server\'s own figure',
        (tester) async {
      await _open(tester, coupons: [_eligible, _tooSmall]);

      expect(find.byKey(const Key('coupon-card-HNHPQ2YWQJD0')), findsOneWidget);
      expect(find.byKey(const Key('coupon-card-BIG5000')), findsOneWidget);
      // `value_formatted`, not a locally formatted `value`.
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('Cupan Code'), findsOneWidget);
      // Twice for BIG5000, and correctly so: it has no description and no
      // title — like `M20` on the live shop — so the subtitle falls back to the
      // formatted value, which the badge is already showing. A blank line under
      // the code would read as a broken card.
      expect(find.text('₹500.00'), findsNWidgets(2));
    });

    testWidgets('an ineligible coupon is dead and says how much short',
        (tester) async {
      await _open(tester, coupons: [_eligible, _tooSmall]);

      final blocked = tester.widget<TextButton>(
        find.byKey(const Key('coupon-apply-BIG5000')),
      );
      expect(blocked.onPressed, isNull);
      // The server's shortfall, not a sentence the app invented.
      expect(find.text('Add ₹3,157.00 more to use this'), findsOneWidget);

      // ...and the eligible one is untouched by it.
      final live = tester.widget<TextButton>(
        find.byKey(const Key('coupon-apply-HNHPQ2YWQJD0')),
      );
      expect(live.onPressed, isNotNull);
    });

    testWidgets('unknown eligibility stays offerable', (tester) async {
      // `?cart_id=<unknown>` returns the full list with `is_eligible: null`.
      // Greying everything out would punish a stale cart id.
      final unknown = Coupon.fromJson(const {
        'code': 'M20',
        'value_formatted': '20%',
        'is_eligible': null,
      });
      await _open(tester, coupons: [unknown]);

      final button = tester.widget<TextButton>(
        find.byKey(const Key('coupon-apply-M20')),
      );
      expect(button.onPressed, isNotNull);
      expect(find.byKey(const Key('coupon-blocked-M20')), findsNothing);
    });

    testWidgets('an empty list is not a dead end', (tester) async {
      // Only admin-ticked coupons are listed; a WhatsApp code is not among them
      // and still works, so the field above is the whole point.
      await _open(tester);

      expect(find.byKey(const Key('coupon-list-empty')), findsOneWidget);
      expect(find.byKey(const Key('coupon-manual-field')), findsOneWidget);
    });

    testWidgets('a failed list keeps the code field usable', (tester) async {
      await _open(tester, couponsError: ApiException('offline'));

      expect(find.byKey(const Key('coupon-list-error')), findsOneWidget);
      // "We couldn't fetch the offers" must not take away the ability to use a
      // code the customer already has.
      expect(find.byKey(const Key('coupon-manual-field')), findsOneWidget);
    });
  });

  group('applying', () {
    testWidgets('a tapped coupon applies and closes the sheet', (tester) async {
      final (container, repo) = await _open(tester, coupons: [_eligible]);

      await _tap(tester, const Key('coupon-apply-HNHPQ2YWQJD0'));

      expect(repo.calls, contains('applyCoupon(HNHPQ2YWQJD0)'));
      expect(_result, isNotNull);
      expect(_result!.appliedCode, 'HNHPQ2YWQJD0');
      expect(_result!.removed, isFalse);
      expect(
        container.read(serverCartProvider).appliedCouponCode,
        'HNHPQ2YWQJD0',
      );
    });

    testWidgets('a refusal keeps the sheet open and quotes the server',
        (tester) async {
      final (_, repo) = await _open(tester, coupons: [_eligible]);
      repo.nextError = _badCode();

      await _tap(tester, const Key('coupon-apply-HNHPQ2YWQJD0'));

      expect(_result, isNull, reason: 'the sheet must not close');
      expect(find.byKey(const Key('coupon-failure')), findsOneWidget);
      expect(find.text('This coupon is invalid or expired!'), findsOneWidget);
      // Still choosing from the same list.
      expect(find.byKey(const Key('coupon-card-HNHPQ2YWQJD0')), findsOneWidget);
    });

    testWidgets('a typed code applies even when it is not in the list',
        (tester) async {
      final (_, repo) = await _open(tester);

      await tester.enterText(
        find.byKey(const Key('coupon-manual-field')),
        'whatsapp10',
      );
      await tester.pumpAndSettle();
      await _tap(tester, const Key('coupon-manual-apply'));

      // Uppercased on the way out, the way every code on this backend is.
      expect(repo.calls, contains('applyCoupon(WHATSAPP10)'));
      expect(_result!.appliedCode, 'WHATSAPP10');
    });

    testWidgets('the Apply button is dead until something is typed',
        (tester) async {
      await _open(tester);

      final before = tester.widget<ElevatedButton>(
        find.byKey(const Key('coupon-manual-apply')),
      );
      expect(before.onPressed, isNull);

      await tester.enterText(
        find.byKey(const Key('coupon-manual-field')),
        'M20',
      );
      await tester.pumpAndSettle();

      final after = tester.widget<ElevatedButton>(
        find.byKey(const Key('coupon-manual-apply')),
      );
      expect(after.onPressed, isNotNull);
    });

    testWidgets('whitespace alone is not a code', (tester) async {
      final (_, repo) = await _open(tester);

      await tester.enterText(
        find.byKey(const Key('coupon-manual-field')),
        '   ',
      );
      await tester.pumpAndSettle();

      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('coupon-manual-apply')),
      );
      expect(button.onPressed, isNull);
      expect(repo.calls.where((c) => c.startsWith('applyCoupon')), isEmpty);
    });
  });

  group('the applied coupon', () {
    testWidgets('shows Remove instead of Apply, and removing closes the sheet',
        (tester) async {
      final (container, repo) = await _open(tester, coupons: [_eligible]);

      // Apply it, then reopen — the list carries no "applied" flag of its own,
      // so the card has to be matched against the cart's applied_coupon_code.
      await _tap(tester, const Key('coupon-apply-HNHPQ2YWQJD0'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('coupon-apply-HNHPQ2YWQJD0')), findsNothing);
      expect(find.byKey(const Key('coupon-remove-HNHPQ2YWQJD0')), findsOneWidget);

      await _tap(tester, const Key('coupon-remove-HNHPQ2YWQJD0'));

      expect(_result!.removed, isTrue);
      expect(_result!.appliedCode, isNull);
      expect(repo.calls, contains('removeCoupon()'));
      expect(container.read(serverCartProvider).appliedCouponCode, isNull);
    });

    testWidgets('is matched case-insensitively', (tester) async {
      // The cart echoes back whatever the server stored, and the sheet
      // uppercases what it sends — so the two can differ in case for the same
      // coupon, and a case-sensitive match would offer Apply on the one already
      // applied.
      final lower = Coupon.fromJson(const {
        'code': 'hnhpq2ywqjd0',
        'value_formatted': '50%',
        'is_eligible': true,
      });
      await _open(tester, coupons: [lower]);

      await _tap(tester, const Key('coupon-apply-hnhpq2ywqjd0'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('coupon-remove-hnhpq2ywqjd0')),
        findsOneWidget,
      );
    });
  });
}

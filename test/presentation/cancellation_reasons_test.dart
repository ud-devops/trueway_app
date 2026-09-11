import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/presentation/providers/order_provider.dart';

/// The cancellation picker, against what the server will actually accept.
///
/// `CancelOrderRequest` validates `cancellation_reason` with
/// `Rule::in(OrderReason::customerVisibleValues('cancellation'))` — the **table**,
/// not the enum. `2026_07_11_000000_remove_unused_cancellation_reasons` deletes
/// five of those rows while deliberately keeping their enum constants and
/// translations, so historical orders still render a label.
///
/// That is the trap: the tokens still exist in the PHP enum and in the language
/// files, so they look valid from the source. They are not — offering one gives
/// the customer a dropdown entry that always fails with a 422.

void main() {
  /// Deleted from `ec_order_reasons` by the migration above. `customer-requested`
  /// is in the same list but was never offered by the app.
  const retired = {
    'out-of-stock',
    'payment-issues',
    'not-as-described',
    'unforeseen-circumstances',
    'customer-requested',
  };

  group('cancellation reasons', () {
    test('offers nothing the server has retired', () {
      final offered = orderCancellationReasons.map((r) => r.value).toSet();

      expect(
        offered.intersection(retired),
        isEmpty,
        reason: 'these tokens 422 — their rows were deleted, not just hidden',
      );
    });

    test('matches the set the backend guide verified live', () {
      expect(
        orderCancellationReasons.map((r) => r.value).toList(),
        const [
          'change-mind',
          'found-better-price',
          'shipping-delays',
          'incorrect-address',
          'other',
        ],
      );
    });

    // `other` is the only token whose description the server *requires*, and
    // the dialog branches on this constant to decide whether to demand one.
    test('includes "other", and it is the token needing a description', () {
      final values = orderCancellationReasons.map((r) => r.value);

      expect(values, contains(otherCancellationReason));
      expect(otherCancellationReason, 'other');
    });

    test('every entry has a label a customer can read', () {
      for (final reason in orderCancellationReasons) {
        expect(reason.value, isNotEmpty);
        expect(reason.label, isNotEmpty);
        // The label is ours, not the token — the API exposes no list to read
        // labels from, so a raw slug would leak into the UI.
        expect(reason.label, isNot(reason.value));
      }
    });

    test('has no duplicates', () {
      final values = orderCancellationReasons.map((r) => r.value).toList();
      expect(values.toSet(), hasLength(values.length));
    });
  });
}

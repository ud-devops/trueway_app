/// Calendar arithmetic for the order-history filter.
///
/// Every preset takes `now` rather than reading the clock, and this file is why:
/// a test that could not pin "now" would pass in the middle of a month and fail
/// on the 31st, in February, or on 1 January.
///
/// The rule that matters most is **inclusive whole days**. `created_at` arrives
/// as `2026-08-11T21:47:04+05:30`; an end bound of `DateTime(2026, 8, 11)` would
/// exclude that order from a range ending on the day it was placed, which is
/// the one answer no customer would accept.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/utils/date_range.dart';


void main() {
  group('DateRange spans whole days', () {
    test('an order at 21:47 belongs to the day it was placed', () {
      final august = DateRange(DateTime(2026, 8, 1), DateTime(2026, 8, 31));

      // The real newest order on the test account.
      expect(august.contains(DateTime(2026, 8, 11, 21, 47, 4)), isTrue);
      // Both edges, to the last microsecond.
      expect(august.contains(DateTime(2026, 8, 1)), isTrue);
      expect(
        august.contains(DateTime(2026, 8, 31, 23, 59, 59, 999, 999)),
        isTrue,
      );
      // ...and nothing outside them.
      expect(august.contains(DateTime(2026, 7, 31, 23, 59, 59)), isFalse);
      expect(august.contains(DateTime(2026, 9, 1)), isFalse);
    });

    test('the time of day the range was built from is discarded', () {
      final fromAfternoons = DateRange(
        DateTime(2026, 8, 1, 14, 30),
        DateTime(2026, 8, 31, 9, 15),
      );

      expect(fromAfternoons.start, DateTime(2026, 8, 1));
      expect(fromAfternoons.contains(DateTime(2026, 8, 1, 0, 0, 1)), isTrue);
      expect(fromAfternoons.contains(DateTime(2026, 8, 31, 23, 0)), isTrue);
    });

    test('reversed ends are swapped rather than yielding an empty range', () {
      final backwards = DateRange(DateTime(2026, 8, 31), DateTime(2026, 8, 1));

      expect(backwards.startDay, '2026-08-01');
      expect(backwards.endDay, '2026-08-31');
      expect(backwards.contains(DateTime(2026, 8, 15)), isTrue);
    });

    test('a single day is a range of one', () {
      final oneDay = DateRange(DateTime(2026, 8, 11), DateTime(2026, 8, 11));

      expect(oneDay.isSingleDay, isTrue);
      expect(oneDay.contains(DateTime(2026, 8, 11, 21, 47)), isTrue);
      expect(oneDay.contains(DateTime(2026, 8, 12)), isFalse);
    });

    test('isoDay is what the server will compare against, zero-padded', () {
      // `whereDate('created_at', '>=', $fromDate)` wants Y-m-d. `2026-8-1`
      // would not match.
      final r = DateRange(DateTime(2026, 1, 5), DateTime(2026, 12, 9));
      expect(r.startDay, '2026-01-05');
      expect(r.endDay, '2026-12-09');
    });
  });

  group('the period filter', () {
    // Years only now. It offered This month / Last month / This year / Last
    // year and a two-calendar custom range — five ways of asking a question
    // customers ask one way: "the order I placed some time in 2025".
    test('a year is that whole calendar year, local time', () {
      const f = OrderDateFilter.year(2025);

      expect(f.range!.startDay, '2025-01-01');
      expect(f.range!.endDay, '2025-12-31');
      expect(f.isActive, isTrue);
      expect(f.label, '2025');
    });

    test('a year contains an order placed late on its last day', () {
      // The reading a customer would accept, and the one a naive
      // `end = DateTime(y, 12, 31)` gets wrong for all but the first
      // microsecond of that day.
      const f = OrderDateFilter.year(2025);

      expect(f.range!.contains(DateTime(2025, 12, 31, 23, 59)), isTrue);
      expect(f.range!.contains(DateTime(2026, 1, 1)), isFalse);
      expect(f.range!.contains(DateTime(2024, 12, 31, 23, 59)), isFalse);
    });

    test('All filters nothing', () {
      expect(OrderDateFilter.all.range, isNull);
      expect(OrderDateFilter.all.isActive, isFalse);
      expect(OrderDateFilter.all.label, 'All');
    });

    test('two filters on the same year are equal', () {
      expect(const OrderDateFilter.year(2025), const OrderDateFilter.year(2025));
      expect(
        const OrderDateFilter.year(2025),
        isNot(const OrderDateFilter.year(2026)),
      );
      expect(const OrderDateFilter.year(2025), isNot(OrderDateFilter.all));
    });
  });

  group('the years offered', () {
    test('run from the first order to now, newest first', () {
      expect(
        orderFilterYears(firstYear: 2023, now: DateTime(2026, 9, 3)),
        [2026, 2025, 2024, 2023],
      );
    });

    test('one order this year offers one year, not a column of empties', () {
      // The whole reason this is built from the customer's own first order
      // rather than a constant.
      expect(
        orderFilterYears(firstYear: 2026, now: DateTime(2026, 9, 3)),
        [2026],
      );
    });

    test('a first order dated in the future does not empty the list', () {
      // Clock skew, or a seeded row. Trusting it would produce a descending
      // range that renders nothing at all.
      expect(
        orderFilterYears(firstYear: 2030, now: DateTime(2026, 9, 3)),
        [2026],
      );
    });
  });
}

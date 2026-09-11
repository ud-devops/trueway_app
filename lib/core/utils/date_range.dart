/// A closed span of days, and the presets an order list offers over it.
///
/// Pure Dart — no Flutter, no models, no providers — so the repository, the
/// notifier, a widget and a unit test can all share one definition of "this
/// month".
///
/// ## Days, not instants
///
/// Both ends are **inclusive whole days in local time**: [start] is that day's
/// midnight and [end] is the last microsecond of its day. An order placed at
/// 21:47 on the last day of a range belongs to it, which is the only reading a
/// customer would accept — and the reading a naive `end = DateTime(y, m, d)`
/// gets wrong for all but the first microsecond of the closing day.
///
/// Local time throughout, deliberately. `created_at` arrives as
/// `2026-08-11T21:47:04+05:30`, so `DateTime.parse(...).toLocal()` puts it on
/// the calendar day the customer remembers ordering.
library;

class DateRange {
  /// Both ends are snapped to whole local days, so a range built from two
  /// mid-afternoon instants still contains everything on both days.
  DateRange(DateTime start, DateTime end)
      : start = _startOfDay(start.isAfter(end) ? end : start),
        end = _endOfDay(start.isAfter(end) ? start : end);

  /// Local midnight of the first day.
  final DateTime start;

  /// The last microsecond of the last day.
  final DateTime end;

  static DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime _endOfDay(DateTime d) =>
      DateTime(d.year, d.month, d.day, 23, 59, 59, 999, 999);

  /// Whether [instant] falls inside, judged on the local calendar.
  bool contains(DateTime instant) {
    final local = instant.toLocal();
    return !local.isBefore(start) && !local.isAfter(end);
  }

  /// `YYYY-MM-DD`, which is what `whereDate` on the server will compare
  /// against once the filter moves there. Zero-padded by hand rather than via
  /// `intl` so this file stays dependency-free.
  static String isoDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String get startDay => isoDay(start);
  String get endDay => isoDay(end);

  bool get isSingleDay => startDay == endDay;

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'DateRange($startDay..$endDay)';
}

/// The earliest year the filter offers, when the real one cannot be found.
///
/// The shop's first order is July 2025 — verified live, the account's orders
/// span 2025-07 to 2026-09. It is only a fallback: the list is normally built
/// from the customer's **own** first order, so someone who joined last month is
/// offered one year rather than a column of empty ones. See
/// `firstOrderYearProvider`.
const int kOrdersFirstYear = 2025;

/// The period an order list is filtered to: everything, or one calendar year.
///
/// ## Why only years
///
/// It offered "This month", "Last month", "This year", "Last year" and a
/// two-calendar custom range. That is five ways of asking a question customers
/// ask one way — "the order I placed some time in 2025" — and the custom picker
/// in particular cost two calendars and four taps to express a span the list
/// could not search inside anyway.
///
/// Years are what Amazon offers and what the client asked for, and they have a
/// property the presets did not: the set is finite, self-explanatory, and every
/// entry is guaranteed to contain at least one order, because it is built from
/// the years the customer actually ordered in.
class OrderDateFilter {
  const OrderDateFilter._(this.year);

  /// No filter at all. [range] is null, which is what the whole stack keys off.
  static const OrderDateFilter all = OrderDateFilter._(null);

  /// One calendar year, local time.
  const OrderDateFilter.year(int year) : this._(year);

  /// The year being filtered to, or null for [all].
  final int? year;

  /// Null exactly when nothing is being filtered.
  DateRange? get range {
    final y = year;
    return y == null ? null : DateRange(DateTime(y), DateTime(y, 12, 31));
  }

  bool get isActive => year != null;

  /// What the chip says.
  String get label => year?.toString() ?? 'All';

  @override
  bool operator ==(Object other) =>
      other is OrderDateFilter && other.year == year;

  @override
  int get hashCode => year.hashCode;

  @override
  String toString() => 'OrderDateFilter($label)';
}

/// The years to offer, newest first, from [firstYear] up to [now]'s year.
///
/// Clamped rather than trusted: a first order dated in the future — a clock
/// skew, a seeded row — would otherwise produce an empty list or a descending
/// range that renders nothing.
List<int> orderFilterYears({required int firstYear, DateTime? now}) {
  final thisYear = (now ?? DateTime.now()).year;
  final from = firstYear > thisYear ? thisYear : firstYear;
  return [for (var y = thisYear; y >= from; y--) y];
}

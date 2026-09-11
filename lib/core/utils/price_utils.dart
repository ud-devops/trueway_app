import 'package:intl/intl.dart';

/// INR formatting. Prefer the server's pre-formatted string when available,
/// otherwise format locally with Indian digit grouping.
class PriceUtils {
  PriceUtils._();

  static final NumberFormat _inr = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 2,
  );

  static final NumberFormat _inrCompact = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );

  static String format(num value, {bool compact = false}) =>
      (compact && value == value.roundToDouble() ? _inrCompact : _inr)
          .format(value);

  /// Use the server label if present + non-empty, else format the raw number.
  static String resolve(String? formatted, num raw) {
    if (formatted != null && formatted.trim().isNotEmpty) return formatted;
    return format(raw);
  }

  static int discountPercent(num price, num original) {
    if (original <= 0 || price >= original) return 0;
    return (((original - price) / original) * 100).round();
  }
}

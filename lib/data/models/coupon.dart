/// A coupon the shop is advertising, from `GET /ecommerce/coupons`.
///
/// ## What this list is, and is not
///
/// Only the coupons an admin ticked as **visible at checkout**, further
/// filtered to ones currently active and not used up. It is not the set of
/// codes that work: a code sent over WhatsApp or SMS is absent from here and
/// still applies fine, which is why the sheet keeps a manual code field beside
/// the list. An empty list is an ordinary state, not a failure.
///
/// The list carries **no "applied" flag**. Which one is on the cart comes from
/// the cart's own `applied_coupon_code`, exactly as the web reads it from
/// `session('applied_coupon_code')` — see [ServerCart.appliedCouponCode].
///
/// ## Money is never computed here
///
/// Every amount arrives twice: a raw double carrying full float precision
/// (`coupon_discount_amount: 351.048`) and a `_formatted` string the server
/// rounded (`₹351.05`). Formatting the raw value in the app disagrees with the
/// web store by a paisa, so the display fields are the ones rendered and the
/// raw ones exist only for comparisons.
library;

import '../../core/utils/json_utils.dart';

/// `start_date` / `end_date` arrive as UTC ISO-8601
/// (`2026-06-09T18:30:00.000000Z`). Converted to local, because "valid till"
/// is read against the customer's own calendar — an IST expiry of 30 June
/// 00:00 is 29 June 18:30 UTC, and printing the UTC date loses a day.
DateTime? _date(Object? raw) {
  final text = asStringOrNull(raw);
  return text == null ? null : DateTime.tryParse(text)?.toLocal();
}

class Coupon {
  const Coupon({
    required this.code,
    this.title,
    this.description,
    this.value = 0,
    this.typeOption = '',
    this.valueFormatted = '',
    this.target = '',
    this.minOrderPrice,
    this.minOrderPriceFormatted,
    this.startDate,
    this.endDate,
    this.canUseWithPromotion = false,
    this.canUseWithFlashSale = false,
    this.isEligible,
    this.amountToAdd,
    this.amountToAddFormatted,
  });

  /// What gets sent to `POST /coupon/apply`, and the card's headline.
  final String code;

  /// Admin's internal name. Usually null on this catalogue.
  final String? title;

  /// Admin-written line, e.g. "Cupan Code". Often null.
  final String? description;

  /// The raw discount figure. [valueFormatted] is what gets rendered.
  final double value;

  /// `percentage`, `amount`, `same-price` or `shipping`.
  final String typeOption;

  /// Server-rendered, e.g. `50%` or `₹100.00`. Print this, never [value].
  final String valueFormatted;

  /// `all-orders`, `minimum-order-amount`, `specific-product`, …
  final String target;

  /// Null means no minimum at all — not zero.
  final double? minOrderPrice;
  final String? minOrderPriceFormatted;

  final DateTime? startDate;

  /// Null means no expiry.
  final DateTime? endDate;

  /// When false, the server refuses the coupon if the cart already carries that
  /// kind of discount.
  ///
  /// Deliberately **not** pre-checked in the app: whether a promotion or flash
  /// sale is actually in play is the server's answer, and guessing it wrong
  /// either hides a usable coupon or promises one that will be refused. The
  /// refusal message is shown instead.
  final bool canUseWithPromotion;
  final bool canUseWithFlashSale;

  /// Whether this cart can use the coupon — **or null for "not known"**.
  ///
  /// Three states, and the difference matters. The key is absent when no
  /// `cart_id` was sent, and present-but-null for a `cart_id` the server does
  /// not recognise (verified live: an unknown id returns 200 with the full list
  /// and `is_eligible: null`). Both mean the server did not judge, so the Apply
  /// button stays live and the server gets the final word — treating unknown as
  /// ineligible would grey out every coupon whenever the cart id went stale.
  final bool? isEligible;

  /// How much more the basket needs, when [isEligible] is false.
  final double? amountToAdd;

  /// Server-rounded form of [amountToAdd], for the "add ₹3,157.00 more" line.
  final String? amountToAddFormatted;

  /// The server judged this cart and said no.
  ///
  /// False for "not known", which is the whole point of the tri-state.
  bool get isKnownIneligible => isEligible == false;

  /// Safe to offer. True when the server said yes *and* when it did not judge.
  bool get canApply => isEligible != false;

  /// One line under the headline, in the order the web falls back.
  ///
  /// `description` is the admin's own sentence and wins; `title` is the
  /// internal name and is the next best thing; the formatted value is a last
  /// resort so the card is never blank.
  String get subtitle {
    final d = description?.trim() ?? '';
    if (d.isNotEmpty) return d;
    final t = title?.trim() ?? '';
    if (t.isNotEmpty) return t;
    return valueFormatted;
  }

  /// Why the button is off, or null when it is on.
  ///
  /// The server's own shortfall figure when it gave one — it is computed
  /// against the live cart and matches the sentence `apply` would return.
  String? get blockedReason {
    if (!isKnownIneligible) return null;
    final more = amountToAddFormatted?.trim() ?? '';
    if (more.isNotEmpty) return 'Add $more more to use this';
    final min = minOrderPriceFormatted?.trim() ?? '';
    if (min.isNotEmpty) return 'Minimum order $min';
    return 'Not applicable to this basket';
  }

  factory Coupon.fromJson(Map<String, dynamic> json) => Coupon(
        code: asString(json['code']).trim(),
        title: asStringOrNull(json['title']),
        description: asStringOrNull(json['description']),
        value: asDouble(json['value']),
        typeOption: asString(json['type_option']),
        valueFormatted: asString(json['value_formatted']),
        target: asString(json['target']),
        minOrderPrice: asDoubleOrNull(json['min_order_price']),
        minOrderPriceFormatted: asStringOrNull(json['min_order_price_formatted']),
        startDate: _date(json['start_date']),
        endDate: _date(json['end_date']),
        canUseWithPromotion: asBool(json['can_use_with_promotion']),
        canUseWithFlashSale: asBool(json['can_use_with_flash_sale']),
        // `asBool` would fold both "absent" and "null" into false, which is the
        // one reading that must not happen — see [isEligible].
        isEligible: json['is_eligible'] is bool ? json['is_eligible'] as bool : null,
        amountToAdd: asDoubleOrNull(json['amount_to_add']),
        amountToAddFormatted: asStringOrNull(json['amount_to_add_formatted']),
      );

  /// The `data` array of `GET /coupons`.
  ///
  /// Codeless rows are dropped rather than rendered: the code is the only thing
  /// a card can act on, and a button that posts `""` would just draw a refusal.
  static List<Coupon> listFrom(Object? data) {
    if (data is! List) return const [];
    return [
      for (final row in data)
        if (row is Map<String, dynamic>) Coupon.fromJson(row),
    ].where((c) => c.code.isNotEmpty).toList();
  }

  @override
  bool operator ==(Object other) => other is Coupon && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'Coupon($code, $valueFormatted, eligible: $isEligible)';
}

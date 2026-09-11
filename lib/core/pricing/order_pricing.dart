/// The order total, as the server reports it.
///
/// This used to be the app's own arithmetic — a hardcoded coupon table, a
/// ₹499/₹40 delivery rule that exists nowhere in the backend, and GST derived
/// with `subtotal - subtotal / 1.05`. Every one of those was a second answer to
/// a question the server already answers, and each was wrong in a different
/// way: fictional discounts, a free-shipping promise on orders that cost ₹330
/// to ship, and a tax figure that ignored the backend applying discounts
/// pre-tax.
///
/// [OrderSummary.fromServerCart] now reads all of it off the cart payload. The
/// only figure not in that payload is delivery, which is quoted per destination
/// by the logistics endpoints — and is null, not guessed, until one exists.
library;

import '../../data/models/server_cart.dart';

/// Immutable breakdown of what the customer pays.
class OrderSummary {
  const OrderSummary({
    required this.itemTotal,
    required this.productDiscount,
    required this.subtotal,
    required this.couponDiscount,
    required this.delivery,
    required this.gstIncluded,
    required this.orderTotal,
    required this.payable,
    this.couponCode,
  });

  /// Goods at the **selling** price, before promotions and coupons — the
  /// cart's `raw_sub_total`.
  ///
  /// **Not MRP**, whatever its name suggests. `Cart::rawSubTotal()` is
  /// `Σ qty × cartItem->price`, and the price a line carries is the one being
  /// charged. Verified live on 2026-09-02: product 129 lists at ₹313.95 MRP and
  /// ₹208.95 selling, and a cart holding one of them reports
  /// `raw_sub_total: 199` — the selling price ex-tax, with no trace of the MRP.
  final double itemTotal;

  /// The **promotions module's** discount — `promotion_discount_amount`.
  ///
  /// It is NOT the saving baked into the product's price. A product marked down
  /// from ₹313.95 to ₹208.95 reports `promotion_discount_amount: 0`, because
  /// the markdown is already inside the price the cart charges; the promotions
  /// plugin is a separate mechanism the shop is not currently using.
  ///
  /// ## Why the app cannot show the website's "Saved ₹114"
  ///
  /// The web cart prints MRP − selling price. Reaching that needs the MRP **per
  /// line**, and the cart payload does not carry it: `CartItemResource` does
  /// emit `original_price`, but it reads `options.original_price`, and nothing
  /// in the cart write path ever sets that option — live, every line comes back
  /// `original_price: null` / `"₹0.00"`.
  ///
  /// It must not be reassembled here from the catalogue either. The catalogue's
  /// `original_price` is tax-**inclusive** (₹313.95) while the cart is
  /// tax-exclusive (₹199), so subtracting one from the other invents a saving
  /// that matches neither figure the customer can see. The fix is a backend
  /// one — see docs/BACKEND_BUGS.md.
  final double productDiscount;

  /// Goods value after discounts and **before** tax — the cart's
  /// `discounted_sub_total`.
  ///
  /// The coupon is already off it. It is a bill *input*, never a total: adding
  /// tax to it gives [orderTotal], and subtracting the coupon from it again is
  /// the bug this class was written to end.
  final double subtotal;

  final double couponDiscount;

  /// Delivery charge, or null when it is **not yet knowable**.
  ///
  /// Shipping is quoted per destination by Shiprocket — the same
  /// `handle_shipping_fee` path the web checkout uses — so it cannot exist
  /// until a delivery pincode is known. In the cart, before any address has
  /// been chosen, this is null and the UI must say the charge is calculated at
  /// checkout rather than print a number.
  ///
  /// It is never computed here. It arrives from
  /// `POST /logistics/check-serviceability` as `CourierOption.billedPrice` of
  /// the courier the customer selected — `freight_charge + coverage_charges +
  /// other_charges`, plus `cod_charges` on a COD quote.
  ///
  /// Two things it is **not**. It is not the courier row's `rate`: `rate` omits
  /// coverage and other charges, so quoting it under-bills every basket past
  /// the insurance threshold by exactly the coverage step. And it does not come
  /// from `/check-pincode`, which is a different service
  /// (`PinCodeDeliveryService`, a different pickup postcode, one courier already
  /// chosen for you) and is not what checkout prices from.
  final double? delivery;

  /// GST the server **adds on top** of [subtotal], straight from the cart's
  /// `discounted_tax_amount` (recomputed on the post-discount base).
  ///
  /// **The name is a lie and the field is not.** Nothing about this figure is
  /// "included" in anything: this backend is tax-*exclusive*, so
  /// `discounted_sub_total + discounted_tax_amount = order_total` — verified
  /// live on order 282, 899.00 + 44.95 = 943.95. [subtotal] does not contain
  /// it; [orderTotal] does.
  ///
  /// The name survives only because renaming it reaches two screens this file
  /// does not own (`cart_screen.dart` and `checkout_screen.dart` both render it
  /// as a plain "GST" row, which is the correct label for an added tax). See
  /// `followUps` for the rename.
  ///
  /// The rule for any caller: a UI that labels this row "incl." tells the
  /// customer the rows above already contain it, and the bill then visibly
  /// fails to sum. It is an added row, and it must read as one.
  final double gstIncluded;

  /// What the goods cost, **verbatim** from the cart's `order_total`.
  ///
  /// The server's own answer to "what is this basket worth", already
  /// post-discount and already taxed. Carried, never recomputed: every attempt
  /// to re-derive it client-side has been wrong, most recently
  /// `subtotal - couponDiscount`, which took the coupon off a base that had
  /// already had it taken off and dropped the GST entirely.
  final double orderTotal;

  /// Amount due, or null while [delivery] is unknown.
  final double? payable;

  /// The code the **server** reports as applied, from `applied_coupon_code`.
  /// The app no longer decides what a coupon is worth, or whether it exists.
  final String? couponCode;

  double get totalSavings => productDiscount + couponDiscount;

  /// True only once a destination has been priced.
  bool get isDeliveryKnown => delivery != null;

  /// A figure that is always safe to render: the amount due when delivery is
  /// known, the full cost of the goods otherwise.
  ///
  /// **Nothing is derived here.** It is one of two server figures — `payable`
  /// (which is `order_total` plus the courier's quote) or [orderTotal] itself.
  ///
  /// It used to be `payable ?? (subtotal - couponDiscount)`, and that single
  /// expression was wrong twice: [subtotal] is `discounted_sub_total`, which is
  /// already net of the coupon, so the discount came off a second time; and it
  /// is pre-tax, so the GST the server adds on top never appeared. A signed-out
  /// customer never left that branch — quoting shipping needs the address book,
  /// which needs a bearer token — so the headline number on the cart bar, the
  /// bold row of the cart bill and checkout's pre-shipping total all read
  /// ₹899.00 for a basket the server prices at ₹943.95.
  ///
  /// Callers must pair it with [isDeliveryKnown] to pick the label — showing
  /// this as "To pay" before shipping is quoted would understate the total.
  double get payableOrSubtotal => payable ?? orderTotal;

  /// Free delivery exists **only** when a coupon grants it.
  ///
  /// The backend has no order-value threshold: `CouponController` returns
  /// `is_free_shipping` on the coupon result, and `CheckoutController` zeroes
  /// the shipping amount when that flag is set. Nothing else makes delivery
  /// free.
  ///
  /// This app previously claimed "free delivery over ₹499" with a ₹40 flat fee
  /// below it. Neither figure exists anywhere in the backend — both were
  /// invented client-side, and the cart was promising free delivery on orders
  /// the courier actually charges ₹330 to ship.
  bool get hasFreeDelivery => delivery == 0;

  /// Builds the summary from a cart the server just serialized.
  ///
  /// **Nothing here is calculated.** Every figure is read off the cart payload:
  /// the backend applies discounts to the pre-tax base and re-derives GST on
  /// the discounted value, which the old client-side formula
  /// (`subtotal - subtotal / (1 + gstRate)`) does not reproduce. Two answers to
  /// the same question, and ours was the wrong one.
  ///
  /// [delivery] is the sole exception, and it still is not computed: shipping
  /// is quoted per destination by the logistics endpoints, so it is null in the
  /// cart where no address exists yet and the UI must say "calculated at
  /// checkout" rather than print a number.
  factory OrderSummary.fromServerCart(ServerCart cart, {double? delivery}) {
    final subtotal = cart.discountedSubTotal.amount;
    final couponDiscount = cart.couponDiscount.amount;
    final promotionDiscount = cart.promotionDiscount.amount;

    return OrderSummary(
      // `raw_sub_total` is the pre-discount, pre-tax goods value.
      itemTotal: cart.rawSubTotal.amount,
      productDiscount: promotionDiscount,
      subtotal: subtotal,
      couponDiscount: couponDiscount,
      delivery: delivery,
      gstIncluded: cart.discountedTax.amount,
      // `order_total` is what the customer pays for goods, carried as-is so no
      // screen has to reassemble it out of the rows above.
      orderTotal: cart.orderTotal.amount,
      // Delivery is added on top only once a courier has quoted it.
      payable: delivery == null ? null : cart.orderTotal.amount + delivery,
      couponCode: cart.appliedCouponCode,
    );
  }

  /// Empty-cart summary. Delivery is 0 because there is nothing to ship.
  static const OrderSummary empty = OrderSummary(
    itemTotal: 0,
    productDiscount: 0,
    subtotal: 0,
    couponDiscount: 0,
    delivery: 0,
    gstIncluded: 0,
    orderTotal: 0,
    payable: 0,
  );
}

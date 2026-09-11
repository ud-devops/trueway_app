import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_icons.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/pricing/order_pricing.dart';
import '../../../core/utils/price_utils.dart';
import '../../../core/design_system/theme_context.dart';
import '../../providers/server_cart_provider.dart';
import '../../../data/models/server_cart.dart';
import '../../providers/checkout_provider.dart';
import '../../providers/delivery_location_provider.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/quantity_stepper.dart';
import '../../widgets/state_views.dart';
import '../../widgets/delivery_location_bar.dart';
import '../../widgets/bill_details.dart';
import '../../widgets/surfaces.dart';
import '../../widgets/app_message.dart';
import '../../widgets/coupon_sheet.dart';
import '../../widgets/tax_information_sheet.dart';

class CartScreen extends ConsumerStatefulWidget {
  const CartScreen({super.key, this.showBack = true});
  final bool showBack;

  @override
  ConsumerState<CartScreen> createState() => _CartScreenState();
}

/// Both text inputs this screen used to own have moved into sheets of their
/// own — [CouponSheet] and [TaxInformationSheet] — so there is no controller
/// here any more. The reason the old one lived on the State still applies to
/// them: `showDialog`'s future completes the moment the route is popped, while
/// the exit animation is still rendering the TextField, so a controller
/// disposed at that point throws "used after dispose". Each sheet is a
/// StatefulWidget that outlives its own animation.
class _CartScreenState extends ConsumerState<CartScreen> {
  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(serverCartProvider);
    // The courier charge the customer picked in [DeliveryLocationBar], which is
    // the same `shippingChargeProvider` checkout reads — so the two screens
    // cannot print two totals for one order, and neither of them recomputes a
    // shipping figure of its own.
    //
    // **Null is the normal opening state**, and it means "no delivery option
    // chosen" — not zero and not free. It also covers signed out (the address
    // book is bearer-only, so there is no destination to quote for), no address
    // yet, a basket not yet weighed, and a quote that is loading, failed or came
    // back undeliverable. Everything below keys off it: the bill's Shipping row
    // says which of those it is, the bold row stays "Subtotal" rather than "To
    // pay", and the bar's caption says the figure excludes shipping. The one
    // thing none of them may do is render it as ₹0 or FREE — free delivery is a
    // real, separate state (`delivery == 0`, granted by a coupon).
    final delivery = ref.watch(cartDeliveryChargeProvider);
    final summary = ref.watch(checkoutSummaryProvider(delivery));
    final notice = _notice(cart);

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        automaticallyImplyLeading: widget.showBack,
        title: const Text('Cart'),
        actions: [
          if (!cart.isEmpty)
            TextButton(
              // `clear()` removes lines one at a time and stops on the first
              // refusal, returning the server's reason — so without this the
              // customer could tap Clear, see some items go and others stay,
              // and be told nothing about why.
              onPressed: cart.busy ? null : _clear,
              child: const Text('Clear'),
            ),
        ],
      ),
      // Order matters. `contentsUnknown` means a mutation failed *and* every
      // read since failed too, so `cart` is null and `isEmpty` is true — the
      // empty branch would confidently tell a customer whose basket we simply
      // cannot see that they have nothing in it, which is the one thing we know
      // is not established.
      body: cart.contentsUnknown
          ? _unknownView(cart)
          : cart.isEmpty
          ? EmptyView(
              title: 'Your cart is empty',
              subtitle: 'Add fresh organic products to get started',
              icon: AppIcons.cart,
              action: ElevatedButton(
                onPressed: () => context.go('/'),
                child: const Text('Start shopping'),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    children: [
                      if (notice != null) ...[notice, AppSpacing.vSm],
                      ...cart.items.map((it) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            // This row's own line. `cart.busy` here faded
                            // every stepper in the basket to 55% each time any
                            // one of them was tapped.
                            child: _CartLine(
                              item: it,
                              busy: cart.isBusyLine(it.lineId),
                            ),
                          ),),
                      AppSpacing.vXs,
                      const DeliveryLocationBar(),
                      AppSpacing.vSm,
                      _couponRow(),
                      AppSpacing.vSm,
                      _gstinRow(),
                      AppSpacing.vSm,
                      _billCard(summary),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                _checkoutBar(context, cart, summary),
              ],
            ),
    );
  }

  // ---- What the server did to the cart ----------------------------------
  //
  // Every mutation route on this backend can destroy the whole cart when it
  // refuses: `Cart::restore()` loads the row by deleting it, and each error path
  // returns before `store()` writes it back. So a customer tapping "+" on a line
  // already at max stock gets HTTP 200 `{"error": true, ...}` and an emptied
  // basket. `ServerCartNotifier` replays its mirror into the same cart id, but a
  // line that has gone out of stock in the meantime does not come back.
  //
  // None of that used to reach the screen. `error`, `recoveryMessage`,
  // `itemsLost` and `contentsUnknown` were all rendered by exactly nothing, and
  // the return value of every stepper and remove call was discarded — so the
  // customer watched an item vanish with no explanation at all. These two
  // builders and `_report` below are the whole of the fix.

  Future<void> _clear() async {
    final failure = await ref.read(serverCartProvider.notifier).clear();
    if (!mounted) return;
    ref.read(checkoutProvider.notifier).reset();
    if (failure != null && failure.isNotEmpty) context.showAlertSnack(failure);
  }

  /// Persistent banner for a change the customer did not make.
  ///
  /// Not a SnackBar: a wiped-and-rebuilt basket is a standing fact about what is
  /// on screen, and it has to still be there when they look back at the total.
  /// The transient snack from `_CartLine._report` is in addition to this, not
  /// instead of it.
  ///
  /// Returns null when the last action was clean, which is the common case.
  Widget? _notice(ServerCartState cart) {
    final recovery = cart.recoveryMessage?.trim() ?? '';

    // A plain refusal is deliberately NOT shown here.
    //
    // The banner is for a change the customer did not make and cannot see —
    // a basket that was wiped and rebuilt, an item that did not come back. That
    // is a standing fact about what is on screen and has to still be there when
    // they look at the total.
    //
    // A refused action is neither of those. It is transient, it belongs beside
    // the control that was refused, and the caller already reports it as a
    // toast. Rendering it here as well meant a "+" tapped on the *home grid*
    // surfaced as a red panel at the top of the cart, quoting the server's
    // "…of Trueway Farms Organic Desi Khand Brown (khandsari) at a time.
    // Please adjust the quantity and try again." — two screens from the tap,
    // and still there after the customer had understood and moved on.
    if (recovery.isEmpty && !cart.itemsLost) return null;

    // Losing items is the more serious of the two, and it survives a refusal
    // the server considered routine — so it, not the rebuild, sets the tone.
    final lost = cart.itemsLost;
    final tone = lost ? AppColors.error : AppColors.accentDark;
    final heading =
        lost ? 'Some items could not be put back' : 'We rebuilt your basket';

    final lines = [
      if (recovery.isNotEmpty)
        recovery
      else
        // lossMessage is null only when nothing was lost, so this is defensive;
        // an empty banner would be worse than a general sentence.
        'Your basket was rebuilt and is short of at least one item.',
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: AppRadius.rMd,
        border: Border.all(color: tone.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.info, size: 18, color: tone),
          AppSpacing.hXs,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(heading, style: context.text.title.copyWith(color: tone)),
                for (final line in lines) ...[
                  AppSpacing.vXs,
                  // The server's own wording. It names the actual constraint —
                  // "Maximum quantity is 93!", "Product X is out of stock!" —
                  // and paraphrasing loses the only useful part.
                  Text(line, style: context.text.bodySm),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Shown instead of the empty view when the contents are genuinely unknowable.
  ///
  /// A mutation failed and every read since has failed too, so there is no cart
  /// to render and no total that could be honest. The one thing we must not do
  /// is what the code did before: fall through to "Your cart is empty", which
  /// reads as a statement of fact about a basket nobody has managed to look at.
  Widget _unknownView(ServerCartState cart) => EmptyView(
        title: "We couldn't check your cart",
        subtitle: cart.error?.message ??
            'Your items may still be there — this device just could not reach '
                'the server to confirm.',
        icon: AppIcons.cloudOff,
        action: ElevatedButton(
          onPressed: cart.busy
              ? null
              : () => ref.read(serverCartProvider.notifier).refresh(),
          child: const Text('Try again'),
        ),
      );

  // ---- Coupon -----------------------------------------------------------
  //
  // The applied code comes from the cart's `applied_coupon_code` and the
  // discount from its `coupon_discount_amount`. The app no longer holds a
  // coupon table, does not decide what a code is worth, and cannot tell the
  // customer a code is invalid — only the server can, and it says so in its
  // own words.
  //
  // The row used to open a bare text box, so a customer could only use a code
  // they already had. `GET /coupons` now lists what the shop is advertising,
  // with server-computed eligibility, and [CouponSheet] shows both that list
  // and the field — a code sent over WhatsApp is not in the list and still
  // works.
  Widget _couponRow() {
    final cartState = ref.watch(serverCartProvider);
    final code = cartState.appliedCouponCode;
    final applied = (code ?? '').isNotEmpty;

    return _actionCard(
      icon: AppIcons.tag,
      iconColor: AppColors.accentDark,
      iconBg: context.colors.accentSoft,
      title: applied ? 'Coupon "$code" applied' : 'Apply Coupon',
      subtitle: applied
          ? 'Discount applied to this order'
          : 'View offers or enter a promo code',
      trailing: applied
          ? TextButton(
              onPressed: cartState.busy ? null : _removeCoupon,
              child: const Text('Remove'),
            )
          : Icon(AppIcons.caretRight, color: context.colors.faint, size: 16),
      // Open even with one applied: only one coupon fits on a cart, and
      // applying a second replaces the first — so switching offers should not
      // mean removing one first.
      onTap: cartState.busy ? null : _openCouponSheet,
    );
  }

  Future<void> _openCouponSheet() async {
    final result = await showCouponSheet(context);
    if (result == null || !mounted) return;

    // The sheet only closes on success — a refusal is painted inside it, where
    // the customer is still looking at the other codes. So there is nothing to
    // report here but the good news.
    if (result.removed) {
      context.showInfoSnack('Coupon removed');
    } else {
      context.showSuccessSnack('Coupon "${result.appliedCode}" applied');
    }
  }

  Future<void> _removeCoupon() async {
    final failure = await ref.read(serverCartProvider.notifier).removeCoupon();
    if (!mounted) return;
    if (failure != null) context.showAlertSnack(failure);
  }

  // ---- GST invoice ------------------------------------------------------
  //
  // Four fields, not one. The row used to collect a bare GSTIN and hand it to
  // `CheckoutState.gstin`, which **no request ever read** — it validated, it
  // rendered here, and it vanished at checkout. `ec_order_tax_information`
  // needs `company_name`, `company_address`, `company_tax_code` and
  // `company_email` together, so the sheet asks for the block the order can
  // actually be invoiced against.
  Widget _gstinRow() {
    final tax = ref.watch(checkoutProvider).taxInformation;
    return _actionCard(
      icon: AppIcons.percent,
      iconColor: AppColors.teal,
      iconBg: context.colors.tealSoft,
      title: tax != null ? 'GSTIN: ${tax.companyTaxCode}' : 'Add GST details',
      subtitle: tax != null
          ? tax.companyName
          : 'Get a GST invoice in your company’s name',
      trailing: tax != null
          ? TextButton(
              onPressed: () =>
                  ref.read(checkoutProvider.notifier).removeTaxInformation(),
              child: const Text('Remove'),
            )
          : Icon(AppIcons.caretRight, color: context.colors.faint, size: 16),
      // Editable once set, rather than remove-and-retype: correcting a typo in
      // a company address should not mean re-entering all four fields.
      onTap: _openGstinSheet,
    );
  }

  Future<void> _openGstinSheet() async {
    final existing = ref.read(checkoutProvider).taxInformation;
    final result = await showTaxInformationSheet(context, initial: existing);
    if (result == null || !mounted) return;

    final notifier = ref.read(checkoutProvider.notifier);
    if (result.removed) {
      notifier.removeTaxInformation();
      context.showInfoSnack('GST details removed');
      return;
    }

    // The sheet only returns a violation-free block, so a failure here would
    // mean the two rule sets had drifted — report it rather than swallow it.
    final failure = notifier.setTaxInformation(result.information!);
    if (!mounted) return;
    if (failure != null) {
      context.showAlertSnack(failure);
    } else {
      context.showSuccessSnack('GST details saved');
    }
  }

  Widget _actionCard({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required String subtitle,
    required Widget trailing,
    VoidCallback? onTap,
  }) {
    return AppCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: iconBg, borderRadius: AppRadius.rMd),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          AppSpacing.hSm,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.title),
                Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.caption),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }

  // ---- Bill -------------------------------------------------------------
  /// The same card checkout and the placed order show.
  ///
  /// Composed once in [OrderBillCard] rather than three times here: the basket
  /// and checkout are one tap apart, and they used to describe the same
  /// discount two different ways — folded into the item row behind a "Saved"
  /// chip on one, a line of its own on the other. Nothing on either screen told
  /// the customer that was a styling choice rather than a different charge.
  ///
  /// The row **order** is what makes a bill add up, and it is verified against
  /// the live payload: `raw_sub_total - promotion - coupon =
  /// discounted_sub_total`, and `discounted_sub_total + discounted_tax =
  /// order_total`, both exactly. Nothing is computed here or in the card —
  /// every figure is a field the server already sent.
  Widget _billCard(OrderSummary summary) => OrderBillCard(
        terms: BillTerms(
          itemTotal: PriceUtils.format(summary.itemTotal),
          discount: summary.totalSavings > 0
              ? PriceUtils.format(summary.totalSavings)
              : null,
          couponCode: summary.couponCode,
          // No quote yet, so no number. Which of the several reasons that is
          // comes from `cartDeliveryStatusLabel`, so this row says the same
          // thing as the shipping card above it — it used to read "At checkout"
          // even for a pincode nothing delivers to.
          shipping: summary.isDeliveryKnown
              ? (summary.hasFreeDelivery
                  ? 'FREE'
                  : PriceUtils.format(summary.delivery!))
              : cartDeliveryStatusLabel(ref),
          shippingMuted: !summary.isDeliveryKnown,
          shippingFree: summary.hasFreeDelivery,
          // Not "GST (incl.)". This backend ADDS tax on top —
          // `discounted_sub_total` + `discounted_tax_amount` = `order_total` —
          // so calling it included told the customer the tax was already inside
          // the rows above, and the bill they read said 1438.40 = 1438.40 while
          // the server charged 1510.32.
          tax: '+ ${PriceUtils.format(summary.gstIncluded)}',
          // "Subtotal" rather than "To pay" while delivery is unknown, so the
          // figure is not read as the final amount due.
          totalLabel: summary.isDeliveryKnown ? 'To pay' : 'Subtotal',
          total: PriceUtils.format(summary.payableOrSubtotal),
          // Always, zero included — see [BillTerms.savings].
          savings: PriceUtils.format(summary.totalSavings),
          // Free delivery is a real saving and the customer can see it in the
          // Shipping row, but it is NOT inside `totalSavings` — that is
          // `productDiscount + couponDiscount`, and there is no would-have-been
          // courier quote to subtract from. Named here rather than added to the
          // figure: adding an amount the server never quoted is how a bill
          // stops reconciling.
          savingsNote: summary.totalSavings > 0 && summary.hasFreeDelivery
              ? 'Plus free delivery on this order'
              : null,
        ),
      );

  Widget _checkoutBar(BuildContext context, ServerCartState cart, OrderSummary summary) {
    return BottomActionBar(
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                PriceUtils.format(summary.payableOrSubtotal),
                style: context.text.price,
              ),
              Text(
                // "Total" would be a claim we cannot back before shipping is
                // quoted, so the bar names what the figure actually is.
                summary.isDeliveryKnown
                    ? 'Total (${cart.count} item${cart.count == 1 ? '' : 's'})'
                    : '${cart.count} item${cart.count == 1 ? '' : 's'} · excl. shipping',
                style: context.text.caption,
              ),
            ],
          ),
          AppSpacing.hMd,
          Expanded(
            child: ElevatedButton(
              // Says which cart it is opening, every time.
              //
              // Checkout spends whichever cart [checkoutCartProvider] names,
              // and a "Buy now" sets that to the throwaway one. Something has
              // to set it back, and doing it here — at the moment of
              // navigation, in the button that means "check out my basket" —
              // is the only version that cannot be missed.
              //
              // It used to be reset from lifecycle callbacks instead, and both
              // failed. This screen's `initState` runs **once**: the tabs live
              // in an `IndexedStack` (main_navigation_screen.dart), so
              // returning to the Cart tab rebuilds nothing. And the checkout
              // screen's `dispose` wrote to a provider during teardown. A
              // customer who bought one product and then opened a basket of
              // nine was shown the one.
              onPressed: () {
                ref.read(checkoutCartProvider.notifier).state =
                    CheckoutCart.basket;
                context.push('/checkout');
              },
              child: const Text('Checkout'),
            ),
          ),
        ],
      ),
    );
  }

}

class _CartLine extends ConsumerWidget {
  const _CartLine({required this.item, this.busy = false});

  final ServerCartItem item;

  /// A cart mutation is already in flight. The stepper is disabled rather than
  /// allowed to queue a second write: concurrent writes are how this backend
  /// loses a cart.
  final bool busy;

  /// Reports a refusal the customer caused by tapping something.
  ///
  /// `increment`, `decrement` and `remove` all return the server's own sentence
  /// on refusal and null on success, and every one of those return values used
  /// to be dropped on the floor — so "Maximum quantity is 93!" arrived as a
  /// stepper that simply did not move, and a refusal that wiped and rebuilt the
  /// basket arrived as an item quietly disappearing. Same treatment the coupon
  /// dialog already gave its failures.
  static Future<void> _report(
    BuildContext context,
    Future<String?> action,
  ) async {
    final message = await action;
    if (message == null || message.isEmpty || !context.mounted) return;
    context.showAlertSnack(message);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.read(serverCartProvider.notifier);
    // Prices come off the line the server serialized; nothing is recomputed.
    //
    // `price` is the per-unit price **excluding** tax (₹899.00), while the
    // catalogue and the product page show ₹943.95 — the same product with the
    // GST this backend adds on top. Rendering `price` here made the price look
    // like it dropped on the way into the basket, and then the total contradicted
    // it. So the line shows the gross unit price, which is the server's `price`
    // plus the server's own per-unit `tax_price` (899.00 + 44.95 = 943.95,
    // exactly the catalogue figure). No rate is applied to anything — that
    // addition is the same one the server publishes as `total_price`.
    //
    // The struck-through `original_price` went with it. It is null on every
    // product in this catalogue (the server only fills it from a cart option
    // nothing sets), and it is an **ex-tax** figure — so the moment it did
    // populate it would have rendered a lower "was" price next to a gross "now"
    // price. There is no server-side gross original to compare against, and
    // deriving one from `tax_rate` would be exactly the client-side tax
    // arithmetic that caused this bug in the first place.
    final grossUnit = item.unitPrice.amount + item.unitTax.amount;
    return AppCard(
      elevated: true,
      padding: const EdgeInsets.all(10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: context.colors.surfaceAlt, borderRadius: AppRadius.rMd),
            clipBehavior: Clip.antiAlias,
            child: AppNetworkImage(url: item.imageUrl, fit: BoxFit.cover),
          ),
          AppSpacing.hSm,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(item.name,
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.title,),
                    ),
                    InkWell(
                      // `lineId`, never a product id: for a variable product
                      // they differ, and removing something not in the cart
                      // 404s *and wipes the whole cart*.
                      onTap: busy
                          ? null
                          : () => _report(context, cart.remove(item.lineId)),
                      child: Icon(AppIcons.trash, size: 18, color: context.colors.faint),
                    ),
                  ],
                ),
                AppSpacing.vXs,
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        children: [
                          Text(PriceUtils.format(grossUnit),
                              style: context.text.price.copyWith(color: context.colors.primaryDark),),
                          // The line's own total, in the server's wording, so
                          // multiple units are still checkable against the bill
                          // without anyone multiplying anything.
                          if (item.quantity > 1)
                            Text('${item.lineTotal.display} total',
                                style: context.text.caption,),
                          // Says why the "+" stopped. A disabled control with
                          // no explanation reads as a broken one, and the
                          // customer's next move is to tap it again.
                          if (item.isAtMaximum)
                            Text(
                              'Max ${item.maxCartQuantity} per order',
                              style: context.text.caption
                                  .copyWith(color: context.colors.primaryDark),
                            ),
                        ],
                      ),
                    ),
                    // Capped at the server's own limits rather than left open
                    // and corrected by a refusal. A refused increment does not
                    // just fail here: `Cart::restore()` has already deleted the
                    // stored row by the time the over-quantity branch returns,
                    // so the whole basket goes with it and the app has to
                    // rebuild from its mirror in front of the customer.
                    // See `docs/BACKEND_BUGS.md` finding 0.
                    QuantityStepper(
                      quantity: item.quantity,
                      dense: true,
                      // This row's own write, so the spinner appears on the
                      // line the customer tapped and nowhere else.
                      busy: busy,
                      // At the cap the button stays live and *says* why, rather
                      // than going grey. A dead control reads as broken and the
                      // customer's next move is to tap it again.
                      //
                      // The sentence is built from `max_cart_quantity` and NOT
                      // forwarded from the server, because the server's own
                      // wording is wrong here: `POST /cart` refuses with
                      // "Maximum quantity is 85558!" — that is `quantity`, the
                      // stock level, not the cap of 3 the same payload states.
                      // Showing it would tell the customer they may buy 85,558
                      // of something limited to 3.
                      //
                      // Nothing is sent either way. `PUT /cart/{id}` does not
                      // enforce the cap at all (qty 50 is accepted on a product
                      // capped at 3), so a request here would not produce a
                      // message — it would simply put an illegal quantity in
                      // the basket. Both are recorded in
                      // `docs/BACKEND_BUGS.md` finding 15.
                      onIncrement: item.canIncrement
                              ? () => _report(
                                    context,
                                    cart.increment(item.lineId),
                                  )
                              : () => context.showAlertSnack(
                                    'Sorry, you can only order a maximum of '
                                    '${item.maxCartQuantity} units.',
                                  ),
                      // At the minimum, one more "−" **removes the line**.
                      //
                      // It used to refuse and point at the bin icon instead —
                      // which is a screen telling the customer to finish, with
                      // a different control, a gesture they had already
                      // started. Stepping to zero means "take this out", and
                      // that is the same call the bin makes.
                      //
                      // Nothing illegal is sent: `remove` is a DELETE, not a
                      // quantity update, so a pack-of-two product — which
                      // cannot legally step to one — still comes out in one
                      // tap.
                      onDecrement: item.canDecrement
                              ? () => _report(
                                    context,
                                    cart.decrement(item.lineId),
                                  )
                              : () => _report(
                                    context,
                                    cart.remove(item.lineId),
                                  ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_icons.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../core/pricing/order_pricing.dart';
import '../../../core/utils/price_utils.dart';
import '../../../core/validation/address_rules.dart';
import '../../../data/repositories/checkout_repository.dart';
import '../../providers/auth_provider.dart';
import '../../providers/server_cart_provider.dart';
import '../../providers/checkout_provider.dart';
import '../../providers/delivery_location_provider.dart';
import '../../providers/shipping_provider.dart';
import '../../widgets/address_picker.dart';
import '../../widgets/shipping_selector.dart';
import '../../widgets/state_views.dart';
import '../../../data/models/server_cart.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/quantity_stepper.dart';
import '../../widgets/app_message.dart';
import '../../widgets/bill_details.dart';
import '../../widgets/summary_row.dart';
import '../../widgets/surfaces.dart';

/// Checkout: where the order is going, what the courier charges to take it
/// there, and what that adds up to.
///
/// This screen used to be a flat address form with a hardcoded `Delivery FREE`
/// line underneath it. Neither half was true. The website prices shipping
/// through the `handle_shipping_fee` filter — `ShipRocketService::
/// getServiceabilityRates()` — and presents the courier list as selectable
/// options whose chosen row becomes the order's `shipping_method` and
/// `shipping_amount`. The mobile app now does the same thing against the same
/// data (`POST /logistics/check-serviceability`), so a basket the courier
/// charges ₹330.20 to ship no longer says FREE.
///
/// The three sections are ordered by dependency, because each one only becomes
/// answerable once the one above it is:
///
///   1. **Delivery address** — [AddressPicker]. Saved rows when signed in, a
///      typed address when not. Its output includes a PIN code that is empty
///      until it is a real one, so a half-typed pincode never triggers a quote.
///   2. **Shipping** — [ShippingSection]: a read-only confirmation of the
///      courier chosen on the cart, with Change reopening the list in a sheet.
///      It falls back to the full [ShippingSelector] when nothing has been
///      chosen for this parcel and pincode. Undeliverable is a hard stop.
///   3. **Bill details** — [CourierOption.billedPrice] of the chosen courier as
///      the shipping line. Not its `rate`: `rate` omits `coverage_charges` and
///      `other_charges`, which is ₹49.00 short on every basket past the
///      insurance threshold and the one figure the divergence sheet would then
///      fire on for every such order.
///
/// ## Chosen once — and never chosen *for* the customer
///
/// This screen used to render the selector's radio list in full, so the customer
/// was asked to pick a courier twice — once in the cart, once here — and the
/// second answer silently replaced the first. Both screens read
/// `shippingChoiceProvider`, so there is one courier and one total for the order;
/// checkout's job is to confirm it, not to reopen it.
///
/// And neither screen answers it on their behalf. `selectedShippingProvider` is
/// null until a row is tapped, so this screen opens with no delivery line, a
/// bold row labelled "Subtotal", no figure on the button and a blocker reading
/// **"Choose a delivery option to continue."** — the same sentence the cart's
/// prompt and the selector's own header use, so it names something on screen
/// rather than describing one. The app used to preselect the fastest courier,
/// which put Blue Dart Air at ₹1,284.15 into a bill whose other option was
/// Xpressbees Surface at ₹324.30 two days later.
///
/// ## "Shipping" or "Delivery"
///
/// Shipping is the charge and the method — the section, the bill row, the
/// options panel. Delivery is the date: `Delivery by 06 Aug` stays, and so does
/// "delivery address", because that is where it is delivered to.
///
/// ## The order is now really placed
///
/// The button used to sleep 600ms, drop the cart id and route to a static
/// success screen. It now runs the real sequence, and every step of it is owned
/// by [CheckoutFlowNotifier] rather than by this widget:
///
///   `POST /checkout/cart/{id}` -> Razorpay sheet -> `POST confirm-payment`
///   -> `GET /orders/{id}` -> success.
///
/// Three things about that sequence shape this screen more than anything else
/// on it:
///
///   * **The checkout POST is not idempotent.** Its server-side de-duplication
///     key is a session token, and the API middleware group has no session, so
///     a second POST is a second real order, a second Razorpay order and
///     another coupon use. The button is therefore dead for the entire call,
///     nothing here ever retries it, and a request that gets no answer leaves
///     the screen in a "check your orders" state rather than offering to try
///     again.
///   * **Cancelling the payment does not undo the order.** It exists, unpaid
///     and invisible to `GET /orders`. So the recovery affordance is *retry
///     payment* — reopening the same Razorpay order — never *place order*
///     again.
///   * **The cart is discarded only for an order proved paid.** The old fake
///     called `forget()` on every tap, orphaning a live server cart and its
///     rebuild mirror each time.
///
/// ## Shipping is priced by the server, and the total is reconciled
///
/// The checkout POST no longer carries `shipping_amount`. It carries
/// `shipping_method: "shiprocket"` and `shipping_option: "shiprocket_<rateId>"`
/// — the member key of the quote the customer picked — and the server prices the
/// line itself, which is what the web checkout has always done. This screen's
/// job in that exchange is two things:
///
///   * **send the right key.** [shippingOptionKeyProvider] resolves it against
///     the rate list that is live now, and the button stays dead when it comes
///     back null. There is no fallback: `"shiprocket_<courierCompanyId>"` and
///     `shipping_method: "default"` are both keys the server's table does not
///     contain, and a miss is not an error — it is a silent `shipping_amount`
///     of 0.00 on an order that otherwise looks perfect.
///   * **reconcile what comes back.** The server re-quotes Shiprocket from its
///     own `store_zip_code`, not the pickup postcode this app quoted with, so
///     its total can differ from the one on the button — higher from the
///     re-quote, lower from a missed lookup or a Shiprocket outage — and the
///     order is created *before* the app finds out. So after `placeOrder`
///     returns and **before** the Razorpay sheet opens, `data.total_amount` is
///     compared with the figure the button showed, and any real difference is
///     put in front of the customer with a Continue and a Cancel. See
///     [_TotalDivergenceSheet].
///
/// The figure on the button and the figure the comparison uses are the same
/// `OrderSummary.payable`, read once in `build` and passed to both. They cannot
/// be made to disagree by editing one of them.
///
/// ## Divergence is the exception, not the rule
///
/// It is worth being explicit about that, because the size of the tolerance and
/// the tone of the sheet both depend on it. A live reconstruction of all 62
/// shiprocket orders in the shop's history — every parcel rebuilt from its own
/// stored dimensions and re-quoted against `/logistics/check-serviceability`
/// with the pickup postcode as the only variable — put the server's origin at
/// **311001**, which is already [kDefaultPickupPinCode]. Five orders matched to
/// the paise and nine more to a uniform rate-card revision; no Gujarat origin
/// matched any of them, quoting 45-70% low.
///
/// So the two sides are quoting from the same warehouse, the sheet should fire
/// rarely, and it is right for it to read as an interruption when it does. That
/// is also why [TotalDivergence.tolerance] is half a paise rather than a band
/// wide enough to absorb a re-price: there is no expected drift for it to
/// absorb.
///
/// ## Once the order exists, the cart is not the bill
///
/// The three sections above are questions about an order that has not been
/// created yet. The moment `placeOrder` answers, every one of them is settled
/// server-side and the live cart total describes something nobody is paying
/// for — so [_placedOrder] replaces the lot with the server's own figures. See
/// its doc for what that was printing before.
class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key});

  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  /// Whatever the picker last told us. Held here rather than in a provider
  /// because it is scoped to this screen: leaving checkout and coming back
  /// should re-derive it from the address book, not resurrect a stale draft.
  AddressSelection _selection = AddressSelection.none;

  /// Whether the invoice goes to the delivery address.
  ///
  /// Default true, matching the web form's checked box — and matching what the
  /// server assumes when no `billing_address` is sent.
  bool _billingSameAsDelivery = true;

  /// The separate billing address, when there is one. Screen-scoped for the
  /// same reason [_selection] is.
  AddressSelection _billingSelection = AddressSelection.none;

  /// The billing address in the checkout body's shape, or null for "same as
  /// delivery" — which is a statement the repository turns into
  /// `billing_address_same_as_shipping_address: "1"`, not an omission.
  CheckoutAddress? _billingAddress() {
    if (_billingSameAsDelivery) return null;
    return _addressFrom(_billingSelection);
  }

  // No reset on the way out.
  //
  // [checkoutCartProvider] is set by whichever button opened this screen —
  // "Checkout" in the basket, "Buy now" on a product — so it is already correct
  // before the first build and there is nothing to undo. Resetting it here as
  // well was worse than redundant: it ran during widget teardown, and a screen
  // popped while a payment was still settling would have moved the flag out
  // from under the flow about to call `forget()` on the cart the order
  // consumed.

  @override
  void initState() {
    super.initState();
    // [checkoutFlowProvider] deliberately outlives this screen — it has to
    // survive a rebuild while the Razorpay sheet is up — so a terminal state
    // from a *previous* order would otherwise greet the next one. Only the two
    // states that are genuinely finished are cleared: `paid` (or the screen
    // would bounce straight back to an old receipt) and `refused` (a stale "out
    // of stock" over a basket that has since changed). Everything else —
    // paymentIncomplete, verifying, unresolved — names an order that still
    // exists and must stay on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final phase = ref.read(checkoutFlowProvider).phase;
      if (phase == CheckoutPhase.paid || phase == CheckoutPhase.refused) {
        ref.read(checkoutFlowProvider.notifier).reset();
      }
    });
  }

  void _onAddressChanged(AddressSelection selection) {
    if (!mounted) return;
    // Safe to setState directly: AddressPicker always calls back from a
    // post-frame callback, never from inside its own build.
    setState(() => _selection = selection);

    // Editing the address answers the refusal, so the refusal stops being
    // shown. Only `refused` is cleared: it is the one state where nothing was
    // created server-side, so there is nothing left to reconcile.
    if (ref.read(checkoutFlowProvider).phase == CheckoutPhase.refused) {
      ref.read(checkoutFlowProvider.notifier).reset();
    }
  }

  /// The delivery address in the shape the checkout body wants.
  ///
  /// Built from [AddressSelection.effectiveDraft] so a saved row and a typed
  /// one take the same path — and, for a saved row, so `state`/`city` go back
  /// as the opaque tokens the server stored rather than the names
  /// `full_address` renders.
  ///
  /// No rule is applied here. [CheckoutAddress.violations] delegates to
  /// [CheckoutAddressRules], which is also what the repository refuses on, so
  /// there is exactly one definition of a deliverable address.
  CheckoutAddress _checkoutAddress() => _addressFrom(_selection);

  /// The same conversion for either picker — delivery or billing.
  ///
  /// One function so the two addresses cannot be built by two slightly
  /// different rules; the billing one is re-validated server-side against the
  /// identical web rules and silently discarded on failure.
  CheckoutAddress _addressFrom(AddressSelection selection) {
    final draft = selection.effectiveDraft;
    return CheckoutAddress(
      name: draft.name,
      email: draft.email,
      phone: draft.phone,
      address: draft.address,
      city: draft.city,
      state: draft.state,
      zipCode: draft.zipCode,
      // Carried through so the order ships to the same place the saved address
      // describes — a landmark the customer added is often the only reason the
      // courier finds the door. Empty for a manually-typed address, and
      // [CheckoutAddress.toJson] omits empties.
      landmark: draft.landmark,
      district: draft.district,
      otherCity: draft.otherCity,
      // No country parameter: the store ships in one country, the server fills
      // it, and [CheckoutAddress] defaults it for the rules that still ask.
    );
  }

  /// True while the divergence sheet is on screen, so a rebuild cannot stack a
  /// second copy of it over the first.
  bool _divergenceOpen = false;

  /// Runs the real sequence. Called once per tap and never re-entered — the
  /// notifier refuses while a call is in flight, and the button is dead for the
  /// duration on top of that.
  ///
  /// [shippingOptionKey] names the quote the server should price; [shownTotal]
  /// is the figure on this button and [shownShipping] the delivery line inside
  /// it, both of which the notifier reconciles the server's answer against
  /// before any money is asked for.
  Future<void> _placeOrder(
    String cartId,
    String? shippingOptionKey,
    double? shownTotal,
    double? shownShipping,
  ) async {
    // Steps 7 and 9 are `auth:sanctum`. A signed-out POST is a guaranteed 401
    // that would read to the customer as a failed order, so ask first. This is
    // not a blocker on the button because the address picker deliberately works
    // signed out — the customer can fill everything in and sign in last.
    if (!ref.read(isAuthenticatedProvider)) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(content: Text('Please sign in to place your order.')),
      );
      await context.push('/login');
      return;
    }

    await ref.read(checkoutFlowProvider.notifier).placeOrder(
          cartId: cartId,
          address: _checkoutAddress(),
          // Names the quote; the server prices it. Null only when the selected
          // courier row carried no rate id, which the blocker already prevents —
          // and the repository refuses outright rather than substituting a key
          // that would bill 0.00.
          shippingOptionKey: shippingOptionKey,
          // The claim being made to the customer. Whatever comes back is
          // measured against exactly this number.
          shownTotal: shownTotal,
          // ...and the delivery line inside it, so a server shipping charge of
          // 0.00 is recognised as the missing courier it is rather than as a
          // parcel that was always free to send.
          shownShipping: shownShipping,
          // Null means "same as delivery", which the repository states
          // explicitly rather than omitting — see its
          // `billing_address_same_as_shipping_address` comment.
          billingAddress: _billingAddress(),
          // Collected in the cart. Null is the common case and sends no
          // `tax_information` block at all.
          taxInformation: ref.read(checkoutProvider).taxInformation,
        );
  }

  /// Abandons an unpaid order so a different one can be placed, having said out
  /// loud what that leaves behind.
  ///
  /// The confirmation is the point. Starting again does **not** cancel the order
  /// that exists — nothing in this app can, because `GET /orders` filters it out
  /// — and the next checkout overwrites the journal record that names it. So the
  /// number goes in front of the customer before it goes, together with the two
  /// facts that matter: nothing was charged, and nothing will be dispatched.
  Future<void> _startOver(int? orderId) async {
    // Two genuinely different situations, and only one of them may claim an
    // order exists.
    //
    //   * `paymentIncomplete` — the checkout POST returned 200, so the order is
    //     named and provably unpaid.
    //   * `unresolved` — the POST was never answered. The server runs no
    //     transaction, so it may well have committed the order, its lines, its
    //     shipment and the coupon's `total_used` before the response was lost.
    //     The app cannot name it and cannot look it up: both order reads filter
    //     `is_finished = 1`, so an unpaid order is invisible there by
    //     construction.
    //
    // The screen used to offer "I checked — it isn't there" here, which asked
    // the customer to confirm a fact that is unverifiable for exactly the orders
    // at risk — looking at My orders can only ever show nothing, whether or not
    // the order exists. They would confirm honestly, and place a duplicate.
    final unknown = orderId == null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('checkout-start-over-dialog'),
        title: const Text('Start a new order?'),
        content: Text(
          unknown
              ? 'Your last checkout was cut off before we heard back, so we do '
                  'not know whether an order was created. Nothing was charged — '
                  'payment never started — but an order may exist that we cannot '
                  'show you here.\n\n'
                  'Starting again may place a second order for the same basket. '
                  'If you would rather be sure first, contact us before '
                  'continuing.'
              : 'Order $orderId has already been created and has not been paid '
                  'for. Nothing was charged for it and it will not be '
                  'dispatched.\n\n'
                  'Starting again places a *second* order. This one stays '
                  'unpaid — note its number if you want to ask us about it, '
                  'because we will stop showing it to you here.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep paying it'),
          ),
          ElevatedButton(
            key: const Key('checkout-start-over-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Start again'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    ref.read(checkoutFlowProvider.notifier).startOver();
  }

  /// Asks the customer whether to pay the server's total after all.
  ///
  /// Modal and undismissable-by-accident: the two answers are genuinely
  /// different — one takes money, the other does not — so there is no sensible
  /// "tapped outside" default. A system back gesture still pops it, and that
  /// returns null, which is read as Cancel: the direction that charges nothing.
  Future<void> _resolveDivergence(TotalDivergence divergence) async {
    if (_divergenceOpen) return;
    _divergenceOpen = true;
    final proceed = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _TotalDivergenceSheet(
        divergence: divergence,
        orderId: ref.read(checkoutFlowProvider).orderId,
      ),
    );
    _divergenceOpen = false;
    if (!mounted) return;

    final notifier = ref.read(checkoutFlowProvider.notifier);
    if (proceed == true) {
      await notifier.acceptServerTotal();
      return;
    }
    notifier.declineServerTotal();
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(activeCartProvider);
    final flow = ref.watch(checkoutFlowProvider);

    // The one navigation in this screen, and it fires on exactly one
    // transition: an order proved paid. Everything else — a dismissed sheet, an
    // unverified payment, a refusal — stays here, because the order still needs
    // something doing to it and the customer must not be shown a receipt.
    ref.listen<CheckoutFlowState>(checkoutFlowProvider, (previous, next) {
      if (next.isPaid && previous?.isPaid != true) {
        context.pushReplacement('/order-success/${next.orderId}');
        return;
      }
      // TEMPORARY — see docs/TODO_CANCELLED_PAYMENT_FLOW.md. A dismissed
      // Razorpay sheet abandons the order and returns the customer to the
      // cart, where the next checkout starts clean. The flow is reset FIRST:
      // this provider is not autoDispose, so without the reset the abandoned
      // order's state would still be live when checkout is next opened.
      if (next.phase == CheckoutPhase.cancelledBackToCart &&
          previous?.phase != CheckoutPhase.cancelledBackToCart) {
        // A microtask, not inline: setting this provider's state from inside
        // its own listener is reentrant notification, and the pop belongs
        // after the reset so the screen cannot rebuild `cancelledBackToCart`
        // on the way out.
        // The navigator is resolved before the microtask so no BuildContext
        // is used across the async gap; `mounted` still gates the pop itself.
        // `Navigator`, not `GoRouter.of`: the cart reaches this screen with
        // `context.push('/checkout')`, which go_router places on the root
        // navigator, so a plain pop lands back on the cart — and it keeps
        // this screen mountable under a bare MaterialApp (the widget tests).
        final navigator = Navigator.of(context);
        Future.microtask(() {
          ref.read(checkoutFlowProvider.notifier).reset();
          if (mounted) navigator.maybePop();
        });
        return;
      }
      // The order exists, nothing has been charged, and the server's total is
      // not the one on the button. This is the only thing in the app that can
      // stand between a created order and the Razorpay sheet, so it is driven
      // off the state transition rather than off a tap.
      if (next.needsDecision && previous?.phase != CheckoutPhase.totalChanged) {
        unawaited(_resolveDivergence(next.divergence!));
      }
    });

    // Nothing to check out. Reachable by emptying the cart in another tab and
    // coming back, and the screen used to render an address form for an order
    // of nothing.
    //
    // Guarded by the flow twice over: the cart is emptied as part of settling a
    // paid order, and for the frame between that and the route change this
    // would otherwise flash "your cart is empty" over a successful checkout —
    // and an order that already exists outranks an empty basket entirely.
    // Showing the empty state there would take away the only button that can
    // pay for it.
    if (cart.isEmpty && !flow.isPaid && !flow.isBusy && !flow.orderMayExist) {
      return _emptyCart(context);
    }

    // The parcel has to be known before a rate can be asked for: serviceability
    // prices a shipment, not a pincode.
    final parcelAsync = ref.watch(checkoutParcelProvider);
    final parcel = parcelAsync.valueOrNull;

    final query = (parcel != null && _selection.pinCode.isNotEmpty)
        ? parcel.toQuery(_selection.pinCode)
        : null;

    // Watched, not derived: `ShippingSelector` reads the same provider, so both
    // the list and the bill are looking at one quote.
    final rates = query == null ? null : ref.watch(courierOptionsProvider(query));
    final charge = query == null ? null : ref.watch(shippingChargeProvider(query));

    // What the order will be sent as `shipping_option`. Resolved live against
    // the current rate list, not off the snapshot the customer tapped — a rate
    // id identifies a quote, and a re-fetch can reissue the same courier under a
    // new one. Null is a hard block, never a substituted guess.
    final optionKey =
        query == null ? null : ref.watch(shippingOptionKeyProvider(query));

    final summary = ref.watch(checkoutSummaryProvider(charge));

    // THE figure. It labels the button and it is what the server's response is
    // reconciled against — read once, here, and handed to both. Null until a
    // courier has quoted, which is also when the button is dead.
    final shownTotal = summary.payable;

    final blocker = _blocker(
      flow: flow,
      parcelAsync: parcelAsync,
      query: query,
      rates: rates,
      charge: charge,
      optionKey: optionKey,
    );
    // Short form of the same story the blocker tells, for the bill's Shipping
    // row. Computed here, next to the blocker, so the two cannot drift.
    final pendingDelivery = charge != null
        ? null
        : _pendingDelivery(
            parcelAsync: parcelAsync,
            query: query,
            rates: rates,
          );

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(title: const Text('Checkout')),
      body: ListView(
        // Bottom inset clears the pinned action bar, which overlays the list.
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.huge * 2,
        ),
        children: [
          // *** Everything below is about an order that does not exist yet. ***
          //
          // Once one does, none of it is answerable any more: the address is
          // fixed on the order, the courier is fixed on the order, and the bill
          // is whatever the server billed. Leaving the three live sections up
          // would put an editable address, a re-priceable courier and a live
          // cart total beside a button that pays a figure none of them can
          // change — which is exactly how the screen came to print "To pay
          // ₹1,982.35" over a button reading "Retry payment • ₹3,174.10".
          if (flow.orderMayExist)
            _placedOrder(context, flow)
          else
            ..._checkoutSections(
              context: context,
              flow: flow,
              cart: cart,
              summary: summary,
              parcelAsync: parcelAsync,
              query: query,
              pendingDelivery: pendingDelivery,
              charge: charge,
              parcel: parcel,
            ),
        ],
      ),
      bottomSheet: BottomActionBar(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // What the last attempt did, when it did something worth saying.
            // Separate from the blocker because these are outcomes, not
            // preconditions, and several of them leave the button live.
            if (_flowNotice(flow) case final notice?) ...[
              Text(
                notice,
                key: const Key('checkout-flow-message'),
                textAlign: TextAlign.center,
                style: context.text.caption.copyWith(
                  color: flow.phase == CheckoutPhase.refused
                      ? AppColors.warning
                      : null,
                ),
              ),
              AppSpacing.vXs,
            ],
            // Saying *why* the button is dead is the whole point — a disabled
            // primary action with no explanation reads as a broken app.
            if (blocker != null) ...[
              Text(
                blocker,
                key: const Key('checkout-blocker'),
                textAlign: TextAlign.center,
                style: context.text.caption,
              ),
              AppSpacing.vXs,
            ],
            _primaryAction(
              context,
              flow: flow,
              shownTotal: shownTotal,
              shownShipping: charge,
              cartId: cart.cart?.id ?? '',
              optionKey: optionKey,
              blocked: blocker != null,
            ),
          ],
        ),
      ),
    );
  }

  /// The three live sections, for as long as there is no order.
  ///
  /// Split out so [build] can state the *one* condition that replaces all of
  /// them, rather than repeating `if (!flow.orderMayExist)` down a list where
  /// forgetting it once is a wrong number on a bill.
  List<Widget> _checkoutSections({
    required BuildContext context,
    required CheckoutFlowState flow,
    required ServerCartState cart,
    required OrderSummary summary,
    required AsyncValue<CheckoutParcel> parcelAsync,
    required ShippingQuery? query,
    required String? pendingDelivery,
    required double? charge,
    required CheckoutParcel? parcel,
  }) =>
      [
        _sectionTitle(context, '1. Delivery address'),
        AppSpacing.vSm,
        if (flow.fieldErrors.isNotEmpty) ...[
          _addressProblems(context, flow.fieldErrors),
          AppSpacing.vSm,
        ],
        AddressPicker(
          // Frozen while the order is going out, so the destination cannot
          // change under an in-flight request.
          enabled: !flow.isBusy,
          // Falls back to the address the cart is already shipping to, so a
          // customer who picked address B down there does not land here
          // addressed to their default. `_selection` wins once the picker has
          // emitted, which it does on its first post-frame callback.
          initialAddressId: _selection.addressId ??
              ref.watch(selectedDeliveryAddressIdProvider),
          initialDraft: _selection.draft,
          onChanged: _onAddressChanged,
        ),
        AppSpacing.vMd,
        ..._billingSection(context, flow),
        AppSpacing.vLg,
        _sectionTitle(context, '2. Shipping'),
        AppSpacing.vSm,
        _shipping(parcelAsync, query),
        AppSpacing.vLg,
        _sectionTitle(context, '3. Items'),
        AppSpacing.vSm,
        _items(context, cart, flow),
        AppSpacing.vLg,
        _bill(context, cart, summary, query, pendingDelivery, charge, parcel),
      ];

  /// What is being bought, and the only place on this screen it can be changed.
  ///
  /// This screen used to list nothing at all: the customer arrived from the
  /// basket, having just read it, so the bill was enough. "Buy now" broke that
  /// assumption — it comes straight here from a product page, and a checkout
  /// that names no products is asking someone to pay for something it never
  /// showed them.
  ///
  /// The counter is here for the same reason. Sending the customer back to the
  /// basket to change a quantity is asking them to leave a payment flow they
  /// have already committed to, and the stepper is one they have used on every
  /// other screen in the app.
  Widget _items(BuildContext context, ServerCartState cart, CheckoutFlowState flow) {
    final items = cart.cart?.items ?? const <ServerCartItem>[];
    if (items.isEmpty) return const SizedBox.shrink();

    final notifier = ref.read(activeCartNotifierProvider);

    return AppCard(
      key: const Key('checkout-items'),
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        children: [
          for (final item in items) ...[
            if (item != items.first) const Divider(height: AppSpacing.lg),
            _itemRow(context, item, cart, notifier, flow),
          ],
        ],
      ),
    );
  }

  Widget _itemRow(
    BuildContext context,
    ServerCartItem item,
    ServerCartState cart,
    ServerCartNotifier notifier,
    CheckoutFlowState flow,
  ) {
    // Frozen while the order is going out, exactly like the address picker and
    // the billing switch: what is being paid for must not change under an
    // in-flight payment.
    final frozen = flow.isBusy;

    return Row(
      key: ValueKey('checkout-item-${item.lineId.value}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: AppNetworkImage(
            url: item.imageUrl,
            borderRadius: AppRadius.rSm,
            fit: BoxFit.cover,
          ),
        ),
        AppSpacing.hSm,
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodySm,
              ),
              if (item.variationLabel case final pack? when pack.isNotEmpty)
                Text(
                  pack,
                  style: context.text.caption
                      .copyWith(color: context.colors.muted),
                ),
              AppSpacing.vXs,
              Text(
                item.lineTotal.display,
                style: context.text.title,
              ),
            ],
          ),
        ),
        AppSpacing.hSm,
        QuantityStepper(
          quantity: item.quantity,
          dense: true,
          // This line's own write, so the spinner lands on the row the
          // customer tapped and every other row stays still.
          busy: cart.isBusyLine(item.lineId),
          // At the cap the button says why rather than going grey — a dead
          // control reads as broken and the next move is to tap it again. The
          // sentence is built from `max_cart_quantity` because the server's own
          // refusal quotes the STOCK level instead of the cap, and because
          // pushing a line past its maximum takes the whole basket with it
          // (docs/BACKEND_BUGS.md finding 0).
          onIncrement: frozen
              ? null
              : item.canIncrement
                  ? () => _report(context, notifier.increment(item.lineId))
                  : () => context.showAlertSnack(
                        'Sorry, you can only order a maximum of '
                        '${item.maxCartQuantity} units.',
                      ),
          // At the minimum the only legal move is removing the line. Doing it
          // here rather than sending the customer back to the basket is the
          // whole point of the counter being on this screen — but an empty
          // basket ends the checkout, so it is worth being sure.
          onDecrement: frozen
              ? null
              : item.canDecrement
                  ? () => _report(context, notifier.decrement(item.lineId))
                  : () => _confirmRemove(context, item, notifier),
        ),
      ],
    );
  }

  /// Taking the last unit out is a removal, and a removal on this screen can
  /// empty the basket and end the checkout — so it is asked about first.
  Future<void> _confirmRemove(
    BuildContext context,
    ServerCartItem item,
    ServerCartNotifier notifier,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this item?'),
        content: Text(
          item.minCartQuantity > 1
              ? '${item.name} is sold in ${item.minCartQuantity}s, so it comes '
                  'out of the order altogether.'
              : 'It comes out of this order.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it'),
          ),
          TextButton(
            key: const Key('checkout-item-remove'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !context.mounted) return;
    await _report(context, notifier.remove(item.lineId));
  }

  /// Surfaces whatever the cart notifier reports, which is the server's own
  /// wording when it refused.
  Future<void> _report(BuildContext context, Future<String?> work) async {
    final failure = await work;
    if (failure != null && context.mounted) context.showAlertSnack(failure);
  }

  /// Where the invoice goes, when that is not where the parcel goes.
  ///
  /// Sits inside section 1 rather than taking a number of its own: almost every
  /// order bills to the delivery address, and a fourth numbered step for a
  /// switch most customers never touch would push the bill and the Place order
  /// button further below the fold for everyone.
  ///
  /// ## This needs a server setting to do anything
  ///
  /// `OrderHelper::storeOrderBillingAddress` opens with
  /// `if (! EcommerceHelper::isBillingAddressEnabled()) { return; }`, and that
  /// setting defaults to `'0'`. With it off the order is still created, HTTP
  /// 200 still comes back, and the billing address is **silently dropped** —
  /// there is no response field that says so and nothing the app can read to
  /// find out. See `docs/BACKEND_BUGS.md`.
  List<Widget> _billingSection(BuildContext context, CheckoutFlowState flow) => [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Not a SwitchListTile: its own padding fights AppCard's and it
              // cannot carry the caption underneath without a second row.
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Billing address same as delivery',
                      style: context.text.title,
                    ),
                  ),
                  Switch(
                    key: const Key('checkout-billing-same'),
                    value: _billingSameAsDelivery,
                    // Frozen while the order is going out, like the address
                    // picker above it — the destination of an in-flight order
                    // must not change under it.
                    onChanged: flow.isBusy ? null : _onBillingSameChanged,
                  ),
                ],
              ),
              if (!_billingSameAsDelivery) ...[
                AppSpacing.vSm,
                Text(
                  'Where the invoice goes. It does not change delivery.',
                  style:
                      context.text.caption.copyWith(color: context.colors.faint),
                ),
                AppSpacing.vSm,
                AddressPicker(
                  key: const Key('checkout-billing-picker'),
                  enabled: !flow.isBusy,
                  initialAddressId: _billingSelection.addressId,
                  initialDraft: _billingSelection.draft,
                  onChanged: _onBillingAddressChanged,
                ),
              ],
            ],
          ),
        ),
      ];

  void _onBillingSameChanged(bool same) {
    if (!mounted) return;
    setState(() {
      _billingSameAsDelivery = same;
      // Turning it back on drops the typed billing address rather than keeping
      // it hidden: leaving it around would have a later toggle resurrect an
      // address the customer has since changed their delivery address away
      // from, and they would never see it again before the order went out.
      if (same) _billingSelection = AddressSelection.none;
    });
    if (ref.read(checkoutFlowProvider).phase == CheckoutPhase.refused) {
      ref.read(checkoutFlowProvider.notifier).reset();
    }
  }

  void _onBillingAddressChanged(AddressSelection selection) {
    if (!mounted) return;
    setState(() => _billingSelection = selection);
    if (ref.read(checkoutFlowProvider).phase == CheckoutPhase.refused) {
      ref.read(checkoutFlowProvider.notifier).reset();
    }
  }

  /// The one button at the bottom, in whichever of its three jobs applies.
  ///
  /// Placing the order and paying for it are separate actions because the order
  /// outlives a failed payment: once it exists, offering "Place order" again is
  /// the single most expensive mistake this screen could make — it would create
  /// a second order, a second Razorpay order and burn another coupon use for a
  /// basket the customer is trying to pay for once.
  Widget _primaryAction(
    BuildContext context, {
    required CheckoutFlowState flow,
    required double? shownTotal,
    required double? shownShipping,
    required String cartId,
    required String? optionKey,
    required bool blocked,
  }) {
    // The divergence sheet is up (or was popped by a back gesture before its
    // answer landed). An order EXISTS, so the one thing that must not be on
    // screen here is a live "Place order" — a second tap would be a second
    // order, a second Razorpay order and another coupon use. The sheet is modal,
    // but this branch is what makes that a belt-and-braces rather than the only
    // guard.
    if (flow.needsDecision) {
      return ElevatedButton(
        key: const Key('checkout-review-total'),
        onPressed: () => _resolveDivergence(flow.divergence!),
        child: const Text('Review your total'),
      );
    }

    // An order exists, unpaid, and the same Razorpay order can be reopened.
    if (flow.canRetryPayment) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton(
            key: const Key('checkout-retry-payment'),
            onPressed: ref.read(checkoutFlowProvider.notifier).retryPayment,
            child: Text(
              flow.serverTotal == null
                  ? 'Retry payment'
                  : 'Retry payment  •  ${flow.serverTotal}',
            ),
          ),
          // The way out. Without it, refusing the server's total was a one-way
          // door: every control here pays the order that already exists, this
          // provider outlives the screen, and nothing the customer could reach
          // ever called `reset` — so they could never place another order at
          // all.
          _startOverButton(flow),
          TextButton(
            key: const Key('checkout-view-orders'),
            onPressed: () => context.push('/orders'),
            child: const Text('View my orders'),
          ),
        ],
      );
    }

    // Money may have moved, or an order may exist that we cannot name. Either
    // way the way out is the orders list, never another checkout.
    if (flow.needsReconciliation) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton(
            key: const Key('checkout-view-orders'),
            onPressed: () => context.push('/orders'),
            child: const Text('View my orders'),
          ),
          // Offered ONLY for `unresolved`, and only as an acknowledgement — see
          // [_startOver], which spells out that a second order may result.
          // Never for `verifying`, where an order definitely exists and money
          // may have moved: checking out again there would charge them twice.
          //
          // This used to be "I checked — it isn't there", wired straight to
          // `reset()`. That asked the customer to certify something no screen in
          // this app can show them: `GET /orders` filters `is_finished = 1`, so
          // an order created by an unanswered POST is invisible there whether or
          // not it exists. The honest answer is that we do not know, so the way
          // out says so rather than putting a false statement in their mouth.
          _startOverButton(flow),
        ],
      );
    }

    // An order exists and none of the branches above claimed it — the journal
    // record lost (or never carried) a usable Razorpay block, so the payment
    // cannot be reopened from here. Falling through to "Place order" would
    // create a SECOND order for a basket that already has one, which is the
    // single most expensive thing this screen can do.
    //
    // `isBusy` is excluded deliberately: the sheet is up or the confirmation is
    // in flight, and the disabled spinner below is the right thing to show.
    if (flow.hasOrder && !flow.isBusy) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton(
            key: const Key('checkout-view-orders'),
            onPressed: () => context.push('/orders'),
            child: const Text('View my orders'),
          ),
          _startOverButton(flow),
        ],
      );
    }

    return ElevatedButton(
      key: const Key('checkout-place-order'),
      // Dead for the whole call. This is the non-idempotency guard the customer
      // can actually see; the notifier refuses re-entry underneath it.
      onPressed: (blocked || flow.isBusy || cartId.isEmpty)
          ? null
          : () => _placeOrder(cartId, optionKey, shownTotal, shownShipping),
      child: flow.isBusy
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          // The amount appears only once it is the real one — delivery
          // included. This is the claim the server's answer is measured
          // against, which is why the same `shownTotal` is what goes to
          // `placeOrder` rather than a second read of the summary.
          : Text(
              shownTotal == null
                  ? 'Place order'
                  : 'Place order  •  ${PriceUtils.format(shownTotal)}',
            ),
    );
  }

  /// The escape hatch from an unpaid order, or nothing when there is no order
  /// to escape from.
  ///
  /// Rendered as the quiet option on purpose: paying the order that already
  /// exists is nearly always the right answer, and this one leaves a real order
  /// behind. [_startOver] is where that is spelled out.
  Widget _startOverButton(CheckoutFlowState flow) => flow.canStartOver
      ? TextButton(
          key: const Key('checkout-start-over'),
          onPressed: () => _startOver(flow.orderId),
          child: const Text('Start a new order'),
        )
      : const SizedBox.shrink();

  /// What the last attempt did, or null while nothing has been attempted.
  ///
  /// Deliberately the *server's own sentence* wherever there is one — "Product
  /// 118 is out of stock!", "Minimum order amount is Rs.500.00" — because it
  /// names the constraint, which a generic "checkout failed" never does.
  String? _flowNotice(CheckoutFlowState flow) => switch (flow.phase) {
        CheckoutPhase.refused ||
        CheckoutPhase.paymentIncomplete ||
        CheckoutPhase.verifying ||
        CheckoutPhase.unresolved ||
        // The same sentence the sheet leads with, left on the page behind it so
        // a customer who backs out of the sheet still knows why the button
        // changed.
        CheckoutPhase.totalChanged =>
          flow.message,
        _ => null,
      };

  /// The address violations the flow refused on, listed where the address is.
  ///
  /// Keyed by the server's own field names, in [AddressField.all] order rather
  /// than map order, so the list reads top-to-bottom like the form does.
  Widget _addressProblems(BuildContext context, Map<String, String> errors) {
    final ordered = [
      for (final field in AddressField.all)
        if (errors[field] != null) errors[field]!,
      // Anything the server named that this app does not model — it still has
      // to reach the customer rather than be swallowed by an unknown key.
      for (final entry in errors.entries)
        if (!AddressField.all.contains(entry.key)) entry.value,
    ];

    return AppCard(
      key: const Key('checkout-address-errors'),
      padding: const EdgeInsets.all(AppSpacing.sm),
      color: context.colors.surfaceAlt,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: AppColors.warning,
          ),
          AppSpacing.hSm,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This address cannot be delivered to',
                  style: context.text.title,
                ),
                AppSpacing.gapXxs,
                for (final message in ordered)
                  Text('• $message', style: context.text.bodySm),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Sections
  // -------------------------------------------------------------------------

  Widget _sectionTitle(BuildContext context, String text) =>
      Text(text, style: context.text.h3);

  /// The chosen courier, plus the two states that sit *before* it.
  ///
  /// [ShippingSection] handles everything from a valid query onwards — the
  /// confirmation, the Change sheet, and the fallback selector with its own
  /// loading, retryable failure and undeliverable states. What it cannot know
  /// about is the parcel: passing `query: null` makes it say "choose a delivery
  /// address", which would be a lie while the cart is being weighed.
  Widget _shipping(
    AsyncValue<CheckoutParcel> parcelAsync,
    ShippingQuery? query,
  ) =>
      parcelAsync.when(
        data: (_) => ShippingSection(query: query),
        loading: () => _selection.pinCode.isEmpty
            // No address yet either, so the section's own idle prompt is still
            // the most useful thing to show.
            ? const ShippingSection()
            : const _ParcelLoading(),
        error: (error, _) => AppCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: InlineErrorStrip(
            error: error,
            label: 'this order for shipping charges',
            onRetry: () => ref.invalidate(checkoutParcelProvider),
          ),
        ),
      );

  /// The bill once the order exists — **the server's figures, and only those**.
  ///
  /// ## Why the live one cannot stay up
  ///
  /// The checkout POST prices the shipping line itself, so the moment it answers
  /// there are two totals in the app and only one of them is owed. This screen
  /// used to keep rendering the other one — built from the live cart and this
  /// app's own courier quote — beside a button that pays the server's, printing
  /// a bold "To pay ₹2,926.30" over "Retry payment • ₹3,174.10".
  ///
  /// The basket is deliberately preserved through a declined payment, which made
  /// it worse than a stale number: going back and removing a unit re-priced the
  /// bill to ₹1,982.35 while the only live action still charged ₹3,174.10 for
  /// the original two-unit order.
  ///
  /// Nothing here is derived and nothing is re-added from parts.
  /// [TotalDivergence.chargedDisplay] and [TotalDivergence.shippingDisplay] are
  /// the strings the server rendered, down to the paise.
  Widget _placedOrder(BuildContext context, CheckoutFlowState flow) {
    final divergence = flow.divergence;
    final total = divergence?.chargedDisplay ?? flow.serverTotal;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(context, 'Your order'),
        AppSpacing.vSm,
        AppCard(
          key: const Key('checkout-order-bill'),
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                // The order **code** (`SF10000315`) or nothing — never the
                // numeric id, which is an internal key printed on no invoice,
                // no email and no other screen.
                //
                // `code` is null today: `POST /checkout/cart/{id}` returns
                // `order_id` and `order_token` and no code (checked in
                // `API/CheckoutController`), and the order cannot be read from
                // `GET /orders/{id}` until it is paid — that route filters
                // `is_finished = 1`. The moment the backend adds
                // `'code' => $order->code` to that payload, this prints it.
                flow.orderCode ?? 'Your order',
                style: context.text.title,
              ),
              AppSpacing.gapXxs,
              Text(_orderStanding(flow), style: context.text.bodySm),
              if (total != null) ...[
                const Divider(height: 22),
                // The order's own delivery line. It is the figure that moved,
                // and on the outage path it is ₹0.00 — which the sheet in front
                // of this panel refuses to let pass as a discount.
                if (divergence != null)
                  _moneyRow(
                    context,
                    'Shipping charged',
                    divergence.shippingDisplay,
                  ),
                _moneyRow(
                  context,
                  // "To pay" over a paid order would be its own small lie, and
                  // this panel is on screen for the frame between settling and
                  // the receipt.
                  flow.phase == CheckoutPhase.paid ? 'Paid' : 'To pay',
                  total,
                  bold: true,
                ),
              ],
              AppSpacing.vXs,
              Text(
                total == null
                    ? "We don't have this order's total. Check My orders before "
                        'ordering again.'
                    : 'This is what the order itself was billed, not an '
                        'estimate. Your basket is untouched.',
                style: context.text.caption,
              ),
            ],
          ),
        ),
        if (flow.phase == CheckoutPhase.paymentIncomplete) ...[
          AppSpacing.vSm,
          _cartChangedHint(context),
        ],
      ],
    );
  }

  /// Names the exact confusion this panel otherwise leaves silent: an order
  /// created earlier and left unpaid pins the screen to *its* total, and
  /// nothing on it says so — a customer who backed out to the cart, added
  /// something, and came back sees the same frozen figure with no obvious
  /// reason why the new item is not in it.
  ///
  /// It is not, and cannot safely be, "your cart changed" — [PendingOrder]
  /// does not carry a line-item snapshot to diff against, and the order's
  /// [CheckoutFlowState.serverTotal] already includes tax and a courier quote
  /// the live cart has not repriced, so the two totals disagreeing proves
  /// nothing either way. The honest version names what is true regardless:
  /// this total is fixed to the order above, and anything added to the basket
  /// since needs its own order.
  Widget _cartChangedHint(BuildContext context) => AppCard(
        color: context.colors.surfaceAlt,
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline_rounded,
              size: 18,
              color: context.colors.muted,
            ),
            AppSpacing.hSm,
            Expanded(
              child: Text(
                'Added anything to your cart since this order was created? '
                'It is not included here and will not be charged. Use '
                '"Start a new order" below to check out your current cart '
                'instead.',
                style: context.text.bodySm,
              ),
            ),
          ],
        ),
      );

  /// Where the order stands, in one sentence.
  ///
  /// Every branch names a real server-side state. None of them says "cancelled"
  /// or "not placed": the order exists from the moment the checkout POST answers
  /// and nothing this screen does removes it.
  String _orderStanding(CheckoutFlowState flow) => switch (flow.phase) {
        CheckoutPhase.totalChanged =>
          'Created. Confirm the total below — no money has moved yet.',
        CheckoutPhase.awaitingPayment => 'Waiting for your payment.',
        CheckoutPhase.confirming => 'Confirming your payment…',
        CheckoutPhase.paid => 'Paid.',
        CheckoutPhase.verifying =>
          "Created. We're checking whether the payment went through.",
        CheckoutPhase.unresolved =>
          'This order may not have been created. Check My orders before '
              'ordering again.',
        _ => 'Created, and not paid for yet. No money has moved.',
      };

  /// The same card the placed order shows, filled from the live basket.
  ///
  /// It used to be composed here separately — same widgets, a different order
  /// of rows and a different treatment of the discount (folded into the item
  /// row behind a "Saved" chip, where the order screen gave it a line of its
  /// own). One tap apart, the same order therefore described its own discount
  /// two ways, and nothing on either screen told the customer that was a
  /// styling choice rather than a different charge.
  Widget _bill(
    BuildContext context,
    ServerCartState cart,
    OrderSummary summary,
    ShippingQuery? query,
    String? pendingDelivery,
    double? charge,
    CheckoutParcel? parcel,
  ) =>
      OrderBillCard(
        terms: BillTerms(
          // `raw_sub_total`: goods before either deduction. The rows below take
          // them off, exactly as the server does.
          itemTotal: PriceUtils.format(summary.itemTotal),
          discount: summary.totalSavings > 0
              ? PriceUtils.format(summary.totalSavings)
              : null,
          couponCode: summary.couponCode,
          shippingRow: _deliveryLine(context, query, pendingDelivery, charge, summary),
          tax: '+ ${PriceUtils.format(summary.gstIncluded)}',
          // "Subtotal" while delivery is unknown, so the figure cannot be
          // mistaken for the amount due.
          totalLabel: summary.isDeliveryKnown ? 'To pay' : 'Subtotal',
          total: PriceUtils.format(summary.payableOrSubtotal),
          // Always, zero included — see [BillTerms.savings].
          savings: PriceUtils.format(summary.totalSavings),
          // Named, not added: free delivery is not inside `totalSavings` and
          // there is no would-have-been quote to subtract from.
          savingsNote: summary.totalSavings > 0 && summary.hasFreeDelivery
              ? 'Plus free delivery on this order'
              : null,
        ),
        extraRows: [
          if (charge != null && parcel != null && !parcel.isWeightKnown)
            _weightCaveat(context, parcel),
        ],
      );

  /// The shipping line of the bill.
  ///
  /// There is no hardcoded branch here and there never will be again: the only
  /// way this prints a number is if a courier quoted one, and the only way it
  /// prints FREE is if that quote was zero. The app used to decide free
  /// delivery for itself from a ₹499 threshold that exists nowhere in the
  /// backend.
  Widget _deliveryLine(
    BuildContext context,
    ShippingQuery? query,
    String? pendingDelivery,
    double? charge,
    OrderSummary summary,
  ) {
    if (charge == null) {
      return BillRow(
        icon: BillIcons.shipping,
        label: 'Shipping',
        value: pendingDelivery ?? 'Add an address',
        muted: true,
      );
    }
    if (summary.hasFreeDelivery) {
      return BillRow(
        icon: BillIcons.shipping,
        label: 'Shipping',
        value: 'FREE',
        valueColor: context.colors.savings,
      );
    }
    // Carries the courier's name under the label, so the bill and the selector
    // cannot disagree about which quote is being charged.
    return ShippingBillLine(query: query);
  }

  /// What the bill's Shipping row says while there is no charge to print.
  ///
  /// Six different situations reach this row and they are not interchangeable.
  /// It used to read "Choose an option above" for all but one of them — an
  /// instruction the customer frequently could not follow, because on an
  /// undeliverable pincode there is no option to choose and mid-quote there is
  /// nothing yet to choose from. A refusal that renders as a nudge is the same
  /// class of untruth as a delivery charge that renders as FREE.
  ///
  /// Deliberately built alongside [_blocker] and in the same order, so the row
  /// and the sentence above the button can never describe different states.
  String _pendingDelivery({
    required AsyncValue<CheckoutParcel> parcelAsync,
    required ShippingQuery? query,
    required AsyncValue<ShippingRates>? rates,
  }) {
    if (query == null || rates == null) {
      if (_selection.pinCode.isEmpty) return 'Add an address';
      if (parcelAsync.hasError) return 'Unavailable — retry above';
      // Address in hand, cart still being weighed.
      return 'Calculating…';
    }
    if (rates.isLoading) return 'Calculating…';
    if (rates.hasError) return 'Unavailable — retry above';
    final value = rates.valueOrNull;
    if (value != null && (!value.deliverable || value.isEmpty)) {
      return "We can't deliver here";
    }
    return 'Choose an option above';
  }

  /// Some lines have no recorded pack weight, so the quote is a floor.
  ///
  /// The cart snapshot keeps no weight and the product *list* response omits
  /// it, so [checkoutParcelProvider] reads each line's product detail. A line it
  /// cannot weigh contributes nothing — which makes the courier's price lower
  /// than the real one, and that is exactly the kind of understatement this
  /// screen exists to stop doing silently.
  Widget _weightCaveat(BuildContext context, CheckoutParcel parcel) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xxs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.info_outline_rounded,
              size: 16,
              color: AppColors.warning,
            ),
            AppSpacing.hXs,
            Expanded(
              child: Text(
                'We have no pack weight on record for '
                '${parcel.unweighedLines} item'
                '${parcel.unweighedLines == 1 ? '' : 's'}, so the courier '
                'charge above may be revised before dispatch.',
                style: context.text.caption,
              ),
            ),
          ],
        ),
      );

  Widget _emptyCart(BuildContext context) => Scaffold(
        backgroundColor: context.colors.background,
        appBar: AppBar(title: const Text('Checkout')),
        body: EmptyView(
          icon: AppIcons.cart,
          title: 'Your cart is empty',
          subtitle: 'Add something to it and the shipping charge will be '
              'quoted for your address here.',
          action: ElevatedButton(
            onPressed: () => context.go('/'),
            child: const Text('Browse products'),
          ),
        ),
      );

  // -------------------------------------------------------------------------
  // Gating
  // -------------------------------------------------------------------------

  /// Why the order cannot be placed yet, or null when it can.
  ///
  /// One function so the button's `onPressed` and the sentence above it can
  /// never drift apart: the button is disabled **exactly** when there is a
  /// reason to show.
  String? _blocker({
    required CheckoutFlowState flow,
    required AsyncValue<CheckoutParcel> parcelAsync,
    required ShippingQuery? query,
    required AsyncValue<ShippingRates>? rates,
    required double? charge,
    required String? optionKey,
  }) {
    if (flow.isBusy) {
      return switch (flow.phase) {
        CheckoutPhase.placing =>
          'Placing your order — please stay on this screen.',
        CheckoutPhase.awaitingPayment =>
          'Complete the payment to finish your order.',
        _ => 'Confirming your payment…',
      };
    }

    // These name an order that already exists, and the action below is a
    // different button entirely — so there is nothing to explain here. Their
    // sentence is [_flowNotice]'s job.
    if (flow.needsDecision ||
        flow.needsReconciliation ||
        flow.canRetryPayment) {
      return null;
    }

    if (!_selection.isComplete) return _addressBlocker();

    // A half-filled billing address is worse than none: the server writes the
    // order, returns 200, re-validates the billing block against these same
    // rules and — on failure — bare-`return`s, so the invoice address is gone
    // with nothing said. Blocking here is the only place it can be caught.
    if (!_billingSameAsDelivery && !_billingSelection.isComplete) {
      return 'Complete the billing address, or switch it back to the delivery '
          'address.';
    }

    if (parcelAsync.hasError) {
      return "We couldn't work out this order's shipping charge. Retry above.";
    }
    if (query == null) return 'Working out shipping charges…';

    if (rates != null) {
      if (rates.isLoading) return 'Checking couriers for ${query.pinCode}…';
      if (rates.hasError) {
        return 'Shipping charges are unavailable right now — try again above.';
      }
      final value = rates.valueOrNull;
      if (value != null && (!value.deliverable || value.isEmpty)) {
        return "We can't deliver to ${query.pinCode}. "
            'Choose a different address to continue.';
      }
    }

    // The state a fresh quote starts in and stays in until the customer taps a
    // row — no longer a momentary gap before a preselection lands, so this is
    // the sentence most customers read on arriving here.
    //
    // Its wording is load-bearing. "Shipping" is this file's noun for the
    // charge, the section and the bill row, but a blocker's job is to name the
    // control that clears it — and that control is captioned "Choose a delivery
    // option" on the cart and at the head of [ShippingSelector]'s list. Three
    // words for one tap is how a disabled button reads as a broken app.
    if (charge == null) return 'Choose a delivery option to continue.';

    // A quoted courier whose row carried no rate id. There is no key to send,
    // and the two keys that look like they would do are both a silent 0.00
    // shipping charge on a real order — so the order is blocked instead. Rare
    // (every capture to date has an `id` on every row) but not impossible, and
    // the failure it prevents is invisible.
    if (optionKey == null) {
      return "This courier can't be booked right now — choose a different "
          'delivery option to continue.';
    }
    return null;
  }

  /// Why the chosen address is not good enough, in its own words.
  ///
  /// [AddressSelection.isComplete] is the full [CheckoutAddressRules] set — the
  /// same rules `CheckoutAddress.violations` refuses on — so it goes false for a
  /// missing state, a landline, a 500-character street line and five other
  /// things besides a bad PIN code. This sentence used to name the PIN code for
  /// every one of them, which told a customer with a state-less saved row to go
  /// and fix something that was not broken. It now reports the rule that
  /// actually failed, read from the same validator the button is gated on.
  String _addressBlocker() {
    final problem = CheckoutAddressRules.firstProblem(
      CheckoutAddressRules.validateJson(
        _selection.effectiveDraft.toCheckoutJson(),
      ),
    );
    // Unreachable — `isComplete` is exactly "this map is empty" — but a
    // disabled button with no explanation is the one outcome worth a fallback.
    if (problem == null) return 'Add a complete delivery address to continue.';
    return _selection.isSaved
        ? '$problem — edit this address to continue.'
        : 'Add a complete delivery address to continue — $problem.';
  }
}

/// One label-and-amount line of a bill, safe at every text size.
///
/// [SummaryRow] for the ordinary case — it is *the* bill line in this app and
/// both the cart and this screen should keep reading like one. But it lays its
/// two halves out as a bare `spaceBetween` `Row` with neither side flexible, so
/// at the largest OS text scale on a 320dp screen `Shipping charged` beside
/// `₹3,500.00` is ~83px wider than the card it sits in, and a `Row` reports that
/// by striping the right-hand end of the line — across the amount, on the two
/// panels whose entire job is to be read carefully before money moves.
///
/// Above the threshold the amount takes its own line instead. The threshold is
/// [shouldStackShippingPrice] — the same rule the courier rows on the cart and
/// in the selector already use — rather than a third opinion about when text has
/// got too big to sit beside something.
///
/// Top-level so the bill and [_TotalDivergenceSheet] share it: the sheet is a
/// restatement of the bill, and the two must not start disagreeing about how a
/// money line reads.
Widget _moneyRow(
  BuildContext context,
  String label,
  String value, {
  bool bold = false,
  bool muted = false,
  Color? valueColor,
  Color? labelColor,
}) {
  if (!shouldStackShippingPrice(context)) {
    return SummaryRow(
      label,
      value,
      bold: bold,
      muted: muted,
      valueColor: valueColor,
      labelColor: labelColor,
    );
  }
  final faint = context.colors.faint;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: (bold ? context.text.title : context.text.bodySm)
              .copyWith(color: labelColor ?? (muted ? faint : null)),
        ),
        Text(
          value,
          style: (bold ? context.text.title : context.text.bodySm)
              .copyWith(color: valueColor ?? (muted ? faint : null)),
        ),
      ],
    ),
  );
}

/// "The server priced this differently — do you still want it?"
///
/// The last thing between a created order and the Razorpay sheet, and the only
/// screen in the app whose job is to *stop* a payment.
///
/// ## Both directions, and neither one silently
///
/// Shipping is priced server-side now, so the total can move either way after
/// the button was tapped:
///
///   * **up** — the server re-quotes Shiprocket from its own `store_zip_code`,
///     which is not the pickup postcode this app quoted with. Charging a card
///     more than the button said, without asking, is the failure this whole
///     slice exists to prevent.
///   * **down** — the delivery line landed at 0.00. Two backend faults do this:
///     the `shipping_option` key missed the server's table, or **Shiprocket was
///     down** when the server re-quoted and `HookServiceProvider.php:63-75`
///     swallowed the exception. Either way it is not a discount and must not
///     read as one: the shipment has no courier metadata, so nobody can dispatch
///     it, and the customer needs to know before they pay for a parcel that will
///     sit still.
///
/// So there is no "it's cheaper, just take it" branch. Both get the same two
/// buttons, and the difference is only in what the panel says about it.
///
/// The 0.00 case is named on its own rather than folded into "you are paying
/// less", because the two are not the same news and the amounts do not have to
/// move together: a server that drops the delivery line and gains the same money
/// elsewhere still produces an undispatchable order, which is why
/// [TotalDivergence.isMaterial] fires on it independently of the arithmetic.
///
/// ## What each answer does
///
/// **Continue** opens the sheet at the *server's* amount — `razorpay.amount` is
/// already that figure in paise, so nothing is recomputed to make it true.
///
/// **Cancel** charges nothing, and that is all it does. The order was created
/// before this sheet could exist, so it stays; the pending-order record stays,
/// because it is the only handle on an order `GET /orders` cannot see; and the
/// basket stays. Saying "your order was cancelled" here would be a lie, and
/// clearing the cart on top of it would leave the customer with neither.
class _TotalDivergenceSheet extends StatelessWidget {
  const _TotalDivergenceSheet({required this.divergence, this.orderId});

  final TotalDivergence divergence;

  /// Named so a customer who cancels can quote it to support. Null only if the
  /// response was unreadable, which is a different flow entirely.
  final int? orderId;

  @override
  Widget build(BuildContext context) {
    final shown = PriceUtils.format(divergence.shown);
    final gap = PriceUtils.format(divergence.difference.abs());
    final up = divergence.isOvercharge;
    // The delivery line vanished. That is the headline whether or not the total
    // moved with it — and it can fail to move, which is exactly when a
    // difference-only panel would have nothing to say.
    final missing = divergence.isShippingMissing;

    return SingleChildScrollView(
      key: const Key('checkout-total-divergence'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.price_change_rounded,
                size: 22,
                color: AppColors.warning,
              ),
              AppSpacing.hSm,
              Expanded(
                child: Text(
                  missing
                      ? 'No delivery charge on this order'
                      : 'Shipping was recalculated',
                  style: context.text.h3,
                ),
              ),
            ],
          ),
          AppSpacing.vSm,
          // The sentence the product decision asked for, verbatim in shape:
          // what it is now, and what you were told.
          Text(
            'Your total is ${divergence.chargedDisplay} — you were shown '
            '$shown.',
            key: const Key('checkout-divergence-headline'),
            style: context.text.body,
          ),
          AppSpacing.vSm,
          AppCard(
            key: const Key('checkout-divergence-figures'),
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                _moneyRow(context, 'You were shown', shown),
                // Both delivery lines when one of them is missing, because
                // "₹0.00" on its own reads as good news and the pair does not.
                if (missing)
                  _moneyRow(
                    context,
                    'Shipping quoted',
                    PriceUtils.format(divergence.shownShipping!),
                  ),
                // The server's own shipping line — the figure the order was
                // really billed for delivery, which is the thing that moved.
                _moneyRow(
                  context,
                  'Shipping charged',
                  divergence.shippingDisplay,
                  valueColor: missing ? AppColors.warning : null,
                ),
                // Suppressed when the total did not actually move — which
                // happens on the missing-shipping path, and "− ₹0.00" under a
                // "Less to pay" label would be gibberish.
                if (up || divergence.isUndercharge)
                  _moneyRow(
                    context,
                    up ? 'More to pay' : 'Less to pay',
                    '${up ? '+' : '−'} $gap',
                    valueColor: up ? AppColors.warning : context.colors.savings,
                  ),
                const Divider(height: 22),
                _moneyRow(
                  context,
                  'Total now',
                  divergence.chargedDisplay,
                  bold: true,
                ),
              ],
            ),
          ),
          AppSpacing.vSm,
          if (missing)
            _noCourier(context)
          else if (divergence.isUndercharge)
            _undercharged(context),
          Text(
            orderId == null
                ? 'Nothing has been charged yet. Your order is saved either way.'
                : 'Nothing has been charged yet. Order $orderId is saved either '
                    'way.',
            style: context.text.caption,
          ),
          AppSpacing.vSm,
          ElevatedButton(
            key: const Key('checkout-divergence-continue'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Continue and pay ${divergence.chargedDisplay}'),
          ),
          TextButton(
            key: const Key('checkout-divergence-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text("Cancel — don't pay now"),
          ),
        ],
      ),
    );
  }

  /// The low total is a fault, not a bargain. Says so.
  Widget _undercharged(BuildContext context) => _warning(
        context,
        key: const Key('checkout-divergence-undercharge'),
        message: 'This is less than we quoted because the delivery charge did '
            'not reach your order. We may not be able to dispatch it '
            'until that is corrected, so please tell us before you '
            'continue.',
      );

  /// **No courier is attached to this order.** The specific case, in its own
  /// words.
  ///
  /// Deliberately not phrased as a saving of any size. The order was billed
  /// ₹0.00 for delivery on a parcel a courier had already priced, which means
  /// the shipment carries no courier metadata — nobody in the warehouse can
  /// dispatch it, whatever the customer pays. Naming both figures is what stops
  /// it reading as a discount.
  Widget _noCourier(BuildContext context) => _warning(
        context,
        key: const Key('checkout-divergence-no-courier'),
        message: 'Your order was billed '
            '${divergence.shippingDisplay} for delivery, but this parcel was '
            'quoted ${PriceUtils.format(divergence.shownShipping!)}. That '
            'means no courier was attached to it, so we will not be able to '
            'dispatch it until we fix that. It is not a discount — please tell '
            'us before you continue.',
      );

  Widget _warning(
    BuildContext context, {
    required Key key,
    required String message,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.08),
            borderRadius: AppRadius.rMd,
            border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: AppColors.warning,
              ),
              AppSpacing.hSm,
              Expanded(
                child: Text(key: key, message, style: context.text.bodySm),
              ),
            ],
          ),
        ),
      );
}

/// The cart is being weighed so it can be quoted.
///
/// Shaped like the selector's own panel so the block does not jump when the
/// real thing replaces it.
class _ParcelLoading extends StatelessWidget {
  const _ParcelLoading();

  @override
  Widget build(BuildContext context) => AppCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: context.colors.muted,
              ),
            ),
            AppSpacing.hSm,
            Expanded(
              child: Text(
                'Working out what your parcel weighs…',
                style: context.text.bodySm,
              ),
            ),
          ],
        ),
      );
}

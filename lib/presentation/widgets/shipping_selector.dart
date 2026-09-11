import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../core/errors/error_presenter.dart';
import '../../data/models/shipping_quote.dart';
import '../providers/shipping_provider.dart';
import 'skeletons.dart';
import 'surfaces.dart';

/// The shipping-option list, the read-only confirmation of what it produced,
/// and the bill line that follows from both.
///
/// This is the mobile version of the web's checkout shipping block: the site
/// runs the `handle_shipping_fee` filter, gets Shiprocket's courier list back
/// and renders it as radio options whose selection becomes the order's shipping
/// method and amount. The customer must be able to see, and choose, the same
/// thing here — including the part where **none of them starts selected**.
/// `shipping-methods.blade.php` renders a radio per courier and waits; so does
/// this.
///
/// The choice is made **once**, on the cart, and every other surface reads it
/// back out of `shippingChoiceProvider`:
///
///   * [ShippingSelector] — the list. The cart's own compact version writes to
///     the same store, so whichever screen the customer chose on, one courier is
///     in effect.
///   * [ShippingSection] — checkout's block. Confirms the courier already chosen
///     and offers a way back to the list, rather than asking the same question a
///     second time with the answer already given.
///   * [ShippingBillLine] — the money.
///
/// ## Wording
///
/// "Shipping" is the charge and the method; "Delivery" is the date. So the panel
/// is *Shipping options*, the bill row is *Shipping*, and the estimate stays
/// `Delivery by 06 Aug` — "Shipping by 06 Aug" is not a thing anyone says.

/// True when a courier's name and its price can no longer share a line.
///
/// At the largest OS text scale `₹1,288.56` is wider than the space a 320dp
/// screen leaves beside a radio button, so a `Row` puts the price where the
/// courier's name should be and reports the difference as an overflow stripe —
/// which is how the customer at the accessibility text size became the one
/// customer who could not read which courier they were being charged for.
/// Above this threshold the price takes its own line instead.
///
/// Shared with the cart's compact rows in `delivery_location_bar.dart` so the
/// two surfaces cannot break at different sizes.
bool shouldStackShippingPrice(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(14) > 19;

// ---------------------------------------------------------------------------
// Selector
// ---------------------------------------------------------------------------

/// Fetches and lists the couriers that can carry the cart to [query]'s pincode.
///
/// Pass a null [query] before an address has been chosen — the widget then shows
/// its idle prompt instead of a spinner that never resolves.
class ShippingSelector extends ConsumerWidget {
  const ShippingSelector({super.key, this.query, this.onChanged});

  /// Null until the customer has picked an address, or while the pincode they
  /// are typing is still incomplete.
  final ShippingQuery? query;

  /// Fires whenever the courier in effect for [query] changes — which now only
  /// ever happens because a customer tapped a row, or because a re-quote
  /// re-priced or dropped the row they tapped.
  ///
  /// It does **not** fire with a courier when the list arrives: nothing is
  /// preselected, so the first value a fresh query reports is null. A caller
  /// that treats "the rates landed" as "a courier was chosen" will read this
  /// wrong.
  final ValueChanged<CourierOption?>? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = this.query;

    if (query == null || !query.hasValidPinCode) {
      return const _ShippingPanel(child: _ShippingIdle());
    }

    // The callback has to fire outside build. `ref.listen` on the derived
    // selection covers the customer's tap and every later re-resolution of it
    // (a re-quote that re-prices the row, or drops it) with one subscription.
    if (onChanged != null) {
      ref.listen<CourierOption?>(
        selectedShippingProvider(query),
        (_, next) => onChanged!(next),
      );
    }

    final rates = ref.watch(courierOptionsProvider(query));

    return _ShippingPanel(
      child: rates.when(
        loading: () => const _ShippingSkeleton(),
        error: (error, _) => _ShippingError(
          error: error,
          onRetry: () => ref.invalidate(courierOptionsProvider(query)),
        ),
        data: (rates) {
          if (!rates.deliverable || rates.isEmpty) {
            return _NotDeliverable(
              pinCode: query.pinCode,
              message: rates.message,
            );
          }
          return _CourierOptionList(
            query: query,
            options: rates.options,
            selected: ref.watch(selectedShippingProvider(query)),
            onSelect: (option) =>
                ref.read(shippingChoiceProvider.notifier).select(query, option),
          );
        },
      ),
    );
  }
}

/// The card every state of the selector sits in, so the block does not change
/// size or shape as it loads — which is what makes a skeleton read as "loading"
/// rather than as a layout glitch.
class _ShippingPanel extends StatelessWidget {
  const _ShippingPanel({
    required this.child,
    super.key,
    this.title = 'Shipping options',
    this.trailing,
  });

  final Widget child;

  /// "Shipping options" while there is a choice to make; "Shipping" once it has
  /// been made and this is a confirmation.
  final String title;

  /// The header's action, if any — [ShippingSection]'s Change button.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => AppCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.local_shipping_rounded,
                  size: 18,
                  color: context.colors.muted,
                ),
                AppSpacing.hSm,
                Expanded(child: Text(title, style: context.text.h3)),
                if (trailing != null) trailing!,
              ],
            ),
            AppSpacing.vSm,
            child,
          ],
        ),
      );
}

// ---------------------------------------------------------------------------
// Checkout's block: confirm, don't re-ask
// ---------------------------------------------------------------------------

/// The courier already chosen, read-only, with a way back to the list.
///
/// Checkout used to render the full [ShippingSelector], which put the same four
/// radio rows in front of the customer a second time — once on the cart, once
/// here. Offering a choice twice is not reassurance, it is a second chance to
/// answer differently, and the screen that shows the *total* is the wrong place
/// to reopen the question. So this confirms: courier, delivery date, charge.
///
/// Two things keep it from being a trap:
///
///   * **Change** reopens the real list in a modal sheet
///     ([showShippingOptionsSheet]) — the confirmation is read-only, not final.
///   * When nothing has been chosen *for this exact parcel-and-pincode* it falls
///     through to the selector itself. That is not a rare path: a customer can
///     open `/checkout` without ever seeing the cart, and changing the address
///     here retires the cart's choice because the rate it named was quoted for
///     the other destination.
class ShippingSection extends ConsumerWidget {
  const ShippingSection({super.key, this.query});

  /// Null until there is an address with a usable pincode.
  final ShippingQuery? query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = this.query;
    if (query == null || !query.hasValidPinCode) {
      return const ShippingSelector();
    }

    final confirmed = _confirmedCourier(ref, query);
    // No standing choice, or one that no longer resolves — ask, rather than
    // confirming something the customer never picked.
    if (confirmed == null) return ShippingSelector(query: query);

    return _ShippingPanel(
      key: const Key('checkout-shipping-summary'),
      title: 'Shipping',
      trailing: TextButton(
        key: const Key('checkout-shipping-change'),
        onPressed: () => showShippingOptionsSheet(context, query),
        style: TextButton.styleFrom(minimumSize: const Size(64, 44)),
        child: const Text('Change'),
      ),
      child: _ChosenShipping(query: query, option: confirmed),
    );
  }
}

/// The courier the customer actually picked for [query], at today's price.
///
/// `selectedShippingProvider` alone would now answer this — it is null until a
/// tap lands and resolves the pin against the live list — so the extra
/// [ShippingChoice] read here is belt and braces rather than the load-bearing
/// half it once was. It stays because the two must agree before checkout swaps
/// a list for a summary: reading both is what makes "checkout is confirming
/// something" and "the customer chose something" the same statement, and it is
/// the assertion that would fail loudly if a default pick were ever
/// reintroduced upstream.
///
/// Both halves matter. The stored [ShippingChoice] carries the query it was made
/// for, so a cart choice cannot survive a different address; and it is re-resolved
/// against the list that is live *now*, so a courier that has since dropped out
/// reopens the list rather than confirming a rate nobody can honour.
CourierOption? _confirmedCourier(WidgetRef ref, ShippingQuery query) {
  final choice = ref.watch(shippingChoiceProvider);
  if (choice == null || choice.query != query) return null;

  final live = ref.watch(selectedShippingProvider(query));
  if (live == null || live.courierCompanyId != choice.option.courierCompanyId) {
    return null;
  }
  return live;
}

/// The confirmation body: date, courier, charge — and where it is going.
///
/// Carries no cash-on-delivery wording, for the reason spelled out on
/// [_CourierOptionTile].
class _ChosenShipping extends StatelessWidget {
  const _ChosenShipping({required this.query, required this.option});

  final ShippingQuery query;
  final CourierOption option;

  @override
  Widget build(BuildContext context) {
    final eta = option.etaLabel;
    final stacked = shouldStackShippingPrice(context);
    final price = Text(option.billedPriceFormatted, style: context.text.price);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The date leads here for the same reason it leads each row of the
        // list: it is the thing being bought.
        if (eta != null) ...[
          Row(
            children: [
              const Icon(
                Icons.event_available_rounded,
                size: 18,
                color: AppColors.primary,
              ),
              AppSpacing.hSm,
              Expanded(
                child: Text(
                  eta,
                  style: context.text.title.copyWith(
                    color: context.colors.primaryDark,
                  ),
                ),
              ),
            ],
          ),
          AppSpacing.vXs,
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(option.courierName, style: context.text.body),
                  AppSpacing.gapXxs,
                  Text(
                    'Delivering to ${query.pinCode}',
                    style: context.text.caption,
                  ),
                  // At the largest text scale the price alone is wider than the
                  // room left beside the courier it belongs to, so it takes its
                  // own line rather than eliding the name it is charging for.
                  if (stacked) ...[AppSpacing.gapXxs, price],
                ],
              ),
            ),
            if (!stacked) ...[AppSpacing.hSm, price],
          ],
        ),
        // Nothing about cash on delivery is shown here. See the note on
        // [_CourierOptionTile].
      ],
    );
  }
}

/// The full courier list, as a modal sheet.
///
/// The way back from [ShippingSection]'s confirmation. A sheet rather than an
/// inline expansion because checkout's job is the total: the list is an
/// occasional detour, and putting it back on the page permanently is exactly the
/// duplication the confirmation exists to remove.
Future<void> showShippingOptionsSheet(
  BuildContext context,
  ShippingQuery query,
) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _ShippingOptionsSheet(query: query),
    );

class _ShippingOptionsSheet extends ConsumerWidget {
  const _ShippingOptionsSheet({required this.query});

  final ShippingQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Closed by the *choice*, not by `ShippingSelector.onChanged`: that callback
    // also fires when a re-quote re-prices or drops the standing pin, so a sheet
    // opened over a list that happened to refresh would slam shut on its own.
    // `shippingChoiceProvider` only ever moves when a person taps a row.
    ref.listen<ShippingChoice?>(shippingChoiceProvider, (_, __) {
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    });

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: ShippingSelector(query: query),
    );
  }
}

// ---------------------------------------------------------------------------
// States
// ---------------------------------------------------------------------------

/// No address yet. Says what is missing rather than showing an empty list.
class _ShippingIdle extends StatelessWidget {
  const _ShippingIdle();

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.pin_drop_rounded,
            size: 20,
            color: context.colors.faint,
          ),
          AppSpacing.hSm,
          Expanded(
            child: Text(
              'Choose a delivery address to see courier options and charges.',
              style: context.text.bodySm,
            ),
          ),
        ],
      );
}

/// Placeholder rows shaped like the real ones.
///
/// A bare spinner here was indistinguishable from the not-deliverable state,
/// which is the single most important thing this widget has to communicate.
class _ShippingSkeleton extends StatelessWidget {
  const _ShippingSkeleton();

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SkeletonBox(height: 14, width: 150),
          AppSpacing.vSm,
          for (var i = 0; i < 3; i++)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.xs),
              child: SkeletonBox(height: 56),
            ),
          AppSpacing.vXs,
          Row(
            children: [
              SizedBox(
                height: 12,
                width: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.colors.muted,
                ),
              ),
              AppSpacing.hSm,
              // Expanded, not a bare Text — the same fix the cart's `_Checking`
              // row already carries. At the largest OS text scale this line is
              // wider than the panel has room for on a 320dp screen, and the Row
              // reported it as a 120px overflow: a black-and-yellow stripe over
              // the state *every* customer passes through while the quote is in
              // flight, on the one screen that is meant to reassure them.
              Expanded(
                child: Text('Checking couriers…', style: context.text.caption),
              ),
            ],
          ),
        ],
      );
}

/// The quote failed. Distinct from "nobody delivers there" — this one is worth
/// retrying, and the retry is right here.
class _ShippingError extends StatelessWidget {
  const _ShippingError({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final e = ErrorPresenter.resolve(error);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 20,
              color: AppColors.error,
            ),
            AppSpacing.hSm,
            Expanded(
              child: Text(
                "Couldn't fetch shipping charges — ${e.message}",
                style: context.text.bodySm,
              ),
            ),
          ],
        ),
        AppSpacing.vSm,
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Try again'),
        ),
      ],
    );
  }
}

/// Nothing ships to this pincode.
///
/// Given its own loud treatment on purpose. This is the answer the feature
/// exists to deliver, and the failure mode it replaces — a silent empty list —
/// let customers carry on to payment for an order that could never be
/// dispatched.
class _NotDeliverable extends StatelessWidget {
  const _NotDeliverable({required this.pinCode, this.message});

  final String pinCode;
  final String? message;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.error.withValues(alpha: 0.08),
          borderRadius: AppRadius.rMd,
          border: Border.all(color: AppColors.error.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.block_rounded,
                  size: 20,
                  color: AppColors.error,
                ),
                AppSpacing.hSm,
                Expanded(
                  child: Text(
                    "We can't deliver to $pinCode",
                    style: context.text.title.copyWith(color: AppColors.error),
                  ),
                ),
              ],
            ),
            AppSpacing.vXs,
            Text(
              message?.trim().isNotEmpty == true
                  ? message!
                  : 'No courier services this pincode. Try a different '
                      'delivery address to continue.',
              style: context.text.bodySm,
            ),
            AppSpacing.vXs,
            Text(
              'This order cannot be placed for this pincode.',
              style: context.text.caption.copyWith(color: AppColors.error),
            ),
          ],
        ),
      );
}

// ---------------------------------------------------------------------------
// The list itself
// ---------------------------------------------------------------------------

class _CourierOptionList extends StatelessWidget {
  const _CourierOptionList({
    required this.query,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  final ShippingQuery query;
  final List<CourierOption> options;
  final CourierOption? selected;
  final ValueChanged<CourierOption> onSelect;

  @override
  Widget build(BuildContext context) {
    final headline = selected?.etaLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Nothing picked yet — which is where every quote starts and where it
        // stays until a tap. The panel says so in the *same words the cart's
        // prompt uses and the blocker above the button quotes back*, so the
        // sentence "Choose a delivery option to continue" points at something
        // the customer can actually see and hit.
        if (selected == null) ...[
          Row(
            children: [
              const Icon(
                Icons.touch_app_rounded,
                size: 18,
                color: AppColors.primary,
              ),
              AppSpacing.hSm,
              Expanded(
                child: Text(
                  'Choose a delivery option',
                  key: const Key('checkout-choose-delivery'),
                  style: context.text.title.copyWith(
                    color: context.colors.primaryDark,
                  ),
                ),
              ),
            ],
          ),
          AppSpacing.vXs,
        ]
        // The date, not the courier, is what the customer is buying. It leads.
        else if (headline != null) ...[
          Row(
            children: [
              const Icon(
                Icons.event_available_rounded,
                size: 18,
                color: AppColors.primary,
              ),
              AppSpacing.hSm,
              Expanded(
                child: Text(
                  headline,
                  style: context.text.title.copyWith(
                    color: context.colors.primaryDark,
                  ),
                ),
              ),
            ],
          ),
          AppSpacing.vXs,
        ],
        Text(
          'Delivering to ${query.pinCode}',
          style: context.text.caption,
        ),
        AppSpacing.vSm,
        // One group for the whole list, so exactly one courier can be in effect
        // and screen readers announce the rows as the choice they are.
        RadioGroup<int>(
          groupValue: selected?.courierCompanyId,
          onChanged: (id) {
            for (final option in options) {
              if (option.courierCompanyId == id) onSelect(option);
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final option in options)
                _CourierOptionTile(
                  option: option,
                  selected: option == selected,
                  onTap: () => onSelect(option),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One courier row: radio, ETA, name, price.
///
/// ## No cash-on-delivery wording, deliberately
///
/// This build takes payment through Razorpay and nothing else: the checkout
/// body hardcodes `payment_method: "razorpay"`, COD is disabled server-side,
/// and its API path 500s *after* the order row has already been committed. So
/// there is no COD to opt into on any courier.
///
/// The rows used to carry Shiprocket's `cod` flag through as
/// "Prepaid only — no cash on delivery" on the couriers that answered `cod: 0`,
/// and "Includes ₹x cash-on-delivery fee" on the ones that answered `cod: 1`
/// with a surcharge. Both sentences say the same untrue thing: that COD is a
/// choice the customer has, and that picking a different courier would give it
/// to them. Neither is shown. (`cod_charges` was never billable here either —
/// the quote is requested with `cod: 0`, so upstream returns 0 for it.)
class _CourierOptionTile extends StatelessWidget {
  const _CourierOptionTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final CourierOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final eta = option.etaLabel;
    // At 320dp and the largest OS text scale this Row overflowed by 1.8px with
    // the price laid out beside the courier — and the 1.8px was the *visible*
    // symptom; the real cost is that the Expanded column holding the estimate
    // and the courier name had been squeezed to nothing to make room. The cart's
    // compact tile has always stacked here; checkout's never did.
    final stacked = shouldStackShippingPrice(context);
    final price = Text(option.billedPriceFormatted, style: context.text.price);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      // Without this the radio is its own semantics node and the ETA, courier
      // name and price are three more beside it — so a screen reader announces
      // "radio button, not selected" with no name, and the customer has to
      // reassemble which price belongs to which control. Merged, each row reads
      // as one labelled, selectable option, which is what it is.
      child: MergeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.rMd,
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.xs),
            decoration: BoxDecoration(
              color: selected ? context.colors.primarySoft : null,
              borderRadius: AppRadius.rMd,
              border: Border.all(
                color: selected ? AppColors.primary : context.colors.line,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // The radio reads its state from the enclosing RadioGroup; the
                // whole row is the tap target, because the control alone is a
                // 20px hit area on a checkout screen.
                Radio<int>(
                  value: option.courierCompanyId,
                  activeColor: AppColors.primary,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                AppSpacing.hXs,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The estimate is the headline and the courier is the
                      // footnote — unless upstream gave no estimate, in which case
                      // the courier is all there is to show.
                      Text(
                        eta ?? option.courierName,
                        style: context.text.title,
                      ),
                      if (eta != null) ...[
                        AppSpacing.gapXxs,
                        Text(option.courierName, style: context.text.caption),
                      ],
                      if (stacked) ...[AppSpacing.gapXxs, price],
                    ],
                  ),
                ),
                if (!stacked) ...[AppSpacing.hSm, price],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bill line
// ---------------------------------------------------------------------------

/// The Shipping line for a bill, read-only.
///
/// Replaces the hardcoded `FREE` in checkout's Bill details. Shows the chosen
/// courier under the label so the bill and the selector cannot disagree about
/// which quote is being charged, and admits when there is no quote yet instead
/// of printing a zero.
class ShippingBillLine extends ConsumerWidget {
  const ShippingBillLine({super.key, this.query, this.label = 'Shipping'});

  final ShippingQuery? query;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = this.query;
    final option = query == null || !query.hasValidPinCode
        ? null
        : ref.watch(selectedShippingProvider(query));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: context.text.body),
                if (option != null)
                  Text(option.courierName, style: context.text.caption),
              ],
            ),
          ),
          AppSpacing.hSm,
          Text(
            option?.billedPriceFormatted ?? '—',
            style: context.text.title.copyWith(
              color: option == null ? context.colors.faint : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// One-line recap of the chosen courier, for a confirmation step or a collapsed
/// checkout section. Read-only by design — changing the courier belongs to
/// [ShippingSelector].
class ShippingChoiceSummary extends ConsumerWidget {
  const ShippingChoiceSummary({super.key, this.query});

  final ShippingQuery? query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = this.query;
    final option = query == null || !query.hasValidPinCode
        ? null
        : ref.watch(selectedShippingProvider(query));

    if (option == null) {
      return Text('No shipping option selected', style: context.text.bodySm);
    }

    final eta = option.etaLabel;
    return Row(
      children: [
        const Icon(
          Icons.local_shipping_rounded,
          size: 18,
          color: AppColors.primary,
        ),
        AppSpacing.hSm,
        Expanded(
          child: Text(
            eta == null ? option.courierName : '$eta · ${option.courierName}',
            style: context.text.bodySm,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        AppSpacing.hSm,
        Text(option.billedPriceFormatted, style: context.text.title),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_icons.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../core/errors/error_presenter.dart';
import '../../data/models/shipping_quote.dart';
import '../providers/address_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/checkout_provider.dart';
import '../providers/delivery_location_provider.dart';
import '../providers/shipping_provider.dart';
import 'address_choose_sheet.dart';
import 'shipping_selector.dart';
import 'skeletons.dart';
import 'state_views.dart';
import 'surfaces.dart';

/// The cart's shipping card: where this order is going, and what each courier
/// charges to take it there.
///
/// Put this on the cart so the customer sees — and *chooses* — the real total
/// before checkout. The cart previously ended at a subtotal and a "shipping
/// calculated at checkout" note, which is honest but leaves the final amount a
/// surprise, and a late shipping reveal is the most common reason a basket is
/// abandoned.
///
/// ## Why the destination is an address and not a typed pincode
///
/// This card used to open a sheet with a "Delivery pincode" field sitting above
/// the customer's own saved addresses. Two controls, one question. They could
/// disagree — type 382415, check out to an address in 474010, and the cart's
/// "To pay" was a figure nobody would be charged — and the pincode was asked for
/// twice in one flow. The field is gone; the card now chooses a saved address
/// through [showAddressChooseSheet], the *same* sheet checkout's address picker
/// opens, and the pincode is read off the row.
///
/// That is a real trade-off, taken deliberately: `GET /ecommerce/addresses` is
/// bearer-only, so a **signed-out** customer has no book to choose from and
/// therefore sees no shipping quote on the cart. The card says so and offers
/// signing in; the cart stays usable and the bill says "Subtotal" rather than
/// inventing a charge.
///
/// ## Why the cart chooses the courier and not just displays one
///
/// The card used to print the *best* courier's charge as a flat line. That was a
/// quote the customer never agreed to: checkout offers the full list, so the
/// moment they picked anything other than the fastest option the two screens
/// showed two different "To pay" figures for one order. Selecting here writes to
/// [shippingChoiceProvider], the same store [ShippingSelector] writes to, so
/// there is exactly one courier in effect for a given parcel-and-pincode no
/// matter which screen chose it — see the note in `cartDeliveryChargeProvider`.
///
/// ## And why it chooses nothing at all until asked
///
/// Even after the list moved here, the card still *collapsed onto*
/// `options.first` and drew it as a decision — courier, date and price — while
/// the bill below it correctly showed no shipping line, because
/// `shippingChoiceProvider` was empty. One of the two was lying. The web
/// checkout preselects nothing (`shipping-methods.blade.php` renders a radio per
/// courier and waits), and preselecting the fastest here put Blue Dart Air at
/// ₹1,284.15 in front of a customer whose other option was Xpressbees Surface at
/// ₹324.30 two days later. So: no selection until a tap, the list opens by
/// default so the tap is one gesture away, the summary row asks the question
/// instead of answering it, and the total stays "Subtotal" until it is real.
///
/// ## The cost of that, and why the list is answered *here*
///
/// Removing the preselection reintroduces the complaint this card was built to
/// answer: a cart that never states a final amount. The resolution is not to
/// choose for the customer again — it is to put the choice where they already
/// are. The list is open by default and sits directly above the bill, so
/// completing the total is one tap on the screen they are already looking at,
/// not a navigation into checkout and a sheet. [_ChooseRow] is deliberately
/// loud about that: it is the only element on the cart standing between a
/// subtotal and a total.
class DeliveryLocationBar extends ConsumerStatefulWidget {
  const DeliveryLocationBar({super.key, this.onSignInRequested});

  /// What the "Sign in" affordance does. Defaults to pushing `/login`.
  final VoidCallback? onSignInRequested;

  @override
  ConsumerState<DeliveryLocationBar> createState() =>
      _DeliveryLocationBarState();
}

class _DeliveryLocationBarState extends ConsumerState<DeliveryLocationBar> {
  @override
  Widget build(BuildContext context) {
    // `isAuthenticatedProvider` rather than `authProvider`: this only needs the
    // flag, and reading the notifier would construct the auth session (and its
    // token-refresh call) for a card that just wants to know whether there is a
    // book to read.
    final signedIn = ref.watch(isAuthenticatedProvider);
    final location = ref.watch(deliveryLocationProvider);

    if (!signedIn) {
      // The stored destination belongs to the account that chose it. Leaving it
      // on screen after a sign-out would name one customer's address to the
      // next, and would keep quoting shipping for a book this session cannot
      // read.
      if (location != null) _after(() => _notifier.clear());
      return _SignInCard(onSignIn: _signIn);
    }

    final book = ref.watch(addressBookProvider);
    // Watching the notifier keeps the autoDispose book alive while the pushed
    // add-address form writes to it, so the post-write re-read cannot be
    // cancelled halfway.
    ref.watch(addressBookProvider.notifier);

    // Reconcile only against a read that actually succeeded. A failed GET is not
    // evidence that the chosen address was deleted, and clearing on it would
    // drop the destination — and the quote — every time the network hiccuped.
    if (!book.loading && book.error == null) {
      _after(() => _notifier.syncWith(book.addresses));
    }

    if (location == null) return _unchosen(context, book);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(AppIcons.mapPin, color: AppColors.teal, size: 22),
              ),
              AppSpacing.hSm,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Shipping to', style: context.text.caption),
                    Text(
                      location.display,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.title,
                    ),
                    if (location.line.trim().isNotEmpty)
                      Text(
                        location.line,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.caption,
                      ),
                  ],
                ),
              ),
              AppSpacing.hXs,
              TextButton(
                key: const Key('cart-address-change'),
                onPressed: _openChooser,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                ),
                child: const Text('Change'),
              ),
            ],
          ),
          Divider(height: AppSpacing.sm, color: context.colors.hairline),
          AppSpacing.vXs,
          _DeliveryOptions(pinCode: location.pinCode),
        ],
      ),
    );
  }

  DeliveryLocationNotifier get _notifier =>
      ref.read(deliveryLocationProvider.notifier);

  /// Runs a provider write after this frame.
  ///
  /// Reached from `build`, so it cannot happen synchronously: mutating a
  /// provider mid-build is what makes Riverpod throw, and every write here is a
  /// no-op when it changes nothing, so this settles after one extra frame rather
  /// than looping.
  void _after(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) action();
    });
  }

  /// Signed in, but nothing to ship to yet.
  ///
  /// Four different reasons, and they are not interchangeable — "we are still
  /// reading your addresses" and "you have none" would be the same grey card
  /// otherwise.
  Widget _unchosen(BuildContext context, AddressBookState book) {
    if (book.loading && book.addresses.isEmpty) return const _CardSkeleton();

    if (book.error != null && book.addresses.isEmpty) {
      return AppCard(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InlineErrorStrip(
              error: book.error,
              label: 'your saved addresses',
              onRetry: ref.read(addressBookProvider.notifier).load,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                0,
                AppSpacing.sm,
                AppSpacing.xs,
              ),
              child: Text(
                'Shipping is quoted for a saved address, so the total below is '
                'the subtotal only.',
                style: context.text.caption,
              ),
            ),
          ],
        ),
      );
    }

    final empty = book.addresses.isEmpty;
    return AppCard(
      key: const Key('cart-address-unchosen'),
      onTap: empty ? () => addDeliveryAddress(context, ref) : _openChooser,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _kTapTarget),
        child: Row(
          children: [
            Icon(AppIcons.mapPin, color: AppColors.teal, size: 24),
            AppSpacing.hSm,
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    empty
                        ? 'Add a shipping address'
                        : 'Choose a shipping address',
                    style: context.text.title,
                  ),
                  Text(
                    'See shipping charges and your final total',
                    style: context.text.caption,
                  ),
                ],
              ),
            ),
            Icon(AppIcons.caretRight, color: context.colors.faint, size: 16),
          ],
        ),
      ),
    );
  }

  void _signIn() {
    final custom = widget.onSignInRequested;
    if (custom != null) {
      custom();
      return;
    }
    context.push('/login');
  }

  /// Opens the shared address chooser and acts on what it reports.
  ///
  /// Delegated to [chooseDeliveryAddress] so this card and the home header
  /// behave identically. This file used to own the whole flow — the id-diff
  /// that finds a just-created row, the PIN-code warning — and a second
  /// hand-written copy on the header is how two surfaces start disagreeing.
  Future<void> _openChooser() => chooseDeliveryAddress(
        context,
        ref,
        onSignInRequested: widget.onSignInRequested,
      );
}

/// Material's own minimum touch target, and this file's floor for every row a
/// customer is expected to hit.
const double _kTapTarget = 48;

/// True when a courier name and its price can no longer share a line.
///
/// At the largest OS text scale `₹180.60` is ~170dp wide, and on a 320dp screen
/// the card has 262dp of usable width. Laid out as one row that leaves the
/// headline about 36dp — i.e. `D…` — so the customer at the accessibility text
/// size is the one customer who cannot read which courier they are being
/// charged for. Above this threshold the price moves onto its own line instead.
///
/// The rule itself now lives with the checkout selector, which needed the same
/// treatment and did not have it: two copies of this threshold is two sizes at
/// which the cart and checkout start disagreeing about how a courier row reads.
bool _stackPrice(BuildContext context) => shouldStackShippingPrice(context);

// ---------------------------------------------------------------------------
// Signed out
// ---------------------------------------------------------------------------

/// The signed-out card — an offer, never a wall.
///
/// The cart stays fully usable behind it: the bill shows a subtotal, and nothing
/// invents a shipping charge for a destination the app cannot know. Removing the
/// typed-pincode escape hatch is what makes this card necessary, and it is the
/// one place a signed-out customer is told why no shipping figure is on screen.
class _SignInCard extends StatelessWidget {
  const _SignInCard({required this.onSignIn});

  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) => AppCard(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _kTapTarget),
          child: Row(
            children: [
              Icon(AppIcons.mapPin, color: AppColors.teal, size: 24),
              AppSpacing.hSm,
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sign in to choose a delivery address',
                      style: context.text.title,
                    ),
                    Text(
                      'Shipping is quoted for your address, so the total below '
                      'is the subtotal only.',
                      style: context.text.caption,
                    ),
                  ],
                ),
              ),
              AppSpacing.hXs,
              TextButton(
                key: const Key('cart-address-signin'),
                onPressed: onSignIn,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                ),
                child: const Text('Sign in'),
              ),
            ],
          ),
        ),
      );
}

/// Placeholder while the address book is being read for the first time, shaped
/// like the card it replaces.
class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            SkeletonBox(height: 12, width: 80, radius: AppRadius.sm),
            AppSpacing.vXs,
            SkeletonBox(height: 14, width: 140, radius: AppRadius.sm),
            AppSpacing.vXs,
            SkeletonBox(height: 12, radius: AppRadius.sm),
          ],
        ),
      );
}

// ---------------------------------------------------------------------------
// The options block
// ---------------------------------------------------------------------------

/// The courier options for this basket at [pinCode] — the same quote checkout
/// reads, rendered small enough to live on a cart card.
///
/// Four outcomes reach the customer and none of them may be mistaken for
/// another:
///
///   * **in flight** — "Checking shipping…", with no number on screen;
///   * **failed** — an error and a Retry, because this one is worth retrying;
///   * **undeliverable** — a refusal, never a `₹0` and never a "FREE";
///   * **quoted** — the open list under a prompt, until a row is tapped; then
///     the courier that was chosen, with the rest one tap away. Never a courier
///     nobody chose, and never a price before there is a choice to price.
///
/// The parcel is part of the first three: `check-serviceability` prices a
/// shipment, so weighing the cart is a leg of the same journey as fetching the
/// rates and its loading/failure states belong to the same four.
class _DeliveryOptions extends ConsumerStatefulWidget {
  const _DeliveryOptions({required this.pinCode});

  final String pinCode;

  @override
  ConsumerState<_DeliveryOptions> createState() => _DeliveryOptionsState();
}

class _DeliveryOptionsState extends ConsumerState<_DeliveryOptions> {
  /// The query whose list is currently open, or null when collapsed.
  ///
  /// Stored as the *query* rather than a bool so that changing the address or
  /// the basket closes the list: the rows would be re-fetched underneath an
  /// expansion the customer opened for a different quote.
  ShippingQuery? _expandedFor;

  @override
  Widget build(BuildContext context) {
    final parcelAsync = ref.watch(checkoutParcelProvider);

    return parcelAsync.when(
      loading: () => const _Checking(),
      error: (error, _) => _QuoteFailed(
        error: error,
        onRetry: () => ref.invalidate(checkoutParcelProvider),
      ),
      data: (parcel) {
        final query = parcel.toQuery(widget.pinCode);
        // `DeliveryLocationNotifier` validates before it stores, so this is
        // unreachable in practice — but spending a request the endpoint answers
        // with `400 Please enter a valid 6-digit pin code` never helps anyone.
        if (!query.hasValidPinCode) return const SizedBox.shrink();

        final rates = ref.watch(courierOptionsProvider(query));

        return rates.when(
          loading: () => const _Checking(),
          error: (error, _) => _QuoteFailed(
            error: error,
            onRetry: () => ref.invalidate(courierOptionsProvider(query)),
          ),
          data: (rates) {
            if (!rates.deliverable || rates.isEmpty) {
              return _NotDeliverable(
                pinCode: widget.pinCode,
                message: rates.message,
              );
            }
            return _OptionList(
              options: rates.options,
              // Null until the customer taps. It used to fall back to
              // `rates.options.first`, which drew a collapsed row naming a
              // courier, a date and a price for a delivery nobody had agreed
              // to — beside a bill that (correctly) showed no shipping line at
              // all. One of the two had to be lying; it was this one.
              selected: ref.watch(selectedShippingProvider(query)),
              expanded: _expandedFor == query,
              unweighedLines:
                  parcel.isWeightKnown ? 0 : parcel.unweighedLines,
              onToggle: () => setState(
                () => _expandedFor = _expandedFor == query ? null : query,
              ),
              onSelect: (option) {
                // The one line that keeps the cart and checkout honest: both
                // read `selectedShippingProvider`, which reads this.
                ref.read(shippingChoiceProvider.notifier).select(query, option);
                // Picking is the end of the interaction, so the block folds
                // back to one row rather than leaving a list open behind the
                // bill.
                setState(() => _expandedFor = null);
              },
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// States
// ---------------------------------------------------------------------------

/// The quote is in flight. Deliberately carries no price and no shape that
/// could be read as an answer.
class _Checking extends StatelessWidget {
  const _Checking();

  @override
  Widget build(BuildContext context) => Row(
        children: [
          SizedBox(
            height: 14,
            width: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: context.colors.muted,
            ),
          ),
          AppSpacing.hSm,
          // Expanded, not a bare Text: at the largest OS text scale this line
          // is ~350dp wide and the card has 262dp on a 320dp screen, which the
          // Row reported as a 114px overflow — over the state every customer
          // passes through while the quote is in flight.
          Expanded(
            child: Text('Checking shipping…', style: context.text.caption),
          ),
        ],
      );
}

/// The request failed — which is *not* "nobody delivers there". This one is the
/// app's problem, so it says so and offers the retry inline.
class _QuoteFailed extends StatelessWidget {
  const _QuoteFailed({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final e = ErrorPresenter.resolve(error);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(AppIcons.cloudOff, size: 18, color: AppColors.error),
        AppSpacing.hXs,
        Expanded(
          child: Text(
            "Couldn't check shipping — ${e.message}",
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.text.caption,
          ),
        ),
        AppSpacing.hXs,
        TextButton(
          onPressed: onRetry,
          style: TextButton.styleFrom(
            minimumSize: const Size(64, _kTapTarget),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          ),
          child: const Text('Retry'),
        ),
      ],
    );
  }
}

/// Nothing ships to this pincode.
///
/// The state the whole block exists for. No delivery and free delivery are
/// different things, so this never renders a charge — not `₹0`, not "FREE" —
/// and says plainly that the destination has to change.
class _NotDeliverable extends StatelessWidget {
  const _NotDeliverable({required this.pinCode, this.message});

  final String pinCode;
  final String? message;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.xs),
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
                  size: 18,
                  color: AppColors.error,
                ),
                AppSpacing.hXs,
                Expanded(
                  child: Text(
                    "We don't deliver to $pinCode yet",
                    style: context.text.title.copyWith(color: AppColors.error),
                  ),
                ),
              ],
            ),
            AppSpacing.gapXxs,
            Text(
              // The server writes a usable sentence for this branch; show it
              // rather than paraphrasing.
              message?.trim().isNotEmpty == true
                  ? message!
                  : 'No courier services this pincode. Choose a different '
                      'address to place this order.',
              style: context.text.caption,
            ),
          ],
        ),
      );
}

// ---------------------------------------------------------------------------
// The list, collapsed by default
// ---------------------------------------------------------------------------

/// The question, then the answer: the list while nothing is chosen, one summary
/// row once something is.
///
/// The collapse is what keeps this cart-sized. Five courier rows permanently
/// open would push the bill and the Checkout button off the first screen — the
/// same crime as the address wall this feature replaced — so once the decision
/// exists the block shows *it* (`Delivery by 04 Aug · Blue Dart Surface ·
/// ₹180.60`) and advertises the alternatives in the same row, which is where a
/// customer who wants a cheaper or faster option will look for them.
///
/// It does **not** collapse before that. A collapsed block with nothing chosen
/// is a cart that ends in a subtotal and hides the control that would finish it,
/// one tap deeper than the customer has any reason to look. So the list starts
/// open, under a [_ChooseRow] that says what it is for, and the extra height is
/// the price of the cart being the place the total gets completed.
///
/// "Delivery by 04 Aug" stays "Delivery": it is the date the parcel arrives, not
/// the shipping charge, and "Shipping by 04 Aug" is not English.
class _OptionList extends StatelessWidget {
  const _OptionList({
    required this.options,
    required this.selected,
    required this.expanded,
    required this.unweighedLines,
    required this.onToggle,
    required this.onSelect,
  });

  final List<CourierOption> options;

  /// The courier the customer picked, or **null while they have not picked
  /// one** — which is the state every quote starts in.
  final CourierOption? selected;

  final bool expanded;

  /// Cart lines the catalogue records no pack weight for. Non-zero makes the
  /// quote a floor, and the block says so instead of presenting it as final.
  final int unweighedLines;

  final VoidCallback onToggle;
  final ValueChanged<CourierOption> onSelect;

  @override
  Widget build(BuildContext context) {
    final selected = this.selected;
    final others = options.length - 1;
    // Nothing chosen: the block has to ask, and it has to open even for a
    // single-courier quote — that tap is the customer accepting a delivery
    // charge, so it is never made for them.
    final open = expanded || selected == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (selected == null)
          _ChooseRow(count: options.length)
        else
          _SelectedRow(
            option: selected,
            others: others,
            expanded: open,
            // A single courier is not a choice; nothing to open.
            onTap: others == 0 ? null : onToggle,
          ),
        if (open) ...[
          AppSpacing.gapXxs,
          // One group for the whole list, so exactly one courier can be in
          // effect and screen readers announce the rows as the choice they are.
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
                  _CompactCourierTile(
                    option: option,
                    selected: option == selected,
                    onTap: () => onSelect(option),
                  ),
              ],
            ),
          ),
        ],
        if (unweighedLines > 0) ...[
          AppSpacing.gapXxs,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.info_outline_rounded,
                size: 14,
                color: AppColors.warning,
              ),
              AppSpacing.hXs,
              Expanded(
                child: Text(
                  'No pack weight on record for $unweighedLines item'
                  '${unweighedLines == 1 ? '' : 's'} — this charge may be '
                  'revised before dispatch.',
                  style: context.text.caption,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The prompt that stands where the summary will go, before anyone has chosen.
///
/// Deliberately carries **no** courier, no date and no price. The block used to
/// draw a full `_SelectedRow` for `options.first` here, which read as a decision
/// already taken — and the customer's own bill, correctly, showed no shipping
/// line beside it. This asks the question instead.
///
/// ## Why it is tinted rather than another quiet row
///
/// It is the one thing standing between the cart's "Subtotal" and a "To pay",
/// and the customer's own complaint about this screen was that it never reached
/// a final amount. Drawn as a plain row it read as a heading — something the
/// eye skips on the way to the bill — over a list that then looked like
/// information rather than a control. The tint, the border and the second line
/// naming what the tap *produces* ("pick one to see your total") are what make
/// it read as the unfinished step it is.
///
/// ## Why it does not toggle
///
/// It used to carry a chevron and `onToggle`, which did nothing: with no
/// selection the list is forced open ([_OptionList]), so the tap flipped a flag
/// no branch could observe. A control that cannot change anything is worse than
/// no control — it teaches the customer that tapping here is how you dismiss
/// the question. The list stays open until a courier is picked, and the only
/// tap on offer is the one that answers.
class _ChooseRow extends StatelessWidget {
  const _ChooseRow({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('cart-choose-delivery'),
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: _kTapTarget),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs,
          vertical: AppSpacing.xxs,
        ),
        decoration: BoxDecoration(
          color: context.colors.primarySoft,
          borderRadius: AppRadius.rMd,
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            Icon(AppIcons.truck, size: 20, color: context.colors.primaryDark),
            AppSpacing.hSm,
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // No maxLines. This is the sentence the whole card exists to
                  // deliver, so at the accessibility text size it wraps rather
                  // than eliding to "Choose a deliver…".
                  Text(
                    'Choose a delivery option',
                    style: context.text.title
                        .copyWith(color: context.colors.primaryDarker),
                  ),
                  // Names the consequence, not just the count: the customer is
                  // being told why the bill below still says "Subtotal".
                  Text(
                    count == 1
                        ? '1 courier delivers here — pick it to see your total'
                        : '$count couriers deliver here — pick one to see your '
                            'total',
                    style: context.text.caption,
                  ),
                ],
              ),
            ),
            // No price and no chevron: there is nothing to price yet, and a
            // dash, a zero or a collapse affordance would each read as an
            // answer.
          ],
        ),
      );
}

/// The collapsed summary: what is being charged, by whom, arriving when — and
/// the handle onto everything else.
class _SelectedRow extends StatelessWidget {
  const _SelectedRow({
    required this.option,
    required this.others,
    required this.expanded,
    required this.onTap,
  });

  final CourierOption option;
  final int others;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final eta = option.etaLabel;
    // The date is what the customer is buying; the courier's name is the
    // footnote — unless upstream sent no estimate, when the name is all there
    // is to lead with.
    final headline = eta ?? option.courierName;

    final detail = <String>[
      if (eta != null) option.courierName,
      if (others == 0)
        'the only option for this address'
      else if (expanded)
        'tap an option to change it'
      else
        '$others more option${others == 1 ? '' : 's'}',
    ].join(' · ');

    final stacked = _stackPrice(context);
    final price = Text(option.billedPriceFormatted, style: context.text.title);

    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _kTapTarget),
      child: Row(
        children: [
          Icon(AppIcons.truck, size: 20, color: context.colors.primaryDark),
          AppSpacing.hSm,
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.title
                      .copyWith(color: context.colors.primaryDarker),
                ),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.caption,
                ),
                // At the largest text scale the price alone is wider than the
                // space left for the courier, so it takes its own line rather
                // than eliding the thing being paid for down to one letter.
                if (stacked) price,
              ],
            ),
          ),
          if (!stacked) ...[
            AppSpacing.hSm,
            price,
          ],
          if (onTap != null)
            Icon(
              expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 20,
              color: context.colors.faint,
            ),
        ],
      ),
    );

    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.rMd,
      child: Semantics(
        button: true,
        label: expanded ? 'Hide shipping options' : 'Show shipping options',
        child: row,
      ),
    );
  }
}

/// One courier row, sized for a cart card rather than a checkout section.
///
/// Deliberately not `ShippingSelector`'s tile: that one gives every row two to
/// four lines inside its own titled panel, which is right for a screen whose
/// only job is the shipping decision and far too tall for a card sitting above
/// the bill. Same data, same selection store — one line each.
///
/// ## No cash-on-delivery wording, deliberately
///
/// These rows used to append "· prepaid only", in warning yellow, to every
/// courier that answered `cod: 0`. Checkout's equivalent row dropped that
/// wording — see the note on `_CourierOptionTile` in `shipping_selector.dart` —
/// and leaving it here made the cart and checkout describe the same courier
/// differently.
///
/// It was not merely inconsistent, it was untrue in both halves. This build
/// takes payment through Razorpay and nothing else: the checkout body hardcodes
/// `payment_method: "razorpay"`, COD is disabled server-side, and its API path
/// 500s *after* the order row has been committed. So there is no cash on
/// delivery to lose, and picking a different courier would not hand it back —
/// which is exactly what "prepaid only" implies. The quote is also requested
/// with `cod: 0`, so upstream returns 0 for `cod_charges` on every row anyway.
class _CompactCourierTile extends StatelessWidget {
  const _CompactCourierTile({
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
    final stacked = _stackPrice(context);
    final price = Text(option.billedPriceFormatted, style: context.text.title);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxs),
      // Without this the Radio is its own semantics node — an unlabelled 40dp
      // button sitting beside three loose text nodes — so a screen reader
      // announces "radio button" with no courier and no price, and the customer
      // has to reassemble which amount belongs to which control. Merged, the row
      // reads as one labelled option carrying the group's checked state, which
      // is what `ShippingSelector`'s equivalent tile already does.
      child: MergeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.rMd,
          child: Container(
            constraints: const BoxConstraints(minHeight: _kTapTarget),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xxs,
              vertical: AppSpacing.xxs,
            ),
            decoration: BoxDecoration(
              color: selected ? context.colors.primarySoft : null,
              borderRadius: AppRadius.rMd,
              border: Border.all(
                color: selected ? AppColors.primary : context.colors.line,
              ),
            ),
            child: Row(
              children: [
                // The radio reads its state from the enclosing RadioGroup; the
                // whole row is the tap target, because the control alone is a
                // 20px hit area.
                Radio<int>(
                  value: option.courierCompanyId,
                  activeColor: AppColors.primary,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                AppSpacing.hXs,
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        eta ?? option.courierName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.title,
                      ),
                      // Only when the estimate is leading — otherwise this
                      // would print the courier's name directly under itself.
                      // Same shape as the checkout tile, and carrying the same
                      // (absent) COD wording.
                      if (eta != null)
                        Text(
                          option.courierName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.caption,
                        ),
                      // Same reason as the collapsed row: at the largest text
                      // scale the price is wider than the space left for the
                      // courier it belongs to.
                      if (stacked) price,
                    ],
                  ),
                ),
                if (!stacked) ...[
                  AppSpacing.hXs,
                  price,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The bill's Shipping row
// ---------------------------------------------------------------------------

/// What the cart's bill puts on its Shipping row while no charge is quoted.
///
/// Lives here, next to the block that produces those states, so the row and the
/// card above it can never tell different stories — the row used to read "At
/// checkout" for every one of them, including the undeliverable address, where
/// it promised a resolution that checkout cannot deliver either.
///
/// Same vocabulary as checkout's own pending-shipping line, deliberately: the
/// two screens describe one quote.
String cartDeliveryStatusLabel(WidgetRef ref) {
  // Signed out there is no address book, so there is no destination and no quote
  // — and saying "choose an address" would point at a control the customer
  // cannot use.
  if (!ref.watch(isAuthenticatedProvider)) return 'Sign in to see shipping';

  final location = ref.watch(deliveryLocationProvider);
  if (location == null) return 'Choose an address';

  final parcelAsync = ref.watch(checkoutParcelProvider);
  if (parcelAsync.hasError) return 'Unavailable — retry above';

  final parcel = parcelAsync.valueOrNull;
  if (parcel == null) return 'Checking shipping…';

  final query = parcel.toQuery(location.pinCode);
  if (!query.hasValidPinCode) return 'Choose an address';

  final rates = ref.watch(courierOptionsProvider(query));
  if (rates.hasError) return 'Unavailable — retry above';

  final value = rates.valueOrNull;
  if (value == null) return 'Checking shipping…';
  if (!value.deliverable || value.isEmpty) return "We can't deliver here";

  // A quote exists and no courier has been chosen. This is no longer a
  // momentary gap between the list arriving and a preselection landing — it is
  // the normal state of a fresh quote, and it lasts until the customer taps a
  // row. So the Shipping line asks, and the total above it stays "Subtotal".
  return 'Choose an option above';
}

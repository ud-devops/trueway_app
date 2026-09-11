import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../core/validation/address_rules.dart';
import '../../data/models/address.dart';
import '../providers/address_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/delivery_location_provider.dart';
import '../screens/profile/address_book_screen.dart';
import '../screens/profile/address_form_screen.dart';
import 'skeletons.dart';
import 'state_views.dart';
import 'surfaces.dart';
import 'app_message.dart';

/// What the address chooser was closed with.
///
/// Deliberately *intent*, not action: the sheet never navigates anywhere itself.
/// Pushing the add/edit form from inside the sheet's own `builder` context means
/// pushing from a route that is about to be popped, and the form then outlives
/// the context that owns the address book subscription. So the sheet reports
/// what the customer asked for and the caller — which is still mounted — does
/// it.
@immutable
class AddressSheetResult {
  const AddressSheetResult._(this.address, this.addNew, this.signIn);

  /// The customer picked a saved row.
  const AddressSheetResult.pick(Address address)
      : this._(address, false, false);

  /// The customer asked for the add-a-new-address form.
  const AddressSheetResult.addNew() : this._(null, true, false);

  /// The customer asked to sign in. Only reachable from the signed-out sheet,
  /// which has no book to offer.
  const AddressSheetResult.signIn() : this._(null, false, true);

  /// The chosen row, or null for the two intents.
  final Address? address;

  final bool addNew;

  final bool signIn;
}

/// Opens the saved-address chooser. Resolves to null when it is dismissed.
///
/// `isScrollControlled` because the list can be longer than the default half
/// screen, and `useSafeArea` so the drag handle clears a notch.
Future<AddressSheetResult?> showAddressChooseSheet(
  BuildContext context, {
  required int? selectedId,
}) =>
    showModalBottomSheet<AddressSheetResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => AddressChooseSheet(selectedId: selectedId),
    );

/// The saved address book, as a pick-one list. **The** address chooser: the cart
/// and checkout both open this one widget.
///
/// ## Why there is no pincode field on it any more
///
/// The cart used to open a different sheet — a "Delivery pincode" text box and a
/// "Use this pincode" button, with the saved addresses listed underneath as
/// shortcuts. Two controls, one question, and they could disagree: a customer
/// could type 382415, then check out to an address in 474010, and the cart's
/// "To pay" was a figure nobody would be charged. The address already carries a
/// pincode, so the address is the only control left.
///
/// ## Why it watches the book instead of taking a snapshot
///
/// The book can change while the sheet is open (a background refresh landing, or
/// the re-read that follows a write elsewhere), and a frozen copy would show
/// rows the server no longer has. That also means every read state the callers
/// used to render inline has to be handled here too — first read, failed read,
/// failed refresh over surviving rows, and empty.
///
/// It is also what makes the region names appear. The lookup that turns the
/// stored "11"/"574" into "Gujarat"/"Ahmedabad" runs *behind* the address read
/// and re-emits the rows when it lands, so a sheet opened before it finished
/// simply repaints — no spinner, no reflow, and nothing waits on it.
///
/// ## Why picking writes to [deliveryLocationProvider]
///
/// This is the one control both screens choose through, so it is the one place
/// that records where the order is going. Applying the pick here — rather than
/// in each caller — is what stops the cart and checkout from holding two
/// different destinations for one order.
///
/// ## Why rows carry a "cannot be delivered to" flag
///
/// The address endpoints are far looser than the web checkout: `zip_code` is
/// `nullable|max:20`, `state` is nullable, `name` has no minimum. A book can
/// therefore contain rows the shop cannot dispatch to, and this list is the
/// last screen before one of them becomes an order — a PIN-less row produces a
/// zero shipping quote and an undispatchable order, silently. So every row is
/// checked against [CheckoutAddressRules] and a failing one says so *in the
/// list*, next to the name, rather than being picked and then explained (or
/// not) somewhere downstream.
///
/// The row stays tappable. Blocking the tap would leave a customer whose only
/// saved address is incomplete with a chooser that does nothing and no
/// explanation of why; the callers each have their own recovery — the cart
/// tells them shipping cannot be quoted, checkout offers "Edit address" — and
/// the flag is what makes the choice informed rather than silent.
class AddressChooseSheet extends ConsumerWidget {
  const AddressChooseSheet({super.key, required this.selectedId});

  /// The row currently in use, so it opens with the right radio filled.
  final int? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `isAuthenticatedProvider` rather than `authProvider`: this only needs the
    // flag, and reading the notifier would construct the auth session (and its
    // token-refresh call) for a sheet that just wants to know whether there is a
    // book to show.
    final signedIn = ref.watch(isAuthenticatedProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Deliver to', style: context.text.h3),
          AppSpacing.vXs,
          if (!signedIn)
            // No `ref.watch(addressBookProvider)` on this path on purpose:
            // `GET /ecommerce/addresses` is bearer-only and reading it without a
            // token 401s, which ApiClient turns into a forced sign-out.
            _signedOut(context)
          else ...[
            // Flexible, not Expanded: a two-address book should make a short
            // sheet, but a ten-address one must stop growing and scroll.
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.6,
                ),
                child: _body(context, ref, ref.watch(addressBookProvider)),
              ),
            ),
            AppSpacing.vSm,
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('address-picker-add'),
                onPressed: () =>
                    Navigator.of(context).pop(const AddressSheetResult.addNew()),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add a new address'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Signed out there is nothing to choose from and nothing to add to.
  ///
  /// Reachable defensively rather than by design — both callers offer signing in
  /// before they open this — but it must never be a blank sheet, and it must
  /// never touch the bearer-only route.
  Widget _signedOut(BuildContext context) => AddressNoticeCard(
        key: const Key('address-chooser-signed-out'),
        icon: Icons.lock_outline_rounded,
        text: 'Sign in to choose a delivery address. Your saved addresses are '
            'tied to your account.',
        actionLabel: 'Sign in',
        onAction: () =>
            Navigator.of(context).pop(const AddressSheetResult.signIn()),
      );

  Widget _body(BuildContext context, WidgetRef ref, AddressBookState book) {
    if (book.loading && book.addresses.isEmpty) {
      return const _OptionSkeleton();
    }
    if (book.error != null && book.addresses.isEmpty) {
      return InlineErrorStrip(
        error: book.error,
        label: 'your saved addresses',
        onRetry: ref.read(addressBookProvider.notifier).load,
      );
    }
    if (book.addresses.isEmpty) {
      return const AddressNoticeCard(
        key: Key('address-chooser-empty'),
        icon: Icons.location_on_rounded,
        text: 'No saved addresses yet. Add one to have it ready next time.',
      );
    }

    return RefreshIndicator(
      onRefresh: ref.read(addressBookProvider.notifier).refresh,
      child: ListView(
        shrinkWrap: true,
        // A two-row book does not overscroll on its own, and without this the
        // pull-to-refresh gesture is unreachable exactly when the list is short.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: [
          // The rows are still on screen, so a failed re-read is reported as
          // staleness rather than replacing them.
          if (book.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: InlineErrorStrip(
                error: book.error,
                label: 'the latest addresses',
                onRetry: ref.read(addressBookProvider.notifier).refresh,
              ),
            ),
          for (final address in book.addresses)
            Padding(
              key: ValueKey('address-option-${address.id}'),
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: _AddressOption(
                address: address,
                selected: address.id == selectedId,
                onTap: () => _pick(context, ref, address),
                onEdit: () => _edit(context, address),
                onDelete: () => confirmDeleteAddress(context, ref, address),
              ),
            ),
        ],
      ),
    );
  }

  /// Records the destination, then hands the row back to the caller.
  ///
  /// The write is fire-and-forget on purpose: it is a `SharedPreferences` put
  /// behind an in-memory state change, and awaiting it would hold the sheet open
  /// on a tap that has already visibly resolved. It returns **false** for a row
  /// the server stored without a usable `zip_code` (the rule is only
  /// `nullable|max:20`), in which case the app-wide destination is deliberately
  /// left alone — there is nothing to quote — and the caller's own "this address
  /// has no PIN code" notice is what the customer sees.
  /// Opens the form over the sheet.
  ///
  /// `rootNavigator: true` because this widget lives inside a modal bottom
  /// sheet: the local navigator would push the form *underneath* it, leaving
  /// the customer looking at the sheet with a form they cannot see. The sheet
  /// stays open behind the form on purpose — it watches `addressBookProvider`,
  /// so the edited row is already correct when the form pops.
  void _edit(BuildContext context, Address address) {
    Navigator.of(context, rootNavigator: true).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AddressFormScreen(address: address),
      ),
    );
  }

  void _pick(BuildContext context, WidgetRef ref, Address address) {
    unawaited(ref.read(deliveryLocationProvider.notifier).select(address));
    Navigator.of(context).pop(AddressSheetResult.pick(address));
  }
}

/// What the per-row menu offers.
enum _AddressAction { edit, delete }

/// One saved address, as a radio-style option.
class _AddressOption extends StatelessWidget {
  const _AddressOption({
    required this.address,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final Address address;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final line = address.displayAddress;
    // The web checkout's rules, not the address endpoint's: this row is one tap
    // away from being the destination on a real order.
    final problems = CheckoutAddressRules.validateJson(address.toJson());
    final undeliverable = problems.isNotEmpty;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.rLg,
        child: Container(
          // 44dp is the floor for a tap target; a three-line card clears it
          // comfortably, but an address with no street line does not.
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: selected
                ? context.colors.primarySurface
                : context.colors.surface,
            borderRadius: AppRadius.rLg,
            border: Border.all(
              // Selection still wins the border: the customer must always be
              // able to see which row is in use, including a broken one they
              // have already picked. The flag below carries the warning.
              color: selected
                  ? AppColors.primary
                  : (undeliverable
                      ? AppColors.warning
                      : context.colors.hairline),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: selected ? AppColors.primary : context.colors.faint,
                ),
              ),
              AppSpacing.hSm,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Wrap, not Row: at the largest OS text scale a long name
                    // plus the badge is wider than a 320dp card, and a Row
                    // reports the difference as a 152px overflow instead of
                    // moving the badge to its own line.
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xxs,
                      children: [
                        Text(address.name, style: context.text.title),
                        // Only ever follows the server's flag — the picker
                        // preselects the first row when nothing is flagged, and
                        // badging that would report a choice nobody made.
                        if (address.isDefault) const AddressDefaultBadge(),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(address.phone, style: context.text.bodySm),
                    AppSpacing.vXs,
                    // The same `Address.displayAddress` the address book and
                    // the checkout picker render, so one row cannot read three
                    // different ways. It resolves the numeric state/city ids
                    // some rows store — from the server's `full_address` when
                    // there is one, otherwise from the geo lookup's names.
                    Text(line, style: context.text.body),
                    if (undeliverable) ...[
                      AppSpacing.vXs,
                      _UndeliverableFlag(
                        key: Key('address-option-undeliverable-${address.id}'),
                        detail: CheckoutAddressRules.firstProblem(problems),
                      ),
                    ],
                  ],
                ),
              ),
              // Outside the Expanded, and its own tap target: a menu drawn
              // inside the row's InkWell would select the address on the way
              // to opening itself. `PopupMenuButton` swallows the tap.
              //
              // It matters most on exactly the rows that look broken — an
              // undeliverable address is one the customer has to *fix*, and
              // until now the only way in was to leave checkout, open Account,
              // find Saved addresses and hunt for the row.
              PopupMenuButton<_AddressAction>(
                key: Key('address-option-menu-${address.id}'),
                tooltip: 'Address options',
                icon: Icon(Icons.more_vert_rounded,
                    size: 20, color: context.colors.muted,),
                onSelected: (action) => switch (action) {
                  _AddressAction.edit => onEdit(),
                  _AddressAction.delete => onDelete(),
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: _AddressAction.edit,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_rounded, size: 20),
                      title: Text('Edit address'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _AddressAction.delete,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.delete_outline_rounded,
                          size: 20, color: AppColors.error,),
                      title: Text(
                        'Delete address',
                        style: TextStyle(color: AppColors.error),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "This row cannot be an order", said in the list rather than after the tap.
///
/// Deliberately one sentence plus the first missing field: eight messages in a
/// list row is a wall, and the customer only has to be told that the row needs
/// finishing and where to start. The wording is
/// [CheckoutAddressRules.undeliverableMessage], shared with anywhere else that
/// has to refuse a row, so one broken address cannot be described two ways.
class _UndeliverableFlag extends StatelessWidget {
  const _UndeliverableFlag({super.key, this.detail});

  /// The first rule the row breaks, e.g. "Enter the 6-digit PIN code".
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final message = detail == null
        ? CheckoutAddressRules.undeliverableMessage
        : '${CheckoutAddressRules.undeliverableMessage} ($detail)';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(
            Icons.warning_amber_rounded,
            size: 16,
            color: AppColors.warning,
          ),
        ),
        AppSpacing.hXs,
        Expanded(
          child: Text(
            message,
            style: context.text.caption.copyWith(color: AppColors.warning),
          ),
        ),
      ],
    );
  }
}

/// The "Default" pill. Shared with the collapsed card in `address_picker.dart`
/// and the cart's shipping card.
class AddressDefaultBadge extends StatelessWidget {
  const AddressDefaultBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: context.colors.primarySoft,
          borderRadius: AppRadius.rPill,
        ),
        child: Text(
          'Default',
          style: context.text.caption.copyWith(
            color: context.colors.primaryDarker,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

/// A bordered strip with one optional action — the fragment-sized stand-in for
/// [EmptyView], which is a full-screen `Center` and cannot live in an unbounded
/// scroll view. Shared with `address_picker.dart` and the cart's shipping card.
class AddressNoticeCard extends StatelessWidget {
  const AddressNoticeCard({
    super.key,
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: context.colors.surfaceAlt,
          borderRadius: AppRadius.rMd,
          border: Border.all(color: context.colors.line),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 18, color: context.colors.muted),
                AppSpacing.hSm,
                Expanded(child: Text(text, style: context.text.bodySm)),
              ],
            ),
            if (actionLabel != null) ...[
              AppSpacing.vXs,
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                  ),
                  child: Text(actionLabel!),
                ),
              ),
            ],
          ],
        ),
      );
}

/// Placeholder options for the first read, shaped like the cards they replace.
class _OptionSkeleton extends StatelessWidget {
  const _OptionSkeleton();

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 2; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: AppCard(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    SkeletonBox(height: 14, width: 140, radius: AppRadius.sm),
                    AppSpacing.vXs,
                    SkeletonBox(height: 12, width: 100, radius: AppRadius.sm),
                    AppSpacing.vXs,
                    SkeletonBox(height: 12, radius: AppRadius.sm),
                  ],
                ),
              ),
            ),
        ],
      );
}

// ---------------------------------------------------------------------------
// The one way to change where an order is going
// ---------------------------------------------------------------------------

/// Opens [showAddressChooseSheet] and acts on every outcome it can report.
///
/// The sheet applies the *pick* itself — it writes to
/// [deliveryLocationProvider] so two screens can never hold two destinations
/// for one order — but it deliberately never navigates. The two intents it
/// reports back (`addNew`, `signIn`) need a caller with a Navigator, and this
/// is that caller.
///
/// ## Why it is a function and not a copy in each screen
///
/// The cart card owned this flow, including the id-diff that finds the row a
/// just-saved form created and the PIN-code warning that explains a card which
/// did not change. The home header needs the same three outcomes, and a second
/// hand-written copy is how the two surfaces start disagreeing — one warns
/// about a PIN-less address and the other silently does nothing.
///
/// [onSignInRequested] exists because the cart may be hosted somewhere that
/// wants to intercept sign-in (a bottom-sheet checkout, a nested navigator)
/// rather than push `/login` onto whatever route stack happens to be current.
Future<void> chooseDeliveryAddress(
  BuildContext context,
  WidgetRef ref, {
  VoidCallback? onSignInRequested,
}) async {
  const noPin =
      'That address has no PIN code, so shipping cannot be quoted for it.';

  final result = await showAddressChooseSheet(
    context,
    selectedId: ref.read(selectedDeliveryAddressIdProvider),
  );
  // The sheet is a route, so anything may have happened to the caller while it
  // was open — including the screen being popped.
  if (!context.mounted || result == null) return;

  final picked = result.address;
  if (picked != null) {
    // The server's `zip_code` rule is only `nullable|max:20`, so a PIN-less row
    // is a real thing in the book. The sheet refuses to make it the destination
    // — there is nothing to quote — and this is where the customer is told why
    // the label did not change.
    if (!DeliveryLocationNotifier.isValidPin(picked.zipCode)) {
      context.showAlertSnack(noPin);
    }
    return;
  }

  if (result.addNew) {
    await addDeliveryAddress(context, ref);
    return;
  }

  if (result.signIn) {
    if (onSignInRequested != null) {
      onSignInRequested();
      return;
    }
    context.push('/login');
  }
}

/// Opens the add-address form and ships this order to whatever it creates.
///
/// Also the whole flow when the book is **empty**: there is nothing to choose
/// between, so offering a chooser first would be a sheet with one button in it.
///
/// The form has no return value beyond "saved" — it pops `true` — but
/// [AddressBookNotifier.create] re-reads the whole book *before* the pop, so the
/// new row is already in state by the time this resumes. Diffing the ids finds
/// it without trusting the unverified create-response body.
Future<void> addDeliveryAddress(BuildContext context, WidgetRef ref) async {
  final before =
      ref.read(addressBookProvider).addresses.map((a) => a.id).toSet();
  await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(builder: (_) => const AddressFormScreen()),
  );
  if (!context.mounted) return;

  Address? created;
  for (final a in ref.read(addressBookProvider).addresses) {
    if (!before.contains(a.id)) {
      created = a;
      break;
    }
  }
  if (created == null) return;

  final ok = await ref.read(deliveryLocationProvider.notifier).select(created);
  if (!context.mounted || ok) return;
  context.showAlertSnack(
    'That address has no PIN code, so shipping cannot be quoted for it.',
  );
}

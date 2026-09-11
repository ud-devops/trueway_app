import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../core/errors/api_exception.dart';
import '../../../data/models/address.dart';
import '../../providers/address_provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/state_views.dart';
import '../../widgets/surfaces.dart';
import 'address_form_screen.dart';
import '../../widgets/app_message.dart';

/// The customer's saved addresses — list, add, edit, delete, set default.
///
/// Every route behind this needs a bearer token, so the screen gates on auth
/// itself rather than relying on the caller: a 401 would sign the customer out
/// and replace the list with "Please sign in again", which is a worse way to
/// learn you were never signed in.
class AddressBookScreen extends ConsumerWidget {
  const AddressBookScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(isAuthenticatedProvider);

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(title: const Text('Saved addresses')),
      body: signedIn
          ? const _AddressBookBody()
          : EmptyView(
              icon: Icons.location_on_rounded,
              title: 'Sign in to save addresses',
              subtitle: 'Your delivery addresses are tied to your account.',
              action: SizedBox(
                width: 220,
                child: ElevatedButton(
                  onPressed: () => context.push('/login'),
                  child: const Text('Sign in'),
                ),
              ),
            ),
      bottomNavigationBar: signedIn
          ? BottomActionBar(
              child: ElevatedButton.icon(
                key: const Key('address-add'),
                onPressed: () => openAddressForm(context),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('Add a new address'),
              ),
            )
          : null,
    );
  }
}

/// Pushes the create/edit form.
///
/// A plain [MaterialPageRoute] rather than a go_router path: the form takes an
/// [Address] object, not an id, and there is no `GET /addresses/{id}` route to
/// rebuild one from — so a deep link to "edit address 16" could not be honoured
/// anyway. The book re-reads itself through the notifier, so nothing depends on
/// the result.
void openAddressForm(BuildContext context, {Address? address}) {
  Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      builder: (_) => AddressFormScreen(address: address),
    ),
  );
}

class _AddressBookBody extends ConsumerStatefulWidget {
  const _AddressBookBody();

  @override
  ConsumerState<_AddressBookBody> createState() => _AddressBookBodyState();
}

class _AddressBookBodyState extends ConsumerState<_AddressBookBody> {
  final _search = TextEditingController();

  /// What the customer has typed, trimmed. Held here rather than in a provider
  /// because it is scoped to this screen: leaving the address book and coming
  /// back should show the whole book again, not a filter nobody can see the
  /// reason for.
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    final next = value.trim();
    if (next == _query) return;
    setState(() => _query = next);
  }

  void _clearQuery() {
    _search.clear();
    _onQueryChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(addressBookProvider);
    final notifier = ref.read(addressBookProvider.notifier);

    if (state.loading && state.addresses.isEmpty) {
      return const _AddressListSkeleton();
    }

    if (state.error != null && state.addresses.isEmpty) {
      return AppErrorView(error: state.error, onRetry: notifier.load);
    }

    if (state.addresses.isEmpty) {
      // Pull-to-refresh works here too: an address added on the website (or on
      // another device) should not need the screen to be closed and reopened
      // before it appears.
      return RefreshIndicator(
        onRefresh: notifier.refresh,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              // No action here on purpose. "Add a new address" is already in
              // the bar pinned to the bottom, whether the book is empty or
              // full — so a second button doing the identical thing two
              // hundred pixels away is a choice the customer has to make for
              // nothing, and it moves the action depending on how many
              // addresses they happen to have. One button, always in the same
              // place, is the thing worth having.
              //
              // The subtitle points at it, so the empty state still says what
              // to do next.
              child: const EmptyView(
                icon: Icons.location_on_rounded,
                title: 'No saved addresses',
                subtitle: 'Add one below and checkout takes a couple of taps.',
              ),
            ),
          ),
        ),
      );
    }

    // Filtered here rather than in the provider: the query is this screen's,
    // and a provider that held it would keep filtering a list the cart and
    // checkout pickers also read.
    final matches = [
      for (final address in state.addresses)
        if (address.matches(_query)) address,
    ];

    return RefreshIndicator(
      onRefresh: notifier.refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        children: [
          // The rows are still on screen, so this reports a *stale* list rather
          // than replacing it — the read failed, the addresses did not vanish.
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: InlineErrorStrip(
                error: state.error,
                label: 'the latest addresses',
                onRetry: notifier.refresh,
              ),
            ),
          // A book with no default is reachable: the server never re-promotes
          // on update, so one edit that clears the flag leaves nothing marked.
          //
          // The wording deliberately does not promise what checkout will do
          // with an unflagged book — no checkout address picker exists yet, so
          // that would be the screen describing behaviour nobody has built.
          if (state.defaultAddress == null)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.xs),
              child: _Notice(
                text: 'No default address set. Choose one so your orders go to '
                    'the right place.',
              ),
            ),
          _SearchField(
            controller: _search,
            resultCount: matches.length,
            total: state.addresses.length,
            onChanged: _onQueryChanged,
            onClear: _clearQuery,
          ),
          AppSpacing.vSm,

          // Searched into nothing. Not [EmptyView] — the book is not empty, and
          // saying "No saved addresses" over a book with eight of them would be
          // a false statement about the account.
          if (matches.isEmpty)
            Padding(
              key: const Key('address-search-empty'),
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Column(
                children: [
                  Icon(Icons.search_off_rounded,
                      size: 40, color: context.colors.faint,),
                  AppSpacing.vSm,
                  Text(
                    'No address matches “$_query”.',
                    textAlign: TextAlign.center,
                    style: context.text.bodySm
                        .copyWith(color: context.colors.muted),
                  ),
                  AppSpacing.vSm,
                  TextButton(
                    key: const Key('address-search-clear-empty'),
                    onPressed: _clearQuery,
                    child: const Text('Show all addresses'),
                  ),
                ],
              ),
            ),

          for (final address in matches)
            Padding(
              key: ValueKey('address-${address.id}'),
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _AddressCard(
                address: address,
                busy: state.isBusy(address.id),
                onEdit: () => openAddressForm(context, address: address),
                onSetDefault: () => _setDefault(context, ref, address),
                onDelete: () => confirmDeleteAddress(context, ref, address),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _setDefault(
    BuildContext context,
    WidgetRef ref,
    Address address,
  ) async {
    try {
      final promoted =
          await ref.read(addressBookProvider.notifier).setDefault(address);
      if (!context.mounted) return;
      // A promotion that was skipped because one was already in flight sent no
      // request at all, so there is nothing to confirm.
      if (!promoted) return;
      context.showSuccessSnack('Default address updated.');
    } on ApiException catch (e) {
      if (!context.mounted) return;
      // A row saved through the server's lenient POST rules can be missing the
      // fields a PUT requires, and promoting is a PUT. "Enter an email address"
      // on its own would look like a bug, so name the real fix.
      if (e.isValidation) {
        context.showAlertSnack(
          'This address is missing details the server needs. Open Edit, '
          'complete it, and try again.',
        );
        return;
      }
      context.showErrorSnack(e, context: 'addressBook.setDefault');
    } catch (e) {
      // Anything that is not an ApiException — a malformed write body that
      // trips a cast, say. Without this the row's spinner simply stops and the
      // customer is left believing the badge moved when it did not.
      if (!context.mounted) return;
      context.showErrorSnack(e, context: 'addressBook.setDefault');
    }
  }

}

/// Asks, then deletes — the one implementation of both.
///
/// Shared with the address chooser sheet so a row cannot be deleted with a
/// different warning depending on which screen the customer opened it from.
/// The wording is not boilerplate: `destroy()` promotes the newest *survivor*,
/// so what the customer is told depends on whether this row is the default and
/// whether anything else is left.
Future<void> confirmDeleteAddress(
  BuildContext context,
  WidgetRef ref,
  Address address,
) async {
  // `destroy()` promotes the newest *survivor* — so there has to be one.
  // Promising a promotion when this is the customer's only address was the
  // dialog describing something the server cannot do; deleting the last row
  // simply leaves the book empty.
  final hasOthers = ref
      .read(addressBookProvider)
      .addresses
      .any((a) => a.id != address.id);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete this address?'),
      content: Text(
        switch ((address.isDefault, hasOthers)) {
          (true, true) => 'This is your default address. Deleting it makes '
              'your newest remaining address the default.',
          (true, false) =>
            'This is your only saved address. Deleting it leaves your '
                'address book empty and nothing selected for checkout.',
          (false, _) => 'This address will be removed from your account.',
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.error,
            minimumSize: const Size(88, 44),
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );

  if (!(confirmed ?? false) || !context.mounted) return;

  try {
    final result =
        await ref.read(addressBookProvider.notifier).delete(address.id);
    if (!context.mounted) return;
    // A delete that was skipped because one was already in flight never
    // reached the server, and the row is still in the book. Saying "Address
    // deleted." here would be the screen inventing a result.
    if (!result.ran) return;
    // The server writes this sentence ("Address deleted successfully"); show
    // its wording when it gave us one.
    context.showSuccessSnack(result.message ?? 'Address deleted.');
  } on ApiException catch (e) {
    if (!context.mounted) return;
    context.showErrorSnack(e, context: 'addressBook.delete');
  } catch (e) {
    if (!context.mounted) return;
    context.showErrorSnack(e, context: 'addressBook.delete');
  }
}

/// One saved address.
/// The address-book search box.
///
/// ## Why it searches what it searches
///
/// Over [Address.searchHaystack], which is built from the **shown** values.
/// `state` and `city` hold opaque geo ids — `"11"`, `"574"` — while the card
/// reads "Gujarat" and "Ahmedabad", so a search over the stored fields would
/// find nothing for the words actually on screen.
///
/// ## Why there is no debounce
///
/// Nothing is fetched. The whole book is already in memory — the endpoint
/// returns it unpaginated — so filtering is a pass over a list of a few rows
/// and a timer would only add lag between the keystroke and the result.
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.resultCount,
    required this.total,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final int resultCount;
  final int total;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final query = controller.text.trim();
    final filtering = query.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('address-search-field'),
          controller: controller,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search by name, area, city or PIN',
            prefixIcon: Icon(Icons.search_rounded, color: context.colors.muted),
            // Only while there is something to clear — a permanent × on an
            // empty field is a control that does nothing.
            suffixIcon: filtering
                ? IconButton(
                    key: const Key('address-search-clear'),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Clear search',
                    onPressed: onClear,
                  )
                : null,
          ),
        ),
        if (filtering) ...[
          AppSpacing.vXs,
          Text(
            // Says what is on screen *and* what is hidden. "2 of 8" is the
            // difference between a filtered book and a book that lost rows.
            '$resultCount of $total ${total == 1 ? 'address' : 'addresses'}',
            key: const Key('address-search-count'),
            style: context.text.caption.copyWith(color: context.colors.muted),
          ),
        ],
      ],
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({
    required this.address,
    required this.busy,
    required this.onEdit,
    required this.onSetDefault,
    required this.onDelete,
  });

  final Address address;

  /// A write against this row is in flight — every action is disabled, because
  /// a second delete would target a row the first one has already removed.
  final bool busy;

  final VoidCallback onEdit;
  final VoidCallback onSetDefault;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  address.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.title,
                ),
              ),
              if (address.isDefault) ...[
                AppSpacing.hXs,
                const _DefaultBadge(),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(address.phone, style: context.text.bodySm),
          AppSpacing.vXs,
          // Never a widget-local join of the raw columns. `displayAddress` is
          // the single getter the chooser sheet and the checkout picker render
          // too, so one address cannot read three different ways; it prefers
          // the server's resolved `full_address` and otherwise composes from
          // the geo-resolved names, dropping any part that is still a bare id.
          //
          // No spinner and no placeholder while the lookup is in flight: this
          // line is always printable, and a row that resolves late repaints in
          // place without changing the card's height.
          Text(
            address.displayAddress,
            style: context.text.body,
          ),
          AppSpacing.vXs,
          // A Row here overflowed by 152px on a 320dp screen and by ~100px on
          // a 360dp one — i.e. on every phone the app actually ships to, and
          // worse at any accessibility text scale. Three labelled buttons never
          // fit one line, so they wrap instead of painting the debug stripes.
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppSpacing.xxs,
            runSpacing: AppSpacing.xxs,
            children: [
              if (busy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
                  child: SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              if (!address.isDefault)
                TextButton(
                  onPressed: busy ? null : onSetDefault,
                  style: _compact,
                  child: const Text('Set as default'),
                ),
              TextButton.icon(
                onPressed: busy ? null : onEdit,
                style: _compact,
                icon: const Icon(Icons.edit_rounded, size: 18),
                label: const Text('Edit'),
              ),
              TextButton.icon(
                onPressed: busy ? null : onDelete,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.error,
                  minimumSize: _minTapTarget,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                  ),
                ),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Delete'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 36 was below the 44dp floor for a destructive control sitting next to two
  /// others.
  static const Size _minTapTarget = Size(0, 44);

  static final ButtonStyle _compact = TextButton.styleFrom(
    minimumSize: _minTapTarget,
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
  );
}

class _DefaultBadge extends StatelessWidget {
  const _DefaultBadge();

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

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.colors.surfaceAlt,
          borderRadius: AppRadius.rMd,
          border: Border.all(color: context.colors.line),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded,
                size: 18, color: context.colors.muted,),
            AppSpacing.hSm,
            Expanded(child: Text(text, style: context.text.caption)),
          ],
        ),
      );
}

/// Placeholder rows for the first read, shaped like the cards they replace.
class _AddressListSkeleton extends StatelessWidget {
  const _AddressListSkeleton();

  @override
  Widget build(BuildContext context) => ListView.separated(
        padding: const EdgeInsets.all(AppSpacing.md),
        itemCount: 3,
        separatorBuilder: (_, __) => AppSpacing.vSm,
        itemBuilder: (_, __) => AppCard(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              SkeletonBox(height: 14, width: 140, radius: AppRadius.sm),
              AppSpacing.vXs,
              SkeletonBox(height: 12, width: 100, radius: AppRadius.sm),
              AppSpacing.vXs,
              SkeletonBox(height: 12, radius: AppRadius.sm),
              AppSpacing.vXs,
              SkeletonBox(height: 12, width: 220, radius: AppRadius.sm),
            ],
          ),
        ),
      );
}

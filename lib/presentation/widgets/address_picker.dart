import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../core/validation/address_rules.dart';
import '../../data/models/address.dart';
import '../providers/address_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/delivery_location_provider.dart';
import '../screens/profile/address_form_screen.dart';
import 'address_choose_sheet.dart';
import 'skeletons.dart';
import 'state_views.dart';
import 'surfaces.dart';

/// Where an order is going, in the two shapes checkout can be handed.
///
/// A signed-in customer picks a row out of their address book, so [address] is
/// set and carries a server id. A signed-out one types the address into the
/// picker itself, so only [draft] exists — the address book is bearer-only and
/// there is nothing to pick from. Exactly one of the two is non-null, and
/// [effectiveDraft] gives the write shape either way.
///
/// ## Why [pinCode] is a separate field rather than `address.zipCode`
///
/// Shipping rates are a function of the delivery PIN and nothing else the
/// customer types, and both `/logistics/check-pincode` and
/// `/logistics/check-serviceability` want a real 6-digit code. So this field is
/// **empty until the PIN is valid** — it never carries the half-typed "3824"
/// that a `zipCode` read mid-keystroke would. A parent can therefore treat "the
/// pin code changed to something non-empty" as "refetch the rates" without
/// debouncing or re-validating.
@immutable
class AddressSelection {
  const AddressSelection({
    this.address,
    this.draft,
    this.pinCode = '',
    this.isComplete = false,
  });

  /// Nothing chosen yet — the picker is still loading, or its form is blank.
  static const AddressSelection none = AddressSelection();

  /// The saved row the customer picked, or null when they typed one instead.
  final Address? address;

  /// The manually-entered address, or null when a saved row is selected.
  ///
  /// Emitted even while incomplete so a parent can hold on to a partly-typed
  /// address across a rebuild; use [isComplete] before sending it anywhere.
  final AddressDraft? draft;

  /// The delivery PIN code, or `''` when it is not (yet) a valid 6-digit one.
  final String pinCode;

  /// Everything checkout needs is present and passes [CheckoutAddressRules] —
  /// the same rules `CheckoutAddress.violations` applies, so this is exactly
  /// "the flow will accept this address".
  ///
  /// False for a saved row that breaks any of them, which is not a rare case:
  /// `POST /ecommerce/addresses` requires only `{name, phone}` and leaves
  /// `zip_code` and `state` nullable, so PIN-less and state-less rows are real
  /// things in real address books.
  final bool isComplete;

  bool get isSaved => address != null;

  /// The id to send when checkout wants to reference the saved row, or null.
  int? get addressId => address?.id;

  /// The write shape, whichever half of the union is populated.
  ///
  /// For a saved row this is [Address.toDraft], which deliberately round-trips
  /// `state`/`city` as the opaque tokens the server stored ("11"/"574") rather
  /// than the names `full_address` renders — sending the rendered names back
  /// would rewrite the row.
  AddressDraft get effectiveDraft =>
      address?.toDraft() ?? draft ?? const AddressDraft();

  /// One line safe to print in a bill summary.
  ///
  /// Prefers [Address.displayAddress] for saved rows — the same getter the
  /// address book, the chooser sheet and the collapsed card render, and the one
  /// that resolves the numeric `state`/`city` ids some rows actually store. The
  /// manual branch needs no resolution: those values are names the customer
  /// typed.
  String get displayLine {
    final saved = address;
    if (saved != null) return saved.displayAddress;
    final d = draft;
    if (d == null) return '';
    return [d.address, d.city, d.state, d.zipCode]
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join(', ');
  }

  /// Field-by-field so a rebuilt-but-identical draft compares equal.
  ///
  /// [AddressDraft] has no `==` of its own, so comparing the two references
  /// would report every rebuild as a change and the picker would re-notify its
  /// parent — and re-trigger a shipping-rate fetch — on every frame.
  static String _signature(AddressDraft? d) =>
      d == null ? '' : d.toJson().toString();

  @override
  bool operator ==(Object other) =>
      other is AddressSelection &&
      other.address == address &&
      other.pinCode == pinCode &&
      other.isComplete == isComplete &&
      _signature(other.draft) == _signature(draft);

  @override
  int get hashCode =>
      Object.hash(address, pinCode, isComplete, _signature(draft));
}

/// Choose where the order goes — a saved address, or one typed in place.
///
/// This is a **fragment, not a screen**: no Scaffold, no AppBar, no scroll view
/// of its own. Checkout drops it into its own list and owns the page chrome.
///
/// ## Collapsed by default
///
/// Signed in, this renders **one** card: the address the order is currently
/// going to, with a "Change" affordance. Every other saved row lives in the
/// modal chooser behind that button ([showAddressChooseSheet]).
///
/// The previous shape — every saved row as a radio card, stacked — cost roughly
/// 120dp per address at the top of checkout, so an account with five addresses
/// pushed the bill and the "Place order" button entirely below the fold. The
/// customer already knows where they live; checkout should open ready to
/// complete, not ready to browse. Nothing about the *selection* changed: the
/// server-flagged default is still preselected on first build, and the picker
/// still emits the same [AddressSelection] at the same moments.
///
/// ## The signed-out case is the important one
///
/// `GET /ecommerce/addresses` is bearer-only, so a signed-out customer has no
/// address book to show — and checkout still has to work for them. Rather than
/// blocking with a sign-in wall, the picker shows its manual entry form
/// directly and offers signing in as an *option*. Signing in and coming back
/// swaps to the saved list, keeping anything already typed if the customer had
/// started filling the form.
///
/// ## Validation is not reimplemented here
///
/// Every rule comes from [CheckoutAddressRules] — the *checkout* rules, which
/// is the whole point: this widget's [AddressSelection.isComplete] is what
/// enables "Place order", and `CheckoutAddress.violations` (which the checkout
/// notifier and `CheckoutRepository.placeOrder` both refuse on) delegates to the
/// same file. One definition of a deliverable address, so the button and the
/// flow can never disagree.
///
/// It used to validate with [AddressDraft.validationErrors] — the *address
/// book's* POST/PUT union — plus a bare pincode check. That is a genuinely
/// different rule set (191-character street lines against 120, no minimum name
/// length, `state` optional), so the button went live for addresses the very
/// next step rejected.
///
/// [AddressFormScreen] cannot be embedded (it is a full Scaffold and it *saves
/// to the bearer-only endpoint*, which a signed-out customer has no token for),
/// so this form is a second set of *fields* but not a second set of *rules*.
class AddressPicker extends ConsumerStatefulWidget {
  const AddressPicker({
    super.key,
    required this.onChanged,
    this.initialAddressId,
    this.initialDraft,
    this.enabled = true,
    this.onSignInRequested,
  });

  /// Fires whenever the effective selection changes — a different saved row, an
  /// edited draft field, or the PIN becoming (in)valid.
  ///
  /// Always called from a post-frame callback, never during the picker's own
  /// build, so a parent may `setState` straight out of it.
  final ValueChanged<AddressSelection> onChanged;

  /// Re-select this saved row if the book still contains it. Lets checkout
  /// survive a rebuild without the customer's choice snapping back to default.
  final int? initialAddressId;

  /// Seed for the manual form, for the same reason.
  final AddressDraft? initialDraft;

  /// False while the parent is placing the order — every control is frozen so
  /// the address cannot change under an in-flight request.
  final bool enabled;

  /// What the "Sign in" affordance does. Defaults to pushing `/login`.
  final VoidCallback? onSignInRequested;

  @override
  ConsumerState<AddressPicker> createState() => _AddressPickerState();
}

class _AddressPickerState extends ConsumerState<AddressPicker> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _street = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _zip = TextEditingController();

  /// The saved row the customer picked. Null means "nothing picked yet", which
  /// resolves to the default address once the book has loaded.
  int? _selectedId;

  /// True while the manual form is showing instead of the saved list.
  ///
  /// Forced true when signed out (there is no list). Signed in it is opt-in —
  /// the escape hatch offered when the address book cannot be read, so a
  /// failing endpoint does not take checkout down with it.
  bool _manual = false;

  /// The customer has typed something into the manual form. Guards the
  /// signed-out -> signed-in transition: their half-typed address must not be
  /// silently swapped for a saved row.
  bool _draftTouched = false;

  /// Whether the manual form should paint its errors yet. Off until the first
  /// interaction so a freshly-opened checkout is not covered in red.
  bool _showManualErrors = false;

  bool? _lastSignedIn;

  /// The last value handed to [AddressPicker.onChanged]; the emit filter.
  AddressSelection _lastEmitted = AddressSelection.none;

  @override
  void initState() {
    super.initState();
    final seed = widget.initialDraft ?? const AddressDraft();
    _name.text = seed.name;
    _phone.text = seed.phone;
    // The seed's email, or the signed-in customer's. The field below is only
    // built when neither had one — see [_needsEmail].
    _email.text = seed.email.trim().isNotEmpty
        ? seed.email
        : (ref.read(authProvider).customer?.email ?? '');
    _street.text = seed.address;
    _city.text = seed.city;
    _state.text = seed.state;
    _zip.text = seed.zipCode;
    _selectedId = widget.initialAddressId;
    _draftTouched = widget.initialDraft != null;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _street.dispose();
    _city.dispose();
    _state.dispose();
    _zip.dispose();
    super.dispose();
  }

  // ---- selection ----------------------------------------------------------

  AddressDraft _draft() => AddressDraft(
        name: _name.text,
        phone: _phone.text,
        email: _email.text,
        state: _state.text,
        city: _city.text,
        address: _street.text,
        zipCode: _zip.text,
      );

  /// The row currently selected, resolving "nothing picked yet" to the default.
  ///
  /// The fallback to the first row matters: a book with **no** flagged default
  /// is reachable (the server never re-promotes on update), and checkout with
  /// nothing preselected would be unusable. The row is selected but never
  /// *badged* "Default" — that badge only ever follows the server's flag.
  Address? _resolveSaved(List<Address> rows) {
    if (rows.isEmpty) return null;
    final id = _selectedId;
    if (id != null) {
      for (final a in rows) {
        if (a.id == id) return a;
      }
    }
    for (final a in rows) {
      if (a.isDefault) return a;
    }
    return rows.first;
  }

  /// The selection for [saved], or for the typed draft when it is null.
  ///
  /// `isComplete` is [CheckoutAddressRules] and nothing else — the *same* rules
  /// `CheckoutAddress.violations` applies, which is what the checkout notifier
  /// and the repository both refuse on. Anything looser here (the old
  /// `AddressDraft.validationErrors` + `isValidPincode` pair allowed a
  /// 191-character street line, a two-character name and a blank state) enables
  /// "Place order" for an address the very next step rejects.
  ///
  /// [AddressSelection.pinCode] deliberately does **not** follow `isComplete`:
  /// shipping rates are a function of the destination alone, so a valid PIN is
  /// reported even while the phone number is still half-typed.
  AddressSelection _selectionFor(Address? saved) {
    final draft = saved?.toDraft() ?? _draft();
    final pin = draft.zipCode.trim();
    // The draft is the write shape either way — for a saved row that is
    // `Address.toDraft()`, exactly what checkout will send.
    // Email is not part of the gate. The form does not collect one, and the
    // server does not require one — `CheckoutRequest` marks it `nullable`, and
    // the live validator passes an address without it.
    final complete = (CheckoutAddressRules.validateJson(draft.toCheckoutJson())
          ..remove(AddressField.email))
        .isEmpty;
    return AddressSelection(
      address: saved,
      draft: saved == null ? draft : null,
      pinCode: _isDeliverablePin(pin) ? pin : '',
      isComplete: complete,
    );
  }

  /// True when the PIN alone is good enough to ask for shipping rates.
  static bool _isDeliverablePin(String value) =>
      CheckoutAddressRules.zipCodeError(value) == null;

  /// Why [saved] cannot be checked out with, or null when it can be.
  ///
  /// The PIN gets its own sentence because it is the failure that also takes
  /// the shipping quote down with it — the customer needs to know the block is
  /// not just paperwork. Every other rule falls back to the shared
  /// [CheckoutAddressRules.firstProblem] wording, which is the same sentence the
  /// chooser sheet puts on the row.
  static String? _savedProblem(Address saved) {
    final problems =
        CheckoutAddressRules.validateJson(saved.toDraft().toCheckoutJson());
    if (problems.isEmpty) return null;
    if (problems.containsKey(AddressField.zipCode)) {
      // "Shipping" is the charge and the method — the panel these are shown in
      // is titled "Shipping options". "Delivery" is kept for the date and for
      // the address itself.
      return 'This address has no valid PIN code, so shipping options '
          'cannot be checked for it.';
    }
    return '${CheckoutAddressRules.undeliverableMessage} '
        '(${CheckoutAddressRules.firstProblem(problems)})';
  }

  /// Hands a changed selection to the parent after this frame.
  ///
  /// Deferred deliberately: this is reached from `build`, and calling back
  /// synchronously would have checkout `setState` in the middle of the picker's
  /// own build. The `==` guard is what keeps a rebuild from re-firing a
  /// shipping-rate fetch.
  void _emit(AddressSelection selection) {
    if (selection == _lastEmitted) return;
    _lastEmitted = selection;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onChanged(selection);
    });
  }

  void _select(Address address) {
    if (!widget.enabled) return;
    setState(() {
      _selectedId = address.id;
      _manual = false;
    });
  }

  void _onManualEdit() => setState(() {
        _draftTouched = true;
        _showManualErrors = true;
      });

  /// Opens the saved-address chooser and applies whatever came back.
  ///
  /// The sheet reports an *intent* rather than acting: "add a new address" is
  /// handled here, after the sheet has closed, because pushing the form from the
  /// sheet's own context means pushing from a route that is being popped — and
  /// [_addNew] has to still be running when it returns, to diff the book.
  Future<void> _openChooser() async {
    if (!widget.enabled) return;
    final result = await showAddressChooseSheet(
      context,
      selectedId: _resolveSaved(ref.read(addressBookProvider).addresses)?.id,
    );
    // The sheet is a route: checkout may have started placing the order while
    // it was open, and the picker itself may be gone.
    if (!mounted || result == null || !widget.enabled) return;
    final picked = result.address;
    if (picked != null) {
      _select(picked);
      return;
    }
    if (result.addNew) await _addNew();
  }

  /// Opens the real add/edit form and adopts whatever it created.
  ///
  /// The form has no return value beyond "saved" — it pops `true` — but
  /// [AddressBookNotifier.create] re-reads the whole book *before* the pop, so
  /// the new row is already in state by the time this resumes. Diffing the ids
  /// finds it without trusting the unverified create-response body.
  Future<void> _addNew({Address? edit}) async {
    if (!widget.enabled) return;
    final before =
        ref.read(addressBookProvider).addresses.map((a) => a.id).toSet();
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => AddressFormScreen(address: edit)),
    );
    if (!mounted) return;
    final rows = ref.read(addressBookProvider).addresses;
    Address? created;
    for (final a in rows) {
      if (!before.contains(a.id)) {
        created = a;
        break;
      }
    }
    if (created == null) return;
    // Same write the chooser sheet performs on a pick. Without it the newly
    // added address is selected *here only*: the cart goes on naming — and
    // quoting for — the previous destination, and because checkout seeds
    // `initialAddressId` from `selectedDeliveryAddressIdProvider`, leaving this
    // screen and coming back silently reverts to that older row. Fire-and-forget
    // for the same reason the sheet does it: the state change is synchronous and
    // only the SharedPreferences write is awaited.
    unawaited(ref.read(deliveryLocationProvider.notifier).select(created));
    setState(() {
      _selectedId = created!.id;
      _manual = false;
    });
  }

  void _signIn() {
    final custom = widget.onSignInRequested;
    if (custom != null) {
      custom();
      return;
    }
    context.push('/login');
  }

  // ---- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(isAuthenticatedProvider);

    // Signing in mid-checkout: the book is readable now, so show it — unless
    // the customer had already started typing, in which case their work stays
    // on screen and the saved list is one tap away.
    if (_lastSignedIn != signedIn) {
      _lastSignedIn = signedIn;
      _manual = signedIn ? (_manual && _draftTouched) : true;
    }

    if (!signedIn) {
      // No `ref.watch(addressBookProvider)` on this path on purpose: the route
      // is bearer-only and reading it without a token 401s, which ApiClient
      // turns into a forced sign-out.
      final selection = _selectionFor(null);
      _emit(selection);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SignInPrompt(enabled: widget.enabled, onSignIn: _signIn),
          AppSpacing.vSm,
          _manualForm(context),
        ],
      );
    }

    final book = ref.watch(addressBookProvider);
    // Watching the notifier keeps the autoDispose book alive while the pushed
    // form writes to it, so the post-write re-read cannot be cancelled halfway.
    ref.watch(addressBookProvider.notifier);

    final saved = _manual ? null : _resolveSaved(book.addresses);
    _emit(_selectionFor(saved));

    // Order matters: a customer who has *opted into* typing an address keeps
    // that form whatever the book is doing. Checking the read states first is
    // how a failing GET took the manual escape hatch away again.
    if (_manual) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _manualForm(context),
          AppSpacing.vXs,
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('address-picker-use-saved'),
              onPressed:
                  widget.enabled ? () => setState(() => _manual = false) : null,
              icon: const Icon(Icons.bookmark_border_rounded, size: 18),
              label: const Text('Use a saved address'),
            ),
          ),
        ],
      );
    }

    if (book.loading && book.addresses.isEmpty) return const _CardSkeleton();
    if (book.error != null && book.addresses.isEmpty) {
      return _readFailed(context, book);
    }
    if (book.addresses.isEmpty) return _emptyBook(context);
    // Unreachable — _resolveSaved only returns null for an empty book, which the
    // line above has already handled — but the analyzer cannot see that, and an
    // `!` here would be a crash if either rule ever moved.
    if (saved == null) return _emptyBook(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The address is still on screen, so a failed re-read is reported as
        // staleness rather than replacing it.
        if (book.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: InlineErrorStrip(
              error: book.error,
              label: 'the latest addresses',
              onRetry: ref.read(addressBookProvider.notifier).refresh,
            ),
          ),
        // One card, whatever the book holds. Everything else is behind Change.
        _SelectedAddressCard(
          key: const Key('address-picker-selected'),
          address: saved,
          enabled: widget.enabled,
          onChange: _openChooser,
        ),
        // A saved row can break the checkout rules in eight different ways —
        // the address endpoint's `zip_code` is only `nullable|max:20`, `state`
        // is `nullable`, and so on — and every one of them now blocks the
        // button. Saying which one is broken is the difference between an
        // "Edit address" the customer knows what to do with and a dead end.
        if (_savedProblem(saved) case final problem?) ...[
          AppSpacing.vXs,
          AddressNoticeCard(
            key: const Key('address-picker-no-pincode'),
            icon: Icons.warning_amber_rounded,
            text: problem,
            actionLabel: 'Edit address',
            onAction: widget.enabled ? () => _addNew(edit: saved) : null,
          ),
        ],
      ],
    );
  }

  /// The book could not be read at all.
  ///
  /// Retry is offered first, but typing the address is offered too: a customer
  /// with a full cart should not be blocked from ordering because one GET is
  /// failing.
  Widget _readFailed(BuildContext context, AddressBookState book) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InlineErrorStrip(
            error: book.error,
            label: 'your saved addresses',
            onRetry: ref.read(addressBookProvider.notifier).load,
          ),
          AppSpacing.vXs,
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('address-picker-manual'),
              onPressed:
                  widget.enabled ? () => setState(() => _manual = true) : null,
              icon: const Icon(Icons.edit_location_alt_rounded, size: 18),
              label: const Text('Enter an address instead'),
            ),
          ),
        ],
      );

  /// Signed in, book read fine, nothing in it.
  ///
  /// Deliberately not [EmptyView]: that is a full-screen `Center`, and this
  /// widget is a fragment inside somebody else's unbounded scroll view.
  Widget _emptyBook(BuildContext context) => AddressNoticeCard(
        key: const Key('address-picker-empty'),
        icon: Icons.location_on_rounded,
        text: 'No saved addresses yet. Add one to have it ready next time.',
        actionLabel: 'Add a new address',
        onAction: widget.enabled ? _addNew : null,
      );

  // ---- manual entry -------------------------------------------------------

  /// One field's message, from [CheckoutAddressRules] and nowhere else.
  ///
  /// The same source as [_selectionFor]'s `isComplete` and as the notifier's
  /// refusal, so a field can never be painted green under a button that is
  /// disabled — or, worse, painted green under a button that submits and then
  /// fails. Field-by-field rather than one `validateJson` per box so the
  /// switch is exhaustive against [AddressField] at compile time.
  String? _errorFor(String field) {
    if (!_showManualErrors) return null;
    return switch (field) {
      AddressField.name => CheckoutAddressRules.nameError(_name.text),
      AddressField.phone => CheckoutAddressRules.phoneError(_phone.text),
      // Nothing on screen carries it, so nothing on screen can report it.
      AddressField.email => null,
      AddressField.address => CheckoutAddressRules.addressError(_street.text),
      AddressField.city => CheckoutAddressRules.cityError(_city.text),
      AddressField.state => CheckoutAddressRules.stateError(_state.text),
      AddressField.zipCode => CheckoutAddressRules.zipCodeError(_zip.text),
      _ => null,
    };
  }

  Widget _manualForm(BuildContext context) => AppCard(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Deliver to', style: context.text.title),
            AppSpacing.vXs,
            _field(
              key: const Key('manual-address-name'),
              controller: _name,
              label: 'Full name',
              capitalize: true,
              error: _errorFor(AddressField.name),
            ),
            _field(
              key: const Key('manual-address-phone'),
              controller: _phone,
              label: 'Mobile number',
              keyboardType: TextInputType.phone,
              maxLength: 10,
              digitsOnly: true,
              prefixText: '+91 ',
              helper: '10 digits, starting 6-9',
              error: _errorFor(AddressField.phone),
            ),
            // No email field — order mail goes to the account's address
            // (`OrderHelper`: account first, address only as a fallback), and
            // the server marks the address field `nullable`.
            _field(
              key: const Key('manual-address-street'),
              controller: _street,
              label: 'Flat, building, street, area',
              capitalize: true,
              minLines: 2,
              maxLines: 3,
              error: _errorFor(AddressField.address),
            ),
            _field(
              key: const Key('manual-address-city'),
              controller: _city,
              label: 'City',
              capitalize: true,
              error: _errorFor(AddressField.city),
            ),
            _field(
              key: const Key('manual-address-state'),
              controller: _state,
              label: 'State',
              capitalize: true,
              error: _errorFor(AddressField.state),
            ),
            _field(
              key: const Key('manual-address-zip'),
              controller: _zip,
              label: 'PIN code',
              keyboardType: TextInputType.number,
              maxLength: 6,
              digitsOnly: true,
              helper: 'Shipping charges are quoted for this PIN code',
              error: _errorFor(AddressField.zipCode),
              // The shop ships in one country and the server fills it in, so
              // there is no Country box to be the last field.
              last: true,
            ),
          ],
        ),
      );

  Widget _field({
    required Key key,
    required TextEditingController controller,
    required String label,
    String? error,
    String? helper,
    String? prefixText,
    TextInputType? keyboardType,
    int? maxLength,
    int? minLines,
    int maxLines = 1,
    bool digitsOnly = false,
    bool capitalize = false,
    bool last = false,
  }) =>
      Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : AppSpacing.sm),
        child: TextField(
          key: key,
          controller: controller,
          enabled: widget.enabled,
          keyboardType: keyboardType,
          maxLength: maxLength,
          minLines: minLines,
          maxLines: maxLines,
          textInputAction:
              last ? TextInputAction.done : TextInputAction.next,
          textCapitalization: capitalize
              ? TextCapitalization.words
              : TextCapitalization.none,
          inputFormatters:
              digitsOnly ? [FilteringTextInputFormatter.digitsOnly] : null,
          onChanged: (_) => _onManualEdit(),
          decoration: InputDecoration(
            labelText: label,
            counterText: '',
            prefixText: prefixText,
            helperText: error == null ? helper : null,
            helperMaxLines: 2,
            errorText: error,
            errorMaxLines: 2,
            alignLabelWithHint: maxLines > 1,
          ),
        ),
      );
}

/// The collapsed "this is where it's going" card — the whole signed-in picker.
///
/// Name, phone and the *resolved* address, plus one way out. The full address
/// is shown rather than truncated to a line: it is the fact the customer is
/// actually checking before they pay, and eliding it to "306, Jahnavi Arc…"
/// would make them open the chooser just to read their own address.
class _SelectedAddressCard extends StatelessWidget {
  const _SelectedAddressCard({
    super.key,
    required this.address,
    required this.enabled,
    required this.onChange,
  });

  final Address address;
  final bool enabled;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) => AppCard(
        // The whole card is the target, not just the button: this is the one
        // control in the section and it should be hard to miss.
        onTap: enabled ? onChange : null,
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                  // The same `Address.displayAddress` the address book and the
                  // chooser sheet render, so the address the customer picked in
                  // the sheet reads identically here. It resolves the numeric
                  // state/city ids some rows store — from the server's
                  // `full_address` when there is one, otherwise from the geo
                  // lookup's names — and a row that resolves late repaints in
                  // place rather than moving the bill down the page.
                  Text(address.displayAddress, style: context.text.body),
                ],
              ),
            ),
            AppSpacing.hXs,
            TextButton(
              key: const Key('address-picker-change'),
              onPressed: enabled ? onChange : null,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              ),
              child: const Text('Change'),
            ),
          ],
        ),
      );
}

/// "You could sign in" — an offer, never a wall.
class _SignInPrompt extends StatelessWidget {
  const _SignInPrompt({required this.enabled, required this.onSignIn});

  final bool enabled;
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: BoxDecoration(
          color: context.colors.surfaceAlt,
          borderRadius: AppRadius.rMd,
          border: Border.all(color: context.colors.line),
        ),
        child: Row(
          children: [
            Icon(
              Icons.bookmark_border_rounded,
              size: 18,
              color: context.colors.muted,
            ),
            AppSpacing.hSm,
            Expanded(
              child: Text(
                'Sign in to use saved addresses',
                style: context.text.caption,
              ),
            ),
            TextButton(
              key: const Key('address-picker-signin'),
              onPressed: enabled ? onSignIn : null,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              ),
              child: const Text('Sign in'),
            ),
          ],
        ),
      );
}

/// Placeholder for the first read, shaped like the one card it replaces.
///
/// One card, not the two the stacked list used to draw: the collapsed picker
/// settles into a single card, and a taller skeleton would make checkout jump
/// as the book lands.
class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();

  @override
  Widget build(BuildContext context) => AppCard(
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
      );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/validation/address_rules.dart';
import '../../../data/models/address.dart';
import '../../../data/repositories/geo_repository.dart';
import '../../../data/repositories/pincode_repository.dart';
import '../../providers/address_provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/geo_picker_field.dart';
import '../../widgets/required_label.dart';
import '../../widgets/surfaces.dart';
import '../../widgets/app_message.dart';

/// Create or edit one saved address.
///
/// One screen for both, because POST and PUT now share a single rule set — see
/// [AddressDraft]. Splitting create and edit would mean two copies of a rule
/// set whose only interesting failure was the mismatch between them, and that
/// mismatch is gone.
///
/// ## State and City are chosen, never typed
///
/// `state` is validated with `exists` on the server: it must be a bare
/// `states.id`, and the name — "Gujarat" — is rejected outright. So the two
/// text boxes this form used to show could not save a new address at all; they
/// are now pickers backed by `GET /ecommerce/states` and
/// `GET /ecommerce/cities?state=<id>`, and what gets posted is always the id.
///
/// `city` is the mirror image: nothing on the server validates it, so a typo is
/// stored and rendered verbatim. The picker is the only guard there is.
///
/// This also retires the whole "opaque token" apparatus this screen used to
/// carry — seeding a box with a resolved name, remembering the seed, and
/// round-tripping the stored id whenever the box was untouched. The row now
/// arrives with `state_name`/`city_name` beside the ids, so the picker can show
/// the name and hold the id without guessing.
///
/// ## Which rules this form enforces
///
/// [CheckoutAddressRules] first, then [AddressDraft.validationErrors], then the
/// server's own last complaint. Checkout's rules are the strictest of the three
/// and the only ones that describe an address the shop can actually dispatch —
/// a six-digit PIN, a name of at least three characters, an email to send the
/// confirmation to. Being stricter than the endpoint can never cause a 422; it
/// only refuses a save the shop could not have fulfilled.
///
/// ## What the form does not let the customer do
///
/// There is no "remove default" control. `is_default` is written, never
/// cleared: `handleDefaultAddress` only ever demotes the *other* rows, so a PUT
/// carrying `is_default: false` on the current default leaves the book with no
/// default at all and the next checkout silently preselects the newest address.
/// Promotion is offered; demotion happens by promoting something else.
class AddressFormScreen extends ConsumerStatefulWidget {
  const AddressFormScreen({super.key, this.address});

  /// The row being edited, or null to create a new one.
  final Address? address;

  @override
  ConsumerState<AddressFormScreen> createState() => _AddressFormScreenState();
}

class _AddressFormScreenState extends ConsumerState<AddressFormScreen> {
  final _form = GlobalKey<FormState>();

  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _street = TextEditingController();
  final _landmark = TextEditingController();
  final _otherCity = TextEditingController();
  final _zip = TextEditingController();

  /// The chosen state, holding both the id that gets posted and the name the
  /// customer reads. Seeded from the row being edited without waiting for the
  /// list to load — the row already carries `state_name`.
  GeoOption? _state;

  /// The chosen city, or the `"Other"` sentinel. See [_isOtherCity].
  GeoOption? _city;

  /// The chosen district, as India Post spells it.
  ///
  /// A plain String rather than a [GeoOption] because `district` is free text
  /// on the server — there is no id to carry and no lookup table behind it.
  String? _district;

  /// The districts the current PIN covers, for the district picker.
  ///
  /// Usually one; 110001 covers two ("Central Delhi", "New Delhi"), which is
  /// why this is a picker at all rather than a silent fill.
  List<PincodeDistrict> _districtOptions = const [];

  /// The last PIN a lookup was run for, so a rebuild or a stray keystroke that
  /// leaves the value unchanged does not re-run the autofill and stamp over
  /// something the customer has since corrected by hand.
  String _lookedUpPin = '';

  /// True while the PIN lookup is in flight.
  bool _lookingUpPin = false;

  /// Cancels a pending lookup when the customer keeps typing.
  Timer? _pinDebounce;

  bool _saving = false;

  /// True while a picker is fetching its list, so a second tap cannot open two
  /// sheets or issue two requests.
  bool _loadingOptions = false;

  /// Whether the customer operated the "make this my default" switch.
  ///
  /// Until they do, [AddressDraft.isDefault] stays null and the key is omitted
  /// from the request entirely, which is what leaves the server's flag alone.
  bool _defaultTouched = false;
  bool _makeDefault = false;

  /// Server-side field errors from the last rejected save, keyed by the
  /// server's own field names so they drop straight onto the matching input.
  Map<String, String> _serverErrors = const {};

  /// The exact value each field held when the server rejected it.
  ///
  /// A server error is only shown while the field still holds the value the
  /// server complained about. Without this, "The phone must be a string."
  /// stayed painted under the phone box no matter what the customer typed.
  Map<String, String> _rejectedValues = const {};

  static const _liveValidation = AutovalidateMode.onUserInteraction;

  /// The store ships in one country, the server fills `country_id` itself, and
  /// nothing is posted — but [CheckoutAddressRules.validate] still asks for a
  /// country, because a checkout address needs one. This is that constant, not
  /// a field the customer fills in.
  static const String _country = CheckoutAddressRules.shipsToCountry;

  Address? get _editing => widget.address;

  bool get _isEditing => _editing != null;

  bool get _isCurrentDefault => _editing?.isDefault ?? false;

  bool get _isOtherCity => _city?.isOther ?? false;

  /// True when this save will create the customer's **first** address.
  ///
  /// `AddressController::store()` forces `is_default` on the first address
  /// whatever the request asked for, so offering a switch in its off position
  /// would promise the opposite of what the server is about to do.
  ///
  /// Read once, in [initState], rather than watched: "known to be empty" means
  /// a read that finished and returned nothing. A book still loading, or one
  /// whose read failed, is *not* known to be empty, so the switch stays.
  late final bool _willBeFirstAddress;

  @override
  void initState() {
    super.initState();
    final book = ref.read(addressBookProvider);
    _willBeFirstAddress = !_isEditing &&
        book.addresses.isEmpty &&
        !book.loading &&
        book.error == null;

    final row = _editing;
    final draft = row?.toDraft() ?? const AddressDraft();
    _name.text = draft.name;
    _phone.text = draft.phone;
    // The row's own email when editing, the account's otherwise. Nothing on
    // screen writes this. It is sent because the column exists and an existing
    // row's value should survive an edit — not because anything requires it;
    // `AddressController` saves `validated()` and never fills it in.
    _email.text = draft.email.trim().isNotEmpty
        ? draft.email
        : (ref.read(authProvider).customer?.email ?? '');
    _street.text = draft.address;
    _landmark.text = draft.landmark;
    _otherCity.text = draft.otherCity;
    _zip.text = draft.zipCode;
    if (draft.district.trim().isNotEmpty) _district = draft.district.trim();

    if (row != null) {
      // Seeded from the row itself rather than from the lists, which are only
      // fetched when a picker is opened. `state_name`/`city_name` come with
      // every row, so an editing customer reads "Gujarat" immediately instead
      // of watching a blank field fill in — and the id underneath is the row's
      // own, so saving without touching either picker round-trips it exactly.
      if (row.state.trim().isNotEmpty) {
        _state = GeoOption(id: row.state.trim(), name: row.stateName);
      }
      if (row.city.trim().isNotEmpty) {
        _city = GeoOption(
          id: row.city.trim(),
          // An other-city row must read "Other" in the picker, not the town —
          // the town belongs in its own box, which is where `other_city` is
          // seeded above.
          name: row.isOtherCity ? 'Other' : row.cityName,
        );
      }
      // An existing row's PIN is already reflected in its state/city/district,
      // so it counts as looked up. Without this, opening the form to fix a
      // typo in the street line would fire a lookup and quietly re-stamp three
      // fields the customer never touched.
      _lookedUpPin = draft.zipCode.trim();

      // ...but the district *list* is not part of the row, and marking the PIN
      // as looked-up used to mean it was never fetched either. The District
      // picker then refused to open on an address that plainly had a PIN in it
      // — "Enter your PIN code first" on a form showing 474010 — and there was
      // no way to change a district while editing.
      //
      // So the options are loaded for the existing PIN, and only the options:
      // nothing the customer already has is overwritten.
      _loadDistrictOptions(_lookedUpPin);
    }

    _zip.addListener(_onPinChanged);
  }

  // ---------------------------------------------------------------------------
  // PIN autofill
  // ---------------------------------------------------------------------------

  /// Fetches the district list for an already-known PIN, and **nothing else**.
  ///
  /// The editing case: state, city and district are already on the row, so
  /// [_autofillFromPin] would be wrong here — it re-stamps all three. This
  /// takes only `districts`, which exists nowhere else. There is no districts
  /// table on the backend (`/ecommerce/districts` 404s in every spelling), so
  /// the PIN lookup is the only source there is.
  ///
  /// Silent on failure, like every other use of this lookup: an unreachable
  /// third-party service must not stop someone fixing their street line.
  Future<void> _loadDistrictOptions(String pin) async {
    if (CheckoutAddressRules.zipCodeError(pin) != null) return;
    if (mounted) setState(() => _lookingUpPin = true);

    PincodeLocation? place;
    try {
      place = await ref.read(pincodeRepositoryProvider).lookup(pin);
    } finally {
      if (mounted) setState(() => _lookingUpPin = false);
    }

    // The customer edited the PIN while this was in flight; whatever came back
    // describes a place they have moved on from, and the listener has already
    // started a real autofill for the new one.
    if (!mounted || place == null || _zip.text.trim() != pin) return;
    setState(() => _districtOptions = place!.districts);
  }

  /// Debounces the lookup while the six digits are still being typed.
  void _onPinChanged() {
    final pin = _zip.text.trim();
    // The District hint now reads off this field — "Enter a PIN code first"
    // until it is valid, then the lookup's own state — so the form has to
    // repaint as it is typed. A listener alone does not: the TextFormField
    // rebuilds itself, not the screen around it.
    if (mounted) setState(() {});
    if (pin == _lookedUpPin) return;
    _pinDebounce?.cancel();
    if (CheckoutAddressRules.zipCodeError(pin) != null) return;
    _pinDebounce = Timer(_pinDebounceDelay, () => _autofillFromPin(pin));
  }

  /// Long enough that typing the last digit of a PIN does not fire two
  /// lookups, short enough to feel immediate.
  static const Duration _pinDebounceDelay = Duration(milliseconds: 350);

  /// Fills state, district and city in from [pin].
  ///
  /// Everything about this is best-effort and silent:
  ///
  ///   * the lookup itself never throws and answers null for an unknown PIN;
  ///   * the state is set only when India Post's name **matches a row of the
  ///     store's own list** — the app posts ids, and an id it does not have is
  ///     worse than an empty field;
  ///   * the city is set only when one of the candidate names matches a row of
  ///     that state's list. Otherwise it is left for the customer, who still
  ///     has the "Other" escape hatch.
  ///
  /// A PIN typed and then edited again mid-flight is dropped on arrival: the
  /// guard re-reads the field rather than trusting the value it started with.
  Future<void> _autofillFromPin(String pin) async {
    if (!mounted || _saving) return;
    setState(() => _lookingUpPin = true);

    PincodeLocation? place;
    List<GeoOption> states = const [];
    try {
      place = await ref.read(pincodeRepositoryProvider).lookup(pin);
      if (place != null) {
        states = await ref.read(geoRepositoryProvider).states();
      }
    } finally {
      if (mounted) setState(() => _lookingUpPin = false);
    }

    // The customer kept typing, or left. Whatever we found is about a PIN that
    // is no longer in the box.
    if (!mounted || _zip.text.trim() != pin) return;
    _lookedUpPin = pin;
    if (place == null) return;

    final state = _matchByName(states, place.stateName);
    final district = place.soleDistrict?.name;

    setState(() {
      _districtOptions = place!.districts;
      if (district != null) _district = district;
      if (state != null && state.id != _state?.id) {
        _state = state;
        // A city id only means anything inside its own state.
        _city = null;
        _otherCity.clear();
      }
    });

    if (state == null) return;
    await _autofillCity(pin: pin, place: place, state: state, district: district);
  }

  /// Picks the city whose name matches one of the PIN's candidate names.
  ///
  /// Split out because it needs the state's city list, which is a second
  /// request — and because it must re-check that nothing moved underneath it
  /// while that request was in flight.
  Future<void> _autofillCity({
    required String pin,
    required PincodeLocation place,
    required GeoOption state,
    required String? district,
  }) async {
    final cities = await ref.read(geoRepositoryProvider).cities(state.id);
    if (!mounted || _zip.text.trim() != pin || _state?.id != state.id) return;
    if (_city != null) return;

    for (final candidate in place.cityCandidates(district: district)) {
      final match = _matchByName(cities, candidate);
      if (match != null) {
        setState(() => _city = match);
        return;
      }
    }
  }

  /// The option whose name is [name], compared on letters and digits only.
  ///
  /// India Post's spelling is not Botble's — 382415 reports the block as
  /// "Ahmadabad City" where the store's row is "Ahmedabad" — so punctuation,
  /// case and spacing are all ignored. Anything looser than that would start
  /// matching the wrong place, and a wrong city is worse than none.
  static GeoOption? _matchByName(List<GeoOption> options, String name) {
    final wanted = _normalise(name);
    if (wanted.isEmpty) return null;
    for (final option in options) {
      if (_normalise(option.name) == wanted) return option;
    }
    return null;
  }

  static String _normalise(String value) =>
      value.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _street.dispose();
    _landmark.dispose();
    _otherCity.dispose();
    _pinDebounce?.cancel();
    _zip.removeListener(_onPinChanged);
    _zip.dispose();
    super.dispose();
  }

  /// The draft as the fields currently stand — the single source of truth for
  /// both validation and the request body.
  AddressDraft _draft() => AddressDraft(
        name: _name.text,
        phone: _phone.text,
        email: _email.text,
        state: _state?.id ?? '',
        city: _city?.id ?? '',
        otherCity: _isOtherCity ? _otherCity.text : '',
        district: _district ?? '',
        landmark: _landmark.text,
        address: _street.text,
        zipCode: _zip.text,
        isDefault: _defaultTouched && _makeDefault ? true : null,
      );

  /// Every text input, keyed by the server's own field name. The two pickers
  /// are absent on purpose — they hold options, not text, and their server
  /// errors are shown on the field itself.
  late final Map<String, TextEditingController> _fields = {
    AddressField.name: _name,
    AddressField.phone: _phone,
    AddressField.email: _email,
    AddressField.address: _street,
    AddressField.landmark: _landmark,
    AddressField.otherCity: _otherCity,
    AddressField.zipCode: _zip,
  };

  /// The server's complaint about [field], but only while the field still says
  /// what the server rejected. Editing it clears the message.
  String? _serverErrorFor(String field) {
    final rejected = _rejectedValues[field];
    if (rejected == null) return null;
    if ((_fields[field]?.text.trim() ?? '') != rejected) return null;
    return _serverErrors[field];
  }

  /// The WEB checkout's rule for one field, live off the current text.
  ///
  /// These come first because they are the strictest of the three rule sets in
  /// play and the only ones that describe an address the shop can dispatch to.
  String? _ruleErrorFor(String field) => switch (field) {
        AddressField.name => CheckoutAddressRules.nameError(_name.text),
        AddressField.phone => CheckoutAddressRules.phoneError(_phone.text),
        // Never — the field is not on screen, and the server accepts a blank
        // email anyway.
        AddressField.email => null,
        AddressField.address =>
          CheckoutAddressRules.addressError(_street.text),
        AddressField.zipCode => CheckoutAddressRules.zipCodeError(_zip.text),
        _ => null,
      };

  /// Checkout's rule first, then the address book's own contract, then whatever
  /// the server said about that field last time. All three come from the same
  /// key space, so no translation is needed.
  String? _errorFor(String field) =>
      _ruleErrorFor(field) ??
      _draft().validationErrors()[field] ??
      _serverErrorFor(field);

  /// Everything the WEB checkout would reject about the form as it stands.
  ///
  /// The submit gate, and deliberately independent of the `Form`: a field that
  /// loses its validator — or one added later without one — would otherwise
  /// silently reopen the hole this screen exists to close. The pickers are not
  /// `FormField`s at all, so their errors reach the gate only through
  /// [AddressDraft.validationErrors].
  Map<String, String> _submitErrors() => {
        ...CheckoutAddressRules.validate(
          name: _name.text,
          phone: _phone.text,
          email: _email.text,
          address: _street.text,
          city: _city?.name ?? '',
          state: _state?.name ?? '',
          zipCode: _zip.text,
          country: _country,
        ),
        ..._draft().validationErrors(),
      }..remove(AddressField.email);

  // ---------------------------------------------------------------------------
  // Pickers
  // ---------------------------------------------------------------------------

  Future<void> _pickState() async {
    final geo = ref.read(geoRepositoryProvider);
    final chosen = await _pick(
      title: 'Select state',
      load: geo.states,
      selected: _state,
      emptyMessage: 'Could not load the list of states. Check your connection '
          'and try again.',
    );
    if (chosen == null || !mounted) return;
    setState(() {
      final changed = chosen.id != _state?.id;
      _state = chosen;
      // A city id only means anything inside its own state, and nothing on the
      // server checks the pair — a Gujarat address happily stores a Delhi city
      // id. Clearing is the only way to keep the two consistent.
      if (changed) {
        _city = null;
        _otherCity.clear();
      }
    });
  }

  Future<void> _pickCity() async {
    final state = _state;
    if (state == null) {
      context.showInfoSnack('Choose a state first.');
      return;
    }
    final geo = ref.read(geoRepositoryProvider);
    final chosen = await _pick(
      title: 'Select city',
      load: () => geo.cities(state.id),
      selected: _city,
      emptyMessage: 'Could not load the cities for ${state.name}. Check your '
          'connection and try again.',
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _city = chosen;
      if (!chosen.isOther) _otherCity.clear();
    });
  }

  /// The districts of the current PIN.
  ///
  /// There is no districts table anywhere on the backend — `/ecommerce/
  /// districts` is a 404 in every spelling — so the only list that exists is
  /// the one the PIN lookup produced. With no PIN there is nothing to offer,
  /// and saying so is better than opening an empty sheet.
  Future<void> _pickDistrict() async {
    if (_districtOptions.isEmpty) {
      final pin = _zip.text.trim();
      context.showInfoSnack(
        CheckoutAddressRules.zipCodeError(pin) != null
            ? 'Enter your PIN code first — we look the district up from it.'
            // The PIN is there and the lookup still gave nothing: an unknown
            // PIN, or India Post was unreachable. Telling the customer to
            // enter a PIN they can see in the box above reads as a broken
            // form.
            : _lookingUpPin
                ? 'Looking up districts for $pin…'
                : 'We could not look up districts for $pin. '
                    'Re-enter the PIN to try again.',
      );
      return;
    }
    final chosen = await showGeoPicker(
      context: context,
      title: 'Select district',
      // `district` is posted as text, so the name is both the id and the label.
      options: [
        for (final d in _districtOptions) GeoOption(id: d.name, name: d.name),
      ],
      selectedId: _district,
    );
    if (chosen == null || !mounted) return;
    setState(() => _district = chosen.name);
  }

  /// Loads a list, then shows the sheet. Returns null when the customer
  /// dismissed it, when the list could not be loaded, or when a load was
  /// already running.
  ///
  /// The list is fetched on demand rather than up front: a customer correcting
  /// their phone number should not pay for an 18 KB city list, and
  /// [GeoRepository] caches so the second open is free.
  Future<GeoOption?> _pick({
    required String title,
    required Future<List<GeoOption>> Function() load,
    required GeoOption? selected,
    required String emptyMessage,
  }) async {
    if (_loadingOptions) return null;
    setState(() => _loadingOptions = true);
    List<GeoOption> options;
    try {
      options = await load();
    } finally {
      if (mounted) setState(() => _loadingOptions = false);
    }
    if (!mounted) return null;
    if (options.isEmpty) {
      // `GeoRepository` never throws — an empty list *is* the failure signal,
      // and it is also what an unknown state id returns.
      context.showInfoSnack(emptyMessage);
      return null;
    }
    return showGeoPicker(
      context: context,
      title: title,
      options: options,
      selectedId: selected?.id,
    );
  }

  // ---------------------------------------------------------------------------
  // Save
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    setState(() {
      _serverErrors = const {};
      _rejectedValues = const {};
      // From here on the pickers may paint their own errors — before the first
      // save attempt there is nothing to scold anyone about.
      _triedToSave = true;
    });
    // Two gates, on purpose. `validate()` paints the messages under the text
    // fields; [_submitErrors] is what actually refuses, and it is the only one
    // that sees the pickers.
    final blocked = !(_form.currentState?.validate() ?? false);
    final problems = _submitErrors();
    if (blocked || problems.isNotEmpty) {
      if (!blocked && mounted) {
        // Every remaining problem belongs to a picker or to the other-city box,
        // which the `Form` cannot paint — say so rather than doing nothing.
        final first = CheckoutAddressRules.firstProblem(problems) ??
            problems.values.first;
        context.showInfoSnack(first);
      }
      return;
    }

    final draft = _draft();
    setState(() => _saving = true);

    final book = ref.read(addressBookProvider.notifier);
    try {
      if (_isEditing) {
        await book.update(_editing!.id, draft);
      } else {
        await book.create(draft);
      }
      if (!mounted) return;
      context.showSuccessSnack(
        _isEditing ? 'Address updated.' : 'Address saved.',
      );
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _serverErrors = _fieldErrors(e);
        _rejectedValues = {
          for (final entry in _fields.entries)
            entry.key: entry.value.text.trim(),
        };
      });
      // Re-run the validators so the newly-arrived server errors are painted
      // under the fields they belong to, not just in the snackbar.
      _form.currentState?.validate();
      context.showErrorSnack(e, context: 'addressForm.save');
    } catch (e) {
      // Anything that is not an ApiException — a write body whose shape trips a
      // cast, for instance. Without this branch the exception escapes, `_saving`
      // stays true forever, and the form is left with every field disabled and
      // a dead Save button.
      if (!mounted) return;
      setState(() => _saving = false);
      context.showErrorSnack(e, context: 'addressForm.save');
    }
  }

  static Map<String, String> _fieldErrors(ApiException e) => {
        for (final entry
            in (e.fieldErrors ?? const <String, List<String>>{}).entries)
          if (entry.value.isNotEmpty) entry.key: entry.value.first,
      };

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Watching the notifier (not its state) keeps the autoDispose book alive
    // while this form is open, so the re-read that follows a save cannot be
    // cancelled by the provider being disposed mid-flight. It never rebuilds
    // this widget.
    ref.watch(addressBookProvider.notifier);

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit address' : 'Add a new address'),
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              if (_isEditing) ...[
                _StoredAddressCard(address: _editing!),
                AppSpacing.vMd,
              ],

              TextFormField(
                key: const Key('address-name'),
                controller: _name,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                enabled: !_saving,
                autovalidateMode: _liveValidation,
                decoration: _decoration('Full name'),
                validator: (_) => _errorFor(AddressField.name),
              ),
              AppSpacing.vMd,

              TextFormField(
                key: const Key('address-phone'),
                controller: _phone,
                keyboardType: TextInputType.phone,
                maxLength: 10,
                textInputAction: TextInputAction.next,
                enabled: !_saving,
                autovalidateMode: _liveValidation,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: _decoration('Mobile number').copyWith(
                  counterText: '',
                  prefixText: '+91 ',
                ),
                validator: (_) => _errorFor(AddressField.phone),
              ),
              AppSpacing.vMd,

              // No email field. Order mail goes to the **account's** address —
              // `OrderHelper` reads `$order->user->email ?: $order->address
              // ->email`, account first — and this route is `auth:sanctum`
              // with guest checkout disabled, so there is always an account.
              //
              // An earlier comment here claimed checkout refuses an address
              // with no email. It does not: `CheckoutRequest` marks the field
              // `nullable` and the live validator passes an email-less
              // address. That claim was inherited, not verified.

              TextFormField(
                key: const Key('address-street'),
                controller: _street,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                enabled: !_saving,
                autovalidateMode: _liveValidation,
                minLines: 2,
                maxLines: 3,
                decoration: _decoration('Flat, building, street, area')
                    .copyWith(alignLabelWithHint: true),
                validator: (_) => _errorFor(AddressField.address),
              ),
              AppSpacing.vMd,
              TextFormField(
                key: const Key('address-zip'),
                controller: _zip,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textInputAction: TextInputAction.next,
                enabled: !_saving,
                autovalidateMode: _liveValidation,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: _decoration('PIN code').copyWith(
                  counterText: '',
                  helperText: 'We fill in the state, city and district for you',
                  suffixIcon: _lookingUpPin
                      ? const Padding(
                          padding: EdgeInsets.all(AppSpacing.sm),
                          child: SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                ),
                validator: (_) => _errorFor(AddressField.zipCode),
              ),
              AppSpacing.vMd,

              TextFormField(
                key: const Key('address-landmark'),
                controller: _landmark,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                enabled: !_saving,
                autovalidateMode: _liveValidation,
                maxLength: AddressDraft.maxRegionLength,
                decoration: _decoration('Landmark', required: false).copyWith(
                  counterText: '',
                  hintText: 'e.g. opposite the bus stand',
                ),
                validator: (_) => _errorFor(AddressField.landmark),
              ),
              AppSpacing.vMd,

              GeoPickerField(
                key: const Key('address-state'),
                label: 'State',
                value: _state?.name,
                hint: 'Select state',
                enabled: !_saving,
                busy: _loadingOptions,
                error: _pickerError(AddressField.state),
                onTap: _saving ? null : _pickState,
              ),
              AppSpacing.vMd,

              GeoPickerField(
                key: const Key('address-city'),
                label: 'City',
                value: _city?.name,
                hint: _state == null ? 'Choose a state first' : 'Select city',
                enabled: !_saving,
                busy: _loadingOptions,
                error: _pickerError(AddressField.city),
                onTap: _saving ? null : _pickCity,
              ),

              if (_isOtherCity) ...[
                AppSpacing.vMd,
                TextFormField(
                  key: const Key('address-other-city'),
                  controller: _otherCity,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  enabled: !_saving,
                  autovalidateMode: _liveValidation,
                  maxLength: AddressDraft.maxRegionLength,
                  decoration: _decoration('Your city or town').copyWith(
                    counterText: '',
                    // The customer picked "Other", so this is the only place
                    // their town is recorded — and the server will 422 without
                    // it.
                    hintText: 'The town this address is in',
                  ),
                  validator: (_) => _errorFor(AddressField.otherCity),
                ),
              ],

              AppSpacing.vMd,
              GeoPickerField(
                key: const Key('address-district'),
                label: 'District',
                required: false,
                value: _district,
                // The hint follows what is actually true of the field: an
                // empty list with a valid PIN in the box is a lookup that is
                // running or that came back empty — not a missing PIN.
                hint: _districtOptions.isNotEmpty
                    ? 'Select district'
                    : CheckoutAddressRules.zipCodeError(_zip.text.trim()) !=
                            null
                        ? 'Enter a PIN code first'
                        : _lookingUpPin
                            ? 'Looking up districts…'
                            : 'No districts found for this PIN',
                enabled: !_saving,
                busy: _lookingUpPin,
                error: _serverErrors[AddressField.district],
                onTap: _saving ? null : _pickDistrict,
              ),


              AppSpacing.vLg,
              _defaultControl(context),
              AppSpacing.vXl,
            ],
          ),
        ),
      ),
      bottomNavigationBar: BottomActionBar(
        child: ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(_isEditing ? 'Save changes' : 'Save address'),
        ),
      ),
    );
  }

  /// A label carrying the asterisk when the field is required.
  ///
  /// [RequiredLabel.inheritStyle] rather than a fixed style, so the decorator
  /// can keep animating the label between its resting and floating sizes.
  InputDecoration _decoration(String label, {bool required = true}) =>
      InputDecoration(
        label: RequiredLabel(
          label,
          required: required,
          style: RequiredLabel.inheritStyle,
        ),
      );

  /// A picker's error, shown only once the customer has tried to save.
  ///
  /// The text fields validate on interaction, but a picker has no "interaction"
  /// short of opening it — painting "Choose a state" in red the moment the form
  /// opens would scold a customer who has not started yet.
  String? _pickerError(String field) {
    if (_serverErrors.isEmpty && !_triedToSave) return null;
    return _draft().validationErrors()[field] ?? _serverErrors[field];
  }

  bool _triedToSave = false;

  /// Promotion control, or a statement that this row already is the default.
  Widget _defaultControl(BuildContext context) {
    if (_isCurrentDefault) {
      return _defaultStatement(
        context,
        'This is your default address. To change it, set another '
        'address as default.',
      );
    }

    if (_willBeFirstAddress) {
      return _defaultStatement(
        context,
        'This will be your default address — your first saved address always '
        'is. Add another later to change it.',
      );
    }

    return AppCard(
      padding: EdgeInsets.zero,
      child: SwitchListTile.adaptive(
        key: const Key('address-default-switch'),
        value: _makeDefault,
        onChanged: _saving
            ? null
            : (value) => setState(() {
                  _makeDefault = value;
                  _defaultTouched = true;
                }),
        title: Text('Make this my default address', style: context.text.title),
        subtitle: Text(
          'Used first at checkout.',
          style: context.text.bodySm,
        ),
      ),
    );
  }

  /// A statement about the default flag, for the two cases where the customer
  /// has no choice to make — this row already is the default, or the server is
  /// about to force it.
  Widget _defaultStatement(BuildContext context, String text) => AppCard(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          children: [
            Icon(
              Icons.check_circle_rounded,
              size: 20,
              color: context.colors.primaryDark,
            ),
            AppSpacing.hSm,
            Expanded(child: Text(text, style: context.text.bodySm)),
          ],
        ),
      );
}

/// The address exactly as the server renders it today.
///
/// Shown while editing as the reference copy: [Address.displayAddress] prefers
/// the server's own `full_address`, which is resolved server-side and ordered
/// the way the courier will read it.
///
/// The same getter the address book, the chooser sheet and the checkout picker
/// render, so one address reads identically everywhere it appears.
class _StoredAddressCard extends StatelessWidget {
  const _StoredAddressCard({required this.address});

  final Address address;

  @override
  Widget build(BuildContext context) => AppCard(
        color: context.colors.surfaceAlt,
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.place_rounded, size: 18, color: context.colors.muted),
            AppSpacing.hSm,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Currently saved as', style: context.text.caption),
                  const SizedBox(height: 2),
                  Text(address.displayAddress, style: context.text.bodySm),
                ],
              ),
            ),
          ],
        ),
      );
}

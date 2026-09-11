import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../data/models/customer.dart';
import '../../providers/auth_provider.dart';
import '../../providers/profile_provider.dart';
import '../../widgets/state_views.dart';
import '../../widgets/app_message.dart';

/// View and edit the signed-in customer's own record.
///
/// Backed by `ProfileController`: `GET /me` to read, `PUT /me` for the details,
/// `POST /update/avatar` for the photo, `PUT /update/password` from
/// [ChangePasswordScreen].
///
/// Name and date of birth are editable; email and phone are shown locked (see
/// the fields themselves for why). `ec_customers` has no `gender`,
/// `description`, `first_name` or `last_name` column even though the controller
/// validates them, so those are not offered at all — the edit would never
/// persist. See [ProfileRepository] for the details.
///
/// There is no account-deletion endpoint, so this screen has no delete action.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();

  DateTime? _dob;

  /// The customer the form was last filled from.
  ///
  /// Two things land here after the first frame — the background `/me` refresh
  /// and the server's copy after a save — and both must reach the form without
  /// overwriting anything the customer is part-way through typing. See
  /// [_pristine].
  Customer? _seededFrom;

  AutovalidateMode _liveValidation = AutovalidateMode.disabled;

  @override
  void initState() {
    super.initState();

    final cached = ref.read(currentCustomerProvider);
    if (cached != null) _seed(cached);

    // OTP verify returns a narrower customer than `/me` — no `dob` — so a
    // customer who has a birthday would see an empty field until this lands.
    // Fire-and-forget: the cached customer is already on screen and a failed
    // refresh must not empty it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(authProvider.notifier).refreshProfile();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// True while every editable box still holds exactly what was seeded into it.
  ///
  /// Once the customer has typed, an arriving refresh must leave the form
  /// alone — losing half-entered text to a background read is worse than a
  /// birthday appearing one beat late.
  bool get _pristine {
    final seeded = _seededFrom;
    if (seeded == null) return true;
    return _name.text == seeded.name && _dob == seeded.dob;
  }

  /// Fills the form from [customer]. Callers own the [setState].
  ///
  /// Never called from `build`: writing to a [TextEditingController] notifies
  /// the mounted [TextFormField], and a `markNeedsBuild` during build is a
  /// framework error. The call sites are [initState] (before the first build,
  /// so no rebuild is owed) and two async points, which wrap it.
  void _seed(Customer customer) {
    if (_seededFrom == customer || !_pristine) return;
    _seededFrom = customer;
    _name.text = customer.name;
    _dob = customer.dob;
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final profile = ref.watch(profileProvider);

    // Carries both the background `/me` refresh and the server's copy after a
    // save into the form. Outside the build phase, which is what makes writing
    // to the controllers safe.
    ref.listen<Customer?>(currentCustomerProvider, (_, next) {
      if (next != null) setState(() => _seed(next));
    });

    ref.listen<ProfileState>(profileProvider, (previous, next) {
      if (next.error != null && next.error != previous?.error) {
        context.showAlertSnack(next.error!);
      }
      if (next.notice != null && next.notice != previous?.notice) {
        context.showSuccessSnack(next.notice!);
      }
    });

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(title: const Text('My profile')),
      body: switch (auth.status) {
        AuthStatus.unknown => const LoadingView(),
        AuthStatus.authenticated when auth.customer != null =>
          _details(auth.customer!, profile),
        _ => const _SignedOut(),
      },
    );
  }

  Widget _details(Customer customer, ProfileState profile) {
    return SafeArea(
      child: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            _AvatarHeader(
              customer: customer,
              uploading: profile.savingAvatar,
              onPick: profile.busy ? null : _pickAvatar,
              onView: profile.busy ? null : () => _viewAvatar(customer),
            ),
            AppSpacing.vLg,

            Text('Your details', style: context.text.title),
            AppSpacing.vSm,

            TextFormField(
              key: const Key('profile-name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              enabled: !profile.busy,
              autovalidateMode: _liveValidation,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: 'Full name',
                counterText: '',
              ),
              validator: _validateName,
            ),
            AppSpacing.vMd,

            // Email and phone are shown but not editable. Both are identity:
            // the email is the password-reset channel, and the phone is what
            // OTP sign-in resolves — and `PUT /me` puts no `unique` rule on it
            // while `OtpController::send` matches with `->first()`, so a typo
            // into someone else's number would silently cost this customer
            // their sign-in. Locking the fields removes that whole class of
            // mistake; a genuine change goes through support.
            _LockedField(
              fieldKey: const Key('profile-email'),
              label: 'Email address',
              value: customer.email,
              empty: 'Not set',
            ),
            AppSpacing.vMd,

            _LockedField(
              fieldKey: const Key('profile-phone'),
              label: 'Mobile number',
              value: customer.phone == null ? null : '+91 ${customer.phone}',
              empty: 'Not set',
            ),
            AppSpacing.vMd,

            _DobField(
              value: _dob,
              enabled: !profile.busy,
              onPick: _pickDob,
            ),

            AppSpacing.vLg,
            FilledButton(
              key: const Key('profile-save'),
              onPressed: profile.busy ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: profile.savingDetails
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Save changes'),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Validation --------------------------------------------------------
  //
  // Mirrors `ProfileController::updateProfile`. The controller answers a
  // rejected save with one concatenated string ("Data invalid! …") and no
  // per-field `errors` map, so nothing the server sends can be attached to the
  // field that caused it — catching what we can locally is the only way the
  // customer sees an error next to the right box.

  String? _validateName(String? _) {
    final value = _name.text.trim();
    if (value.isEmpty) return 'Please enter your name.';
    if (value.length < 2) return 'At least 2 characters.';
    return null;
  }

  // ---- Actions -----------------------------------------------------------

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 25, now.month, now.day),
      firstDate: DateTime(1900),
      // A birthday cannot be in the future. The server does not check this —
      // `date_format` is the only rule — so the picker is the guard.
      lastDate: now,
      helpText: 'Date of birth',
    );
    if (picked != null && mounted) setState(() => _dob = picked);
  }

  /// Opens the photo full screen.
  ///
  /// With no uploaded photo there is nothing to look at — the circle is drawn
  /// from initials — so the tap falls through to picking one instead.
  Future<void> _viewAvatar(Customer customer) async {
    final url = customer.avatar;
    if (url == null) return _pickAvatar();

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _AvatarViewer(
          // The original, with the thumbnail kept as a fallback — see
          // [Customer.avatarOriginal] for why the first one can miss.
          url: customer.avatarOriginal ?? url,
          fallbackUrl: url,
          name: customer.displayName,
        ),
      ),
    );
  }

  Future<void> _pickAvatar() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      // The grabber the sheet is missing without it. It also tells the customer
      // the sheet is draggable, which is how most people dismiss one.
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(sheet, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(sheet, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    final XFile? file;
    try {
      file = await ImagePicker().pickImage(
        source: source,
        // The store enforces its own ceiling inside `RvMedia::handleUpload`,
        // and a modern phone camera clears it easily. Downscaling here turns a
        // rejected upload into a successful one, and an avatar is never shown
        // larger than a few hundred pixels anyway.
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
    } on Object catch (e) {
      // A denied camera/photo permission throws rather than returning null.
      if (mounted) context.showErrorSnack(e, context: 'profile.pickAvatar');
      return;
    }

    if (file == null || !mounted) return;
    await ref.read(profileProvider.notifier).uploadAvatar(file.path);
  }

  Future<void> _save() async {
    setState(() => _liveValidation = AutovalidateMode.onUserInteraction);
    if (!(_form.currentState?.validate() ?? false)) return;

    final customer = ref.read(currentCustomerProvider);
    if (customer == null) return;

    // Only the two editable fields are sent. `email` and `phone` are omitted
    // entirely rather than echoed back — the controller's `nullable` rules mean
    // a null reaches `fill()` and overwrites the column, and there is no reason
    // to re-send a value this screen cannot change.
    final saved = await ref.read(profileProvider.notifier).saveDetails(
          name: _name.text.trim(),
          dob: _dob == customer.dob ? null : _dob,
        );
    if (!saved || !mounted) return;

    // Show what the server stored, not what was typed: the controller accepts
    // fields it then discards, and a rejected value left sitting in the box
    // reads as saved.
    //
    // Done here rather than left to the `currentCustomerProvider` listener,
    // which only fires when the customer actually *changed* — a save the server
    // normalised back to the existing record notifies nobody, and that is
    // precisely the case where the typed text must not survive. Clearing the
    // seed marker first makes the form pristine so [_seed] will act.
    _seededFrom = null;
    final stored = ref.read(currentCustomerProvider);
    if (stored != null) setState(() => _seed(stored));
  }

}

/// A value the customer can see but not change, rendered to match the editable
/// fields beside it so the form reads as one thing.
///
/// Not a disabled [TextFormField]: that greys the value out to the point of
/// being hard to read, and greyed-out normally means "temporarily unavailable"
/// rather than "permanently not yours to edit". The padlock says which.
class _LockedField extends StatelessWidget {
  const _LockedField({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.empty,
  });

  final Key fieldKey;
  final String label;
  final String? value;

  /// Shown when there is nothing stored.
  final String empty;

  @override
  Widget build(BuildContext context) {
    final missing = value == null || value!.isEmpty;
    return InputDecorator(
      key: fieldKey,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: Icon(
          Icons.lock_outline_rounded,
          size: 18,
          color: context.colors.faint,
        ),
      ),
      child: Text(
        missing ? empty : value!,
        style: missing
            ? context.text.body.copyWith(color: context.colors.faint)
            : context.text.body,
      ),
    );
  }
}

/// Circular avatar with a camera badge, plus an upload spinner.
///
/// Two targets, deliberately: the circle itself opens the photo ([onView]) and
/// the badge changes it ([onPick]). Tapping a photo to look at it is what the
/// gesture means everywhere else, so the badge carries the destructive action
/// rather than the whole circle.
class _AvatarHeader extends StatelessWidget {
  const _AvatarHeader({
    required this.customer,
    required this.uploading,
    required this.onPick,
    required this.onView,
  });

  final Customer customer;
  final bool uploading;
  final VoidCallback? onPick;
  final VoidCallback? onView;

  static const double _radius = 44;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        children: [
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              GestureDetector(
                key: const Key('profile-avatar-view'),
                onTap: onView,
                child: CircleAvatar(
                  radius: _radius,
                  backgroundColor: context.colors.primarySurface,
                  // `avatar` is null unless the server holds a real uploaded
                  // image — its generated-initials placeholder is filtered out
                  // in [Customer.fromJson], because the app draws better
                  // initials itself and cannot decode a data URI anyway.
                  backgroundImage: customer.hasAvatar
                      ? CachedNetworkImageProvider(customer.avatar!)
                      : null,
                  child: customer.hasAvatar
                      ? null
                      : Text(
                          customer.initials,
                          style: context.text.h2
                              .copyWith(color: context.colors.primaryDarker),
                        ),
                ),
              ),
              if (uploading)
                Container(
                  height: _radius * 2,
                  width: _radius * 2,
                  decoration: const BoxDecoration(
                    color: Colors.black38,
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: SizedBox(
                      height: 24,
                      width: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              if (!uploading)
                Material(
                  color: context.colors.primaryDark,
                  shape: const CircleBorder(),
                  child: InkWell(
                    key: const Key('profile-avatar-pick'),
                    customBorder: const CircleBorder(),
                    onTap: onPick,
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(
                        Icons.photo_camera_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          AppSpacing.vXs,
          Text(
            uploading ? 'Uploading…' : customer.displayName,
            style: context.text.title,
          ),
        ],
      ),
    );
  }
}

/// The profile photo, full screen and pinch-zoomable.
///
/// [url] is the uploaded original, derived by [Customer.avatarOriginal].
/// [fallbackUrl] is the 150×150 thumbnail the API actually hands out, shown if
/// the original 404s — the derivation is a path transform, not a promise.
class _AvatarViewer extends StatelessWidget {
  const _AvatarViewer({
    required this.url,
    required this.fallbackUrl,
    required this.name,
  });

  final String url;
  final String fallbackUrl;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        // The app bar sits on black, so the light theme's dark icon/status-bar
        // colours have to be overridden explicitly — `foregroundColor` alone
        // loses to `AppTheme`'s `appBarTheme.iconTheme`.
        iconTheme: const IconThemeData(color: Colors.white),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        title: Text(name, style: const TextStyle(color: Colors.white)),
        leading: IconButton(
          key: const Key('avatar-viewer-close'),
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      // `SizedBox.expand` rather than a `Center`: under loose constraints the
      // image lays itself out at its intrinsic pixel size, so a small source
      // rendered as a small square in the middle of a black screen instead of
      // filling it. `BoxFit.contain` then scales it to the viewport.
      body: InteractiveViewer(
        maxScale: 5,
        child: SizedBox.expand(
          child: _image(
            url,
            // One retry, at the size the API vouches for. Nesting rather than
            // looping: the fallback is a different URL, so a plain retry of the
            // same one would fail identically.
            onError: (_, __, ___) => _image(
              fallbackUrl,
              key: const Key('avatar-viewer-image-fallback'),
            ),
          ),
        ),
      ),
    );
  }

  Widget _image(
    String from, {
    Key key = const Key('avatar-viewer-image'),
    LoadingErrorWidgetBuilder? onError,
  }) =>
      CachedNetworkImage(
        key: key,
        imageUrl: from,
        fit: BoxFit.contain,
        placeholder: (_, __) => const Center(
          child: SizedBox(
            height: 32,
            width: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
        ),
        // A cached avatar that 404s after the store cleaned up media should say
        // so rather than leave a black rectangle.
        errorWidget: onError ??
            (_, __, ___) => const Padding(
                  padding: EdgeInsets.all(AppSpacing.xl),
                  child: Center(
                    child: Text(
                      "This photo couldn't be loaded.",
                      style: TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
      );
}

/// Read-only box that opens a date picker — `dob` must reach the server as
/// `dd-MM-yyyy`, so free text is not offered.
class _DobField extends StatelessWidget {
  const _DobField({
    required this.value,
    required this.enabled,
    required this.onPick,
  });

  final DateTime? value;
  final bool enabled;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('profile-dob'),
      onTap: enabled ? onPick : null,
      borderRadius: AppRadius.rSm,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Date of birth',
          enabled: enabled,
          suffixIcon: const Icon(Icons.calendar_today_rounded, size: 18),
        ),
        child: Text(
          value == null ? 'Not set' : Customer.apiDob(value!),
          style: value == null
              ? context.text.body.copyWith(color: context.colors.faint)
              : context.text.body,
        ),
      ),
    );
  }
}

class _SignedOut extends StatelessWidget {
  const _SignedOut();

  @override
  Widget build(BuildContext context) => EmptyView(
        icon: Icons.person_outline_rounded,
        title: 'Sign in to see your profile',
        subtitle: 'Verify your mobile number to view and edit your details.',
        action: FilledButton(
          onPressed: () => context.push('/login'),
          child: const Text('Sign in'),
        ),
      );
}

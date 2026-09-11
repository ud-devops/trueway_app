import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_spacing.dart';
import '../../../core/utils/validators.dart';
import '../../widgets/required_label.dart';
import '../../../core/design_system/theme_context.dart';
import '../../providers/auth_provider.dart';
import 'auth_widgets.dart';
import '../../widgets/app_message.dart';

/// Customer registration — `POST /api/v1/register`.
///
/// Field rules mirror the backend's `RegisterRequest` exactly:
///   name      required (sent instead of first_name/last_name), 2–120 chars
///   email     required, unique, 6–60 chars
///   password  required, min 6, `confirmed`
///   phone     nullable server-side, but REQUIRED here — OTP login resolves
///             customers by phone, so registering without one would lock the
///             customer out of the phone flow permanently.
///
/// The endpoint returns a message, not a token, so [AuthNotifier.register]
/// signs in with the same credentials immediately afterwards.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key, this.prefill});

  final RegisterPrefill? prefill;

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _form = GlobalKey<FormState>();

  /// Lets the password field re-check the confirmation without validating the
  /// whole form — see the note on the password field's `onChanged`.
  final _confirmField = GlobalKey<FormFieldState<String>>();

  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _obscure = true;
  bool _obscureConfirm = true;

  /// Every field validates itself once the customer has interacted with *that*
  /// field, so mistakes are reported as they type rather than all at once on
  /// submit — and, crucially, an untouched field stays quiet.
  static const _liveValidation = AutovalidateMode.onUserInteraction;

  @override
  void initState() {
    super.initState();
    _phone.text = widget.prefill?.phone ?? '';
    _email.text = widget.prefill?.email ?? '';
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;

    final ok = await ref.read(authProvider.notifier).register(
          name: _name.text.trim(),
          email: _email.text.trim(),
          password: _password.text,
          phone: _phone.text.trim(),
        );

    if (!ok || !mounted) return;

    // Registration signs the customer straight in, which previously happened
    // with no acknowledgement at all — the screen just disappeared. The
    // SnackBar is raised on the app-level ScaffoldMessenger, so it survives
    // this route being popped and is still visible on the screen behind.
    final name = ref.read(authProvider).customer?.displayName ?? '';
    context.showSuccessSnack(
      name.isEmpty
          ? 'Your account has been created. You are signed in.'
          : 'Welcome, $name! Your account has been created.',
    );
    context.pop(true);
  }

  /// A label carrying the asterisk that marks the field required.
  ///
  /// **Every field on this form is required** — each one's validator rejects an
  /// empty value, and the backend rejects the request without it — so the
  /// asterisk is unconditional here rather than a parameter.
  ///
  /// [RequiredLabel.inheritStyle] rather than a fixed style, so the decorator
  /// keeps animating the label between its resting and floating positions
  /// instead of freezing it at one size. Same helper shape as
  /// `AddressFormScreen._decoration`.
  InputDecoration _decoration(String label) => InputDecoration(
        label: RequiredLabel(label, style: RequiredLabel.inheritStyle),
      );

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: context.colors.surface,
      appBar: AppBar(
        backgroundColor: context.colors.surface,
        title: const Text('Create your account'),
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('Join Trueway Farms', style: context.text.h1),
              AppSpacing.vLg,

              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                enabled: !auth.busy,
                autovalidateMode: _liveValidation,
                // No input formatter here on purpose: silently swallowing the
                // keypress leaves the customer wondering why the key "doesn't
                // work". Let the character through and explain the rule.
                decoration: _decoration('Full name'),
                validator: nameError,
              ),
              AppSpacing.vMd,

              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                maxLength: 10,
                textInputAction: TextInputAction.next,
                enabled: !auth.busy,
                autovalidateMode: _liveValidation,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: _decoration('Mobile number').copyWith(
                  counterText: '',
                  // `prefixText` only renders once the field has focus, so the
                  // country code was invisible on an empty form. A prefixIcon
                  // is always painted.
                  prefixIcon: CountryCodePrefix(),
                  prefixIconConstraints:
                      BoxConstraints(minWidth: 0, minHeight: 0),
                ),
                validator: (v) =>
                    isValidMobile(v) ? null : 'Enter a valid 10-digit mobile',
              ),
              AppSpacing.vMd,

              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                enabled: !auth.busy,
                autovalidateMode: _liveValidation,
                decoration: _decoration('Email address'),
                validator: (v) =>
                    isValidEmail(v) ? null : 'Enter a valid email address',
              ),
              AppSpacing.vMd,

              TextFormField(
                controller: _password,
                obscureText: _obscure,
                textInputAction: TextInputAction.next,
                enabled: !auth.busy,
                autovalidateMode: _liveValidation,
                // Only re-check the confirmation once it actually has content.
                // Validating the whole form here is what made "Passwords don't
                // match" appear while the customer was still typing the first
                // password, before they had even reached the second field.
                onChanged: (_) {
                  if (_confirm.text.isNotEmpty) {
                    _confirmField.currentState?.validate();
                  }
                },
                decoration: _decoration('Password').copyWith(
                  helperText: kPasswordRequirements,
                  helperMaxLines: 2,
                  errorMaxLines: 2,
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: passwordError,
              ),
              AppSpacing.vMd,

              TextFormField(
                key: _confirmField,
                controller: _confirm,
                obscureText: _obscureConfirm,
                enabled: !auth.busy,
                autovalidateMode: _liveValidation,
                onFieldSubmitted: (_) => _submit(),
                decoration: _decoration('Confirm password').copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(_obscureConfirm
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,),
                    onPressed: () =>
                        setState(() => _obscureConfirm = !_obscureConfirm),
                  ),
                ),
                // The backend's `confirmed` rule would reject a mismatch, but
                // catching it here saves a round trip and a wasted attempt.
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Re-enter your password';
                  return v == _password.text ? null : "Passwords don't match";
                },
              ),

              if (auth.error != null) ...[
                AppSpacing.vMd,
                AuthErrorBanner(
                  message: auth.error!,
                  severity: auth.registeredPendingSignIn
                      ? AuthBannerSeverity.info
                      : AuthBannerSeverity.error,
                  // The account exists; telling them to register again would
                  // just hit the "email already taken" rule.
                  hint: auth.registeredPendingSignIn
                      ? 'Your account was created. If email verification is '
                          'required, check your inbox and then sign in.'
                      : null,
                  action: auth.registeredPendingSignIn
                      ? TextButton(
                          onPressed: () => context.pop(false),
                          child: const Text('Go to sign in'),
                        )
                      : null,
                ),
              ],

              AppSpacing.vLg,
              ElevatedButton(
                onPressed: auth.busy ? null : _submit,
                child: auth.busy
                    ? const AuthSpinner()
                    : const Text('Create account'),
              ),
              AppSpacing.vMd,
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Already have an account?', style: context.text.bodySm),
                  TextButton(
                    onPressed: auth.busy ? null : () => context.pop(false),
                    child: const Text('Sign in'),
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../providers/auth_provider.dart';
import '../../providers/profile_provider.dart';
import '../../widgets/app_message.dart';

/// `PUT /update/password`.
///
/// Rules, from `ProfileController::updatePassword`: both `old_password` and
/// `password` are `required|string|min:6|max:60`. A wrong current password is a
/// **403** carrying "Current password is not valid!" — not a 401 — so the
/// session survives a failed attempt.
///
/// The endpoint changes only the password. It does not revoke tokens, so the
/// customer stays signed in here and on their other devices.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  bool _obscure = true;
  bool _sendingReset = false;
  AutovalidateMode _liveValidation = AutovalidateMode.disabled;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider);
    final email = ref.watch(currentCustomerProvider)?.email;
    final busy = profile.busy || _sendingReset;

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(title: const Text('Change password')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Text(
                'Your password is used for email sign-in. Signing in with your '
                'mobile number and an OTP does not need one.',
                style: context.text.bodySm,
              ),
              AppSpacing.vLg,

              TextFormField(
                key: const Key('password-current'),
                controller: _current,
                obscureText: _obscure,
                enabled: !busy,
                autovalidateMode: _liveValidation,
                maxLength: 60,
                decoration: InputDecoration(
                  labelText: 'Current password',
                  counterText: '',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (_) => _lengthError(_current.text),
              ),
              AppSpacing.vMd,

              TextFormField(
                key: const Key('password-new'),
                controller: _next,
                obscureText: _obscure,
                enabled: !busy,
                autovalidateMode: _liveValidation,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: 'New password',
                  counterText: '',
                ),
                validator: (_) => _lengthError(_next.text),
              ),
              AppSpacing.vMd,

              TextFormField(
                key: const Key('password-confirm'),
                controller: _confirm,
                obscureText: _obscure,
                enabled: !busy,
                autovalidateMode: _liveValidation,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: 'Confirm new password',
                  counterText: '',
                ),
                // Checked here only. The endpoint takes no
                // `password_confirmation`, so a typo would otherwise become a
                // password nobody knows.
                validator: (_) => _confirm.text == _next.text
                    ? null
                    : "The passwords don't match.",
              ),

              AppSpacing.vLg,
              FilledButton(
                key: const Key('password-submit'),
                onPressed: busy ? null : _submit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: profile.savingPassword
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Update password'),
              ),

              // Only offered when there is somewhere to send it. A customer who
              // has only ever used OTP login may not know their password, and
              // the endpoint gives no way to set one without the old value.
              if (email != null && email.isNotEmpty) ...[
                AppSpacing.vMd,
                Center(
                  child: TextButton(
                    onPressed: busy ? null : () => _emailReset(email),
                    child: Text(
                      _sendingReset
                          ? 'Sending…'
                          : "I don't know my current password",
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String? _lengthError(String value) {
    if (value.isEmpty) return 'Required.';
    if (value.length < 6) return 'At least 6 characters.';
    return null;
  }

  Future<void> _submit() async {
    setState(() => _liveValidation = AutovalidateMode.onUserInteraction);
    if (!(_form.currentState?.validate() ?? false)) return;

    final ok = await ref.read(profileProvider.notifier).changePassword(
          currentPassword: _current.text,
          newPassword: _next.text,
        );
    if (!mounted) return;

    if (ok) {
      // The notice snack belongs to the screen the customer lands on, so it is
      // shown here rather than left to the profile screen's listener — popping
      // first would tear down this scaffold's messenger mid-frame.
      context.showSuccessSnack('Password changed.');
      Navigator.of(context).pop();
    } else {
      final error = ref.read(profileProvider).error;
      if (error != null) context.showAlertSnack(error);
    }
  }

  Future<void> _emailReset(String email) async {
    setState(() => _sendingReset = true);
    try {
      await ref.read(authRepositoryProvider).sendPasswordReset(email);
      if (mounted) {
        context.showSuccessSnack('We sent a reset link to $email.');
      }
    } on Object catch (e) {
      if (mounted) context.showErrorSnack(e, context: 'profile.passwordReset');
    } finally {
      if (mounted) setState(() => _sendingReset = false);
    }
  }
}

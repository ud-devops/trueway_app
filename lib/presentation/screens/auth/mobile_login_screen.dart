import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/utils/validators.dart';
import '../../widgets/app_logo.dart';
import '../../../core/design_system/theme_context.dart';
import '../../providers/auth_provider.dart';
import 'auth_widgets.dart';
import '../../widgets/app_message.dart';

/// Sign-in, offering both methods the backend supports:
///
///  * **Phone + OTP** — `/otp/send` then `/otp/verify` (`uminber` plugin).
///  * **Email + password** — `/login` then `/me` (`botble/api` package).
///
/// Both resolve to the same `Customer` and yield a Sanctum token.
class MobileLoginScreen extends ConsumerStatefulWidget {
  const MobileLoginScreen({super.key});

  @override
  ConsumerState<MobileLoginScreen> createState() => _MobileLoginScreenState();
}

enum _Method { phone, email }

class _MobileLoginScreenState extends ConsumerState<MobileLoginScreen> {
  // ───────────────────────────────────────────────────────────────────────
  // ⚠️ TESTING VALUE — RESTORE BEFORE RELEASE
  //
  // How long "Resend OTP" stays disabled after a code is sent. Temporarily
  // 10s so the resend path can be exercised without waiting out the full OTP
  // lifetime.
  //
  // To restore production behaviour set this to `null` — the cooldown then
  // follows the server's own expiry (`expires_in`, 300s), which is correct
  // because resending invalidates the outstanding code.
  //
  // The type stays nullable on purpose: `null` is the documented "no override"
  // value, so narrowing it would remove the way back to production behaviour.
  // ignore: unnecessary_nullable_for_final_variable_declarations
  static const Duration? _resendCooldownOverride = Duration(seconds: 10);
  // ───────────────────────────────────────────────────────────────────────

  _Method _method = _Method.phone;

  final _phone = TextEditingController();
  final _otp = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _otpFocus = FocusNode();
  final _emailForm = GlobalKey<FormState>();

  bool _obscurePassword = true;

  Timer? _ticker;
  int _expiryLeft = 0;
  int _resendLeft = 0;

  @override
  void dispose() {
    _ticker?.cancel();
    _phone.dispose();
    _otp.dispose();
    _email.dispose();
    _password.dispose();
    _otpFocus.dispose();
    super.dispose();
  }

  void _startCountdowns(int expiresInSeconds) {
    _ticker?.cancel();
    setState(() {
      _expiryLeft = expiresInSeconds;
      _resendLeft = _resendCooldownOverride?.inSeconds ?? expiresInSeconds;
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        if (_expiryLeft > 0) _expiryLeft--;
        if (_resendLeft > 0) _resendLeft--;
      });
      if (_expiryLeft == 0 && _resendLeft == 0) t.cancel();
    });
  }

  static String _mmss(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ---- actions ----------------------------------------------------------

  Future<void> _sendOtp() async {
    if (!isValidMobile(_phone.text)) return;
    await ref.read(authProvider.notifier).sendOtp(_phone.text.trim());
  }

  Future<void> _resend() async {
    _otp.clear();
    await ref.read(authProvider.notifier).resendOtp();
  }

  Future<void> _verifyOtp() async {
    if (_otp.text.length != 6) return;
    final ok = await ref.read(authProvider.notifier).verifyOtp(_otp.text.trim());
    if (ok) _finish(announce: true);
  }

  Future<void> _loginWithPassword() async {
    if (!(_emailForm.currentState?.validate() ?? false)) return;
    final ok = await ref.read(authProvider.notifier).loginWithPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
    if (ok) _finish(announce: true);
  }

  Future<void> _goToRegister() async {
    final registered = await context.push<bool>(
      '/register',
      // Carry whatever the customer already typed so they don't retype it.
      extra: RegisterPrefill(
        phone: _method == _Method.phone ? _phone.text.trim() : null,
        email: _method == _Method.email ? _email.text.trim() : null,
      ),
    );
    if ((registered ?? false) && mounted) _finish();
  }

  /// Leaves the auth flow, optionally confirming who was signed in.
  ///
  /// [announce] is false when returning from registration — that screen has
  /// already shown its own "account created" message, and two SnackBars would
  /// replace one another.
  void _finish({bool announce = false}) {
    if (!mounted) return;
    _ticker?.cancel();

    if (announce) {
      final name = ref.read(authProvider).customer?.displayName ?? '';
      context.showSuccessSnack(
        name.isEmpty ? "You're signed in." : 'Welcome back, $name!',
      );
    }

    if (context.canPop()) {
      context.pop(true);
    } else {
      context.go('/');
    }
  }

  void _switchMethod(_Method method) {
    if (_method == method) return;
    ref.read(authProvider.notifier).clearMessages();
    setState(() => _method = method);
  }

  // ---- build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final otpStage = auth.status == AuthStatus.otpPending;

    ref.listen(authProvider, (prev, next) {
      final challenge = next.challenge;
      if (challenge != null && !identical(prev?.challenge, challenge)) {
        _startCountdowns(challenge.expiresIn);
        _otpFocus.requestFocus();
      }
      if (next.notice != null && next.notice != prev?.notice) {
        context.showSuccessSnack(next.notice!);
      }
    });

    return Scaffold(
      backgroundColor: context.colors.surface,
      appBar: AppBar(
        backgroundColor: context.colors.surface,
        leading: BackButton(
          onPressed: () {
            if (otpStage) {
              ref.read(authProvider.notifier).changeNumber();
            } else if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const AppLogo(height: 84),
            AppSpacing.vXl,
            Text(
              otpStage ? 'Verify your number' : 'Login or Sign up',
              style: context.text.display,
            ),
            AppSpacing.vXs,
            Text(
              switch (_method) {
                _ when otpStage =>
                  'Enter the 6-digit code sent to +91 ${auth.challenge?.maskedPhone ?? ''}',
                _Method.phone => 'We will send you a one-time verification code',
                _Method.email => 'Sign in with your email and password',
              },
              style: context.text.body,
            ),
            AppSpacing.vLg,

            // The method switcher is hidden mid-OTP: changing it there would
            // silently abandon a code that has already been sent.
            if (!otpStage) ...[
              _MethodSwitcher(
                selected: _method,
                onChanged: auth.busy ? null : _switchMethod,
              ),
              AppSpacing.vLg,
            ],

            if (otpStage)
              ..._otpStage(auth)
            else if (_method == _Method.phone)
              ..._phoneStage(auth)
            else
              ..._emailStage(auth),

            if (auth.error != null) ...[
              AppSpacing.vMd,
              AuthErrorBanner(
                message: auth.error!,
                hint: auth.unknownPhone
                    ? "There's no account with this number yet."
                    : null,
                action: auth.unknownPhone
                    ? TextButton(
                        onPressed: auth.busy ? null : _goToRegister,
                        child: const Text('Create an account'),
                      )
                    : null,
              ),
            ],

            AppSpacing.vXl,
            if (!otpStage)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("Don't have an account?", style: context.text.bodySm),
                  TextButton(
                    onPressed: auth.busy ? null : _goToRegister,
                    child: const Text('Register'),
                  ),
                ],
              ),
            AppSpacing.vMd,
            Text(
              'By continuing you agree to our Terms & Privacy Policy',
              style: context.text.caption,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _phoneStage(AuthState auth) => [
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          maxLength: 10,
          autofocus: true,
          enabled: !auth.busy,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _sendOtp(),
          decoration: const InputDecoration(
            hintText: 'Mobile number',
            counterText: '',
            prefixIcon: CountryCodePrefix(),
            prefixIconConstraints: BoxConstraints(minWidth: 0, minHeight: 0),
          ),
          style: context.text.h3,
        ),
        AppSpacing.vLg,
        ElevatedButton(
          onPressed: auth.busy || !isValidMobile(_phone.text) ? null : _sendOtp,
          child: auth.busy ? const AuthSpinner() : const Text('Send OTP'),
        ),
      ];

  List<Widget> _emailStage(AuthState auth) => [
        Form(
          key: _emailForm,
          child: Column(
            children: [
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                enabled: !auth.busy,
                // Reports a malformed address as it is typed, but only after
                // this field has been touched.
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration: const InputDecoration(labelText: 'Email address'),
                validator: (v) =>
                    isValidEmail(v) ? null : 'Enter a valid email address',
              ),
              AppSpacing.vMd,
              TextFormField(
                controller: _password,
                obscureText: _obscurePassword,
                autofillHints: const [AutofillHints.password],
                enabled: !auth.busy,
                onFieldSubmitted: (_) => _loginWithPassword(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Enter your password' : null,
              ),
            ],
          ),
        ),
        AppSpacing.vLg,
        ElevatedButton(
          onPressed: auth.busy ? null : _loginWithPassword,
          child: auth.busy ? const AuthSpinner() : const Text('Sign in'),
        ),
      ];

  List<Widget> _otpStage(AuthState auth) => [
        TextField(
          controller: _otp,
          focusNode: _otpFocus,
          keyboardType: TextInputType.number,
          maxLength: 6,
          autofocus: true,
          enabled: !auth.busy,
          textAlign: TextAlign.center,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (v) {
            setState(() {});
            if (v.length == 6) _verifyOtp();
          },
          decoration: const InputDecoration(hintText: '••••••', counterText: ''),
          style: context.text.display.copyWith(letterSpacing: 12),
        ),
        AppSpacing.vSm,
        Text(
          _expiryLeft > 0
              ? 'Code expires in ${_mmss(_expiryLeft)}'
              : 'Your code has expired — request a new one.',
          textAlign: TextAlign.center,
          style: context.text.caption.copyWith(
            color: _expiryLeft > 0 ? context.colors.muted : AppColors.error,
          ),
        ),
        AppSpacing.vLg,
        ElevatedButton(
          onPressed: auth.busy || _otp.text.length != 6 ? null : _verifyOtp,
          child:
              auth.busy ? const AuthSpinner() : const Text('Verify & continue'),
        ),
        AppSpacing.vSm,
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: auth.busy
                  ? null
                  : () => ref.read(authProvider.notifier).changeNumber(),
              child: const Text('Change number'),
            ),
            TextButton(
              // Resending invalidates the outstanding code server-side, so the
              // button is held until the cooldown elapses. In production that
              // cooldown is the code's own lifetime; see
              // _resendCooldownOverride for the shortened testing value.
              onPressed: auth.busy || _resendLeft > 0 ? null : _resend,
              child: Text(
                _resendLeft > 0
                    ? 'Resend in ${_mmss(_resendLeft)}'
                    : 'Resend OTP',
              ),
            ),
          ],
        ),
      ];
}

class _MethodSwitcher extends StatelessWidget {
  const _MethodSwitcher({required this.selected, required this.onChanged});

  final _Method selected;
  final ValueChanged<_Method>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: context.colors.surfaceAlt,
        borderRadius: AppRadius.rPill,
        border: Border.all(color: context.colors.line),
      ),
      child: Row(
        children: [
          _tab(context, _Method.phone, 'Phone & OTP', Icons.smartphone_rounded),
          _tab(context, _Method.email, 'Email & password', Icons.alternate_email_rounded),
        ],
      ),
    );
  }

  Widget _tab(BuildContext context, _Method method, String label, IconData icon) {
    final active = selected == method;
    return Expanded(
      child: GestureDetector(
        onTap: onChanged == null ? null : () => onChanged!(method),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? AppColors.primary : Colors.transparent,
            borderRadius: AppRadius.rPill,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: active ? Colors.white : context.colors.muted,),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.buttonSm.copyWith(
                    color: active ? Colors.white : context.colors.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

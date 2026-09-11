import 'package:flutter/material.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';

/// Values carried from the login screen into registration so the customer
/// doesn't retype what they already entered.
class RegisterPrefill {
  const RegisterPrefill({this.phone, this.email});

  final String? phone;
  final String? email;
}

/// Inline failure banner for the auth screens.
///
/// Shows the server's message verbatim (see docs/ERROR_HANDLING.md), with an
/// optional hint and a call to action for cases the user can resolve — e.g.
/// "no account with this number" offering registration.
class AuthErrorBanner extends StatelessWidget {
  const AuthErrorBanner({
    super.key,
    required this.message,
    this.hint,
    this.action,
    this.severity = AuthBannerSeverity.error,
  });

  final String message;
  final String? hint;
  final Widget? action;
  final AuthBannerSeverity severity;

  @override
  Widget build(BuildContext context) {
    final color = switch (severity) {
      AuthBannerSeverity.error => AppColors.error,
      AuthBannerSeverity.info => AppColors.info,
      AuthBannerSeverity.success => AppColors.success,
    };
    final icon = switch (severity) {
      AuthBannerSeverity.error => Icons.error_outline_rounded,
      AuthBannerSeverity.info => Icons.info_outline_rounded,
      AuthBannerSeverity.success => Icons.check_circle_outline_rounded,
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: AppRadius.rMd,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          AppSpacing.hSm,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: context.text.bodySm.copyWith(color: color)),
                if (hint != null) ...[
                  const SizedBox(height: 4),
                  Text(hint!, style: context.text.caption),
                ],
                if (action != null)
                  Align(alignment: Alignment.centerLeft, child: action!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum AuthBannerSeverity { error, info, success }

/// Always-visible `+91` prefix for mobile-number fields.
///
/// `InputDecoration.prefixText` is only painted while the field has focus, so
/// on an untouched form the country code simply wasn't there. Use as:
///
/// ```dart
/// decoration: const InputDecoration(
///   prefixIcon: CountryCodePrefix(),
///   prefixIconConstraints: BoxConstraints(minWidth: 0, minHeight: 0),
/// )
/// ```
class CountryCodePrefix extends StatelessWidget {
  const CountryCodePrefix({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        child: Text(
          '+91',
          style: context.text.body.copyWith(color: context.colors.ink),
        ),
      );
}

/// Button spinner sized to sit inside an ElevatedButton without resizing it.
class AuthSpinner extends StatelessWidget {
  const AuthSpinner({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
}

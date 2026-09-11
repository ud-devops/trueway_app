import 'package:flutter/material.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/errors/api_exception.dart';
import '../../core/errors/error_presenter.dart';
import '../../core/design_system/theme_context.dart';

class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label});
  final String? label;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.primary),
            if (label != null) ...[
              AppSpacing.vMd,
              Text(label!, style: context.text.bodySm),
            ],
          ],
        ),
      );
}

/// Full-screen failure state.
///
/// Pass the thrown object as [error] — never a pre-formatted string — so the
/// server's own message, its field errors and the debug details all survive.
/// Screens used to do `AppErrorView(message: '$e')`, which showed users
/// `ApiException(422): ...`.
class AppErrorView extends StatelessWidget {
  const AppErrorView({super.key, required this.error, this.onRetry});

  final Object? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final e = ErrorPresenter.resolve(error);
    final heading = ErrorPresenter.title(error);
    final detail = ErrorPresenter.developerDetail(error);
    // Field errors are shown in full; the first one may already be the headline
    // message, in which case don't repeat it.
    final fields = e.allFieldErrors.where((m) => m != e.message).toList();

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_iconFor(e.kind), size: 48, color: context.colors.faint),
            AppSpacing.vMd,
            if (heading != null) ...[
              Text(heading, style: context.text.h3, textAlign: TextAlign.center),
              AppSpacing.vXs,
            ],
            Text(
              e.message,
              style: heading == null ? context.text.h3 : context.text.bodySm,
              textAlign: TextAlign.center,
            ),
            if (fields.isNotEmpty) ...[
              AppSpacing.vSm,
              for (final m in fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '• $m',
                    style: context.text.bodySm.copyWith(color: AppColors.error),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
            if (onRetry != null && e.isRetryable) ...[
              AppSpacing.vLg,
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try again'),
              ),
            ],
            if (detail != null) ...[
              AppSpacing.vMd,
              DeveloperErrorDetails(detail: detail),
            ],
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(ApiErrorKind kind) => switch (kind) {
        ApiErrorKind.network || ApiErrorKind.timeout => Icons.cloud_off_rounded,
        ApiErrorKind.unauthorized ||
        ApiErrorKind.forbidden =>
          Icons.lock_outline_rounded,
        ApiErrorKind.notFound => Icons.search_off_rounded,
        ApiErrorKind.validation => Icons.error_outline_rounded,
        ApiErrorKind.server => Icons.dns_rounded,
        _ => Icons.cloud_off_rounded,
      };
}

/// Collapsed technical detail. Only built in debug/profile builds —
/// [ErrorPresenter.developerDetail] returns null in release.
class DeveloperErrorDetails extends StatelessWidget {
  const DeveloperErrorDetails({super.key, required this.detail});

  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      decoration: BoxDecoration(
        color: context.colors.surfaceAlt,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: context.colors.line),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: Icon(Icons.bug_report_rounded,
              size: 18, color: context.colors.muted,),
          title: Text('Developer details', style: context.text.caption),
          subtitle: Text('debug builds only', style: context.text.caption),
          children: [
            SizedBox(
              width: double.infinity,
              child: SelectableText(
                detail,
                style: context.text.caption.copyWith(
                  fontFamily: 'monospace',
                  color: context.colors.body,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact inline failure for a non-critical section of a screen.
///
/// Home used to render `SizedBox.shrink()` when sliders/ads/categories failed,
/// so a broken endpoint looked identical to "no data" — the section simply
/// vanished. This keeps the page usable while still admitting the failure.
class InlineErrorStrip extends StatelessWidget {
  const InlineErrorStrip({
    super.key,
    required this.error,
    required this.label,
    this.onRetry,
  });

  final Object? error;

  /// What failed to load, e.g. 'offers'.
  final String label;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final e = ErrorPresenter.resolve(error);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.colors.surfaceAlt,
          borderRadius: AppRadius.rMd,
          border: Border.all(color: context.colors.line),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 18, color: context.colors.muted),
            AppSpacing.hSm,
            Expanded(
              child: Text(
                "Couldn't load $label — ${e.message}",
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.caption,
              ),
            ),
            if (onRetry != null && e.isRetryable)
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Retry'),
              ),
          ],
        ),
      ),
    );
  }
}

/// The snack helpers moved to `app_message.dart`.
///
/// They were three shapes with three looks — a bare Material default for
/// success, two different reds for failure, and nothing at all for a warning.
/// `AppMessages` is now the single component behind all of them, so the names
/// callers already use draw one consistent toast. Import `app_message.dart` for
/// `showSuccessSnack`, `showAlertSnack`, `showWarningSnack`, `showInfoSnack`
/// and `showErrorSnack`.

class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    this.action,
  });

  final String title;
  final String? subtitle;

  /// **Required, and deliberately not defaulted.**
  ///
  /// This was `this.icon = Icons.inventory_2_rounded`, and the release build's
  /// icon tree-shaker does not see a glyph that is only ever a default: the
  /// APK's `MaterialIcons` subset carried 104 codepoints and `0xf134` was not
  /// among them. Measured, not assumed — moving the fallback to a static const
  /// field read from `build()` did not help either, and the subset came back
  /// byte-identical at 15,084 bytes.
  ///
  /// Nothing was rendering blank, because all 27 call sites pass an icon. But
  /// the next `EmptyView` written without one would have shown an empty box in
  /// **release only**, and looked perfect in debug where the whole font ships.
  /// Requiring it turns that into a compile error instead, which is the one
  /// version of this bug that cannot reach a customer.
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: context.colors.primarySoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 44, color: AppColors.primary),
              ),
              AppSpacing.vLg,
              Text(title, style: context.text.h3, textAlign: TextAlign.center),
              if (subtitle != null) ...[
                AppSpacing.vXs,
                Text(subtitle!, style: context.text.bodySm, textAlign: TextAlign.center),
              ],
              if (action != null) ...[AppSpacing.vLg, action!],
            ],
          ),
        ),
      );
}

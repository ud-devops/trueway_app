import 'package:flutter/material.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../core/errors/error_presenter.dart';

/// What a message is telling the customer.
///
/// The kind decides the colour and the icon, and nothing else — the same shape,
/// position and timing for all four, so a message is recognisable as a message
/// before it is read.
enum MessageKind {
  /// Something worked. "Added to cart", "Address saved".
  success,

  /// Something did not, and the customer may be able to fix it. A refused
  /// coupon, a quantity over the limit, a failed save.
  error,

  /// It worked, but not entirely, or it needs care. A cart rebuilt with an item
  /// missing; an address with no PIN code.
  warning,

  /// Neutral fact. "Your basket is still here."
  info,
}

extension _KindStyle on MessageKind {
  Color get color => switch (this) {
        MessageKind.success => AppColors.success,
        MessageKind.error => AppColors.error,
        MessageKind.warning => AppColors.warning,
        MessageKind.info => AppColors.info,
      };

  IconData get icon => switch (this) {
        MessageKind.success => Icons.check_circle_rounded,
        MessageKind.error => Icons.error_rounded,
        MessageKind.warning => Icons.warning_rounded,
        MessageKind.info => Icons.info_rounded,
      };

  /// Long enough to read, short enough not to sit over the thing it is about.
  ///
  /// Errors get longer because they usually ask the customer to do something;
  /// a success is a confirmation of what they just did and needs no dwelling.
  Duration get duration => switch (this) {
        MessageKind.success => const Duration(seconds: 2, milliseconds: 500),
        MessageKind.info => const Duration(seconds: 3),
        MessageKind.warning => const Duration(seconds: 4),
        MessageKind.error => const Duration(seconds: 4),
      };
}

/// **The** way this app talks to a customer in passing.
///
/// ## Why one component
///
/// There were three helpers with three different looks: `showSuccessSnack` drew
/// the bare Material default — grey, no icon, indistinguishable from a system
/// message — while `showErrorSnack` and `showAlertSnack` were red boxes that
/// differed from each other in duration and in whether they carried field
/// errors. Nothing marked a warning at all, so "your basket was rebuilt and one
/// item is gone" arrived styled exactly like "Added to cart".
///
/// A customer should be able to tell what kind of thing happened before reading
/// the sentence. That is a property of having one component, not of each caller
/// choosing well.
///
/// ## Why a floating toast rather than a docked SnackBar
///
/// A docked SnackBar occupies the bottom edge, which on this app is where the
/// cart bar, the Place-order button and the bottom navigation live. The message
/// covered the control it was usually about — "Max 3 per order" printed across
/// the "+" the customer had just pressed. Floating with a margin keeps both
/// visible.
///
/// ## What it deliberately does not do
///
/// It does **not** shorten a server message. Clamping to three lines is a
/// display decision and reversible; cutting a sentence is a judgement about
/// meaning, and "Payment failed. Please contact support." would lose the half
/// that matters. Callers that know their own wording is too long should send
/// shorter wording.
void showAppMessage(
  BuildContext context,
  String message, {
  MessageKind kind = MessageKind.info,
  Duration? duration,
  List<String> details = const [],
  SnackBarAction? action,
}) {
  final text = message.trim();
  if (text.isEmpty) return;

  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;

  final extras = details
      .map((d) => d.trim())
      .where((d) => d.isNotEmpty && d != text)
      .toList();

  messenger
    // Replace rather than queue. Tapping "+" four times at the limit used to
    // line up four identical messages, each waiting out the one before it.
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: kind.color,
        elevation: 6,
        margin: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.md,
        ),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.rMd),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        duration: duration ?? kind.duration,
        dismissDirection: DismissDirection.horizontal,
        action: action,
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(kind.icon, color: Colors.white, size: 20),
            AppSpacing.hSm,
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    // Three lines, then ellipsis. A toast that grows to six
                    // lines stops being a toast and covers the screen it is
                    // reporting on.
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodySm.copyWith(color: Colors.white),
                  ),
                  for (final d in extras)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '• $d',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.caption
                            .copyWith(color: Colors.white70),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
}

/// The three names the app already calls, kept so 60-odd call sites need no
/// edit — and so every one of them now draws the same component.
extension AppMessages on BuildContext {
  /// Confirmation of something that worked.
  ///
  /// [duration] shortens it for high-frequency, low-stakes feedback such as
  /// "Added to cart" firing on every tap of a grid tile.
  void showSuccessSnack(String message, {Duration? duration}) =>
      showAppMessage(
        this,
        message,
        kind: MessageKind.success,
        duration: duration,
      );

  /// A problem detected **locally** — an invalid coupon code, a quantity over
  /// the product's limit, a malformed GSTIN.
  ///
  /// Never pass an exception here: `'$e'` is developer output and must not
  /// reach a customer. Use [showErrorSnack], which knows how to read one.
  void showAlertSnack(String message) =>
      showAppMessage(this, message, kind: MessageKind.error);

  /// It worked, but something was lost or needs attention.
  void showWarningSnack(String message, {List<String> details = const []}) =>
      showAppMessage(
        this,
        message,
        kind: MessageKind.warning,
        details: details,
      );

  /// A neutral statement of fact.
  void showInfoSnack(String message) =>
      showAppMessage(this, message, kind: MessageKind.info);

  /// Reports a **thrown object**, so the server's own sentence and its field
  /// errors survive to the screen.
  ///
  /// [context] names the call site for [ErrorLog]; it is not shown.
  void showErrorSnack(Object? error, {String? context}) {
    final e = ErrorPresenter.resolve(error);
    if (context != null) ErrorLog.capture(e, context: context);

    showAppMessage(
      this,
      e.message,
      kind: MessageKind.error,
      // The field errors the server named, minus the one already shown as the
      // headline — repeating it reads as two separate problems.
      details: e.allFieldErrors.where((m) => m != e.message).toList(),
    );
  }
}

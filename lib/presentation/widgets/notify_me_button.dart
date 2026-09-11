import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../data/models/product_model.dart';
import '../providers/auth_provider.dart';
import '../providers/core_providers.dart';
import '../providers/products_provider.dart';
import 'app_message.dart';

/// Back-in-stock subscription — `POST /ecommerce/products/{id}/notify-me`.
///
/// ## The id must be a parent product
///
/// `ProductNotifyController` filters `is_variation: false`, so a **variation
/// id is refused** with *"Product not found."* — there is no way to subscribe
/// to one 5 kg pack. Callers therefore pass the parent product, and a screen
/// that knows only a pack is sold out must say so rather than offering a
/// subscription the server will reject.
///
/// The notification is an **email**, sent by the backend when stock returns, so
/// this needs a signed-in customer with an email on file. Signed out it offers
/// sign-in instead of failing at the request; `ProductNotifyController` is
/// behind `auth:sanctum` and answers an anonymous call with a redirect to the
/// web login page, which is not something to show a customer.
///
/// Every outcome is the server's own sentence — *"We will notify you when this
/// product is back in stock."*, *"Your account does not have a valid email
/// address."*, *"This product is already in stock."* — because each names a
/// different cause and the client cannot tell them apart from a status code.
class NotifyMeButton extends ConsumerStatefulWidget {
  const NotifyMeButton({super.key, required this.product});

  final Product product;

  @override
  ConsumerState<NotifyMeButton> createState() => NotifyMeButtonState();
}

class NotifyMeButtonState extends ConsumerState<NotifyMeButton> {
  bool _sending = false;

  Future<void> _subscribe() async {
    setState(() => _sending = true);
    try {
      final result = await ref
          .read(catalogRepositoryProvider)
          .notifyWhenInStock(widget.product.id);
      if (!mounted) return;

      if (result.subscribed) {
        // Re-read so the button settles into its subscribed state rather than
        // relying on what this call happened to return.
        ref.invalidate(stockSubscriptionProvider(widget.product.id));
        context.showSuccessSnack(result.message);
      } else {
        context.showAlertSnack(result.message);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(isAuthenticatedProvider);
    final subscribed = ref
            .watch(stockSubscriptionProvider(widget.product.id))
            .valueOrNull ??
        false;

    if (subscribed) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_rounded,
              size: 20, color: context.colors.primaryDark,),
          AppSpacing.hSm,
          Flexible(
            child: Text(
              "We'll email you when this is back in stock",
              style: context.text.bodySm
                  .copyWith(color: context.colors.primaryDark),
            ),
          ),
        ],
      );
    }

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _sending
            ? null
            : signedIn
                ? _subscribe
                : () => context.push('/login'),
        icon: _sending
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.notifications_active_rounded, size: 20),
        label: Text(
          signedIn ? 'Notify me when available' : 'Sign in to get notified',
        ),
      ),
    );
  }
}


/// The compact version: the control a sold-out grid tile shows **in place of
/// ADD**.
///
/// It deliberately lives in the button slot rather than over the photo. Drawn
/// in the middle of the image it covered the goods and sat where nothing else
/// on the card is tappable; in the ADD slot it takes the space of the action it
/// replaces, which is exactly what it is — the one thing left to do with a
/// product that cannot be bought.
///
/// **Deliberately does not read `stockSubscriptionProvider`.** That status
/// check is one request per product, and a grid of sold-out tiles would fire
/// one for every card on screen before the customer had asked for anything. So
/// this tile costs nothing until it is tapped, and the outcome it reports is
/// the server's own sentence from the POST — which already distinguishes a new
/// subscription from *"Your account does not have a valid email address."*,
/// *"This product is already in stock."* and an existing one.
class NotifyMeCardButton extends ConsumerStatefulWidget {
  const NotifyMeCardButton({super.key, required this.productId});

  /// Must be a parent product id. A variation is refused — see the library doc.
  final int productId;

  @override
  ConsumerState<NotifyMeCardButton> createState() => _NotifyMeCardButtonState();
}

class _NotifyMeCardButtonState extends ConsumerState<NotifyMeCardButton> {
  bool _sending = false;
  bool _subscribed = false;

  Future<void> _subscribe() async {
    setState(() => _sending = true);
    try {
      final result = await ref
          .read(catalogRepositoryProvider)
          .notifyWhenInStock(widget.productId);
      if (!mounted) return;

      if (result.subscribed) {
        setState(() => _subscribed = true);
        // So a product page opened afterwards shows the subscribed state
        // rather than offering the same subscription again.
        ref.invalidate(stockSubscriptionProvider(widget.productId));
        context.showSuccessSnack(result.message);
      } else {
        context.showAlertSnack(result.message);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(isAuthenticatedProvider);

    // Icon-only: the slot is ~50dp wide, shared with the pack label. The
    // meaning travels in the tooltip and the semantics label instead, both of
    // which say which of the three states this is.
    final (IconData icon, Color color, String label, VoidCallback? onTap) =
        switch ((_subscribed, _sending, signedIn)) {
      (true, _, _) => (
          Icons.check_circle_rounded,
          context.colors.primaryDark,
          "We'll email you when this is back in stock",
          null,
        ),
      (_, true, _) => (
          Icons.notifications_active_rounded,
          context.colors.muted,
          'Setting up your alert',
          null,
        ),
      (_, _, true) => (
          Icons.notifications_active_rounded,
          context.colors.primaryDark,
          'Notify me when back in stock',
          _subscribe,
        ),
      // Signed out the endpoint can only 401, so the offer is sign-in.
      _ => (
          Icons.notifications_active_rounded,
          context.colors.muted,
          'Sign in to get notified',
          () => context.push('/login'),
        ),
    };

    return Tooltip(
      message: label,
      child: Semantics(
        button: onTap != null,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: context.colors.surfaceAlt,
          borderRadius: AppRadius.rSm,
          child: InkWell(
            key: const Key('notify-me-card'),
            onTap: onTap,
            borderRadius: AppRadius.rSm,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: AppRadius.rSm,
                border: Border.all(color: context.colors.line),
              ),
              child: _sending
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(icon, size: 16, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

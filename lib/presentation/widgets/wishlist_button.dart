import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_icons.dart';
import '../../core/design_system/theme_context.dart';
import '../providers/wishlist_provider.dart';
import 'app_message.dart';

/// Saves or removes a product, and says what the **server** did.
///
/// Shared by the grid tile's overlay heart and the product page's app-bar
/// button so the two cannot drift: same provider read, same toggle, same
/// wording, same rule about never flipping optimistically.
///
/// ## Why the flip is never optimistic
///
/// Every mutation on this API opens with `Cart::restore()`, which *deletes* the
/// stored row and only re-stores on the way out — a failure can leave the list
/// empty rather than unchanged (verified live: a DELETE for a product not on
/// the list 404s and wipes everything). So the heart renders only what
/// [WishlistNotifier] last reconciled with the server.
Future<void> toggleWishlist(
  BuildContext context,
  WidgetRef ref,
  int productId, {
  Duration? toastDuration,
}) async {
  final wasSaved = ref.read(wishlistProvider).contains(productId);
  try {
    final saved = await ref.read(wishlistProvider.notifier).toggle(productId);
    if (!context.mounted) return;
    context.showSuccessSnack(
      wishlistConfirmation(wasSaved: wasSaved, saved: saved),
      duration: toastDuration,
    );
  } catch (e) {
    // Catches everything, not just ApiException: only the transport promises
    // that type, and the repository parses the response after the client has
    // returned. `showErrorSnack` takes `Object?` and runs it through
    // ErrorPresenter, so a TypeError can never leak its toString() here.
    //
    // The notifier has already reconciled with the server, so the heart is
    // showing the truth by the time this runs.
    if (!context.mounted) return;
    context.showErrorSnack(e, context: 'wishlist.toggle');
  }
}

/// The message for a toggle that ended with the product [saved] or not, having
/// started [wasSaved].
///
/// "Saved"/"Removed" claim a *change*, and the end state does not always
/// change: a list can hold a variable product's parent row **and** one of its
/// variations at once (verified live — products 111 and 117 on one list), and
/// both rows answer to 111. Removing the parent leaves the variation, so the
/// product is still on the list and the heart correctly stays filled — but the
/// old code read that trailing `true` as an add and announced "Saved to
/// wishlist" for a tap that had just deleted a row. The same reversal appears
/// whenever another device changed the list first. When the state did not move,
/// say what the state *is* rather than inventing an action.
String wishlistConfirmation({required bool wasSaved, required bool saved}) {
  if (saved == wasSaved) {
    return saved ? 'Still on your wishlist' : 'Not on your wishlist';
  }
  return saved ? 'Saved to wishlist' : 'Removed from wishlist';
}

/// The app-bar heart on the product page.
///
/// An `IconButton`, so it lands on the 48dp target and the standard splash that
/// every other action in that bar has — unlike the tile's overlay heart, which
/// is a small disc drawn on top of a photo and has to build its own target.
class WishlistIconButton extends ConsumerWidget {
  const WishlistIconButton({super.key, required this.productId});

  /// May be a parent id — the notifier resolves it to the line the server
  /// actually stored before mutating. [WishlistState.contains] matches a saved
  /// variation against its parent, so the button is filled when one of a
  /// variable product's packs is saved.
  final int productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved =
        ref.watch(wishlistProvider.select((s) => s.contains(productId)));
    final busy = ref.watch(wishlistProvider.select((s) => s.isBusy(productId)));

    return IconButton(
      key: const Key('wishlist-action'),
      tooltip: saved ? 'Remove from wishlist' : 'Save to wishlist',
      // Null while in flight, so a second tap cannot queue a second mutation on
      // a list the first one may still be rewriting.
      onPressed: busy ? null : () => toggleWishlist(context, ref, productId),
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.berry,
              ),
            )
          : Icon(
              AppIcons.heart,
              fill: saved ? 1 : 0,
              color: saved ? AppColors.berry : context.colors.ink,
            ),
    );
  }
}

import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Premium icon set — Material Symbols **Rounded**, a modern variable-icon
/// family. Selected/active states use the FILL axis on the Icon widget
/// (`fill: 1`), which reads far more premium than the default Material glyphs.
///
/// ## Rounded, and every constant says so
///
/// This doc claimed "Rounded" from the start while every constant pointed at
/// `Symbols.<name>` — which is the **Outlined** cut, with square terminals and
/// hard corners. The bottom nav, the bell, the search glass, the map pin and
/// the wishlist heart were all drawn sharp, and against a UI this round
/// (16-20dp corner radii everywhere, pill chips, circular avatars) they were
/// the one hard-edged thing on screen.
///
/// The `_rounded` suffix is the whole difference: same codepoints, softer
/// terminals. Every name below has one — checked against the package — so the
/// family is consistent rather than a mix.
class AppIcons {
  AppIcons._();

  // Bottom nav
  static const IconData home = Symbols.home_rounded;
  static const IconData grid = Symbols.grid_view_rounded;
  static const IconData cart = Symbols.shopping_cart_rounded;
  static const IconData orders = Symbols.receipt_long_rounded;
  static const IconData user = Symbols.person_rounded;

  // Header / nav chrome
  static const IconData bell = Symbols.notifications_rounded;
  static const IconData search = Symbols.search_rounded;
  static const IconData mapPin = Symbols.location_on_rounded;
  static const IconData caretDown = Symbols.expand_more_rounded;
  static const IconData caretRight = Symbols.chevron_right_rounded;
  static const IconData sliders = Symbols.tune_rounded;
  static const IconData sort = Symbols.swap_vert_rounded;

  // Product / commerce
  static const IconData plus = Symbols.add_rounded;
  static const IconData minus = Symbols.remove_rounded;
  static const IconData heart = Symbols.favorite_rounded;
  static const IconData trash = Symbols.delete_rounded;
  static const IconData tag = Symbols.sell_rounded;
  static const IconData percent = Symbols.percent_rounded;
  static const IconData star = Symbols.star_rounded;

  /// For a rating that lands between two whole stars. Same family and metrics
  /// as [star], so a row mixing the two stays evenly spaced.
  static const IconData starHalf = Symbols.star_half_rounded;
  static const IconData bag = Symbols.shopping_bag_rounded;
  static const IconData clock = Symbols.schedule_rounded;
  static const IconData moped = Symbols.moped_rounded;

  // Trust / value badges
  static const IconData leaf = Symbols.eco_rounded;
  static const IconData shield = Symbols.verified_user_rounded;
  static const IconData truck = Symbols.local_shipping_rounded;
  static const IconData returns = Symbols.replay_rounded;

  // Account / misc
  static const IconData sun = Symbols.light_mode_rounded;
  static const IconData moon = Symbols.dark_mode_rounded;
  static const IconData share = Symbols.share_rounded;
  static const IconData info = Symbols.info_rounded;
  static const IconData mail = Symbols.mail_rounded;
  static const IconData storefront = Symbols.storefront_rounded;
  static const IconData checkCircle = Symbols.check_circle_rounded;
  static const IconData cloudOff = Symbols.cloud_off_rounded;
}

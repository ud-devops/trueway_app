import 'package:flutter/widgets.dart';

/// Small responsive helpers so grids/gutters adapt from phone → tablet.
class Responsive {
  Responsive._();

  /// Columns for the home feed's product grids.
  ///
  /// Denser than [productColumns]: home is a browsing surface, so three tiles
  /// across a phone shows more of the catalogue per screen. The card adapts —
  /// its ADD button drops to an icon at this tile width — so the extra column
  /// costs legibility rather than breaking the layout.
  static int homeProductColumns(double width) =>
      width >= 1100 ? 6 : (width >= 900 ? 5 : (width >= 640 ? 4 : 3));

  /// Tile shape for the denser home grid.
  ///
  /// Narrower tiles need proportionally more height, because everything below
  /// the photo — unit price, price, three lines of name, the rating — is a
  /// fixed number of text lines whatever the tile's width. On a three-across
  /// phone that block is about 115dp, so at the old 0.50 a 108dp-wide tile left
  /// the photo only 60dp: a squat strip across a tall card.
  ///
  /// 0.41 gives it roughly a square photo. The photo is an
  /// [Expanded] inside the card, so this ratio is the only thing that decides
  /// how large it gets — and it has to be revisited whenever the block below
  /// gains a line.
  ///
  /// Tablets are untouched: at four across the tiles are already wide enough
  /// that 0.56 leaves a square photo.
  static double homeProductAspect(double width) =>
      width >= 640 ? 0.56 : 0.41;

  static int productColumns(double width) =>
      width >= 1100 ? 5 : (width >= 900 ? 4 : (width >= 640 ? 3 : 2));

  /// Four across a phone: the tile is a circular image over one short label,
  /// so it stays legible where a product tile — which carries a price block and
  /// three lines of name — would not.
  static int categoryColumns(double width) =>
      width >= 900 ? 6 : (width >= 640 ? 5 : 4);

  static double gutter(double width) => width >= 640 ? 24 : 16;

  /// Width / height of a product tile.
  ///
  /// The card's image box is [Expanded], so this controls how much of the tile
  /// the photo gets rather than whether the content fits — the price and name
  /// below take a fixed amount either way.
  ///
  /// Lowered again when the card was restructured: the bordered surface now
  /// wraps only the image (plus the pack/ADD row), and the text sits bare
  /// beneath it. A taller tile turns straight into a larger image.
  ///
  /// 0.47 rather than 0.54 for the same reason as [homeProductAspect]: the
  /// narrowest place this grid runs is CategoryBrowseScreen, whose 88dp rail
  /// leaves 136dp tiles, and there the old ratio left the photo 111dp against
  /// its 136dp width.
  static double productAspect(double width) => width >= 640 ? 0.58 : 0.47;

  static bool isTablet(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 640;
}

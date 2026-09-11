import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_icons.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/app_typography.dart';
import '../../core/utils/price_utils.dart';
import '../../core/design_system/theme_context.dart';
import '../../data/models/home_sections.dart';
import '../../data/models/product_model.dart';
import '../../data/models/product_variation.dart';
import '../../data/models/server_cart.dart';
import '../providers/server_cart_provider.dart';
import '../providers/variation_provider.dart';
import '../providers/wishlist_provider.dart';
import 'app_network_image.dart';
import 'variant_sheet.dart';
import 'app_message.dart';
import 'notify_me_button.dart';
import 'wishlist_button.dart';

/// Type scale for grid tiles.
///
/// A step below the app ramp on purpose. Cards sit three across a phone, and at
/// the global sizes the pack size and the ADD button could not share a line —
/// which is what forced the label to truncate. Smaller type buys that line back
/// and keeps the tile readable rather than crowded.
///
/// Colours still come from the palette, so these follow the theme.
class _CardType {
  const _CardType._();

  static TextStyle pack(BuildContext context) => AppTypography.body
      .copyWith(fontSize: 11, height: 1.1, color: context.colors.body);

  static TextStyle unitPrice(BuildContext context) => AppTypography.caption
      .copyWith(fontSize: 10, height: 1.2, color: context.colors.faint);

  static TextStyle price(BuildContext context) => AppTypography.price
      .copyWith(fontSize: 14, height: 1.2, color: context.colors.ink);

  static TextStyle strike(BuildContext context) => AppTypography.strike
      .copyWith(fontSize: 11, height: 1.2, color: context.colors.faint);

  static TextStyle name(BuildContext context) => AppTypography.body
      .copyWith(fontSize: 12, height: 1.25, color: context.colors.ink);

  /// The review count beside the stars.
  static TextStyle reviewCount(BuildContext context) => AppTypography.caption
      .copyWith(fontSize: 10, height: 1.2, color: context.colors.muted);

  static TextStyle addLabel(BuildContext context) => AppTypography.buttonSm
      .copyWith(fontSize: 11, height: 1, color: context.colors.primaryDark);

  /// The "2 options" line under ADD.
  ///
  /// Subordinate to ADD but still legible — it is the only thing telling the
  /// customer a choice exists, so 8px (where it read as a smudge) was too
  /// small. Lighter weight and a softer green keep ADD the call to action.
  static TextStyle optionsLabel(BuildContext context) =>
      AppTypography.caption.copyWith(
        fontSize: 9,
        height: 1.15,
        fontWeight: FontWeight.w500,
        color: context.colors.primaryDark,
      );
}

/// Cart/wishlist feedback fires on every tap of a grid tile, so it clears fast
/// — long enough to read, short enough not to queue up behind rapid taps.
const _toastDuration = Duration(milliseconds: 900);

/// How much room the block under the photo takes, and how much of the title
/// fits in it.
///
/// **This is what makes every card's image the same size.** The photo is an
/// [Expanded], so it gets the tile height minus whatever this block took — and
/// when the block's height varied per card, so did the photo. A product whose
/// price and MRP wrapped to two lines, or whose name ran to one line instead of
/// three, ended up with a visibly different image from the tile beside it.
///
/// So the block is reserved rather than measured: room for a unit price, two
/// lines of price (whether or not the MRP wrapped), [lines] of name and a rating
/// line, on every card, always. A short title leaves the rest blank, and an
/// unrated product leaves the rating line empty rather than handing the space
/// back to its photo.
///
/// Everything here is derived from the **tile**, never from this product's own
/// content, which is what keeps it identical across a grid — every tile in a
/// grid is the same size, so every card resolves to the same numbers.
///
/// Two things make the reservation adapt rather than be a constant:
///
///  * it is counted in *lines*, so at 2× accessibility text it grows exactly as
///    the text does and the photo gives way instead of the tile overflowing;
///  * [lines] drops below [_nameLines] on a tile too short to afford them. Some
///    grids hand out tiles smaller than their own aspect ratio implies — the
///    home in-category grid sizes its columns from the screen width while being
///    laid out in a narrower box — and a card that insisted on three lines
///    there overflowed by 12dp.
class _CardMetrics {
  const _CardMetrics({required this.height, required this.lines});

  /// Height to reserve for the block under the photo.
  final double height;

  /// Lines of title this tile can afford.
  final int lines;

  /// Everything the bordered surface draws besides the photo: the pack/ADD
  /// row, its padding, and the border.
  static const double surfaceChrome = _AddControl.height + 6 + 2;

  /// Room the surface needs before the photo is worth drawing at all — the
  /// chrome plus a sliver of picture.
  static const double _surfaceFloor = surfaceChrome + 20;

  factory _CardMetrics.of(BuildContext context, double tileHeight) {
    final scaler = MediaQuery.textScalerOf(context);
    double line(TextStyle style) =>
        scaler.scale(style.fontSize ?? 14) * (style.height ?? 1.2);

    final nameLine = line(_CardType.name(context));
    final fixed = line(_CardType.unitPrice(context)) +
        line(_CardType.price(context)) * 2 +
        _priceToNameGap +
        _nameToRatingGap +
        // The stars are icons and do not scale with the text, so the taller of
        // the two governs. At 1x they match by construction.
        _maxDouble(line(_CardType.reviewCount(context)), _RatingLine.starSize);

    var lines = _nameLines;
    if (tileHeight.isFinite) {
      final budget = tileHeight - _photoToTextGap - _surfaceFloor - fixed;
      lines = (budget / nameLine).floor().clamp(1, _nameLines);
    }

    return _CardMetrics(height: fixed + nameLine * lines, lines: lines);
  }
}

double _maxDouble(double a, double b) => a > b ? a : b;

/// Tile height that leaves the photo [photoHeight] tall with the title at its
/// full [_nameLines].
///
/// The inverse of [_CardMetrics.of], and it exists because grids and rails
/// choose their tile height in opposite directions. A grid is handed a
/// `childAspectRatio` and the card fits itself into whatever that produces; a
/// rail has to *pick* a height, and the only sensible height is the one that
/// leaves the photo the shape a photo should be.
///
/// One ratio cannot serve both, because the block under the photo is a fixed
/// number of text lines whatever the tile's width. At [Responsive]'s 0.41 a
/// 108dp grid tile gets a square photo — which is what that number was chosen
/// for — but the rail's tiles are ~125dp wide, and the same ratio there left
/// the photo 148dp tall against its 125dp width: a card noticeably taller than
/// it needed to be, for no gain.
///
/// Text scale is respected, so at 2× the tile grows with the words rather than
/// squeezing the photo to nothing.
double productTileHeightForPhoto(BuildContext context, double photoHeight) =>
    photoHeight +
    _CardMetrics.surfaceChrome +
    _photoToTextGap +
    // `infinity` means "no height pressure", which is what makes this the full
    // three lines rather than however many some tile could afford.
    _CardMetrics.of(context, double.infinity).height;

/// How much of the title a tile shows when it has the room.
///
/// Three, not two: these names are long enough that two lines cut most of them
/// mid-word. Every extra line is paid for out of the photo — the card's height
/// is fixed by the grid — so `Responsive`'s aspect ratios were lowered at the
/// same time to keep the image square. Changing this without changing those
/// makes the photo squat again.
const int _nameLines = 3;

const double _photoToTextGap = 8;
const double _priceToNameGap = 2;
const double _nameToRatingGap = 3;

/// Grocery-style product card.
///
/// Layout, top to bottom:
///   image (flexes) with discount flag + wishlist heart
///   pack size  ·  ADD button
///   unit price (₹/kg)
///   price + struck-through MRP
///   name
///
/// The rating sits on the image as a chip rather than under the name — the
/// text block below stays a clean price → title stack, and the row that used
/// to hold rating + review count + stock note no longer has to fit three
/// variable-width items across a ~160dp tile.
///
/// The image is [Expanded] rather than a fixed [AspectRatio]: these cards sit
/// in grids whose tile height comes from `childAspectRatio`, and a fixed image
/// plus variable text is exactly what makes such tiles overflow on small
/// screens — a square photo overflowed the home rails by 41dp at 2×
/// accessibility text. Letting the image absorb the slack means any aspect
/// ratio, and any text scale, renders cleanly.
///
/// That only produces *equal* images because the block beneath the photo is a
/// reserved constant rather than however much this particular product's price
/// and name happened to need — see [_CardMetrics]. The two go together:
/// take the reservation away and the photo silently starts tracking the length
/// of each title.
class ProductCard extends ConsumerStatefulWidget {
  const ProductCard({
    super.key,
    required this.product,
    this.width,
    this.flashSale,
  });

  final Product product;
  final double? width;

  /// The flash-sale allocation this product is on, when it is on one.
  ///
  /// Adds a stock line — a progress bar and "N left" — beneath the name, and
  /// makes ADD refuse once the allocation is gone. Everything else is the
  /// ordinary card, deliberately: a flash-sale tile that looked like its own
  /// design would read as a different kind of product.
  ///
  /// The **price needs no special handling.** `ProductFlashSalePriceService`
  /// sits in the pipeline behind `front_sale_price`, so the sale price is what
  /// every product endpoint already reports — the pivot override in
  /// `FlashSaleProductResource` produces the same figure.
  final FlashSaleProduct? flashSale;

  @override
  ConsumerState<ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends ConsumerState<ProductCard> {
  /// A variability lookup is in flight for this tile — see [_add].
  bool _checking = false;

  /// This tile's own add is in flight. Distinct from the cart's global `busy`,
  /// which is true for every tile while any one of them is writing.
  bool _adding = false;

  Product get product => widget.product;
  double? get width => widget.width;
  FlashSaleProduct? get flashSale => widget.flashSale;

  @override
  Widget build(BuildContext context) {
    // A variable product's cart line carries the *variation* id, and the
    // catalogue list row gives no hint that a product is variable at all — a
    // simple and a variable product have identical fields. So the tile asks the
    // cart which line this product currently occupies rather than assuming the
    // product id is it; `quantityOfProduct` and `lineForProduct` resolve
    // through the mapping the server handed back on the add.
    final qty = ref.watch(
      serverCartProvider.select((c) => c.quantityOfProduct(product.id)),
    );
    final line = ref.watch(
      serverCartProvider.select((c) => c.lineForProduct(product.id)),
    );
    // This tile's own line, not the cart's global flag. Watching `busy` here
    // rebuilt every tile on screen the moment any one of them wrote, and
    // `select` could not help: the value genuinely did change for all of them.
    final busy = ref.watch(
      serverCartProvider
          .select((c) => line != null && c.isBusyLine(line)),
    );
    final cart = ref.read(serverCartProvider.notifier);
    // A flash-sale row has a **second** stock system on top of the catalogue's:
    // the allocation given to the sale. Either running out means there is
    // nothing to add.
    final soldOut = product.isOutOfStock || (flashSale?.isSoldOut ?? false);

    // Null for a simple product. For a variable one this resolves without the
    // customer doing anything: `variableProductIdsProvider` settles which
    // products are variable for the whole catalogue in two requests, and only
    // those cost a detail lookup to count their packs.
    final optionCount = ref
        .watch(variantCountProvider((id: product.id, slug: product.slug)))
        .valueOrNull;

    return GestureDetector(
      onTap: () => _open(context),
      child: SizedBox(
        width: width,
        // The tile's height is known only here — it comes from the grid's
        // `childAspectRatio`, not from anything the card can see — and
        // [_CardMetrics] needs it to size the block under the photo.
        child: LayoutBuilder(
          builder: (context, tile) => _body(
            context,
            _CardMetrics.of(context, tile.maxHeight),
            cart: cart,
            line: line,
            qty: qty,
            soldOut: soldOut,
            busy: busy,
            optionCount: optionCount,
          ),
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    _CardMetrics metrics, {
    required ServerCartNotifier cart,
    required CartLineId? line,
    required int qty,
    required bool soldOut,
    required bool busy,
    required int? optionCount,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Only the image is a surface: bordered, filled and rounded, with
        // the pack size and ADD button living inside it. Everything below
        // sits bare on the page background.
        //
        // [Expanded], so the photo takes the tile height minus everything
        // below it — which is only safe because everything below it is a
        // *constant* height. See [_CardMetrics]: that reservation is
        // what makes this image the same size on every card, and it is also
        // what lets the photo absorb 2× accessibility text instead of the
        // tile overflowing.
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: context.colors.surface,
              borderRadius: AppRadius.rLg,
              border: Border.all(color: context.colors.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                Expanded(child: _imageArea(context, soldOut)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(5, 0, 5, 6),
                  child: _packAndAddRow(
                    context,
                    cart,
                    line,
                    qty,
                    soldOut,
                    busy,
                    optionCount,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: _photoToTextGap),
        SizedBox(
          height: metrics.height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _priceBlock(context),
              const SizedBox(height: _priceToNameGap),
              // [_nameLines], always — a shorter title leaves the rest
              // blank rather than giving the space back to the photo, which
              // is what made neighbouring images different sizes.
              Text(
                product.name,
                maxLines: metrics.lines,
                overflow: TextOverflow.ellipsis,
                style: _CardType.name(context),
              ),
              const SizedBox(height: _nameToRatingGap),
              // Reserved even when unrated — see [_CardMetrics]. The
              // slot stays, only its contents disappear.
              if (product.rating > 0)
                _RatingLine(
                  rating: product.rating,
                  reviewsCount: product.reviewsCount,
                ),
            ],
          ),
        ),
        if (flashSale != null) ...[
          const SizedBox(height: 6),
          FlashSaleStockLine(entry: flashSale!),
        ],
      ],
    );
  }

  /// ADD: choose a pack if there is one to choose, otherwise add.
  ///
  /// A bare `POST {product_id: parent}` resolves to whichever variation the
  /// server considers default — the ₹921.50 pack for these products — so a
  /// variable product must not be added without asking.
  ///
  /// [variableProductIdsProvider] normally has the answer already, which makes
  /// this instant in both directions: a known-simple product adds with no extra
  /// request, and a known-variable one opens the sheet from cached detail. The
  /// lookup below is the fallback for when that scan has not landed or failed.
  Future<void> _add() async {
    if (_checking || _adding) return;

    // Known simple — nothing to choose, so don't spend a request finding that
    // out.
    final variableIds = ref.read(variableProductIdsProvider).valueOrNull;
    if (variableIds != null && !variableIds.contains(product.id)) {
      await _addDirect();
      return;
    }

    setState(() => _checking = true);
    ProductVariationOptions? options;
    try {
      options =
          await ref.read(knownVariantsProvider.notifier).ensure(product.slug);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
    if (!mounted) return;

    // More than one attribute set means a variation is a *combination*, which a
    // flat sheet would misrepresent. Those go to the detail screen, where the
    // picker resolves one set against another.
    if (options != null && options.isVariable) {
      if (canShowVariantSheet(options)) {
        await showVariantSheet(context, product: product, options: options);
      } else {
        _open(context);
      }
      return;
    }

    // Simple product — or a lookup that failed, in which case the server still
    // rules on the add and names any refusal itself.
    await _addDirect();
  }

  /// Adds the product as it stands, letting the server rule on it.
  ///
  /// Its refusal names the actual constraint — "Maximum quantity is 93!" —
  /// which is better than anything composed here, so it is shown verbatim.
  Future<void> _addDirect() async {
    setState(() => _adding = true);
    String? failure;
    try {
      failure = await ref.read(serverCartProvider.notifier).add(product);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
    if (!mounted) return;
    if (failure == null) {
      _toast(context, 'Added to cart');
    } else {
      context.showAlertSnack(failure);
    }
  }

  /// Opens the product page.
  ///
  /// Guarded on the slug because one source of [Product] does not have one: a
  /// wishlist row for a *variation* comes back with `slug: ""` (verified live —
  /// product 117 on a real list), and `/product/` matches no route, so an
  /// unguarded push lands the customer on the router's error page. There is no
  /// id-based product route to fall back to.
  void _open(BuildContext context) {
    if (product.slug.isEmpty) {
      context.showAlertSnack("This item's product page isn't available.");
      return;
    }
    context.push('/product/${product.slug}', extra: product);
  }

  // ---- image ------------------------------------------------------------

  Widget _imageArea(BuildContext context, bool soldOut) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Edge to edge: no inset, and `cover` so the photo fills the box
        // instead of floating at its own size with white margins around it.
        // The box clips, so the image takes its rounded top corners.
        AppNetworkImage(url: product.primaryImage, fit: BoxFit.cover),
        if (product.hasDiscount)
          Positioned(
            top: 0,
            left: 0,
            child: _DiscountFlag(percent: product.discountPercent),
          ),
        if (soldOut)
          Container(
            color: context.colors.surface.withValues(alpha: 0.72),
            alignment: Alignment.center,
            child: Text(
              'Out of stock',
              style: context.text.buttonSm.copyWith(color: AppColors.error),
            ),
          ),
        // Last, so it stays above the out-of-stock wash. That wash is a
        // `Container` with a colour, which is *opaque to hit tests* — drawn over
        // the heart it swallowed the tap, and the gesture fell through to the
        // card, so hearting a sold-out product opened the product page instead.
        // Saving something that is temporarily unavailable is exactly what a
        // wishlist is for, so the control stays live here.
        //
        // Flush to the corner: the heart insets *itself* by 6 and pads the rest
        // of its 44dp target out into the image — see [_WishlistHeart].
        Positioned(
          top: 0,
          right: 0,
          child: _WishlistHeart(productId: product.id),
        ),
      ],
    );
  }

  // ---- pack size + ADD ---------------------------------------------------

  /// [line] is null until the product is actually in the cart — for a variable
  /// product it is the *variation's* line, which only exists once the server has
  /// resolved one. The stepper is only shown when there is a line to drive.
  Widget _packAndAddRow(
    BuildContext context,
    ServerCartNotifier cart,
    CartLineId? line,
    int qty,
    bool soldOut,
    bool busy,
    int? optionCount,
  ) {
    final pack = product.packLabel;

    return SizedBox(
      // One height whatever the button is showing, so every card in a row puts
      // its price block on the same line.
      height: _AddControl.height,
      child: Row(
        // `spaceBetween`, never a `Spacer`. A Spacer is an `Expanded(flex: 1)`,
        // so it and the Flexible label below split the free space in half and
        // the label gets half the room it should — which is why "5 kg" rendered
        // as "5 …" on a three-column phone tile. Pushing the button right with
        // alignment instead leaves the label everything the button does not
        // need.
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (pack != null)
            // Flexible so an unusually long pack size ellipsizes by a hair
            // rather than pushing the button out of the tile.
            Flexible(
              child: Text(
                pack,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _CardType.pack(context),
              ),
            ),
          const SizedBox(width: 4),
          _AddControl(
            quantity: line == null ? 0 : qty,
            soldOut: soldOut,
            notifyProductId: product.isOutOfStock ? product.id : null,
            // The spinner belongs to the tile doing the work — looking up
            // whether this product has packs, or adding it — not to every tile
            // on screen.
            loading: _checking || _adding,
            // True only while THIS line is being written. It gates taps; it
            // must not change what the control looks like — see [_AddControl].
            busy: busy,
            optionsLabel: optionCount == null ? null : '$optionCount options',
            onAdd: _add,
            // Capped here too, not only in the cart and on the product page.
            // Without it this tile was the one place a customer could push a
            // line past its limit: the request went out, the server refused,
            // and the refusal surfaced two screens away as a red banner in the
            // cart — for a tap made on the home grid.
            //
            // The message is the app's own short sentence rather than the
            // server's, which names the product the customer is already looking
            // at and asks them to "adjust the quantity and try again".
            onInc: line == null || busy
                ? null
                : qty < product.maxCartQuantity
                    ? () => cart.increment(line)
                    : () => context.showAlertSnack(
                          'Sorry, you can only order a maximum of '
                          '${product.maxCartQuantity} units.',
                        ),
            // At the minimum, one more tap **removes the line**. It used to
            // print "Open your cart to remove this item.", which sent the
            // customer to another screen to finish a gesture they had already
            // started here — and for a pack-of-two product it refused twice
            // over. `remove` is the same call the cart screen makes.
            //
            // Stepping to 0 is not a quantity update: this server does not
            // treat 0 as a delete, so `setQuantity` routes it to DELETE itself.
            onDec: line == null || busy
                ? null
                : qty > product.minCartQuantity
                    ? () => cart.decrement(line)
                    : () => cart.remove(line),
          ),
        ],
      ),
    );
  }

  // ---- prices ------------------------------------------------------------

  /// Unit price, then the price and its struck-through MRP.
  ///
  /// The price/MRP pair is a [Wrap], not a [Row]. Two four-figure amounts do not
  /// fit across a three-column tile, and the Row this replaces made both
  /// [Flexible] — so the pair stayed on one line by **ellipsizing the numbers**,
  /// turning ₹1,199.10 into "₹1,19…". A truncated price is worse than no price:
  /// it is quietly wrong rather than obviously missing.
  ///
  /// [Wrap] keeps them side by side whenever they fit and drops the MRP onto its
  /// own line when they do not, with no measuring code and no breakpoint to
  /// maintain. The trade is that Wrap children cannot flex, so each amount is
  /// capped at the tile width by [LayoutBuilder] — a single price wider than the
  /// whole card still has to ellipsize somewhere.
  Widget _priceBlock(BuildContext context) {
    final unit = product.unitPriceLabel;

    return LayoutBuilder(
      builder: (context, constraints) {
        Widget amount(String text, TextStyle style) => ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (unit != null)
              Text(
                unit,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _CardType.unitPrice(context),
              ),
            Wrap(
              spacing: 4,
              // `end` rather than a baseline: Wrap has no baseline alignment,
              // and bottom-aligning two sizes of digits is visually the same
              // thing since neither has a descender.
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                amount(
                  PriceUtils.resolve(product.priceFormatted, product.price),
                  _CardType.price(context),
                ),
                if (product.hasDiscount)
                  amount(
                    PriceUtils.resolve(
                      product.originalPriceFormatted,
                      product.originalPrice,
                    ),
                    _CardType.strike(context),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _toast(BuildContext context, String msg) =>
      context.showSuccessSnack(msg, duration: _toastDuration);
}

/// Rating chip overlaid on the product image: `4.4 ★ | 636`.
///
/// Lives on the photo rather than under the name so the text block below stays
/// a clean price → title stack. It also frees the row that previously had to
/// fit a rating, a review count and a stock note side by side on a ~160dp tile.
class _RatingLine extends StatelessWidget {
  const _RatingLine({required this.rating, required this.reviewsCount});

  final double rating;
  final int reviewsCount;

  /// Deliberately a hard size rather than one scaled by the text scaler:
  /// [_CardMetrics] reserves the larger of this and the count's line, and a
  /// star that grew with the text would make that reservation a moving target.
  static const double starSize = 12;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var position = 1; position <= 5; position++) _star(position),
        if (reviewsCount > 0) ...[
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              _grouped(reviewsCount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _CardType.reviewCount(context),
            ),
          ),
        ],
      ],
    );
  }

  /// The star at [position] (1-5), filled according to [rating].
  ///
  /// Material Symbols is a variable font, so a filled and an empty star are the
  /// same glyph at `fill: 1` and `fill: 0` — they line up exactly, which two
  /// different glyphs would not.
  Widget _star(int position) {
    if (rating >= position) {
      return const Icon(
        AppIcons.star,
        size: starSize,
        fill: 1,
        color: AppColors.warning,
      );
    }
    if (rating >= position - 0.5) {
      return const Icon(
        AppIcons.starHalf,
        size: starSize,
        fill: 1,
        color: AppColors.warning,
      );
    }
    return Icon(
      AppIcons.star,
      size: starSize,
      color: AppColors.warning.withValues(alpha: 0.32),
    );
  }

  /// `89799` → `89,799`. Counts on this store are small today, but the line is
  /// modelled on a marketplace's, and five unseparated digits read as noise.
  static String _grouped(int value) {
    final digits = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

/// Corner discount flag, matching the reference's top-left badge.
class _DiscountFlag extends StatelessWidget {
  const _DiscountFlag({required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(7, 3, 8, 4),
        decoration: const BoxDecoration(
          gradient: AppColors.offerGradient,
          borderRadius: BorderRadius.only(bottomRight: Radius.circular(10)),
        ),
        child: Text(
          '$percent% OFF',
          style: context.text.overline.copyWith(
            color: Colors.white,
            fontSize: 9,
            letterSpacing: 0.2,
          ),
        ),
      );
}

/// The real wishlist toggle, backed by `/ecommerce/wishlist`.
///
/// ## No sign-in gate
///
/// The wishlist endpoints identify a list purely by an opaque id in the path;
/// the bearer token is never consulted. A signed-out visitor keeps a real
/// wishlist and it survives login untouched, so gating this on auth would
/// invent a restriction the server does not have.
///
/// ## Why the flip is never optimistic
///
/// Every mutation on this API opens with `Cart::restore()`, which *deletes* the
/// stored row, and only re-stores on the way out — a failure can leave the list
/// empty rather than unchanged (verified live: a DELETE for a product not on the
/// list 404s and wipes everything). So the heart renders only what
/// [WishlistNotifier] last reconciled with the server. Flipping it on tap and
/// leaving it flipped would claim an item is saved on a list that no longer
/// exists.
///
/// The state also has to be right on the *first* build, not just after a tap:
/// [WishlistState.contains] matches a saved variation against its parent id, so
/// a card for a variable product lights up when one of its variations is saved.
class _WishlistHeart extends ConsumerWidget {
  const _WishlistHeart({required this.productId});

  /// The card's product id. May be a parent id — the notifier resolves it to
  /// the line the server actually stored before mutating.
  final int productId;

  /// The circle you can see. Kept small: it sits on the product photo of a
  /// ~160dp tile and a larger disc would cover the goods.
  static const double _visual = 28;

  /// The area that actually responds to a finger. The visual disc alone is a
  /// 28dp target — well under the 44/48dp minimum — and on the wishlist screen
  /// this *is* the delete button, so a near-miss either does nothing or opens
  /// the product page instead. The extra 16dp is transparent padding spilling
  /// down and left into the image, where nothing else is tappable.
  static const double _target = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Selected rather than watched whole: every tile in a grid subscribes to
    // this provider, and a change to one product must not rebuild the rest.
    final saved =
        ref.watch(wishlistProvider.select((s) => s.contains(productId)));
    final busy = ref.watch(wishlistProvider.select((s) => s.isBusy(productId)));

    return Semantics(
      button: true,
      // A busy heart accepts no tap, and its icon is a spinner — announcing it
      // as "Save to wishlist" would offer a screen-reader user an action that
      // silently does nothing.
      enabled: !busy,
      label: busy
          ? 'Updating wishlist'
          : (saved ? 'Remove from wishlist' : 'Save to wishlist'),
      child: GestureDetector(
        // Opaque so the transparent part of the target still catches the tap
        // instead of letting it through to the card underneath.
        behavior: HitTestBehavior.opaque,
        // Kept non-null while busy so the tap is still swallowed here rather
        // than falling through to the card and opening the product page.
        onTap: busy
            ? () {}
            : () => toggleWishlist(context, ref, productId,
                  toastDuration: _toastDuration,),
        child: SizedBox(
          width: _target,
          height: _target,
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 6, right: 6),
              child: Container(
                width: _visual,
                height: _visual,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: context.colors.surface.withValues(alpha: 0.92),
                  shape: BoxShape.circle,
                  boxShadow: AppShadows.soft,
                ),
                child: busy
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.berry,
                        ),
                      )
                    : Icon(
                        AppIcons.heart,
                        fill: saved ? 1 : 0,
                        size: 15,
                        color: saved ? AppColors.berry : context.colors.muted,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

}

/// "12 left" plus a bar showing how much of a flash-sale allocation has gone.
///
/// ⚠ `sale_percent` is **how much has sold**, not a discount:
/// `($pivot->sold / $pivot->quantity) * 100`. Rendering it as a saving would
/// advertise "80% off" on a sale that is merely 80% gone — the discount comes
/// from `price` against `original_price`, which the price block above already
/// shows.
///
/// Lives here rather than beside the flash-sale rail so the rail can use the
/// ordinary [ProductCard] without the two files importing each other.
class FlashSaleStockLine extends StatelessWidget {
  const FlashSaleStockLine({super.key, required this.entry});

  final FlashSaleProduct entry;

  @override
  Widget build(BuildContext context) {
    // An allocation of zero means the sale is unlimited — there is no progress
    // to show, and a full bar would read as sold out.
    if (entry.saleQuantity <= 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: AppRadius.rPill,
          child: LinearProgressIndicator(
            value: entry.soldFraction,
            minHeight: 4,
            backgroundColor: context.colors.surfaceAlt,
            valueColor: const AlwaysStoppedAnimation(AppColors.accent),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          entry.isSoldOut ? 'Sold out' : '${entry.remaining} left',
          style: AppTypography.caption.copyWith(
            fontSize: 10,
            color: entry.isSoldOut ? AppColors.error : context.colors.muted,
          ),
        ),
      ],
    );
  }
}

/// Outlined ADD button that becomes a compact stepper once in the cart.
///
/// A bordered pill rather than a floating circle, matching the reference, with
/// the variant count tucked underneath when the product has options.
class _AddControl extends StatelessWidget {
  const _AddControl({
    required this.quantity,
    required this.onAdd,
    required this.onInc,
    required this.onDec,
    this.soldOut = false,
    this.notifyProductId,
    this.loading = false,
    this.busy = false,
    this.optionsLabel,
  });

  final int quantity;
  final VoidCallback onAdd;

  /// Null when there is no cart line to drive yet — the control shows ADD.
  final VoidCallback? onInc;
  final VoidCallback? onDec;

  /// Out of stock — the only thing that replaces ADD.
  final bool soldOut;

  /// The product to subscribe to while [soldOut], or null when there is
  /// nothing subscribable. Always a **parent** id; the endpoint refuses a
  /// variation.
  final int? notifyProductId;

  /// **This** tile is working — looking up whether the product has variants, or
  /// adding it. Draws a spinner in place of the label.
  final bool loading;

  /// A cart write is in flight *somewhere*.
  ///
  /// Deliberately changes nothing visually. Writes are serialised because a
  /// queued second one is how this backend loses a cart, so taps are ignored
  /// for the length of the request — but the tile that is not being added to
  /// has no business announcing that, and certainly not by looking sold out.
  final bool busy;

  /// "2 options", printed under ADD when the product has packs to choose from.
  /// Null for a simple product — and also for one whose variability is not yet
  /// known, which is most of them on first paint.
  final String? optionsLabel;

  /// Deliberately compact so the pack size keeps its half of the line on a
  /// three-column phone tile (~96dp of row). This is the size the reference
  /// design uses; it is a dense grid affordance, and the product detail screen
  /// carries a full-width button for anyone who wants a larger target.
  static const double width = 50;

  /// **One height for every state** — plain ADD, the two-line options button
  /// and the stepper alike.
  ///
  /// The options variant was briefly taller (44dp) to give its second line
  /// room. That made the button rows sit at different heights across a grid,
  /// so cards visibly disagreed about where their price block started. Two
  /// small lines fit 32dp with the padding below; consistency across the row
  /// is worth more than the extra 12dp of slack.
  static const double height = 32;

  /// Wider when it carries an options line, so "3 options" is not ellipsised
  /// to "3 opt…" — but only just, because every dp here is taken from the pack
  /// label sharing the row.
  static const double widthWithOptions = 58;

  static double widthFor(bool hasOptions) =>
      hasOptions ? widthWithOptions : width;

  @override
  Widget build(BuildContext context) {
    // The struck-out circle means **out of stock** and nothing else. It used to
    // also stand in for "a cart write is in flight", which painted every tile
    // in the grid as unavailable the moment any one of them was added to — the
    // whole screen looked sold out for the length of a request.
    if (soldOut) {
      // The slot ADD would have occupied, carrying the only action left: ask
      // to be told when it returns. It used to be a struck-out circle — an
      // affordance-shaped thing that did nothing — and the notify control
      // briefly sat over the photo instead, covering the goods.
      //
      // `notifyProductId` is null on a flash-sale row that has merely sold out
      // of its allocation: the product itself is still in stock, and
      // `ProductNotifyController` refuses that with "This product is already in
      // stock." So the dead circle stays for exactly the case where there is
      // genuinely nothing to subscribe to.
      final id = notifyProductId;
      return _frame(
        id == null
            ? Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: context.colors.surfaceAlt,
                  borderRadius: AppRadius.rSm,
                  border: Border.all(color: context.colors.line),
                ),
                child: Icon(Icons.block_rounded,
                    size: 14, color: context.colors.faint,),
              )
            : NotifyMeCardButton(productId: id),
      );
    }

    // `quantity > 0` decides the shape, and nothing else does.
    //
    // This used to also require `onInc != null && onDec != null`, which made a
    // disabled stepper fall through to the ADD button below — so a tile holding
    // three jars visibly turned into "ADD" and back every time a cart write was
    // in flight. A control that is momentarily inert still has the same
    // quantity in it, and must still look like it does. Taps are refused by
    // handing [_step] a null callback, not by rendering a different widget.
    if (quantity > 0) {
      return _frame(
        DecoratedBox(
          decoration: const BoxDecoration(
            color: AppColors.primary,
            borderRadius: AppRadius.rSm,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _step(AppIcons.minus, busy ? null : onDec),
              // The quantity's slot doubles as the acknowledgement. A tap on a
              // 16dp button with no feedback reads as a missed tap, and the
              // customer's next move is to tap again — which this backend
              // handles by dropping the second write, so they get nothing twice.
              //
              // In the number's place, not beside it: the pill keeps its width,
              // its colour and its position, so nothing moves under the finger
              // that just landed.
              if (busy)
                const SizedBox(
                  key: Key('card-stepper-busy'),
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.white,
                  ),
                )
              else
                Text(
                  '$quantity',
                  style: AppTypography.buttonSm
                      .copyWith(fontSize: 11, color: Colors.white),
                ),
              _step(AppIcons.plus, busy ? null : onInc),
            ],
          ),
        ),
      );
    }

    return _frame(
      Material(
        color: context.colors.primarySoft,
        borderRadius: AppRadius.rSm,
        child: InkWell(
          // Inert while this tile is working, and while any other cart write is
          // in flight — but it still *looks* like a button either way.
          onTap: loading || busy ? null : onAdd,
          borderRadius: AppRadius.rSm,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: AppRadius.rSm,
              border: Border.all(color: AppColors.primary, width: 1.2),
            ),
            child: _label(context),
          ),
        ),
      ),
    );
  }

  /// The button's contents.
  ///
  /// A plain [Text] when there is nothing but ADD to say. The two-line form is
  /// only built when there *is* an options line: a [Column] reports overflow
  /// where a centred [Text] silently tolerates it, and at the 30dp compact
  /// height the label already fills the box on a large text scale.
  Widget _label(BuildContext context) {
    if (loading) {
      return const SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 1.6,
          color: AppColors.primary,
        ),
      );
    }

    final add = Text('ADD', style: _CardType.addLabel(context));
    final options = optionsLabel;
    if (options == null) return add;

    return Padding(
      // Tight, because both lines now share the standard 32dp button. Enough
      // that the text is not against the border; no more than that.
      padding: const EdgeInsets.fromLTRB(3, 2, 3, 2),
      child: Column(
        children: [
          // ADD keeps the button's optical centre; the count sits on the
          // bottom edge beneath it, as the reference does. Centring the two as
          // one block instead leaves ADD sitting high and the count floating in
          // the middle, which is what this looked like before.
          Expanded(child: Center(child: add)),
          // The count that tells the customer a choice exists — without it, ADD
          // on a variable product looks like it buys the one price shown above.
          Text(
            options,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _CardType.optionsLabel(context),
          ),
        ],
      ),
    );
  }

  Widget _frame(Widget child) => SizedBox(
        width: widthFor(optionsLabel != null),
        height: height,
        child: child,
      );

  /// A nullable [onTap] is how this refuses a tap. The icon does not dim: at
  /// 12dp on a green pill the difference reads as a rendering glitch, and the
  /// refusal lasts one request.
  Widget _step(IconData icon, VoidCallback? onTap) => InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 16,
          height: height,
          child: Icon(icon, size: 12, color: Colors.white),
        ),
      );
}

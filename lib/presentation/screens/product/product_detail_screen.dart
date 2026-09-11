import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_icons.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/utils/html_utils.dart';
import '../../../core/utils/price_utils.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../data/models/product_model.dart';
import '../../../data/models/product_variation.dart';
import '../../../data/models/review.dart';
import '../../../data/models/server_cart.dart';
import '../../providers/server_cart_provider.dart';
import '../../providers/products_provider.dart';
import '../../providers/review_provider.dart';
import '../../providers/variation_provider.dart';
import '../../widgets/variation_selector.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/cart_badge_button.dart';
import '../../widgets/diet_mark.dart';
import '../../widgets/media_viewer.dart';
import '../../widgets/notify_me_button.dart';
import '../../widgets/product_carousel.dart';
import '../../widgets/quantity_stepper.dart';
import '../../widgets/review_tile.dart';
import '../../widgets/state_views.dart';
import '../../widgets/surfaces.dart';
import '../../widgets/wishlist_button.dart';
import '../../widgets/app_message.dart';

class ProductDetailScreen extends ConsumerWidget {
  const ProductDetailScreen({super.key, required this.slug, this.initial});

  final String slug;
  final Product? initial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(productDetailProvider(slug));

    // `initial` is the row the grid was already showing. It makes the screen
    // paint instantly on tap, but it is a *placeholder*, not a substitute for
    // the fetch: list rows carry no variation block, so returning early on it
    // — which this screen used to do — meant a variable product opened from a
    // grid never showed a picker at all.
    final product = async.valueOrNull?.product ?? initial;

    if (product == null) {
      if (async.isLoading) {
        return const Scaffold(body: LoadingView(label: 'Loading product...'));
      }
      if (async.hasError) {
        return Scaffold(
          appBar: AppBar(),
          body: AppErrorView(
            error: async.error!,
            onRetry: () => ref.invalidate(productDetailProvider(slug)),
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyView(
          title: 'Product not found',
          icon: Icons.search_off_rounded,
        ),
      );
    }

    return _Detail(product: product, slug: slug);
  }
}

class _Detail extends ConsumerStatefulWidget {
  const _Detail({required this.product, required this.slug});
  final Product product;
  final String slug;

  @override
  ConsumerState<_Detail> createState() => _DetailState();
}

class _DetailState extends ConsumerState<_Detail> {
  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final variation = ref.watch(variationProvider(widget.slug));

    // For a variable product the *variation* is what is being priced, stocked
    // and bought — the parent is only a container. Everything below reads
    // through these three, so a picked pack cannot be shown at the parent's
    // price or added at the parent's id.
    final chosen = variation.isVariable ? variation.variation : null;
    final cartId = cartProductIdFor(p, variation);

    // A resolved variation carries its own gallery. The *default* one does not
    // (`image_with_sizes` is null there), so the parent's images stand in until
    // the customer picks something.
    final gallery = (chosen?.images.isNotEmpty ?? false)
        ? chosen!.images
        : p.gallery;

    final qty = cartId == null
        ? 0
        : ref.watch(
            serverCartProvider.select((c) => c.quantityOfProduct(cartId)),
          );

    return Scaffold(
      backgroundColor: context.colors.surface,
      appBar: AppBar(
        backgroundColor: context.colors.surface,
        title: Text(p.store?.name ?? 'Product', style: context.text.title),
        // The heart takes the *parent* id even for a variable product, which is
        // what the notifier resolves against — a saved 5 kg pack lights the
        // heart up on the parent page too.
        actions: [
          WishlistIconButton(productId: p.id),
          const CartBadgeButton(),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          // Gallery. Keyed on the variation's own image set so picking a
          // different pack resets the pager to that pack's first photo rather
          // than keeping page 4 of the previous one — which, on a shorter
          // gallery, showed nothing at all.
          _ProductGallery(
            key: ValueKey(gallery.isEmpty ? p.primaryImage : gallery.first),
            diet: p.dietType,
            media: [
              for (final url in gallery.isNotEmpty ? gallery : [p.primaryImage])
                if (url.isNotEmpty) AppMedia.image(url),
              // Product clips — a YouTube link or a file uploaded to the store,
              // and nothing else. `AppMedia.isPlayable` drops anything that is
              // neither, which today means the Amazon Live page sitting on
              // products 123 and 125: an admin slip that would otherwise open a
              // third-party storefront inside this page.
              for (final video in p.videos)
                if (video.url.isNotEmpty)
                  if (AppMedia.video(video.url, thumbnail: video.thumbnail)
                      case final clip when clip.isPlayable)
                    clip,
            ],
          ),

          Padding(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _stockChip(p, chosen),
                    const Spacer(),
                    if (p.rating > 0) ...[
                      const Icon(Icons.star_rounded, color: AppColors.accent, size: 18),
                      const SizedBox(width: 3),
                      Text('${p.rating.toStringAsFixed(1)}  (${p.reviewsCount})',
                          style: context.text.bodySm,),
                    ],
                  ],
                ),
                AppSpacing.vSm,
                Text(p.name, style: context.text.h2),
                AppSpacing.vXs,
                // The variation has its own SKU — the pack the customer is
                // actually buying, not the parent container.
                Text('SKU: ${chosen?.sku ?? p.sku}', style: context.text.caption),
                AppSpacing.vMd,
                _priceRow(context, p, chosen),
                Text('Inclusive of all taxes', style: context.text.caption),
                if (variation.isVariable) ...[
                  const Divider(height: 32),
                  VariationSelector(
                    sets: variation.options.attributeSets,
                    selection: variation.selection,
                    unavailableIds: variation.unavailableAttributeIds,
                    enabled: !variation.resolving,
                    onSelect: (setId, attributeId) => ref
                        .read(variationProvider(widget.slug).notifier)
                        .select(setId, attributeId),
                  ),
                  // The server's own line — "98 products available" — rather
                  // than anything composed from `quantity` here.
                  if (chosen?.successMessage != null)
                    Text(
                      chosen!.successMessage!,
                      style: context.text.caption
                          .copyWith(color: context.colors.savings),
                    ),
                  if (variation.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        variation.error!.message,
                        style: context.text.bodySm
                            .copyWith(color: AppColors.accent),
                      ),
                    ),
                ],
                if (p.conditions.isNotEmpty) ...[
                  AppSpacing.vMd,
                  _ConditionsRow(conditions: p.conditions),
                ],
                const Divider(height: 32),
                _ProductDetails(product: p),
                const Divider(height: 32),
                ProductReviewsSection(slug: p.slug, product: p),
                _MerchandisingRail(
                  slug: p.slug,
                  title: 'You may also like',
                  provider: relatedProductsProvider,
                ),
                _MerchandisingRail(
                  slug: p.slug,
                  title: 'Frequently bought together',
                  provider: crossSaleProductsProvider,
                ),
                const SizedBox(height: 90),
              ],
            ),
          ),
        ],
      ),
      bottomSheet: _bottomBar(context, p, qty, cartId, chosen),
    );
  }

  /// The price of the thing being bought.
  ///
  /// For a variable product that is the **variation's** price, and both figures
  /// come from the server's own formatted strings — `formatted_sale_price` and
  /// `formatted_original_price`, whose meanings are inverted relative to the
  /// rest of the API. Reading the parent's price here would quote the default
  /// pack's ₹921.50 under a ₹493.50 pack the customer had just selected.
  Widget _priceRow(BuildContext context, Product p, ProductVariation? chosen) {
    final price = chosen?.priceFormatted ??
        PriceUtils.resolve(p.priceFormatted, p.price);
    final original = chosen?.originalPriceFormatted ??
        PriceUtils.resolve(p.originalPriceFormatted, p.originalPrice);
    final hasDiscount = chosen?.hasDiscount ?? p.hasDiscount;
    final percent = chosen?.discountPercent ?? p.discountPercent;

    // The pack's own rate, so two sizes of the same product can be compared at
    // a glance. Null when the catalogue records no weight — never guessed.
    final unit = chosen?.unitPriceLabel ?? p.unitPriceLabel;

    // Two lines: what it costs, then what that saves.
    //
    // All four used to sit in one [Row] with no flexible child, so nothing
    // could give and the line overflowed — 0.058px on this catalogue's longest
    // name, and far more at a large OS text scale. Splitting it is also the
    // better reading: the price is the answer, and the MRP and the percentage
    // are the argument for it.
    //
    // Each line is a [Wrap] rather than a [Row] so neither can overflow on its
    // own account either. At 2x text the discount drops below the struck-out
    // price instead of running off the card.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: AppSpacing.xs,
          children: [
            Text(price, style: context.text.priceLg),
            // The pack's own rate, so two sizes of the same product can be
            // compared at a glance.
            if (unit != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('($unit)', style: context.text.caption),
              ),
          ],
        ),
        if (hasDiscount) ...[
          const SizedBox(height: 2),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppSpacing.xs,
            children: [
              Text(
                original,
                style: context.text.strike.copyWith(fontSize: 15),
              ),
              Text(
                '$percent% off',
                style:
                    context.text.title.copyWith(color: context.colors.savings),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Stock for the selected variation, not the parent.
  ///
  /// A variable product's parent reports the stock of the whole set; one pack
  /// can be sold out while another is not, so the chip has to follow the pick.
  Widget _stockChip(Product p, ProductVariation? chosen) {
    final outOfStock = chosen?.isOutOfStock ?? p.isOutOfStock;
    final label = chosen?.stockStatusLabel ?? p.stockStatusLabel;
    final ok = !outOfStock;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: ok ? context.colors.primarySoft : context.colors.accentSoft,
        borderRadius: AppRadius.rPill,
      ),
      child: Text(
        label,
        style: context.text.overline.copyWith(
          color: ok ? context.colors.primaryDarker : AppColors.accent,
        ),
      ),
    );
  }

  /// The buy bar.
  ///
  /// [cartId] is what gets posted: the product's own id for a simple product,
  /// the **variation's** id for a variable one. It is null while a resolve is
  /// in flight, and then both buttons are disabled — adding at that moment
  /// would post the previous pack's id under the new pack's name.
  Widget _bottomBar(
    BuildContext context,
    Product p,
    int qty,
    int? cartId,
    ProductVariation? chosen,
  ) {
    final cart = ref.read(serverCartProvider.notifier);
    final busy = ref.watch(serverCartProvider.select((c) => c.busy));
    final outOfStock = chosen?.isOutOfStock ?? p.isOutOfStock;
    final canBuy = cartId != null && !outOfStock && !busy;

    // Nothing to buy — offer to tell them when there is. Two disabled buttons
    // is the one thing this bar must not be: it leaves the customer with no
    // action at all on a product they came here for.
    //
    // But only the *parent* can be subscribed to: `ProductNotifyController`
    // filters `is_variation: false`, so a pack id is refused with "Product not
    // found." — and when the parent is in stock and merely this pack is not,
    // the same call is refused again with "This product is already in stock."
    // Offering the button there is a dead end either way, so a sold-out pack
    // gets the truth and a way forward instead: the picker above already marks
    // which packs are available.
    if (outOfStock) {
      final parentInStock = !p.isOutOfStock;
      return BottomActionBar(
        child: parentInStock
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 20, color: context.colors.muted,),
                  AppSpacing.hSm,
                  Flexible(
                    child: Text(
                      'This pack is sold out. Choose another size above.',
                      style: context.text.bodySm,
                    ),
                  ),
                ],
              )
            : NotifyMeButton(product: p),
      );
    }

    // The line the stepper drives. For a variation this is the variation id,
    // which is what the cart line comes back carrying — passing the parent id
    // would add a duplicate line on PUT and 404 on DELETE, and a 404 delete
    // wipes the whole cart.
    final line = cartId == null ? null : CartLineId.forSimpleProduct(cartId);

    // The chosen variation's limits win over the parent's: a 5 kg pack and a
    // 500 g pack of one product routinely carry different caps, and the cart
    // line that results is the variation's.
    final minQty = chosen?.minCartQuantity ?? p.minCartQuantity;
    final maxQty = chosen?.maxCartQuantity ?? p.maxCartQuantity;

    Future<void> addToCart() async {
      if (cartId == null) return;
      // Opens at the server's MINIMUM, not at 1. `Sona Moti Wheat` is sold in
      // twos on this catalogue, so adding one would be refused — and a refusal
      // on this backend takes the whole basket with it, because
      // `Cart::restore()` deletes the stored row before the branch that
      // rejects. See `docs/BACKEND_BUGS.md` finding 0.
      //
      // The server still rules on stock and maximums; its refusal names the
      // constraint, so it is shown as-is when one gets through anyway.
      final failure = await cart.addProductId(cartId, quantity: minQty);
      if (!context.mounted) return;
      if (failure == null) {
        context.showSuccessSnack('Added to cart');
      } else {
        context.showAlertSnack(failure);
      }
    }

    return BottomActionBar(
      child: Row(
        children: [
          if (qty > 0 && line != null)
            QuantityStepper(
              quantity: qty,
              // This line's write, not the cart's global flag — the bar sits
              // under the product whose quantity is changing.
              busy: ref.watch(
                serverCartProvider.select((c) => c.isBusyLine(line)),
              ),
              // At the cap the button says why rather than going grey. The
              // sentence is built from `max_cart_quantity`, not forwarded from
              // the server: `POST /cart` refuses with the STOCK level
              // ("Maximum quantity is 85558!") instead of the cap of 3 the same
              // payload states, and `PUT /cart/{id}` does not enforce the cap
              // at all. See `docs/BACKEND_BUGS.md` finding 15.
              onIncrement: qty < maxQty
                      ? () => cart.increment(line)
                      : () => context.showAlertSnack(
                            'Sorry, you can only order a maximum of '
                            '$maxQty units.',
                          ),
              // `qty <= minQty` rather than `<= 1`: stepping a pack-of-two
              // product down to one is a quantity the server rejects.
              // At the minimum, one more tap **removes the line** rather than
              // sending the customer to the cart to finish the gesture they
              // started here. A pack-of-two product cannot step down to one,
              // but it can certainly be taken out of the basket.
              onDecrement: qty > minQty
                      ? () => cart.decrement(line)
                      : () => cart.remove(line),
            )
          else
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canBuy ? addToCart : null,
                icon: const Icon(AppIcons.cart, size: 20),
                label: const Text('Add to cart'),
              ),
            ),
          AppSpacing.hSm,
          Expanded(
            child: ElevatedButton(
              // Was `onPressed: p.isOutOfStock ? null : ...`, which navigated
              // to the cart without waiting for the add and ignored a refusal
              // entirely — "Buy now" on an out-of-stock pack opened an empty
              // cart with no explanation.
              // Straight to checkout, not to the basket.
              //
              // "Buy now" and "Add to cart" used to end in the same place,
              // which made the second button a slower version of the first.
              // This one now skips the basket entirely: one unit in, and the
              // next thing the customer sees is the address and the bill.
              //
              // The quantity is not fixed at one — checkout's Items section
              // carries a counter, so it can be raised there without leaving
              // the payment flow.
              //
              // Waits for the add and honours a refusal, as it has since
              // "Buy now" on an out-of-stock pack used to open an empty cart
              // with no explanation.
              // A cart of its own, holding this product and nothing else.
              //
              // Not the basket. The customer's basket is a different cart with
              // a different server id, and it is neither carried to checkout
              // nor emptied by buying something else — which is the whole
              // shape of the shortcut: one product, straight to payment, with
              // the shopping they have not finished left exactly where it is.
              //
              // The flag is set before the push so the bill, the parcel weight
              // and the courier quote are all computed for this product from
              // the checkout screen's first build.
              onPressed: canBuy
                  ? () async {
                      final failure = await ref
                          .read(buyNowCartProvider.notifier)
                          .startBuyNow(cartId);
                      if (!context.mounted) return;
                      if (failure != null) {
                        context.showAlertSnack(failure);
                        return;
                      }
                      ref.read(checkoutCartProvider.notifier).state =
                          CheckoutCart.buyNow;
                      context.push('/checkout');
                    }
                  : null,
              child: const Text('Buy now'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The product's photos and clips, swipeable left/right.
///
/// The thumbnail rail is kept as a second way in — it is the only affordance
/// that shows *how many* there are before you start swiping — but it now drives
/// the same pager rather than a separate index, and it scrolls itself so the
/// selected tile cannot end up off screen after a few swipes.
///
/// Tapping the big image opens the full-screen viewer at the current page;
/// videos play inline in the pager as well, so a customer who never taps still
/// gets the clip.
class _ProductGallery extends StatefulWidget {
  const _ProductGallery({super.key, required this.media, this.diet});

  final List<AppMedia> media;

  /// Stamped over the image, bottom-right. Null on a product whose catalogue
  /// never stated a diet — see [Product.dietType] — and then nothing is drawn.
  final DietType? diet;

  @override
  State<_ProductGallery> createState() => _ProductGalleryState();
}

class _ProductGalleryState extends State<_ProductGallery> {
  final _pager = PageController();
  final _rail = ScrollController();
  int _index = 0;

  static const double _thumb = 56;
  static const double _thumbGap = 8;

  @override
  void dispose() {
    _pager.dispose();
    _rail.dispose();
    super.dispose();
  }

  void _goTo(int i) {
    _pager.animateToPage(
      i,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  void _onPageChanged(int i) {
    setState(() => _index = i);
    if (!_rail.hasClients) return;
    // Centre the newly selected tile in the rail, clamped to its extent.
    final target = (i * (_thumb + _thumbGap)) -
        (_rail.position.viewportDimension / 2) +
        (_thumb / 2);
    _rail.animateTo(
      target.clamp(
        _rail.position.minScrollExtent,
        _rail.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.media;
    if (media.isEmpty) {
      return AspectRatio(
        aspectRatio: 1,
        child: Container(color: context.colors.surfaceAlt),
      );
    }

    return Container(
      color: context.colors.surfaceAlt,
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              children: [
                PageView.builder(
                  controller: _pager,
                  itemCount: media.length,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, i) {
                    final item = media[i];
                    return GestureDetector(
                      onTap: () =>
                          showMediaViewer(context, media, initialIndex: i),
                      // A clip shows its poster under a play button rather than
                      // a live player. Every product video on this catalogue is
                      // a hosted *page* — a YouTube embed or an Amazon Live
                      // page — so an inline player meant a full third-party page
                      // loading inside a square in a scrolling list. The poster
                      // is a real still on all of them, so there is something
                      // honest to show until the customer asks for the video.
                      child: item.isVideo
                          ? _VideoPoster(media: item)
                          : AppNetworkImage(
                              url: item.url,
                              fit: BoxFit.contain,
                              backgroundColor: Colors.transparent,
                            ),
                    );
                  },
                ),
                if (media.length > 1)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 8,
                    child: MediaPageDots(count: media.length, index: _index),
                  ),
                // Bottom-right, clear of the dots, and on every page rather
                // than only the first — it labels the product, not the photo.
                if (widget.diet != null)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: DietMark(diet: widget.diet),
                  ),
              ],
            ),
          ),
          if (media.length > 1)
            SizedBox(
              height: 72,
              child: ListView.separated(
                controller: _rail,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                itemCount: media.length,
                separatorBuilder: (_, __) => const SizedBox(width: _thumbGap),
                itemBuilder: (_, i) => GestureDetector(
                  onTap: () => _goTo(i),
                  child: Container(
                    width: _thumb,
                    decoration: BoxDecoration(
                      borderRadius: AppRadius.rSm,
                      border: Border.all(
                        color: i == _index
                            ? AppColors.primary
                            : context.colors.line,
                        width: i == _index ? 1.8 : 1,
                      ),
                    ),
                    child: MediaThumb(
                      media: media[i],
                      size: _thumb,
                      onTap: () => _goTo(i),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The merchant's promise badges, straight from `product_conditions`.
///
/// **Every word and icon here is the server's.** This row used to be four
/// hard-coded badges — "100% Organic", "Tracked shipping", "Secure payment",
/// "Easy returns" — printed on every product regardless of what the merchant
/// had configured. On product 120 that last one was flatly false: the backend's
/// own fourth condition reads **"No Return"**. The app was promising a returns
/// policy the store does not offer.
///
/// Nothing is drawn when the list is empty (product 125 returns `[]`), because
/// an empty answer is still the merchant's answer.
///
/// The icon is whatever image the merchant uploaded. There is no local icon
/// fallback by design: guessing a leaf for a title we cannot read would put us
/// straight back to inventing badges.
class _ConditionsRow extends StatelessWidget {
  const _ConditionsRow({required this.conditions});

  final List<ProductCondition> conditions;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final condition in conditions)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: context.colors.primarySoft,
                      shape: BoxShape.circle,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: condition.image == null
                        ? Icon(
                            Icons.verified_rounded,
                            color: context.colors.primaryDark,
                            size: 22,
                          )
                        // Fills the disc rather than sitting inside it.
                        // `contain` left each icon floating in a ring of
                        // background, and since the merchant's uploads are
                        // different shapes (a wide .jpg doodle, a square .png,
                        // a logo) they all floated by different amounts — four
                        // badges that never looked like one row.
                        : AppNetworkImage(
                            url: condition.image!,
                            width: 44,
                            height: 44,
                            backgroundColor: Colors.transparent,
                          ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    condition.title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.caption
                        .copyWith(color: context.colors.body),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// "Product details" — the specification table first, the long copy behind a
/// toggle.
///
/// `description` is the compact spec table (brand, net quantity, shelf life);
/// `content` is the several-hundred-word "About this item" marketing copy.
/// Showing the copy first pushed the facts a customer actually came for below
/// two screens of prose, so the order is inverted and the copy is collapsed.
///
/// The toggle is only built when there is something behind it, so a product
/// with no `content` does not get a "Show more" that reveals nothing.
class _ProductDetails extends StatefulWidget {
  const _ProductDetails({required this.product});

  final Product product;

  @override
  State<_ProductDetails> createState() => _ProductDetailsState();
}

class _ProductDetailsState extends State<_ProductDetails> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final hasDescription = p.description.isNotEmpty;
    final hasContent = p.content.isNotEmpty;
    if (!hasDescription && !hasContent) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Product details', style: context.text.h3),
        AppSpacing.vSm,
        if (hasDescription)
          // Relaxed first: the pasted spec table pins its cells to desktop
          // widths (`<td style="width:484.962px">`), which is a phone-width
          // table trying to be 485px wide.
          HtmlWidget(
            relaxPastedLayout(p.description),
            textStyle: context.text.bodySm,
          ),
        if (hasContent) ...[
          if (_expanded) ...[
            AppSpacing.vMd,
            HtmlWidget(
              // Amazon's collapsed-expander wrapper rides along in the paste
              // with `max-height:300px` on it. That ceiling — not our layout —
              // is the "BOTTOM OVERFLOWED BY 80 PIXELS" stripe.
              relaxPastedLayout(p.content),
              textStyle: context.text.body,
              customStylesBuilder: (e) => e.localName == 'a'
                  ? {'color': '#2E8B39', 'text-decoration': 'none'}
                  : null,
            ),
          ],
          AppSpacing.vXs,
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('product-details-toggle'),
              onPressed: () => setState(() => _expanded = !_expanded),
              icon: Icon(
                _expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 20,
              ),
              label: Text(_expanded ? 'Show less' : 'Show more'),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
            ),
          ),
        ],
      ],
    );
  }
}

/// A clip's page in the gallery: its still, under a play button.
///
/// Falls back to a plain dark panel when the server sent no usable poster —
/// never to the clip's own URL, which for a review video *is* the .mp4.
class _VideoPoster extends StatelessWidget {
  const _VideoPoster({required this.media});

  final AppMedia media;

  @override
  Widget build(BuildContext context) {
    final poster = media.posterUrl;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (poster != null)
          AppNetworkImage(
            url: poster,
            fit: BoxFit.contain,
            backgroundColor: Colors.transparent,
          )
        else
          Container(color: context.colors.surfaceAlt),
        Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: Colors.black45,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 38,
            ),
          ),
        ),
      ],
    );
  }
}

/// A merchandising rail — "You may also like", "Frequently bought together".
///
/// Draws **nothing at all** unless the server named products: no heading, no
/// spinner, no empty state. Both endpoints are advisory, both can be empty (
/// cross-sale is empty for every product on this store today), and a skeleton
/// that resolves to nothing is worse than never having appeared.
class _MerchandisingRail extends ConsumerWidget {
  const _MerchandisingRail({
    required this.slug,
    required this.title,
    required this.provider,
  });

  final String slug;
  final String title;
  final AutoDisposeFutureProviderFamily<List<Product>, String> provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(provider(slug)).valueOrNull ?? const <Product>[];
    if (products.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ProductCarousel(title: title, products: products),
    );
  }
}

/// The reviews block on the product page.
///
/// Shows at most [previewCount] reviews and defers the rest to a sheet, because
/// the feed is unbounded and every row can carry media. The signed-in
/// customer's own review is pinned above the rest (the notifier has already
/// removed it from the body list, so it cannot appear twice).
///
/// There is deliberately no star-count histogram: the API publishes no per-star
/// breakdown on any endpoint, and faking one would mean downloading every
/// review just to count locally.
class ProductReviewsSection extends ConsumerWidget {
  const ProductReviewsSection({super.key, required this.slug, this.product});

  final String slug;

  /// The product this section belongs to, for the "Write a review" route.
  ///
  /// Passed down rather than re-read from `productDetailProvider`: the screen
  /// that hosts this section already has it, and watching the provider from
  /// here made the section fire a product request of its own — which turned up
  /// as a pending timer in a test that had only stubbed the reviews feed.
  final Product? product;

  static const int previewCount = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(productReviewsProvider(slug));
    final notifier = ref.read(productReviewsProvider(slug).notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('Ratings & reviews', style: context.text.h3)),
            // Only the server's own total is printed, and it is labelled.
            //
            // It used to render `displayCount`, which falls back to
            // `reviews.length` — page 1 of a 40-review product would have shown
            // a bare "10" beside the heading, stating a total the app does not
            // know. When the total could not be read, no count is shown at all.
            //
            // Labelled because the header above shows the catalogue's
            // `reviews_count`, which counts *published* reviews only, while this
            // feed also returns pending ones (captured: product 118 is
            // `reviews_count: 1` but "2 review(s)" here). Two bare numbers on
            // one screen read as a contradiction; "N reviews" reads as this
            // section's own count.
            //
            // Suppressed at zero: product 119 answers "0 review(s) for ..." so
            // the total *is* exact, and the section then read
            // "Ratings & reviews    0 reviews" directly above an empty-state
            // panel that already says "No reviews yet" — the same fact twice.
            // `review_summary.reviews_count`, never `reviews.length` — the
            // list is one page, and since moderation started being honoured it
            // also omits other people's pending reviews.
            if (!state.loading &&
                state.error == null &&
                (state.displayTotal ?? 0) > 0)
              Text(
                '${state.displayTotal} review'
                '${state.displayTotal == 1 ? '' : 's'}',
                style: context.text.caption,
              ),
          ],
        ),
        AppSpacing.vSm,
        if (state.loading)
          const Column(
            children: [ReviewTileSkeleton(), ReviewTileSkeleton()],
          )
        else if (state.error != null)
          // A failed review feed must not take the product page down with it,
          // so this stays inline and retryable rather than full-screen.
          InlineErrorStrip(
            error: state.error,
            label: 'reviews',
            onRetry: notifier.refresh,
          )
        else if (state.isEmpty && state.userReview == null)
          const EmptyView(
            title: 'No reviews yet',
            subtitle: 'Be the first to share how this product worked for you.',
            icon: Icons.rate_review_rounded,
          )
        else ...[
          // Bars and the customer media strip, from `review_summary`. Above the
          // list, as on the website.
          if (state.summary.count > 0) ...[
            _ReviewSummaryPanel(summary: state.summary),
            AppSpacing.vSm,
          ],
          if (state.userReview case final mine?)
            ReviewTile(review: mine, compact: true, isMine: true),
          for (final review in state.reviews.take(previewCount))
            ReviewTile(review: review, compact: true),
          if (state.hasMore || state.reviews.length > previewCount) ...[
            AppSpacing.vXs,
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => showReviewsSheet(context, slug),
                child: const Text('See all reviews'),
              ),
            ),
          ],
        ],
        // No "Write a review" entry here, on purpose — not even for a customer
        // the server reports as eligible. Reviews are written from the order
        // they belong to (Orders → the reviewable-products list), where the
        // customer is looking at what they actually bought.
        //
        // `review_eligibility` is still read: it is what pins the customer's
        // own review above and keeps it out of the public list below.
      ],
    );
  }
}

/// Average, star bars and the media strip across a product's approved reviews.
///
/// The per-star **tally is deliberately not shown**. `star_distribution` sends
/// a `count` alongside `percent`, and on 2026-08-12 that count was 100 for a
/// product with exactly one review — on every product probed. Only `percent` is
/// trustworthy, so the bar is drawn and no number sits beside it.
class _ReviewSummaryPanel extends StatelessWidget {
  const _ReviewSummaryPanel({required this.summary});

  final ReviewSummary summary;

  @override
  Widget build(BuildContext context) {
    // Normalised the same way a review row does, so the strip behaves the
    // same: photos open, clips play, and a clip's URL never reaches an image
    // widget. Binding `thumbnail` straight into `AppNetworkImage` is what put a
    // placeholder leaf where every video should have been — on this backend a
    // video's `thumbnail` *is* the .mp4, so the image decode fails and the
    // fallback draws.
    final media = <AppMedia>[
      for (final image in summary.images)
        AppMedia.image(image.fullUrl, thumbnail: image.thumbnail),
      for (final video in summary.videos)
        AppMedia.video(video.fullUrl, thumbnail: video.thumbnail),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Column(
              children: [
                Text(
                  summary.average.toStringAsFixed(1),
                  style: context.text.h2,
                ),
                ReviewStars(star: summary.average.round()),
                const SizedBox(height: 2),
                Text(
                  '${summary.count} review'
                  '${summary.count == 1 ? '' : 's'}',
                  style: context.text.caption,
                ),
              ],
            ),
            AppSpacing.hMd,
            Expanded(
              child: Column(
                children: [
                  for (final bar in summary.bars) _bar(context, bar),
                ],
              ),
            ),
          ],
        ),
        if (media.isNotEmpty) ...[
          AppSpacing.vSm,
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: media.length,
              separatorBuilder: (_, __) => AppSpacing.hXs,
              // Tappable, which it was not: the strip was a bare ClipRRect, so
              // the one place a customer sees every photo on a product at once
              // was the one place none of them opened.
              itemBuilder: (context, i) => MediaThumb(
                media: media[i],
                onTap: () => showMediaViewer(context, media, initialIndex: i),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _bar(BuildContext context, StarBar bar) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              child: Text('${bar.star}', style: context.text.caption),
            ),
            const Icon(
              AppIcons.star,
              size: 11,
              fill: 1,
              color: AppColors.warning,
            ),
            AppSpacing.hXs,
            Expanded(
              child: ClipRRect(
                borderRadius: AppRadius.rPill,
                child: LinearProgressIndicator(
                  value: bar.fraction,
                  minHeight: 5,
                  backgroundColor: context.colors.surfaceAlt,
                  valueColor: const AlwaysStoppedAnimation(AppColors.warning),
                ),
              ),
            ),
          ],
        ),
      );
}

/// Opens the full, paging review list.
///
/// It reads the same `productReviewsProvider(slug)` instance the section does,
/// so pages already fetched are reused instead of re-downloaded.
Future<void> showReviewsSheet(BuildContext context, String slug) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (_, controller) =>
            _AllReviewsList(slug: slug, controller: controller),
      ),
    );

class _AllReviewsList extends ConsumerWidget {
  const _AllReviewsList({required this.slug, required this.controller});

  final String slug;
  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(productReviewsProvider(slug));
    final notifier = ref.read(productReviewsProvider(slug).notifier);

    if (state.loading) {
      return const LoadingView(label: 'Loading reviews...');
    }
    if (state.error != null) {
      return AppErrorView(error: state.error, onRetry: notifier.refresh);
    }
    if (state.isEmpty && state.userReview == null) {
      return const EmptyView(
        title: 'No reviews yet',
        icon: Icons.rate_review_rounded,
      );
    }

    // The endpoint has no pagination metadata at all, so there is no page count
    // to drive a progress indicator — paging just walks until a short page
    // comes back and `hasMore` flips false.
    final rows = <Review>[
      if (state.userReview case final mine?) mine,
      ...state.reviews,
    ];

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        // Depth 0 only. ScrollNotifications bubble, and every review row can
        // carry a horizontal media strip (captured: one review on product 118
        // has 6 photos and 2 videos). Without this guard, swiping a row's photos
        // reports `pixels >= maxScrollExtent - 300` from the *inner* list — its
        // extent is a few hundred pixels at most — and fires a page fetch the
        // customer never asked for.
        if (n.depth != 0) return false;
        if (state.hasMore &&
            !state.loadingMore &&
            state.loadMoreError == null &&
            n.metrics.pixels >= n.metrics.maxScrollExtent - 300) {
          notifier.loadMore();
        }
        return false;
      },
      child: ListView.separated(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        itemCount: rows.length + 2,
        separatorBuilder: (_, __) => Divider(height: 1, color: context.colors.hairline),
        itemBuilder: (context, i) {
          if (i == 0) {
            final total = state.total;
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(
                // A count is only claimed when the server gave one. This used
                // to fall back to what had been paged in, so a partly-loaded
                // feed titled itself "10 reviews" while more were still coming
                // — and it left the pinned own review out of that number.
                total == null
                    ? 'Ratings & reviews'
                    : '$total review${total == 1 ? '' : 's'}',
                style: context.text.h3,
              ),
            );
          }
          if (i <= rows.length) {
            final review = rows[i - 1];
            return ReviewTile(
              key: ValueKey(review.id),
              review: review,
              isMine: state.userReview?.id == review.id,
            );
          }
          // Footer: paging progress, a retryable paging failure, or nothing.
          if (state.loadMoreError != null) {
            return InlineErrorStrip(
              error: state.loadMoreError,
              label: 'more reviews',
              onRetry: notifier.loadMore,
            );
          }
          if (state.loadingMore) {
            return const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: LoadingView(),
            );
          }
          return const SizedBox(height: AppSpacing.md);
        },
      ),
    );
  }
}

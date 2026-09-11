import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/design_system/app_icons.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../core/utils/responsive.dart';
import '../../data/models/home_sections.dart';
import '../../data/models/product_model.dart';
import 'product_card.dart';
import 'section_header.dart';
import 'skeletons.dart';

/// Geometry for a horizontal product rail.
///
/// Derived from the same numbers the grids use so a carousel tile and a grid
/// tile are the same shape — [Responsive.homeProductAspect] owns the ratio, and
/// only the *width* differs, because a rail sizes its cards to leave the next
/// one peeking rather than to fill a row.
class CarouselMetrics {
  const CarouselMetrics._();

  static const double spacing = 12;

  /// How many cards are visible at once. The fractional part is deliberate:
  /// a partially-visible card is the only affordance that says "this scrolls".
  ///
  /// 2.6 on a phone, not 2.4. The rail's tiles were the widest product tiles
  /// in the app — wider than the three-across home grid's, on the same screen —
  /// and since [cardHeight] now gives the photo a square, every dp of width is
  /// also a dp of height. Narrowing them shrinks the card in both directions at
  /// once, and shows more of the third product, which is what a rail is for.
  ///
  /// 2.8 was tried and overshot: at 105dp the tile was down to grid width while
  /// still carrying a rail's job, which is to be the thing you browse rather
  /// than the thing you scan. 2.6 keeps most of the saving and stays a card.
  static double _visibleCards(double width) => width >= 1100
      ? 6.4
      : (width >= 900 ? 5.4 : (width >= 640 ? 4.4 : 2.6));

  static double cardWidth(double width) {
    final usable = width - Responsive.gutter(width) * 2;
    final raw = usable / _visibleCards(width) - spacing;
    // Clamped so a 320dp phone still gets a legible card and a desktop-width
    // window doesn't stretch tiles into billboards.
    //
    // The floor is 104, not the old 118. 118 was a guess; the home grid is the
    // evidence — it runs this same [ProductCard] at three across, which is
    // 108dp on a 360dp phone, and the ADD control is built for exactly that
    // (`_AddControl.width` is sized for "~96dp of row"). A rail tile hits 104
    // only on a 320dp screen, and that is the narrowest this card is asked to
    // be anywhere in the app.
    return raw.clamp(104.0, 210.0);
  }

  /// [ProductCard] puts its image in an [Expanded], so the rail must supply a
  /// bounded height — an unbounded one throws during layout.
  ///
  /// A square photo, rather than [Responsive.homeProductAspect]. That ratio is
  /// tuned for the three-across grid, where it does give a square photo; borrowed
  /// here, where the tiles are wider, it produced one half again as tall as it
  /// was wide and a rail that ate most of the screen. See
  /// [productTileHeightForPhoto].
  static double cardHeight(BuildContext context, double width) =>
      productTileHeightForPhoto(context, cardWidth(width));

  /// [SectionHeader]'s own padding, shared so the placeholder header lines up
  /// with the real one rather than being re-typed and drifting.
  static const EdgeInsets headerPadding = EdgeInsets.fromLTRB(16, 16, 12, 12);

  /// The icon block [SectionHeader] draws to the left of the text.
  static const double headerIcon = 34;

  /// Content height of a [SectionHeader] carrying a one-line title over a
  /// one-line subtitle, **at the current text scale**.
  ///
  /// The placeholder header was three fixed-pixel [SkeletonBox]es, so it stayed
  /// 62dp tall whatever the user's font size while the real header grew with it
  /// (measured on a 411dp surface: 69dp at 1x, 189dp at 2x). A placeholder that
  /// ignores the text scale reserves the wrong space on exactly the devices
  /// least able to absorb the shift.
  ///
  /// This tracks the scale but not line *wrapping*, so at very large sizes the
  /// real header is still taller — see [ProductCarouselSkeleton] on why the
  /// placeholder cannot be an exact stand-in.
  static double headerHeight(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    double line(TextStyle style) =>
        scaler.scale(style.fontSize ?? 14) * (style.height ?? 1.2);
    return math.max(
      headerIcon,
      line(context.text.h3) + 1 + line(context.text.bodySm),
    );
  }
}

/// A titled, horizontally scrolling row of [ProductCard]s.
///
/// Renders nothing when [products] is empty. That is *only* correct for a
/// section that genuinely has no rows — a section whose request FAILED must
/// render an [InlineErrorStrip] instead, or a broken endpoint is indis-
/// tinguishable from an empty catalogue. The caller owns that distinction; see
/// `home_screen.dart`.
class ProductCarousel extends StatelessWidget {
  const ProductCarousel({
    super.key,
    required this.title,
    required this.products,
    this.subtitle,
    this.icon,
    this.onSeeAll,
  });

  final String title;
  final List<Product> products;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    if (products.isEmpty) return const SizedBox.shrink();

    final width = MediaQuery.sizeOf(context).width;
    final cardWidth = CarouselMetrics.cardWidth(width);
    final cardHeight = CarouselMetrics.cardHeight(context, width);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: title,
          subtitle: subtitle,
          icon: icon,
          onSeeAll: onSeeAll,
        ),
        SizedBox(
          height: cardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding:
                EdgeInsets.symmetric(horizontal: Responsive.gutter(width)),
            itemCount: products.length,
            separatorBuilder: (_, __) =>
                const SizedBox(width: CarouselMetrics.spacing),
            itemBuilder: (_, i) => ProductCard(
              product: products[i],
              width: cardWidth,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
      ],
    );
  }
}

/// Loading placeholder built from the same geometry as [ProductCarousel].
///
/// It approximates the rail rather than reproducing it, and deliberately so:
/// the placeholder cannot know how many rails will land (`/top-products-group`
/// returns anywhere from zero to four non-empty groups) or how the real titles
/// will wrap, so some shift when the data arrives is unavoidable. What it *can*
/// do is reserve the right card geometry and a header that grows with the
/// user's text size — see [CarouselMetrics.headerHeight].
class ProductCarouselSkeleton extends StatelessWidget {
  const ProductCarouselSkeleton({super.key, this.itemCount = 3});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cardWidth = CarouselMetrics.cardWidth(width);
    final cardHeight = CarouselMetrics.cardHeight(context, width);
    final headerHeight = CarouselMetrics.headerHeight(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Mirrors SectionHeader's padding and icon block rather than reusing it
        // — the header's own text would need placeholder strings, which read as
        // real content for a frame.
        Padding(
          padding: CarouselMetrics.headerPadding,
          child: SizedBox(
            height: headerHeight,
            child: Row(
              children: [
                const SkeletonBox(
                  height: CarouselMetrics.headerIcon,
                  width: CarouselMetrics.headerIcon,
                  radius: AppRadius.md,
                ),
                AppSpacing.hSm,
                // Expanded, and the bars scale with the header: at 2x the old
                // fixed 14/10dp bars floated in the top-left of a block twice
                // their height.
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SkeletonBox(
                        height: headerHeight * 0.34,
                        width: 132,
                        radius: AppRadius.sm,
                      ),
                      const SizedBox(height: 6),
                      SkeletonBox(
                        height: headerHeight * 0.24,
                        width: 88,
                        radius: AppRadius.sm,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          height: cardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            // The real rail scrolls; the placeholder must not, or a drag during
            // load moves content that is about to be replaced.
            physics: const NeverScrollableScrollPhysics(),
            padding:
                EdgeInsets.symmetric(horizontal: Responsive.gutter(width)),
            itemCount: itemCount,
            separatorBuilder: (_, __) =>
                const SizedBox(width: CarouselMetrics.spacing),
            itemBuilder: (_, __) => SkeletonBox(
              width: cardWidth,
              height: cardHeight,
              radius: AppRadius.lg,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
      ],
    );
  }
}

/// Icon for each of the four `/top-products-group` carousels.
///
/// Lives here rather than on [HomeSectionKind]: the kind is a data-layer enum
/// and must not depend on a design-system import.
IconData iconForSectionKind(HomeSectionKind kind) => switch (kind) {
      HomeSectionKind.topSelling => AppIcons.bag,
      HomeSectionKind.trending => AppIcons.percent,
      HomeSectionKind.recentlyAdded => AppIcons.leaf,
      HomeSectionKind.topRated => AppIcons.star,
    };

/// One-line description under each carousel title.
///
/// Each line has to be true of what the endpoint actually returns. Inventing a
/// window, a metric or a recency the payload never states is the same class of
/// lie as a fake success toast.
///
/// `trending` is the one to be careful with, and the line that used to sit here
/// — "Popular with shoppers right now" — was exactly the lie this comment
/// claimed to be avoiding. It asserts two things the app has never verified:
/// that the section measures popularity, and that it measures it *now*.
/// Nothing in the payload or the contract says what `trending` ranks by, and in
/// the captured response it is `[111, 118, 119, 120]` — every product in the
/// catalogue, in ascending id order, which is indistinguishable from "no
/// ranking at all". So the subtitle now attributes the selection to the store,
/// which is the only part that is certainly true: the server labelled this
/// group `trending`.
///
/// The other three do describe what the backend computes (`top_selling` from
/// paid orders, `recently_added` by creation date, `top_rated` from reviews)
/// and stop short of naming a window.
String subtitleForSectionKind(HomeSectionKind kind) => switch (kind) {
      HomeSectionKind.topSelling => 'What shoppers buy most',
      HomeSectionKind.trending => "The store's trending picks",
      HomeSectionKind.recentlyAdded => 'Fresh on the shelf',
      HomeSectionKind.topRated => 'Highest rated by customers',
    };

/// Drops repeated products, keeping the server's ordering.
///
/// `/top-products-group` really does repeat a product inside a single rail: the
/// captured payload's `top_selling` is `[118, 118, 119]` — the top-selling query
/// aggregates order rows and does not collapse them to one row per product. Fed
/// straight to [ProductCarousel] that renders the identical card twice in "Best
/// sellers", which reads as a broken rail (and, worse, as a padded one).
///
/// First occurrence wins, so the ranking the server sent is preserved.
List<Product> dedupeProducts(List<Product> products) {
  final seen = <int>{};
  return [
    for (final p in products)
      if (seen.add(p.id)) p,
  ];
}

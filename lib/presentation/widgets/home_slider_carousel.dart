import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../core/utils/cms_link.dart';
import '../../data/models/slider_model.dart';
import 'app_network_image.dart';

class HomeSliderCarousel extends StatefulWidget {
  const HomeSliderCarousel({super.key, required this.items});
  final List<SliderItem> items;

  @override
  State<HomeSliderCarousel> createState() => _HomeSliderCarouselState();
}

class _HomeSliderCarouselState extends State<HomeSliderCarousel> {
  /// Kept as constants because the height is derived from both — see the
  /// LayoutBuilder in [build].
  static const double _viewportFraction = 0.92;
  static const double _slideGap = 6;

  final _controller = PageController(viewportFraction: _viewportFraction);
  Timer? _timer;
  int _page = 0;

  /// Width / height of the slide box — **one shape for every banner**.
  ///
  /// The CMS's tablet cut is 768x350 and that is what every phone and tablet is
  /// served (see [SliderItem.imageFor]), so the box is that ratio and the
  /// artwork fills it exactly: nothing is cropped, and no ground shows through
  /// at the edges to round off oddly.
  ///
  /// Deliberately fixed rather than measured. An earlier revision resolved each
  /// slide's intrinsic size and took the tallest, which made the banner resize
  /// itself a beat after the page painted and gave slides of differing shapes
  /// differing heights. Every banner comes out of the same admin flow at the
  /// same size, so there is nothing to discover at runtime.
  static const double _aspect = 768 / 350;

  @override
  void initState() {
    super.initState();
    if (widget.items.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 4), (_) {
        if (!mounted || !_controller.hasClients) return;
        _page = (_page + 1) % widget.items.length;
        _controller.animateToPage(
          _page,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Height comes from the width of ONE SLIDE, not of the viewport.
        // A plain AspectRatio on the pager sized itself from the full screen,
        // while each page is only `_viewportFraction` of that minus its own
        // 6dp gutters — so the box was ~24dp taller than the artwork it held,
        // and the picture overflowed its rounded card.
        LayoutBuilder(
          builder: (context, constraints) {
            final slideWidth =
                (constraints.maxWidth * _viewportFraction) - (_slideGap * 2);
            return SizedBox(
              height: slideWidth / _aspect,
              child: PageView.builder(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                itemCount: widget.items.length,
                itemBuilder: (_, i) => _slide(widget.items[i]),
              ),
            );
          },
        ),
        if (widget.items.length > 1) ...[
          AppSpacing.vSm,
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(widget.items.length, (i) {
              final active = i == _page;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: active ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: active ? AppColors.primary : context.colors.line,
                  borderRadius: AppRadius.rPill,
                ),
              );
            }),
          ),
        ],
      ],
    );
  }

  /// Opens the slide's link — natively where the app has a screen for it.
  ///
  /// This used to push `/web` for **every** link, and to hand it the raw
  /// `item.link` unresolved. Two things were wrong with that: a relative link
  /// (`/products`, which the CMS emits) is not a URL a browser can open, and a
  /// link to a product page opened a *web page* of a product this app has a
  /// real screen for — no add-to-cart, no variants, no reviews. Both rules now
  /// live in [CmsLink], shared with the ad banners.
  void _open(SliderItem item, Uri target) {
    final native = CmsLink.appRoute(target);
    context.push(native ?? CmsLink.webRoute(target, title: item.plainTitle));
  }

  Widget _slide(SliderItem item) {
    final target = CmsLink.resolve(item.link);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _slideGap),
      child: Semantics(
        label: item.plainTitle.isEmpty ? 'Offer' : item.plainTitle,
        button: target != null,
        child: InkWell(
          // Null for a slide with no link — two of the three live ones. An
          // InkWell with a null callback draws no ripple and lets the tap fall
          // through, so a slide that goes nowhere no longer swallows the tap
          // and pretends to be a button. The old GestureDetector always had an
          // onTap and simply did nothing inside it.
          onTap: target == null ? null : () => _open(item, target),
          child: ClipRRect(
            // `rLg` (16), the radius every other surface on this screen uses —
            // AppCard, the product tiles, the category chips. The banner was
            // alone on `rXl` (20), which is visible when it sits directly above
            // a row of cards.
            borderRadius: AppRadius.rLg,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // No scrim. See the note on [AppColors.onSliderInk].
                //
                // This carried a dark gradient wash under white copy, which is the
                // right treatment for a dark photograph and the wrong one here:
                // every asset this shop uploads is a light cream studio shot, so
                // the wash only muddied artwork that needed nothing done to it.
                // The website draws dark text straight onto the same images with
                // no overlay at all, and it reads better because the picture is
                // left alone.
                // The artwork the admin uploaded for *this* screen size. The
                // three are different crops, not one picture rescaled, so on a
                // phone the desktop banner put the subject half out of frame.
                // `cover`, with the box already cut to the artwork's own
                // ratio — so this fills the slide exactly and the rounded
                // corners clip the picture itself. `contain` left a hairline of
                // ground at the edges, which is what made the radius read as
                // ragged.
                AppNetworkImage(
                  url: item.imageFor(MediaQuery.sizeOf(context).width),
                  fit: BoxFit.cover,
                ),

                Padding(
                  // Generous horizontal inset: the text is centred, so this is
                  // what stops a long title from running out over the artwork at
                  // the edges instead of wrapping.
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
                  child: Column(
                    // `min` + Flexible: at a large text scale two lines of h2
                    // plus two of body are taller than the card, and a Column
                    // that cannot fit its children overflows rather than
                    // clipping. Now the text ellipsises instead.
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (item.plainTitle.isNotEmpty)
                        Flexible(
                          child: Text(
                          item.plainTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                            style: context.text.h2.copyWith(
                              color: AppColors.onSliderInk,
                              height: 1.15,
                            ),
                          ),
                        ),
                      if (item.plainDescription.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Flexible(
                          child: Text(
                          item.plainDescription,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                            style: context.text.bodySm
                                .copyWith(color: AppColors.onSliderMuted),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

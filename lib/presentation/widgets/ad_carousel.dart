import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../core/utils/cms_link.dart';
import '../../data/models/ad_model.dart';
import 'app_network_image.dart';

/// Every published ad banner, swipeable, and each one opens where the CMS
/// pointed it.
///
/// ## What this replaced
///
/// A single `AspectRatio` around `list.first`. The endpoint returns five
/// banners — the shop had published five and was seeing one — and the image
/// carried no gesture at all, so the `link` the CMS attaches to each was never
/// used. A banner nobody can tap is decoration the merchandiser thinks is
/// working.
///
/// ## Why there is no auto-advance
///
/// The hero slider above already rotates itself every four seconds. A second
/// timer moving a second row of artwork turns the top of the feed into
/// competing motion, and it steals the banner out from under a thumb that was
/// reaching for it. These advance only when the customer swipes.
class AdCarousel extends StatefulWidget {
  const AdCarousel({super.key, required this.ads});

  final List<AdBanner> ads;

  @override
  State<AdCarousel> createState() => _AdCarouselState();
}

class _AdCarouselState extends State<AdCarousel> {
  // Matches the hero slider, so the two rows of artwork line up down the page
  // and the next banner peeks by the same amount.
  final _controller = PageController(viewportFraction: 0.92);
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.ads.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        AspectRatio(
          // 16:7 on the *page*, not on each child: a child-level AspectRatio
          // inside a PageView leaves the row unbounded and the banners collapse.
          aspectRatio: 16 / 7,
          child: PageView.builder(
            controller: _controller,
            onPageChanged: (i) => setState(() => _page = i),
            itemCount: widget.ads.length,
            itemBuilder: (_, i) => _banner(context, widget.ads[i]),
          ),
        ),
        if (widget.ads.length > 1) ...[
          AppSpacing.vSm,
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(widget.ads.length, (i) {
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

  Widget _banner(BuildContext context, AdBanner ad) {
    final target = CmsLink.resolve(ad.link);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: ClipRRect(
        borderRadius: AppRadius.rXl,
        child: Semantics(
          label: ad.name,
          button: target != null,
          child: InkWell(
            // Null for the two live banners whose `link` is empty. An InkWell
            // with a null callback draws no ripple, so a banner that cannot go
            // anywhere does not pretend it can.
            onTap: target == null ? null : () => _open(context, ad, target),
            child: AppNetworkImage(url: ad.image, fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context, AdBanner ad, Uri target) {
    // `open_in_new_tab` is ignored on purpose — there are no tabs here, and the
    // web view is already a separate screen the customer can back out of.
    //
    // Resolution and the native-route mapping both live in [CmsLink], shared
    // with the home slider: the two carousels had drifted, and the slider was
    // the one missing both.
    final native = CmsLink.appRoute(target);
    context.push(native ?? CmsLink.webRoute(target, title: ad.name));
  }
}

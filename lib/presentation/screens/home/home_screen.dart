import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_icons.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../data/models/category_model.dart';
import '../../../data/models/customer.dart';
import '../../../data/models/home_sections.dart';
import '../../providers/auth_provider.dart';
import '../../providers/delivery_location_provider.dart';
import '../../providers/notification_provider.dart';
import '../../widgets/address_choose_sheet.dart';
import '../../../core/utils/responsive.dart';
import '../../providers/home_providers.dart';
import '../../providers/products_provider.dart';
import '../../widgets/ad_carousel.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/flash_sale_section.dart';
import '../../widgets/home_slider_carousel.dart';
import '../../widgets/home_sticky_header.dart';
import '../../widgets/product_carousel.dart';
import '../../widgets/product_grid.dart';
import '../../widgets/section_header.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/state_views.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Selected category tab; null == "All".
  int? _categoryId;

  Future<void> _refresh() async {
    final categoryId = _categoryId;

    // The gesture has to refetch what is *on screen*. Picking a category
    // replaces the whole feed with `productsProvider(query)` — the rails, the
    // sliders and Fresh picks are not built at all — so refreshing them here
    // spun the indicator, fired five requests for content the user could not
    // see, and left the one grid they were looking at untouched. A refresh that
    // visibly changes nothing is indistinguishable from a broken one.
    if (categoryId != null) {
      final query = ProductQuery(categoryId: categoryId);
      await Future.wait([
        _settled(ref.read(productsProvider(query).notifier).refresh()),
        // The tab strip is the only home chrome still rendered while browsing.
        _settled(_reload(categoriesProvider)),
      ]);
      return;
    }

    // *Every* invalidated provider is awaited, so the pull-to-refresh spinner
    // stays up until the whole feed is actually redrawn — awaiting only two of
    // the five ended the gesture while the sliders and tabs were still blank,
    // which reads as "the refresh dropped them".
    //
    // Failures are swallowed *here* only: each provider's AsyncValue still
    // carries the error and the section renders it. Letting the rejection
    // escape would instead throw out of the RefreshIndicator's callback and
    // leave the spinner stuck.
    await Future.wait([
      _settled(_reload(homeSectionsProvider)),
      _settled(_reload(featuredProductsProvider)),
      _settled(_reload(slidersProvider)),
      _settled(_reload(adsProvider)),
      _settled(_reload(categoriesProvider)),
      // Time-boxed, so it is the one section a pull is most likely to be *for*:
      // a sale can start, sell out or end while the screen is open.
      _settled(_reload(flashSalesProvider)),
    ]);
  }

  /// Invalidate and re-read as one step, so a provider can never be invalidated
  /// without also being awaited (or awaited without being invalidated, which
  /// returns the stale future and ends the gesture immediately).
  Future<void> _reload<T>(FutureProvider<T> provider) {
    ref.invalidate(provider);
    return ref.read(provider.future);
  }

  static Future<void> _settled(Future<void> f) =>
      f.then<void>((_) {}, onError: (_, __) {});

  void _selectCategory(int? id) {
    if (_categoryId == id) return;
    setState(() => _categoryId = id);
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider);
    // Tabs appear only once there is something to show; the header shrinks to
    // just the search bar while loading or on failure, rather than reserving
    // an empty strip.
    // Empty categories are dropped. Nine of this shop's ten top-level
    // categories currently have nothing in them, and each one is a tab that
    // costs a customer a tap and returns an empty grid.
    //
    // The roll-up matters: `products_count` counts direct members only, so
    // `Wheat & Wheat Flour` — whose stock partly lives in its `Sona Moti Wheat`
    // child — is kept by the descendants total, not by its own 5.
    final tabs =
        categoriesWithProducts(categories.asData?.value ?? const <Category>[]);
    final browsing = _categoryId != null;
    final greetingHeight = _greetingHeight(context);

    // Built once so `expandedHeight` and `bottom` agree on the strip height —
    // deriving it twice is how the app bar ends up clipping its own content.
    final stickyHeader = HomeStickyHeader(
      categories: tabs,
      selectedId: _categoryId,
      showTabs: tabs.isNotEmpty,
      onCategorySelected: _selectCategory,
      onSearchTap: () => context.push('/search'),
      // Grown for the OS text scale, the same way the greeting above is. The
      // strip is a fixed box around real text, and at the accessibility sizes
      // the labels outgrow it — which was already true before they wrapped.
      tabsHeight: stickyTabsHeight(context),
    );

    return Scaffold(
      backgroundColor: context.colors.background,
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _refresh,
        child: CustomScrollView(
          slivers: [
            // The greeting scrolls away; search + tabs stay pinned beneath the
            // status bar. SliverAppBar is what keeps the pinned strip clear of
            // the system inset — it adds MediaQuery.padding.top to its extent,
            // so nothing slides under the clock and battery icons.
            SliverAppBar(
              pinned: true,
              backgroundColor: context.colors.surface,
              surfaceTintColor: Colors.transparent,
              elevation: 2,
              scrolledUnderElevation: 2,
              shadowColor: Colors.black26,
              automaticallyImplyLeading: false,
              // No toolbar row of its own — the greeting lives in
              // flexibleSpace and the strip in `bottom`, so the collapsed
              // height is exactly status bar + strip.
              toolbarHeight: 0,
              collapsedHeight: 0,
              expandedHeight:
                  greetingHeight + stickyHeader.preferredSize.height,
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration:
                      BoxDecoration(gradient: context.colors.headerWash),
                  child: SafeArea(
                    bottom: false,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: _Header(height: greetingHeight),
                    ),
                  ),
                ),
              ),
              bottom: stickyHeader,
            ),

            // Picking a category turns the feed into a plain product grid —
            // the merchandising rows only make sense on the "All" tab.
            if (browsing)
              ..._categoryFeed(context)
            else
              ..._defaultFeed(context),

            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  /// Height of the greeting strip.
  ///
  /// [kHomeGreetingHeight] is a fixed extent, but the two lines inside it are
  /// real text: at the OS's larger accessibility sizes they outgrow the
  /// constant and the greeting Column overflows (verified: 1dp at 1.4x, 23dp at
  /// 2.0x — the yellow-and-black stripes ship to the user). The strip grows
  /// with the text instead of clipping it, and `expandedHeight` is derived from
  /// the same number so the app bar and its content stay in agreement.
  ///
  /// Capped at 2x: past that the greeting would eat the whole viewport, and the
  /// text inside ellipsizes rather than pushing further.
  static double _greetingHeight(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    return kHomeGreetingHeight * scale.clamp(1.0, 2.0);
  }

  List<Widget> _defaultFeed(BuildContext context) => [
        _categoryStatusSliver(ref),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        _slidersSliver(ref),
        const SliverToBoxAdapter(child: SizedBox(height: 18)),
        // Above the merchandising rails: a flash sale is time-boxed, so it
        // outranks the evergreen carousels. Draws nothing at all when no sale
        // is running, which on this store is always — see [FlashSaleSection].
        const SliverToBoxAdapter(child: FlashSaleSection()),
        // The ad banners are emitted from inside this, directly after New
        // arrivals. See [_sectionCarouselSlivers].
        ..._sectionCarouselSlivers(ref),
        SliverToBoxAdapter(
          child: SectionHeader(
            title: 'Fresh picks',
            subtitle: 'Handpicked organic essentials',
            icon: AppIcons.leaf,
            onSeeAll: () => context.push('/products'),
          ),
        ),
        _productsSliver(context, ref),
        const SliverToBoxAdapter(child: _BrandSignOff()),
      ];

  // ---- Merchandising carousels -----------------------------------------
  //
  // Best sellers / Trending / New arrivals / Top rated, all four from ONE
  // request to `/top-products-group`. `homeSectionsProvider` is watched exactly
  // once here and the four rails are built from its result — a per-carousel
  // provider would quadruple the traffic for no gain.
  List<Widget> _sectionCarouselSlivers(WidgetRef ref) {
    final sections = ref.watch(homeSectionsProvider);

    return sections.when(
      // Two placeholder rails rather than four: the feed is already long, and
      // over-reserving height makes the page snap upward when fewer sections
      // come back (top_selling and top_rated are routinely empty).
      loading: () => [
        const SliverToBoxAdapter(child: ProductCarouselSkeleton()),
        const SliverToBoxAdapter(child: ProductCarouselSkeleton()),
        // The banners come from their own endpoint, so they are not held behind
        // a rail that is still loading.
        _adsSliver(ref),
      ],
      // The distinction that matters: a *failed* call is not "no data". Hiding
      // it would make a dead endpoint look like an empty catalogue, which is
      // exactly the bug this strip exists to prevent.
      error: (e, __) => [
        SliverToBoxAdapter(
          child: InlineErrorStrip(
            error: e,
            label: 'featured collections',
            onRetry: () => ref.invalidate(homeSectionsProvider),
          ),
        ),
        _adsSliver(ref),
      ],
      // `.sections` already drops the empty carousels, so a quiet month simply
      // renders fewer rails instead of four empty headers. All four empty means
      // no slivers at all — Fresh picks below still carries the page.
      // `dedupeProducts` is not defensive padding: the live payload's
      // `top_selling` is [118, 118, 119], so without it "Best sellers" renders
      // the same card twice.
      data: (s) {
        final sections = s.sections;

        // The banners sit directly after New arrivals, which is where the shop
        // asked for them.
        //
        // `recentlyAdded` is not guaranteed to be on screen: `.sections` drops
        // any rail with no products, and on this store right now **all four are
        // empty**. So "after New arrivals" degrades in the only way that keeps
        // the banners visible — after the last rail that did render, and on
        // their own when none did. Anchoring to an index instead would have
        // hidden every ad on the live catalogue.
        final anchor = sections
            .indexWhere((x) => x.kind == HomeSectionKind.recentlyAdded);
        final after = anchor >= 0 ? anchor : sections.length - 1;

        return [
          for (final (i, section) in sections.indexed) ...[
            SliverToBoxAdapter(
              child: ProductCarousel(
                title: section.title,
                subtitle: subtitleForSectionKind(section.kind),
                icon: iconForSectionKind(section.kind),
                products: dedupeProducts(section.products),
              ),
            ),
            if (i == after) _adsSliver(ref),
          ],
          if (sections.isEmpty) _adsSliver(ref),
        ];
      },
    );
  }

  /// Grid for the selected category, reusing the paged provider the catalogue
  /// screens already use.
  List<Widget> _categoryFeed(BuildContext context) {
    final query = ProductQuery(categoryId: _categoryId);
    final state = ref.watch(productsProvider(query));
    final width = MediaQuery.sizeOf(context).width;

    if (state.loading) {
      return const [
        SliverToBoxAdapter(
          child: ProductGridSkeleton(itemCount: 4),
        ),
      ];
    }
    if (state.error != null && state.items.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 280,
            child: AppErrorView(
              error: state.error,
              onRetry: () =>
                  ref.read(productsProvider(query).notifier).refresh(),
            ),
          ),
        ),
      ];
    }
    if (state.items.isEmpty) {
      return [
        SliverToBoxAdapter(
          // minHeight, not a fixed height: [EmptyView] is an unscrollable
          // Column, so at large accessibility text sizes a fixed box clips it
          // and paints overflow stripes over the message.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 280),
            child: const EmptyView(
              title: 'Nothing here yet',
              subtitle: 'This category has no products right now',
              icon: Icons.search_off_rounded,
            ),
          ),
        ),
      ];
    }

    return [
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ProductSliverGrid(
        products: state.items,
        columns: Responsive.homeProductColumns(width),
        aspectRatio: Responsive.homeProductAspect(width),
      ),
    ];
  }

  // ---- Sliders ----------------------------------------------------------
  Widget _slidersSliver(WidgetRef ref) {
    final sliders = ref.watch(slidersProvider);
    return SliverToBoxAdapter(
      child: sliders.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          child: SkeletonBox(height: 172, radius: AppRadius.xl),
        ),
        // Previously SizedBox.shrink() — a failed request looked exactly like
        // "no sliders configured", so a broken endpoint was invisible.
        error: (e, __) => InlineErrorStrip(
          error: e,
          label: 'offers',
          onRetry: () => ref.invalidate(slidersProvider),
        ),
        data: (list) {
          if (list.isEmpty) return const SizedBox.shrink();
          return HomeSliderCarousel(items: list.first.items);
        },
      ),
    );
  }

  // ---- Category tab status ----------------------------------------------
  //
  // The tabs themselves live in the pinned header, which can only render a
  // list. Loading and failure are reported here so a broken
  // `/ecommerce/product-categories` still surfaces instead of the tab strip
  // silently not appearing.
  Widget _categoryStatusSliver(WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);
    return SliverToBoxAdapter(
      child: categories.when(
        loading: () => const SizedBox(height: 74, child: SkeletonRow()),
        error: (e, __) => InlineErrorStrip(
          error: e,
          label: 'categories',
          onRetry: () => ref.invalidate(categoriesProvider),
        ),
        data: (_) => const SizedBox.shrink(),
      ),
    );
  }

  // ---- Ad banners -------------------------------------------------------
  //
  // Every published banner, not just the first. `/ads` returns five on this
  // store and this rendered `list.first`, so four of them were fetched, sorted,
  // and thrown away on every home load. The repository already sorts by `order`
  // and drops any row with no image, so what arrives here is exactly what the
  // merchandiser published, in the order they set.
  Widget _adsSliver(WidgetRef ref) {
    final ads = ref.watch(adsProvider);
    return SliverToBoxAdapter(
      child: ads.when(
        loading: () => const SizedBox(height: 8),
        error: (e, __) => InlineErrorStrip(
          error: e,
          label: 'banners',
          onRetry: () => ref.invalidate(adsProvider),
        ),
        data: (list) {
          if (list.isEmpty) return const SizedBox(height: 8);
          return Padding(
            padding: const EdgeInsets.fromLTRB(10, 20, 10, 4),
            child: AdCarousel(ads: list),
          );
        },
      ),
    );
  }

  // ---- Products grid (responsive) --------------------------------------
  Widget _productsSliver(BuildContext context, WidgetRef ref) {
    final products = ref.watch(featuredProductsProvider);
    final width = MediaQuery.sizeOf(context).width;
    return products.when(
      loading: () => const SliverToBoxAdapter(
        child: ProductGridSkeleton(itemCount: 4),
      ),
      error: (e, __) => SliverToBoxAdapter(
        child: SizedBox(
          height: 260,
          child: AppErrorView(
            error: e,
            onRetry: () => ref.invalidate(featuredProductsProvider),
          ),
        ),
      ),
      data: (list) {
        if (list.isEmpty) {
          return SliverToBoxAdapter(
            // See the category feed's empty state: a fixed height clips
            // [EmptyView] at large accessibility text sizes.
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 260),
              child: const EmptyView(
                title: 'No products yet',
                icon: Icons.local_grocery_store_rounded,
              ),
            ),
          );
        }
        return ProductSliverGrid(
          products: list,
          columns: Responsive.homeProductColumns(width),
          aspectRatio: Responsive.homeProductAspect(width),
        );
      },
    );
  }
}

// ============================ Header ===================================
/// Greeting + delivery location. Scrolls away above the pinned search strip.
///
/// The status-bar inset and the gradient wash are applied by the SliverAppBar
/// that hosts this, so neither belongs here — nesting a second SafeArea would
/// double the top padding.
class _Header extends ConsumerWidget {
  const _Header({required this.height});

  /// Supplied by the host so the strip and the SliverAppBar's `expandedHeight`
  /// are derived from one number — see `_HomeScreenState._greetingHeight`.
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The badge reflects the real unread count from
    // `GET /api/v1/notifications/stats`. Signed out it resolves to zero rather
    // than firing a request that could only 401.
    final unread = ref.watch(notificationStatsProvider).maybeWhen(
          data: (s) => s.unread,
          orElse: () => 0,
        );
    // Where this order is going, app-wide. The cart and checkout read the same
    // provider, so the header cannot name one destination while the bill prices
    // another.
    final location = ref.watch(deliveryLocationProvider);
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
        child: Row(
          children: [
            Icon(AppIcons.mapPin, color: AppColors.primary, size: 22),
            AppSpacing.hXs,
            Expanded(child: _DeliverTo(location: location)),
            _circleAction(
              context,
              AppIcons.bell,
              badgeCount: unread,
              onTap: () => context.push('/notifications'),
            ),
            AppSpacing.hXs,
            _circleAction(
              context,
              AppIcons.user,
              // Signed in goes to the account tab's screen; signed out goes
              // straight to login, which is what the icon can actually do.
              onTap: () => context.push(
                ref.read(isAuthenticatedProvider) ? '/account' : '/login',
              ),
              child: _AccountAvatar(
                customer: ref.watch(authProvider.select((a) => a.customer)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _circleAction(
    BuildContext context,
    IconData icon, {
    required VoidCallback onTap,
    int badgeCount = 0,
    /// Drawn instead of [icon] — the customer's own picture, for the account
    /// button. Clipped to the same circle so it cannot square off the row.
    Widget? child,
  }) =>
      Stack(
        clipBehavior: Clip.none,
        children: [
          Material(
            color: context.colors.surface,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: SizedBox(
                width: 42,
                height: 42,
                child: child ??
                    Icon(icon, color: context.colors.primaryDark, size: 21),
              ),
            ),
          ),
          // Only shown when there is genuinely something unread — the dot used
          // to be hardcoded on, so it signalled nothing.
          if (badgeCount > 0)
            Positioned(
              right: 4,
              top: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                constraints: const BoxConstraints(minWidth: 16),
                decoration: BoxDecoration(
                  color: AppColors.error,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: context.colors.surface, width: 1.5),
                ),
                child: Text(
                  badgeCount > 99 ? '99+' : '$badgeCount',
                  textAlign: TextAlign.center,
                  // Through `context.text`, like every other style in this
                  // file: naming AppTypography directly is what bakes the
                  // light-theme colour into a widget.
                  style: context.text.overline.copyWith(
                    color: Colors.white,
                    fontSize: 9,
                    height: 1.2,
                  ),
                ),
              ),
            ),
        ],
      );
}

/// The delivery destination, and the control that changes it.
///
/// ## What this replaced
///
/// The literal string `'Ahmedabad · 382415'`, under a caret that had no
/// handler. Every customer in the country was shown one shop's neighbourhood as
/// if it were their own, and the caret invited a tap that did nothing — so the
/// header managed to be both wrong and falsely interactive.
///
/// ## Why it reads the same provider the cart does
///
/// [deliveryLocationProvider] is where the destination lives app-wide, and the
/// cart bill and the checkout picker price against it. A header with its own
/// copy would be a fourth answer to a question that already has one, free to
/// drift from the figure the customer is actually charged.
///
/// ## The three states, and why none of them invents an address
///
///   * **chosen** — the row's own name and PIN code;
///   * **signed in, nothing chosen** — an invitation, not a guess. The book is
///     bearer-only and may be empty;
///   * **signed out** — there is no book to read, so the header says where it
///     would deliver *once they sign in* rather than naming a place.
///
/// Tapping opens [chooseDeliveryAddress] — the one sheet the cart and checkout
/// also open, which applies the pick itself.
class _DeliverTo extends ConsumerWidget {
  const _DeliverTo({required this.location});

  final DeliveryLocation? location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(isAuthenticatedProvider);
    final chosen = location;

    final label = switch ((signedIn, chosen)) {
      (false, _) => 'Sign in to set your address',
      (true, null) => 'Select delivery address',
      (true, final l?) => l.pinCode.isEmpty
          ? l.display
          // "Gwalior home · 474010" — the row's own label beside the PIN the
          // quote is actually priced on, so the customer can check both.
          : '${l.display} · ${l.pinCode}',
    };

    return InkWell(
      key: const Key('home-deliver-to'),
      onTap: () => chooseDeliveryAddress(context, ref),
      borderRadius: AppRadius.rSm,
      child: Padding(
        // Vertical only: the row already has the header's horizontal padding,
        // and insetting further would push the label away from its map pin.
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Flexible: at 2x text the label plus its caret overran the row
                // by half a pixel and painted the overflow stripes across the
                // greeting.
                Flexible(
                  child: Text(
                    'Deliver to',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.caption,
                  ),
                ),
                const SizedBox(width: 3),
                Icon(AppIcons.caretDown, size: 12, color: context.colors.muted),
              ],
            ),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.title.copyWith(color: context.colors.ink),
            ),
          ],
        ),
      ),
    );
  }
}

/// The brand sign-off that closes the feed.
///
/// Sits after the last product rather than in a persistent footer: it marks the
/// end of the scroll, which a long feed otherwise leaves ambiguous.
///
/// Muted on purpose — it is a signature, not a heading, and it must not read as
/// another section the customer should tap.
class _BrandSignOff extends StatelessWidget {
  const _BrandSignOff();

  @override
  Widget build(BuildContext context) {
    // `faint`, not a fixed grey: this is the last thing on a screen that has a
    // dark theme, and a hardcoded colour would either vanish or glare there.
    final tint = context.colors.faint;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                // The company's full slogan. Wraps to two or three lines by
                // design and is allowed to keep wrapping at the accessibility
                // sizes rather than clipping — a signature that ends in "…"
                // reads worse than one that takes an extra line.
                child: Text(
                  'Transforming nature to nature',
                  style: context.text.display.copyWith(
                    fontSize: 34,
                    color: tint,
                    height: 1.12,
                  ),
                ),
              ),
              AppSpacing.hXs,
              // Sits on the baseline of the last line rather than the top of
              // the block, so it reads as part of the sign-off instead of
              // floating beside it.
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Icon(AppIcons.leaf, size: 28, color: AppColors.primary),
              ),
            ],
          ),
          AppSpacing.vSm,
          // Separates the slogan from the name rather than letting the two run
          // together as one block of grey.
          Divider(height: 1, thickness: 1, color: context.colors.line),
          AppSpacing.vSm,
          Text(
            'Trueway Farms',
            style: context.text.title.copyWith(color: tint),
          ),
        ],
      ),
    );
  }
}

/// The customer's own picture in the header's account button.
///
/// Three states, in the order they are actually reached:
///
/// * **signed out** (or a customer not read back yet) — the person glyph, which
///   is the only honest thing to draw for someone the app has no name for;
/// * **signed in, no uploaded picture** — their initials. The server *does*
///   send an avatar for these customers, but it is a generated-initials PNG
///   embedded as a base64 `data:` URI, which [Customer.fromJson] strips. Drawing
///   the initials locally is the same picture without the multi-KB payload,
///   and it is what the account screen already does;
/// * **signed in with a real upload** — the image, cached and clipped to the
///   circle.
class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({required this.customer});

  final Customer? customer;

  @override
  Widget build(BuildContext context) {
    final customer = this.customer;
    if (customer == null) {
      return Icon(AppIcons.user, color: context.colors.primaryDark, size: 21);
    }

    if (!customer.hasAvatar) {
      return Center(
        child: Text(
          customer.initials,
          style: context.text.buttonSm
              .copyWith(color: context.colors.primaryDarker),
        ),
      );
    }

    return ClipOval(
      // Sized to the button so `cover` crops a non-square upload to the circle
      // instead of letterboxing it.
      child: AppNetworkImage(
        url: customer.avatar!,
        width: 42,
        height: 42,
      ),
    );
  }
}

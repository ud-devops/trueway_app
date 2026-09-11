/// Where a link the shop's admin typed should actually take the customer.
///
/// Sliders and ad banners both carry a free-text `link` the CMS lets an admin
/// point anywhere on the website. Three shapes arrive in practice, all of them
/// live on this shop today:
///
/// ```
/// ""                                                       -> nowhere
/// "/products"                                              -> relative
/// "https://…/products/trueway-farms-organic-finger-millet…" -> absolute
/// "https://…/shop-by-solution?tags=15"                      -> web only
/// ```
///
/// One definition for both carousels, because they were drifting: the ads
/// resolved relative links and mapped `/products` to the native screen, and the
/// slider did neither — every slide opened a web view of a page the app already
/// has a screen for.
library;

import '../config/app_config.dart';

abstract final class CmsLink {
  /// The link as something openable, or null when there is nothing to open.
  ///
  /// A relative link is resolved against [AppConfig.origin] rather than a
  /// literal, so a build pointed at a local or production backend does not send
  /// the customer to the dev site.
  static Uri? resolve(String? link) {
    final raw = link?.trim() ?? '';
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    return uri.hasScheme ? uri : Uri.parse(AppConfig.origin).resolveUri(uri);
  }

  /// The app route that serves [target] natively, or null for "open the web".
  ///
  /// Deliberately an exact mapping rather than "push whatever the path is":
  /// go_router throws on an unknown route, and the CMS can point a banner
  /// anywhere — `/shop-by-solution?tags=15` is on a live slider right now and
  /// has no app screen. Anything not named here opens in the web view, which
  /// can render every page the site has.
  ///
  /// A query is always a web link. The catalogue screen does not read one, so
  /// `/products?foo=bar` would open the plain catalogue and quietly drop
  /// whatever the admin was pointing at.
  static String? appRoute(Uri target) {
    if (target.hasQuery) return null;

    // `/products/` and `/products` are the same page to the website.
    final path = target.path.endsWith('/') && target.path.length > 1
        ? target.path.substring(0, target.path.length - 1)
        : target.path;

    if (path == '/products') return '/products';

    // The website's product URL is **plural** and the app's route is
    // **singular** — `/products/<slug>` vs `/product/<slug>`. Without this one
    // line the most useful link an admin can put on a banner, a link straight
    // to a product, opens a web page of a product the app has a real screen
    // for: no add-to-cart, no variants, no reviews.
    //
    // The slug is the same one `GET /ecommerce/products/{slug}` takes —
    // verified live against `…-finger-millet-ragi-185-kg-125`, which the
    // slider links to today and which resolves to product 125.
    const productPrefix = '/products/';
    if (path.startsWith(productPrefix)) {
      final slug = path.substring(productPrefix.length);
      // Nested paths (`/products/a/b`) are not product pages.
      if (slug.isNotEmpty && !slug.contains('/')) return '/product/$slug';
    }

    return null;
  }

  /// The `/web` location for [target], with [title] on the header.
  ///
  /// Both parts are encoded: a CMS title can carry an ampersand, and an
  /// unencoded one would end the `url` parameter early — the browser would open
  /// a truncated address.
  static String webRoute(Uri target, {String title = ''}) {
    final trimmed = title.trim();
    return '/web?url=${Uri.encodeComponent(target.toString())}'
        '${trimmed.isEmpty ? '' : '&title=${Uri.encodeComponent(trimmed)}'}';
  }
}

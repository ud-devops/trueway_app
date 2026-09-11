/// Where a CMS link takes the customer.
///
/// Every fixture here is a link that is **live on the shop right now**, read off
/// `GET /simple-sliders` and `GET /ads` on 2026-08-14:
///
/// ```
/// slider: https://dev.truewayerp.com/shop-by-solution?tags=15
/// slider: https://dev.truewayerp.com/products/trueway-farms-organic-finger-millet-ragi-185-kg-125
/// ad:     /products
/// ad:     (null)
/// ```
///
/// The one that matters most is the product link. The website's product URL is
/// **plural** (`/products/<slug>`) and this app's route is **singular**
/// (`/product/<slug>`) — so without the mapping below, the single most useful
/// thing a merchandiser can put on a banner opens a *web page* of a product the
/// app has a real screen for: no add-to-cart, no variants, no reviews.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/config/app_config.dart';
import 'package:trueway_farms/core/utils/cms_link.dart';

/// The live slider slug, which `GET /ecommerce/products/{slug}` resolves to
/// product 125.
const _slug = 'trueway-farms-organic-finger-millet-ragi-185-kg-125';

void main() {
  group('resolve', () {
    test('nothing to open is null, not an empty Uri', () {
      // Two of the three live slides and two of the five live ads carry "".
      for (final nothing in [null, '', '   ']) {
        expect(CmsLink.resolve(nothing), isNull, reason: '$nothing');
      }
    });

    test('a relative link is resolved against the build\'s own backend', () {
      // `/products` is what the CMS emits for the ads, and it is not something
      // a browser can open. Resolving it against a literal would send a
      // production build to the dev site.
      final resolved = CmsLink.resolve('/products');

      expect(resolved, isNotNull);
      expect(resolved.toString(), '${AppConfig.origin}/products');
    });

    test('an absolute link is left alone', () {
      const live = 'https://dev.truewayerp.com/shop-by-solution?tags=15';
      expect(CmsLink.resolve(live).toString(), live);
    });
  });

  group('appRoute — the app screen, when there is one', () {
    test('a product link becomes the SINGULAR app route', () {
      // The whole point: website `/products/<slug>` -> app `/product/<slug>`.
      final target = CmsLink.resolve('${AppConfig.origin}/products/$_slug')!;

      expect(CmsLink.appRoute(target), '/product/$_slug');
    });

    test('a relative product link works the same way', () {
      final target = CmsLink.resolve('/products/$_slug')!;
      expect(CmsLink.appRoute(target), '/product/$_slug');
    });

    test('the catalogue link opens the catalogue', () {
      expect(CmsLink.appRoute(CmsLink.resolve('/products')!), '/products');
      // The website treats these as the same page.
      expect(CmsLink.appRoute(CmsLink.resolve('/products/')!), '/products');
    });

    test('a page the app has no screen for stays on the web', () {
      // Live on a slider today, and go_router would throw on it.
      final target =
          CmsLink.resolve('${AppConfig.origin}/shop-by-solution?tags=15')!;

      expect(CmsLink.appRoute(target), isNull);
    });

    test('anything with a query stays on the web', () {
      // The catalogue screen reads no query, so a native push would open the
      // plain catalogue and quietly drop what the admin was pointing at.
      expect(CmsLink.appRoute(CmsLink.resolve('/products?tags=15')!), isNull);
      expect(
        CmsLink.appRoute(CmsLink.resolve('/products/$_slug?ref=banner')!),
        isNull,
      );
    });

    test('a nested path under /products is not a product page', () {
      expect(CmsLink.appRoute(CmsLink.resolve('/products/a/b')!), isNull);
    });

    test('unknown pages stay on the web', () {
      for (final path in ['/', '/about-us', '/faq', '/blog/some-post']) {
        expect(CmsLink.appRoute(CmsLink.resolve(path)!), isNull, reason: path);
      }
    });
  });

  group('webRoute', () {
    test('carries the whole URL, encoded', () {
      const live = 'https://dev.truewayerp.com/shop-by-solution?tags=15';
      final route = CmsLink.webRoute(CmsLink.resolve(live)!, title: 'Offer');

      // Unencoded, the `?tags=15` would end the `url` parameter early and the
      // browser would open a truncated address.
      expect(route, contains(Uri.encodeComponent(live)));
      expect(route, startsWith('/web?url='));
      expect(route, contains('&title=Offer'));
    });

    test('an ampersand in the title does not end the parameter', () {
      final route = CmsLink.webRoute(
        CmsLink.resolve('/faq')!,
        title: 'Shipping & delivery',
      );

      expect(route, contains(Uri.encodeComponent('Shipping & delivery')));
      expect(Uri.parse(route).queryParameters['title'], 'Shipping & delivery');
    });

    test('an empty title is omitted rather than sent blank', () {
      // Every live slide has `title: ""`. A blank `title=` would override the
      // WebViewScreen's own "Trueway Farms" fallback with nothing.
      for (final blank in ['', '   ']) {
        final route = CmsLink.webRoute(CmsLink.resolve('/faq')!, title: blank);
        expect(route, isNot(contains('title=')), reason: '"$blank"');
      }
    });
  });
}

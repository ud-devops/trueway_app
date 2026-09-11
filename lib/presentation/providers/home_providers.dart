import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/ad_model.dart';
import '../../data/models/brand_model.dart';
import '../../data/models/category_model.dart';
import '../../data/models/home_sections.dart';
import '../../data/models/product_model.dart';
import '../../data/models/slider_model.dart';
import 'core_providers.dart';

final slidersProvider = FutureProvider<List<HomeSlider>>((ref) async {
  return ref.watch(catalogRepositoryProvider).sliders();
});

final adsProvider = FutureProvider<List<AdBanner>>((ref) async {
  return ref.watch(catalogRepositoryProvider).ads();
});

final categoriesProvider = FutureProvider<List<Category>>((ref) async {
  return ref.watch(catalogRepositoryProvider).categories();
});

/// Flash sales worth putting on screen.
///
/// `FlashSaleController::index` already filters `wherePublished()`,
/// `notExpired()` and `started()`, so the endpoint only ever returns running
/// sales — [HomeRepository.liveFlashSales] additionally drops any that came
/// back with no products, which would otherwise render an empty countdown.
///
/// ⚠ **This store has never run a flash sale.** `GET /ecommerce/flash-sales`
/// answers `{"error":false,"data":[],"message":null}` on every probe, so the
/// populated shape is **source-derived, not observed** — see
/// `FlashSaleProductResource`. Everything downstream degrades to "no section"
/// rather than assuming a field is present.
final flashSalesProvider = FutureProvider<List<FlashSale>>((ref) async {
  return ref.watch(homeRepositoryProvider).liveFlashSales();
});

final brandsProvider = FutureProvider<List<Brand>>((ref) async {
  return ref.watch(catalogRepositoryProvider).brands();
});

/// How many products each home carousel asks for.
///
/// The endpoint's own default is 4, which is thin for a rail that already shows
/// ~2.5 cards on a phone — there would be almost nothing to scroll. 10 keeps it
/// inside the server's hard cap of 20. `limit=1` is the one value that must
/// never be sent (it 500s); [HomeRepository.sections] clamps anyway.
const int kHomeSectionLimit = 10;

/// The four home carousels — best sellers, trending, new arrivals, top rated —
/// from ONE call to `/top-products-group`.
///
/// This is the whole point of the endpoint: four merchandising rows for a
/// single round trip. Every carousel reads *this* provider; none of them may
/// fetch on its own, or the saving is thrown away.
///
/// Sections empty out individually and legitimately (`top_selling` is computed
/// from the last 30 days of paid orders, `top_rated` needs reviews), so an
/// empty list is not an error — see [HomeSections.sections], which drops the
/// empty ones. A thrown [ApiException] is a different thing entirely and the UI
/// must show it rather than silently render nothing.
final homeSectionsProvider = FutureProvider<HomeSections>((ref) async {
  return ref
      .watch(homeRepositoryProvider)
      .sections(limit: kHomeSectionLimit);
});

/// First page of products for the home feed.
final featuredProductsProvider = FutureProvider<List<Product>>((ref) async {
  final res = await ref.watch(catalogRepositoryProvider).products(perPage: 20);
  return res.items;
});

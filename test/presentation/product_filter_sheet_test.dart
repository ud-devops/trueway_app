import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/presentation/providers/catalog_filter_provider.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/widgets/product_filter_sheet.dart';

import '../support/fake_home_repository.dart';

/// The advanced filter sheet on a category listing.
///
/// Facets come from `GET /ecommerce/filters?categories[]=<id>`, so the sheet
/// only ever offers a choice that some product in this category actually has.

/// Opens the sheet and hands back both the fake and the chosen selection.
Future<
    ({
      FakeHomeRepository facets,
      Future<FilterSelection?> result,
    })> _open(
  WidgetTester tester, {
  FilterSelection selection = const FilterSelection(),
  List<Map<String, dynamic>> attributeSets = kPackSizeAttributeSets,
  List<Map<String, dynamic>> tags = kHealthTags,
  List<Map<String, dynamic>> collections = kCollections,
  List<Map<String, dynamic>> discountRanges = kDiscountRanges,
  List<Map<String, dynamic>> ratingRanges = kRatingRanges,
  double maxPrice = 4200,
  int categoryId = 17,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final facets = FakeHomeRepository(
    attributeSets: attributeSets,
    tags: tags,
    collections: collections,
    discountRanges: discountRanges,
    ratingRanges: ratingRanges,
    maxPrice: maxPrice,
  );
  late Future<FilterSelection?> result;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [homeRepositoryProvider.overrideWithValue(facets)],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => result = showProductFilterSheet(
                  context,
                  categoryId: categoryId,
                  selection: selection,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  return (facets: facets, result: result);
}

void main() {
  testWidgets('offers the category\'s attribute sets and tags', (tester) async {
    await _open(tester);

    expect(find.text('Pack Size'), findsOneWidget);
    expect(find.text('1.85 KG (Pack of 1)'), findsOneWidget);
    expect(find.text('5 KG (Pack of 2)'), findsOneWidget);
    expect(find.text('Good for'), findsOneWidget);
  });

  // The count is what turns a guess into a decision.
  testWidgets('shows the product count the server sends for a tag',
      (tester) async {
    await _open(tester);

    expect(find.text('Diabetes Friendly (2)'), findsOneWidget);
  });

  // Scoped to the category being browsed, so a filter can never come back
  // empty just because it belongs to a different part of the catalogue.
  testWidgets('asks for the facets of this category only', (tester) async {
    final t = await _open(tester, categoryId: 42);

    expect(t.facets.lastCategoryId, 42);
  });

  testWidgets('returns the chosen facets on apply', (tester) async {
    final t = await _open(tester);

    await tester.tap(find.byKey(const Key('facet-22')));
    await tester.tap(find.byKey(const Key('facet-15')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-apply')));
    await tester.pumpAndSettle();

    final chosen = await t.result;
    expect(chosen!.attributeIds, {22});
    expect(chosen.tagIds, {15});
  });

  testWidgets('the apply button counts what was chosen', (tester) async {
    await _open(tester);
    expect(find.text('Apply'), findsOneWidget, reason: 'nothing chosen yet');

    await tester.tap(find.byKey(const Key('facet-22')));
    await tester.pumpAndSettle();

    expect(find.text('Apply 1'), findsOneWidget);
  });

  testWidgets('tapping a chosen facet again removes it', (tester) async {
    final t = await _open(tester);

    await tester.tap(find.byKey(const Key('facet-22')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('facet-22')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-apply')));
    await tester.pumpAndSettle();

    expect((await t.result)!.isEmpty, isTrue);
  });

  testWidgets('clear all empties the draft', (tester) async {
    await _open(
      tester,
      selection: const FilterSelection(attributeIds: {22}, tagIds: {15}),
    );
    expect(find.text('Apply 2'), findsOneWidget, reason: 'the premise');

    await tester.tap(find.byKey(const Key('filter-clear')));
    await tester.pumpAndSettle();

    expect(find.text('Apply'), findsOneWidget);
  });

  testWidgets('cancelling keeps the previous selection', (tester) async {
    final t = await _open(
      tester,
      selection: const FilterSelection(tagIds: {15}),
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await t.result, isNull, reason: 'the caller should keep its own');
  });

  // The API has no in-stock parameter, so this one filters the page that came
  // back rather than the query — but it is still a filter the customer chose.
  testWidgets('in stock only is part of the selection', (tester) async {
    final t = await _open(tester);

    await tester.tap(find.byKey(const Key('filter-in-stock')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('filter-apply')));
    await tester.pumpAndSettle();

    expect((await t.result)!.inStockOnly, isTrue);
  });

  // A single brand cannot narrow anything, and this store has exactly one.
  testWidgets('offers no brand section when there is one brand',
      (tester) async {
    await _open(tester);

    expect(find.text('Brand'), findsNothing);
  });

  // The facets failing must not take the working controls down with them.
  testWidgets('still offers in-stock when the facets cannot be read',
      (tester) async {
    await _open(
      tester,
      attributeSets: const [],
      tags: const [],
      collections: const [],
      discountRanges: const [],
      ratingRanges: const [],
      maxPrice: 0,
    );

    expect(find.byKey(const Key('filter-in-stock')), findsOneWidget);
    expect(find.byKey(const Key('filter-apply')), findsOneWidget);
  });

  // The app's ChipThemeData fills every chip with `primarySoft`, so an
  // unstyled FilterChip renders *unselected* in the same pale green it uses for
  // selected — the whole group looked already chosen.
  group('a chip shows whether it is chosen', () {
    FilterChip chipFor(WidgetTester tester, String key) =>
        tester.widget<FilterChip>(find.byKey(Key(key)));

    testWidgets('an unselected chip is not filled with the theme green',
        (tester) async {
      await _open(tester);

      final chip = chipFor(tester, 'facet-22');
      expect(chip.selected, isFalse, reason: 'the premise');
      // Null is the bug, not a pass: it means the chip inherits
      // ChipThemeData.backgroundColor, which is the same green as selected.
      expect(chip.backgroundColor, isNotNull, reason: 'it inherits the theme');
      expect(
        chip.backgroundColor,
        isNot(AppTheme.light.chipTheme.backgroundColor),
        reason: 'it reads as already selected',
      );
    });

    testWidgets('selected and unselected are different fills', (tester) async {
      await _open(tester);

      final chip = chipFor(tester, 'facet-22');
      expect(chip.backgroundColor, isNotNull);
      expect(chip.selectedColor, isNotNull);
      expect(chip.backgroundColor, isNot(chip.selectedColor));
    });

    testWidgets('choosing one marks only that chip', (tester) async {
      await _open(tester);

      await tester.tap(find.byKey(const Key('facet-22')));
      await tester.pumpAndSettle();

      expect(chipFor(tester, 'facet-22').selected, isTrue);
      expect(chipFor(tester, 'facet-21').selected, isFalse);
      expect(chipFor(tester, 'facet-23').selected, isFalse);
    });
  });

  // Both take *prefixed tokens*: `ProductRepository` matches
  // `str_starts_with($f, 'rating_')`, so a bare `4` parses fine and filters
  // nothing at all. Verified live: rating_4 -> 2 of 6, on_sale -> 5 of 6.
  group('ratings and offers', () {
    testWidgets('offers both sections', (tester) async {
      await _open(tester);

      expect(find.text('Customer rating'), findsOneWidget);
      expect(find.text('Offers'), findsOneWidget);
      // The server's label, not one of ours.
      expect(find.text('On Sale (5)'), findsOneWidget);
    });

    testWidgets('a rating threshold comes back as one value', (tester) async {
      final t = await _open(tester);

      await tester.tap(find.byKey(const Key('facet-rating_4')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();

      final chosen = await t.result;
      expect(chosen!.minRating, 4);
      expect(chosen.ratingTokens, ['rating_4'], reason: 'the prefix matters');
    });

    // The server ORs the list, so 3+ and 4+ together would just mean 3+ — a
    // control that cannot say anything the simpler one cannot.
    testWidgets('picking a second threshold replaces the first',
        (tester) async {
      final t = await _open(tester);

      await tester.tap(find.byKey(const Key('facet-rating_4')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('facet-rating_3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();

      expect((await t.result)!.ratingTokens, ['rating_3']);
    });

    testWidgets('tapping the chosen threshold clears it', (tester) async {
      final t = await _open(tester);

      await tester.tap(find.byKey(const Key('facet-rating_4')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('facet-rating_4')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();

      expect((await t.result)!.minRating, isNull);
    });

    // Offers are ORed, which is what a row of chips implies.
    testWidgets('offers stack', (tester) async {
      final t = await _open(tester);

      await tester.tap(find.byKey(const Key('facet-on_sale')));
      await tester.tap(find.byKey(const Key('facet-discount_20')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();

      expect((await t.result)!.sortedDiscounts, ['discount_20', 'on_sale']);
    });
  });

  // Shippable since the backend started comparing the displayed price
  // (2026-08-12). Before that a rupee slider would have contradicted the
  // prices beside it.
  group('price', () {
    testWidgets('offers a slider bounded by the server ceiling',
        (tester) async {
      await _open(tester);

      expect(find.byType(RangeSlider), findsOneWidget);
      expect(tester.widget<RangeSlider>(find.byType(RangeSlider)).max, 4200);
    });

    // The callback is invoked rather than the thumb dragged: a RangeSlider's
    // hit geometry is not something a widget test can aim at reliably, and the
    // question here is whether the chosen bounds reach the caller.
    testWidgets('a narrowed range comes back as rupee bounds', (tester) async {
      final t = await _open(tester);

      tester
          .widget<RangeSlider>(find.byType(RangeSlider))
          .onChanged!(const RangeValues(0, 900));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();

      final chosen = await t.result;
      expect(chosen!.maxPrice, 900);
      expect(chosen.minPrice, 0);
    });

    testWidgets('the slider shows the chosen band', (tester) async {
      await _open(tester);

      tester
          .widget<RangeSlider>(find.byType(RangeSlider))
          .onChanged!(const RangeValues(0, 900));
      await tester.pumpAndSettle();

      expect(find.textContaining('900'), findsWidgets);
      expect(find.text('Apply 1'), findsOneWidget);
    });

    // A range covering everything narrows nothing, so it must not count as a
    // filter — the pill would say "1" for a slider the customer never moved.
    testWidgets('the full range is not a filter', (tester) async {
      const untouched = FilterSelection();
      expect(untouched.withPriceRange(0, 4200, 4200).isEmpty, isTrue);
      expect(untouched.withPriceRange(0, 900, 4200).count, 1);
    });

    // Nothing to bound, and a 0-to-0 slider is worse than no slider.
    testWidgets('hides itself when the ceiling is unknown', (tester) async {
      await _open(tester, maxPrice: 0);

      expect(find.byType(RangeSlider), findsNothing);
    });
  });

  group('collections', () {
    testWidgets('offers them with the server counts', (tester) async {
      await _open(tester);

      expect(find.text('Collections'), findsOneWidget);
      expect(find.text('New Arrival (4)'), findsOneWidget);
      expect(find.text('Special Offer (2)'), findsOneWidget);
    });

    testWidgets('a chosen collection comes back by id', (tester) async {
      final t = await _open(tester);

      await tester.tap(find.byKey(const Key('facet-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-apply')));
      await tester.pumpAndSettle();

      expect((await t.result)!.collectionIds, {1});
    });

    testWidgets('the section hides when the server sends none',
        (tester) async {
      await _open(tester, collections: const []);

      expect(find.text('Collections'), findsNothing);
    });
  });

  // The bands used to be hardcoded from the PHP source, so an admin could not
  // change them without a mobile release.
  group('bands come from the server', () {
    testWidgets('labels and counts are the ones sent', (tester) async {
      await _open(tester);

      expect(find.text('4+ Stars (2)'), findsOneWidget);
      expect(find.text('On Sale (5)'), findsOneWidget);
      expect(find.text('20% or more (5)'), findsOneWidget);
    });

    // The old hardcoded list had a 25% band; the server sends 20%.
    testWidgets('no band survives that the server did not send',
        (tester) async {
      await _open(tester);

      expect(find.textContaining('25%'), findsNothing);
    });

    testWidgets('the sections vanish when no band is sent', (tester) async {
      await _open(tester, discountRanges: const [], ratingRanges: const []);

      expect(find.text('Customer rating'), findsNothing);
      expect(find.text('Offers'), findsNothing);
    });
  });
}

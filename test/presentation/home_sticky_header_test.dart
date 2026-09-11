import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/category_model.dart';
import 'package:trueway_farms/presentation/widgets/home_sticky_header.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';

/// Status bar height typical of a modern Android device.
const _statusBar = 48.0;

List<Category> _categories(int n) => [
      for (var i = 1; i <= n; i++)
        Category(
          id: i,
          name: 'Category $i',
          slug: 'category-$i',
          parentId: 0,
        ),
    ];

/// Mirrors how HomeScreen hosts the header, minus the providers.
Future<void> _pump(
  WidgetTester tester, {
  required List<Category> categories,
  int? selectedId,
  ValueChanged<int?>? onSelected,
}) async {
  final header = HomeStickyHeader(
    categories: categories,
    selectedId: selectedId,
    showTabs: categories.isNotEmpty,
    onCategorySelected: onSelected ?? (_) {},
    onSearchTap: () {},
  );

  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(padding: EdgeInsets.only(top: _statusBar)),
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                toolbarHeight: 0,
                collapsedHeight: 0,
                expandedHeight:
                    kHomeGreetingHeight + header.preferredSize.height,
                flexibleSpace: const FlexibleSpaceBar(
                  background: SafeArea(
                    bottom: false,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        height: kHomeGreetingHeight,
                        child: Text('GREETING'),
                      ),
                    ),
                  ),
                ),
                bottom: header,
              ),
              SliverList.builder(
                itemCount: 40,
                itemBuilder: (_, i) => SizedBox(height: 80, child: Text('row $i')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('pinned strip', () {
    // The bug this guards: as a bare SliverPersistentHeader the strip pinned to
    // the very top of the viewport and slid under the status bar, colliding
    // with the clock and battery icons.
    testWidgets('stays below the status bar once scrolled', (tester) async {
      await _pump(tester, categories: _categories(6));

      final searchAtRest = tester.getTopLeft(find.byType(HomeSearchField)).dy;
      expect(searchAtRest, greaterThanOrEqualTo(_statusBar));

      // Scroll well past the greeting.
      await tester.drag(find.text('row 3'), const Offset(0, -600));
      await tester.pumpAndSettle();

      final searchWhenPinned =
          tester.getTopLeft(find.byType(HomeSearchField)).dy;
      expect(
        searchWhenPinned,
        greaterThanOrEqualTo(_statusBar),
        reason: 'the pinned strip must not slide under the system status bar',
      );
    });

    testWidgets('search and tabs survive scrolling', (tester) async {
      await _pump(tester, categories: _categories(6));

      await tester.drag(find.text('row 3'), const Offset(0, -600));
      await tester.pumpAndSettle();

      expect(find.byType(HomeSearchField), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
    });

    testWidgets('the greeting scrolls away', (tester) async {
      await _pump(tester, categories: _categories(6));
      expect(find.text('GREETING'), findsOneWidget);

      await tester.drag(find.text('row 3'), const Offset(0, -600));
      await tester.pumpAndSettle();

      // Collapsed to status bar + strip, so the greeting is gone.
      final greeting = tester.getTopLeft(find.byType(HomeSearchField)).dy;
      expect(greeting, lessThan(_statusBar + kHomeGreetingHeight));
    });
  });

  group('tabs', () {
    testWidgets('render "All" first, then the categories', (tester) async {
      await _pump(tester, categories: _categories(3));

      expect(find.text('All'), findsOneWidget);
      expect(find.text('Category 1'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('All')).dx,
        lessThan(tester.getTopLeft(find.text('Category 1')).dx),
      );
    });

    testWidgets('report the tapped category id', (tester) async {
      int? tapped = -1;
      await _pump(
        tester,
        categories: _categories(3),
        onSelected: (id) => tapped = id,
      );

      await tester.tap(find.text('Category 2'));
      await tester.pumpAndSettle();
      expect(tapped, 2);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(tapped, isNull, reason: 'the All tab clears the filter');
    });

    // Height differs with and without tabs, so `expandedHeight` and `bottom`
    // must be derived from the same instance or the bar clips its own content.
    testWidgets('collapse to search only when there are no categories',
        (tester) async {
      await _pump(tester, categories: const []);

      expect(find.byType(HomeSearchField), findsOneWidget);
      expect(find.text('All'), findsNothing);
    });

    testWidgets('preferredSize accounts for the tab strip', (tester) async {
      const withTabs = HomeStickyHeader(
        categories: [],
        selectedId: null,
        onCategorySelected: _noop,
        onSearchTap: _noopVoid,
      );
      const withoutTabs = HomeStickyHeader(
        categories: [],
        selectedId: null,
        showTabs: false,
        onCategorySelected: _noop,
        onSearchTap: _noopVoid,
      );

      expect(withTabs.preferredSize.height,
          kStickySearchHeight + kStickyTabsHeight,);
      expect(withoutTabs.preferredSize.height, kStickySearchHeight);
    });
  });

  group('tab labels', () {
    // The tab is 76dp wide. "Wheat & Wheat Flour" needs roughly 115dp at the
    // 12px caption size, so on one line it ellipsised to "Wheat & …" no matter
    // how small the type got — the name only fits if it is allowed to wrap.
    testWidgets('a long category name wraps instead of being cut off',
        (tester) async {
      await _pump(tester, categories: [
        const Category(
          id: 17,
          name: 'Wheat & Wheat Flour',
          slug: 'wheat-wheat-flour',
          parentId: 0,
        ),
      ],);

      final label = tester.widget<Text>(find.text('Wheat & Wheat Flour'));
      expect(label.maxLines, 2);
      expect(label.style?.fontSize, 11);
    });

    testWidgets('the strip grows with the OS text scale', (tester) async {
      // A fixed box around real text paints overflow stripes at the
      // accessibility sizes. That was already true of the single-line label at
      // 2x (38 + 4 + 32 + 4 + 2.5 against a box of 74); wrapping only made it
      // arrive sooner.
      final measured = <double, double>{};

      Future<void> measure(double scale) async {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Builder(
              builder: (context) {
                measured[scale] = stickyTabsHeight(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        );
      }

      await measure(1.0);
      await measure(2.0);
      await measure(4.0);

      expect(measured[1.0], kStickyTabsHeight);
      expect(measured[2.0], kStickyTabsHeight * 2);
      // Capped, or the tabs would take the whole viewport.
      expect(measured[4.0], kStickyTabsHeight * 2);
    });
  });
}

void _noop(int? _) {}
void _noopVoid() {}

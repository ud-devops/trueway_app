import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/category_model.dart';
import 'package:trueway_farms/presentation/providers/home_providers.dart';
import 'package:trueway_farms/presentation/screens/categories/categories_screen.dart';

Category _cat(int id, String name, {int parentId = 0, List<Category> children = const []}) =>
    Category(
      id: id,
      name: name,
      slug: name.toLowerCase().replaceAll(' ', '-'),
      parentId: parentId,
      children: children,
    );

/// The real tree shape: some roots have children, most do not.
List<Category> _tree() => [
      _cat(17, 'Wheat & Wheat Flour', children: [
        _cat(29, 'Wheat Flour', parentId: 17),
        _cat(28, 'Wheat', parentId: 17),
      ],),
      _cat(18, 'Millets', children: [
        _cat(30, 'Whole Millets', parentId: 18),
      ],),
      _cat(19, 'Pulses (Dals)'),
      _cat(20, 'Rice'),
    ];

/// Gives the test a viewport tall enough to hold every section.
///
/// The page nests non-scrolling GridViews inside a ListView, so
/// `scrollUntilVisible` cannot resolve a single Scrollable to drive. Sizing the
/// surface up is deterministic and lets a test assert on the whole page.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester, List<Category> roots) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        categoriesProvider.overrideWith((ref) async => roots),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const CategoriesScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('index', () {
    testWidgets('shows each parent as a heading over its subcategories',
        (tester) async {
      await _pump(tester, _tree());

      expect(find.text('Wheat & Wheat Flour'), findsOneWidget);
      expect(find.text('Wheat Flour'), findsOneWidget);
      expect(find.text('Wheat'), findsOneWidget);

      expect(find.text('Millets'), findsOneWidget);
      expect(find.text('Whole Millets'), findsOneWidget);
    });

    testWidgets('the heading sits above its own tiles', (tester) async {
      await _pump(tester, _tree());

      expect(
        tester.getTopLeft(find.text('Wheat & Wheat Flour')).dy,
        lessThan(tester.getTopLeft(find.text('Wheat Flour')).dy),
      );
    });

    // Six of ten real roots have no children; a strict heading-per-root layout
    // would render six empty sections.
    testWidgets('collects childless roots into one trailing section',
        (tester) async {
      _useTallViewport(tester);
      await _pump(tester, _tree());

      expect(find.text('More categories'), findsOneWidget);
      expect(find.text('Pulses (Dals)'), findsOneWidget);
      expect(find.text('Rice'), findsOneWidget);
    });

    testWidgets('omits the extra section when every root has children',
        (tester) async {
      await _pump(tester, [
        _cat(17, 'Wheat', children: [_cat(28, 'Whole Wheat', parentId: 17)]),
      ]);

      expect(find.text('More categories'), findsNothing);
      expect(find.text('All categories'), findsNothing);
    });

    testWidgets('names the section differently when nothing has children',
        (tester) async {
      await _pump(tester, [_cat(19, 'Pulses'), _cat(20, 'Rice')]);

      expect(find.text('All categories'), findsOneWidget);
      expect(find.text('More categories'), findsNothing);
    });

    testWidgets('shows an empty state when the tree is empty', (tester) async {
      await _pump(tester, const []);
      expect(find.text('No categories yet'), findsOneWidget);
    });

    // A parent that only exists to group children should not also be tappable
    // as a tile — it appears once, as the heading.
    testWidgets('a grouped parent appears only as a heading', (tester) async {
      await _pump(tester, _tree());
      expect(find.text('Wheat & Wheat Flour'), findsOneWidget);
    });
  });
}

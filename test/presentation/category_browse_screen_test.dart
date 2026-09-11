import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/category_model.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/home_providers.dart';
import 'package:trueway_farms/presentation/screens/categories/category_browse_screen.dart';

Category _cat(
  int id,
  String name, {
  int parentId = 0,
  List<Category> children = const [],
}) =>
    Category(
      id: id,
      name: name,
      slug: name.toLowerCase().replaceAll(' ', '-'),
      parentId: parentId,
      children: children,
    );

/// Mirrors the live tree: two roots with children, two without.
List<Category> _tree() => [
      _cat(17, 'Wheat & Wheat Flour', children: [
        _cat(29, 'Wheat Flour', parentId: 17),
        _cat(28, 'Wheat', parentId: 17),
        _cat(40, 'Sona Moti Wheat', parentId: 17),
      ],),
      _cat(18, 'Millets', children: [
        _cat(30, 'Whole Millets', parentId: 18),
      ],),
      _cat(19, 'Pulses (Dals)'),
      _cat(20, 'Rice'),
    ];

Future<void> _pump(WidgetTester tester, int categoryId) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        categoriesProvider.overrideWith((ref) async => _tree()),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: CategoryBrowseScreen(categoryId: categoryId),
      ),
    ),
  );
  // Products come from a real repository call that has no stub here, so settle
  // is not reachable — pump enough frames for the tree to resolve instead.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('branch resolution', () {
    // Tapping a subcategory should put its siblings in the rail so the customer
    // can move sideways without going back.
    testWidgets('a subcategory gets its siblings in the rail', (tester) async {
      await _pump(tester, 29); // Wheat Flour

      expect(find.text('Wheat Flour'), findsOneWidget);
      expect(find.text('Wheat'), findsOneWidget);
      expect(find.text('Sona Moti Wheat'), findsOneWidget);
      // Siblings only — nothing from another branch.
      expect(find.text('Whole Millets'), findsNothing);
    });

    testWidgets('the parent name titles the screen', (tester) async {
      await _pump(tester, 29);
      expect(find.text('Wheat & Wheat Flour'), findsOneWidget);
    });

    testWidgets('a root with children shows those children', (tester) async {
      await _pump(tester, 17); // Wheat & Wheat Flour itself

      expect(find.text('Wheat Flour'), findsOneWidget);
      expect(find.text('Sona Moti Wheat'), findsOneWidget);
    });

    // Six of ten live roots have no children; the rail falls back to the root
    // list so those stay navigable rather than showing an empty sidebar.
    testWidgets('a childless root falls back to the root list', (tester) async {
      await _pump(tester, 20); // Rice

      expect(find.text('Rice'), findsOneWidget);
      expect(find.text('Pulses (Dals)'), findsOneWidget);
      expect(find.text('Millets'), findsOneWidget);
    });

    testWidgets('an unknown id still renders a usable rail', (tester) async {
      // e.g. a stale deep link to a category that has since been removed.
      await _pump(tester, 99999);

      expect(find.text('Categories'), findsOneWidget);
      expect(find.text('Wheat & Wheat Flour'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('rail', () {
    // The old all-categories screen had an "All" entry; scoped to one branch it
    // would silently widen the results beyond the category the customer chose.
    testWidgets('has no "All" entry', (tester) async {
      await _pump(tester, 29);
      expect(find.text('All'), findsNothing);
    });
  });
}

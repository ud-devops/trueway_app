import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/review.dart';
import 'package:trueway_farms/data/repositories/review_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/screens/product/write_review_screen.dart';

/// Every field on the review form is required.
///
/// The server only insists on `star` and `comment` (`API\ReviewRequest`); the
/// photo is this shop's own rule, matching the return form. Either way the
/// refusal has to happen **here** — a submit that reaches the server and comes
/// back 422 costs a round trip and shows the customer a message they could have
/// been given while typing.
///
/// These tests are written from the refusal side on purpose. Satisfying the
/// photo rule needs `image_picker`, which cannot run under the test binding, so
/// what is pinned is that an incomplete form **sends nothing** — which is the
/// requirement.

class _RecordingReviewRepository implements ReviewRepository {
  final List<({int productId, int star, String comment})> created = [];

  @override
  Future<Review?> create({
    required int productId,
    required int star,
    required String comment,
    List<String> imagePaths = const [],
    List<String> videoPaths = const [],
  }) async {
    created.add((productId: productId, star: star, comment: comment));
    return null;
  }

  /// The form reads the gate for its upload limits.
  @override
  Future<({ReviewEligibility eligibility, ReviewSettings settings})> reviewGate(
    String slug,
  ) async =>
      (
        eligibility: ReviewEligibility.unknown,
        settings: ReviewSettings.fallback,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'RecordingReviewRepository does not implement ${invocation.memberName}',
      );
}

Future<_RecordingReviewRepository> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final repo = _RecordingReviewRepository();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        reviewRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const WriteReviewScreen(
          productId: 118,
          productName: 'Organic Desi Khand',
          productSlug: 'organic-desi-khand',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

/// Presses the form's submit button, wherever it sits.
Future<void> _submit(WidgetTester tester) async {
  final button = find.widgetWithText(ElevatedButton, 'Post review');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _writeComment(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).first, text);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an untouched form sends nothing and says why', (tester) async {
    final repo = await _pump(tester);

    await _submit(tester);

    expect(repo.created, isEmpty);
    expect(find.textContaining('rating'), findsWidgets);
    expect(
      find.textContaining('write a few words'),
      findsOneWidget,
      reason: 'the comment is required',
    );
    expect(
      find.textContaining('photo'),
      findsWidgets,
      reason: 'a photo is required',
    );
  });

  testWidgets('a rating alone is not enough', (tester) async {
    final repo = await _pump(tester);

    await tester.tap(find.byKey(const Key('review-star-5')));
    await tester.pumpAndSettle();
    await _submit(tester);

    expect(repo.created, isEmpty);
  });

  testWidgets('a rating and a comment without a photo still send nothing',
      (tester) async {
    final repo = await _pump(tester);

    await tester.tap(find.byKey(const Key('review-star-5')));
    await _writeComment(tester, 'Genuinely good wheat, ground fresh.');
    await _submit(tester);

    expect(repo.created, isEmpty, reason: 'the photo rule is not optional');
    expect(find.textContaining('photo'), findsWidgets);
  });

  testWidgets('a comment without a rating sends nothing', (tester) async {
    final repo = await _pump(tester);

    await _writeComment(tester, 'Genuinely good wheat, ground fresh.');
    await _submit(tester);

    expect(repo.created, isEmpty);
  });

  // The server's own rules, enforced here so the customer is not refused after
  // a round trip. `not_regex:/<[^>]*>/i` and `not_regex:/[Ѐ-ӿ]/u`.
  group('the comment rules the server would refuse on', () {
    testWidgets('angle brackets are caught before sending', (tester) async {
      final repo = await _pump(tester);

      await tester.tap(find.byKey(const Key('review-star-5')));
      await _writeComment(tester, 'I paid <10 for this> pack and it was fine.');
      await _submit(tester);

      expect(repo.created, isEmpty);
      expect(find.textContaining('Angle brackets'), findsOneWidget);
    });

    testWidgets('Cyrillic is caught before sending', (tester) async {
      final repo = await _pump(tester);

      await tester.tap(find.byKey(const Key('review-star-5')));
      await _writeComment(tester, 'Хороший продукт, отличное качество.');
      await _submit(tester);

      expect(repo.created, isEmpty);
      expect(find.textContaining('in English'), findsOneWidget);
    });

    testWidgets('a too-short comment is caught before sending', (tester) async {
      final repo = await _pump(tester);

      await tester.tap(find.byKey(const Key('review-star-5')));
      await _writeComment(tester, 'ok');
      await _submit(tester);

      expect(repo.created, isEmpty);
      // Specific: the picker also says "Add at least one photo", and a loose
      // matcher would pass on that instead of the comment rule under test.
      expect(find.textContaining('characters'), findsOneWidget);
    });
  });

  // The rules above are enforced on submit. These say so beforehand, which is
  // the difference between a form that guides and one that scolds.
  group('required markers', () {
    testWidgets('every required field is starred', (tester) async {
      await _pump(tester);

      expect(find.textContaining('Your rating *'), findsOneWidget);
      expect(find.textContaining('Your review *'), findsOneWidget);
      expect(find.textContaining('Photos or video *'), findsOneWidget);
    });

    // The word said the same thing the asterisk does.
    testWidgets('the picker does not also spell out "Required"',
        (tester) async {
      await _pump(tester);

      expect(find.text('Required'), findsNothing);
    });

    testWidgets('they are there before any submit', (tester) async {
      await _pump(tester);

      expect(find.textContaining('write a few words'), findsNothing,
          reason: 'no errors yet',);
      expect(find.textContaining('*'), findsWidgets);
    });
  });

  // Errors appear on submit, not while the customer is still typing their
  // first character.
  testWidgets('nothing is flagged before the first submit', (tester) async {
    await _pump(tester);

    expect(find.textContaining('write a few words'), findsNothing);
    expect(find.textContaining('Add at least one photo'), findsNothing);
  });
}

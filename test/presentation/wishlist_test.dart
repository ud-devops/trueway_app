import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_icons.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/data/models/product_model.dart';
import 'package:trueway_farms/data/repositories/wishlist_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/screens/wishlist/wishlist_screen.dart';
import 'package:trueway_farms/presentation/widgets/product_card.dart';
import 'package:trueway_farms/presentation/widgets/wishlist_button.dart';
import 'package:trueway_farms/presentation/widgets/product_grid.dart';
import 'package:trueway_farms/presentation/widgets/state_views.dart';

import '../support/fake_home_repository.dart';

/// Wishlist slice: the heart on a product card and the saved-items screen.
///
/// Nothing here touches the network - [_FakeWishlistRepository] stands in for
/// the real one through `wishlistRepositoryProvider`.

// ---------------------------------------------------------------------------
// Fixtures, shaped like a row of `data.items` from
// GET /ecommerce/wishlist/{id}.
// ---------------------------------------------------------------------------

Map<String, dynamic> _productJson(
  int id, {
  String? name,
  String? slug,
  bool soldOut = false,
}) =>
    {
      'id': id,
      'slug': slug ?? 'product-$id',
      'name': name ?? 'Product $id',
      'price': 943.95,
      'price_formatted': '₹943.95',
      'original_price': 1296.75,
      'weight': 5000,
      'quantity': soldOut ? 0 : 10,
      'is_out_of_stock': soldOut,
      'stock_status_label': soldOut ? 'Out of stock' : 'In stock',
    };

Product _product(int id, {String? name, String? slug, bool soldOut = false}) =>
    Product.fromJson(
      _productJson(id, name: name, slug: slug, soldOut: soldOut),
    );

/// Builds the envelope the way the server does - items nested under `data`,
/// keyed by an opaque rowId - so the parser is exercised rather than bypassed.
WishlistSnapshot _snapshot(
  List<int> ids, {
  int? serverCount,
  bool? added,
  String id = 'list-1',
}) =>
    WishlistSnapshot.fromJson({
      'id': id,
      'data': {
        'count': serverCount ?? ids.length,
        if (added != null) 'added': added,
        'items': ids.isEmpty
            ? <dynamic>[] // PHP serialises an empty list as `[]`, not `{}`.
            : {
                for (final pid in ids)
                  'row-$pid': {
                    ..._productJson(pid),
                    'rowId': 'row-$pid',
                    'original_product_id': pid,
                    'is_variation': 0,
                  },
              },
      },
    });

const _boom = ApiException(
  'The server had a problem.',
  kind: ApiErrorKind.server,
  statusCode: 500,
);

/// A failure [ApiException.isRetryable] refuses to offer a retry for, so
/// [AppErrorView] renders no "Try again" button at all. The screen has to keep
/// a way back from this state anyway.
const _notFound = ApiException(
  'Not found',
  kind: ApiErrorKind.notFound,
  statusCode: 404,
);

// ---------------------------------------------------------------------------
// Fake repository
// ---------------------------------------------------------------------------

/// Implements the repository interface rather than subclassing it, so no
/// ApiClient (and therefore no Dio, no socket) is ever constructed.
///
/// Models the failure shapes the UI has to survive:
///
///  * a mutation that fails **and wipes the list** ([wipeOnMutationFailure]),
///    the verified live behaviour of a 404'd DELETE, with `latest` re-read to
///    the emptied list exactly as the real repository does;
///  * a mutation that fails and whose re-read *also* fails ([resyncFails]),
///    leaving `latest` null: the list's fate is genuinely unknown.
class _FakeWishlistRepository implements WishlistRepository {
  _FakeWishlistRepository({
    List<int> saved = const [],
    this.loadError,
    this.mutationError,
    this.delay,
    this.wipeOnMutationFailure = true,
    this.resyncFails = false,
    this.ghosts = 0,
  }) : _saved = [...saved];

  List<int> _saved;
  final ApiException? loadError;
  final ApiException? mutationError;
  final Duration? delay;
  final bool wipeOnMutationFailure;
  final bool resyncFails;

  /// Rows the server counts whose catalogue product has been deleted: they
  /// inflate `data.count`, parse to nothing, and survive every call — there is
  /// no id left to send for them.
  final int ghosts;

  WishlistSnapshot? _latest;
  int loads = 0;
  final List<String> calls = [];

  @override
  WishlistSnapshot? get latest => _latest;

  /// Ghost rows counted by the server survive every call, including a clear —
  /// they have no id to send, so nothing can remove them.
  WishlistSnapshot _snap() =>
      _snapshot(_saved, serverCount: _saved.length + ghosts);

  @override
  Future<WishlistSnapshot> refresh() async {
    loads++;
    if (delay != null) await Future<void>.delayed(delay!);
    if (loadError != null) {
      _latest = null;
      throw loadError!;
    }
    return _latest = _snap();
  }

  @override
  Future<WishlistSnapshot> add(int productId) => _mutate('add:$productId', () {
        if (!_saved.contains(productId)) _saved.add(productId);
      });

  @override
  Future<WishlistSnapshot> remove(int productId) =>
      _mutate('remove:$productId', () => _saved.remove(productId));

  Future<WishlistSnapshot> _mutate(String call, VoidCallback apply) async {
    calls.add(call);
    if (delay != null) await Future<void>.delayed(delay!);
    if (mutationError != null) {
      // The real repository re-reads the list on every failure path, because a
      // failed mutation can have emptied it server-side.
      if (wipeOnMutationFailure) _saved = [];
      _latest = resyncFails ? null : _snap();
      throw mutationError!;
    }
    apply();
    return _latest = _snap();
  }

  @override
  Future<WishlistSnapshot> clear() async {
    calls.add('clear');
    if (delay != null) await Future<void>.delayed(delay!);
    if (mutationError != null) {
      _latest = resyncFails ? null : _snap();
      throw mutationError!;
    }
    _saved = [];
    return _latest = _snap();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// A list holding a variable product's parent row **and** one of its
/// variations — verified live: products 111 and 117 sat on one wishlist, and
/// row 117 carries `original_product_id: 111`, so both rows answer to 111.
///
/// Removing the parent therefore leaves the product still on the list.
class _ParentAndVariationRepository implements WishlistRepository {
  _ParentAndVariationRepository({this.parentSaved = true});

  bool parentSaved;
  final List<String> calls = [];
  WishlistSnapshot? _latest;

  @override
  WishlistSnapshot? get latest => _latest;

  WishlistSnapshot _snap() => WishlistSnapshot.fromJson({
        'id': 'list-1',
        'data': {
          'count': parentSaved ? 2 : 1,
          'items': {
            if (parentSaved)
              'row-111': {
                ..._productJson(111),
                'rowId': 'row-111',
                'original_product_id': 111,
                'is_variation': 0,
              },
            // The variation. `slug` really does come back empty for these.
            'row-117': {
              ..._productJson(117, slug: ''),
              'rowId': 'row-117',
              'original_product_id': 111,
              'is_variation': 1,
              'variation_attributes': '(Pack Size: 1.85 KG (Pack of 1))',
            },
          },
        },
      });

  @override
  Future<WishlistSnapshot> refresh() async => _latest = _snap();

  @override
  Future<WishlistSnapshot> remove(int productId) async {
    calls.add('remove:$productId');
    // The server matches on the stored line id, so only the parent row goes.
    if (productId == 111) parentSaved = false;
    return _latest = _snap();
  }

  @override
  Future<WishlistSnapshot> add(int productId) async {
    calls.add('add:$productId');
    if (productId == 111) parentSaved = true;
    return _latest = _snap();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Throws something that is *not* an [ApiException], the way a malformed
/// envelope does: only the transport layer promises that type, and the
/// repository parses the body after the client has returned.
class _CrashingRepository extends _FakeWishlistRepository {
  @override
  Future<WishlistSnapshot> add(int productId) async {
    calls.add('add:$productId');
    throw StateError('type \'Null\' is not a subtype of type \'Map\'');
  }
}

/// Fails the first read and succeeds afterwards, so a retry has something to
/// prove.
class _RecoveringRepository extends _FakeWishlistRepository {
  _RecoveringRepository({this.failure = _boom}) : super(saved: const [118]);

  final ApiException failure;

  @override
  Future<WishlistSnapshot> refresh() {
    if (loads == 0) {
      loads++;
      return Future.error(failure);
    }
    return super.refresh();
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

Future<Widget> _wrap(
  Widget child, {
  required WishlistRepository repo,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      wishlistRepositoryProvider.overrideWithValue(repo),
      // Product tiles ask which products are variable; stubbed empty.
      homeRepositoryProvider.overrideWithValue(FakeHomeRepository()),
    ],
    child: MaterialApp(theme: AppTheme.light, home: child),
  );
}

/// A card at a realistic grid-tile size, so the heart is hit-testable.
Future<void> _pumpCard(
  WidgetTester tester,
  Product product, {
  required WishlistRepository repo,
}) async {
  await tester.pumpWidget(
    await _wrap(
      Scaffold(
        body: Center(
          child: SizedBox(
            width: 160,
            height: 260,
            child: ProductCard(product: product),
          ),
        ),
      ),
      repo: repo,
    ),
  );
  await tester.pump();
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required WishlistRepository repo,
}) async {
  await tester.pumpWidget(
    await _wrap(const WishlistScreen(showBack: false), repo: repo),
  );
  await tester.pump();
}

/// The nth card's heart. Scoped to [ProductCard] on purpose: the screen also
/// draws a heart glyph in its "tap to remove" hint, which is decorative and
/// must never be what a test taps.
Finder _heart([int index = 0]) => find
    .descendant(
      of: find.byType(ProductCard),
      matching: find.byIcon(AppIcons.heart),
    )
    .at(index);

/// Whether the nth heart is filled. The icon's FILL axis is the whole visual
/// difference between saved and not, so it is what gets asserted.
bool _heartFilled(WidgetTester tester, [int index = 0]) =>
    tester.widget<Icon>(_heart(index)).fill == 1;

void main() {
  // -------------------------------------------------------------------------
  // The heart on a product card
  // -------------------------------------------------------------------------

  group('wishlist heart', () {
    testWidgets('is outlined for a product that is not saved', (tester) async {
      final repo = _FakeWishlistRepository();
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();

      expect(_heartFilled(tester), isFalse);
    });

    // The bug this replaces: the heart was local state, so a saved product's
    // card always rendered empty until you tapped it.
    testWidgets('is filled on first build for an already-saved product',
        (tester) async {
      final repo = _FakeWishlistRepository(saved: const [118]);
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();

      expect(_heartFilled(tester), isTrue);
    });

    testWidgets('tapping saves the product and confirms it', (tester) async {
      final repo = _FakeWishlistRepository();
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      expect(repo.calls, ['add:118']);
      expect(_heartFilled(tester), isTrue);
      expect(find.text('Saved to wishlist'), findsOneWidget);
    });

    testWidgets('tapping a saved product removes it', (tester) async {
      final repo = _FakeWishlistRepository(saved: const [118]);
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      // Never DELETE: its miss path 404s and wipes the whole list.
      expect(repo.calls, ['remove:118']);
      expect(_heartFilled(tester), isFalse);
      expect(find.text('Removed from wishlist'), findsOneWidget);
    });

    testWidgets('shows a spinner instead of the icon while in flight',
        (tester) async {
      final repo = _FakeWishlistRepository(
        delay: const Duration(milliseconds: 50),
      );
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(_heart());
      await tester.pump();

      expect(find.byIcon(AppIcons.heart), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpAndSettle();
      expect(_heartFilled(tester), isTrue);
    });

    // The data-loss contract. A failed mutation can leave the list *empty*
    // server-side, so an optimistic heart would claim the product is saved on a
    // list that no longer exists.
    testWidgets('does not stay flipped when the save fails', (tester) async {
      final repo = _FakeWishlistRepository(
        saved: const [119],
        mutationError: _boom,
      );
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      expect(_heartFilled(tester), isFalse);
      expect(find.text('Saved to wishlist'), findsNothing);
      expect(find.text('The server had a problem.'), findsOneWidget);
    });

    testWidgets('adopts the server re-read, not the pre-tap state',
        (tester) async {
      // 118 was saved; the mutation fails and the server wipes the list.
      final repo = _FakeWishlistRepository(
        saved: const [118],
        mutationError: _boom,
      );
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();
      expect(_heartFilled(tester), isTrue);

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      // Not "still saved because the removal failed" - the list is gone.
      expect(_heartFilled(tester), isFalse);
    });

    testWidgets('empties the heart when the list becomes unknown',
        (tester) async {
      final repo = _FakeWishlistRepository(
        saved: const [118],
        mutationError: _boom,
        resyncFails: true,
      );
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();
      expect(_heartFilled(tester), isTrue);

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      expect(_heartFilled(tester), isFalse);
    });

    // The endpoint is a toggle, so two taps racing each other land back where
    // they started.
    testWidgets('ignores a second tap while one is in flight', (tester) async {
      final repo = _FakeWishlistRepository(
        delay: const Duration(milliseconds: 50),
      );
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(_heart());
      await tester.pump();
      // The heart is a spinner now; tap where it sits.
      await tester.tap(find.byType(CircularProgressIndicator));
      await tester.pumpAndSettle();

      expect(repo.calls, ['add:118']);
      expect(_heartFilled(tester), isTrue);
    });

    // The visible disc is 28dp. On the wishlist screen this control is also the
    // delete button, and a near-miss on the untouched part of the tile opens
    // the product page instead - so the target has to be bigger than the paint.
    testWidgets('has a tap target at least 44dp square', (tester) async {
      final repo = _FakeWishlistRepository();
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();

      final size = tester.getSize(
        find.descendant(
          of: find.byType(ProductCard),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.label == 'Save to wishlist',
          ),
        ),
      );

      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    });

    // The whole target has to be live, not just the pixels under the glyph.
    testWidgets('responds to a tap on the padded part of the target',
        (tester) async {
      final repo = _FakeWishlistRepository();
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();

      final rect = tester.getRect(
        find.descendant(
          of: find.byType(ProductCard),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.label == 'Save to wishlist',
          ),
        ),
      );
      // Bottom-left of the target: transparent padding, well clear of the disc.
      await tester.tapAt(Offset(rect.left + 4, rect.bottom - 4));
      await tester.pumpAndSettle();

      expect(repo.calls, ['add:118']);
    });

    // The out-of-stock wash is painted over the image and is opaque to hit
    // tests. Stacked above the heart it ate the tap, which then fell through to
    // the card and opened the product page - and "save it for when it is back"
    // is the case a wishlist exists for.
    testWidgets('still saves a sold-out product', (tester) async {
      final repo = _FakeWishlistRepository();
      await _pumpCard(tester, _product(118, soldOut: true), repo: repo);
      await tester.pumpAndSettle();

      expect(find.text('Out of stock'), findsOneWidget);

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      expect(repo.calls, ['add:118']);
      expect(_heartFilled(tester), isTrue);
    });

    // A spinner that still announces itself as "Save to wishlist" offers a
    // screen-reader user an action that does nothing.
    testWidgets('announces itself as disabled while in flight', (tester) async {
      final semantics = tester.ensureSemantics();
      final repo = _FakeWishlistRepository(
        delay: const Duration(milliseconds: 50),
      );
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(_heart());
      await tester.pump();

      expect(find.bySemanticsLabel('Updating wishlist'), findsOneWidget);
      expect(find.bySemanticsLabel('Save to wishlist'), findsNothing);

      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Remove from wishlist'), findsOneWidget);
      semantics.dispose();
    });

    // A saved *variation* has to light up its parent's card, or the catalogue
    // shows an outlined heart for a product the customer has already saved.
    testWidgets('is filled for a product whose variation is saved',
        (tester) async {
      final repo = _ParentAndVariationRepository(parentSaved: false);
      await _pumpCard(tester, _product(111), repo: repo);
      await tester.pumpAndSettle();

      expect(_heartFilled(tester), isTrue);
    });

    // The reversal: a list can hold the parent row *and* a variation, and both
    // answer to 111. Removing the parent leaves the variation, so the product
    // is still saved - the heart is right to stay filled, but announcing
    // "Saved to wishlist" for a tap that just deleted a row is a lie, and
    // "Removed from wishlist" would be one too.
    testWidgets('does not claim a save when a removal left the variation',
        (tester) async {
      final repo = _ParentAndVariationRepository();
      await _pumpCard(tester, _product(111), repo: repo);
      await tester.pumpAndSettle();
      expect(_heartFilled(tester), isTrue);

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      expect(repo.calls, ['remove:111']);
      expect(_heartFilled(tester), isTrue);
      expect(find.text('Saved to wishlist'), findsNothing);
      expect(find.text('Removed from wishlist'), findsNothing);
      expect(find.text('Still on your wishlist'), findsOneWidget);
    });

    // Only the transport promises ApiException; the envelope is parsed after
    // the client returns. An `on ApiException` catch let a TypeError past, and
    // `pending` never cleared - the heart span forever and refused every tap
    // for the rest of the session.
    testWidgets('recovers from a failure that is not an ApiException',
        (tester) async {
      final repo = _CrashingRepository();
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      expect(repo.calls, ['add:118']);
      // Spinner gone, heart back, and the failure reported rather than silent.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(AppIcons.heart), findsOneWidget);
      expect(_heartFilled(tester), isFalse);
      expect(find.text('Something went wrong'), findsOneWidget);
      // The raw toString() is developer output and must never reach the user.
      expect(find.textContaining('is not a subtype'), findsNothing);

      // ...and the control still works afterwards.
      await tester.tap(_heart());
      await tester.pumpAndSettle();
      expect(repo.calls, ['add:118', 'add:118']);
    });

    // No login gate: the wishlist API is identified by an opaque id and ignores
    // the bearer token entirely, so a signed-out visitor keeps a real list.
    testWidgets('works with no auth token present', (tester) async {
      final repo = _FakeWishlistRepository();
      await _pumpCard(tester, _product(118), repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      expect(find.text('Sign in'), findsNothing);
      expect(repo.calls, ['add:118']);
    });
  });

  // -------------------------------------------------------------------------
  // The screen
  // -------------------------------------------------------------------------

  // The product page's app-bar heart. Same provider, same toggle and same
  // wording as the tile's overlay heart — they share `wishlist_button.dart`
  // precisely so the two cannot drift apart.
  group('wishlist app-bar button', () {
    Future<void> pumpButton(
      WidgetTester tester, {
      required WishlistRepository repo,
    }) async {
      await tester.pumpWidget(
        await _wrap(
          const Scaffold(
            body: Center(child: WishlistIconButton(productId: 118)),
          ),
          repo: repo,
        ),
      );
      await tester.pump();
    }

    // Scoped to the button: the confirmation snack draws its own icon.
    bool filled(WidgetTester tester) => tester
            .widget<Icon>(
              find.descendant(
                of: find.byKey(const Key('wishlist-action')),
                matching: find.byType(Icon),
              ),
            )
            .fill ==
        1;

    testWidgets('is filled on first build for an already-saved product',
        (tester) async {
      await pumpButton(tester, repo: _FakeWishlistRepository(saved: const [118]));
      await tester.pumpAndSettle();

      expect(filled(tester), isTrue);
    });

    testWidgets('saves the product and says what the server did',
        (tester) async {
      final repo = _FakeWishlistRepository();
      await pumpButton(tester, repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('wishlist-action')));
      await tester.pumpAndSettle();

      expect(filled(tester), isTrue);
      expect(find.text('Saved to wishlist'), findsOneWidget);
    });

    testWidgets('takes no second tap while a mutation is in flight',
        (tester) async {
      final repo = _FakeWishlistRepository(
        delay: const Duration(milliseconds: 300),
      );
      await pumpButton(tester, repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('wishlist-action')));
      await tester.pump();

      // Disabled, not merely ignoring the tap — a queued second mutation would
      // race the first on a list the server rewrites wholesale.
      expect(
        tester.widget<IconButton>(find.byKey(const Key('wishlist-action')))
            .onPressed,
        isNull,
      );
      await tester.pumpAndSettle();
    });
  });

  group('wishlist screen', () {
    testWidgets('shows grid skeletons while the list is in flight',
        (tester) async {
      final repo = _FakeWishlistRepository(
        saved: const [118],
        delay: const Duration(milliseconds: 50),
      );
      await _pumpScreen(tester, repo: repo);

      expect(find.byType(ProductGridSkeleton), findsOneWidget);
      expect(find.byType(ProductCard), findsNothing);

      await tester.pumpAndSettle();
      expect(find.byType(ProductGridSkeleton), findsNothing);
    });

    testWidgets('shows the saved products', (tester) async {
      final repo = _FakeWishlistRepository(saved: const [118, 119]);
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      expect(find.byType(ProductCard), findsNWidgets(2));
      expect(find.text('Product 118'), findsOneWidget);
      expect(find.text('Product 119'), findsOneWidget);
      expect(find.text('2 items saved'), findsOneWidget);
      expect(find.byType(EmptyView), findsNothing);
    });

    testWidgets('shows an empty state with a way out', (tester) async {
      final repo = _FakeWishlistRepository();
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      expect(find.byType(EmptyView), findsOneWidget);
      expect(find.text('Nothing saved yet'), findsOneWidget);
      expect(find.text('Browse products'), findsOneWidget);
      expect(find.byType(ProductCard), findsNothing);
    });

    testWidgets('shows the error with a retry that re-reads the list',
        (tester) async {
      final repo = _FakeWishlistRepository(loadError: _boom);
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.text('The server had a problem.'), findsOneWidget);
      expect(repo.loads, 1);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      // Still failing, so still the error view - but the retry is real.
      expect(repo.loads, 2);
      expect(find.byType(AppErrorView), findsOneWidget);
    });

    testWidgets('retry renders the list once the server recovers',
        (tester) async {
      final repo = _RecoveringRepository();
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      expect(find.byType(AppErrorView), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.byType(AppErrorView), findsNothing);
      expect(find.byType(ProductCard), findsOneWidget);
      expect(find.text('1 item saved'), findsOneWidget);
    });

    testWidgets('removing the last item leaves the empty state',
        (tester) async {
      final repo = _FakeWishlistRepository(saved: const [118]);
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      expect(find.byType(ProductCard), findsOneWidget);

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      expect(repo.calls, ['remove:118']);
      expect(find.byType(ProductCard), findsNothing);
      expect(find.byType(EmptyView), findsOneWidget);
    });

    testWidgets('clearing asks first, then empties the list', (tester) async {
      final repo = _FakeWishlistRepository(saved: const [118, 119]);
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(AppIcons.trash));
      await tester.pumpAndSettle();
      expect(find.text('Clear wishlist?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.calls, isEmpty);
      expect(find.byType(ProductCard), findsNWidgets(2));

      await tester.tap(find.byIcon(AppIcons.trash));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(repo.calls, ['clear']);
      expect(find.byType(EmptyView), findsOneWidget);
    });

    // Clearing is one request per product - there is no bulk route - and every
    // one of them deletes the stored row before re-storing it. Leaving the grid
    // live and silent through that invites a heart tap that interleaves with
    // the loop.
    testWidgets('blocks the grid and says so while clearing', (tester) async {
      final repo = _FakeWishlistRepository(
        saved: const [118, 119],
        delay: const Duration(milliseconds: 50),
      );
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(AppIcons.trash));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pump();

      expect(find.text('Clearing your wishlist…'), findsOneWidget);

      // A heart tapped mid-clear must not reach the notifier.
      await tester.tap(_heart(), warnIfMissed: false);
      await tester.pump();
      expect(repo.calls, ['clear']);

      await tester.pumpAndSettle();
      expect(find.text('Clearing your wishlist…'), findsNothing);
      expect(find.byType(EmptyView), findsOneWidget);
      expect(find.text('Wishlist cleared'), findsOneWidget);
    });

    // Ghost rows have no id to send, so nothing can remove them. Reporting a
    // flat "Wishlist cleared" would contradict the count still on screen.
    testWidgets('does not claim a clear removed the rows it cannot touch',
        (tester) async {
      final repo = _FakeWishlistRepository(saved: const [118], ghosts: 2);
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(AppIcons.trash));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(find.text('Wishlist cleared'), findsNothing);
      expect(
        find.text('Cleared. 2 unavailable items could not be removed.'),
        findsOneWidget,
      );
      expect(find.textContaining('no longer sold'), findsOneWidget);
    });

    // Rows the server counts but whose catalogue product is gone: they parse to
    // nothing and cannot be removed, so the screen admits they are there.
    testWidgets('admits rows it cannot render', (tester) async {
      final repo = _FakeWishlistRepository(saved: const [118], ghosts: 2);
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      expect(find.byType(ProductCard), findsOneWidget);
      expect(find.textContaining('no longer sold'), findsOneWidget);
    });

    // A mutation failed but the re-read worked: the list is still known, so the
    // grid keeps rendering and the failure is reported rather than swallowed.
    testWidgets('keeps the grid and reports a failed mutation', (tester) async {
      final repo = _FakeWishlistRepository(
        saved: const [118, 119],
        mutationError: _boom,
        wipeOnMutationFailure: false,
      );
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      expect(find.byType(InlineErrorStrip), findsOneWidget);
      expect(find.byType(ProductCard), findsNWidgets(2));
    });

    // The wipe case, on the screen: the customer sees the list actually empty
    // rather than two tiles that no longer exist server-side.
    testWidgets('adopts a wiped list after a failed removal', (tester) async {
      final repo = _FakeWishlistRepository(
        saved: const [118, 119],
        mutationError: _boom,
      );
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      expect(find.byType(ProductCard), findsNothing);
      expect(find.byType(EmptyView), findsOneWidget);
    });

    // ...and it must not read as "you never saved anything". Their two items
    // were destroyed by a call that failed a second ago; the failure is stated
    // above and the headline must not contradict it.
    testWidgets('does not call a wiped list "nothing saved yet"',
        (tester) async {
      final repo = _FakeWishlistRepository(
        saved: const [118, 119],
        mutationError: _boom,
      );
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      expect(find.text('Nothing saved yet'), findsNothing);
      expect(find.text('Your wishlist is empty'), findsOneWidget);
      expect(find.byType(InlineErrorStrip), findsOneWidget);
    });

    // Every row is a ghost: the grid is empty but the *list* is not. The note
    // and the headline used to be rendered together and flatly contradicted
    // each other - "2 saved items are no longer sold" over "Nothing saved yet".
    testWidgets('does not call an all-unavailable list "nothing saved yet"',
        (tester) async {
      final repo = _FakeWishlistRepository(ghosts: 2);
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      expect(find.byType(EmptyView), findsOneWidget);
      expect(find.text('Nothing saved yet'), findsNothing);
      expect(find.text('Nothing left to show'), findsOneWidget);
      // Stated once, not twice and not in two different voices.
      expect(find.textContaining('no longer sold'), findsOneWidget);
    });

    // A genuinely untouched list keeps the inviting copy.
    testWidgets('keeps the first-run copy when nothing has failed',
        (tester) async {
      final repo = _FakeWishlistRepository();
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      expect(find.text('Nothing saved yet'), findsOneWidget);
      expect(find.byType(InlineErrorStrip), findsNothing);
    });

    // AppErrorView only offers a retry for errors it judges retryable, so a 404
    // would otherwise strand the customer on a dead screen.
    testWidgets('offers a refresh even when the error carries no retry',
        (tester) async {
      final repo = _RecoveringRepository(failure: _notFound);
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.text('Try again'), findsNothing);

      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pumpAndSettle();

      expect(repo.loads, 2);
      expect(find.byType(AppErrorView), findsNothing);
      expect(find.byType(ProductCard), findsOneWidget);
    });

    testWidgets('falls back to the error view when the list becomes unknown',
        (tester) async {
      final repo = _FakeWishlistRepository(
        saved: const [118],
        mutationError: _boom,
        resyncFails: true,
      );
      await _pumpScreen(tester, repo: repo);
      await tester.pumpAndSettle();

      await tester.tap(_heart());
      await tester.pumpAndSettle();

      // Not an empty state: "we do not know" is not "you saved nothing".
      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.byType(EmptyView), findsNothing);
      expect(find.byType(ProductCard), findsNothing);
    });
  });
}

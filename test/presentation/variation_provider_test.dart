import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/data/models/product_model.dart';
import 'package:trueway_farms/data/models/product_variation.dart';
import 'package:trueway_farms/data/repositories/catalog_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/providers/variation_provider.dart';

import '../data/product_variation_test.dart' show detailEnvelope, resolvedVariation;

/// Picking a pack, and what the app is allowed to conclude from it.
///
/// The app never works out which variation a selection means — that mapping
/// lives in `getProductVariation`, which also knows which combinations exist.
/// So every test here is about faithfully asking and faithfully rendering the
/// answer, including when the answer is "no".

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const _slug = 'sona-moti-wheat';

Product _parent() => Product.fromJson({
      'id': 120,
      'slug': _slug,
      'name': 'Trueway Farms Organic Sona Moti Wheat',
      'sku': 'TRW3214',
      'price': 921.501,
      'original_price': 1296.75,
      'quantity': 1891,
      'is_out_of_stock': false,
    });

Product _simpleProduct() => Product.fromJson({
      'id': 118,
      'slug': 'desi-khand',
      'name': 'Desi Khand',
      'sku': 'TRW3215',
      'price': 943.95,
      'quantity': 50,
      'is_out_of_stock': false,
    });

/// The three variations behind product 120, keyed by attribute id.
///
/// Ids captured live: attribute 21 → variation 122, 22 → 121, 23 → 124.
ProductVariation _variationFor(int attributeId) {
  const ids = {21: 122, 22: 121, 23: 124};
  final prices = {21: 493.5, 22: 921.501, 23: 921.501};
  return ProductVariation.fromJson({
    ...resolvedVariation(salePrice: prices[attributeId]!),
    'id': ids[attributeId],
    'selected_attributes': [
      {'id': attributeId, 'set_slug': 'pack-size', 'set_id': 6},
    ],
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _FakeCatalog implements CatalogRepository {
  _FakeCatalog({this.product, this.variable = true});

  final Product? product;
  final bool variable;

  final List<List<int>> resolves = [];

  /// Blocks each resolve until completed, for ordering tests.
  Completer<void>? gate;

  /// Thrown by the next resolve.
  Object? error;

  /// When true the next resolve answers "no such combination".
  bool unresolvable = false;

  @override
  Future<ProductDetail?> productDetail(String slug) async {
    final p = product ?? _parent();
    return ProductDetail(
      product: p,
      variations: variable
          ? ProductVariationOptions.fromEnvelope(detailEnvelope())
          : ProductVariationOptions.none,
    );
  }

  @override
  Future<ProductVariation?> resolveVariation({
    required int parentId,
    required List<int> attributeIds,
  }) async {
    resolves.add(attributeIds);
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    if (unresolvable) return null;
    return _variationFor(attributeIds.last);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

typedef _Host = ({ProviderContainer container, _FakeCatalog catalog});

Future<_Host> _host({_FakeCatalog? catalog}) async {
  final fake = catalog ?? _FakeCatalog();
  final container = ProviderContainer(
    overrides: [catalogRepositoryProvider.overrideWithValue(fake)],
  );
  addTearDown(container.dispose);

  // The notifier seeds itself from the detail provider; hold a subscription so
  // the autoDispose family stays alive, then let the fetch land.
  container.listen(variationProvider(_slug), (_, __) {}, fireImmediately: true);
  await _settle(container);
  return (container: container, catalog: fake);
}

Future<void> _settle(ProviderContainer container) async {
  for (var i = 0; i < 50; i++) {
    if (container.read(variationProvider(_slug)).isVariable) return;
    await Future<void>.delayed(Duration.zero);
  }
}

VariationState _state(_Host h) => h.container.read(variationProvider(_slug));

Future<void> _select(_Host h, int setId, int attributeId) =>
    h.container.read(variationProvider(_slug).notifier).select(setId, attributeId);

void main() {
  // -------------------------------------------------------------------------
  group('seeding', () {
    // The default variation rides on the product-detail response, so opening a
    // product costs no extra request and still has a price and a cart id.
    test('adopts the server selection without resolving anything', () async {
      final h = await _host();

      expect(_state(h).isVariable, isTrue);
      expect(_state(h).selection, {6: 22});
      expect(_state(h).variation?.id, 121);
      expect(h.catalog.resolves, isEmpty, reason: 'no request on open');
    });

    test('a simple product has no picker and no selection', () async {
      final h = await _host(
        catalog: _FakeCatalog(product: _simpleProduct(), variable: false),
      );

      expect(_state(h).isVariable, isFalse);
      expect(_state(h).selection, isEmpty);
      expect(_state(h).variation, isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('selecting', () {
    test('asks the server and adopts the variation it names', () async {
      final h = await _host();

      await _select(h, 6, 21);

      expect(h.catalog.resolves, [
        [21],
      ]);
      expect(_state(h).selection, {6: 21});
      // The 1.85 kg pack — a different id *and* a different price.
      expect(_state(h).variation?.id, 122);
      expect(_state(h).variation?.price, 493.5);
    });

    test('re-picking the current option costs no request', () async {
      final h = await _host();

      await _select(h, 6, 22);

      expect(h.catalog.resolves, isEmpty);
    });

    // The id ADD posts. Posting the parent (120) would get the default
    // variation back and silently discard the customer's pick.
    test('the cart id follows the selection, not the parent', () async {
      final h = await _host();
      expect(_state(h).cartProductId, 121);

      await _select(h, 6, 21);

      expect(_state(h).cartProductId, 122);
      expect(_state(h).cartProductId, isNot(120));
    });
  });

  // -------------------------------------------------------------------------
  group('while resolving', () {
    // ADD must wait: the id it would post is about to change, and posting the
    // old one puts the previous pack in the basket under the new pack's name.
    test('there is no cart id to add', () async {
      final h = await _host();
      h.catalog.gate = Completer<void>();

      final pending = _select(h, 6, 21);
      expect(_state(h).resolving, isTrue);
      expect(_state(h).cartProductId, isNull);

      h.catalog.gate!.complete();
      await pending;

      expect(_state(h).resolving, isFalse);
      expect(_state(h).cartProductId, 122);
    });

    // Tapping 21 then 23 with a slow first request must not land 21 last.
    test('a stale answer cannot overwrite a newer one', () async {
      final h = await _host();

      final firstGate = Completer<void>();
      h.catalog.gate = firstGate;
      final first = _select(h, 6, 21);

      // The second pick supersedes the first before either has answered.
      h.catalog.gate = null;
      final second = _select(h, 6, 23);
      await second;

      firstGate.complete();
      await first;

      expect(_state(h).selection, {6: 23});
      expect(_state(h).variation?.id, 124, reason: 'the newer pick wins');
      expect(_state(h).variation?.id, isNot(122));
    });
  });

  // -------------------------------------------------------------------------
  group('a selection the server will not resolve', () {
    // Everything on screen — price, stock, images, the id ADD posts — belongs
    // to the *current* variation. A failed pick left highlighted would show one
    // pack selected at another pack's price.
    test('rolls back rather than showing a mismatched price', () async {
      final h = await _host();
      h.catalog.unresolvable = true;

      await _select(h, 6, 21);

      expect(_state(h).selection, {6: 22}, reason: 'rolled back');
      expect(_state(h).variation?.id, 121);
      expect(_state(h).cartProductId, 121);
      expect(_state(h).error, isNotNull);
    });

    test('a failed request rolls back too, and keeps the server wording',
        () async {
      final h = await _host();
      h.catalog.error = const ApiException('Shiprocket unreachable');

      await _select(h, 6, 21);

      expect(_state(h).selection, {6: 22});
      expect(_state(h).error?.message, 'Shiprocket unreachable');
      expect(_state(h).resolving, isFalse);
    });

    test('and the next successful pick clears the error', () async {
      final h = await _host();
      h.catalog.unresolvable = true;
      await _select(h, 6, 21);
      expect(_state(h).error, isNotNull);

      h.catalog.unresolvable = false;
      await _select(h, 6, 23);

      expect(_state(h).error, isNull);
      expect(_state(h).variation?.id, 124);
    });
  });

  // -------------------------------------------------------------------------
  group('cartProductIdFor', () {
    test('is the product id for a simple product', () async {
      final h = await _host(
        catalog: _FakeCatalog(product: _simpleProduct(), variable: false),
      );

      expect(cartProductIdFor(_simpleProduct(), _state(h)), 118);
    });

    test('is the variation id for a variable one', () async {
      final h = await _host();
      await _select(h, 6, 21);

      expect(cartProductIdFor(_parent(), _state(h)), 122);
    });

    test('is null mid-resolve, so ADD is disabled', () async {
      final h = await _host();
      h.catalog.gate = Completer<void>();
      final pending = _select(h, 6, 21);

      expect(cartProductIdFor(_parent(), _state(h)), isNull);

      h.catalog.gate!.complete();
      await pending;
    });
  });

  // -------------------------------------------------------------------------
  group('unavailable options', () {
    // The server publishes which combinations do not exist, so the customer is
    // stopped before the request rather than after it.
    test('come from the resolved variation once one exists', () async {
      final h = await _host();
      expect(_state(h).isUnavailable(23), isFalse);

      h.catalog.gate = null;
      await _select(h, 6, 21);

      // The fixture resolves with an empty list, so nothing is blocked — what
      // matters is that the *variation's* list is the one consulted.
      expect(_state(h).unavailableAttributeIds,
          _state(h).variation!.unavailableAttributeIds,);
    });
  });

  // -------------------------------------------------------------------------
  group('selectionLabel', () {
    // Matches the `variation_attributes` string the cart line comes back with,
    // so the two screens name the same pack the same way.
    test('names the chosen options', () async {
      final h = await _host();
      expect(_state(h).selectionLabel, '5 KG (Pack of 1)');

      await _select(h, 6, 21);
      expect(_state(h).selectionLabel, '1.85 KG (Pack of 1)');
    });
  });
}

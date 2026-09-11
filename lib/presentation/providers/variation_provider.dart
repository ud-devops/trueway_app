import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/errors/error_presenter.dart';
import '../../data/models/product_model.dart';
import '../../data/models/product_variation.dart';
import 'core_providers.dart';
import 'products_provider.dart';

/// What the customer has picked, and what the server says that resolves to.
///
/// The app never works out which variation a selection means — that mapping
/// lives in the backend's `getProductVariation`, which also knows which
/// combinations exist. Picking an attribute therefore asks the server and
/// renders the answer.
class VariationState {
  const VariationState({
    this.options = ProductVariationOptions.none,
    this.selection = const {},
    this.variation,
    this.resolving = false,
    this.error,
  });

  final ProductVariationOptions options;

  /// attribute-set id → chosen attribute id.
  final Map<int, int> selection;

  /// The variation the current [selection] resolves to.
  ///
  /// Seeded from `default_product_variation` so the screen has a price and an
  /// id before the customer touches anything — which is also why opening a
  /// product costs no extra request.
  final ProductVariation? variation;

  /// A resolve is in flight. The picker stays interactive, but ADD waits: the
  /// id it would post is about to change.
  final bool resolving;

  final ApiException? error;

  bool get isVariable => options.isVariable;

  /// Options the server says cannot be picked with the current selection.
  ///
  /// The resolved variation's list is fresher than the envelope's, so it wins
  /// once one exists.
  List<int> get unavailableAttributeIds =>
      variation?.unavailableAttributeIds.isNotEmpty ?? false
          ? variation!.unavailableAttributeIds
          : options.unavailableAttributeIds;

  bool isUnavailable(int attributeId) =>
      unavailableAttributeIds.contains(attributeId);

  /// The id to put in the cart.
  ///
  /// Null while a resolve is in flight or after one failed — adding then would
  /// post an id that no longer matches what is on screen. For a simple product
  /// this is null too, and the caller uses the product's own id.
  int? get cartProductId => resolving ? null : variation?.id;

  /// The chosen attribute in one set.
  int? selectedInSet(int setId) => selection[setId];

  /// A label for the whole selection: "1.85 KG (Pack of 1)".
  ///
  /// Matches the `variation_attributes` string the cart line comes back with,
  /// so the two screens name the same thing the same way.
  String? get selectionLabel {
    final titles = <String>[];
    for (final set in options.attributeSets) {
      final id = selection[set.id];
      if (id == null) continue;
      final attribute = options.attributeById(id);
      if (attribute != null) titles.add(attribute.title);
    }
    return titles.isEmpty ? null : titles.join(', ');
  }

  VariationState copyWith({
    ProductVariationOptions? options,
    Map<int, int>? selection,
    ProductVariation? variation,
    bool? resolving,
    ApiException? error,
    bool clearError = false,
  }) =>
      VariationState(
        options: options ?? this.options,
        selection: selection ?? this.selection,
        variation: variation ?? this.variation,
        resolving: resolving ?? this.resolving,
        error: clearError ? null : (error ?? this.error),
      );
}

class VariationNotifier extends StateNotifier<VariationState> {
  VariationNotifier(this._ref, this._slug) : super(const VariationState()) {
    _seedFromDetail();
  }

  final Ref _ref;
  final String _slug;

  /// Bumped on every selection change so a slow resolve cannot overwrite a
  /// newer one. Without this, tapping A then B lands B then A whenever the
  /// first request is slower, and the screen shows B selected at A's price.
  int _generation = 0;

  void _seedFromDetail() {
    _ref.listen<AsyncValue<ProductDetail?>>(
      productDetailProvider(_slug),
      (_, next) => _adopt(next),
      fireImmediately: true,
    );
  }

  void _adopt(AsyncValue<ProductDetail?> async) {
    final detail = async.valueOrNull;
    if (detail == null || !mounted) return;

    // Opening a product teaches every grid tile that shows it, so the "N
    // options" label appears without a second request.
    _ref.read(knownVariantsProvider.notifier)
        .remember(detail.product.slug, detail.variations);

    // Already seeded — a rebuild of the same detail must not discard what the
    // customer has picked since.
    if (state.options.isVariable) return;

    final options = detail.variations;
    if (!options.isVariable) return;

    state = state.copyWith(
      options: options,
      selection: options.defaultSelection,
      // `default_product_variation` carries the right id and price, so the
      // screen is complete before any resolve. Its images and weight are null,
      // which is why the screen falls back to the parent's for those.
      variation: options.defaultVariation,
    );
  }

  /// Picks [attributeId] within [setId] and asks the server what it resolves to.
  ///
  /// A selection that the server will not resolve is **rolled back**. The price,
  /// stock, images and cart id on screen all belong to the current variation, so
  /// leaving a failed pick highlighted would show one pack selected at another
  /// pack's price — and ADD would post the other pack's id.
  Future<void> select(int setId, int attributeId) async {
    if (state.selection[setId] == attributeId) return;

    final previous = state.selection;
    final selection = Map<int, int>.from(previous)..[setId] = attributeId;
    state = state.copyWith(
      selection: selection,
      resolving: true,
      clearError: true,
    );

    final generation = ++_generation;
    final parentId =
        _ref.read(productDetailProvider(_slug)).valueOrNull?.product.id;
    if (parentId == null) {
      state = state.copyWith(selection: previous, resolving: false);
      return;
    }

    try {
      final resolved =
          await _ref.read(catalogRepositoryProvider).resolveVariation(
                parentId: parentId,
                attributeIds: selection.values.toList(),
              );
      // A slower earlier request must not land on top of a newer one, or the
      // screen ends up showing the pack the customer tapped *first*.
      if (!mounted || generation != _generation) return;

      if (resolved == null) {
        state = state.copyWith(
          selection: previous,
          resolving: false,
          error: ApiException.local(
            'That combination is not available. Please pick another.',
            developerDetail: 'resolveVariation(parent: $parentId, attributes: '
                '${selection.values.toList()}) returned no variation',
          ),
        );
        return;
      }

      state = state.copyWith(
        variation: resolved,
        resolving: false,
        clearError: true,
      );
    } catch (e, s) {
      ErrorLog.capture(e, stackTrace: s, context: 'variation.resolve');
      if (!mounted || generation != _generation) return;
      state = state.copyWith(
        selection: previous,
        resolving: false,
        error: ErrorPresenter.resolve(e),
      );
    }
  }
}

/// Variation selection for one product, keyed by slug.
final variationProvider = StateNotifierProvider.autoDispose
    .family<VariationNotifier, VariationState, String>(
  (ref, slug) => VariationNotifier(ref, slug),
);

/// Which products are variable, learned as details are fetched.
///
/// ## Why this cache has to exist
///
/// The catalogue **list** payload cannot say whether a product has variants.
/// Verified against `AvailableProductResource` itself: it emits
/// `product_options` (a different feature — add-on options — empty on every
/// live product) and exposes `variation_attributes` only for rows that *are*
/// variations. A parent product in a listing looks byte-identical to a simple
/// one; products 118 and 120 differ in nothing but price and dimensions.
///
/// So a grid tile has no way to know it should offer a choice. Without that,
/// tapping ADD posts the parent id, the server quietly resolves it to the
/// **default** variation, and a customer who wanted the ₹493.50 pack gets the
/// ₹921.50 one with no indication a choice existed.
///
/// This learns the answer from `GET /products/{slug}`, which does carry it, and
/// remembers it for the session: the first ADD on an unknown product costs one
/// request, and every tile for that product shows its options count from then
/// on.
///
/// **One backend field removes all of this.** An `is_variable` boolean — or a
/// `variations_count` int — on `AvailableProductResource` would let the label
/// render on first paint and drop the pre-add request entirely. See followUps.
class KnownVariantsNotifier
    extends StateNotifier<Map<String, ProductVariationOptions>> {
  KnownVariantsNotifier(this._ref) : super(const {});

  final Ref _ref;

  /// In-flight lookups, so several tiles tapping at once make one request.
  final Map<String, Future<ProductVariationOptions?>> _pending = {};

  /// What is already known, without asking.
  ProductVariationOptions? cached(String slug) => state[slug];

  /// The variation block for [slug], fetching once if it is not yet known.
  ///
  /// Returns null when the lookup failed — the caller should then treat the
  /// product as simple and let the server rule on the add, rather than blocking
  /// the customer on a request that is only an optimisation.
  Future<ProductVariationOptions?> ensure(String slug) {
    final known = state[slug];
    if (known != null) return Future.value(known);
    if (slug.isEmpty) return Future.value(null);

    return _pending.putIfAbsent(slug, () async {
      try {
        final detail =
            await _ref.read(catalogRepositoryProvider).productDetail(slug);
        if (detail == null) return null;
        if (mounted) {
          state = {...state, slug: detail.variations};
        }
        return detail.variations;
      } catch (e, s) {
        ErrorLog.capture(e, stackTrace: s, context: 'variants.ensure');
        return null;
      } finally {
        _pending.remove(slug);
      }
    });
  }

  /// Records what a detail fetch already established, so opening a product page
  /// teaches every tile that shows it.
  void remember(String slug, ProductVariationOptions options) {
    if (slug.isEmpty || state[slug] != null) return;
    state = {...state, slug: options};
  }
}

final knownVariantsProvider = StateNotifierProvider<KnownVariantsNotifier,
    Map<String, ProductVariationOptions>>(KnownVariantsNotifier.new);

/// Every product the catalogue considers variable, in two requests.
///
/// A listing row cannot say whether a product has packs to choose from. But the
/// **filter** can: only variable products carry attributes, so asking for
/// products matching *every* attribute value in the catalogue returns exactly
/// the variable ones. Verified live — `?attributes[]=21&attributes[]=22&
/// attributes[]=23` returns `[111, 120]`, which are precisely the two variable
/// products in this store.
///
/// That is two requests for the whole catalogue, once per session, instead of
/// one per product — and it means a tile knows on first paint, so the "N
/// options" hint no longer waits for the customer to tap something.
///
/// Failure is not fatal: an empty set means every tile behaves as it did
/// before, adding through the server, which still rules on the result.
final variableProductIdsProvider = FutureProvider<Set<int>>((ref) async {
  try {
    final filters = await ref.watch(homeRepositoryProvider).filters();
    final attributeIds = [
      for (final set in filters.attributeSets)
        for (final value in set.values) value.id,
    ];
    if (attributeIds.isEmpty) return const {};

    final ids = <int>{};
    // Paged, because a catalogue can hold more variable products than one page
    // — but bounded, because this is a hint and not worth an unbounded crawl.
    for (var page = 1; page <= _maxVariableScanPages; page++) {
      final result = await ref.watch(catalogRepositoryProvider).products(
            page: page,
            perPage: 100,
            attributeIds: attributeIds,
          );
      ids.addAll(result.items.map((p) => p.id));
      if (result.items.length < 100) break;
    }
    return ids;
  } catch (e, s) {
    ErrorLog.capture(e, stackTrace: s, context: 'variants.scan');
    return const {};
  }
});

const int _maxVariableScanPages = 5;

/// Identifies a product for [variantCountProvider].
typedef ProductKey = ({int id, String slug});

/// The options count to print under a tile's ADD button, or null.
///
/// Two steps, and the order matters. [variableProductIdsProvider] settles
/// *which* products are variable for the whole catalogue at once; only those
/// then cost a detail request to learn how many packs they have. A simple
/// product — the majority — never triggers one.
///
/// Null for a simple product, and for a variable one with a single option,
/// where "1 options" would be noise.
final variantCountProvider =
    FutureProvider.autoDispose.family<int?, ProductKey>((ref, key) async {
  final variable = await ref.watch(variableProductIdsProvider.future);
  if (!variable.contains(key.id)) return null;

  final options =
      await ref.read(knownVariantsProvider.notifier).ensure(key.slug);
  if (options == null || !options.isVariable) return null;

  final count = options.attributeSets.fold<int>(
    0,
    (sum, set) => sum + set.attributes.length,
  );
  return count > 1 ? count : null;
});

/// What ADD should post for [product], given the current selection.
///
/// For a simple product that is the product's own id. For a variable one it is
/// the **variation's** id — posting the parent gets the default variation and
/// silently discards the customer's pick.
int? cartProductIdFor(Product product, VariationState variation) =>
    variation.isVariable ? variation.cartProductId : product.id;

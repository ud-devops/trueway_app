import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/app_typography.dart';
import '../../core/design_system/theme_context.dart';
import '../../core/utils/price_utils.dart';
import '../../data/models/product_model.dart';
import '../../data/models/product_variation.dart';
import '../../data/models/server_cart.dart';
import '../providers/core_providers.dart';
import '../providers/server_cart_provider.dart';
import 'app_network_image.dart';
import 'quantity_stepper.dart';
import 'app_message.dart';

/// The pack picker that opens from a grid tile's ADD button.
///
/// One row per option, each with its own price and its own ADD — the customer
/// chooses a pack instead of getting whichever one the server considers
/// default. That default is what a bare `POST {product_id: parent}` resolves
/// to, so without this sheet a tap on a ₹493.50 product's tile silently buys
/// the ₹921.50 pack.
///
/// Prices, MRPs and pack sizes come straight from `attribute_sets[].attributes`
/// on the product-detail payload, so the sheet opens with no further request.
/// Only committing to a row needs one: the **variation id** is not in that
/// payload, and is resolved from `/product-variation/{parent}?attributes[]=…`
/// at the moment the customer taps ADD.
Future<void> showVariantSheet(
  BuildContext context, {
  required Product product,
  required ProductVariationOptions options,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _VariantSheet(product: product, options: options),
  );
}

/// Whether [options] can be rendered as a flat list of packs.
///
/// A single attribute set means one axis of choice, so one row per option is
/// the whole truth. With two or more sets a *variation* is a combination, and a
/// flat list would misrepresent it — those products open the detail screen,
/// where the full picker resolves one set against another.
bool canShowVariantSheet(ProductVariationOptions options) =>
    options.attributeSets.length == 1 &&
    options.attributeSets.single.attributes.length > 1;

class _VariantSheet extends ConsumerStatefulWidget {
  const _VariantSheet({required this.product, required this.options});

  final Product product;
  final ProductVariationOptions options;

  @override
  ConsumerState<_VariantSheet> createState() => _VariantSheetState();
}

class _VariantSheetState extends ConsumerState<_VariantSheet> {
  /// Attribute id currently being resolved-and-added.
  int? _adding;

  /// Attribute id → the variation the server resolved it to. Fills in as rows
  /// are added, which is what lets a row show a stepper afterwards.
  final Map<int, int> _resolved = {};

  @override
  Widget build(BuildContext context) {
    final set = widget.options.attributeSets.single;
    final colors = context.colors;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Text(
                  widget.product.name,
                  style: context.text.h3,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: set.attributes.length,
                  separatorBuilder: (_, __) => AppSpacing.vSm,
                  itemBuilder: (_, i) => _VariantRow(
                    product: widget.product,
                    attribute: set.attributes[i],
                    unavailable: widget.options.unavailableAttributeIds
                        .contains(set.attributes[i].id),
                    busy: _adding != null,
                    adding: _adding == set.attributes[i].id,
                    resolvedLineId: _resolved[set.attributes[i].id],
                    onAdd: () => _add(set.attributes[i]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Resolves the tapped option to a variation, then adds *that* id.
  ///
  /// Two round trips, and both are necessary: the attribute list carries prices
  /// but no variation ids, and the cart matches on the variation id. Skipping
  /// the resolve and posting the parent is exactly the bug this sheet exists to
  /// prevent.
  Future<void> _add(VariationAttribute attribute) async {
    setState(() => _adding = attribute.id);
    try {
      final variation =
          await ref.read(catalogRepositoryProvider).resolveVariation(
                parentId: widget.product.id,
                attributeIds: [attribute.id],
              );
      if (!mounted) return;

      if (variation == null) {
        context.showAlertSnack(
          'That pack is not available right now. Please pick another.',
        );
        return;
      }

      final failure = await ref
          .read(serverCartProvider.notifier)
          .addProductId(variation.id);
      if (!mounted) return;

      if (failure != null) {
        // The server names the constraint — "Maximum quantity is 93!" — far
        // better than anything composed here.
        context.showAlertSnack(failure);
        return;
      }
      setState(() => _resolved[attribute.id] = variation.id);
    } finally {
      if (mounted) setState(() => _adding = null);
    }
  }
}

class _VariantRow extends ConsumerWidget {
  const _VariantRow({
    required this.product,
    required this.attribute,
    required this.unavailable,
    required this.busy,
    required this.adding,
    required this.resolvedLineId,
    required this.onAdd,
  });

  final Product product;
  final VariationAttribute attribute;
  final bool unavailable;

  /// Some row on the sheet is mid-add; writes are serialised, so the others
  /// wait rather than racing it.
  final bool busy;
  final bool adding;

  /// Set once this row has been added and the server named its variation.
  final int? resolvedLineId;

  final VoidCallback onAdd;

  /// Pulls the attribute title out of a cart line's `variation_attributes`.
  ///
  /// The server writes `"(Pack Size: 1.85 KG (Pack of 1))"` — set title, then
  /// the attribute title. That string is the **only** link a cart line offers
  /// back to an attribute: the line carries no parent id and no attribute ids,
  /// and its own id is the variation's, which this sheet does not know until it
  /// resolves one.
  ///
  /// Parsed rather than substring-matched, so `"5 KG (Pack of 1)"` cannot match
  /// a line for `"5 KG (Pack of 1) Refill"`. Only single-set products reach
  /// this sheet ([canShowVariantSheet]), so the format is exactly one pair.
  /// Anything else yields null and the row simply offers ADD.
  static String? _attributeTitleIn(String label) {
    var text = label.trim();
    if (text.startsWith('(') && text.endsWith(')')) {
      text = text.substring(1, text.length - 1);
    }
    final separator = text.indexOf(': ');
    return separator < 0 ? null : text.substring(separator + 2).trim();
  }

  /// The cart line already holding this pack, if any.
  CartLineId? _lineInCart(ServerCartState cart) {
    // A row added in this sheet knows its variation id outright.
    final resolved = resolvedLineId;
    if (resolved != null) return CartLineId.forSimpleProduct(resolved);

    // Otherwise recognise it from the basket, so reopening the sheet shows a
    // stepper for packs that are already in it rather than another ADD.
    for (final item in cart.items) {
      final label = item.variationLabel;
      if (label == null) continue;
      if (_attributeTitleIn(label) == attribute.title) return item.lineId;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final cartState = ref.watch(serverCartProvider);
    final line = _lineInCart(cartState);
    final qty = line == null ? 0 : cartState.quantityOf(line);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppRadius.rLg,
        border: Border.all(color: colors.line),
      ),
      child: Row(
        children: [
          _thumb(context),
          AppSpacing.hSm,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  // The pack size reads better as the row's headline than the
                  // full attribute title, which repeats the product name's
                  // wording ("5 KG (Pack of 1)" vs "5 kg").
                  attribute.packLabel ?? attribute.title,
                  style: context.text.title,
                ),
                if (attribute.packLabel != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    attribute.title,
                    style: context.text.caption.copyWith(color: colors.muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          AppSpacing.hSm,
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                PriceUtils.format(attribute.price),
                style: context.text.price,
              ),
              if (attribute.hasDiscount)
                Text(
                  PriceUtils.format(attribute.originalPrice),
                  style: context.text.strike.copyWith(fontSize: 12),
                ),
            ],
          ),
          AppSpacing.hSm,
          _action(
            context,
            ref,
            qty,
            line,
            cartState.busy,
            // Per pack. `cartState.busy` is true for every row at once, so it
            // can gate the ADD button (a write really is in flight) but must
            // never drive one row's appearance.
            lineBusy: line != null && cartState.isBusyLine(line),
          ),
        ],
      ),
    );
  }

  Widget _thumb(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        children: [
          Positioned.fill(
            child: AppNetworkImage(
              // Each option can carry its own image, but the live catalogue
              // leaves it empty — and a variation's real gallery only arrives
              // with a resolve. The parent's image is the honest stand-in.
              url: attribute.image.isNotEmpty
                  ? attribute.image
                  : product.primaryImage,
              borderRadius: AppRadius.rMd,
              fit: BoxFit.cover,
            ),
          ),
          if (attribute.hasDiscount)
            Positioned(
              top: 0,
              left: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: const BoxDecoration(
                  color: AppColors.info,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(8),
                    bottomRight: Radius.circular(6),
                  ),
                ),
                child: Text(
                  '${attribute.discountPercent}% OFF',
                  style: AppTypography.overline.copyWith(
                    fontSize: 8,
                    height: 1.1,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Fixed width so every row's control lines up down the sheet, and so
  /// swapping ADD for a stepper does not shift the price column.
  static const double _actionWidth = 86;

  /// The row's control: a spinner while **this** row is being added, a stepper
  /// once the pack is in the basket, an ADD button otherwise.
  ///
  /// ## Why nothing here greys out on `busy`
  ///
  /// Cart writes are serialised — a queued second one is how this backend
  /// loses a cart — so while any row is being added the others cannot write.
  /// They must not *look* that way: disabling every row's button turned the
  /// whole sheet grey for the length of one request, which reads as "these
  /// packs are unavailable" rather than "please wait a moment".
  ///
  /// Only [unavailable] — a combination the server says does not exist — dims a
  /// control. Everything else keeps its ordinary appearance and simply ignores
  /// taps, and the row actually working shows the spinner.
  Widget _action(
    BuildContext context,
    WidgetRef ref,
    int qty,
    CartLineId? line,
    bool cartBusy, {
    bool lineBusy = false,
  }) {
    if (adding) {
      return const SizedBox(
        width: _actionWidth,
        height: 34,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (qty > 0 && line != null) {
      final cart = ref.read(serverCartProvider.notifier);
      return SizedBox(
        width: _actionWidth,
        // Callbacks stay live even mid-write. `ServerCartNotifier` already
        // drops a mutation that arrives while another is in flight, so the
        // guard is there rather than here — and passing null to both would dim
        // the stepper, which is the very thing being fixed.
        child: QuantityStepper(
          quantity: qty,
          dense: true,
          busy: lineBusy,
          onIncrement: () => cart.increment(line),
          // At one unit this removes the line — the server does not treat qty 0
          // as a delete, so the notifier routes to DELETE itself.
          onDecrement: () => cart.decrement(line),
        ),
      );
    }

    // An InkWell rather than an OutlinedButton: a disabled OutlinedButton
    // repaints itself grey, and this control has to stay looking normal while
    // a sibling row is writing. Appearance is keyed on [unavailable] alone;
    // `busy` and `cartBusy` only make it inert.
    final colors = context.colors;
    final border = unavailable ? colors.line : AppColors.primary;

    return SizedBox(
      // Keyed by attribute so a caller — or a test — can address one pack's
      // button rather than relying on row order.
      key: ValueKey('variant-add-${attribute.id}'),
      width: _actionWidth,
      height: 34,
      child: Material(
        color: unavailable ? colors.surfaceAlt : colors.primarySoft,
        borderRadius: AppRadius.rSm,
        child: InkWell(
          onTap: unavailable || busy || cartBusy ? null : onAdd,
          borderRadius: AppRadius.rSm,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: AppRadius.rSm,
              border: Border.all(color: border, width: 1.2),
            ),
            child: Text(
              unavailable ? 'N/A' : 'ADD',
              style: context.text.buttonSm.copyWith(
                fontSize: 11,
                // Via the palette, not AppColors: this token differs between
                // light and dark, and theme_test pins that the presentation
                // layer never reaches past `context.colors` for one.
                color: unavailable ? colors.muted : colors.primaryDark,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

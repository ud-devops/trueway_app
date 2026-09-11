import 'package:flutter/material.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../core/utils/price_utils.dart';
import '../../data/models/product_variation.dart';

/// The attribute picker on a variable product.
///
/// One block per attribute set ("Pack Size"), one chip per option. Each option
/// carries its **own** price on the product-detail payload, so the price sits
/// beside the option rather than only updating after a tap — the customer can
/// compare packs without committing to one.
///
/// Nothing here decides which variation a selection means, or whether a
/// combination exists. Both are the server's answers: [unavailableIds] comes
/// from `unavailable_attribute_ids`, and the chosen id goes to
/// `/product-variation/{parent}`.
class VariationSelector extends StatelessWidget {
  const VariationSelector({
    super.key,
    required this.sets,
    required this.selection,
    required this.unavailableIds,
    required this.onSelect,
    this.enabled = true,
  });

  final List<VariationAttributeSet> sets;

  /// attribute-set id → chosen attribute id.
  final Map<int, int> selection;

  final List<int> unavailableIds;

  /// Called with (setId, attributeId).
  final void Function(int setId, int attributeId) onSelect;

  /// False while a resolve is in flight — taps are ignored rather than queued,
  /// because each one is a request and the last answer would win anyway.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (sets.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final set in sets) ...[
          _SetBlock(
            set: set,
            selectedId: selection[set.id],
            unavailableIds: unavailableIds,
            enabled: enabled,
            onSelect: (attributeId) => onSelect(set.id, attributeId),
          ),
          AppSpacing.vMd,
        ],
      ],
    );
  }
}

class _SetBlock extends StatelessWidget {
  const _SetBlock({
    required this.set,
    required this.selectedId,
    required this.unavailableIds,
    required this.enabled,
    required this.onSelect,
  });

  final VariationAttributeSet set;
  final int? selectedId;
  final List<int> unavailableIds;
  final bool enabled;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final chosen = set.attributes.where((a) => a.id == selectedId).firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(set.title, style: context.text.title),
            AppSpacing.hSm,
            // Naming the current pick matters when the chips wrap onto several
            // rows and the selected one has scrolled out of the first.
            if (chosen != null)
              Expanded(
                child: Text(
                  chosen.title,
                  style: context.text.bodySm.copyWith(color: context.colors.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        AppSpacing.vSm,
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final attribute in set.attributes)
              _AttributeChip(
                attribute: attribute,
                selected: attribute.id == selectedId,
                // The server publishes which combinations do not exist, so the
                // customer is stopped before the request rather than after it.
                unavailable: unavailableIds.contains(attribute.id),
                showPrice: set.hasVaryingPrices,
                enabled: enabled,
                onTap: () => onSelect(attribute.id),
              ),
          ],
        ),
      ],
    );
  }
}

/// One option. Shows its title, its pack size and — when the options in the set
/// are priced differently — its own price.
class _AttributeChip extends StatelessWidget {
  const _AttributeChip({
    required this.attribute,
    required this.selected,
    required this.unavailable,
    required this.showPrice,
    required this.enabled,
    required this.onTap,
  });

  final VariationAttribute attribute;
  final bool selected;
  final bool unavailable;
  final bool showPrice;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final interactive = enabled && !unavailable;

    final borderColor = selected ? AppColors.primary : colors.line;
    final background = selected ? colors.primarySoft : colors.surface;

    // An unavailable option stays legible rather than vanishing: the customer
    // needs to see that the 5 kg pack exists but is not combinable, or the set
    // looks arbitrarily short.
    final titleColor = unavailable
        ? colors.muted
        : (selected ? colors.primaryDarker : colors.ink);

    return Semantics(
      button: true,
      selected: selected,
      enabled: interactive,
      label: unavailable
          ? '${attribute.title}, unavailable'
          : attribute.title,
      child: InkWell(
        onTap: interactive ? onTap : null,
        borderRadius: AppRadius.rMd,
        child: Container(
          constraints: const BoxConstraints(minWidth: 96),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: background,
            borderRadius: AppRadius.rMd,
            border: Border.all(
              color: borderColor,
              width: selected ? 1.8 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                attribute.title,
                style: context.text.bodySm.copyWith(
                  color: titleColor,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  decoration: unavailable ? TextDecoration.lineThrough : null,
                ),
              ),
              if (showPrice && attribute.price > 0) ...[
                const SizedBox(height: 3),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      PriceUtils.format(attribute.price),
                      style: context.text.bodySm.copyWith(
                        color: unavailable ? colors.muted : colors.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (attribute.hasDiscount) ...[
                      const SizedBox(width: 5),
                      Text(
                        PriceUtils.format(attribute.originalPrice),
                        style: context.text.strike.copyWith(fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ],
              if (attribute.packLabel != null) ...[
                const SizedBox(height: 2),
                Text(
                  attribute.packLabel!,
                  style: context.text.caption.copyWith(color: colors.muted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

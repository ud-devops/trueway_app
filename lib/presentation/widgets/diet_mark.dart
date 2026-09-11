import 'package:flutter/material.dart';

import '../../core/design_system/theme_context.dart';
import '../../data/models/product_model.dart';

/// The Indian packaged-food diet mark: a filled dot inside a square outline,
/// green for vegetarian and brown-red for non-vegetarian.
///
/// **Drawn here, not downloaded.** The backend has no symbol image for this —
/// no diet field and no icon on any endpoint — so the only thing that comes
/// from the server is the *fact*, read out of the spec table
/// ([Product.dietType]). Drawing the glyph keeps it crisp at any size and
/// costs no request, and there is nothing to drift from because the shape is
/// fixed by the regulation rather than by the merchant.
///
/// There is no "unknown" rendering on purpose: callers pass a null [diet] and
/// get nothing at all. A mark is a food-safety claim, and one must never be
/// inferred from a silent catalogue.
class DietMark extends StatelessWidget {
  const DietMark({super.key, required this.diet, this.size = 22});

  final DietType? diet;

  /// Outer square, in logical pixels.
  final double size;

  static const Color _veg = Color(0xFF0F7B34);
  static const Color _nonVeg = Color(0xFF9B1C1C);

  @override
  Widget build(BuildContext context) {
    final diet = this.diet;
    if (diet == null) return const SizedBox.shrink();

    final color = diet == DietType.vegetarian ? _veg : _nonVeg;

    return Semantics(
      label: diet == DietType.vegetarian ? 'Vegetarian' : 'Non-vegetarian',
      excludeSemantics: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          // The mark sits on a product photo, so it carries its own ground —
          // a bare outline over a dark or busy image reads as noise.
          color: context.colors.surface,
          border: Border.all(color: color, width: size * 0.09),
          borderRadius: BorderRadius.circular(size * 0.16),
        ),
        alignment: Alignment.center,
        child: Container(
          width: size * 0.5,
          height: size * 0.5,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/theme_context.dart';

/// A field heading with the asterisk that marks it required.
///
/// The asterisk is a separate red span rather than part of the label string, so
/// it reads as a marker instead of as punctuation someone typed — and so a
/// screen reader is told "required" instead of announcing a star.
///
/// Used wherever a form field must be filled. The app's forms refuse an
/// incomplete submit anyway; this is what tells the customer *before* they press
/// it, which is the difference between a form that guides and one that scolds.
class RequiredLabel extends StatelessWidget {
  const RequiredLabel(this.label, {super.key, this.style, this.required = true});

  final String label;

  /// Defaults to the section-heading style the forms use.
  ///
  /// Pass [inheritStyle] to take the style from the surrounding
  /// `DefaultTextStyle` instead — which is what makes this usable as an
  /// `InputDecoration.label`, where the decorator animates the label's own
  /// style between its resting and floating positions.
  final TextStyle? style;

  /// A style that adds nothing, so the label inherits its surroundings.
  ///
  /// `inherit` is true by default on [TextStyle], so an empty one merges with
  /// whatever `DefaultTextStyle` is in scope; the asterisk still gets its own
  /// colour on top.
  static const TextStyle inheritStyle = TextStyle();

  /// False renders the plain label, so a caller can drive this from the same
  /// flag that drives its validation rather than branching at the call site.
  final bool required;

  @override
  Widget build(BuildContext context) {
    final base = style ?? context.text.h3;

    if (!required) return Text(label, style: base);

    return Semantics(
      label: '$label, required',
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(
          text: label,
          style: base,
          children: [
            TextSpan(
              text: ' *',
              style: base.copyWith(color: AppColors.error),
            ),
          ],
        ),
      ),
    );
  }
}

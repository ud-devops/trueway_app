/// Strips hard-coded box sizing out of pasted product HTML.
///
/// ## Why this exists
///
/// The catalogue's `content` and `description` are pasted straight from an
/// Amazon listing, and the paste brings Amazon's *desktop* layout with it.
/// Product 119 carries Amazon's collapsed-expander wrapper verbatim:
///
/// ```html
/// <div class="a-expander-collapsed-height …" style="…max-height:300px;width:513.25px;…">
/// ```
///
/// On Amazon that box is paired with `overflow:hidden` and a "See more" link,
/// so the clip is invisible. Here it is a hard 300px ceiling on a list that
/// needs ~380px — which is the yellow **"BOTTOM OVERFLOWED BY 80 PIXELS"**
/// stripe through the middle of "About this item". The `width:513.25px` is the
/// same problem sideways: a fixed box wider than any phone. The spec table
/// brings its own version, `<td style="width:484.962px">`.
///
/// Products 118 and 119 carry the wrapper; 111, 120, 123 and 125 do not, which
/// is exactly why the overflow appears on some products and not others.
///
/// So the sizing is dropped and the text is allowed to take the height it
/// needs. Nothing else is touched: colours, weights, list markers and links all
/// survive, and `line-height` — which is layout the merchant *did* mean, and
/// which reads as "…height:115%" to a careless pattern — is explicitly kept.
library;

/// Removes fixed heights and pixel widths from inline `style` attributes.
///
/// Returns [html] unchanged when there is nothing to strip, so the common case
/// costs one regex scan and no allocation.
String relaxPastedLayout(String html) {
  if (html.isEmpty) return html;
  return html.replaceAllMapped(_styleAttribute, (m) {
    // Group 1 is the double-quoted body, group 2 the single-quoted one — only
    // one of the two ever matches.
    final doubleQuoted = m.group(1) != null;
    final relaxed = _stripSizing(m.group(1) ?? m.group(2)!);
    // An attribute left empty is dropped entirely rather than left as
    // `style=""`.
    if (relaxed.trim().isEmpty) return '';
    final quote = doubleQuoted ? '"' : "'";
    return 'style=$quote$relaxed$quote';
  });
}

final RegExp _styleAttribute = RegExp(
  '''\\bstyle\\s*=\\s*(?:"([^"]*)"|'([^']*)')''',
  caseSensitive: false,
);

/// The declarations to drop, matched only at the start of a property name.
///
/// The `(?<![-\\w])` guard is what keeps `line-height` and `border-width`: both
/// end in a property this would otherwise match, and losing `line-height` would
/// re-space every bullet on the page.
final RegExp _sizingDeclaration = RegExp(
  r'(?<![-\w])(max-height|min-height|height)\s*:\s*[^;"]*;?',
  caseSensitive: false,
);

/// Widths are only dropped when they are absolute. `width:100%` is responsive
/// and does no harm; `width:513.25px` is a desktop column.
final RegExp _fixedWidthDeclaration = RegExp(
  r'(?<![-\w])(max-width|min-width|width)\s*:\s*[\d.]+(px|pt|cm|in)\s*;?',
  caseSensitive: false,
);

String _stripSizing(String style) => style
    .replaceAll(_sizingDeclaration, '')
    .replaceAll(_fixedWidthDeclaration, '');

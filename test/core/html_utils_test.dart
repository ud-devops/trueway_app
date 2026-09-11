import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/utils/html_utils.dart';

/// The catalogue's product copy is pasted from Amazon, desktop layout and all.
/// These are the exact shapes that reach the app.
void main() {
  group('relaxPastedLayout', () {
    // Verbatim from product 119's `content`. This wrapper is the whole bug:
    // 300px of room for ~380px of bullets, and no `overflow:hidden` on this
    // side to hide the clip.
    const amazonExpander =
        '<div class="a-expander-collapsed-height a-row a-expander-container '
        'a-expander-partial-collapse-container" style="background-color:'
        'rgb(255,255,255);color:rgb(15,17,17);font-family:\'Amazon Ember\', '
        'Arial, sans-serif;font-size:14px;font-style:normal;font-weight:400;'
        'max-height:300px;width:513.25px;word-spacing:0px;">'
        '<ul><li>Rich in Nutrients</li></ul></div>';

    test('drops the ceiling that clipped "About this item"', () {
      final out = relaxPastedLayout(amazonExpander);
      expect(out, isNot(contains('max-height')));
      expect(out, isNot(contains('513.25px')));
    });

    test('keeps every style that is not box sizing', () {
      final out = relaxPastedLayout(amazonExpander);
      expect(out, contains('color:rgb(15,17,17)'));
      expect(out, contains('font-size:14px'));
      expect(out, contains('font-weight:400'));
      // Content survives untouched.
      expect(out, contains('<li>Rich in Nutrients</li>'));
    });

    test('keeps line-height, which merely ends in "height"', () {
      // Product 125's copy is full of these. Dropping them would re-space
      // every bullet on the page.
      const html = '<span style="font-size:12pt;line-height:115%;">Size</span>';
      expect(relaxPastedLayout(html), contains('line-height:115%'));
    });

    test('drops the spec table\'s desktop column widths', () {
      // From product 120's `description` — the diet row.
      const html = '<td class="a-span9" style="margin-right:0px;'
          'padding:0.1875rem;width:484.962px;">Vegetarian</td>';
      final out = relaxPastedLayout(html);
      expect(out, isNot(contains('484.962px')));
      expect(out, contains('padding:0.1875rem'));
    });

    test('keeps a relative width, which is not a desktop column', () {
      const html = '<div style="width:100%;">x</div>';
      expect(relaxPastedLayout(html), contains('width:100%'));
    });

    test('keeps border-width, which also ends in "width"', () {
      const html = '<div style="border-width:2px;">x</div>';
      expect(relaxPastedLayout(html), contains('border-width:2px'));
    });

    test('removes an attribute it emptied rather than leaving style=""', () {
      const html = '<div style="height:24px;">x</div>';
      final out = relaxPastedLayout(html);
      expect(out, isNot(contains('style')));
      expect(out, contains('<div >x</div>'));
    });

    test('handles single-quoted attributes without changing the quoting', () {
      const html = "<div style='color:red;height:24px;'>x</div>";
      final out = relaxPastedLayout(html);
      expect(out, contains("style='color:red;'"));
    });

    test('leaves untouched html alone', () {
      // Products 111 and 120 carry no sizing at all — most of the catalogue.
      const html = '<ul><li><span style="font-size:16px;">Organic</span></li></ul>';
      expect(relaxPastedLayout(html), html);
      expect(relaxPastedLayout(''), '');
    });
  });
}

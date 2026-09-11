import '../../core/config/app_config.dart';
import '../../core/utils/json_utils.dart';

class SliderItem {
  const SliderItem({
    required this.id,
    required this.title,
    required this.description,
    required this.image,
    required this.link,
    required this.order,
    this.tabletImage,
    this.mobileImage,
  });

  final int id;
  final String title;
  final String description;

  /// The desktop artwork. **The only one the server sends as a URL** — it is
  /// the single field `SimpleSliderItemResource` puts through
  /// `RvMedia::getImageUrl()`.
  final String image;
  final String link;
  final int order;

  /// The tablet and phone artwork, when the admin uploaded them.
  ///
  /// ⚠ These arrive as **raw stored paths, not URLs** — live: `"./tab1.webp"`
  /// and `"./mobile1.webp"` against an `image` of
  /// `"https://dev.truewayerp.com/storage/./web1.webp"`. Binding either
  /// straight into an Image widget requests a relative path off the API host
  /// and fails. They are resolved against the storage base in [fromJson], and
  /// they stay null when the admin left them empty (slider "test1" does).
  final String? tabletImage;
  final String? mobileImage;

  /// The artwork for a slide box [width] logical pixels wide.
  ///
  /// **Not "mobile crop on a phone".** The three uploads are cut for the
  /// *website's* three layouts, and measured they are wildly different shapes:
  ///
  /// | upload | size | aspect |
  /// |---|---|---|
  /// | `image` (desktop) | 1905x540 | 3.53 |
  /// | `tablet_image` | 768x350 | 2.19 |
  /// | `mobile_image` | 400x350 | 1.14 |
  ///
  /// This app's slide is a **fixed 2.13 box** on every device — 172dp tall
  /// against a 92%-viewport width — so the tablet cut is the one that fits it,
  /// phone included. Choosing by device class instead put the 1.14 mobile cut
  /// in a 2.13 box, where `BoxFit.cover` scaled it to the width and threw away
  /// close to half its height: that is the sliced artwork on the home screen.
  ///
  /// So the pick follows the **box**, not the screen. Only a genuinely wide
  /// layout — a desktop or web build past [_desktopBreakpoint], where the box
  /// stops being 2.13 — earns the 3.53 banner.
  String imageFor(double width) {
    if (width >= _desktopBreakpoint) return image;
    return tabletImage ?? mobileImage ?? image;
  }

  /// Above this the slide is wide enough for the desktop banner. A Windows or
  /// web build of this app, not a phone or a tablet.
  static const double _desktopBreakpoint = 1024;

  /// The title as text, with the CMS's markup and its indentation removed.
  ///
  /// The naive version — splitting on `<br>` and calling `trim()` on the
  /// whole string — left the live title's **ten literal tabs** on its second
  /// line, because `trim()` only touches the ends of the string. Left-aligned
  /// that read as a stray gap; centred it threw the second line off-centre,
  /// which is what made it visible.
  ///
  /// Each line is therefore collapsed and trimmed on its own, and empty lines
  /// (from a trailing `<br>`) are dropped rather than rendered as blank rows
  /// that push the real text off the slide.
  String get plainTitle => _plain(title);

  /// The description, given the same treatment. It carries no markup today,
  /// but it comes from the same CMS field editor as [title] and there is no
  /// reason for the two to diverge.
  String get plainDescription => _plain(description);

  static String _plain(String raw) => raw
      .split(RegExp(r'<br\s*/?>'))
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');

  factory SliderItem.fromJson(Map<String, dynamic> j) => SliderItem(
        id: asInt(j['id']),
        title: asString(j['title']),
        description: asString(j['description']),
        image: AppConfig.resolveImage(asString(j['image'])),
        // `resolveStorageImage`, not `resolveImage`: these are stored paths
        // relative to the media disk, so they need the `/storage` segment that
        // the server already baked into `image`.
        tabletImage: AppConfig.resolveStorageImage(j['tablet_image']),
        mobileImage: AppConfig.resolveStorageImage(j['mobile_image']),
        link: asString(j['link']),
        order: asInt(j['order']),
      );
}

class HomeSlider {
  const HomeSlider({
    required this.id,
    required this.name,
    required this.key,
    required this.items,
  });

  final int id;
  final String name;
  final String key;
  final List<SliderItem> items;

  factory HomeSlider.fromJson(Map<String, dynamic> j) {
    final items = asMapList(j['items']).map(SliderItem.fromJson).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    return HomeSlider(
      id: asInt(j['id']),
      name: asString(j['name']),
      key: asString(j['key']),
      items: items,
    );
  }
}

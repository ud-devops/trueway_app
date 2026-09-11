import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../core/config/app_config.dart';
import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import 'app_network_image.dart';

/// Whether a [AppMedia] is a still image or a clip.
enum AppMediaKind { image, video }

/// One viewable attachment, normalised out of whatever the API handed us.
///
/// Product galleries, product `videos[]` and review `images[]`/`videos[]` all
/// have different shapes; the viewer takes this one instead of any of them.
class AppMedia {
  const AppMedia({
    required this.url,
    required this.kind,
    this.thumbnail,
  });

  const AppMedia.image(String url, {String? thumbnail})
      : this(url: url, kind: AppMediaKind.image, thumbnail: thumbnail);

  const AppMedia.video(String url, {String? thumbnail})
      : this(url: url, kind: AppMediaKind.video, thumbnail: thumbnail);

  /// Full-size image, or the playable clip URL.
  final String url;

  /// A *still* poster. Null for most videos — on this backend a review's
  /// `videos[].thumbnail` is the .mp4 URL itself (both keys go through the same
  /// `RvMedia::getImageUrl()` call), so it must never be bound to an Image
  /// widget. Callers pass null there and the tile draws a play glyph instead.
  final String? thumbnail;

  final AppMediaKind kind;

  bool get isVideo => kind == AppMediaKind.video;

  /// A poster only when it is genuinely a still — see [thumbnail].
  String? get posterUrl {
    final t = thumbnail;
    if (t == null || t.isEmpty) return null;
    if (t == url && isVideo) return null;
    if (_looksLikeVideo(t)) return null;
    return t;
  }

  static bool _looksLikeVideo(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final ext in const ['.mp4', '.mov', '.m4v', '.webm', '.avi', '.3gp']) {
      if (path.endsWith(ext)) return true;
    }
    return false;
  }

  /// Whether [url] is a media file we can wrap in a `<video>` tag.
  ///
  /// **Default is no.** Handing a web page to a `<video src>` renders a broken
  /// player stuck at 0:00, which is what shipped first — every product video on
  /// the catalogue is a page, not a file. Only a recognised media extension
  /// takes the `<video>` path. Review attachments go the other way: those
  /// genuinely are `.mp4` files.
  bool get isFile => _looksLikeVideo(url);

  /// A YouTube watch/embed/short link, which plays as a page in the WebView.
  bool get isYouTube {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return host == 'youtu.be' ||
        host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host.endsWith('.youtube-nocookie.com');
  }

  /// The video id out of any YouTube link shape, or null.
  ///
  /// Handles `/embed/<id>`, `/shorts/<id>`, `/v/<id>`, `youtu.be/<id>` and
  /// `watch?v=<id>`.
  ///
  /// **The id is taken and the rest of the link is discarded**, deliberately.
  /// The catalogue's own URL is
  /// `…/embed/-XOd-l4CpcA?si=OlIEL77K4Us99UGu?enablejsapi=1&iv_load_policy=3&fs=0&rel=0&loop=1&start=1`
  /// — note the *second* `?`, which makes everything after it part of the `si`
  /// value. Worse, it asks for `enablejsapi=1`, and the IFrame API refuses a
  /// JS-enabled player whose `origin` does not match the embedding page: that
  /// is **error 153, "Video player configuration error"**, which is what the
  /// screen showed. Rebuilding the URL from the id alone drops both problems.
  String? get youTubeId {
    if (!isYouTube) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (uri.host.toLowerCase() == 'youtu.be') {
      return segments.isEmpty ? null : _cleanId(segments.first);
    }
    for (var i = 0; i < segments.length - 1; i++) {
      if (const {'embed', 'shorts', 'v', 'live'}.contains(segments[i])) {
        return _cleanId(segments[i + 1]);
      }
    }
    return _cleanId(uri.queryParameters['v']);
  }

  /// Ids are `[A-Za-z0-9_-]`; anything else means we did not find one.
  static String? _cleanId(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return RegExp(r'^[A-Za-z0-9_-]{6,}$').hasMatch(raw) ? raw : null;
  }

  /// A page URL, i.e. not [isFile]. Loaded into the WebView as-is.
  bool get isPage => !isFile;

  /// Whether this is something the app will actually show.
  ///
  /// **Only two sources are supported: a YouTube link, or a file uploaded to
  /// the store.** The catalogue also carries an Amazon Live *page* URL on
  /// products 123 and 125 — that is an admin mistake, not a source we support,
  /// and it is dropped rather than rendered: it opens a third-party storefront
  /// inside the product page, which is not a product video and is not something
  /// a customer asked for.
  ///
  /// Dropping is silent by design. An unsupported entry is a data-entry slip to
  /// be fixed in the admin, and a customer-facing "this video is broken" panel
  /// tells the customer about a problem only the merchant can act on. Images
  /// are unaffected — this only gates [isVideo] entries.
  /// A YouTube link only counts once an id can actually be read out of it — a
  /// link we cannot rebuild is one we cannot play.
  bool get isPlayable => !isVideo || isFile || youTubeId != null;
}

/// Opens the full-screen, swipeable media viewer at [initialIndex].
///
/// Images pinch-zoom; videos play in place. Swiping left/right moves through
/// the whole set, so a review's six photos and two clips are one gesture apart
/// rather than eight separate dialogs.
Future<void> showMediaViewer(
  BuildContext context,
  List<AppMedia> media, {
  int initialIndex = 0,
}) {
  if (media.isEmpty) return Future<void>.value();
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black87,
      pageBuilder: (_, __, ___) => _MediaViewer(
        media: media,
        initialIndex: initialIndex.clamp(0, media.length - 1),
      ),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _MediaViewer extends StatefulWidget {
  const _MediaViewer({required this.media, required this.initialIndex});

  final List<AppMedia> media;
  final int initialIndex;

  @override
  State<_MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<_MediaViewer> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.media.length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: count,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) {
              final item = widget.media[i];
              if (item.isVideo) {
                // Not wrapped in a dismiss-on-tap gesture: taps belong to the
                // player's own controls.
                return SafeArea(
                  child: Padding(
                    // Clear of the close button and the page counter.
                    padding: const EdgeInsets.fromLTRB(0, 48, 0, 48),
                    // A hosted player is a whole layout with its own controls,
                    // so it gets the screen. Only a bare media file is a plain
                    // 16:9 rectangle to centre.
                    child: item.isPage
                        ? VideoPlayerView(media: item, fill: true)
                        : Center(child: VideoPlayerView(media: item)),
                  ),
                );
              }
              return GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Center(
                    child: AppNetworkImage(
                      url: item.url,
                      fit: BoxFit.contain,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                ),
              );
            },
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 4,
            right: 4,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          if (count > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).padding.bottom + AppSpacing.md,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    borderRadius: AppRadius.rPill,
                  ),
                  child: Text(
                    '${_index + 1} / $count',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Plays a clip inside a WebView.
///
/// **Why a WebView and not `video_player`:** the plugin requires Dart >= 3.12
/// and this toolchain is on 3.11, so declaring it breaks `flutter pub get`
/// outright (see the note in `pubspec.yaml`). `webview_flutter` is already a
/// dependency, and an HTML5 `<video controls>` gives the platform's own player
/// — controls, scrubbing, fullscreen — for the mp4/mov/webm the API serves.
///
/// Playback is user-initiated: no autoplay attribute is set, because muting it
/// to satisfy the gesture policy would play a review's clip silently, and
/// lifting the policy needs platform-specific controller code on Android only.
class VideoPlayerView extends StatefulWidget {
  const VideoPlayerView({super.key, required this.media, this.fill = false});

  final AppMedia media;

  /// Take all the room offered instead of a 16:9 box. A hosted page — YouTube's
  /// chrome, an Amazon Live page — is a whole layout, not a video rectangle,
  /// so squeezing it into 16:9 leaves it scrolling inside a letterbox.
  final bool fill;

  @override
  State<VideoPlayerView> createState() => _VideoPlayerViewState();
}

class _VideoPlayerViewState extends State<VideoPlayerView> {
  /// Null when `webview_flutter` has no implementation for this platform.
  ///
  /// The plugin ships Android/iOS only, and constructing a controller anywhere
  /// else *asserts* rather than degrading — which would take the whole product
  /// page down on a desktop or web build (and under a widget test, where no
  /// platform instance is registered). A clip that cannot play is not a reason
  /// to lose the page, so the failure is caught and stated instead.
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    try {
      final controller = WebViewController.fromPlatformCreationParams(
        // iOS plays *every* clip in a native fullscreen player — with its own
        // AirPlay, share and done chrome — unless inline playback is allowed,
        // and it demands a tap YouTube's own JS cannot supply.
        WebViewPlatform.instance is WebKitWebViewPlatform
            ? WebKitWebViewControllerCreationParams(
                allowsInlineMediaPlayback: true,
                mediaTypesRequiringUserAction: const {},
              )
            : const PlatformWebViewControllerCreationParams(),
      )
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black);

      // The player lives inside a page we cannot step through with a debugger,
      // so its own reporting is the only way to see why a clip did not start.
      // Debug builds only — a customer's log should not carry player chatter.
      if (kDebugMode) {
        controller.setOnConsoleMessage(
          (message) => debugPrint('[video] ${message.message}'),
        );
      }

      // Android refuses any playback that was started by script rather than by
      // a direct tap on a media element. Our play button, and YouTube's own,
      // both start playback through the IFrame API — so with the default policy
      // the tap registers and nothing happens, which is exactly the "play hi
      // nahi ho raha" symptom. This is the switch that lets it start.
      if (controller.platform case final AndroidWebViewController android) {
        android.setMediaPlaybackRequiresUserGesture(false);
      }

      final url = widget.media.url;
      final youTubeId = widget.media.youTubeId;
      if (youTubeId != null) {
        // Embedded in a page of ours, served under the store's own origin.
        //
        // Loading `youtube.com/embed/<id>` straight into the WebView is what
        // produced **error 153**: the embed arrives with no referrer, and the
        // catalogue's URL also carries `enablejsapi=1`, which makes the IFrame
        // API demand an `origin` matching the embedding page. There is no
        // embedding page in that arrangement, so the player refuses to
        // configure itself. Giving it a real `baseUrl` supplies the referrer,
        // and the rebuilt `src` drops `enablejsapi` so no origin is demanded at
        // all.
        controller.loadHtmlString(
          _youTubePage(youTubeId),
          baseUrl: AppConfig.origin,
        );
      } else if (widget.media.isFile) {
        // A media file is wrapped in a page rather than loaded directly: a bare
        // media URL can come back with `Content-Disposition: attachment`, which
        // a WebView treats as a download instead of something to render.
        controller.loadHtmlString(_videoPage(url));
      } else {
        controller.loadRequest(Uri.parse(url));
      }
      _controller = controller;
    } catch (_) {
      _controller = null;
    }
  }

  /// A minimal embedding page for one YouTube id.
  ///
  /// The `src` is rebuilt from the id, never forwarded from the server, so the
  /// catalogue's `enablejsapi=1` (and its malformed second `?`) cannot reach
  /// the player — see [AppMedia.youTubeId]. Those two are what made the player
  /// answer **error 153, "Video player configuration error"**: the IFrame API
  /// demands an `origin` matching the embedding page, and there was none.
  ///
  /// The player keeps its own standard controls. An earlier revision hid them
  /// behind a tap-swallowing shield driven by the IFrame API; it stopped
  /// playback from starting at all, so it was taken back out. YouTube's terms
  /// expect those affordances to stay anyway.
  ///
  /// `playsinline` keeps it in the box on iOS; `rel=0` keeps the end-screen
  /// suggestions to the same channel.
  static String _youTubePage(String id) => '''
<!doctype html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>
  html,body{margin:0;height:100%;background:#000;overflow:hidden;}
  iframe{position:absolute;inset:0;width:100%;height:100%;border:0;}
</style>
</head><body>
<iframe
  src="https://www.youtube.com/embed/$id?playsinline=1&rel=0"
  allow="accelerometer; encrypted-media; gyroscope; picture-in-picture; fullscreen"
  allowfullscreen></iframe>
</body></html>
''';

  static String _videoPage(String url) => '''
<!doctype html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>
  html,body{margin:0;height:100%;background:#000;}
  video{width:100%;height:100%;object-fit:contain;background:#000;}
</style>
</head><body>
<video src="${Uri.encodeFull(url)}" controls playsinline preload="metadata"></video>
</body></html>
''';

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final child = controller == null
          ? Container(
              color: Colors.black,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(AppSpacing.md),
              child: const Text(
                'Video playback is not available on this device.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            )
          : WebViewWidget(controller: controller);

    if (widget.fill) return child;
    return AspectRatio(aspectRatio: 16 / 9, child: child);
  }
}

/// A square media thumbnail — the picture for an image, a drawn play glyph for
/// a clip. Never binds a video URL to an Image widget; see [AppMedia.thumbnail].
class MediaThumb extends StatelessWidget {
  const MediaThumb({
    super.key,
    required this.media,
    required this.onTap,
    this.size = 64,
  });

  final AppMedia media;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final poster = media.posterUrl;

    Widget child;
    if (media.isVideo) {
      child = Stack(
        fit: StackFit.expand,
        children: [
          if (poster != null)
            AppNetworkImage(url: poster, width: size, height: size)
          // No poster — which is every review clip on this backend, because
          // `videos[].thumbnail` is the .mp4 itself. Rather than a grey square,
          // the clip's own **first frame** is drawn: a muted, controls-less
          // `<video preload="metadata">` parks on frame one without ever
          // playing, which is exactly a thumbnail.
          else if (media.isFile)
            _VideoFirstFrame(url: media.url)
          else
            Container(color: context.colors.surfaceAlt),
          Center(
            child: Icon(
              Icons.play_circle_fill_rounded,
              size: size * 0.42,
              // White over any frame — poster or first frame. The muted grey is
              // only for the tile that has no picture behind it at all.
              color: poster != null || media.isFile
                  ? Colors.white
                  : context.colors.muted,
            ),
          ),
        ],
      );
    } else {
      child = AppNetworkImage(
        url: poster ?? media.url,
        width: size,
        height: size,
      );
    }

    return Semantics(
      label: media.isVideo ? 'Play video' : 'View photo',
      button: onTap != null,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: ClipRRect(borderRadius: AppRadius.rSm, child: child),
        ),
      ),
    );
  }
}

/// A clip's first frame, used where the server sent no poster.
///
/// `preload="metadata"` fetches only the container header and the first frame —
/// not the clip — and with no `autoplay` the element simply displays that frame.
/// `muted` and `playsinline` keep it silent and in place; pointer events are
/// off so the tile's own tap handler still gets the gesture.
///
/// Degrades to a plain panel wherever `webview_flutter` has no implementation
/// (desktop, web, widget tests), which is the same rule [VideoPlayerView]
/// follows — a thumbnail is not worth an assertion.
class _VideoFirstFrame extends StatefulWidget {
  const _VideoFirstFrame({required this.url});

  final String url;

  @override
  State<_VideoFirstFrame> createState() => _VideoFirstFrameState();
}

class _VideoFirstFrameState extends State<_VideoFirstFrame> {
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    try {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.disabled)
        ..setBackgroundColor(Colors.black)
        ..loadHtmlString(_page(widget.url));
    } catch (_) {
      _controller = null;
    }
  }

  static String _page(String url) => '''
<!doctype html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>
  html,body{margin:0;height:100%;background:#000;overflow:hidden;}
  video{width:100%;height:100%;object-fit:cover;pointer-events:none;}
</style>
</head><body>
<video src="${Uri.encodeFull(url)}#t=0.1" preload="metadata" muted playsinline></video>
</body></html>
''';

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Container(color: context.colors.surfaceAlt);
    }
    // Ignores pointers so the thumbnail cannot swallow the tap that opens the
    // viewer — a WebView is greedy with gestures.
    return IgnorePointer(child: WebViewWidget(controller: controller));
  }
}

/// The dots under a swipeable gallery.
class MediaPageDots extends StatelessWidget {
  const MediaPageDots({super.key, required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (count < 2) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == index ? 18 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == index ? AppColors.primary : context.colors.line,
              borderRadius: AppRadius.rPill,
            ),
          ),
      ],
    );
  }
}

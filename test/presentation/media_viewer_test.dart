import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/presentation/widgets/app_network_image.dart';
import 'package:trueway_farms/presentation/widgets/media_viewer.dart';

/// The shared photo/clip viewer used by the product gallery and by review rows.
void main() {
  const photo = AppMedia.image('https://example.test/a.jpg',
      thumbnail: 'https://example.test/a-150x150.jpg',);
  // The shape the backend actually sends: `thumbnail` IS the clip.
  const clip = AppMedia.video('https://example.test/clip.mp4',
      thumbnail: 'https://example.test/clip.mp4',);

  Widget host(Widget child) => MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: Center(child: child)),
      );

  group('AppMedia', () {
    test('a clip whose thumbnail is the clip has no poster', () {
      expect(clip.posterUrl, isNull);
    });

    test('a clip with a real still keeps it', () {
      const withPoster = AppMedia.video(
        'https://example.test/clip.mp4',
        thumbnail: 'https://example.test/poster.jpg',
      );
      expect(withPoster.posterUrl, 'https://example.test/poster.jpg');
    });

    test('a video-looking thumbnail is refused even on an image entry', () {
      // `ec_reviews.videos` is a raw JSON column, so a clip can land in the
      // wrong array. Binding it to an Image widget downloads the whole file.
      const misfiled = AppMedia.image(
        'https://example.test/x.jpg',
        thumbnail: 'https://example.test/x.m4v',
      );
      expect(misfiled.posterUrl, isNull);
    });

    const youtube = AppMedia.video(
      'https://www.youtube.com/embed/-XOd-l4CpcA?si=OlIEL77K4Us99UGu',
    );
    const amazonLive = AppMedia.video(
      'https://www.amazon.in/live/video/1ad46949130f4bdc80cea9303d982ca9?ref_=dp_vse_ibvc0',
    );

    test('only a real media file takes the <video> path', () {
      // A review attachment: a genuine mp4.
      expect(clip.isFile, isTrue);
      expect(clip.isPage, isFalse);

      // A YouTube link is a page. Putting one in a `<video src>` renders a
      // broken player stuck at 0:00 — which is what the product page first did.
      expect(youtube.isPage, isTrue);
    });

    test('the supported sources are YouTube and an uploaded file', () {
      expect(youtube.isPlayable, isTrue);
      expect(clip.isPlayable, isTrue);
      for (final host in const [
        'https://youtu.be/-XOd-l4CpcA',
        'https://m.youtube.com/watch?v=-XOd-l4CpcA',
        'https://www.youtube-nocookie.com/embed/-XOd-l4CpcA',
      ]) {
        expect(AppMedia.video(host).isPlayable, isTrue, reason: host);
      }
    });

    test('the id is read out of the catalogue\'s own malformed link', () {
      // Verbatim from products 119/120. Two `?`, so everything after the
      // second one is part of the `si` value — and `enablejsapi=1` is what
      // made the player answer "Error 153, Video player configuration error",
      // because the IFrame API then demands an `origin` match. Only the id
      // survives, so neither problem reaches the player.
      const live = AppMedia.video(
        'https://www.youtube.com/embed/-XOd-l4CpcA?si=OlIEL77K4Us99UGu?enablejsapi=1&iv_load_policy=3&fs=0&rel=0&loop=1&start=1',
      );
      expect(live.youTubeId, '-XOd-l4CpcA');
    });

    test('every YouTube link shape yields the same id', () {
      const id = '-XOd-l4CpcA';
      for (final url in const [
        'https://www.youtube.com/embed/$id',
        'https://www.youtube.com/watch?v=$id&t=30s',
        'https://youtu.be/$id?si=abc',
        'https://www.youtube.com/shorts/$id',
        'https://m.youtube.com/v/$id',
      ]) {
        expect(AppMedia.video(url).youTubeId, id, reason: url);
      }
    });

    test('a YouTube link with no readable id is not offered', () {
      const noId = AppMedia.video('https://www.youtube.com/');
      expect(noId.youTubeId, isNull);
      expect(noId.isPlayable, isFalse);
    });

    test('anything else is dropped, not rendered', () {
      // The Amazon Live page on products 123/125 — an admin slip, not a source
      // this app supports.
      expect(amazonLive.isPlayable, isFalse);
      // A lookalike host must not sneak through.
      expect(
        const AppMedia.video('https://youtube.com.evil.test/x').isPlayable,
        isFalse,
      );
      // The gate is for clips only; photos are never affected.
      expect(photo.isPlayable, isTrue);
    });
  });

  testWidgets('a clip thumbnail draws a glyph, never an image of the clip',
      (tester) async {
    await tester.pumpWidget(host(MediaThumb(media: clip, onTap: () {})));
    await tester.pump();

    expect(find.byIcon(Icons.play_circle_fill_rounded), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is AppNetworkImage && w.url.endsWith('.mp4'),
      ),
      findsNothing,
    );
  });

  testWidgets('the viewer swipes left and right across every attachment',
      (tester) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaViewer(
              context,
              const [photo, photo, clip],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);

    expect(find.text('1 / 3'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await _settle(tester);
    expect(find.text('2 / 3'), findsOneWidget);

    // ...and back, so the gesture is not one-way.
    await tester.drag(find.byType(PageView), const Offset(500, 0));
    await _settle(tester);
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('the viewer opens on the attachment that was tapped',
      (tester) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaViewer(
              context,
              const [photo, photo, clip],
              initialIndex: 2,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);

    expect(find.text('3 / 3'), findsOneWidget);
    expect(find.byType(VideoPlayerView), findsOneWidget);
  });

  testWidgets('a clip that cannot play says so instead of taking the page down',
      (tester) async {
    // No `WebViewPlatform.instance` is registered under a widget test — the
    // same situation as a desktop or web build, where the plugin has no
    // implementation and constructing a controller asserts.
    await tester.pumpWidget(host(const VideoPlayerView(media: clip)));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.text('Video playback is not available on this device.'),
      findsOneWidget,
    );
  });

  testWidgets('an out-of-range index is clamped rather than thrown',
      (tester) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showMediaViewer(context, const [photo], initialIndex: 7),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);

    expect(tester.takeException(), isNull);
  });
}

/// The image placeholder's spinner never stops under a test binding, so
/// `pumpAndSettle` would time out. Pump a fixed amount instead — long enough
/// for the route transition and the page snap.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../widgets/state_views.dart';

/// A shop page, shown inside the app.
///
/// Used by the Account menu's help and policy rows (About us, Contact us,
/// Shipping & delivery, Cancellation & returns, FAQ) and by any ad whose link
/// points somewhere the app has no native screen for.
///
/// ## The theme cannot be read in initState
///
/// This screen used to call `context.colors.surface` inside [initState] to give
/// the WebView a background. `context.colors` is `Theme.of(context)`, which is
/// `dependOnInheritedWidgetOfExactType<_InheritedTheme>()` — and Flutter
/// **throws** for that before `initState` has completed:
///
/// > dependOnInheritedWidgetOfExactType<_InheritedTheme>() … was called before
/// > _WebViewScreenState.initState() completed.
///
/// So every one of those menu rows opened onto a red error page. The background
/// is now set in [didChangeDependencies], which is where Flutter's own message
/// says inherited-widget work belongs — and which has the second benefit of
/// running again when the theme changes, so switching to dark mode repaints the
/// WebView's backdrop instead of leaving a white flash behind the page.
class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key, required this.url, this.title});

  final String url;
  final String? title;

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  /// Null when `webview_flutter` has no implementation here.
  ///
  /// The plugin ships Android/iOS only and *asserts* everywhere else rather
  /// than degrading — including under a widget test, where no platform instance
  /// is registered. Same treatment as `VideoPlayerView`: catch it and say so,
  /// rather than take the screen down.
  WebViewController? _controller;

  /// What went wrong, or null while things are fine.
  String? _failure;

  double _progress = 0;

  @override
  void initState() {
    super.initState();

    // Checked before the controller exists: `Uri.parse` throws on a malformed
    // string, and a link that is not http(s) — a `tel:` or a typo — would load
    // nothing and leave a blank page with a spinner that never stops.
    final target = Uri.tryParse(widget.url.trim());
    if (target == null || !target.hasScheme || !target.isScheme('http') && !target.isScheme('https')) {
      _failure = 'This link could not be opened.';
      return;
    }

    try {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onProgress: (p) {
              if (mounted) setState(() => _progress = p / 100);
            },
            onPageFinished: (_) {
              if (mounted) setState(() => _progress = 1);
            },
            onWebResourceError: (error) {
              // Only the page itself. A missing image or a blocked analytics
              // script also arrives here, and replacing a perfectly readable
              // page with an error card because one asset failed would be
              // worse than the asset failing.
              if (error.isForMainFrame == false || !mounted) return;
              setState(() {
                _progress = 1;
                _failure = 'This page could not be loaded. '
                    'Check your connection and try again.';
              });
            },
          ),
        )
        ..loadRequest(target);
    } on Object {
      _controller = null;
      _failure = 'Web pages cannot be opened on this device.';
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // THE fix. Also re-runs on a theme change, so the backdrop follows it.
    _controller?.setBackgroundColor(context.colors.surface);
  }

  Future<void> _retry() async {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _failure = null;
      _progress = 0;
    });
    await controller.loadRequest(Uri.parse(widget.url.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final failure = _failure;

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: Text(widget.title ?? 'Trueway Farms'),
        bottom: failure == null && _progress < 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress == 0 ? null : _progress,
                  minHeight: 2,
                  backgroundColor: context.colors.hairline,
                  color: AppColors.primary,
                ),
              )
            : null,
      ),
      body: failure != null || controller == null
          ? _problem(context, failure ?? 'This page is not available.')
          : WebViewWidget(controller: controller),
    );
  }

  /// A stated failure rather than a blank white page.
  ///
  /// Retry is offered only when there is a controller to retry with — on a
  /// platform with no WebView at all, a button that cannot work is worse than
  /// no button.
  Widget _problem(BuildContext context, String message) => Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: EmptyView(
          key: const Key('webview-error'),
          icon: Icons.public_off_rounded,
          title: 'Page unavailable',
          subtitle: message,
          action: _controller == null
              ? null
              : SizedBox(
                  width: 200,
                  child: ElevatedButton(
                    key: const Key('webview-retry'),
                    onPressed: _retry,
                    child: const Text('Try again'),
                  ),
                ),
        ),
      );
}

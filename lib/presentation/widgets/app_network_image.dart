import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/theme_context.dart';

/// Cached image with a branded placeholder + graceful fallback.
///
/// Also accepts a **`data:` URI**, which [CachedNetworkImage] cannot: it hands
/// the string to Dio, which needs a host. The review API returns one wherever a
/// customer or a replying staff member has no photo — the server generates an
/// initials avatar and inlines it as `data:image/jpeg;base64,…` — so a loader
/// that only understands http would show the fallback leaf on most reviews.
class AppNetworkImage extends StatelessWidget {
  const AppNetworkImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.height,
    this.width,
    this.backgroundColor,
  });

  final String url;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final double? height;
  final double? width;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final inline = _decodeDataUri(url);

    final child = url.isEmpty
        ? _fallback(context)
        : inline != null
            ? Image.memory(
                inline,
                fit: fit,
                height: height,
                width: width,
                // Already in memory — nothing to cache, nothing to fade in.
                errorBuilder: (ctx, _, __) => _fallback(ctx),
              )
            : CachedNetworkImage(
                imageUrl: url,
                fit: fit,
                height: height,
                width: width,
                // The builders get their own context — the placeholder tints come
                // from the theme, so they cannot be resolved once up here.
                placeholder: (ctx, _) => _shimmer(ctx),
                errorWidget: (ctx, _, __) => _fallback(ctx),
                fadeInDuration: const Duration(milliseconds: 220),
              );

    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: child);
    }
    return child;
  }

  /// Bytes of a base64 `data:` URI, or null when [url] is an ordinary address.
  ///
  /// Returns null rather than throwing on a malformed payload, so a corrupt
  /// avatar falls through to the network path and then to the fallback instead
  /// of taking the screen down.
  static Uint8List? _decodeDataUri(String url) {
    if (!url.startsWith('data:')) return null;
    final comma = url.indexOf(',');
    if (comma < 0 || !url.substring(0, comma).contains(';base64')) return null;
    try {
      return base64Decode(url.substring(comma + 1));
    } on FormatException {
      return null;
    }
  }

  Widget _shimmer(BuildContext context) => Container(
        height: height,
        width: width,
        color: backgroundColor ?? context.colors.primarySurface,
        child: const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primaryLight,
            ),
          ),
        ),
      );

  Widget _fallback(BuildContext context) => Container(
        height: height,
        width: width,
        color: backgroundColor ?? context.colors.primarySoft,
        child: const Center(
          child:
              Icon(Icons.eco_rounded, color: AppColors.primaryLight, size: 34),
        ),
      );
}

import 'package:flutter/material.dart';

import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';

/// Placeholder blocks shown while a section is loading.
///
/// These used to be private to `home_screen.dart`, so every other screen fell
/// back to a bare spinner and the app had two different loading languages.
/// Anything that can predict its own layout should use these instead.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.height = 100,
    this.width,
    this.radius = AppRadius.md,
  });

  final double height;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: context.colors.hairline,
          borderRadius: BorderRadius.circular(radius),
        ),
      );
}

/// Horizontal strip of tiles — stands in for the home category rail.
class SkeletonRow extends StatelessWidget {
  const SkeletonRow({
    super.key,
    this.itemCount = 5,
    this.itemSize = 70,
    this.padding = const EdgeInsets.all(AppSpacing.md),
  });

  final int itemCount;
  final double itemSize;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: itemCount,
        separatorBuilder: (_, __) => AppSpacing.hMd,
        itemBuilder: (_, __) => SkeletonBox(
          height: itemSize,
          width: itemSize,
          radius: AppRadius.xl,
        ),
      );
}

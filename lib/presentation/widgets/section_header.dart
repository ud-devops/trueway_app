import 'package:flutter/material.dart';

import '../../core/design_system/app_icons.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.onSeeAll,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: context.colors.primarySoft,
                borderRadius: AppRadius.rMd,
              ),
              child: Icon(icon, size: 19, color: context.colors.primaryDark),
            ),
            AppSpacing.hSm,
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.h3),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(subtitle!, style: context.text.bodySm),
                  ),
              ],
            ),
          ),
          if (onSeeAll != null)
            GestureDetector(
              onTap: onSeeAll,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  children: [
                    Text('See all',
                        style: context.text.buttonSm.copyWith(color: context.colors.primaryDark),),
                    const SizedBox(width: 2),
                    Icon(AppIcons.caretRight, size: 13, color: context.colors.primaryDark),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

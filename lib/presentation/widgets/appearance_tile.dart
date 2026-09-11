import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/design_system/app_icons.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../providers/theme_provider.dart';
import 'surfaces.dart';

/// Appearance picker: System / Light / Dark.
///
/// One row — an icon, the label, and a chip naming the current mode — that
/// opens a sheet with all three choices. It used to be a `SegmentedButton`
/// showing all three inline, which was the one row in the Account list built
/// differently from every menu row around it; this now reads like the rest of
/// the screen and still offers exactly the same three choices.
///
/// Three explicit choices rather than a switch, because "follow the device" is
/// the default and a two-state toggle cannot express it — a user who flips a
/// switch off has no way back to system-follows.
class AppearanceTile extends ConsumerWidget {
  const AppearanceTile({super.key});

  static const _options = <(ThemeMode, String, IconData)>[
    (ThemeMode.system, 'System', Symbols.brightness_auto),
    (ThemeMode.light, 'Light', AppIcons.sun),
    (ThemeMode.dark, 'Dark', AppIcons.moon),
  ];

  static (String, IconData) _display(ThemeMode mode) {
    for (final (value, label, icon) in _options) {
      if (value == mode) return (label, icon);
    }
    return (_options.first.$2, _options.first.$3); // unreachable
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final (label, icon) = _display(mode);

    return AppCard(
      elevated: true,
      onTap: () => _openPicker(context, ref, mode),
      padding: MenuRowMetrics.padding,
      border: MenuRowMetrics.outline(context),
      child: Row(
        children: [
          // Bare, like the menu rows below it — this tile sits directly above
          // them and a tinted disc here would be the only one left on the
          // screen. The badge's width is kept so its label lines up with
          // theirs.
          SizedBox(
            width: MenuRowMetrics.badge,
            height: MenuRowMetrics.badge,
            child: Align(
              alignment: Alignment.centerLeft,
              // Outlined and flush left, matching the menu rows directly
              // below — see the note on `_MenuRow`'s icon.
              child: Icon(
                icon,
                size: 20,
                // Same weight as the menu rows below — see `_iconWeight` in
                // account_screen.dart.
                weight: 400,
                color: context.colors.primaryDark,
              ),
            ),
          ),
          AppSpacing.hSm,
          // Same step as the menu labels underneath, so the two do not read as
          // different kinds of row.
          Expanded(
            child: Text(
              'Appearance',
              style: context.text.bodySm.copyWith(color: context.colors.ink),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
            decoration: BoxDecoration(
              color: context.colors.surfaceAlt,
              borderRadius: AppRadius.rPill,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label.toUpperCase(),
                  style: context.text.caption.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  AppIcons.caretDown,
                  size: 18,
                  weight: 300,
                  color: context.colors.muted,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openPicker(
    BuildContext context,
    WidgetRef ref,
    ThemeMode current,
  ) async {
    final selected = await showModalBottomSheet<ThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Appearance', style: sheetContext.text.h3),
              ),
            ),
            for (final (value, label, icon) in _options)
              ListTile(
                leading: Icon(
                  icon,
                  weight: 300,
                  color: sheetContext.colors.primaryDark,
                ),
                title: Text(label),
                trailing: value == current
                    ? Icon(
                        Icons.check_rounded,
                        color: sheetContext.colors.primaryDark,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, value),
              ),
          ],
        ),
      ),
    );
    if (selected != null) {
      await ref.read(themeModeProvider.notifier).set(selected);
    }
  }
}

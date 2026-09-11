import 'package:flutter/material.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_icons.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/app_typography.dart';
import '../../core/design_system/theme_context.dart';
import '../../data/models/category_model.dart';
import 'app_network_image.dart';

/// Height of the pinned strip: search bar + category tabs.
const double kStickySearchHeight = 62;

/// The tab strip at the default text scale.
///
/// 38 icon + 4 + two lines of 11px at 1.2 + 4 + 2.5 underline, rounded up.
/// Raised from 74 when the label was allowed to wrap: the old value fitted one
/// line, and at 74 a second line was clipped.
const double kStickyTabsHeight = 88;

/// [kStickyTabsHeight] grown for the OS text scale.
///
/// The strip is a fixed-height box around real text, so at the accessibility
/// sizes the label outgrows it and Flutter paints the yellow-and-black overflow
/// stripes. That was already true of the single-line label at 2x — 38 + 4 + 32
/// + 4 + 2.5 is 80.5 against a box of 74 — and wrapping to two lines only made
/// it arrive sooner.
///
/// Capped at 2x for the same reason the greeting is: past that the tabs would
/// take the whole viewport, and the label ellipsises rather than pushing on.
double stickyTabsHeight(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(11) / 11;
  return kStickyTabsHeight * scale.clamp(1.0, 2.0);
}

/// Height of the greeting row that scrolls away above the pinned strip.
const double kHomeGreetingHeight = 64;

/// Search field + category tabs, used as a [SliverAppBar.bottom] so it pins
/// beneath the status bar as the greeting scrolls away.
///
/// It has to be a `PreferredSizeWidget` rather than a
/// [SliverPersistentHeaderDelegate]: a bare persistent header pins to the very
/// top of the viewport and slides underneath the system status bar. SliverAppBar
/// adds `MediaQuery.padding.top` to its own extent, so the strip stops at the
/// right place on notched and punch-hole devices without hardcoding an inset.
class HomeStickyHeader extends StatelessWidget implements PreferredSizeWidget {
  const HomeStickyHeader({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.onCategorySelected,
    required this.onSearchTap,
    this.showTabs = true,
    this.tabsHeight = kStickyTabsHeight,
  });

  final List<Category> categories;

  /// null == the "All" tab.
  final int? selectedId;

  final ValueChanged<int?> onCategorySelected;
  final VoidCallback onSearchTap;
  final bool showTabs;

  /// Height of the tab strip, which the host computes so it can account for the
  /// OS text scale — see [stickyTabsHeight].
  ///
  /// [preferredSize] is a getter with no [BuildContext], so a strip that sizes
  /// itself from `MediaQuery` cannot report its own height. Passing it in is how
  /// the greeting above already solves the same problem.
  final double tabsHeight;

  @override
  Size get preferredSize => Size.fromHeight(
        kStickySearchHeight + (showTabs ? tabsHeight : 0),
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: kStickySearchHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: HomeSearchField(onTap: onSearchTap),
          ),
        ),
        if (showTabs)
          SizedBox(
            height: tabsHeight,
            child: _CategoryTabs(
              categories: categories,
              selectedId: selectedId,
              onSelected: onCategorySelected,
            ),
          ),
      ],
    );
  }
}

/// Tappable search affordance. Navigates to the search screen rather than
/// accepting input inline, matching the existing behaviour.
class HomeSearchField extends StatelessWidget {
  const HomeSearchField({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: context.colors.surfaceAlt,
          borderRadius: AppRadius.rPill,
          border: Border.all(color: context.colors.line),
        ),
        child: Row(
          children: [
            Icon(AppIcons.search, color: context.colors.muted, size: 20),
            AppSpacing.hSm,
            Expanded(
              child: Text(
                'Search for atta, dal, spices and more',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.body.copyWith(color: context.colors.faint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontally scrolling category tabs, with "All" pinned first.
class _CategoryTabs extends StatefulWidget {
  const _CategoryTabs({
    required this.categories,
    required this.selectedId,
    required this.onSelected,
  });

  final List<Category> categories;
  final int? selectedId;
  final ValueChanged<int?> onSelected;

  @override
  State<_CategoryTabs> createState() => _CategoryTabsState();
}

class _CategoryTabsState extends State<_CategoryTabs> {
  final _controller = ScrollController();

  static const _tabWidth = 76.0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _CategoryTabs old) {
    super.didUpdateWidget(old);
    if (old.selectedId != widget.selectedId) _scrollSelectedIntoView();
  }

  /// Keeps the active tab visible when selection changes from elsewhere, and
  /// when tapping a tab near the edge of the strip.
  void _scrollSelectedIntoView() {
    if (!_controller.hasClients) return;
    final index = widget.selectedId == null
        ? 0
        : widget.categories.indexWhere((c) => c.id == widget.selectedId) + 1;
    if (index < 0) return;

    final target = (index * _tabWidth) - (_tabWidth * 1.5);
    _controller.animateTo(
      target.clamp(0, _controller.position.maxScrollExtent),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      // +1 for the leading "All" tab.
      itemCount: widget.categories.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return _Tab(
            label: 'All',
            icon: AppIcons.grid,
            selected: widget.selectedId == null,
            onTap: () => widget.onSelected(null),
          );
        }
        final category = widget.categories[i - 1];
        return _Tab(
          label: category.name,
          imageUrl: category.displayImage,
          icon: AppIcons.leaf,
          selected: widget.selectedId == category.id,
          onTap: () => widget.onSelected(category.id),
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.imageUrl,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final tint = selected ? context.colors.primaryDark : context.colors.muted;

    return SizedBox(
      width: 76,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.rMd,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 38,
              height: 38,
              child: imageUrl != null
                  ? Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: context.colors.surfaceAlt,
                        border: Border.all(
                          color: selected ? AppColors.primary : context.colors.line,
                          width: selected ? 1.5 : 1,
                        ),
                      ),
                      // Clips the image to the circle. `cover` rather than
                      // `contain` so the photo fills the disc — contained
                      // images leave wedges of empty background at the edges.
                      clipBehavior: Clip.antiAlias,
                      child: AppNetworkImage(
                        url: imageUrl!,
                        fit: BoxFit.cover,
                      ),
                    )
                  : Icon(icon, size: 24, color: tint),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              // Two lines at 11px, not one at 12. The tab is 76dp wide and
              // "Wheat & Wheat Flour" needs roughly 115dp at caption size, so
              // on one line it ellipsised to "Wheat & …" no matter how small
              // the type got — the name only fits if it is allowed to wrap.
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: context.text.caption.copyWith(
                  fontSize: 11,
                  height: 1.2,
                  color: tint,
                  fontWeight:
                      selected ? AppTypography.emphasis : AppTypography.regular,
                ),
              ),
            ),
            const SizedBox(height: 4),
            // Underline marks the active tab, as in the reference design.
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 2.5,
              width: selected ? 34 : 0,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

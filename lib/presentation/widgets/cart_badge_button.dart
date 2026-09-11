import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_icons.dart';
import '../../core/design_system/theme_context.dart';
import '../providers/server_cart_provider.dart';

class CartBadgeButton extends ConsumerWidget {
  const CartBadgeButton({super.key, this.onTap, this.color});

  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(cartCountProvider);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          onPressed: onTap ?? () => context.push('/cart'),
          // The same glyph the bottom nav's Cart tab uses. It used to be
          // `shopping_bag_outlined` here and `Symbols.shopping_cart` there, so
          // the cart changed shape depending on which screen you were on.
          icon: Icon(AppIcons.cart, color: color ?? context.colors.ink),
        ),
        if (count > 0)
          Positioned(
            right: 4,
            top: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              constraints: const BoxConstraints(minWidth: 18),
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: context.colors.surface, width: 1.5),
              ),
              child: Text(
                count > 99 ? '99+' : '$count',
                textAlign: TextAlign.center,
                style: context.text.overline.copyWith(color: Colors.white, fontSize: 10),
              ),
            ),
          ),
      ],
    );
  }
}

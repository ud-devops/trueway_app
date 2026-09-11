import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_icons.dart';
import '../providers/server_cart_provider.dart';
import 'cart/cart_screen.dart';
import 'categories/categories_screen.dart';
import 'home/home_screen.dart';
import 'orders/orders_screen.dart';
import 'profile/account_screen.dart';

class MainNavigationScreen extends ConsumerStatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  ConsumerState<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends ConsumerState<MainNavigationScreen> {
  int _index = 0;

  static const _tabs = [
    HomeScreen(),
    CategoriesScreen(),
    CartScreen(showBack: false),
    OrdersScreen(),
    AccountScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final count = ref.watch(cartCountProvider);

    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: _icon(AppIcons.home, false),
            selectedIcon: _icon(AppIcons.home, true),
            label: 'Home',
          ),
          NavigationDestination(
            icon: _icon(AppIcons.grid, false),
            selectedIcon: _icon(AppIcons.grid, true),
            label: 'Category',
          ),
          NavigationDestination(
            icon: _cartIcon(false, count),
            selectedIcon: _cartIcon(true, count),
            label: 'Cart',
          ),
          NavigationDestination(
            icon: _icon(AppIcons.orders, false),
            selectedIcon: _icon(AppIcons.orders, true),
            label: 'Orders',
          ),
          NavigationDestination(
            icon: _icon(AppIcons.user, false),
            selectedIcon: _icon(AppIcons.user, true),
            label: 'Account',
          ),
        ],
      ),
    );
  }

  Icon _icon(IconData icon, bool active) =>
      Icon(icon, fill: active ? 1 : 0, weight: active ? 600 : 400);

  Widget _cartIcon(bool active, int count) => Badge(
        isLabelVisible: count > 0,
        backgroundColor: AppColors.accent,
        label: Text('$count'),
        child: _icon(AppIcons.cart, active),
      );
}

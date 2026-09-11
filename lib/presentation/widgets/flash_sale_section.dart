import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../data/models/home_sections.dart';
import '../providers/home_providers.dart';
import 'product_card.dart';
import 'product_carousel.dart';

/// The flash-sale rail on the home feed.
///
/// ## Draws nothing unless there is a live sale
///
/// No heading, no skeleton, no empty state. `GET /ecommerce/flash-sales`
/// answers `data: []` on this store — no sale has ever been configured — so the
/// common case is *absent*, and a section that reserves space for something
/// that never arrives is worse than one that appears when it does.
///
/// ⚠ The populated shape is **source-derived, not observed**: it comes from
/// `FlashSaleController::formatFlashSale` and `FlashSaleProductResource`, since
/// there has never been live data to probe. Everything here treats a missing or
/// odd field as "skip the row", not as an error.
class FlashSaleSection extends ConsumerWidget {
  const FlashSaleSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sales = ref.watch(flashSalesProvider).valueOrNull ?? const [];
    if (sales.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final sale in sales) _FlashSaleRail(sale: sale),
      ],
    );
  }
}

class _FlashSaleRail extends StatelessWidget {
  const _FlashSaleRail({required this.sale});

  final FlashSale sale;

  /// Room under the ordinary card for the progress bar and "N left".
  static const double _stockLineHeight = 26;

  @override
  Widget build(BuildContext context) {
    // `isLive` is already true here (the provider filters), but a sale can tick
    // over while the screen is open — the countdown reports that itself rather
    // than the rail vanishing mid-scroll.
    final sellable = sale.products.where((p) => !p.isSoldOut).toList();
    final products = sellable.isEmpty ? sale.products : sellable;
    final width = MediaQuery.sizeOf(context).width;

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            child: Row(
              children: [
                const Icon(Icons.bolt_rounded,
                    color: AppColors.accent, size: 22,),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    sale.name.isEmpty ? 'Flash sale' : sale.name,
                    style: context.text.h3,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                AppSpacing.hSm,
                FlashSaleCountdown(endsAt: sale.endsAt),
              ],
            ),
          ),
          AppSpacing.vSm,
          SizedBox(
            // The same metrics the other home rails use, plus room for the
            // stock line this variant adds under the name. Deriving the size
            // rather than fixing it is what keeps the tiles the same shape as
            // Best sellers and Trending on every screen width.
            height:
                CarouselMetrics.cardHeight(context, width) + _stockLineHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              itemCount: products.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(width: CarouselMetrics.spacing),
              // The **ordinary** card, with the sale's stock line added. This
              // used to be a bespoke flash-sale card, and it read as a
              // different kind of product sitting among the other rails.
              itemBuilder: (_, i) => ProductCard(
                product: products[i].product,
                width: CarouselMetrics.cardWidth(width),
                flashSale: products[i],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ticking "Ends in 02:14:09".
///
/// Rebuilds once a second and **stops on its own** once the sale is over, so a
/// finished sale does not keep a timer alive behind a static "Ended" label.
class FlashSaleCountdown extends StatefulWidget {
  const FlashSaleCountdown({super.key, required this.endsAt});

  final DateTime? endsAt;

  @override
  State<FlashSaleCountdown> createState() => _FlashSaleCountdownState();
}

class _FlashSaleCountdownState extends State<FlashSaleCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(FlashSaleCountdown old) {
    super.didUpdateWidget(old);
    if (old.endsAt != widget.endsAt) _start();
  }

  void _start() {
    _timer?.cancel();
    if (widget.endsAt == null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (_left <= Duration.zero) _timer?.cancel();
    });
  }

  Duration get _left {
    final end = widget.endsAt;
    if (end == null) return Duration.zero;
    final left = end.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `end_date` arrives without an offset and is parsed as UTC; if it were
    // ever unparseable there is no honest countdown to show, so none is shown.
    if (widget.endsAt == null) return const SizedBox.shrink();

    final left = _left;
    if (left <= Duration.zero) {
      return Text(
        'Ended',
        style: context.text.caption.copyWith(color: context.colors.muted),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.colors.accentSoft,
        borderRadius: AppRadius.rPill,
      ),
      child: Text(
        'Ends in ${formatCountdown(left)}',
        style: context.text.overline.copyWith(color: AppColors.accent),
      ),
    );
  }
}

/// `2d 03h` past a day, `02:14:09` under one.
///
/// Days are spelled out rather than folded into the hours field: a bare
/// "50:14:09" reads as a broken clock.
String formatCountdown(Duration left) {
  if (left.inDays >= 1) {
    return '${left.inDays}d ${(left.inHours % 24).toString().padLeft(2, '0')}h';
  }
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(left.inHours)}:${two(left.inMinutes % 60)}:'
      '${two(left.inSeconds % 60)}';
}

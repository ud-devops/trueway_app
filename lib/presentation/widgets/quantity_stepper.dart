import 'package:flutter/material.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';

class QuantityStepper extends StatelessWidget {
  const QuantityStepper({
    super.key,
    required this.quantity,
    required this.onIncrement,
    required this.onDecrement,
    this.dense = false,
    this.filled = true,
    this.busy = false,
  });

  final int quantity;

  /// Null disables the control. Cart mutations go to the server one at a time —
  /// a queued second write is how a cart gets wiped — so the stepper is
  /// disabled while one is in flight rather than allowed to race it.
  final VoidCallback? onIncrement;
  final VoidCallback? onDecrement;
  final bool dense;
  final bool filled;

  /// This line's write is in flight.
  ///
  /// The quantity is replaced by a spinner in the same fixed-width slot, and
  /// both buttons stop accepting taps. Nothing else changes: the pill keeps its
  /// size, its colour and its position, because the customer is looking
  /// straight at it and a control that jumps reads as a mis-tap.
  ///
  /// **Per line, never the cart's global `busy`.** Ask
  /// `ServerCartState.isBusyLine`; the global flag is true for every row at
  /// once, which is how one tap used to animate the whole basket.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final size = dense ? 30.0 : 38.0;
    // Faded only when there is genuinely nothing to do. A busy stepper is
    // working, not unavailable, and the spinner already says so — dimming it as
    // well would tell the customer their tap was refused.
    final disabled =
        !busy && onIncrement == null && onDecrement == null;
    final bg = filled ? AppColors.primary : Colors.transparent;
    final fg = filled ? Colors.white : AppColors.primary;

    return Container(
      decoration: BoxDecoration(
        color: disabled ? bg.withValues(alpha: 0.55) : bg,
        borderRadius: AppRadius.rMd,
        border: filled ? null : Border.all(color: AppColors.primary, width: 1.4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _btn(Icons.remove_rounded, busy ? null : onDecrement, size, fg),
          SizedBox(
            width: dense ? 26 : 34,
            child: busy
                ? Center(
                    child: SizedBox(
                      key: const Key('stepper-busy'),
                      width: dense ? 12 : 16,
                      height: dense ? 12 : 16,
                      child: CircularProgressIndicator(
                        strokeWidth: dense ? 1.6 : 2,
                        color: fg,
                      ),
                    ),
                  )
                : Text(
                    '$quantity',
                    textAlign: TextAlign.center,
                    style: (dense ? context.text.buttonSm : context.text.button)
                        .copyWith(color: fg),
                  ),
          ),
          _btn(Icons.add_rounded, busy ? null : onIncrement, size, fg),
        ],
      ),
    );
  }

  Widget _btn(IconData icon, VoidCallback? onTap, double size, Color fg) => InkWell(
        onTap: onTap,
        borderRadius: AppRadius.rMd,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: dense ? 16 : 20, color: fg),
        ),
      );
}

/// Compact "ADD" pill that swaps to a stepper once the item is in the cart.
class AddToCartControl extends StatelessWidget {
  const AddToCartControl({
    super.key,
    required this.quantity,
    required this.onAdd,
    required this.onIncrement,
    required this.onDecrement,
    this.width = 92,
  });

  final int quantity;
  final VoidCallback onAdd;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final double width;

  @override
  Widget build(BuildContext context) {
    if (quantity <= 0) {
      return SizedBox(
        width: width,
        height: 34,
        child: OutlinedButton(
          onPressed: onAdd,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 34),
            side: const BorderSide(color: AppColors.primary, width: 1.4),
            shape: const RoundedRectangleBorder(borderRadius: AppRadius.rMd),
          ),
          child: Text('ADD',
              style: context.text.buttonSm.copyWith(color: AppColors.primary),),
        ),
      );
    }
    return SizedBox(
      width: width,
      child: QuantityStepper(
        quantity: quantity,
        onIncrement: onIncrement,
        onDecrement: onDecrement,
        dense: true,
      ),
    );
  }
}

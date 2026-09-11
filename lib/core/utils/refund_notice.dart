/// What the app promises about money coming back, in one place.
///
/// Two screens say it — a cancelled order and a submitted return — and they
/// must not drift, because this is a commitment the shop has to keep.
///
/// ## Why it is not one sentence
///
/// The account's own history says why. Across 100 live orders:
///
/// ```
/// payment_method: razorpay 92, cod 8
/// payment_status: completed 84, refunded 10, pending 6
/// ```
///
/// * **COD** money arrived as cash, so "back to your original payment method"
///   would be describing a route that does not exist.
/// * **`pending`** means nothing was ever taken. Promising a refund there is
///   promising to return money the customer never paid.
/// * A **return** is a *request*. The team can reject it or ask for more —
///   `resubmit` is a real status on this backend — so a refund window quoted at
///   submission time would be a promise nobody has made yet.
library;

/// The window itself, so the number lives once.
const String kRefundWindow = '5–7 business days';

abstract final class RefundNotice {
  /// An online payment, refunded the way it came.
  static const String toOriginalMethod =
      'Refunds reach your original payment method in $kRefundWindow.';

  /// Cash on delivery: the money came as cash, so the route back is not the
  /// "original payment method" and this deliberately does not claim it is.
  static const String processed =
      'Your refund will be processed in $kRefundWindow.';

  /// The shop has already sent the money back. `payment_status: refunded` is
  /// a real state — 10 of the account's 100 orders sit in it — and it means
  /// *issued*, not *landed*: the bank still takes its own few days, so the
  /// window is still the useful half of the sentence.
  static const String issued =
      'Refunded. It can take up to $kRefundWindow to reach your account.';

  // A fourth sentence lived here for a submitted return — "Once approved, your
  // refund follows in 5-7 business days" — shown as a toast. The toast is gone
  // (the window belongs on the page, not in a four-second flash) and the return
  // detail screen has no refund line yet, so the copy went with its only
  // caller rather than sitting here unused.
}

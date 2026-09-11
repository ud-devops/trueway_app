import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../data/models/order.dart';
import '../../providers/order_provider.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/state_views.dart';
import '../../widgets/surfaces.dart';
// `formatOrderDate` lives with the orders list, which owns the app's one
// rendering of an order date — the summary must not invent a second.
import 'orders_screen.dart';

/// The order summary, in the shape a customer already knows from Amazon.
///
/// ## Why this screen exists
///
/// The invoice is a **delivery document** in this shop: `_InvoiceButton` is
/// offered only once the parcel has arrived, because the PDF the server renders
/// is the tax invoice for a completed sale. That left everything before
/// delivery with no printable record at all — a customer who wanted to check
/// what they had ordered, where it was going and what they had been charged had
/// to read it off a screen built for tracking.
///
/// So this is what stands in until then. It is deliberately *not* an invoice
/// and never claims to be one: no invoice number, no tax breakup presented as a
/// statutory document, and nothing to download. It is the order, restated.
///
/// ## What the reference layout asks for that this backend cannot answer
///
/// Two lines of the Amazon format have no data behind them here, verified live
/// on 2026-09-01 against `GET /ecommerce/orders/{id}`:
///
///   * **"Arriving Thursday."** The order payload carries `shipping_status`,
///     `shipping_method`, `shipping_option` and `shipping_company_name` — and
///     no arrival date of any kind. The items block is therefore headed by the
///     shipment's real status and courier rather than by a date the app would
///     be inventing. A wrong arrival date is the single worst thing a summary
///     like this could say.
///   * **"Sold by …"** `products[]` has no `store_name`; [OrderLine.storeName]
///     parses one when a future payload sends it, and the line is simply
///     absent until then.
///
/// Both are noted rather than faked. Everything else — placed date, order
/// number, ship-to, payment method, and every figure in the money column — is
/// a field the server sent.
class OrderSummaryScreen extends ConsumerWidget {
  const OrderSummaryScreen({super.key, required this.orderId});

  final int orderId;

  /// The sheet's width, on every screen.
  ///
  /// **Deliberately not responsive.** Reflowing the three columns into a stack
  /// on a phone is what stopped this reading as an invoice: an invoice is a
  /// sheet of paper of a known size, and one that rearranges itself to fit the
  /// window is a web page. So the document keeps its proportions and the phone
  /// scrolls sideways across it — the same thing you do with a paper bill that
  /// is wider than your hand.
  ///
  /// 720 is two phone-widths: wide enough that Ship to, Payment method and the
  /// money column sit side by side with the address unwrapped, narrow enough
  /// that one swipe crosses it.
  static const double _sheetWidth = 720;

  // ---- the sheet's type scale --------------------------------------------
  //
  // Set smaller than the rest of the app, and deliberately. A bill is read
  // closely and all at once — the eye goes down the column of figures rather
  // than across a screen — and the whole point of a fixed-width sheet is that
  // it reads as one piece of paper. At the app's ordinary sizes the document
  // sprawled and needed more scrolling in both directions than it had content.
  //
  // Named here rather than spelled out at each `Text`, because a document whose
  // sections are set at slightly different sizes stops looking printed.

  /// The document's own name, at the top. One step under the app's [h1] —
  /// large enough to title the page, small enough not to shout on a sheet the
  /// customer is holding at reading distance.
  static TextStyle _heading(BuildContext c) => c.text.h2;

  /// "Ship to", "Payment method", "Order Summary" — and the shipment's status
  /// over the items.
  static TextStyle _sectionTitle(BuildContext c) =>
      c.text.title.copyWith(fontSize: 13);

  /// Everything the document actually says: address lines, the payment method,
  /// a charge and its figure, a product's name.
  static TextStyle _line(BuildContext c) =>
      c.text.bodySm.copyWith(fontSize: 12, color: c.colors.body);

  /// Secondary to a line it sits under — the courier, the seller, the quantity,
  /// the payment's status.
  static TextStyle _quiet(BuildContext c) =>
      c.text.caption.copyWith(fontSize: 11, color: c.colors.muted);

  /// The figures that conclude something: the Grand Total, an item's price.
  static TextStyle _strong(BuildContext c) =>
      c.text.title.copyWith(fontSize: 13);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(orderDetailProvider(orderId));

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(title: const Text('Order Summary')),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, __) => AppErrorView(
          error: e,
          onRetry: () => ref.invalidate(orderDetailProvider(orderId)),
        ),
        data: (order) => _body(context, order),
      ),
    );
  }

  Widget _body(BuildContext context, Order order) {
    // Vertical outside, horizontal inside. The outer scroller hands the sheet
    // unbounded height so it can be as long as the order is; the inner one
    // hands it unbounded width so [_sheetWidth] is honoured rather than
    // squeezed into the phone.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: _sheetWidth,
          // ONE sheet. Everything the order is — who it is going to, how it
          // was paid for, what it cost and what is in it — inside a single
          // bordered box, the way it would be printed. Three separate cards
          // read as three unrelated things; a bill is one thing.
          child: AppCard(
            key: const Key('summary-sheet'),
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Order Summary', style: _heading(context)),
                AppSpacing.vSm,
                _placedLine(context, order),
                const Divider(height: AppSpacing.xl),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _addresses(context, order)),
                      AppSpacing.hMd,
                      Expanded(child: _payment(context, order)),
                      AppSpacing.hMd,
                      Expanded(child: _money(context, order)),
                    ],
                  ),
                ),
                const Divider(height: AppSpacing.xl),
                _shipment(context, order),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "Order placed 31 Aug 2026 | Order number SF10000330".
  ///
  /// One line with a rule between the two facts, exactly as the reference has
  /// it, and outside any card — it titles the document rather than being a
  /// section of it. Wraps to two lines on a narrow phone rather than shrinking,
  /// because these are the two things a customer reads the page for.
  Widget _placedLine(BuildContext context, Order order) {
    final style = _line(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpacing.sm,
      runSpacing: 2,
      children: [
        if (order.createdAt case final placed?) ...[
          Text('Order placed ${formatOrderDate(placed)}', style: style),
          SizedBox(
            height: 14,
            child: VerticalDivider(
              width: 1,
              thickness: 1,
              color: context.colors.line,
            ),
          ),
        ],
        Text(
          'Order number ${order.displayCode}',
          key: const Key('summary-order-number'),
          style: style,
        ),
      ],
    );
  }

  /// Where the parcel goes, and — when it is somewhere else — where the
  /// invoice goes.
  ///
  /// Stacked in one column rather than given a fourth of their own. They are
  /// the same kind of fact and they are read together ("is this going to the
  /// right place, and billed to the right one?"), and a fourth column would
  /// take the sheet past a single swipe on a phone for something most orders
  /// do not have.
  Widget _addresses(BuildContext context, Order order) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _block(
            context,
            key: const Key('summary-ship-to'),
            title: 'Ship to',
            child: order.shippingInfo == null
                // The shipping row is deleted outright for an order that needs
                // no shipping, so its absence is a real state, not a failure.
                ? Text(
                    'No delivery address on this order.',
                    style: _quiet(context),
                  )
                : _address(context, order.shippingInfo!),
          ),
          // Only when it is genuinely a different place. `billing_info` is
          // all-nulls on most orders and, when present, is usually the delivery
          // address again — printing that twice under two headings reads as two
          // addresses. [Order.hasSeparateBillingAddress] compares the parts a
          // customer would read, not field for field, because the two rows are
          // written at different moments and one can carry a landmark or an
          // email the other does not while naming the identical doorstep.
          if (order.hasSeparateBillingAddress) ...[
            AppSpacing.vMd,
            _block(
              context,
              key: const Key('summary-bill-to'),
              title: 'Bill to',
              child: _address(context, order.billingInfo!),
            ),
          ],
        ],
      );

  /// One address, a line per line — the way it is written on a parcel, and the
  /// way the reference prints it.
  ///
  /// [OrderContact.addressLines] builds those lines from the fields. This used
  /// to split [OrderContact.streetLine] on ", " instead, which shredded every
  /// street line that contains a comma of its own — "306, Ring Road" came out
  /// as two lines.
  Widget _address(BuildContext context, OrderContact to) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (to.name case final name? when name.isNotEmpty)
            Text(name, style: _line(context)),
          for (final line in to.addressLines)
            Text(line, style: _line(context)),
          if (to.phone case final phone? when phone.isNotEmpty)
            Text(phone, style: _line(context)),
        ],
      );

  Widget _payment(BuildContext context, Order order) => _block(
        context,
        key: const Key('summary-payment'),
        title: 'Payment method',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              // The server's own label ("Razorpay", "Cash on delivery"), not a
              // word of the app's choosing — the customer is checking this
              // against what they were charged.
              order.paymentMethod.display.isEmpty
                  ? 'Not recorded'
                  : order.paymentMethod.display,
              style: _line(context),
            ),
            if (order.paymentStatus.display.isNotEmpty)
              Text(
                order.paymentStatus.display,
                style: _quiet(context),
              ),
          ],
        ),
      );

  /// The money column.
  ///
  /// Every row is a field the server sent, and the Grand Total is `amount` —
  /// the figure actually charged — not a sum this screen performed. Where a
  /// term is missing from the payload it is left out rather than printed as
  /// zero: a fee of nothing and a fee the server did not mention are different
  /// things.
  ///
  /// The reference prints "Total:" and "Grand Total:" as two rows carrying the
  /// same figure — they differ there only when a gift card or promotion sits
  /// between them, which this shop has no concept of. One number under two
  /// names reads as a mistake, so only the one the customer was charged is
  /// printed.
  Widget _money(BuildContext context, Order order) {
    final subTotal = order.subTotalDisplay;
    final fee = order.paymentFeeDisplay;

    return _block(
      context,
      key: const Key('summary-money'),
      title: 'Order Summary',
      child: Column(
        children: [
          if (subTotal != null) _money2(context, 'Item(s) Subtotal', subTotal),
          if (order.shippingAmount != 0)
            _money2(context, 'Shipping', order.shippingDisplay),
          if (order.discountAmount > 0)
            _money2(
              context,
              order.couponCode == null
                  ? 'Discount'
                  : 'Discount (${order.couponCode})',
              '- ${order.discountDisplay}',
            ),
          if (order.taxAmount != 0)
            _money2(context, 'GST', '+ ${order.taxDisplay}'),
          if (fee != null && order.paymentFee != 0)
            _money2(context, 'Payment fee', fee),
          _money2(context, 'Grand Total', order.amountDisplay, bold: true),
        ],
      ),
    );
  }

  /// A money line: "Label:" left, figure right.
  ///
  /// The colon is the reference's, and it is doing something — it turns a
  /// two-column table into a list of statements, which is how the rest of the
  /// document reads. No colour on the discount either: this page is a record,
  /// and the green that marks a saving on the basket would be selling
  /// something here.
  Widget _money2(
    BuildContext context,
    String label,
    String value, {
    bool bold = false,
  }) {
    final style = bold ? _strong(context) : _line(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: Text('$label:', style: style)),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Text(value, textAlign: TextAlign.end, style: style),
          ),
        ],
      ),
    );
  }

  /// The items, headed by where the parcel has actually got to.
  ///
  /// The reference heads this "Arriving Thursday". There is no arrival date in
  /// this backend's order payload, so the shipment's own status stands in — a
  /// fact rather than a guess. See the class doc.
  Widget _shipment(BuildContext context, Order order) {
    final status = order.shippingStatus.display;
    final courier = order.shippingCompanyName;

    return Column(
      key: const Key('summary-items'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          status.isEmpty ? 'Your order' : status,
          style: _sectionTitle(context),
        ),
        if (courier != null && courier.isNotEmpty)
          Text(courier, style: _quiet(context)),
        AppSpacing.vMd,
        for (final line in order.lines) ...[
          if (line != order.lines.first) AppSpacing.vMd,
          _item(context, line),
        ],
      ],
    );
  }

  /// Image left, then title, seller and price stacked beside it.
  ///
  /// The price sits under the title rather than off at the right margin, which
  /// is the reference's arrangement and the reason its rows read as entries
  /// rather than as another table.
  ///
  /// The title is **not** rendered as a link. It is one in the reference, where
  /// it opens the product; here `products[]` carries a product id and an
  /// absolute `product_url`, and the app's product route is keyed by slug — so
  /// there is nothing reliable to open. Blue text that does nothing when tapped
  /// is a worse copy of the format than black text that is honest about it.
  Widget _item(BuildContext context, OrderLine line) => Row(
        key: ValueKey('summary-item-${line.id}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: AppNetworkImage(
              url: line.imageUrl,
              borderRadius: AppRadius.rSm,
              fit: BoxFit.cover,
            ),
          ),
          AppSpacing.hSm,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.name, style: _line(context)),
                // Absent until the payload carries `store_name` — see the class
                // doc. Never a placeholder: an invented seller on a document
                // like this is worse than no seller.
                if (line.storeName case final seller? when seller.isNotEmpty)
                  Text(
                    'Sold by: $seller',
                    style: _quiet(context),
                  ),
                const SizedBox(height: 4),
                Text(line.totalDisplay, style: _strong(context)),
                if (line.quantity > 1)
                  Text(
                    'Qty ${line.quantity}',
                    style: _quiet(context),
                  ),
              ],
            ),
          ),
        ],
      );

  /// One labelled block of the summary.
  Widget _block(
    BuildContext context, {
    required Key key,
    required String title,
    required Widget child,
  }) =>
      Column(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: _sectionTitle(context)),
          AppSpacing.vXs,
          child,
        ],
      );
}

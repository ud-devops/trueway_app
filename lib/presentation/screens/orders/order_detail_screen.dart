import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/platform/invoice_opener.dart';
import '../../../core/utils/price_utils.dart';
import '../../../data/models/order.dart';
import '../../../data/models/order_return.dart';
import '../../../data/repositories/order_repository.dart' show InvoicePdf;
import '../../providers/core_providers.dart';
import '../../providers/order_provider.dart';
import '../../providers/return_provider.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/skeletons.dart';
import '../../widgets/state_views.dart';
import '../../widgets/bill_details.dart';
import '../../widgets/order_timeline.dart';
import '../../widgets/surfaces.dart';
import 'orders_screen.dart';
import '../../widgets/app_message.dart';

/// Downloads the invoice PDF and opens it in the device's PDF viewer.
///
/// `GET /invoice/download` is the **only** invoice route usable from the app —
/// the `url` on `GET /invoice` points at a session-guarded web route that a
/// bearer token cannot open.
///
/// ## Opened, not shared
///
/// The bytes used to go straight to the platform share sheet, which asked the
/// customer to choose an app before they could see anything — a "Download
/// invoice" button that produced a contact list. Now the file is written to
/// app-private storage and handed to whatever opens PDFs, so one tap shows the
/// invoice.
///
/// The share sheet survives as the **fallback**, for the one case that needs
/// it: a device with no PDF viewer at all. The download has already succeeded
/// by then, and offering nothing would throw away a working file.
///
/// ## Why it is slow, and why the UI says so
///
/// The server re-renders the PDF through dompdf on **every** request with no
/// cache (~10 s cold, measured by the backend team), hence the long timeout, a
/// spinner in place of the icon, and a "Preparing your invoice…" note.
class _InvoiceButton extends ConsumerStatefulWidget {
  const _InvoiceButton({required this.orderId});

  final int orderId;

  @override
  ConsumerState<_InvoiceButton> createState() => _InvoiceButtonState();
}

class _InvoiceButtonState extends ConsumerState<_InvoiceButton> {
  bool _busy = false;

  Future<void> _download() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Preparing your invoice…'),
        duration: Duration(seconds: 12),
      ),
    );

    try {
      final pdf = await ref
          .read(orderRepositoryProvider)
          .downloadInvoice(widget.orderId);
      if (!mounted) return;
      messenger.hideCurrentSnackBar();

      final result = await ref.read(invoiceOpenerProvider).open(pdf);
      if (!mounted || result == InvoiceOpenResult.opened) return;

      // Nothing on the device opens a PDF. The file is real and already
      // written, so the share sheet is a way out rather than a dead end.
      if (result == InvoiceOpenResult.noViewer) {
        context.showAlertSnack(
          'No PDF app found on this device — choose where to save it.',
        );
        await _share(pdf);
        return;
      }
      context.showAlertSnack('The invoice could not be opened.');
    } on ApiException catch (e) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      // A 404 here is routine — the invoice row is created by a queued listener
      // on order placement, so a very fresh order may not have one yet.
      context.showAlertSnack(
        e.kind == ApiErrorKind.notFound
            ? 'The invoice for this order is not ready yet.'
            : e.message,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The fallback: hand the bytes to the platform share sheet so a customer
  /// with no PDF viewer can still put the file somewhere.
  Future<void> _share(InvoicePdf pdf) => SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              pdf.bytes,
              mimeType: InvoiceOpener.pdfMimeType,
              name: pdf.fileName,
            ),
          ],
          // `XFile.fromData` has no path, so the name has to be given here or
          // the sheet offers the file as an unnamed blob.
          fileNameOverrides: [pdf.fileName],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: _busy ? null : _download,
      tooltip: 'Download invoice',
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.receipt_long_rounded),
    );
  }
}

/// One order in full: what was bought, where it is going, what it cost, and the
/// two actions the server says are still available.
///
/// This is the only place that calls `GET /ecommerce/orders/{id}` — the list
/// row has no line items, no discount and no capability flags, so Cancel and
/// Confirm delivery can only be offered here.
class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({super.key, required this.orderId});

  final int orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(orderDetailProvider(orderId));

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: Text(detail.valueOrNull?.displayCode ?? 'Order'),
        actions: [
          // Two conditions, and both are the server's own.
          //
          // `isInvoiceAvailable` needs an `ec_invoices` row and a non-canceled
          // order, so a cancelled one gets no button rather than one that 404s.
          //
          // `isDelivered` is the shop's rule: the invoice is a delivery
          // document here, not an order confirmation, so it is offered only
          // once the parcel has arrived. See [Order.isDelivered] for why a
          // completed order counts as delivered — the backend sets the one from
          // the other.
          if (detail.valueOrNull case final order?
              when order.isInvoiceAvailable && order.isDelivered)
            _InvoiceButton(orderId: orderId)
          // Not delivered, so there is no invoice to offer — and until now
          // nothing in its place. The summary is what a customer wanting a
          // record of the order before it arrives actually needs, and it is
          // deliberately not called an invoice: it carries no invoice number
          // and nothing to download, because the tax document for this sale
          // does not exist yet.
          else if (detail.valueOrNull != null)
            IconButton(
              key: const Key('order-summary-action'),
              tooltip: 'Order summary',
              icon: const Icon(Symbols.receipt_long, weight: 300),
              onPressed: () => context.push('/order/$orderId/summary'),
            ),
        ],
      ),
      body: detail.when(
        loading: () => const _DetailSkeleton(),
        error: (e, __) => AppErrorView(
          error: e,
          onRetry: () => ref.invalidate(orderDetailProvider(orderId)),
        ),
        data: (order) => RefreshIndicator(
          onRefresh: () => _reread(ref),
          child: _OrderBody(order: order),
        ),
      ),
      bottomNavigationBar: detail.valueOrNull == null
          ? null
          : _Actions(order: detail.valueOrNull!),
    );
  }

  /// Pull-to-refresh, awaited.
  ///
  /// `onRefresh: () async => ref.invalidate(...)` completes on the same frame
  /// it is called, so the spinner retracted before the server had answered —
  /// the gesture claimed to have refreshed the order while the read was still
  /// in flight. Awaiting the provider's own future ties the two together. A
  /// failed re-read is already reported by the provider (its AsyncError renders
  /// [AppErrorView]), so the throw is swallowed here rather than escaping into
  /// [RefreshIndicator], which would surface it as an uncaught async error.
  Future<void> _reread(WidgetRef ref) async {
    ref.invalidate(orderDetailProvider(orderId));
    try {
      await ref.read(orderDetailProvider(orderId).future);
    } on Object {
      // Rendered by the provider's error branch.
    }
  }
}

class _OrderBody extends ConsumerStatefulWidget {
  const _OrderBody({required this.order});

  final Order order;

  @override
  ConsumerState<_OrderBody> createState() => _OrderBodyState();
}

class _OrderBodyState extends ConsumerState<_OrderBody> {
  /// How many item rows a folded list shows.
  ///
  /// Two is enough to recognise the order without the card pushing the bill —
  /// the part most customers open this screen for — off the first screenful.
  static const int _collapsedItems = 2;

  bool _allItems = false;
  bool _historyOpen = false;
  bool _returnsOpen = false;

  Order get order => widget.order;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xl,
      ),
      children: [
        _header(context),
        AppSpacing.vSm,
        _items(context),
        ..._returnedItems(context),
        AppSpacing.vSm,
        _bill(context),
        AppSpacing.vSm,
        _addresses(context),
        // Last, and only when there is one. The list endpoint omits `histories`
        // entirely, so a screen opened from a cached list row simply has no
        // timeline until the detail read lands.
        // Folded by default. The timeline is the longest block on the screen
        // and it is a *record* — useful when something looks wrong, in the way
        // of the bill and the address the rest of the time.
        if (order.hasHistory) ...[
          AppSpacing.vSm,
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  key: const Key('order-history-toggle'),
                  onTap: () => setState(() => _historyOpen = !_historyOpen),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Order history', style: context.text.title),
                      ),
                      Icon(
                        _historyOpen
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        color: context.colors.muted,
                      ),
                    ],
                  ),
                ),
                if (_historyOpen) ...[
                  AppSpacing.vXs,
                  OrderTimeline(
                    histories: order.histories,
                    // The toggle above already says "Order history".
                    showHeading: false,
                    shippingCompanyName: order.shippingCompanyName,
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ---- Header: code, date, the three statuses ----------------------------
  Widget _header(BuildContext context) => AppCard(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Legacy codes already carry the '#'; never add one.
                      Text(order.displayCode, style: context.text.h3),
                      if (order.createdAt != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Placed ${formatOrderDate(order.createdAt!, withTime: true)}',
                          style: context.text.caption,
                        ),
                      ],
                    ],
                  ),
                ),
                AppSpacing.hXs,
                OrderStatusChip(status: order.status),
              ],
            ),
            AppSpacing.vXs,
            // Each status is a {value,label} object and any of them can be the
            // degenerate {value: null, label: ""} form, which renders nothing.
            Wrap(
              spacing: AppSpacing.xxs,
              runSpacing: AppSpacing.xxs,
              children: [
                _pair(context, 'Payment', order.paymentStatus),
                _pair(context, 'Shipping', order.shippingStatus),
              ],
            ),
            if (order.paymentMethod.display.isNotEmpty) ...[
              AppSpacing.vXs,
              Text('Paid by ${order.paymentMethod.display}',
                  style: context.text.bodySm,),
            ],
            if (order.shippingMethod.display.isNotEmpty)
              Text('Shipped via ${order.shippingMethod.display}',
                  style: context.text.bodySm,),
            // Beside the status, as the website does. The status chip can only
            // say "Cancelled"; this is the part that says why, including the
            // customer's own note when they left one.
            if ((order.cancellationMessage ?? '').isNotEmpty)
              OrderCancellationNote(message: order.cancellationMessage!),
            // The money question, where the customer can actually sit and read
            // it. `hasRefundDue` is what keeps it off a delivered order the
            // customer is perfectly happy with, and off one that was never
            // paid for.
            if (order.hasRefundDue)
              if (order.refundNotice case final notice?)
                OrderRefundNote(message: notice),
          ],
        ),
      );

  Widget _pair(BuildContext context, String label, StatusValue status) {
    if (status.isEmpty || status.display.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: context.text.caption),
        OrderStatusChip(status: status, dense: true),
      ],
    );
  }

  // ---- Line items --------------------------------------------------------
  Widget _items(BuildContext context) {
    if (order.lines.isEmpty) {
      return AppCard(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Text(
          // Real on this dataset: orders whose products were hard-deleted come
          // back with an empty products array.
          'The items on this order are no longer available to show.',
          style: context.text.bodySm,
        ),
      );
    }

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            order.lines.length == 1 ? '1 item' : '${order.lines.length} items',
            style: context.text.title,
          ),
          AppSpacing.vXs,
          for (final line in _shownLines)
            Padding(
              key: ValueKey('order-line-${line.id}'),
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: _line(context, line),
            ),
          if (_foldableItems)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('order-items-toggle'),
                onPressed: () => setState(() => _allItems = !_allItems),
                child: Text(
                  _allItems
                      ? 'Show less'
                      : 'Show all ${order.lines.length} items',
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Whether the list is long enough to be worth folding.
  ///
  /// A three-item order folding to two saves one row and costs a tap, so the
  /// button only appears once there is something real behind it.
  bool get _foldableItems => order.lines.length > _collapsedItems + 1;

  List<OrderLine> get _shownLines => _foldableItems && !_allItems
      ? order.lines.take(_collapsedItems).toList()
      : order.lines;

  /// What went back, as its own card under the items.
  ///
  /// ## Why it is not a badge on the line any more
  ///
  /// It was, and it did not work: the badge lived inside the line's own text
  /// column, so on a long product name — which is most of this catalogue — the
  /// row grew a third line and the badge ran into the next item's thumbnail.
  /// A return is also its own event with its own quantity, price and status;
  /// squeezing that onto a row that is already saying "10 × ₹599.00" asks one
  /// row to answer two questions.
  ///
  /// Folded by default, like the history. Most orders have no returns at all,
  /// and the ones that do are usually being opened for the bill.
  ///
  /// Nothing here is computed — quantity, price and refund are the return
  /// request's own fields.
  List<Widget> _returnedItems(BuildContext context) {
    final requests = [
      for (final request in ref.watch(returnsForOrderProvider(order.id)))
        if (request.countsAgainstOrder) request,
    ];
    if (requests.isEmpty) return const [];

    final lines = [
      for (final request in requests)
        for (final item in request.items)
          (item: item, stage: request.stageLabel),
    ];
    if (lines.isEmpty) return const [];

    final units = lines.fold<int>(0, (sum, l) => sum + l.item.quantity);

    return [
      AppSpacing.vSm,
      AppCard(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              key: const Key('order-returned-toggle'),
              onTap: () => setState(() => _returnsOpen = !_returnsOpen),
              child: Row(
                children: [
                  Icon(
                    Icons.keyboard_return_rounded,
                    size: 18,
                    color: context.colors.primaryDark,
                  ),
                  AppSpacing.hXs,
                  Expanded(
                    child: Text(
                      units == 1 ? '1 item returned' : '$units items returned',
                      style: context.text.title
                          .copyWith(color: context.colors.primaryDark),
                    ),
                  ),
                  Icon(
                    _returnsOpen
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: context.colors.muted,
                  ),
                ],
              ),
            ),
            if (_returnsOpen) ...[
              AppSpacing.vXs,
              for (final line in lines)
                Padding(
                  key: ValueKey('returned-item-${line.item.id}'),
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: _returnedLine(context, line.item, line.stage),
                ),
            ],
          ],
        ),
      ),
    ];
  }

  Widget _returnedLine(
    BuildContext context,
    OrderReturnItem item,
    String stage,
  ) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: AppNetworkImage(
              url: item.imageUrl,
              borderRadius: AppRadius.rSm,
              fit: BoxFit.cover,
            ),
          ),
          AppSpacing.hSm,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySm,
                ),
                Text(
                  '${item.quantity} × ${PriceUtils.format(item.price)}'
                  '${stage.isEmpty ? '' : ' · $stage'}',
                  style:
                      context.text.caption.copyWith(color: context.colors.muted),
                ),
              ],
            ),
          ),
          AppSpacing.hXs,
          // The server's own refund figure for this item — prorated by the
          // backend across the order's discount, so it is not qty × price.
          Text(
            PriceUtils.format(item.refundAmount),
            style: context.text.bodySm
                .copyWith(color: context.colors.savings),
          ),
        ],
      );

  Widget _line(BuildContext context, OrderLine line) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: context.colors.surfaceAlt,
              borderRadius: AppRadius.rSm,
              border: Border.all(color: context.colors.hairline),
            ),
            clipBehavior: Clip.antiAlias,
            child: AppNetworkImage(url: line.imageUrl, fit: BoxFit.cover),
          ),
          AppSpacing.hSm,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.body,
                ),
                if ((line.variantLabel ?? '').isNotEmpty)
                  Text(line.variantLabel!, style: context.text.caption),
                Text(
                  '${line.quantity} × ${line.unitPriceDisplay}',
                  style: context.text.caption,
                ),
              ],
            ),
          ),
          AppSpacing.hXs,
          // The server's own per-line total, formatted by the server. Never a
          // local quantity × price, which disagrees on the lines that carry a
          // negative amount.
          Text(line.totalDisplay, style: context.text.title),
      ],
    );
  }

  // ---- Bill --------------------------------------------------------------
  //
  // Every figure here is the server's. Nothing is derived.
  //
  // The rows can only be *made* to sum once the server sends `sub_total` and
  // `payment_fee`; both were absent from the order resources until recently, and
  // their absence is exactly why orders 14, 15 and 17 each showed a Total ₹10.00
  // above what their own rows added to. Both are now serialized on this backend
  // (verified live on orders 282, 14 and 52), so the breakdown is the normal
  // case — but the app still has to be correct against a server that has not
  // been upgraded, which is what [Order.hasFullBreakdown] gates.
  Widget _bill(BuildContext context) {
    // [Order.hasFullBreakdown] is the whole gate. Only when the server sent
    // BOTH `sub_total` and `payment_fee` can rows be drawn that add up to
    // `amount`, so on anything less they are withheld entirely rather than
    // printed not adding up.
    //
    // The fallback subtotal ([Order.subTotal] summing the line items) is not a
    // rescue here: it cannot see `payment_fee`, which is exactly the term whose
    // absence made orders 14, 15 and 17 show a Total ₹10.00 above their own
    // rows. Order 14's lines total ₹477.00 against a charged ₹487.00 — drawing
    // "Items ₹477.00 / Total ₹487.00" and explaining the gap in a caption is
    // still a bill the customer can see does not work, so it is not drawn.
    final itemised = order.hasFullBreakdown;
    final paymentFee = order.paymentFeeDisplay;

    return OrderBillCard(
      terms: BillTerms(
        // Withheld together: half a breakdown is worse than none.
        itemTotal: itemised ? order.subTotalDisplay : null,
        discount: itemised && order.discountAmount > 0
            ? order.discountDisplay
            : null,
        couponCode: order.couponCode,
        shipping:
            itemised && order.shippingAmount != 0 ? order.shippingDisplay : null,
        tax: itemised && order.taxAmount != 0 ? '+ ${order.taxDisplay}' : null,
        // Only when the server actually sent it AND it is non-zero. A null fee
        // means "not serialized", which is not a fee of nothing.
        paymentFee: itemised && paymentFee != null && order.paymentFee != 0
            ? paymentFee
            : null,
        total: order.amountDisplay,
        savings: itemised ? order.discountDisplay : null,
      ),
      footnotes: [
        // No rows were drawn, so the total stands alone: say why rather than
        // leave the customer to wonder what the figure is made of.
        if (!itemised)
          Text(
            'The total above is the amount charged. Some charges are not '
            'itemised here.',
            style: context.text.caption,
          )
        else if (!order.breakdownReconciles)
          // Every term arrived and the rows still miss the charged figure —
          // order 52 computes 708.16 against 708.17, because a ₹44.63 discount
          // scales the tax. That is a server-side rounding artifact, so the
          // charged figure is named as the one that governs rather than the
          // rows being quietly nudged to agree with it.
          Text(
            'The total above is the amount charged, and is what applies if it '
            'differs from the rows above.',
            style: context.text.caption,
          ),
        // A coupon with no discount row to sit in — the server sent a code but
        // no amount. Rare, and still worth saying, because the customer
        // applied one and would otherwise see no trace of it.
        if (order.couponCode != null && order.discountAmount <= 0)
          Text('Coupon ${order.couponCode}', style: context.text.caption),
        if (order.discountDescription != null)
          Text(order.discountDescription!, style: context.text.caption),
      ],
    );
  }

  // ---- Addresses ---------------------------------------------------------
  /// The delivery address, and the billing address when it is a different one.
  ///
  /// Each block is gated on **its own** data. This used to open with
  /// `if (shipping == null) return SizedBox.shrink()`, which meant an order
  /// whose shipping block came back empty showed no addresses at all — the
  /// billing address the customer had typed at checkout included. The two come
  /// from two different `ec_order_addresses` rows written at two different
  /// moments in `OrderHelper::checkAndCreateOrderAddress`, and either can be
  /// missing on its own:
  ///
  ///   * the shipping row is **deleted** when the order needs no shipping
  ///     (`is_save_order_shipping_address`, computed from the products, not
  ///     sent by the app);
  ///   * the billing row is skipped whenever its own validation fails, and
  ///     `storeOrderBillingAddress` swallows that — the order still succeeds.
  ///
  /// So "no shipping row" is not evidence about billing, and hiding one for
  /// the other's absence loses information the customer gave us.
  Widget _addresses(BuildContext context) {
    final shipping = order.shippingInfo;
    final billing = order.billingInfo;
    final separateBilling = order.hasSeparateBillingAddress;

    // Nothing to show only when there is genuinely nothing.
    if (shipping == null && billing == null) return const SizedBox.shrink();

    return AppCard(
      key: const Key('order-addresses'),
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (shipping != null) ...[
            Text('Delivery address', style: context.text.title),
            AppSpacing.vXs,
            _contact(context, shipping),
          ],
          // Its own heading only when it is a different doorstep.
          // `billing_info` is all-nulls on 82 of 90 orders and, when present,
          // is usually the delivery address again — printing that twice under
          // two headings reads as two addresses.
          if (separateBilling) ...[
            if (shipping != null) const Divider(height: AppSpacing.lg),
            Text(
              'Billing address',
              key: const Key('order-billing-address'),
              style: context.text.title,
            ),
            AppSpacing.vXs,
            _contact(context, billing!),
          ] else if (shipping != null) ...[
            AppSpacing.vXs,
            Text('Billed to the same address.', style: context.text.caption),
          ],
        ],
      ),
    );
  }

  Widget _contact(BuildContext context, OrderContact contact) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (contact.name != null)
            Text(contact.name!, style: context.text.body),
          if (contact.phone != null)
            Text(contact.phone!, style: context.text.bodySm),
          // streetLine now includes city and state — the order resources
          // resolve them (`city_name`/`state_name`), so this reads
          // "306, Ring Road, Ahmedabad, Gujarat, 382415, India". A row that
          // still carries a raw id is skipped by value, not by endpoint.
          if (contact.streetLine.isNotEmpty)
            Text(contact.streetLine, style: context.text.bodySm),
        ],
      );
}

/// The bottom bar. Only renders what the *server* says is possible — both
/// flags come from the detail response and default to false everywhere else.
class _Actions extends ConsumerWidget {
  const _Actions({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!order.canBeCanceled &&
        !order.canConfirmDelivery &&
        !order.canBeReturned) {
      return const SizedBox.shrink();
    }
    final busy = ref.watch(orderActionsProvider(order.id));

    // Stacked, never side by side: two labelled buttons in a Row overflow a
    // 320dp screen by 33px before any accessibility text scale is applied.
    // The confirming action leads; cancelling is the destructive one and sits
    // below it.
    return BottomActionBar(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (order.canConfirmDelivery)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: busy ? null : () => _confirm(context, ref),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                ),
                child: busy
                    ? const _ButtonSpinner(color: Colors.white)
                    : const Text('Confirm delivery'),
              ),
            ),
          // A delivered order can be returned but not cancelled, so these are
          // mutually exclusive in practice — `canBeReturned` needs `completed`
          // status, `canBeCanceled` needs a pre-shipment one.
          if (order.canBeReturned) ...[
            if (order.canConfirmDelivery) AppSpacing.vXs,
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('order-request-return'),
                onPressed: () => context.push('/order/${order.id}/return'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                ),
                icon: const Icon(Icons.assignment_return_rounded, size: 20),
                label: const Text('Claim & Refund'),
              ),
            ),
          ],
          if (order.canBeCanceled &&
              (order.canConfirmDelivery || order.canBeReturned))
            AppSpacing.vXs,
          if (order.canBeCanceled)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: busy ? null : () => _cancel(context, ref),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: const BorderSide(color: AppColors.error),
                  minimumSize: const Size(0, 48),
                ),
                child: busy
                    ? const _ButtonSpinner(color: AppColors.error)
                    : const Text('Cancel order'),
              ),
            ),
        ],
      ),
    );
  }

  /// Cancelling is irreversible — there is no un-cancel route — so it asks for
  /// a reason first and the dialog's confirm button is the destructive colour.
  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final choice = await showDialog<({String reason, String? description})>(
      context: context,
      builder: (_) => _CancelDialog(code: order.displayCode),
    );
    if (choice == null || !context.mounted) return;

    try {
      final ran = await ref.read(orderActionsProvider(order.id).notifier).cancel(
            reason: choice.reason,
            description: choice.description,
          );
      if (!context.mounted) return;
      // A write skipped because one was already in flight never reached the
      // server; claiming success here would be the screen inventing a result.
      if (!ran) return;
      // Deliberately just the headline. The refund window lives on the order
      // itself ([OrderRefundNote]) rather than here: a SnackBar is four seconds
      // long, and "when does my money come back?" is the question a customer
      // reopens the order to answer — not one they read once, in passing, at
      // the moment they are least likely to be paying attention.
      context.showSuccessSnack('Order ${order.displayCode} has been cancelled.');
    } on ApiException catch (e) {
      if (!context.mounted) return;
      // Refusals arrive as HTTP 200 + error:true ("You cannot cancel this
      // order") and carry the server's own sentence.
      context.showErrorSnack(e, context: 'orderDetail.cancel');
    } catch (e) {
      if (!context.mounted) return;
      context.showErrorSnack(e, context: 'orderDetail.cancel');
    }
  }

  Future<void> _confirm(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm delivery?'),
        content: const Text(
          'Only confirm once the order is in your hands. This tells the shop '
          'the delivery is complete.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not yet'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(minimumSize: const Size(88, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, received'),
          ),
        ],
      ),
    );
    if (!(ok ?? false) || !context.mounted) return;

    try {
      final ran = await ref
          .read(orderActionsProvider(order.id).notifier)
          .confirmDelivery();
      if (!context.mounted) return;
      if (!ran) return;
      context.showSuccessSnack('Thanks — delivery confirmed.');
    } on ApiException catch (e) {
      if (!context.mounted) return;
      context.showErrorSnack(e, context: 'orderDetail.confirmDelivery');
    } catch (e) {
      if (!context.mounted) return;
      context.showErrorSnack(e, context: 'orderDetail.confirmDelivery');
    }
  }
}

/// Asks for the reason the cancel route requires.
///
/// `cancellation_reason` is mandatory, and `cancellation_reason_description` is
/// mandatory (min 3 chars) when the reason is `other` — enforced here so the
/// customer is not made to discover it through a 422.
class _CancelDialog extends StatefulWidget {
  const _CancelDialog({required this.code});

  final String code;

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  CancellationReason _reason = orderCancellationReasons.first;
  final _description = TextEditingController();
  String? _error;

  bool get _needsDescription => _reason.value == otherCancellationReason;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _description.text.trim();
    if (_needsDescription && text.length < 3) {
      setState(() => _error = 'Tell us a little more (at least 3 characters).');
      return;
    }
    Navigator.pop<({String reason, String? description})>(
      context,
      (reason: _reason.value, description: text.isEmpty ? null : text),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cancel this order?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Order ${widget.code} will be cancelled. This cannot be undone — '
              'you would need to place a new order.',
              style: context.text.bodySm,
            ),
            AppSpacing.vSm,
            DropdownButtonFormField<String>(
              key: const Key('cancel-reason'),
              initialValue: _reason.value,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Reason'),
              items: [
                for (final r in orderCancellationReasons)
                  DropdownMenuItem(value: r.value, child: Text(r.label)),
              ],
              onChanged: (value) => setState(() {
                _reason = orderCancellationReasons
                    .firstWhere((r) => r.value == value);
                _error = null;
              }),
            ),
            if (_needsDescription) ...[
              AppSpacing.vXs,
              TextField(
                key: const Key('cancel-description'),
                controller: _description,
                maxLength: 255,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'What happened?',
                  errorText: _error,
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Keep order'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.error,
            minimumSize: const Size(88, 44),
          ),
          onPressed: _submit,
          child: const Text('Cancel order'),
        ),
      ],
    );
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 18,
        width: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      );
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: const [
          AppCard(
            padding: EdgeInsets.all(AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(height: 18, width: 140, radius: AppRadius.sm),
                AppSpacing.vXs,
                SkeletonBox(height: 12, width: 180, radius: AppRadius.sm),
                AppSpacing.vSm,
                SkeletonBox(height: 20, width: 220, radius: AppRadius.pill),
              ],
            ),
          ),
          AppSpacing.vSm,
          AppCard(
            padding: EdgeInsets.all(AppSpacing.sm),
            child: Column(
              children: [
                SkeletonBox(height: 52, radius: AppRadius.sm),
                AppSpacing.vXs,
                SkeletonBox(height: 52, radius: AppRadius.sm),
              ],
            ),
          ),
          AppSpacing.vSm,
          AppCard(
            padding: EdgeInsets.all(AppSpacing.sm),
            child: Column(
              children: [
                SkeletonBox(height: 12, radius: AppRadius.sm),
                AppSpacing.vXs,
                SkeletonBox(height: 12, radius: AppRadius.sm),
                AppSpacing.vXs,
                SkeletonBox(height: 12, width: 160, radius: AppRadius.sm),
              ],
            ),
          ),
        ],
      );
}

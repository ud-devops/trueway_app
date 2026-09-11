import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/platform/invoice_opener.dart';
import 'package:trueway_farms/data/models/order.dart';
import 'package:trueway_farms/data/repositories/order_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/screens/orders/order_detail_screen.dart';

/// The "Download invoice" button.
///
/// It used to hand the PDF straight to the platform share sheet, which asked
/// the customer to pick an app — a contact list where an invoice should have
/// been. It now writes the file and opens it in a PDF viewer, and only falls
/// back to sharing when the device genuinely has nothing that reads a PDF.

Map<String, dynamic> _order({
  bool invoiceAvailable = true,
  // Delivered by default: the shop only offers the invoice once the parcel has
  // arrived, so an undelivered order has no button to test the download with.
  // `delivered` is the shipment's own status — the backend turns it into a
  // completed order (`OrderHelper::shippingStatusDelivered`), and
  // `Order.isDelivered` accepts either.
  bool delivered = true,
}) => {
      'id': 286,
      'code': 'SF10000286',
      'status': {'value': 'processing', 'label': 'Processing'},
      if (delivered)
        'shipping_status': {'value': 'delivered', 'label': 'Delivered'},
      'amount': '1798.00',
      'created_at': '2026-08-11T21:47:35+05:30',
      'is_invoice_available': invoiceAvailable,
      // Both point at session-guarded web routes. The button must ignore them.
      'invoice_links': {
        'print': 'https://dev.truewayerp.com/customer/orders/print/286?type=print',
        'download': 'https://dev.truewayerp.com/customer/orders/print/286',
      },
      'products': <Map<String, dynamic>>[],
    };

final _pdf = InvoicePdf(
  bytes: Uint8List.fromList('%PDF-1.4 fake'.codeUnits),
  fileName: 'invoice-INV-156.pdf',
);

class _FakeOrderRepository implements OrderRepository {
  _FakeOrderRepository({required this.payload, this.error, this.gate});

  final Map<String, dynamic> payload;

  /// Thrown by [downloadInvoice] instead of answering.
  final ApiException? error;

  /// Holds the download open so the in-flight UI can be inspected.
  ///
  /// Without it the fake answers in the same microtask and the busy state is
  /// gone before the first `pump` — the spinner would be untestable and the
  /// "no second tap" guard would look broken when it is not.
  final Completer<void>? gate;

  final List<int> downloads = [];

  @override
  Future<Order> order(int id) async => Order.fromJson(payload);

  @override
  Future<InvoicePdf> downloadInvoice(int id, {bool forPreview = false}) async {
    downloads.add(id);
    if (gate != null) await gate!.future;
    final e = error;
    if (e != null) throw e;
    return _pdf;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeOpener implements InvoiceOpener {
  _FakeOpener([this.result = InvoiceOpenResult.opened]);

  final InvoiceOpenResult result;
  final List<InvoicePdf> opened = [];

  @override
  Future<InvoiceOpenResult> open(InvoicePdf pdf) async {
    opened.add(pdf);
    return result;
  }
}

Future<(_FakeOrderRepository, _FakeOpener)> _pump(
  WidgetTester tester, {
  Map<String, dynamic>? payload,
  ApiException? error,
  InvoiceOpenResult openResult = InvoiceOpenResult.opened,
  Completer<void>? gate,
}) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final repo = _FakeOrderRepository(
    payload: payload ?? _order(),
    error: error,
    gate: gate,
  );
  final opener = _FakeOpener(openResult);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        orderRepositoryProvider.overrideWithValue(repo),
        // The real one writes a file and fires a platform intent. Neither
        // exists under the test binding, which is the whole reason the opener
        // is a seam rather than two lines in the button.
        invoiceOpenerProvider.overrideWithValue(opener),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: OrderDetailScreen(orderId: 286),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return (repo, opener);
}

Finder get _button => find.byTooltip('Download invoice');

Future<void> _tapAndSettle(WidgetTester tester) async {
  await tester.tap(_button);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('the button', () {
    testWidgets('is offered when the server says an invoice exists',
        (tester) async {
      await _pump(tester);
      expect(_button, findsOneWidget);
    });

    // `is_invoice_available` needs an `ec_invoices` row and a non-cancelled
    // order. A button that 404s is worse than no button.
    testWidgets('is absent when it does not', (tester) async {
      await _pump(tester, payload: _order(invoiceAvailable: false));
      expect(_button, findsNothing);
    });
  });

  group('a successful download', () {
    testWidgets('opens the PDF instead of offering a share sheet',
        (tester) async {
      final (repo, opener) = await _pump(tester);

      await _tapAndSettle(tester);

      expect(repo.downloads, [286]);
      expect(opener.opened.single.fileName, 'invoice-INV-156.pdf');
      expect(opener.opened.single.bytes, _pdf.bytes);
    });

    // The server names the file, and the invoice code is unrelated to the
    // order — order 286 is invoice INV-156.
    testWidgets('keeps the name the server gave it', (tester) async {
      final (_, opener) = await _pump(tester);

      await _tapAndSettle(tester);

      expect(opener.opened.single.fileName, isNot(contains('286')));
    });

    testWidgets('says nothing once the viewer has it', (tester) async {
      await _pump(tester);

      await _tapAndSettle(tester);

      expect(find.textContaining('could not be opened'), findsNothing);
      expect(find.textContaining('No PDF app'), findsNothing);
    });
  });

  group('while it is downloading', () {
    // dompdf re-renders on every request with no cache — ~10 s cold. A button
    // that looks idle for ten seconds gets tapped again.
    testWidgets('shows a spinner and says what is happening', (tester) async {
      final gate = Completer<void>();
      await _pump(tester, gate: gate);

      await tester.tap(_button);
      await tester.pump();

      expect(find.text('Preparing your invoice…'), findsOneWidget);
      expect(
        find.descendant(
          of: _button,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      gate.complete();
      await _tapAndSettle(tester);
    });

    testWidgets('refuses a second tap', (tester) async {
      final gate = Completer<void>();
      final (repo, _) = await _pump(tester, gate: gate);

      await tester.tap(_button);
      await tester.pump();
      await tester.tap(_button, warnIfMissed: false);
      await tester.pump();

      // Two taps, one request. dompdf takes ~10 s and a second render is not
      // free for anyone.
      expect(repo.downloads, hasLength(1));

      gate.complete();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    });
  });

  group('when the device has no PDF viewer', () {
    testWidgets('falls back to the share sheet rather than a dead end',
        (tester) async {
      await _pump(tester, openResult: InvoiceOpenResult.noViewer);

      await _tapAndSettle(tester);

      // The download already succeeded; throwing the bytes away would be the
      // one unrecoverable outcome.
      expect(find.textContaining('No PDF app found'), findsOneWidget);
    });

    testWidgets('a failure to open says so and shares nothing',
        (tester) async {
      await _pump(tester, openResult: InvoiceOpenResult.failed);

      await _tapAndSettle(tester);

      expect(find.textContaining('could not be opened'), findsOneWidget);
      expect(find.textContaining('No PDF app found'), findsNothing);
    });
  });

  group('when the download fails', () {
    // The `ec_invoices` row is written by a queued listener, so a very fresh
    // order can legitimately have none yet — and the live 404 body is
    // `{"message":"No query results for model [...Order]."}`, which is not
    // something to put in front of a customer.
    testWidgets('a 404 reads as "not ready", not as a fault', (tester) async {
      final (_, opener) = await _pump(
        tester,
        error: const ApiException(
          'Not found',
          kind: ApiErrorKind.notFound,
          statusCode: 404,
          serverMessage: 'No query results for model '
              '[Botble\\Ecommerce\\Models\\Order].',
        ),
      );

      await _tapAndSettle(tester);

      expect(
        find.text('The invoice for this order is not ready yet.'),
        findsOneWidget,
      );
      expect(find.textContaining('No query results'), findsNothing);
      expect(opener.opened, isEmpty);
    });

    testWidgets('any other failure shows the server\'s own message',
        (tester) async {
      final (_, opener) = await _pump(
        tester,
        error: const ApiException(
          'The invoice could not be generated.',
          kind: ApiErrorKind.server,
          statusCode: 500,
        ),
      );

      await _tapAndSettle(tester);

      expect(find.text('The invoice could not be generated.'), findsOneWidget);
      expect(opener.opened, isEmpty);
    });

    testWidgets('the button becomes tappable again', (tester) async {
      final (repo, _) = await _pump(
        tester,
        error: const ApiException('boom', kind: ApiErrorKind.server),
      );

      await _tapAndSettle(tester);
      await _tapAndSettle(tester);

      expect(repo.downloads, hasLength(2));
    });
  });

  // The shop's rule: the invoice is a delivery document. The download flow
  // above is only reachable once the parcel has arrived.
  testWidgets('is withheld until the order is delivered', (tester) async {
    await _pump(tester, payload: _order(delivered: false));

    expect(_button, findsNothing);
  });
}

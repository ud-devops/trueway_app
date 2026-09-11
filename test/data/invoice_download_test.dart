import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/repositories/order_repository.dart';

/// The invoice PDF — the one invoice route a mobile client can actually use.
///
/// `GET /orders/{id}/invoice` returns a link to `customer.invoices.generate_invoice`,
/// a web route behind a **session** guard, so a bearer token gets a redirect to
/// the storefront login page. `GET /orders/{id}/invoice/download` returns the
/// PDF bytes directly, and that is what this covers.

/// Serves raw bytes with the headers a real download carries.
class _PdfAdapter implements HttpClientAdapter {
  _PdfAdapter({
    this.disposition = 'attachment; filename=invoice-INV-97.pdf',
    this.statusCode = 200,
    this.body,
    this.jsonBody,
  });

  final String? disposition;
  final int statusCode;
  final List<int>? body;
  final Object? jsonBody;

  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);

    if (jsonBody != null) {
      return ResponseBody.fromString(
        jsonEncode(jsonBody),
        statusCode,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }

    return ResponseBody.fromBytes(
      body ?? _pdfBytes,
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/pdf'],
        if (disposition != null) 'content-disposition': [disposition!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A minimal but real PDF header, so the bytes are not just noise.
final List<int> _pdfBytes = utf8.encode('%PDF-1.4\n%âãÏÓ\ntrailer\n%%EOF');

Future<({OrderRepository repo, _PdfAdapter adapter})> _repo(
  _PdfAdapter adapter,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final dio = Dio()..httpClientAdapter = adapter;
  return (repo: OrderRepository(ApiClient(prefs: prefs, dio: dio)), adapter: adapter);
}

void main() {
  // -------------------------------------------------------------------------
  group('downloadInvoice', () {
    test('returns the PDF bytes, not a parsed body', () async {
      final h = await _repo(_PdfAdapter());

      final pdf = await h.repo.downloadInvoice(237);

      expect(pdf.bytes, isA<Uint8List>());
      expect(pdf.sizeBytes, _pdfBytes.length);
      // Really a PDF, not JSON that happened to decode.
      expect(utf8.decode(pdf.bytes.take(5).toList()), '%PDF-');
    });

    test('asks the download route, not the link route', () async {
      final h = await _repo(_PdfAdapter());

      await h.repo.downloadInvoice(237);

      expect(
        h.adapter.requests.single.path,
        '/ecommerce/orders/237/invoice/download',
      );
    });

    // The request must not be JSON-decoded, and it needs far longer than the
    // app-wide timeout: the server re-renders the PDF through dompdf on every
    // request with no cache — ~10 s on a cold render.
    test('requests bytes with a long receive timeout', () async {
      final h = await _repo(_PdfAdapter());

      await h.repo.downloadInvoice(237);

      final sent = h.adapter.requests.single;
      expect(sent.responseType, ResponseType.bytes);
      expect(
        sent.receiveTimeout!.inSeconds,
        greaterThanOrEqualTo(30),
        reason: 'a cold dompdf render was measured at ~10s',
      );
    });

    test('`type=print` asks for the inline variant', () async {
      final h = await _repo(_PdfAdapter());

      await h.repo.downloadInvoice(237, forPreview: true);

      expect(h.adapter.requests.single.queryParameters['type'], 'print');
    });

    test('an empty body is refused rather than shared as a broken file',
        () async {
      final h = await _repo(_PdfAdapter(body: const []));

      expect(
        () => h.repo.downloadInvoice(237),
        throwsA(isA<ApiException>()),
      );
    });

    // Routine, not a fault: the invoice row is created by a queued listener on
    // order placement, and cancelled orders never get one.
    test('a 404 arrives as a notFound ApiException', () async {
      final h = await _repo(_PdfAdapter(
        statusCode: 404,
        jsonBody: {'message': 'Not found'},
      ),);

      await expectLater(
        h.repo.downloadInvoice(237),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiErrorKind.notFound),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  group('the filename', () {
    // The invoice code is numbered independently of orders — order 131 is
    // invoice INV-97 — so it can only come from the server.
    test('comes from Content-Disposition', () async {
      final h = await _repo(_PdfAdapter());

      final pdf = await h.repo.downloadInvoice(131);

      expect(pdf.fileName, 'invoice-INV-97.pdf');
      expect(pdf.fileName, isNot(contains('131')));
    });

    test('handles a quoted filename', () async {
      final h = await _repo(_PdfAdapter(
        disposition: 'attachment; filename="invoice-INV-97.pdf"',
      ),);

      expect((await h.repo.downloadInvoice(131)).fileName,
          'invoice-INV-97.pdf',);
    });

    test('handles the RFC 5987 encoded form', () async {
      final h = await _repo(_PdfAdapter(
        disposition:
            "attachment; filename*=UTF-8''invoice%20INV-97.pdf",
      ),);

      expect((await h.repo.downloadInvoice(131)).fileName,
          'invoice INV-97.pdf',);
    });

    // Never derived from the order id — that would state an invoice code the
    // app cannot know. The fallback says "order" instead.
    test('falls back to the order id when the header is missing', () async {
      final h = await _repo(_PdfAdapter(disposition: null));

      final pdf = await h.repo.downloadInvoice(131);

      expect(pdf.fileName, 'invoice-order-131.pdf');
      expect(pdf.fileName, isNot(contains('INV')));
    });

    // A server-chosen path separator must not decide where the file lands.
    test('strips any directory component', () async {
      final h = await _repo(_PdfAdapter(
        disposition: 'attachment; filename="../../etc/invoice.pdf"',
      ),);

      expect((await h.repo.downloadInvoice(131)).fileName, 'invoice.pdf');
    });
  });
}

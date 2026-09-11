import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/repositories/order_repository.dart' show InvoicePdf;

/// What happened when the invoice was handed to the device.
enum InvoiceOpenResult {
  /// A PDF viewer took it. Nothing more to say to the customer.
  opened,

  /// The file was written, but the device has nothing that opens a PDF.
  ///
  /// Recoverable, and the caller should recover: the bytes are real and the
  /// share sheet can still put them somewhere useful.
  noViewer,

  /// The file could not be written or the platform refused it.
  failed,
}

/// Saves an invoice PDF and opens it in whatever the device uses for PDFs.
///
/// ## Why a class rather than two lines at the call site
///
/// It is the seam. Writing a file and asking the platform to open it cannot run
/// in a widget test — there is no file system plugin and no activity to hand an
/// intent to — so the screen depends on this type and a fake stands in. The
/// alternative was a screen no test could press the button on.
///
/// ## Where the file goes
///
/// `<app documents>/invoices/<server's filename>.pdf`. App-private on both
/// platforms, so no storage permission is involved on any Android version, and
/// `open_filex` hands Android a `FileProvider` URI rather than a bare `file://`
/// path (which would be a `FileUriExposedException` from Android 7).
///
/// The name is the server's — `invoice-INV-156.pdf` — so re-downloading the
/// same invoice overwrites its own file instead of piling up copies, and the
/// customer sees the same name the website gives them.
class InvoiceOpener {
  const InvoiceOpener();

  /// The subdirectory invoices are written to, relative to app documents.
  static const String directoryName = 'invoices';

  static const String pdfMimeType = 'application/pdf';

  /// Writes [pdf] and opens it. Never throws.
  ///
  /// A failure here is not worth an exception: the download already succeeded,
  /// the bytes are in hand, and the caller has a perfectly good fallback. What
  /// it needs is *which* failure, which is what [InvoiceOpenResult] carries.
  Future<InvoiceOpenResult> open(InvoicePdf pdf) async {
    File file;
    try {
      final root = await getApplicationDocumentsDirectory();
      final dir = Directory('${root.path}${Platform.pathSeparator}'
          '$directoryName');
      if (!dir.existsSync()) await dir.create(recursive: true);
      file = File('${dir.path}${Platform.pathSeparator}${pdf.fileName}');
      await file.writeAsBytes(pdf.bytes, flush: true);
    } catch (_) {
      return InvoiceOpenResult.failed;
    }

    try {
      final result = await OpenFilex.open(file.path, type: pdfMimeType);
      return switch (result.type) {
        ResultType.done => InvoiceOpenResult.opened,
        // Android 11+ hides apps this one has not declared an interest in, so
        // this also fires when the `<queries>` entry for `application/pdf` is
        // missing from the manifest — worth checking there before believing the
        // device really has no viewer.
        ResultType.noAppToOpen => InvoiceOpenResult.noViewer,
        _ => InvoiceOpenResult.failed,
      };
    } catch (_) {
      return InvoiceOpenResult.failed;
    }
  }
}

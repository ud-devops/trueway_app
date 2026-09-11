/// The tax-invoice block the web checkout collects, and the order stores.
///
/// ## What this replaced
///
/// The cart used to collect a bare GSTIN into `CheckoutState.gstin` and **send
/// it nowhere**. It validated, it rendered as "GSTIN: 27AAPFU0939F1Z5" on the
/// cart, and then it evaporated: no branch of `CheckoutRepository.placeOrder`
/// ever looked at it, so every order placed from this app carried no tax
/// information at all and no invoice could be raised against it.
///
/// ## The server's shape
///
/// `ec_order_tax_information` has exactly four columns the client fills, and
/// `CheckoutController::mobileCheckout` writes them wholesale:
///
/// ```php
/// if (EcommerceHelper::isDisplayTaxFieldsAtCheckoutPage() &&
///     $request->boolean('with_tax_information') &&
///     $request->has('tax_information')) {
///     $order->taxInformation()->create($request->input('tax_information'));
/// }
/// ```
///
/// All three conditions matter. `display_tax_fields_at_checkout_page` defaults
/// to **true**, so the block normally lands — but if the shop turns it off the
/// order still succeeds and the tax information is dropped without a word.
///
/// ## Rules
///
/// Taken from `CheckoutRequest::rules()`, which the mobile endpoint shares with
/// the web checkout — the same class, so these are not an approximation:
///
/// | field             | server rule                    |
/// |-------------------|--------------------------------|
/// | `company_name`    | string, min 3, max 120         |
/// | `company_address` | string, min 3, max 255         |
/// | `company_tax_code`| string, min 3, max 20          |
/// | `company_email`   | `EmailRule`                    |
///
/// The tax code is checked harder here than `min:3|max:20` — this shop is
/// Indian and the field is a GSTIN, so [isValidGstin]'s 15-character pattern
/// applies. That is stricter than the endpoint, which can never cause a 422; it
/// only refuses a code that would produce an unusable invoice. The column is 20
/// wide, so a valid GSTIN always fits.
library;

import '../../core/utils/validators.dart';

/// The server's field names, as they appear inside the body's `tax_information`
/// object and in a 422's `errors` bag (minus the `tax_information.` prefix).
abstract final class TaxField {
  static const String companyName = 'company_name';
  static const String companyAddress = 'company_address';
  static const String companyTaxCode = 'company_tax_code';
  static const String companyEmail = 'company_email';

  /// Every field, in the order the form presents them.
  static const List<String> all = [
    companyName,
    companyAddress,
    companyTaxCode,
    companyEmail,
  ];
}

/// A completed — or half-completed — tax-invoice block.
///
/// Immutable and trimmed on construction, so what [violations] judged is
/// exactly what [toJson] sends. Half-completed is a real state: the form holds
/// one of these while the customer is typing, and only a violation-free one is
/// ever attached to an order.
class TaxInformation {
  TaxInformation({
    required String companyName,
    required String companyAddress,
    required String companyTaxCode,
    required String companyEmail,
  })  : companyName = companyName.trim(),
        companyAddress = companyAddress.trim(),
        // Uppercased for the same reason the old dialog did it: a GSTIN is
        // conventionally upper case and the pattern only matches that way, so a
        // customer typing lower case should not be told their code is invalid.
        companyTaxCode = companyTaxCode.trim().toUpperCase(),
        companyEmail = companyEmail.trim();

  static final TaxInformation empty = TaxInformation(
    companyName: '',
    companyAddress: '',
    companyTaxCode: '',
    companyEmail: '',
  );

  final String companyName;
  final String companyAddress;

  /// The GSTIN.
  final String companyTaxCode;

  final String companyEmail;

  /// True when nothing has been entered — the ordinary case, and the one where
  /// the order goes out with no `tax_information` block at all.
  bool get isEmpty =>
      companyName.isEmpty &&
      companyAddress.isEmpty &&
      companyTaxCode.isEmpty &&
      companyEmail.isEmpty;

  bool get isNotEmpty => !isEmpty;

  /// Every rule this block breaks, keyed by [TaxField]. Empty means it is safe
  /// to attach to an order.
  ///
  /// All four fields are `required_if:with_tax_information,1` — there is no
  /// partial block. Attaching three of four would store a row the shop cannot
  /// raise an invoice from.
  Map<String, String> violations() {
    final problems = <String, String>{};

    if (companyName.isEmpty) {
      problems[TaxField.companyName] = 'Enter the company name';
    } else if (companyName.length < 3) {
      problems[TaxField.companyName] = 'Company name is too short';
    } else if (companyName.length > 120) {
      problems[TaxField.companyName] = 'Company name is too long';
    }

    if (companyAddress.isEmpty) {
      problems[TaxField.companyAddress] = 'Enter the company address';
    } else if (companyAddress.length < 3) {
      problems[TaxField.companyAddress] = 'Company address is too short';
    } else if (companyAddress.length > 255) {
      problems[TaxField.companyAddress] = 'Company address is too long';
    }

    if (companyTaxCode.isEmpty) {
      problems[TaxField.companyTaxCode] = 'Enter your GSTIN';
    } else if (!isValidGstin(companyTaxCode)) {
      problems[TaxField.companyTaxCode] =
          'Enter a valid 15-character GSTIN';
    }

    if (companyEmail.isEmpty) {
      problems[TaxField.companyEmail] = 'Enter the company email';
    } else if (!isValidEmail(companyEmail)) {
      problems[TaxField.companyEmail] = 'Enter a valid email address';
    }

    return problems;
  }

  bool get isValid => violations().isEmpty;

  /// The first problem, for a form that shows one message at a time.
  ///
  /// Ordered by [TaxField.all] rather than by map order so the message always
  /// names the field nearest the top of the form.
  static String? firstProblem(Map<String, String> problems) {
    for (final field in TaxField.all) {
      final message = problems[field];
      if (message != null) return message;
    }
    return problems.values.isEmpty ? null : problems.values.first;
  }

  /// The `tax_information` object of the checkout body.
  ///
  /// Exactly the four columns `ec_order_tax_information` fills. The controller
  /// passes this straight to `create()`, so an extra key would be a mass
  /// assignment against a model that does not expect it.
  Map<String, dynamic> toJson() => {
        TaxField.companyName: companyName,
        TaxField.companyAddress: companyAddress,
        TaxField.companyTaxCode: companyTaxCode,
        TaxField.companyEmail: companyEmail,
      };

  TaxInformation copyWith({
    String? companyName,
    String? companyAddress,
    String? companyTaxCode,
    String? companyEmail,
  }) =>
      TaxInformation(
        companyName: companyName ?? this.companyName,
        companyAddress: companyAddress ?? this.companyAddress,
        companyTaxCode: companyTaxCode ?? this.companyTaxCode,
        companyEmail: companyEmail ?? this.companyEmail,
      );

  @override
  bool operator ==(Object other) =>
      other is TaxInformation &&
      other.companyName == companyName &&
      other.companyAddress == companyAddress &&
      other.companyTaxCode == companyTaxCode &&
      other.companyEmail == companyEmail;

  @override
  int get hashCode =>
      Object.hash(companyName, companyAddress, companyTaxCode, companyEmail);

  @override
  String toString() => 'TaxInformation($companyTaxCode, $companyName)';
}

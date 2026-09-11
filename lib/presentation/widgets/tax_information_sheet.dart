import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../data/models/tax_information.dart';

/// What the tax-invoice sheet was closed with.
///
/// Three outcomes, and the difference between two of them matters: dismissing
/// the sheet leaves whatever was already attached alone, while *removing* takes
/// it off the order. Returning a bare `TaxInformation?` could not tell those
/// apart — null would have to mean both "unchanged" and "delete it".
@immutable
class TaxInformationSheetResult {
  const TaxInformationSheetResult._(this.information, this.removed);

  /// The customer filled the block in. Always violation-free: the sheet's save
  /// button does not enable otherwise.
  const TaxInformationSheetResult.saved(TaxInformation information)
      : this._(information, false);

  /// The customer took the tax details off the order.
  const TaxInformationSheetResult.removed() : this._(null, true);

  final TaxInformation? information;
  final bool removed;
}

/// Opens the GST invoice form. Resolves to null when it is dismissed.
///
/// `isScrollControlled` with a viewInsets-aware padding inside, because four
/// fields plus a phone keyboard is taller than the default half sheet.
Future<TaxInformationSheetResult?> showTaxInformationSheet(
  BuildContext context, {
  TaxInformation? initial,
}) =>
    showModalBottomSheet<TaxInformationSheetResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => TaxInformationSheet(initial: initial),
    );

/// The tax-invoice block the web checkout collects, as a form.
///
/// ## Why four fields and not one
///
/// The cart used to ask for a GSTIN alone. The order's tax row does not work
/// that way: `ec_order_tax_information` has `company_name`, `company_address`,
/// `company_tax_code` and `company_email`, all four are
/// `required_if:with_tax_information,1` in the shared `CheckoutRequest`, and
/// `$order->taxInformation()->create(...)` writes them together. A code without
/// a company is a row the shop cannot raise an invoice from.
///
/// ## Validation is the model's
///
/// Every rule comes from [TaxInformation.violations], which is also what
/// `CheckoutNotifier.setTaxInformation` and the checkout flow refuse on — so the
/// save button and the order flow cannot disagree about what a complete block
/// is.
class TaxInformationSheet extends StatefulWidget {
  const TaxInformationSheet({super.key, this.initial});

  /// What is already attached to the order, so re-opening edits rather than
  /// restarts.
  final TaxInformation? initial;

  @override
  State<TaxInformationSheet> createState() => _TaxInformationSheetState();
}

class _TaxInformationSheetState extends State<TaxInformationSheet> {
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _taxCode;
  late final TextEditingController _email;

  /// Errors are painted only after the first save attempt.
  ///
  /// Validating from the first keystroke marks every field red before the
  /// customer has typed anything into it, which reads as four things already
  /// wrong rather than a form waiting to be filled.
  bool _showErrors = false;

  @override
  void initState() {
    super.initState();
    final seed = widget.initial;
    _name = TextEditingController(text: seed?.companyName ?? '');
    _address = TextEditingController(text: seed?.companyAddress ?? '');
    _taxCode = TextEditingController(text: seed?.companyTaxCode ?? '');
    _email = TextEditingController(text: seed?.companyEmail ?? '');
    for (final c in [_name, _address, _taxCode, _email]) {
      c.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _address, _taxCode, _email]) {
      c
        ..removeListener(_onChanged)
        ..dispose();
    }
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  TaxInformation get _current => TaxInformation(
        companyName: _name.text,
        companyAddress: _address.text,
        companyTaxCode: _taxCode.text,
        companyEmail: _email.text,
      );

  void _save() {
    final info = _current;
    final problems = info.violations();
    if (problems.isNotEmpty) {
      setState(() => _showErrors = true);
      return;
    }
    Navigator.pop(context, TaxInformationSheetResult.saved(info));
  }

  @override
  Widget build(BuildContext context) {
    final info = _current;
    final problems = _showErrors ? info.violations() : const <String, String>{};
    final complete = info.isValid;

    return Padding(
      // Lifts the form clear of the keyboard, which otherwise covers the two
      // fields nearest the button — the two most likely to be wrong.
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('GST invoice details', style: context.text.h3),
            AppSpacing.vXs,
            Text(
              'For a GST invoice in your company’s name. All four are needed — '
              'the invoice cannot be raised on a GSTIN alone.',
              style: context.text.bodySm.copyWith(color: context.colors.faint),
            ),
            AppSpacing.vMd,
            _field(
              key: const Key('tax-company-name'),
              controller: _name,
              label: 'Company name',
              hint: 'Registered business name',
              error: problems[TaxField.companyName],
              maxLength: 120,
              textCapitalization: TextCapitalization.words,
            ),
            AppSpacing.vSm,
            _field(
              key: const Key('tax-company-address'),
              controller: _address,
              label: 'Company address',
              hint: 'Registered address',
              error: problems[TaxField.companyAddress],
              maxLength: 255,
              maxLines: 2,
              textCapitalization: TextCapitalization.words,
            ),
            AppSpacing.vSm,
            _field(
              key: const Key('tax-company-tax-code'),
              controller: _taxCode,
              label: 'GSTIN',
              hint: 'e.g. 27AAPFU0939F1Z5',
              error: problems[TaxField.companyTaxCode],
              maxLength: 15,
              textCapitalization: TextCapitalization.characters,
              // The pattern only matches upper case, so a lower-case keystroke
              // would otherwise mark a correct code invalid until the model
              // uppercased it on save.
              inputFormatters: [UpperCaseTextFormatter()],
            ),
            AppSpacing.vSm,
            _field(
              key: const Key('tax-company-email'),
              controller: _email,
              label: 'Company email',
              hint: 'billing@company.com',
              error: problems[TaxField.companyEmail],
              maxLength: 60,
              keyboardType: TextInputType.emailAddress,
            ),
            AppSpacing.vMd,
            ElevatedButton(
              key: const Key('tax-save'),
              // Live rather than disabled while incomplete: a dead button with
              // no message reads as a broken one. Tapping it paints the reason.
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: Text(complete ? 'Save GST details' : 'Save'),
            ),
            if (widget.initial != null) ...[
              AppSpacing.vXs,
              TextButton(
                key: const Key('tax-remove'),
                onPressed: () => Navigator.pop(
                  context,
                  const TaxInformationSheetResult.removed(),
                ),
                child: const Text('Remove GST details'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _field({
    required Key key,
    required TextEditingController controller,
    required String label,
    required String hint,
    required String? error,
    required int maxLength,
    int maxLines = 1,
    TextCapitalization textCapitalization = TextCapitalization.none,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) =>
      TextField(
        key: key,
        controller: controller,
        maxLines: maxLines,
        // The server's column widths. Counted rather than merely validated so a
        // long name is stopped at the box instead of after a round trip.
        maxLength: maxLength,
        // The counter is noise on four stacked fields; the cap still applies.
        buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
        textCapitalization: textCapitalization,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: error,
        ),
      );
}

/// Uppercases as the customer types, preserving the cursor.
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}

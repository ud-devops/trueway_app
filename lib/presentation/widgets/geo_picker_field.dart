import 'package:flutter/material.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../data/repositories/geo_repository.dart';
import 'required_label.dart';

/// A read-only field that opens a picker.
///
/// Looks like the `TextFormField`s beside it — same decoration, same label
/// behaviour, same error slot — but its value can only be *chosen*. That is the
/// point: `state` must be posted as a `states.id`, so a box a customer can type
/// "Gujarat" into is a box that cannot save.
///
/// Deliberately **not** a `FormField`. The value lives in the parent's state
/// (the id has to be posted, and the name only displayed), and a `Form`'s
/// `validate()` would paint "Choose a state" the moment autovalidation kicked
/// in on an unrelated field. The parent decides when the error appears.
class GeoPickerField extends StatelessWidget {
  const GeoPickerField({
    super.key,
    required this.label,
    required this.value,
    required this.hint,
    required this.onTap,
    this.error,
    this.enabled = true,
    this.busy = false,
    this.required = true,
  });

  /// The field's label. Carries the required asterisk unless [required] is
  /// false.
  final String label;

  /// The **name** of the selected option, or null when nothing is selected.
  /// Never the id — that is the parent's business.
  final String? value;

  /// Shown in place of [value] when nothing is selected.
  final String hint;

  /// Null disables the field.
  final VoidCallback? onTap;

  final String? error;
  final bool enabled;

  /// True while the list this field opens is being fetched. Replaces the
  /// chevron with a spinner so a slow list looks like work rather than a dead
  /// tap.
  final bool busy;

  final bool required;

  @override
  Widget build(BuildContext context) {
    final selected = value?.trim() ?? '';
    final hasValue = selected.isNotEmpty;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: AppRadius.rMd,
      child: InputDecorator(
        // `isEmpty: true` would park the label in its **resting** position, on
        // top of the child — and the child here is always painted, because a
        // picker shows its hint as content rather than as an
        // `InputDecoration.hintText` (which `InputDecorator` only reveals once
        // the label has floated). The two then overlap into
        // "Sudet*state"-shaped mush.
        //
        // Floating the label always is the fix: the label sits above, the hint
        // or the chosen name sits inside, and the field matches the text
        // fields around it once they have something in them.
        isEmpty: false,
        decoration: InputDecoration(
          floatingLabelBehavior: FloatingLabelBehavior.always,
          label: RequiredLabel(
            label,
            required: required,
            style: RequiredLabel.inheritStyle,
          ),
          errorText: error,
          enabled: enabled,
          suffixIcon: busy
              ? const Padding(
                  padding: EdgeInsets.all(AppSpacing.sm),
                  child: SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        child: Text(
          hasValue ? selected : hint,
          style: hasValue
              ? context.text.body
              : context.text.body.copyWith(color: context.colors.muted),
        ),
      ),
    );
  }
}

/// Shows the list and returns what was picked, or null if it was dismissed.
///
/// A sheet with a search box rather than a `DropdownButton`: the city list runs
/// to 306 rows for Gujarat and 576 for Uttar Pradesh, and scrolling to "Vadodara"
/// through a dropdown is not a thing anyone should be asked to do.
Future<GeoOption?> showGeoPicker({
  required BuildContext context,
  required String title,
  required List<GeoOption> options,
  String? selectedId,
}) =>
    showModalBottomSheet<GeoOption>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: context.colors.surface,
      builder: (_) => _GeoPickerSheet(
        title: title,
        options: options,
        selectedId: selectedId,
      ),
    );

class _GeoPickerSheet extends StatefulWidget {
  const _GeoPickerSheet({
    required this.title,
    required this.options,
    required this.selectedId,
  });

  final String title;
  final List<GeoOption> options;
  final String? selectedId;

  @override
  State<_GeoPickerSheet> createState() => _GeoPickerSheetState();
}

class _GeoPickerSheetState extends State<_GeoPickerSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Case-insensitive substring match, in the server's own order.
  ///
  /// The "Other" sentinel is kept **whatever the query says**: it is the escape
  /// hatch for a town that is not in this list, so it has to survive the search
  /// that failed to find that town. Filtering it out is how a customer ends up
  /// staring at "No matches" with no way forward.
  List<GeoOption> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.options;
    return [
      for (final option in widget.options)
        if (option.isOther || option.name.toLowerCase().contains(q)) option,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    // Leaves room for the keyboard the search box is about to raise.
    final inset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title, style: context.text.h3),
                  AppSpacing.vSm,
                  TextField(
                    key: const Key('geo-picker-search'),
                    controller: _search,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onChanged: (value) => setState(() => _query = value),
                    decoration: const InputDecoration(
                      hintText: 'Search',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Text(
                          'No matches for "${_query.trim()}".',
                          style: context.text.body
                              .copyWith(color: context.colors.muted),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final option = rows[i];
                        final isSelected = option.id == widget.selectedId;
                        return ListTile(
                          title: Text(
                            option.name,
                            style: option.isOther
                                ? context.text.body.copyWith(
                                    fontStyle: FontStyle.italic,
                                    color: context.colors.muted,
                                  )
                                : context.text.body,
                          ),
                          subtitle: option.isOther
                              ? Text(
                                  'My city is not in this list',
                                  style: context.text.caption,
                                )
                              : null,
                          trailing: isSelected
                              ? const Icon(
                                  Icons.check_rounded,
                                  color: AppColors.primary,
                                )
                              : null,
                          onTap: () => Navigator.of(context).pop(option),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

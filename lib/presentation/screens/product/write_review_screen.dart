import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../data/models/review.dart';
import '../../providers/review_provider.dart';
import '../../widgets/evidence_picker.dart';
import '../../widgets/required_label.dart';
import '../../widgets/surfaces.dart';
import '../../widgets/app_message.dart';

/// Write a review for one product.
///
/// Every field is required. The server agrees on `star` and `comment`
/// (`API\ReviewRequest`); photos are this shop's own rule, matching the return
/// form.
///
/// Two of the server's rules cannot be expressed as a length check and are
/// enforced here so the customer is not refused after a round trip:
///
///  * `not_regex:/<[^>]*>/i` — anything that looks like an HTML tag is rejected
///    outright, so `I paid <10 for this> pack` fails;
///  * `not_regex:/[\x{0400}-\x{04FF}]/u` — Cyrillic is blocked as spam.
class WriteReviewScreen extends ConsumerStatefulWidget {
  const WriteReviewScreen({
    super.key,
    required this.productId,
    this.productName,
    this.productSlug,
  });

  final int productId;
  final String? productName;
  final String? productSlug;

  @override
  ConsumerState<WriteReviewScreen> createState() => _WriteReviewScreenState();
}

class _WriteReviewScreenState extends ConsumerState<WriteReviewScreen> {
  int _star = 0;
  final _comment = TextEditingController();
  EvidenceSelection _evidence = const EvidenceSelection();
  bool _showErrors = false;

  /// Not a server rule — `comment` is only `required|max:5000`. A one-word
  /// review helps nobody, so this shop asks for a sentence.
  static const int _minComment = 20;
  static const int _maxComment = 5000;

  /// `not_regex:/<[^>]*>/i`
  static final _htmlTag = RegExp('<[^>]*>');

  /// `not_regex:/[\x{0400}-\x{04FF}]/u`
  static final _cyrillic = RegExp(r'[Ѐ-ӿ]');

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  String get _text => _comment.text.trim();

  /// Null when the comment is acceptable, otherwise the reason — phrased as the
  /// fix rather than as the rule.
  String? get _commentError {
    if (_text.isEmpty) return 'Please write a few words about the product.';
    if (_text.length < _minComment) {
      return 'Please write at least $_minComment characters '
          '(${_text.length} so far).';
    }
    if (_htmlTag.hasMatch(_text)) {
      return 'Angle brackets like < > are not allowed — please remove them.';
    }
    if (_cyrillic.hasMatch(_text)) {
      return 'Please write your review in English.';
    }
    return null;
  }

  bool get _isComplete =>
      _star > 0 && _commentError == null && !_evidence.isEmpty;

  Future<void> _submit() async {
    setState(() => _showErrors = true);
    if (!_isComplete) return;

    final ok = await ref.read(reviewSubmitProvider.notifier).submit(
          productId: widget.productId,
          star: _star,
          comment: _text,
          productSlug: widget.productSlug,
          imagePaths: _evidence.imagePaths,
          videoPaths: _evidence.videoPaths,
        );

    if (!mounted) return;
    if (!ok) {
      final error = ref.read(reviewSubmitProvider).error;
      context.showAlertSnack(error?.message ?? 'Could not post your review.');
      return;
    }

    context.pop();
    // Whether moderation is on is a store setting, so the wording follows it
    // rather than assuming. Promising a review is live when it is queued is a
    // lie the customer notices when it does not appear on the product page.
    context.showSuccessSnack(
      _settings.needsApproval
          ? 'Thanks! Your review is awaiting approval.'
          : 'Thanks! Your review is live.',
    );
  }

  /// Upload limits from the store, or the fallback while they are in flight.
  ///
  /// The picker used to hardcode these. An admin change then desynchronised it
  /// from the server silently, and uploads started failing with a message that
  /// explained nothing.
  ReviewSettings get _settings {
    final slug = widget.productSlug;
    if (slug == null || slug.isEmpty) return ReviewSettings.fallback;
    return ref.read(reviewGateProvider(slug)).valueOrNull?.settings ??
        ReviewSettings.fallback;
  }

  EvidenceLimits get _limits => EvidenceLimits.fromReviewSettings(_settings);

  @override
  Widget build(BuildContext context) {
    final submit = ref.watch(reviewSubmitProvider);
    // Watched, not just read: the limits arrive after the first frame and the
    // picker has to pick them up.
    final slug = widget.productSlug;
    if (slug != null && slug.isNotEmpty) ref.watch(reviewGateProvider(slug));

    return Scaffold(
      appBar: AppBar(title: const Text('Write a review')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.gutter,
          AppSpacing.gutter,
          120,
        ),
        children: [
          if ((widget.productName ?? '').isNotEmpty) ...[
            Text(
              widget.productName!,
              style: context.text.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            AppSpacing.vMd,
          ],

          const RequiredLabel('Your rating'),
          AppSpacing.vSm,
          _StarPicker(
            value: _star,
            enabled: !submit.busy,
            onChanged: (v) => setState(() => _star = v),
          ),
          if (_showErrors && _star == 0) ...[
            AppSpacing.vXs,
            Text(
              'Please pick a rating.',
              style: context.text.bodySm.copyWith(color: AppColors.error),
            ),
          ],

          AppSpacing.vLg,
          const RequiredLabel('Your review'),
          AppSpacing.vSm,
          TextField(
            key: const Key('review-comment'),
            controller: _comment,
            enabled: !submit.busy,
            minLines: 4,
            maxLines: 8,
            maxLength: _maxComment,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'What did you think? How was the quality, the packing, '
                  'the value?',
              errorText: _showErrors ? _commentError : null,
            ),
          ),

          AppSpacing.vMd,
          EvidencePicker(
            selection: _evidence,
            limits: _limits,
            enabled: !submit.busy,
            required: true,
            errorText: _showErrors && _evidence.isEmpty
                ? 'Add at least one photo of the product.'
                : null,
            onChanged: (value) => setState(() => _evidence = value),
          ),
        ],
      ),
      bottomSheet: BottomActionBar(
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            key: const Key('review-submit'),
            onPressed: submit.busy ? null : _submit,
            style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
            child: submit.busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Post review'),
          ),
        ),
      ),
    );
  }
}

/// One to five stars. Tapping a star sets that rating.
class _StarPicker extends StatelessWidget {
  const _StarPicker({
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final bool enabled;

  static const List<String> _labels = [
    'Poor',
    'Not great',
    'Okay',
    'Good',
    'Excellent',
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 1; i <= 5; i++)
          IconButton(
            key: Key('review-star-$i'),
            onPressed: enabled ? () => onChanged(i) : null,
            iconSize: 34,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            constraints: const BoxConstraints(),
            tooltip: _labels[i - 1],
            icon: Icon(
              i <= value ? Icons.star_rounded : Icons.star_border_rounded,
              color: i <= value ? AppColors.accent : context.colors.line,
            ),
          ),
        if (value > 0) ...[
          AppSpacing.hSm,
          Text(
            _labels[value - 1],
            style: context.text.bodySm.copyWith(color: context.colors.muted),
          ),
        ],
      ],
    );
  }
}

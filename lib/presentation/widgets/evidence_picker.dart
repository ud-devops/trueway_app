import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/models/review.dart';
import 'required_label.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../data/repositories/order_repository.dart';
import 'app_message.dart';

/// Photos and video a customer attaches as evidence.
///
/// Holds **file paths**, not bytes: `POST /order-returns/upload-media` is a
/// multipart call that wants paths, and the resulting URLs — not the files —
/// are what the submit call carries. The submit endpoint reads `media_images`
/// with `$request->input()`, so a file attached there is silently dropped.
///
/// Every limit below is the server's, checked here so a customer is told before
/// spending upload time rather than after.
class EvidenceSelection {
  const EvidenceSelection({this.imagePaths = const [], this.videoPaths = const []});

  final List<String> imagePaths;
  final List<String> videoPaths;

  bool get isEmpty => imagePaths.isEmpty && videoPaths.isEmpty;
  int get count => imagePaths.length + videoPaths.length;

  EvidenceSelection copyWith({
    List<String>? imagePaths,
    List<String>? videoPaths,
  }) =>
      EvidenceSelection(
        imagePaths: imagePaths ?? this.imagePaths,
        videoPaths: videoPaths ?? this.videoPaths,
      );
}

/// Server-side upload limits.
///
/// **Returns and reviews do not share these**, so they cannot be constants on
/// this class — each preset below is copied from its own validator, and they
/// disagree on nearly every value. Getting this wrong means the customer waits
/// through an upload only to be refused.
class EvidenceLimits {
  const EvidenceLimits({
    required this.maxImages,
    required this.maxVideos,
    required this.maxImageBytes,
    required this.maxVideoBytes,
    required this.imageExtensions,
    required this.videoExtensions,
    this.videoNote,
  });

  final int maxImages;
  final int maxVideos;
  final int maxImageBytes;
  final int maxVideoBytes;
  final List<String> imageExtensions;
  final List<String> videoExtensions;

  /// A rule the app cannot check itself, shown so the customer is not surprised
  /// by a server refusal — review videos are capped at 30 seconds by
  /// `MaxVideoDurationRule`, and reading a duration needs a decoder this app
  /// does not carry.
  final String? videoNote;

  String get maxImageLabel => '${(maxImageBytes / (1024 * 1024)).round()} MB';
  String get maxVideoLabel => '${(maxVideoBytes / (1024 * 1024)).round()} MB';

  /// `OrderReturnController::uploadMedia` — `max:10` files per call,
  /// `max:5120` KB images, `max:51200` KB videos.
  static const EvidenceLimits returns = EvidenceLimits(
    // 6, not the server's `max:10` per call. Same reasoning as the video cap
    // below: stricter than the API on purpose, and a claim the team can act on
    // rarely needs ten photographs.
    maxImages: 6,
    maxVideos: OrderRepository.maxUploadFiles,
    maxImageBytes: 5120 * 1024,
    // 10 MB, not the server's own `max:51200` KB (50 MB). Deliberately
    // stricter than the API: a 50 MB clip off a phone camera is a long upload
    // on mobile data and a long wait before the customer learns whether their
    // return went through. The server still accepts anything under its own
    // cap, so tightening here can only refuse earlier — never break a request
    // the backend would have taken.
    maxVideoBytes: 10240 * 1024,
    // `mimes:jpg,jpeg,png,webp` — no heic, no gif.
    imageExtensions: ['jpg', 'jpeg', 'png', 'webp'],
    // `mimes:mp4,mov,avi,webm` — 3gp is **not** accepted.
    videoExtensions: ['mp4', 'mov', 'avi', 'webm'],
  );

  /// `API\ReviewRequest` — stricter on every axis. Images are capped by
  /// `review_max_file_number` (6) and `review_max_file_size` (2 MB); videos are
  /// `array|max:2`, `mimes:mp4,mov`, `max:10240` KB **and 30 seconds**.
  ///
  /// Note **webp is not accepted here** even though returns take it.
  /// Built from the store's own admin settings.
  ///
  /// The constant below was the same set of numbers hardcoded. An admin change
  /// then silently desynchronised the picker from the server and uploads began
  /// failing with no useful message, which is exactly why the API started
  /// sending them.
  factory EvidenceLimits.fromReviewSettings(ReviewSettings settings) =>
      EvidenceLimits(
        maxImages: settings.maxImages,
        maxVideos: settings.maxVideos,
        maxImageBytes: settings.maxImageBytes,
        maxVideoBytes: settings.maxVideoBytes,
        imageExtensions: settings.imageExtensions,
        videoExtensions: settings.videoExtensions,
        videoNote:
            'Videos must be under ${settings.maxVideoSeconds} seconds.',
      );

  /// Only for a form opened before the settings have arrived. Prefer
  /// [EvidenceLimits.fromReviewSettings].
  static const EvidenceLimits reviews = EvidenceLimits(
    maxImages: 6,
    maxVideos: 2,
    maxImageBytes: 2 * 1024 * 1024,
    maxVideoBytes: 10240 * 1024,
    imageExtensions: ['jpg', 'jpeg', 'png'],
    videoExtensions: ['mp4', 'mov'],
    videoNote: 'Videos must be under 30 seconds.',
  );
}

/// Attach-evidence control: a row of thumbnails plus add buttons.
class EvidencePicker extends StatelessWidget {
  const EvidencePicker({
    super.key,
    required this.selection,
    required this.onChanged,
    required this.limits,
    this.enabled = true,
    this.required = false,
    this.errorText,
  });

  final EvidenceSelection selection;
  final ValueChanged<EvidenceSelection> onChanged;

  /// Which validator this picker is feeding. Returns and reviews disagree on
  /// every limit, so there is no default — the caller has to say.
  final EvidenceLimits limits;

  final bool enabled;

  /// Whether the surrounding form insists on at least one file.
  ///
  /// Nothing server-side does: `OrderReturnRequest` has no media rules, so a
  /// return with no photos validates. This only changes the label and lets the
  /// caller pass [errorText] — the enforcing is the form's.
  final bool required;

  /// Shown under the tiles when the form has something to say about the
  /// selection. Null while the field is untouched or satisfied.
  final String? errorText;

  Future<void> _addImages(BuildContext context) async {
    final room = limits.maxImages - selection.imagePaths.length;
    if (room <= 0) {
      context.showAlertSnack(
        'You can attach up to ${limits.maxImages} photos.',
      );
      return;
    }

    final picked = await ImagePicker().pickMultiImage();
    if (picked.isEmpty || !context.mounted) return;

    final accepted = <String>[];
    var oversize = 0;
    var wrongType = 0;

    for (final file in picked.take(room)) {
      if (!_hasExtension(file.path, limits.imageExtensions)) {
        wrongType++;
        continue;
      }
      if (await File(file.path).length() > limits.maxImageBytes) {
        oversize++;
        continue;
      }
      accepted.add(file.path);
    }
    if (!context.mounted) return;

    if (accepted.isNotEmpty) {
      onChanged(
        selection.copyWith(imagePaths: [...selection.imagePaths, ...accepted]),
      );
    }
    _report(context, picked.length, accepted.length, oversize, wrongType);
  }

  Future<void> _addVideo(BuildContext context) async {
    if (selection.videoPaths.length >= limits.maxVideos) {
      context.showAlertSnack(
        'You can attach up to ${limits.maxVideos} '
        '${limits.maxVideos == 1 ? 'video' : 'videos'}.',
      );
      return;
    }

    final file = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (file == null || !context.mounted) return;

    if (!_hasExtension(file.path, limits.videoExtensions)) {
      context.showAlertSnack(
        'Videos must be ${_readableList(limits.videoExtensions)}.',
      );
      return;
    }
    if (await File(file.path).length() > limits.maxVideoBytes) {
      if (context.mounted) {
        context.showAlertSnack(
          'Each video must be under ${limits.maxVideoLabel}.',
        );
      }
      return;
    }
    if (!context.mounted) return;

    onChanged(
      selection.copyWith(videoPaths: [...selection.videoPaths, file.path]),
    );
  }

  /// `['mp4', 'mov']` -> `MP4 or MOV`.
  static String _readableList(List<String> extensions) {
    final upper = extensions.map((e) => e.toUpperCase()).toList();
    if (upper.length == 1) return upper.single;
    return '${upper.sublist(0, upper.length - 1).join(', ')} or ${upper.last}';
  }

  /// One sentence covering everything that was skipped, rather than a snack per
  /// file — picking eight photos of which three are too large should not queue
  /// three toasts.
  ///
  /// The reasons name the **actual** limits rather than a fixed sentence: the
  /// same widget serves returns (5 MB, WEBP allowed) and reviews (2 MB, no
  /// WEBP), and a message quoting the wrong one sends the customer to resize a
  /// photo that was never too big.
  void _report(
    BuildContext context,
    int picked,
    int accepted,
    int oversize,
    int wrongType,
  ) {
    final skipped = picked - accepted;
    if (skipped <= 0) return;

    final parts = <String>[
      if (oversize > 0) '$oversize over ${limits.maxImageLabel}',
      if (wrongType > 0)
        '$wrongType not a ${_readableList(limits.imageExtensions)}',
    ];
    final why = parts.isEmpty ? 'the limit was reached' : parts.join(' and ');
    context.showAlertSnack('Skipped $skipped photos — $why.');
  }

  static bool _hasExtension(String path, List<String> allowed) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return false;
    return allowed.contains(path.substring(dot + 1).toLowerCase());
  }

  void _remove(String path, {required bool isVideo}) {
    onChanged(
      isVideo
          ? selection.copyWith(
              videoPaths: [...selection.videoPaths]..remove(path),
            )
          : selection.copyWith(
              imagePaths: [...selection.imagePaths]..remove(path),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // The asterisk carries "required"; the word beside it would say
            // the same thing twice. "Optional" still earns its place, because
            // nothing else on the row would say so.
            RequiredLabel(
              'Photos or video',
              style: context.text.title,
              required: required,
            ),
            if (!required) ...[
              AppSpacing.hSm,
              Text(
                'Optional',
                style: context.text.caption
                    .copyWith(color: context.colors.muted),
              ),
            ],
          ],
        ),
        AppSpacing.vXs,
        Text(
          [
            'Up to ${limits.maxImages} photos, ${limits.maxImageLabel} each.',
            if (limits.videoNote != null) limits.videoNote!,
          ].join(' '),
          style: context.text.caption.copyWith(color: context.colors.muted),
        ),
        AppSpacing.vSm,
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final path in selection.imagePaths)
              _Thumb(
                path: path,
                onRemove: enabled ? () => _remove(path, isVideo: false) : null,
              ),
            for (final path in selection.videoPaths)
              _Thumb(
                path: path,
                isVideo: true,
                onRemove: enabled ? () => _remove(path, isVideo: true) : null,
              ),
            _AddTile(
              icon: Icons.add_photo_alternate_rounded,
              label: 'Photo',
              onTap: enabled ? () => _addImages(context) : null,
            ),
            _AddTile(
              icon: Icons.videocam_rounded,
              label: 'Video',
              onTap: enabled ? () => _addVideo(context) : null,
            ),
          ],
        ),
        if (errorText != null) ...[
          AppSpacing.vXs,
          Text(
            errorText!,
            style: context.text.bodySm.copyWith(color: AppColors.error),
          ),
        ],
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.path, this.isVideo = false, this.onRemove});

  final String path;
  final bool isVideo;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: AppRadius.rMd,
              child: isVideo
                  // No frame is extracted: that needs a video decoder, and the
                  // file is only held long enough to upload it.
                  ? Container(
                      color: context.colors.surfaceAlt,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.play_circle_outline_rounded,
                        color: context.colors.muted,
                      ),
                    )
                  : Image.file(File(path), fit: BoxFit.cover),
            ),
          ),
          if (onRemove != null)
            Positioned(
              top: -6,
              right: -6,
              child: IconButton(
                icon: const Icon(Icons.cancel_rounded, size: 18),
                color: context.colors.muted,
                onPressed: onRemove,
                tooltip: 'Remove',
              ),
            ),
        ],
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.rMd,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          borderRadius: AppRadius.rMd,
          border: Border.all(color: context.colors.line),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: context.colors.muted),
            const SizedBox(height: 4),
            Text(
              label,
              style: context.text.caption.copyWith(color: context.colors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

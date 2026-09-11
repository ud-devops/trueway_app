import 'package:flutter/material.dart';

import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../data/models/order_return.dart';
import '../screens/orders/orders_screen.dart' show formatOrderDate;
import 'app_network_image.dart';
import 'media_viewer.dart';

/// The conversation a return actually is.
///
/// ## What it replaced
///
/// A return used to show one status chip and, while it was waiting, the store's
/// current instruction. Everything before that was gone: what the customer sent
/// first, what the store said about it, what was sent in answer. A return can
/// run three submissions deep, and the customer could see none of it.
///
/// ## The text is the server's
///
/// [OrderReturnHistory.title] is the heading and [OrderReturnHistory.note] is
/// the store's message. `action.label` is never rendered — it is worded for
/// staff ("Resubmit requested by admin", "Mark as completed") and would read
/// as the shop talking about the customer rather than to them. `action.value`
/// picks the icon and nothing else, so a code this app has never heard of
/// still renders its step.
class ReturnTimeline extends StatelessWidget {
  const ReturnTimeline({super.key, required this.histories});

  /// Newest first, as the server orders them.
  final List<OrderReturnHistory> histories;

  @override
  Widget build(BuildContext context) {
    if (histories.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < histories.length; i++)
          _Step(
            entry: histories[i],
            // The connector hangs *below* a marker, so the last row has none.
            isLast: i == histories.length - 1,
          ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.entry, required this.isLast});

  final OrderReturnHistory entry;
  final bool isLast;

  static const double _dot = 26;

  /// Open-ended by design: the backend can add steps without an app release,
  /// so an unknown code gets a neutral marker and its text still shows.
  static IconData _iconFor(String action) => switch (action) {
        'created' => Icons.keyboard_return_rounded,
        'resubmit_requested' => Icons.help_outline_rounded,
        'resubmitted' => Icons.reply_rounded,
        'approved' => Icons.check_circle_outline_rounded,
        'rejected' => Icons.cancel_rounded,
        'mark_as_completed' => Icons.verified_rounded,
        _ => Icons.circle_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final submission = entry.submission;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: _dot,
                height: _dot,
                decoration: BoxDecoration(
                  color: context.colors.primarySoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _iconFor(entry.action.value ?? ''),
                  size: 14,
                  color: context.colors.primaryDarker,
                ),
              ),
              if (!isLast)
                Expanded(child: Container(width: 2, color: context.colors.line)),
            ],
          ),
          AppSpacing.hSm,
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The server's own heading. Never `action.label`.
                  Text(
                    entry.title.isEmpty ? 'Update' : entry.title,
                    style: context.text.title,
                  ),
                  if (entry.createdAt case final at?) ...[
                    const SizedBox(height: 2),
                    Text(
                      formatOrderDate(at, withTime: true),
                      style: context.text.caption,
                    ),
                  ],
                  // What the store said at this step. Kept even after the
                  // customer has answered it — `admin_feedback` only ever holds
                  // the *current* instruction, so this is the only place the
                  // earlier ones survive.
                  if ((entry.note ?? '').trim().isNotEmpty) ...[
                    AppSpacing.vXs,
                    _NoteCard(text: entry.note!.trim()),
                  ],
                  // Only when there is something left to draw. With the item
                  // list gone, a submission carrying nothing but items would
                  // otherwise render an empty gap under the heading.
                  if (submission != null && submission.hasVisibleContent) ...[
                    AppSpacing.vXs,
                    _SubmissionBlock(submission: submission),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A message from the store, set apart from the step's own heading.
class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.xs),
        decoration: BoxDecoration(
          color: context.colors.surfaceAlt,
          borderRadius: AppRadius.rSm,
        ),
        child: Text(text, style: context.text.bodySm),
      );
}

/// What the customer sent: their words, the items they named, and the evidence.
class _SubmissionBlock extends StatelessWidget {
  const _SubmissionBlock({required this.submission});

  final ReturnSubmission submission;

  @override
  Widget build(BuildContext context) {
    final media = [
      for (final url in submission.images)
        AppMedia(url: url, kind: AppMediaKind.image),
      // Videos are NOT images. Rendering an `.mp4` through an image widget
      // gives a permanently-failed thumbnail; the viewer plays them.
      for (final url in submission.videos)
        AppMedia(url: url, kind: AppMediaKind.video),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The items the submission named are deliberately NOT listed here.
        //
        // They are already on the screen: the return's own "Items" section
        // above shows each product with its reason. Repeating three full
        // catalogue names — and this catalogue's names run to a line and a half
        // each — inside every round buried the customer's own words under a
        // wall of text they had already read.
        //
        // `ReturnSubmission.items` is still parsed; nothing renders it.
        if ((submission.comment ?? '').trim().isNotEmpty)
          Text(submission.comment!.trim(), style: context.text.bodySm),
        if (media.isNotEmpty) ...[
          AppSpacing.vXs,
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: media.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) => _Thumb(
                media: media[i],
                onTap: () => showMediaViewer(context, media, initialIndex: i),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.media, required this.onTap});

  final AppMedia media;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: AppRadius.rSm,
        child: SizedBox(
          width: 64,
          height: 64,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: AppRadius.rSm,
                child: media.kind == AppMediaKind.video
                    // A video has no still to show, so the tile is a surface
                    // with a play badge rather than a broken image.
                    ? ColoredBox(color: context.colors.surfaceAlt)
                    : AppNetworkImage(url: media.url, fit: BoxFit.cover),
              ),
              if (media.kind == AppMediaKind.video)
                Center(
                  child: Icon(
                    Icons.play_circle_fill_rounded,
                    color: context.colors.primaryDark,
                    size: 28,
                  ),
                ),
            ],
          ),
        ),
      );
}

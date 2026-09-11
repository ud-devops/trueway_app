import 'package:flutter/material.dart';

import '../../core/design_system/app_colors.dart';
import '../../core/design_system/app_spacing.dart';
import '../../core/design_system/theme_context.dart';
import '../../data/models/review.dart';
import 'app_network_image.dart';
import 'media_viewer.dart';
import 'skeletons.dart';

/// One review: reviewer, rating, comment, media and date.
///
/// [compact] is the product-page variant — the comment is clamped so three
/// reviews cannot push the rest of the page off screen. The "see all" sheet
/// uses the full variant.
class ReviewTile extends StatelessWidget {
  const ReviewTile({
    super.key,
    required this.review,
    this.compact = false,
    this.isMine = false,
  });

  final Review review;

  /// Clamp the comment to a few lines.
  final bool compact;

  /// Marks the signed-in customer's own review, which is pinned to the top.
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ReviewAvatar(review: review),
              AppSpacing.hSm,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            review.userName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.title,
                          ),
                        ),
                        if (isMine) ...[
                          AppSpacing.hXs,
                          _tag(context, 'You'),
                        ],
                        // "Waiting for approval", and it can only ever be the
                        // reader's own review.
                        //
                        // The public feed used to return *everyone's* pending
                        // reviews — an anonymous read of product 118 came back
                        // with review 1019 at `status:"pending"` — so this badge
                        // used to mean "not published yet, whoever you are".
                        // Moderation is honoured since 2026-08-12: a pending
                        // review reaches nobody but its author, which is why the
                        // wording is now personal.
                        if (!review.isApproved) ...[
                          AppSpacing.hXs,
                          _tag(context, 'Waiting for approval'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        ReviewStars(star: review.star),
                        AppSpacing.hXs,
                        Flexible(
                          child: Text(
                            // Server-rendered relative prose ("2 weeks ago"),
                            // already localized. `created_at` cannot be parsed
                            // back into a date — `Review.createdAt` (from
                            // created_at_tz) is the field to sort on.
                            review.createdAtRelative,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.caption,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (review.isVerifiedPurchase && review.orderedAtLabel != null) ...[
            const SizedBox(height: 6),
            // Rendered verbatim: the server bakes the emoji into the
            // translation string ("✅ Purchased 7 months ago"), so prefixing an
            // icon of our own would double it up.
            Text(
              review.orderedAtLabel!,
              style: context.text.caption.copyWith(color: context.colors.savings),
            ),
          ],
          if (review.comment.trim().isNotEmpty) ...[
            AppSpacing.vXs,
            ReviewComment(text: review.comment, clamp: compact),
          ],
          if (review.hasMedia) ...[
            AppSpacing.vXs,
            _Media(review: review),
          ],
          if (review.reply case final reply?) ...[
            AppSpacing.vXs,
            _Reply(reply: reply),
          ],
        ],
      ),
    );

    // Dimmed while it waits, matching the website. Only the author sees this
    // state at all, so the fade reads as "yours, not live yet" rather than as a
    // disabled control.
    return review.isApproved ? body : Opacity(opacity: 0.6, child: body);
  }

  Widget _tag(BuildContext context, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: context.colors.primarySoft,
          borderRadius: AppRadius.rPill,
        ),
        child: Text(
          label,
          style: context.text.overline.copyWith(color: context.colors.primaryDarker),
        ),
      );
}

/// A review body that can be clamped without losing the text.
///
/// **Why this is not a plain `Text(maxLines: 4, overflow: ellipsis)`:** the real
/// feed's reviews are long — every captured row on products 111 and 118 is
/// 582-633 characters, roughly fifteen lines on a phone — so a four-line clamp
/// hides about three quarters of every review. The product page only offers
/// "See all reviews" once there are more reviews than fit in the preview, so on
/// a product with one or two reviews (both captured products) the clipped text
/// was unreachable from anywhere in the app: the customer could read the first
/// four lines and nothing else, ever.
///
/// So the clamp keeps a way out. The toggle is only built when the text
/// genuinely overflows — measured with a [TextPainter] against the real width
/// and the user's text scale, not guessed from a character count — so short
/// reviews stay a bare paragraph with no stray "Read more" under them.
class ReviewComment extends StatefulWidget {
  const ReviewComment({super.key, required this.text, required this.clamp});

  final String text;

  /// Clamp to [maxLines] with an expander. False renders the whole thing.
  final bool clamp;

  static const int maxLines = 4;

  @override
  State<ReviewComment> createState() => _ReviewCommentState();
}

class _ReviewCommentState extends State<ReviewComment> {
  bool _expanded = false;

  @override
  void didUpdateWidget(ReviewComment old) {
    super.didUpdateWidget(old);
    // Rows are recycled by the list; a new review must not inherit the previous
    // one's expanded state.
    if (old.text != widget.text) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final style = context.text.body;
    if (!widget.clamp) return Text(widget.text, style: style);

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: ReviewComment.maxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();

        if (!overflows) return Text(widget.text, style: style);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              maxLines: _expanded ? null : ReviewComment.maxLines,
              overflow: _expanded ? null : TextOverflow.ellipsis,
              style: style,
            ),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  _expanded ? 'Show less' : 'Read more',
                  style: context.text.caption.copyWith(
                    color: context.colors.primaryDark,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The reviewer's picture — initials for the inline case, image for a real URL.
///
/// **Why not just render `user_avatar`:** when a reviewer has no uploaded
/// picture the backend generates an initials image and embeds it in the JSON as
/// a base64 `data:` URI — ~3.9 KB per review, 45–69% of the whole response, and
/// re-encoded on every request (the same review measured 2927/3259/3835/4003
/// bytes across identical calls). Nothing can cache it: the bytes change, so
/// the URI that keys the image cache changes with them, and every rebuild in a
/// scrolling list re-decodes several multi-KB PNGs on the UI thread.
///
/// So we branch on [Review.isInlineAvatar] and draw the initials ourselves —
/// visually the same thing the server was drawing — and only send genuine http
/// URLs (which are stable and cacheable) through [AppNetworkImage].
class ReviewAvatar extends StatelessWidget {
  const ReviewAvatar({super.key, required this.review, this.size = 40});

  final Review review;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = review.avatarUrl;
    if (url != null && url.isNotEmpty) {
      return ClipOval(
        child: AppNetworkImage(
          url: url,
          width: size,
          height: size,
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.colors.primarySoft,
        shape: BoxShape.circle,
      ),
      child: Text(
        review.initials,
        style: context.text.buttonSm.copyWith(color: context.colors.primaryDarker),
      ),
    );
  }
}

/// Five stars, filled up to [star].
///
/// There is deliberately no per-star histogram anywhere in this file: the API
/// exposes no star-count breakdown on any endpoint, and the only way to build
/// one would be to download every review and count locally.
class ReviewStars extends StatelessWidget {
  const ReviewStars({super.key, required this.star, this.size = 14});

  final int star;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
        // Five bare Icons announce nothing, so a screen-reader user got the
        // reviewer's name, the date and the comment but no rating at all.
        label: '$star out of 5 stars',
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 1; i <= 5; i++)
              Icon(
                i <= star ? Icons.star_rounded : Icons.star_outline_rounded,
                size: size,
                color: i <= star ? AppColors.accent : context.colors.faint,
              ),
          ],
        ),
      );
}

/// A review's attachments, as one horizontal strip.
///
/// Photos and clips share a single list so the full-screen viewer can page
/// across all of them — captured: one review on product 118 carries 6 photos
/// and 2 videos, which used to be six separate one-shot dialogs plus two dead
/// tiles.
///
/// Videos still never bind their `thumbnail` to an Image widget: on this
/// backend `videos[].thumbnail` is the .mp4 URL itself (both keys go through
/// the same `RvMedia::getImageUrl()` call), so an Image would download the
/// whole clip and then fail to decode it. [AppMedia.posterUrl] drops it and
/// [MediaThumb] draws a play glyph instead.
class _Media extends StatelessWidget {
  const _Media({required this.review});

  final Review review;

  List<AppMedia> get _items => [
        for (final image in review.images)
          AppMedia.image(image.fullUrl, thumbnail: image.thumbnail),
        for (final video in review.videos)
          AppMedia.video(video.fullUrl, thumbnail: video.thumbnail),
      ];

  @override
  Widget build(BuildContext context) {
    final items = _items;

    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => AppSpacing.hXs,
        itemBuilder: (context, i) => MediaThumb(
          media: items[i],
          onTap: () => showMediaViewer(context, items, initialIndex: i),
        ),
      ),
    );
  }
}

/// Placeholder shaped like a [ReviewTile], for the section's loading state.
class ReviewTileSkeleton extends StatelessWidget {
  const ReviewTileSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SkeletonBox(height: 40, width: 40, radius: AppRadius.pill),
            AppSpacing.hSm,
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(height: 12, width: 120, radius: AppRadius.sm),
                  AppSpacing.vXs,
                  SkeletonBox(height: 10, width: 90, radius: AppRadius.sm),
                  AppSpacing.vXs,
                  SkeletonBox(height: 10, radius: AppRadius.sm),
                ],
              ),
            ),
          ],
        ),
      );
}

/// The store's reply, under the review it answers.
///
/// A tinted box with an "Admin" badge, matching the website. Inline `data:`
/// avatars are drawn as initials for the same reason the reviewer's are — see
/// [Review.isInlineAvatar].
class _Reply extends StatelessWidget {
  const _Reply({required this.reply});

  final ReviewReply reply;

  @override
  Widget build(BuildContext context) {
    final url = reply.avatarUrl;

    return Container(
      margin: const EdgeInsets.only(left: AppSpacing.xl),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: context.colors.surfaceAlt,
        borderRadius: AppRadius.rMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (url != null && url.isNotEmpty)
                ClipOval(child: AppNetworkImage(url: url, width: 22, height: 22))
              else
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: context.colors.primarySoft,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    reply.initials,
                    style: context.text.caption
                        .copyWith(color: context.colors.primaryDarker),
                  ),
                ),
              AppSpacing.hXs,
              Flexible(
                child: Text(
                  reply.userName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySm
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              AppSpacing.hXs,
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: context.colors.primarySoft,
                  borderRadius: AppRadius.rSm,
                ),
                child: Text(
                  'Admin',
                  style: context.text.caption
                      .copyWith(color: context.colors.primaryDarker),
                ),
              ),
              if (reply.createdAtRelative.isNotEmpty) ...[
                const Spacer(),
                Text(reply.createdAtRelative, style: context.text.caption),
              ],
            ],
          ),
          if (reply.message.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(reply.message, style: context.text.bodySm),
          ],
        ],
      ),
    );
  }
}

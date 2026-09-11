import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/config/app_config.dart';
import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_icons.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../data/models/customer.dart';
import '../../../core/design_system/theme_context.dart';
import '../../../core/utils/external_link.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/appearance_tile.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/surfaces.dart';

/// The WGHT axis every icon on this screen is drawn at.
///
/// Material Symbols is a variable font, so weight is a real axis rather than a
/// different glyph — 300 is one step under the 400 default and is what takes
/// the chrome from bold to quiet. Size and colour cannot do this: a smaller
/// heavy glyph is still a heavy glyph, and a paler one just looks disabled.
/// Stroke weight for this screen's icons.
///
/// 400, not 300. At 20dp a 300-weight Material Symbols glyph is a hairline
/// whose strokes meet at visibly hard corners — a lock, a bell and a chat
/// bubble are mostly those corners, which is what read as "sharp edges".
/// 400 gives the Rounded family's terminals enough body to actually show.
///
/// Filled (`fill: 1`) was the other way to soften them and was rejected: solid
/// glyphs down a menu read as twelve buttons, which is the same problem the
/// tinted discs behind them had.
const double _iconWeight = 400;

/// The Account tab: a dashboard of cards rather than one long settings list.
///
/// This replaced a screen where every destination — orders, wishlist,
/// addresses, help pages, appearance — sat in the same flat, boxed list of
/// chevron rows. Reaching the FAQ meant scrolling past everything else, and
/// nothing on screen said which of those twelve rows actually mattered day to
/// day. The three most-used destinations are now their own quick-action cards
/// up top; everything else is grouped under a labelled section and drawn as
/// individual cards, so a glance at the section label says what kind of thing
/// a row does before reading its name.
///
/// Every destination the old screen offered is still here — nothing was
/// dropped, only regrouped. [_MenuRow]/[_QuickAction] are the two shapes a row
/// can take; nothing here invents a third.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key, this.showBack = false});

  /// True when pushed as a route (from the home header) rather than shown
  /// as the Account tab, which has no back destination.
  final bool showBack;

  /// How far the wash reaches, below the status bar.
  ///
  /// Enough to hold the AppBar and the profile header and to fade out level
  /// with the quick-action tiles, so the tiles sit on the page rather than on
  /// the colour. Measured against the header's own 84dp avatar plus its type.
  static const double _washHeight = 260;

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  final _scroll = ScrollController();

  /// Whether the bar has taken over from the header.
  ///
  /// At rest the customer's own name is the title — printing "Account" a
  /// centimetre above it says the same thing twice, and a solid bar there cuts
  /// the wash in half. Once that header scrolls away the bar has to become a
  /// real bar: opaque, so the list does not run visibly underneath it, and
  /// titled, so the screen still says where it is.
  bool _barSolid = false;

  /// The point the header clears the bar. Below the wash on purpose — the
  /// swap should happen as the name leaves, not when the colour does.
  static const double _threshold = 96;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final solid = _scroll.offset > _threshold;
      if (solid != _barSolid) setState(() => _barSolid = solid);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final signedIn = auth.isAuthenticated;
    final showBack = widget.showBack;

    // Signed-in destinations. While signed out these route to /login, which
    // pops back here on success.
    void guarded(String route) => context.push(signedIn ? route : '/login');

    return Scaffold(
      backgroundColor: context.colors.background,
      // Transparent bar over the wash, so the gradient starts at the very top
      // of the screen instead of under a hard grey band. `extendBodyBehindAppBar`
      // is what lets it run up behind the status bar.
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        automaticallyImplyLeading: showBack,
        // Both fade together, so the bar arrives as one thing rather than a
        // title appearing over a still-transparent strip.
        title: AnimatedOpacity(
          opacity: _barSolid ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: const Text('Account'),
        ),
        backgroundColor:
            _barSolid ? context.colors.surface : Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          // The header wash — the same gradient the home screen wears, so the
          // two tabs open the same way rather than one green and one grey.
          //
          // Fixed height and painted behind the list, not wrapped around the
          // header: a gradient that scrolls with the content reads as a
          // coloured box sliding up the screen. This one stays put and the
          // content passes over it, which is what makes it read as the page
          // rather than as an element.
          //
          // `context.colors.headerWash` is a palette token, so dark mode gets
          // its own (near-black green) rather than a light green smear.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: AccountScreen._washHeight +
                MediaQuery.paddingOf(context).top,
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: context.colors.headerWash),
            ),
          ),
          ListView(
        controller: _scroll,
        padding: EdgeInsets.only(
          left: AppSpacing.md,
          right: AppSpacing.md,
          bottom: AppSpacing.md,
          // Clears the transparent AppBar the list now runs under.
          top: kToolbarHeight + MediaQuery.paddingOf(context).top,
        ),
        children: [
          // Who this account belongs to, before anything it can do.
          //
          // The screen used to open straight onto the tiles, on the argument
          // that the name is one tap away under "My profile". That reads as a
          // menu rather than an account: every account tab a customer knows
          // opens by confirming *whose* account they are looking at, which is
          // also the fastest way to notice you are signed into the wrong one.
          _ProfileHeader(customer: auth.customer),
          AppSpacing.vLg,

          if (!signedIn) ...[
            const _SignInInvite(),
            AppSpacing.vLg,
          ],

          Row(
            children: [
              _QuickAction(
                key: const Key('account-quick-orders'),
                icon: AppIcons.orders,
                label: 'Orders',
                onTap: () => guarded('/orders'),
              ),
              AppSpacing.hSm,
              _QuickAction(
                key: const Key('account-quick-wishlist'),
                icon: AppIcons.heart,
                label: 'Wishlist',
                // Deliberately not [guarded]: the wishlist API is anonymous,
                // so requiring a sign-in here would gate a feature the
                // backend does not gate.
                onTap: () => context.push('/wishlist'),
              ),
              AppSpacing.hSm,
              _QuickAction(
                key: const Key('account-quick-address'),
                icon: AppIcons.mapPin,
                label: 'Address',
                onTap: () => guarded('/addresses'),
              ),
            ],
          ),
          AppSpacing.vLg,

          // Its own card, above the list. It is a *setting*, not a
          // destination — nothing slides in when you touch it — so grouping it
          // with rows that all navigate somewhere made it the odd one out.
          const AppearanceTile(),
          AppSpacing.vLg,

          _MenuGroup(title: 'Your information', children: [
          _MenuRow(
            key: const Key('account-my-profile'),
            icon: AppIcons.user,
            label: 'My profile',
            onTap: () => guarded('/profile'),
          ),
          // Every return route is behind `auth:sanctum`, so this is guarded
          // like orders rather than left open.
          _MenuRow(
            key: const Key('account-my-returns'),
            icon: AppIcons.returns,
            label: 'My returns',
            onTap: () => guarded('/returns'),
          ),
          // `GET /ecommerce/reviews` is behind auth:sanctum too.
          _MenuRow(
            key: const Key('account-my-reviews'),
            icon: Symbols.reviews,
            label: 'My reviews',
            onTap: () => guarded('/reviews'),
          ),
          // `PUT /update/password` is behind auth:sanctum like the rest.
          _MenuRow(
            key: const Key('account-change-password'),
            icon: Symbols.lock,
            label: 'Change password',
            onTap: () => guarded('/profile/password'),
          ),
          // `/notifications` needs a bearer token, but the screen itself
          // handles the signed-out case (a sign-in prompt) rather than asking
          // every caller to gate it — the same convention the home screen's
          // bell icon already follows.
          _MenuRow(
            key: const Key('account-notifications'),
            icon: AppIcons.bell,
            label: 'Notifications',
            onTap: () => context.push('/notifications'),
          ),
          ],),
          AppSpacing.vLg,

          // The shop's own pages, and sharing it — about the *store*, not
          // about this account. They were in the same group as "My profile"
          // and "Change password", where the FAQ sat one row under a password
          // form.
          _MenuGroup(title: 'Other information', children: [
            _MenuRow(
              key: const Key('account-share'),
              icon: AppIcons.share,
              label: 'Share the app',
              onTap: () => SharePlus.instance.share(
                ShareParams(
                  text: 'Check out Trueway Farms - fresh organic products '
                      'delivered! ${AppConfig.origin}',
                ),
              ),
            ),
            for (final page in _infoPages)
              _MenuRow(
                key: Key('account-page-${page.path}'),
                icon: page.icon,
                label: page.label,
                onTap: () => _openPage(context, ref, page),
              ),
          ],),
          AppSpacing.vLg,

          // Last, and on its own. It used to sit between "Share the app" and
          // the help pages, where a customer scrolling for the FAQ passed the
          // one row that ends their session — and where, being the same shape
          // and colour as its neighbours, it read as just another destination.
          // Bottom-of-the-list is where every app puts this, so it is where a
          // customer looking for it looks first and everyone else never does.
          _MenuRow(
            key: const Key('account-auth-action'),
            icon: signedIn ? Symbols.logout : Symbols.login,
            label: signedIn ? 'Log out' : 'Sign in',
            danger: signedIn,
            onTap: () =>
                signedIn ? _confirmSignOut(context, ref) : context.push('/login'),
          ),

          AppSpacing.vMd,
          Center(child: Text('Trueway Farms - v1.0.0', style: context.text.caption)),
          // Which backend this build talks to. Debug only — a customer must
          // never see it, and a release build must never carry it.
          //
          // `AppConfig.origin` is a `String.fromEnvironment`, i.e. resolved at
          // COMPILE time. A hot restart therefore does NOT pick up a changed
          // `--dart-define=API_ORIGIN=...`; only a full stop-and-run does. That
          // is genuinely easy to get wrong — a session testing "against local"
          // read 91 orders off the live server and nobody could tell from the
          // UI, because the two databases render identically. Printing the
          // origin is the cheapest way to make the mistake visible instead of
          // silent.
          if (kDebugMode) ...[
            AppSpacing.vXs,
            Center(
              child: Text(
                AppConfig.origin,
                style: context.text.caption.copyWith(
                  color: _isLocalBackend
                      ? context.colors.savings
                      : context.colors.muted,
                ),
              ),
            ),
          ],
            ],
          ),
        ],
      ),
    );
  }

  /// True when this build points at something other than a public server.
  ///
  /// Only used to tint the debug line, so a glance says "local" or "not local"
  /// without reading the whole URL.
  static bool get _isLocalBackend =>
      AppConfig.origin.contains('.test') ||
      AppConfig.origin.contains('localhost') ||
      AppConfig.origin.contains('127.0.0.1') ||
      AppConfig.origin.contains('10.0.2.2');

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'You will need to verify your mobile number again to see your orders.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(minimumSize: const Size(88, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(authProvider.notifier).logout();
    }
  }

  /// Opens a shop page in the **device browser**.
  ///
  /// Chrome rather than the in-app WebView, because these are ordinary web
  /// pages: the customer gets an address bar, their own bookmarks, text zoom
  /// and a share sheet, and the app is not asked to be a browser.
  ///
  /// Falls back to the in-app [WebViewScreen] when nothing external could take
  /// it — a device with no browser, or a platform with no `url_launcher`. The
  /// page stays reachable either way, which matters more than which viewer
  /// shows it.
  ///
  /// Both query parts of the fallback are encoded rather than pasted: the title
  /// carries an ampersand ("Shipping & delivery"), and an unencoded `&` would
  /// be read as the start of another parameter — the header would arrive
  /// truncated at "Shipping ".
  Future<void> _openPage(
    BuildContext context,
    WidgetRef ref,
    _InfoPage page,
  ) async {
    final opened = await ref.read(externalLauncherProvider)(Uri.parse(page.url));
    if (opened || !context.mounted) return;

    context.push(
      '/web'
      '?url=${Uri.encodeComponent(page.url)}'
      '&title=${Uri.encodeComponent(page.label)}',
    );
  }
}

/// The one line a signed-out visitor sees above the menu.
///
/// This is what is left of the old header, and "not tappable" is the point:
/// there is no profile to open yet, and the way in is the "Sign in" row down
/// in OTHER INFORMATION ([AccountScreen]'s `account-auth-action`), not a
/// sentence at the top of the screen that happens to be live.
///
/// Signed in it is not built at all — see the mount site. The name and phone
/// number it used to carry there are on the profile screen the menu already
/// links to.
/// Whose account this is: picture, name, phone.
///
/// Centred and above everything else, which is where every account tab a
/// customer already uses puts it — and the fastest way to notice you are
/// signed into the wrong account.
///
/// The picture follows the same rule as the home header's: a real upload when
/// the server has one, initials otherwise. The server *does* send an avatar
/// for customers with no upload, but it is a generated-initials PNG embedded
/// as a base64 `data:` URI — several KB, re-encoded per request — which
/// [Customer.fromJson] strips. Drawing the initials locally is the same
/// picture without the payload.
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.customer});

  final Customer? customer;

  static const double _size = 84;

  @override
  Widget build(BuildContext context) {
    final customer = this.customer;

    return Column(
      key: const Key('account-profile-header'),
      children: [
        Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            color: context.colors.surfaceAlt,
            shape: BoxShape.circle,
            border: Border.all(color: context.colors.hairline),
          ),
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.center,
          child: switch (customer) {
            null => Icon(
                AppIcons.user,
                size: 40,
                weight: _iconWeight,
                color: context.colors.faint,
              ),
            final c when c.hasAvatar =>
              AppNetworkImage(url: c.avatar!, width: _size, height: _size),
            final c => Text(
                c.initials,
                style: context.text.h2.copyWith(
                  color: context.colors.primaryDarker,
                ),
              ),
          },
        ),
        AppSpacing.vSm,
        Text(
          customer?.displayName ?? 'Your account',
          style: context.text.h2,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // Phone first, email second: this shop signs people in by phone, so
        // that is the identifier they recognise as theirs.
        if (customer != null &&
            ((customer.phone ?? '').isNotEmpty ||
                (customer.email ?? '').isNotEmpty)) ...[
          const SizedBox(height: 2),
          Text(
            (customer.phone ?? '').isNotEmpty
                ? customer.phone!
                : customer.email!,
            style: context.text.bodySm,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

class _SignInInvite extends StatelessWidget {
  const _SignInInvite();

  @override
  Widget build(BuildContext context) => Padding(
        key: const Key('account-header'),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
        child: Row(
          children: [
            Icon(
              Symbols.call,
              size: 16,
              weight: _iconWeight,
              color: context.colors.muted,
            ),
            AppSpacing.hXs,
            Text('Sign in to track your orders', style: context.text.bodySm),
          ],
        ),
      );
}

/// One of the three most-used destinations, as an icon over a label.
///
/// Three rather than the old screen's seven-item list: Orders, Wishlist and
/// Address are what a customer opens this tab *for* — the rest is reachable
/// one section down, not gone.
class _QuickAction extends StatelessWidget {
  const _QuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
        child: AppCard(
          elevated: true,
          onTap: onTap,
          border: MenuRowMetrics.outline(context),
          padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.md,
            horizontal: AppSpacing.xxs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 26, weight: _iconWeight, color: context.colors.ink),
              AppSpacing.vXs,
              Text(
                label,
                style: context.text.bodySm.copyWith(color: context.colors.ink),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      );
}

/// One destination, as its own card: an icon in a soft circle, a label, and a
/// chevron. Every row in "MY ACCOUNT" and "OTHER INFORMATION" is one of these.
///
/// A row per card rather than the old screen's single card holding a Column of
/// dividers — that grouping is what made twelve unrelated destinations read as
/// one long list. Spacing between cards does the same organisational job with
/// nothing to misread as a boundary.
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.grouped = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Colours the row for a destructive action, and drops the chevron.
  ///
  /// Exactly one row is this: signing out. The chevron goes because it is a
  /// promise about what a tap does — every other row slides a screen in, and
  /// this one throws the session away. Red is the second half of that warning;
  /// on its own, a red row that still wore a chevron would be shouting and
  /// pointing in different directions.
  ///
  /// Deliberately NOT set for the signed-out "Sign in" row that shares this
  /// call site: signing in destroys nothing.
  final bool danger;

  /// Drawn inside a [_MenuGroup] — no card of its own, because the group is
  /// the card. Only [_MenuGroup] sets this.
  final bool grouped;

  /// This row as a member of a group.
  _MenuRow _inGroup() => _MenuRow(
        key: key,
        icon: icon,
        label: label,
        onTap: onTap,
        danger: danger,
        grouped: true,
      );

  @override
  Widget build(BuildContext context) {
    final tone = danger ? AppColors.error : context.colors.primaryDark;

    final row = Padding(
      padding: MenuRowMetrics.padding,
      child: Row(
        children: [
          // No disc behind it. Twelve tinted circles down a single card read
          // as twelve buttons; the icon alone reads as what it is — a marker
          // for the row. The badge's width is kept so the labels still line up
          // and the divider's indent still lands past the icons.
          //
          // Outlined, at weight 400.
          //
          // Filled was tried and rejected: solid glyphs down a menu read as
          // twelve buttons, the same problem the tinted discs had. The stroke
          // stays, and the softening comes from the weight instead — 300 draws
          // a hairline that meets at visibly hard corners at 20dp, 400 has
          // enough body for the Rounded family's terminals to actually show.
          SizedBox(
            width: MenuRowMetrics.badge,
            height: MenuRowMetrics.badge,
            child: Align(
              // Flush left, so the glyph starts where the heading does. Centred
              // in its 28dp box it sat a few pixels in, and the heading looked
              // misaligned against a column of icons that were not where they
              // appeared to be.
              alignment: Alignment.centerLeft,
              child: Icon(icon, size: 20, weight: _iconWeight, color: tone),
            ),
          ),
          AppSpacing.hSm,
          Expanded(
            child: Text(
              // `bodySm` (13) rather than `body` (14): a menu label is a
              // destination, not prose, and one step down is what lets the
              // list read as a list rather than as fourteen paragraphs.
              label,
              style: danger
                  ? context.text.bodySm.copyWith(color: AppColors.error)
                  : context.text.bodySm.copyWith(color: context.colors.ink),
            ),
          ),
          if (!danger)
            Icon(
              AppIcons.caretRight,
              weight: _iconWeight,
              color: context.colors.faint,
            ),
        ],
      ),
    );

    if (grouped) {
      return InkWell(onTap: onTap, child: row);
    }
    return AppCard(
      elevated: true,
      onTap: onTap,
      padding: EdgeInsets.zero,
      border: MenuRowMetrics.outline(context),
      child: row,
    );
  }
}

/// A run of [_MenuRow]s inside **one** card, split by hairlines.
///
/// The screen used to give every destination its own card, on the argument
/// that a single card holding twelve rows read as one long undifferentiated
/// list. That is true of twelve — it is not true of a named group of related
/// ones, and a column of separate cards spends a lot of vertical space saying
/// "these are unrelated" about rows that are not.
///
/// So: grouped under a heading, the way an account screen is normally read.
class _MenuGroup extends StatelessWidget {
  const _MenuGroup({required this.title, required this.children});

  /// Drawn as the card's own first row.
  ///
  /// It used to float above the card as a bare label. Inside is where it
  /// belongs: a heading sitting in the gap between two cards belongs to
  /// neither of them, and on a screen of stacked cards the eye reads it as
  /// closing the one above rather than opening the one below.
  final String title;

  final List<_MenuRow> children;

  @override
  Widget build(BuildContext context) => AppCard(
        elevated: true,
        padding: EdgeInsets.zero,
        border: MenuRowMetrics.outline(context),
        child: Column(
          children: [
            Padding(
              // Left inset matches a row's, so the heading starts exactly
              // where the icons below it do rather than hanging into the
              // card's margin.
              padding: EdgeInsets.only(
                left: MenuRowMetrics.padding.left,
                right: MenuRowMetrics.padding.right,
                top: AppSpacing.sm,
                bottom: AppSpacing.xs,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  // Sentence case, not SHOUTING CAPS: this is a heading inside
                  // the card, not a system label floating above it, and caps at
                  // 11px with tracking is the one thing on the screen that
                  // cannot be skimmed.
                  title,
                  style: context.text.title
                      .copyWith(color: context.colors.ink),
                ),
              ),
            ),
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  // Indented past the icon badge, so the rule separates the
                  // labels rather than cutting the row in half.
                  indent: MenuRowMetrics.badge + AppSpacing.md + AppSpacing.sm,
                  color: context.colors.hairline,
                ),
              children[i]._inGroup(),
            ],
          ],
        ),
      );
}

/// A CMS page on the shop, as a menu row.
///
/// [path] is stored, never a full URL: `AppConfig.origin` is a compile-time
/// `--dart-define`, so a build pointed at production must not carry a link to
/// the dev server. That is the same mistake `/web`'s own route guards against —
/// see `app_router.dart`.
class _InfoPage {
  const _InfoPage(this.icon, this.label, this.path);

  final IconData icon;

  /// What the row says. Not derived from [path]: the shop's URL for the
  /// returns policy is misspelled (`cancelation-return`, one L), and that is
  /// the server's business — a customer should still read correct English.
  final String label;

  /// The path on the shop, without a leading slash.
  final String path;

  String get url => '${AppConfig.origin}/$path';
}

/// Help and policy pages, in the order the shop lists them.
///
/// All five verified live on 2026-08-12 — each returns 200 with no redirect.
/// They are public, so none of them is behind [AccountScreen.build]'s `guarded`.
const List<_InfoPage> _infoPages = [
  _InfoPage(AppIcons.info, 'About us', 'about-us'),
  _InfoPage(AppIcons.mail, 'Contact us', 'contact'),
  _InfoPage(
    AppIcons.truck,
    'Shipping & delivery',
    'shipping-delivery',
  ),
  _InfoPage(
    Symbols.policy,
    // "Cancellation" with two Ls. The path keeps the shop's spelling because
    // that is the URL that resolves; the label does not have to inherit it.
    'Cancellation & returns',
    'cancelation-return',
  ),
  _InfoPage(Symbols.help, 'FAQ', 'faq'),
];

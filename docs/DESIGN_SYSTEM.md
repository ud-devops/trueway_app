# Design System

All design tokens live in [`lib/core/design_system/`](../lib/core/design_system/).
**Never hardcode** a color, size, radius, font, or icon in a screen — always
reference these. The visual language is the **"Ashop" grocery layout recoloured
to the Trueway green brand**: white base, green primary, warm/teal accents,
rounded cards, premium Material Symbols icons.

## Colors — `app_colors.dart` (`AppColors`)

| Token | Hex | Use |
|---|---|---|
| `primary` | `#40B048` | Brand green (sampled from logo). CTAs, active states |
| `primaryDark` / `primaryDarker` | `#2E8B39` / `#1F6B29` | Prices, emphasis, gradients |
| `primaryLight` / `primarySoft` / `primarySurface` | `#7CCB80` / `#E7F5E8` / `#F1F9F1` | Tints, chips, soft fills |
| `accent` / `accentDark` / `accentSoft` | `#F59E0B` / `#D97706` / `#FEF3E2` | Harvest amber — offers, discount tags |
| `teal` / `tealSoft` | `#0E9A94` / `#DFF3F1` | Secondary accent (variety) |
| `berry`, `sky` | `#E0518A`, `#3B9FE0` | Sparingly — wishlist heart, misc |
| `ink` / `body` / `muted` / `faint` | `#0F1B12` … `#9AA69C` | Text ramp (headings → hints) |
| `line` / `hairline` | `#E4E9E4` / `#EEF1EE` | Borders / dividers |
| `background` / `surface` / `surfaceAlt` | `#F7F8F6` / `#FFFFFF` / `#FBFCFB` | Page / card / subtle fills |
| `success` `warning` `error` `info` `savings` | — | Semantic |
| Dark-theme set | `dark*` | Full dark palette |

**Category-tile pastels** — `tilePastels[]` + `tileTints[]` (mint, butter, sky,
lilac, peach, blush) via `AppColors.tileBg(i)` / `tileTint(i)`. This is what makes
the category row colorful without breaking the green identity.

**Gradients** — `heroGradient` (green→teal), `offerGradient` (amber),
`brandGradient`, `splashGradient`, `homeHeaderWash` (subtle top wash).

## Typography — `app_typography.dart` (`AppTypography`)

Single family **Poppins** (via `google_fonts`, fetched at runtime — bundle it for
offline/perf later). Ramp: `display, h1, h2, h3, title, bodyLg, body, bodySm,
caption, overline, price, priceLg, strike, button, buttonSm`. `textTheme()` wires
it into `ThemeData`.

## Icons — `app_icons.dart` (`AppIcons`)

**Material Symbols (Rounded)** via `material_symbols_icons` — a premium variable
icon family. Active/selected states use the **FILL axis**:
`Icon(AppIcons.home, fill: 1, weight: 600)`. All app icons are referenced through
`AppIcons` (one file) — swapping icon sets is a single-file change.

> ⚠️ Do **not** reintroduce `phosphor_flutter` — it's incompatible with Flutter
> 3.44 (see KNOWN_ISSUES). Material Symbols is the replacement.

## Spacing / radius / shadow — `app_spacing.dart`

- `AppSpacing` — 4-pt scale (`xxs`4 … `huge`48), page `gutter`16, and ready-made
  `SizedBox` gaps (`vSm`, `hMd`, `gapLg`, …).
- `AppRadius` — `sm`8 `md`12 `lg`16 `xl`20 `xxl`28 `pill`999 (+ `rSm`…`rPill`
  `BorderRadius` consts). Cards use `rXl`; buttons are pill.
- `AppShadows` — `soft`, `card`, `raised` (consistent elevation).

## Theme — `app_theme.dart` (`AppTheme.light` / `.dark`)

Material 3. Pill `ElevatedButton`/`OutlinedButton`, centered app bars, themed
inputs, bottom sheets, snackbars, and a `navigationBarTheme` (green pill
indicator, Poppins labels). Dark theme is a full override. Wired in `main.dart`
with `themeProvider` controlling light/dark.

## Responsive — `core/utils/responsive.dart`

`Responsive.productColumns(width)` (2→5), `categoryColumns`, `gutter`,
`productAspect`. Grids call these off `MediaQuery.sizeOf(context).width` so the
layout adapts phone → tablet.

## Reusable components (`presentation/widgets/`)

| Widget | Purpose |
|---|---|
| `ProductCard` | The catalogue card — image, discount tag, wishlist heart, rating pill, floating **+** → stepper. Used everywhere products are listed |
| `SectionHeader` | Titled section w/ optional colored icon chip + "See all" |
| `QuantityStepper` / `AddToCartControl` | Cart quantity controls |
| `HomeSliderCarousel` | Auto-advancing banner carousel with dots |
| `AppNetworkImage` | Cached image with placeholder + error fallback — **use this for all remote images** |
| `state_views.dart` | `LoadingView`, `AppErrorView` (with retry), `EmptyView` — **reuse for every loading/error/empty state** so the app stays consistent |

## Brand assets
- Logo: `assets/images/logo.png` ("TRUEWAY FARMS — Transforming Nature to Natural").
- **TODO:** the launcher icon + native splash are still Flutter defaults — replace
  before release (`flutter_launcher_icons` + `flutter_native_splash`).

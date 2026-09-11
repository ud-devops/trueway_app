# Trueway Farms — Mobile App (Flutter)

Organic-grocery e-commerce app for **Trueway Organic Pvt Ltd** ("Trueway Farms —
_Transforming Nature to Natural_"). Native Flutter client for the Trueway
storefront, talking to a Botble/Laravel e-commerce backend.

> **New to this project? Start with [`docs/HANDOFF.md`](docs/HANDOFF.md).**
> It explains the history, current state, and exactly where to pick up.

---

## Status at a glance

| | |
|---|---|
| **Platform** | Android (primary) + Web (untested). **No `ios/` directory exists** — iOS does not build until `flutter create --platforms=ios .` is run. |
| **Flutter** | 3.41.4+ / Dart 3.11+ (verified on 3.41.4; the README previously required 3.44.8) |
| **App ID** | `com.trueway.trueway_farms` |
| **Backend** | `https://dev.truewayerp.com` (Botble/Laravel) · REST `/api/v1` |
| **Brand** | Green `#40B048` · font Poppins · icons Material Symbols Rounded |
| **Build** | Signed release APK ✅ **77.7 MB**. Build with `tool\build_release.ps1` — release **must** pass `--no-tree-shake-icons` or icons render blank ([why](docs/BUILD_AND_RUN.md#-no-tree-shake-icons-is-required-not-optional)) |
| **Tests** | 104 unit tests ✅ · `flutter analyze` clean ✅ |
| **Auth** | OTP login wired to `/api/v1/otp/*` (Sanctum token, persisted, 401 auto-logout). Needs a registered customer to test — no mobile signup endpoint exists. |
| **What works** | Catalogue (home, categories, product detail, search), cart (persisted), checkout form + order-success — all on **live data** |
| **What's stubbed** | OTP login, Razorpay payment, product variants, wishlist, order history — **UI done, backend not wired** (see [`docs/ROADMAP.md`](docs/ROADMAP.md)) |
| **Not shippable yet** | Checkout creates **no order** and takes **no payment**; OTP accepts any 6-digit code. Demo only. |

---

## Quick start

```bash
# 1. Install Flutter 3.41+  (https://docs.flutter.dev/get-started/install)
flutter --version

# 2. Get packages
flutter pub get

# 3. Run on a connected device / emulator
flutter run

# 4. Tests + static analysis
flutter test
flutter analyze

# 5. Build a debug APK
flutter build apk --debug

# 6. Build the SIGNED release APK  (needs android/key.properties — see docs)
flutter build apk --release

# 6b. Smaller per-architecture APKs (recommended for distribution)
flutter build apk --release --split-per-abi
```

> ⚠️ **On the original Windows build machine** the Android build needs an extra
> temp-dir workaround or it fails with "Unable to establish loopback connection".
> See [`docs/BUILD_AND_RUN.md`](docs/BUILD_AND_RUN.md).

---

## Project structure

```
lib/
├── core/                     # cross-cutting foundation
│   ├── config/               # AppConfig — base URL, API key, timeouts
│   ├── design_system/        # colors, typography, spacing, theme, icons
│   ├── errors/               # ApiException
│   ├── network/              # Dio ApiClient, endpoints, response envelopes
│   ├── pricing/              # OrderSummary — the ONLY place order totals are computed
│   └── utils/                # price / json / validators / responsive helpers
├── data/                     # data layer
│   ├── models/               # Product, Category, Slider, Ad, Brand, CartItem
│   └── repositories/         # CatalogRepository (all catalogue API calls)
├── presentation/             # UI layer (Riverpod + go_router)
│   ├── providers/            # Riverpod providers (DI + state)
│   ├── router/               # go_router routes
│   ├── screens/              # one folder per feature area
│   └── widgets/              # shared widgets (ProductCard, cards, states…)
└── main.dart                 # entry point + ProviderScope + theme

test/                         # unit tests (core/, data/, presentation/)
docs/                         # 📖 handoff documentation (read these)
android/                      # Android host project (+ release keystore config)
assets/images/                # logo.png
_recovered/                   # ⚙️ APK-recovery artefacts (blueprint + API samples)
```

## Documentation index

| Doc | What's in it |
|---|---|
| [HANDOFF.md](docs/HANDOFF.md) | **Read first.** Origin story, current state, priorities, how to continue |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Clean Architecture layers, state management, routing, data flow |
| [BUILD_AND_RUN.md](docs/BUILD_AND_RUN.md) | Environment, build/run, release signing, Windows gotchas |
| [BACKEND_API.md](docs/BACKEND_API.md) | Backend, endpoints, API key, models, pending authed endpoints |
| [DESIGN_SYSTEM.md](docs/DESIGN_SYSTEM.md) | Colors, type, icons, spacing, components |
| [MOBILE_API_INTEGRATION_PLAN.md](docs/MOBILE_API_INTEGRATION_PLAN.md) | **Section-wise plan to wire the full backend API** (auth, cart, coupons, checkout, orders) |
| [ERROR_HANDLING.md](docs/ERROR_HANDLING.md) | Error policy: show server messages verbatim, when the app may substitute, how to log |
| [ROADMAP.md](docs/ROADMAP.md) | Pending features + implementation guidance |
| [KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) | Gotchas, security notes, package caveats |

---

_Property of Trueway Organic Pvt Ltd. Internal handoff documentation._

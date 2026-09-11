# Error Handling

## The rule

**Show the server's message verbatim. Do not paraphrase it on the client.**

The Botble backend writes specific, actionable copy — *"Invalid or expired OTP.
Please try again."*, *"Maximum quantity is 5!"*, *"Product X is out of stock!"*,
*"Minimum order quantity is 2, you need to buy more 1 to place an order!"*.
Rewriting those on the client is actively harmful:

* the app drifts out of sync whenever backend rules change,
* the real cause gets hidden behind a generic sentence,
* two sources of truth for the same rule means they eventually disagree.

The **only** text the app substitutes is what a user cannot act on: HTML error
pages, stack traces, SQL errors, transport jargon. Even then the original is
never discarded — it moves to `developerDetail`, which reaches the logs and the
debug-only details panel.

## Layers

```
Dio  ──▶ ApiClient._wrap ──▶ ApiException ──▶ provider state ──▶ AppErrorView
             │                    │                                InlineErrorStrip
             │                    ├─ message          (show this)   showErrorSnack
             └─ ErrorLog.capture  ├─ serverMessage    (verbatim)
                (logged once)     ├─ fieldErrors      (verbatim)
                                  ├─ kind             (branch on this)
                                  └─ developerDetail  (debug only)
```

### `ApiException` — `lib/core/errors/api_exception.dart`

| Field | Meaning |
|---|---|
| `message` | What to show the user. Equals `serverMessage` when that is fit to display. |
| `serverMessage` | Exactly what the server said, unmodified. Null if the request never reached it. |
| `fieldErrors` | Laravel's `errors` bag, shown verbatim. |
| `kind` | `network`, `timeout`, `unauthorized`, `validation`, `server`, … — branch on this, never on message text. |
| `developerDetail` | Method, URL, status, transport message, body preview. Debug only. |
| `isServerAuthored` | True when `message` is the server's own wording. |

Both response envelopes are parsed:

```jsonc
{ "error": true, "data": null, "message": "Phone number not found!" }      // Botble
{ "message": "…", "errors": { "phone": ["Phone number is required."] } }   // Laravel
```

### The substitution gate

`ApiException.isDeveloperFacing(String)` is the single, tested predicate
deciding show-vs-substitute. It rejects HTML, stack traces, `SQLSTATE`, PHP
fatals, source paths, Dio/Socket exception names, and anything over 300
characters.

It is deliberately **permissive** — anything reading like a sentence gets
through. Being too strict is the worse failure: it silently hides the backend's
useful messages, which is the exact problem this class exists to prevent. If you
tighten it, add a test in `test/core/api_exception_test.dart` first.

## Using it

**Full-screen failure** — always pass the *object*, never a string:

```dart
AppErrorView(error: e, onRetry: () => ref.invalidate(someProvider))
```

Renders the icon for the kind, a heading only when the message is ours (no
"Something went wrong" stacked on top of a real server message), every field
error, a retry button only when `kind.isRetryable`, and the developer panel in
debug builds.

**Non-critical section of a screen:**

```dart
InlineErrorStrip(error: e, label: 'categories', onRetry: () => ref.invalidate(p))
```

**A failed action** (add to cart, apply coupon, place order):

```dart
context.showErrorSnack(e);          // or showSuccessSnack('…')
```

**Anything non-`ApiException`** goes through `ErrorPresenter.resolve()`, so a
`FormatException` can never leak its `toString()` into the UI.

## Logging

`ApiClient._wrap` is the single choke point: every HTTP failure is normalized
and logged **once**, with the request attached. **Do not call `ErrorLog.capture`
for API errors in providers or widgets** — it double-logs. Capture manually only
for non-HTTP failures (cache parse, third-party SDKs).

`ErrorLog` is also the seam where a crash reporter gets wired in — it is
currently a `dart:developer` log, and the app still has no Crashlytics/Sentry.

## Rules

1. Never render `'$e'`, `e.toString()`, or a pre-formatted string into an error
   widget. Pass the object.
2. Never branch on message text — branch on `kind`, or add a typed subclass
   (see `OtpUnknownPhoneException`). Subclasses must use `.from(e)` so no
   context is lost.
3. Never swallow an error. If a failure is genuinely non-blocking (pincode
   autofill), log it and tell the user why the outcome differs.
4. Never store a flattened `String?` error in provider state — store the
   `ApiException`.
5. `developerDetail` must never reach a release UI. `ErrorPresenter
   .developerDetail()` returns null when `kReleaseMode`.

## What this replaced

| Before | After |
|---|---|
| `AppErrorView(message: '$e')` in 3 screens → users saw `ApiException(422): …` | The object is passed; users see the server's sentence. |
| `ProductListState.error` was `String?` | Holds the `ApiException`; field errors and kind survive. |
| Home hid slider/ads/category failures with `SizedBox.shrink()` | `InlineErrorStrip` — a broken endpoint no longer looks like "no data". |
| Pincode lookup `catch (_) {/* silent */}` | Logged, with a note under the field explaining the empty city/state. |
| Cart cache `catch (_) {/* ignore */}` | Logged, and the corrupt entry is cleared. |
| `statusCode`-based `isNetwork`/`isUnauthorized` | `kind` enum covering timeout, rate-limit, forbidden, validation, … |

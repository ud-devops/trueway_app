# Keep rules for the release build (R8 is enabled in build.gradle.kts).
#
# The Flutter Gradle plugin already contributes the engine's own keep rules, so
# this file only needs to cover the plugins this app actually uses.

# --- Flutter engine / embedding -------------------------------------------
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# --- webview_flutter -------------------------------------------------------
# JavascriptInterface members are reached by name from JS.
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# --- Kotlin / AndroidX -----------------------------------------------------
-dontwarn kotlin.**
-dontwarn kotlinx.**

# Keep annotations so reflective lookups keep working.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

# Preserve line numbers for readable release stack traces, but hide the
# original source file names.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# --- razorpay_flutter ------------------------------------------------------
# Now active: payments are wired (lib/core/payments/razorpay_gateway.dart).
#
# These are Razorpay's own published rules and they are not optional here —
# R8 and resource shrinking are both on for `release` above. Without them the
# checkout SDK's classes are stripped or renamed and the payment callback never
# fires, which fails **only in release**: a debug build looks perfectly fine.
-keep class com.razorpay.** { *; }
-dontwarn com.razorpay.**

# The SDK finds onPaymentSuccess / onPaymentError reflectively, by name, so the
# usual "unused method" reasoning does not apply to them.
-keepclasseswithmembers class * {
    public void onPayment*(...);
}

# Razorpay ships pre-optimised; re-inlining its methods breaks the reflective
# lookups above.
-optimizations !method/inlining/

# proguard-android-optimize.txt keeps annotations for the classes it keeps, but
# Razorpay's rules ask for them globally. Already covered by the -keepattributes
# line further up; repeated here only so this block stays self-contained if the
# file is ever reorganised.
-keepattributes *Annotation*

# ---------------------------------------------------------------------------
# KEEP EVERYTHING THIS APP AND ITS PLUGINS SHIP
# ---------------------------------------------------------------------------
#
# Why this block exists
# ---------------------
# R8 removes any class it cannot see a call to. Every plugin below is reached
# from Dart across the platform channel — never from Java/Kotlin — so R8 sees
# no caller and is free to delete or rename the whole thing. The result fails
# **only in the release build**: debug has no R8 at all, so the app looks
# perfect right up until the signed build reaches a device.
#
# NOTE: none of these rules affect the missing Material Symbols icons. Those
# are font glyphs removed by Flutter's Dart icon tree-shaker, not by R8 — the
# fix for those is building with `--no-tree-shake-icons`. Keep rules here and
# the icon flag there are two separate problems with two separate switches.

# --- This app's own code ---------------------------------------------------
-keep class com.trueway.trueway_farms.** { *; }

# --- Plugins registered from Dart, never called from Java ------------------
# GeneratedPluginRegistrant instantiates each of these by name at startup.
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugin.editing.** { *; }
-dontwarn io.flutter.plugins.**

# webview_flutter — the WebView renders the shop's CMS pages (About us,
# Contact, Shipping & delivery, Cancellation & returns, FAQ).
-keep class io.flutter.plugins.webviewflutter.** { *; }

# image_picker — return evidence, review photos, profile avatar.
-keep class io.flutter.plugins.imagepicker.** { *; }
-keep class androidx.core.content.FileProvider { *; }
-keep class * extends androidx.core.content.FileProvider { *; }

# share_plus / url_launcher / open_filex — all resolve Intents by name.
-keep class dev.fluttercommunity.plus.share.** { *; }
-keep class io.flutter.plugins.urllauncher.** { *; }
-keep class com.crazecoder.openfile.** { *; }

# sqflite + path_provider — local cart/session storage.
-keep class com.tekartik.sqflite.** { *; }
-keep class io.flutter.plugins.pathprovider.** { *; }

# --- Data classes crossing the platform channel ----------------------------
# Field names are the wire format; renaming them silently breaks decoding.
-keepclassmembers class * implements android.os.Parcelable { *; }
-keepclassmembers class * implements java.io.Serializable { *; }
-keepclassmembers enum * { *; }

# --- Native (JNI) methods --------------------------------------------------
# Resolved by exact name at runtime; a rename is an UnsatisfiedLinkError.
-keepclasseswithmembernames class * {
    native <methods>;
}

# --- Silence warnings for optional deps that are simply absent -------------
-dontwarn javax.annotation.**
-dontwarn com.google.errorprone.annotations.**

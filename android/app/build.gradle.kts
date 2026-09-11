import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // Declared explicitly. It is versioned in settings.gradle.kts with
    // `apply false`, and this module never applied it — the Kotlin DSL below
    // only resolved because the `fluttertoast` dependency applied KGP as a side
    // effect. See the note in the root build.gradle.kts.
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.trueway.trueway_farms"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.trueway.trueway_farms"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val hasKeystore = keystorePropertiesFile.exists()
            if (hasKeystore) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8 + resource shrinking. Previously both off, which is a large
            // part of why the universal release APK was 62.6 MB.
            // Build with --split-per-abi (or an app bundle) to cut it further.
            //
            // Nothing this module ships is deleted: proguard-rules.pro keeps
            // every plugin class (they are reached only from Dart, so R8 sees
            // no caller), and res/raw/keep.xml keeps every resource.
            //
            // ---- MISSING ICONS ARE NOT CONTROLLED HERE ----
            // Blank / absent Material Symbols in a release build come from
            // Flutter's Dart icon tree-shaker, which subsets the icon font to
            // the glyphs it can prove are used. material_symbols_icons ships
            // *variable* fonts (FILL and weight axes) and the subsetter breaks
            // them, so glyphs go missing in release while debug is fine.
            // No Gradle or ProGuard setting affects it -- it is a flutter CLI
            // flag, and every release build must carry it:
            //
            //   flutter build apk      --release --no-tree-shake-icons
            //   flutter build appbundle --release --no-tree-shake-icons
            //
            // Cost is real and it is not small: the three un-subsetted
            // Material Symbols faces measured in the shipped APK are
            // Rounded 15.0 MB + Outlined 10.6 MB + Sharp 8.8 MB = 34.5 MB,
            // which took the universal release APK from 62.6 MB to 78.3 MB.
            // Pay it anyway -- blank icons are not shippable -- but note two
            // ways to earn it back, in order of value:
            //
            //  1. Ship an app bundle. Play serves one ABI per device, and the
            //     native libs are ~63 MB of this APK across three ABIs.
            //     For a directly-shared APK use --split-per-abi instead.
            //  2. Sharp is never referenced; Outlined is referenced by 14
            //     call sites that use a bare `Symbols.x` while AppIcons uses
            //     `Symbols.x_rounded` for the other 35. Moving those 14 onto
            //     the rounded cut makes the UI consistent (which is what the
            //     AppIcons doc already claims) and drops the 10.6 MB Outlined
            //     face with it.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

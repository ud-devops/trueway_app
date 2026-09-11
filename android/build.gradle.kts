allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Apply the Kotlin Gradle Plugin to every Android module.
//
// This used to happen by accident: the `fluttertoast` dependency applied KGP,
// and the Flutter Gradle Plugin then propagated it across the plugin modules.
// Removing that unused dependency broke the build, because the app's own
// `kotlin { }` block and share_plus's build script both need the KGP extension
// while shared_preferences_android still applies `kotlin-android` explicitly
// (so `android.builtInKotlin=true` is not an option either — see
// gradle.properties). Declaring it here makes the requirement explicit and
// independent of which packages happen to be in pubspec.yaml.
subprojects {
    plugins.withId("com.android.library") {
        apply(plugin = "org.jetbrains.kotlin.android")
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

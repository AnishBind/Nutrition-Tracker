plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    // ✅ Namespace required in AGP 8+
    namespace = "com.example.nutrition_tracker"

    // ✅ Compile SDK from Flutter
    compileSdk = flutter.compileSdkVersion

    // ✅ Force NDK version (only if needed for native plugins)
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // ✅ Your unique application ID
        applicationId = "com.example.nutrition_tracker"

        // ⚠ minSdk set manually to avoid plugin errors
        minSdk = 21

        // Target SDK from Flutter config
        targetSdk = flutter.targetSdkVersion

        // App version
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Currently using debug signing for testing.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

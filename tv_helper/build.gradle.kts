// OmniFlow's pointer helper for Android TV. It draws a mouse pointer over
// whatever is on screen and takes moves only from ADB, on an abstract Unix
// socket. It has no network permission and no dependencies beyond the
// Android framework.
//
// Build it and copy it into the app's assets with
//   dart run packages/omniflow_app/tool/tv_helper_asset.dart
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.jashnm.omniflow.tvhelper"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.jashnm.omniflow.tvhelper"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            // Installed over ADB, never from a store, so the debug key is
            // enough. A changed key would only mean reinstalling.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// The Android counterpart of `Examples/CollieHarness`: a one-button host that calls
// `Collie.presentReport()`, so the banner, the form and the markup editor can be driven on an
// emulator without waiting for a shake. It doubles as the API-compatibility gate in CI — the
// release workflow compiles it against `:collie` and against `:collie-no-op`, so a signature
// that drifts between the two fails the build.
android {
    namespace = "com.collie.sample"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.collie.sample"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
}

// `-PcollieNoOp` swaps the real artifact for the no-op one. CI builds the sample both ways;
// locally the default (the real Collie) is what you want.
val useNoOp = (findProperty("collieNoOp") as? String)?.toBoolean() ?: false

dependencies {
    if (useNoOp) {
        implementation(project(":collie-no-op"))
    } else {
        implementation(project(":collie"))
    }

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    debugImplementation(libs.compose.ui.tooling)
}

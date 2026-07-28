plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// A realistic host app: it makes real HTTP calls, inspects them with Chucker, and files bug
// reports with Collie — wired together the way a real project wires them, including the
// debug/release artifact split that keeps both tools out of a production build.
android {
    namespace = "com.collie.example"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.collie.example"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"

        // Collie's backend settings never live in source. A real project feeds these from a
        // secrets file that is not committed; here they are literals so the example runs with
        // no setup, and they point at a public echo service rather than anyone's backend.
        buildConfigField("boolean", "COLLIE_ENABLED", "true")
        buildConfigField("String", "COLLIE_API_BASE_URL", "\"https://postman-echo.com\"")
        buildConfigField("String", "COLLIE_API_KEY", "\"example-api-key\"")
    }

    buildTypes {
        debug {
            // The tools are on in debug only — see the dependency block.
            buildConfigField("boolean", "COLLIE_ENABLED", "true")
        }
        release {
            isMinifyEnabled = false
            // ⚠️ The gate that matters: a release build never enables the reporter, and links
            // the no-op artifacts so the code is not there to enable.
            buildConfigField("boolean", "COLLIE_ENABLED", "false")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    // ── The two debug tools, each with its release counterpart ────────────────────────
    // Chucker inspects the traffic; Collie reports the bug. Both follow the same pattern:
    // the real artifact in debug, an API-identical no-op in release, so neither reaches
    // production even if someone forgets a flag.
    debugImplementation(libs.chucker)
    releaseImplementation(libs.chucker.no.op)

    debugImplementation(project(":collie"))
    releaseImplementation(project(":collie-no-op"))

    implementation(libs.okhttp)
    implementation(libs.androidx.core.ktx)
    implementation(libs.coroutines.android)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    debugImplementation(libs.compose.ui.tooling)
}

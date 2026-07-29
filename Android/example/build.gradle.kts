plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// The Firestore transport needs a `google-services.json`, which points at a specific Firebase
// project — so it is a local file, not a committed one (see .gitignore). When it is present the
// example writes reports to Firestore, the way an app whose network policy allows Firebase only
// would; when it is absent the example still builds and runs, falling back to the HTTPS transport
// against a public echo service. CI takes the second path.
val firebaseConfig = file("google-services.json")
val useFirestore = firebaseConfig.exists()
if (useFirestore) {
    apply(plugin = "com.google.gms.google-services")
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

        // Which transport the app wires up at startup.
        buildConfigField("boolean", "COLLIE_USE_FIRESTORE", useFirestore.toString())
        // Which app the report belongs to — the panel groups by this, and the key must match an
        // app record there or the bridge answers "Unknown appKey". Not a secret: write access is
        // enforced by the Firestore rules, not by keeping this hidden.
        buildConfigField("String", "COLLIE_APP_KEY", "\"ykb-nl-test\"")
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

    // The Firestore transport, debug-only like the reporter itself. Its release counterpart
    // lives inside `collie-no-op`, so the single line that builds the transport compiles in
    // both variants without splitting this file across source sets.
    debugImplementation(project(":collie-firebase"))

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

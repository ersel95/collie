plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    `maven-publish`
}

android {
    namespace = "com.collie"
    compileSdk = 36

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    publishing {
        // A single `release` component keeps the published POM as simple as the
        // iOS package's single SPM product.
        singleVariant("release") {
            withSourcesJar()
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    // The HTTPS transport. `api` (not `implementation`): a host that wants to inspect or
    // reuse the types sees them, and OkHttp is already in every app Collie ships with.
    api(libs.okhttp)

    implementation(libs.androidx.core.ktx)
    implementation(libs.coroutines.android)
    // Persistent retry after the host process exits. The worker is only packaged in the real
    // debug artifact; release builds link `collie-no-op` and carry no background work.
    implementation(libs.androidx.work.runtime)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    debugImplementation(libs.compose.ui.tooling)
    implementation(libs.compose.ui.tooling.preview)

    testImplementation(libs.junit)
    testImplementation(libs.json)
    testImplementation(libs.coroutines.test)
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = rootProject.extra["collieGroup"] as String
            artifactId = "collie"
            version = rootProject.extra["collieVersion"] as String

            afterEvaluate {
                from(components["release"])
            }

            pom {
                name.set("Collie")
                description.set("Shake-to-report bug reporter for Android test builds.")
                url.set("https://github.com/ersel95/collie")
                licenses {
                    license {
                        name.set("MIT License")
                        url.set("https://github.com/ersel95/collie/blob/main/LICENSE")
                    }
                }
                developers {
                    developer {
                        id.set("ersel95")
                        name.set("Ersel Tarhan")
                    }
                }
                scm {
                    url.set("https://github.com/ersel95/collie")
                }
            }
        }
    }
}

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    `maven-publish`
}

// The release counterpart of `:collie` — same public API surface, empty bodies.
// Consumers wire it up the way they already wire Olaf:
//   debugImplementation("com.github.ersel95.collie:collie:android-x.y.z")
//   releaseImplementation("com.github.ersel95.collie:collie-no-op:android-x.y.z")
// so no reporter code (no shake detector, no screenshot, no upload) reaches the production APK.
//
// This is a second line of defence, not the first: `CollieConfiguration.enabled` already
// defaults to false and the SDK fails closed. The no-op artifact makes it a build-time
// guarantee instead of a runtime one.
android {
    namespace = "com.collie.noop"
    compileSdk = 36

    defaultConfig {
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

dependencies {
    // Nothing. The real artifact keeps OkHttp, Compose and Firestore behind an internal
    // surface, so the no-op needs none of them to match its public signatures — which is the
    // whole point: a release build pulls in no reporter dependencies at all.
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = rootProject.extra["collieGroup"] as String
            artifactId = "collie-no-op"
            version = rootProject.extra["collieVersion"] as String

            afterEvaluate {
                from(components["release"])
            }

            pom {
                name.set("Collie No-Op")
                description.set("No-op variant of Collie for release builds.")
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

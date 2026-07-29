plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    `maven-publish`
}

// The Firestore transport, in its own artifact for the same reason `CollieFirebase` is its
// own SPM product: a host on the plain HTTPS path must never have to build Firebase.
android {
    namespace = "com.collie.firebase"
    compileSdk = 36

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
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

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    // `api`: the host passes the transport to `Collie.configure(...)`, so Collie's own types
    // are part of this module's public surface.
    api(project(":collie"))

    // A real dependency, not `compileOnly`: a host may reach for the Firebase transport
    // precisely because it has no backend of its own, in which case nothing else would put
    // Firestore on the runtime classpath. When the host does pin its own Firebase version,
    // Gradle's conflict resolution settles it — which is the same freedom the deliberately
    // wide SPM version range buys on iOS.
    api(platform(libs.firebase.bom))
    api(libs.firebase.firestore)

    implementation(libs.coroutines.android)

    testImplementation(libs.junit)
    // `org.json` is a stub on the JVM; the conversion test needs the real implementation.
    testImplementation(libs.json)
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = rootProject.extra["collieGroup"] as String
            artifactId = "collie-firebase"
            version = rootProject.extra["collieVersion"] as String

            afterEvaluate {
                from(components["release"])
            }

            pom {
                name.set("Collie Firebase")
                description.set("Firestore transport for Collie — for hosts whose network policy allows Firebase only.")
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

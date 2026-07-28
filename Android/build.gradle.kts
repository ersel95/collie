import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension

plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

// Published version. Locally it is the constant below (kept in step with Android/CHANGELOG.md);
// on a release build JitPack and CI pass the git tag through `-Pversion`, so the artifact always
// carries the tag it was built from and nothing has to be edited at release time.
// iOS keeps its own version line — see /CHANGELOG.md and /RELEASING.md.
private val localVersion = "0.1.0"
val collieVersion by extra(
    (findProperty("version") as? String)
        ?.takeIf { it.isNotBlank() && it != "unspecified" }
        ?: localVersion
)
val collieGroup by extra("com.github.ersel95.collie")

subprojects {
    plugins.withId("org.jetbrains.kotlin.android") {
        extensions.configure<KotlinAndroidProjectExtension> {
            compilerOptions {
                jvmTarget.set(JvmTarget.JVM_17)
                // Same bar as the iOS package: the build stays warning-free.
                allWarningsAsErrors.set(true)
            }
        }
    }
}

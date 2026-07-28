// Collie integration template — COPY THIS FILE INTO YOUR APP.
//
// It is not part of the published artifact; it exists to be copied and edited. Everything
// project-specific lives here, so upgrading Collie never means re-reading your own wiring.
//
// Where to find it if you added Collie from JitPack:
//   https://raw.githubusercontent.com/ersel95/collie/main/Android/Integration/CollieIntegration.kt
//
// ── Setup ──────────────────────────────────────────────────────────────────────────────
// 1. Dependency (app module):
//        debugImplementation("com.github.ersel95.collie:collie:android-0.1.0")
//        releaseImplementation("com.github.ersel95.collie:collie-no-op:android-0.1.0")
//    plus `maven { url = uri("https://jitpack.io") }` in settings.gradle.kts.
//
// 2. BuildConfig fields, fed from secrets that are NOT committed:
//        buildConfigField("String", "COLLIE_API_BASE_URL", "\"…\"")
//        buildConfigField("String", "COLLIE_API_KEY", "\"…\"")
//        debug   { buildConfigField("boolean", "COLLIE_ENABLED", "true") }
//        release { buildConfigField("boolean", "COLLIE_ENABLED", "false") }   // ⚠️ never true
//
// 3. Call `CollieIntegration.start(this)` from Application.onCreate().
// ───────────────────────────────────────────────────────────────────────────────────────

package com.example.yourapp.diagnostics

import android.app.Application
import android.util.Log
import com.collie.Collie
import com.collie.CollieConfiguration
import com.collie.CollieLogEntry

object CollieIntegration {

    /**
     * Call once, at startup — after the app's logging library is up, if logs are fed from one.
     */
    fun start(application: Application) {
        val configuration = CollieConfiguration(
            // Gate 1. Comes from BuildConfig, never a literal: a release build must not be able
            // to turn the reporter on by accident.
            enabled = BuildConfig.COLLIE_ENABLED,

            apiBaseUrl = BuildConfig.COLLIE_API_BASE_URL,
            apiKey = BuildConfig.COLLIE_API_KEY,
            environment = "staging",

            // `true` (default): a shake asks "Spotted a problem?" first — a shake can be
            // accidental. `false`: the form opens straight away.
            asksBeforeReporting = true,

            // Set to `false` when another shake-activated tool (Olaf) owns the gesture; Collie
            // is then reached only through `Collie.presentReport()`.
            activatesOnShake = true,

            // Recommended: hand Collie the app's logs. See `logSnapshot()` below.
            logSnapshotProvider = { logSnapshot() },

            // Collie's own diagnostics — worth forwarding to your logger while integrating.
            diagnostics = { message -> Log.d("Collie", message) },
        )

        Collie.configure(context = application, configuration = configuration)

        // Optional: if another diagnostics tool is installed, make Collie's logo a switch.
        // The handler runs after Collie's UI has fully closed, so starting an activity is safe.
        //
        // Collie.onLogoTap {
        //     application.startActivity(
        //         Chucker.getLaunchIntent(application).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        //     )
        // }
    }

    /**
     * Map your logging library's snapshot onto Collie's entries.
     *
     * The metadata keys are a convention the panel reads: `method` / `url` / `status` /
     * `durationMs`, headers under the `reqH.` and `respH.` prefixes, `screen` / `kind` for
     * navigation. See INTEGRATION.md §6 — and redact credentials before they leave the device.
     *
     * A complete OkHttp bridge, including the exclusion of Collie's own uploads, is in the
     * example app: Android/example/…/CollieLogInterceptor.kt
     */
    private fun logSnapshot(): List<CollieLogEntry> {
        // return YourLogger.snapshot().map { entry ->
        //     CollieLogEntry(
        //         epochMillis = entry.timestamp,
        //         level = entry.level.name.lowercase(),
        //         category = entry.category.name.lowercase(),
        //         message = entry.message,
        //         metadata = entry.metadata,
        //     )
        // }
        return emptyList()
    }
}

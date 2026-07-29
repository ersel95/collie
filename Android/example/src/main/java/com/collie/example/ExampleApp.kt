package com.collie.example

import android.app.Application
import android.content.Intent
import android.util.Log
import com.chuckerteam.chucker.api.Chucker
import com.chuckerteam.chucker.api.ChuckerCollector
import com.chuckerteam.chucker.api.ChuckerInterceptor
import com.chuckerteam.chucker.api.RetentionManager
import com.collie.Collie
import com.collie.CollieConfiguration
import com.collie.ReportTransport
import com.collie.firebase.FirestoreTransport
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/**
 * The whole integration, in one file — the thing this example exists to show.
 *
 * Order matters: the Collie configuration is built first because it is what tells the
 * interceptors which URLs to leave alone (Collie's own uploads), then the OkHttp client is
 * assembled with both tools, then Collie is started.
 */
class ExampleApp : Application() {

    lateinit var httpClient: OkHttpClient
        private set

    lateinit var logs: CollieLogInterceptor
        private set

    override fun onCreate() {
        super.onCreate()

        // ── 1. Collie's configuration ──────────────────────────────────────────────────
        // `enabled` comes from BuildConfig, never a literal `true`: the release build type
        // sets it to false, and links the no-op artifact on top of that.
        val configuration = CollieConfiguration(
            enabled = BuildConfig.COLLIE_ENABLED,
            apiBaseUrl = BuildConfig.COLLIE_API_BASE_URL,
            apiKey = BuildConfig.COLLIE_API_KEY,
            // postman-echo has no Collie endpoints of course — `/post` accepts the multipart
            // upload and echoes it back with a 200, which is enough to walk the "Sent" path
            // end to end. Point these at a real deployment and nothing else changes.
            reportsPath = "/post",
            configPath = "/get",
            environment = "example",
            // The shake belongs to Collie here. If the host also gave Olaf the shake, this
            // would be `false` and Collie would be reached only through `presentReport()`.
            activatesOnShake = true,
            asksBeforeReporting = true,
            logSnapshotProvider = { logs.snapshot() },
            diagnostics = { message -> Log.d(TAG, message) },
        )

        // ── 2. The HTTP client: Chucker to inspect, Collie's bridge to report ───────────
        logs = CollieLogInterceptor(
            // Recursion prevention, safeguard #2. Collie's own client carries none of these
            // interceptors to begin with (safeguard #1), but the host's client would happily
            // log a report upload if it ever saw one.
            excludedUrlPrefixes = configuration.captureExclusionFragments,
        )

        httpClient = OkHttpClient.Builder()
            .callTimeout(30, TimeUnit.SECONDS)
            .addInterceptor(chuckerInterceptor())
            .addInterceptor(logs)
            .build()

        // ── 3. Start Collie ────────────────────────────────────────────────────────────
        // Two transports, one destination. With a google-services.json present the report goes
        // to Firestore — the path an app takes when its network policy allows Firebase and
        // nothing else — and the analyst panel reads it from there. Without one, the HTTPS
        // transport takes over and the example still runs end to end.
        Collie.configure(
            context = this,
            configuration = configuration,
            transport = if (BuildConfig.COLLIE_USE_FIRESTORE) firestoreTransport() else null,
        )

        // ── 4. Tool switching ──────────────────────────────────────────────────────────
        // Tapping the paw in Collie's top bar closes the report screen and opens Chucker.
        // The handler runs *after* Collie's UI is gone, so starting another activity from it
        // is safe. A tester who shakes to report and then wants to look at the traffic does
        // not have to leave the app and come back.
        Collie.onLogoTap {
            startActivity(
                Chucker.getLaunchIntent(this).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }

        logs.log("info", "app", "Example app started")
    }

    /**
     * The report lands in `collie_reports/<reportId>`, its screenshot base64-encoded in
     * `collie_report_screenshots/<reportId>` — Cloud Storage needs a paid Firebase plan, so it is
     * deliberately not used. The document id is the queue's report id, so a retry after a lost
     * response overwrites the same document instead of filing a second report.
     *
     * `FirebaseApp` initialises itself from `google-services.json` before `onCreate` runs, so
     * there is nothing to set up here.
     */
    private fun firestoreTransport(): ReportTransport = FirestoreTransport(
        FirestoreTransport.Configuration(appKey = BuildConfig.COLLIE_APP_KEY),
    )

    private fun chuckerInterceptor(): ChuckerInterceptor {
        val collector = ChuckerCollector(
            context = this,
            showNotification = true,
            retentionPeriod = RetentionManager.Period.ONE_HOUR,
        )
        return ChuckerInterceptor.Builder(this)
            .collector(collector)
            .maxContentLength(250_000L)
            // Same reasoning as the bridge's redaction: a screenshot of Chucker ends up in
            // tickets and chat threads.
            .redactHeaders("Authorization", "Cookie", "x-collie-api-key")
            .alwaysReadResponseBody(true)
            .createShortcut(true)
            .build()
        // Chucker needs no exclusions of its own here: Collie uploads through its own OkHttp
        // client, which carries none of these interceptors, so a report upload never reaches
        // this one in the first place.
    }

    private companion object {
        const val TAG = "CollieExample"
    }
}

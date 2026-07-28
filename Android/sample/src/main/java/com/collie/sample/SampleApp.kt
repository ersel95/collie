package com.collie.sample

import android.app.Application
import android.util.Log
import com.collie.Collie
import com.collie.CollieConfiguration
import com.collie.CollieLogEntry

/**
 * Configures Collie the way a host app does — opt-in, with the backend settings coming from
 * outside the source.
 *
 * The sample points at a URL that does not exist, on purpose: with no backend reachable the
 * flow still runs end to end and finishes on "Queued", which is exactly the path a tester on
 * the wrong network takes. Point `COLLIE_BASE_URL` at a real deployment (or swap in
 * `FirestoreTransport`) to watch a report land.
 */
class SampleApp : Application() {

    override fun onCreate() {
        super.onCreate()

        Collie.configure(
            context = this,
            configuration = CollieConfiguration(
                enabled = true,
                apiBaseUrl = "https://collie.invalid",
                apiKey = "sample-key",
                environment = "sample",
                logSnapshotProvider = ::sampleLogs,
                diagnostics = { message -> Log.d("Collie", message) },
            ),
        )
    }

    /** Stands in for the host's logging library (Olaf, Timber, anything). */
    private fun sampleLogs(): List<CollieLogEntry> {
        val now = System.currentTimeMillis()
        return listOf(
            CollieLogEntry(
                epochMillis = now - 8_000,
                level = "info",
                category = "navigation",
                message = "SampleActivity",
                metadata = mapOf("screen" to "SampleActivity", "kind" to "appear"),
            ),
            CollieLogEntry(
                epochMillis = now - 5_000,
                level = "info",
                category = "network",
                message = "GET https://api.example.com/v1/accounts",
                metadata = mapOf(
                    "method" to "GET",
                    "url" to "https://api.example.com/v1/accounts",
                    "status" to "200",
                    "durationMs" to "412",
                ),
            ),
            CollieLogEntry(
                epochMillis = now - 1_000,
                level = "error",
                category = "app",
                message = "The account list came back empty",
            ),
        )
    }
}

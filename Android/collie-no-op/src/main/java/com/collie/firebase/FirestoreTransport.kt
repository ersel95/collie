package com.collie.firebase

import com.collie.CollieOperationResult
import com.collie.CollieRemoteConfig
import com.collie.ReportTransport

/**
 * The Firestore transport's no-op counterpart, in the same artifact as the rest of the
 * no-op API.
 *
 * It lives here rather than in a `collie-firebase-no-op` of its own because of how the host
 * writes its integration: one call site builds the transport and hands it to
 * `Collie.configure(...)`. If the type vanished in a release build, that call site would
 * have to be duplicated into `src/debug` and `src/release` source sets — a lot of ceremony
 * for a class with no bodies. So the release artifact keeps the name and drops the Firebase
 * dependency: **no Firestore code reaches production, and the host's integration file stays
 * one file.**
 */
public class FirestoreTransport @JvmOverloads constructor(
    private val configuration: Configuration,
    @Suppress("UNUSED_PARAMETER") firestore: Any? = null,
) : ReportTransport {

    public data class Configuration(
        public val appKey: String,
        public val collection: String = "collie_reports",
        public val screenshotCollection: String = "collie_report_screenshots",
        public val configCollection: String = "collie_config",
        public val maxDocumentBytes: Int = 900_000,
        public val maxScreenshotBytes: Int = 650_000,
    )

    override suspend fun upload(
        reportId: String,
        envelope: ByteArray,
        screenshot: ByteArray?,
    ): CollieOperationResult<String> =
        CollieOperationResult.PermanentFailure("Collie is not present in this build")

    override suspend fun fetchRemoteConfig(): CollieRemoteConfig? = null
}

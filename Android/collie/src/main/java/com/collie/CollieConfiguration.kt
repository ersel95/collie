package com.collie

/**
 * Bug-reporter configuration. Provided once via `Collie.configure(...)`.
 *
 * **All backend settings are parametric** — base URL and api-key are supplied by the
 * integrating project at init time; nothing project- or person-specific is embedded in
 * Collie's code.
 *
 * ⚠️ **Public repo rule**: No real URL / company name / secret ever enters this class
 * as a **default** value. [apiBaseUrl] / [apiKey] are provided by the host app at
 * runtime (BuildConfig fields fed from a secrets file) and are never committed here.
 */
public class CollieConfiguration(

    // MARK: - Gate

    /**
     * Local (build-time) on/off switch for the feature. **Default `false` (opt-in).**
     * While `false`, `Collie.configure` returns early: zero sensor / network / upload.
     */
    public val enabled: Boolean = false,

    // MARK: - Backend (all provided by the host)

    /**
     * Root URL of the Collie backend (e.g. `https://collie-api.example.com`). Corporate
     * deployments are often reachable only over VPN; on send failures the offline queue
     * takes over.
     *
     * Only the HTTPS transport needs this. A host on the Firestore transport passes its
     * own destination with the transport and may leave this blank.
     */
    public val apiBaseUrl: String = "",

    /**
     * Ingestion api-key. Sent as the `x-collie-api-key` header — it is the **sole**
     * ingestion credential: it identifies which app the report belongs to and
     * authenticates the caller. If blank, configure behaves fail-closed (no-op).
     */
    public val apiKey: String = "",

    /** Path of the report ingestion endpoint, appended to [apiBaseUrl]. */
    public val reportsPath: String = DEFAULT_REPORTS_PATH,

    /**
     * Path of the remote-config endpoint (server-side kill switch), appended to
     * [apiBaseUrl].
     */
    public val configPath: String = DEFAULT_CONFIG_PATH,

    // MARK: - Flow

    /**
     * Does a shake ask before opening the report form? `true` (default) shows the
     * "Spotted a problem?" yes/no banner first; `false` opens the report sheet directly.
     *
     * This is an explicit switch: whether another diagnostics tool is installed (i.e.
     * whether `Collie.onLogoTap` has a handler) does not affect it.
     */
    public val asksBeforeReporting: Boolean = true,

    /**
     * Does a shake open Collie at all? `true` (default) installs the shake detector.
     *
     * Set `false` when another shake-activated tool owns the gesture — Olaf, typically —
     * and Collie is reached only deliberately, through `Collie.presentReport()` from that
     * tool's hand-off. Without this both tools answer the same shake and Collie's banner
     * ends up buried under the other tool's full-screen UI.
     *
     * `presentReport()` keeps working regardless.
     */
    public val activatesOnShake: Boolean = true,

    // MARK: - Report meta

    /**
     * Environment label (e.g. "staging" / "uat"). Sent with every report.
     *
     * The app's display name is **not** configured here: the backend resolves which app
     * a report belongs to from the api-key (HTTPS) or the app key (Firestore) and uses
     * the name on its own app record.
     */
    public val environment: String = "staging",

    // MARK: - Upload behavior

    /** Timeout for a single request (milliseconds). */
    public val requestTimeoutMillis: Long = 30_000,

    /** Maximum number of attempts for a report in the offline queue. */
    public val maxRetryCount: Int = 5,

    /** Base delay for exponential backoff (milliseconds). Attempt n → `baseRetryDelay * 2^n`. */
    public val baseRetryDelayMillis: Long = 5_000,

    /** Screenshot JPEG compression quality (0..1). */
    public val screenshotJpegQuality: Double = 0.7,

    /**
     * Upper bound allowed for the screenshot (bytes). Kept safely below the backend's
     * ingestion limit (default ~8 MB server-side).
     */
    public val maxScreenshotBytes: Int = 4 * 1_048_576,

    // MARK: - Host bridges (optional)

    /**
     * Provides the log snapshot at report time. The host maps its own logs to
     * [CollieLogEntry]. When `null`, reports go without logs.
     */
    public val logSnapshotProvider: (() -> List<CollieLogEntry>)? = null,

    /** Provides the current session identifier from the host's logging system. */
    public val sessionIdProvider: (() -> String?)? = null,

    /**
     * Collie's own diagnostic messages (queue/send states). The host can forward these
     * to its own logging system.
     */
    public val diagnostics: ((String) -> Unit)? = null,
) {

    init {
        require(requestTimeoutMillis >= 1_000) { "requestTimeoutMillis must be at least 1000" }
        require(maxRetryCount >= 0) { "maxRetryCount cannot be negative" }
        require(baseRetryDelayMillis >= 0) { "baseRetryDelayMillis cannot be negative" }
        require(maxScreenshotBytes >= 0) { "maxScreenshotBytes cannot be negative" }
    }

    /** Clamped to the range the JPEG encoder accepts, matching the iOS SDK. */
    public val effectiveJpegQuality: Double = screenshotJpegQuality.coerceIn(0.1, 1.0)

    // MARK: - Validation (fail-closed)

    /**
     * The reason if any required field is blank; `null` when all are set.
     * `Collie.configure` refuses to install unless this is `null` (fail-closed).
     *
     * Only meaningful for the built-in HTTPS transport — a custom transport brings its
     * own destination and credentials, and `configure` skips this check for one.
     */
    public val validationError: String?
        get() {
            if (apiKey.isBlank()) return "apiKey is blank — cannot authenticate to the Collie backend"
            if (apiBaseUrl.isBlank()) return "apiBaseUrl is blank"
            val host = runCatching { java.net.URI(apiBaseUrl).host }.getOrNull()
            if (host.isNullOrBlank()) return "apiBaseUrl has no host"
            if (reportsPath.isBlank()) return "reportsPath is blank"
            if (configPath.isBlank()) return "configPath is blank"
            return null
        }

    // MARK: - URLs

    /** `POST <apiBaseUrl><reportsPath>` — multipart report upload. */
    public val reportsUrl: String get() = url(reportsPath)

    /** `GET <apiBaseUrl><configPath>` — remote config / server-side kill switch. */
    public val configUrl: String get() = url(configPath)

    /**
     * Recursion prevention: if the host uses a network-capture tool, it should add
     * these fragments to that tool's URL exclude list. (Collie's own OkHttp client carries
     * none of the host's interceptors to begin with — this is the second safeguard.)
     */
    public val captureExclusionFragments: List<String>
        get() = buildList {
            runCatching { java.net.URI(apiBaseUrl).host }.getOrNull()
                ?.takeIf { it.isNotBlank() }
                ?.let { add(it.lowercase()) }
            add(reportsPath)
        }.filter { it.isNotEmpty() }

    private fun url(path: String): String {
        val base = apiBaseUrl.trimEnd('/')
        val normalized = if (path.startsWith("/")) path else "/$path"
        return base + normalized
    }

    public companion object {
        /** Default ingestion endpoint path. */
        public const val DEFAULT_REPORTS_PATH: String = "/api/v1/collie/reports"

        /** Default remote-config endpoint path. */
        public const val DEFAULT_CONFIG_PATH: String = "/api/v1/collie/config"

        /** HTTP header carrying the ingestion api-key. */
        public const val API_KEY_HEADER: String = "x-collie-api-key"
    }
}

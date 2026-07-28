package com.collie

import android.content.Context

/**
 * No-op Collie. Same public surface as the real artifact, empty bodies.
 *
 * A release build links this instead of `:collie`, so a production APK contains no shake
 * detector, no screenshot capture, no upload queue and no Compose UI — the reporter is not
 * merely switched off, it is absent. `CollieConfiguration.enabled` remains the first gate;
 * this is the one that cannot be flipped by mistake.
 *
 * Every declaration here mirrors the real one exactly. The CI release job compiles the
 * sample app against both artifacts, so a signature that drifts fails the build rather than
 * the host's release.
 */
public object Collie {

    /** No-op: nothing is configured, nothing is installed. */
    @JvmStatic
    @JvmOverloads
    public fun configure(
        context: Context,
        configuration: CollieConfiguration,
        transport: ReportTransport? = null,
    ): Unit = Unit

    /** Always `null` — there is no service in a release build. */
    @JvmStatic
    public val bugReportService: BugReportService? get() = null

    /** Always `false`. */
    @JvmStatic
    public val isConfigured: Boolean get() = false

    /** No-op. */
    @JvmStatic
    public fun flushPendingUploads(): Unit = Unit

    /** No-op. */
    @JvmStatic
    public fun presentReport(): Unit = Unit

    /** No-op. */
    @JvmStatic
    public fun onLogoTap(handler: (() -> Unit)?): Unit = Unit
}

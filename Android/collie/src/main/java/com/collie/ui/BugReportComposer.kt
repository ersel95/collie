package com.collie.ui

import android.content.Context
import android.graphics.Bitmap
import com.collie.Collie
import com.collie.CollieDeviceIdentity
import com.collie.CollieSubmitOutcome
import com.collie.CollieTelemetryCollector
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import kotlin.math.roundToInt

/**
 * Bridge that gathers the fields from the report screen + the screenshots it holds +
 * device/app meta and hands them to `Collie`'s `BugReportService`.
 *
 * The log snapshot (the host's `logSnapshotProvider`) is collected on the service side;
 * this only prepares the data coming from the UI.
 */
internal object BugReportComposer {

    /**
     * Sends the report.
     *
     * @param shots In the order the form holds them; the transport keeps that order, so it is
     *   the order the analyst sees. Each one carries its own capture event, which is why they
     *   travel as pairs rather than as two lists: an image that fails to encode must take its
     *   marker with it, or the stream announces "screenshot 3 captured" beside two pictures
     *   and sends the analyst looking for one that never arrived.
     */
    suspend fun send(
        context: Context,
        whatHappened: String,
        testerName: String?,
        shots: List<BugReportShot>,
    ): CollieSubmitOutcome {
        val service = Collie.bugReportService
            ?: return CollieSubmitOutcome.Rejected("Collie is not configured")

        // Per image, not for all of them together: each one is uploaded on its own, so
        // attaching a fifth must not shrink the first four. The form already stops at the
        // limit; capping again here means a caller that does not (a host driving the service
        // directly) cannot exceed what the panel displays.
        val encoded = withContext(Dispatchers.Default) {
            shots.take(service.maxScreenshots).mapNotNull { shot ->
                encodeJpeg(shot.bitmap, service.screenshotJpegQuality, service.maxScreenshotBytes)
                    ?.let { it to shot.event }
            }
        }

        val identity = CollieDeviceIdentity.current(context)
        // Capture the point-in-time device state (battery/network/thermal/disk/memory…)
        // at the moment the report is taken.
        val telemetry = CollieTelemetryCollector.capture(context)

        return service.sendReport(
            whatHappened = whatHappened,
            testerName = testerName,
            screenshotsJpeg = encoded.map { it.first },
            screenshotEvents = encoded.map { it.second },
            identity = identity,
            telemetry = telemetry,
        )
    }

    /**
     * Compresses ONE image to JPEG; when [maxBytes] is exceeded, first lowers quality, then
     * scales the image down. A report whose screenshot is slightly softer still tells the
     * story; one rejected for size tells nothing.
     */
    internal fun encodeJpeg(bitmap: Bitmap, quality: Double, maxBytes: Int): ByteArray? {
        var currentQuality = (quality * 100).roundToInt().coerceIn(10, 100)
        var data = compress(bitmap, currentQuality) ?: return null

        // First try lowering the quality.
        while (maxBytes > 0 && data.size > maxBytes && currentQuality > 20) {
            currentQuality -= 15
            data = compress(bitmap, currentQuality) ?: return data
        }

        // Still too large: scale the image down.
        var scaled = bitmap
        while (maxBytes > 0 && data.size > maxBytes && scaled.width > 320 && scaled.height > 320) {
            val next = runCatching {
                Bitmap.createScaledBitmap(
                    scaled,
                    (scaled.width * 0.7f).toInt(),
                    (scaled.height * 0.7f).toInt(),
                    true,
                )
            }.getOrNull() ?: break
            scaled = next
            data = compress(scaled, currentQuality) ?: return data
        }
        return data
    }

    private fun compress(bitmap: Bitmap, quality: Int): ByteArray? = runCatching {
        ByteArrayOutputStream().use { stream ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, quality, stream)
            stream.toByteArray()
        }
    }.getOrNull()
}

package com.collie.ui

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.View
import android.view.WindowManager
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

/**
 * Renders the current screen into a bitmap. The system never hands an app a screenshot, so
 * Collie takes one itself at shake time — before any of its own UI is on screen.
 *
 * Two paths, in this order:
 *
 * 1. **[PixelCopy]** — copies what the compositor actually shows, so dialogs, video and
 *    anything drawn outside the view hierarchy appear as the tester saw them.
 * 2. **`View.draw`** — the fallback. It re-draws the view hierarchy into a bitmap, which
 *    misses `SurfaceView`/`TextureView` content but works where PixelCopy refuses.
 *
 * **`FLAG_SECURE` is honoured, and that is the point.** A window marked secure cannot be
 * copied by PixelCopy (the platform blocks it), and Collie does not try to work around it:
 * it falls back to the view draw, which renders only what the app itself draws. A host that
 * marks a screen secure has decided its pixels must not leave the device, and a bug reporter
 * is not an exception to that. This is the equivalent of the iOS SDK rendering with
 * `afterScreenUpdates: true` so the secure-field mask takes effect.
 */
internal object ScreenCapture {

    /** Captures [activity]'s window; `null` when nothing could be rendered. */
    suspend fun capture(activity: Activity): Bitmap? {
        val view = activity.window?.decorView ?: return null
        if (view.width <= 0 || view.height <= 0) return null

        val isSecure = (activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE) != 0
        if (!isSecure && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            pixelCopy(activity, view)?.let { return it }
        }
        return drawToBitmap(view)
    }

    private suspend fun pixelCopy(activity: Activity, view: View): Bitmap? =
        suspendCoroutine { continuation ->
            val bitmap = runCatching {
                Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            }.getOrNull()

            if (bitmap == null) {
                continuation.resume(null)
                return@suspendCoroutine
            }

            runCatching {
                PixelCopy.request(
                    activity.window,
                    bitmap,
                    { result ->
                        continuation.resume(if (result == PixelCopy.SUCCESS) bitmap else null)
                    },
                    Handler(Looper.getMainLooper()),
                )
            }.onFailure {
                // An unattached or secure window throws rather than reporting a failure code.
                continuation.resume(null)
            }
        }

    private fun drawToBitmap(view: View): Bitmap? = runCatching {
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        bitmap
    }.getOrNull()
}

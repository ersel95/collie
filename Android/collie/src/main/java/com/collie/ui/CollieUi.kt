package com.collie.ui

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import com.collie.Collie
import com.collie.CollieConfiguration
import com.collie.CollieScreenshotEvent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.android.awaitFrame
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.lang.ref.WeakReference

/**
 * The bug-reporter UI orchestrator: when the device is shaken, Collie's UI appears **over**
 * the host's, never inside its view hierarchy in a way the host can see.
 *
 * By default a shake raises a yes/no bubble from the bottom (**Yes** → the report screen);
 * with `CollieConfiguration.asksBeforeReporting = false` the question is skipped and the
 * report screen opens directly. Finally a "Report sent" / "Queued" toast is shown.
 *
 * Where iOS gets a separate `UIWindow` at `.alert + 1`, this attaches a wrap-content
 * [ComposeView] to the current activity's content view, pinned to the bottom. The effect is
 * the one that matters: the app underneath stays fully interactive, because the banner only
 * covers — and only receives touches in — the area it actually occupies.
 */
internal object CollieUi {

    private var installed = false
    private var currentActivity: WeakReference<Activity>? = null
    private var bannerView: ComposeView? = null
    private var autoDismissJob: Job? = null
    private val scope: CoroutineScope = MainScope()

    /**
     * What the tester has entered so far, handed to the report activity and handed back when
     * it leaves for screenshot mode.
     *
     * It lives here, not in the activity, because the flow spans more than one screen: the
     * form is *finished* on the way into screenshot mode and created again on the way out. A
     * reporter that loses the sentence when you go and photograph the bug gets used once.
     * (It also has to travel outside the intent — a full-resolution bitmap is far past the
     * binder transaction limit, which is why `pendingScreenshot` was already here.)
     */
    @Volatile
    internal var draft: BugReportDraft = BugReportDraft()

    /** The screenshot captured at shake time, handed to the report activity. */
    @Volatile
    internal var pendingScreenshot: Bitmap? = null

    /** The two screenshot-mode controls, while that mode is up. */
    private var screenshotBar: ComposeView? = null
    private var screenshotShutter: ComposeView? = null

    /**
     * Whether screenshot mode is on. Survives activity changes on purpose: the whole point is
     * that the tester navigates the host app, so the controls have to follow them from one
     * screen to the next.
     */
    private var inScreenshotMode = false

    /**
     * Handler for taps on the Collie logo in the report screen's top bar (set via
     * `Collie.onLogoTap`). When set, the logo becomes a switch-tool button.
     */
    @Volatile
    internal var logoTapHandler: (() -> Unit)? = null

    private val shakeDetector = ShakeDetector(::handleShake)

    /** The banner auto-dismisses after a few seconds without interaction. */
    private const val AUTO_DISMISS_MILLIS = 6_000L

    // MARK: - Setup (triggered by Collie.configure)

    /**
     * Tracks the foreground activity and installs the shake detector. Called **only when
     * the bug-reporter opt-in is on**. Idempotent.
     */
    fun install(application: Application) {
        if (installed) return
        installed = true

        application.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                currentActivity = WeakReference(activity)
                // Collie's own screens must not answer a shake with another report.
                if (activity is CollieReportActivity) {
                    shakeDetector.stop()
                } else if (activatesOnShake()) {
                    shakeDetector.start(activity)
                }
                // Screenshot mode follows the tester: they came here to walk the app, and the
                // controls are attached to whichever activity is in front.
                if (inScreenshotMode && activity !is CollieReportActivity) {
                    attachScreenshotControls(activity)
                }
            }

            override fun onActivityPaused(activity: Activity) {
                dismissBanner()
                detachScreenshotControls()
                shakeDetector.stop()
            }

            override fun onActivityDestroyed(activity: Activity) {
                if (currentActivity?.get() === activity) currentActivity = null
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityStarted(activity: Activity) = Unit
            override fun onActivityStopped(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        })

        if (!activatesOnShake()) {
            Collie.bugReportService?.diag(
                "Shake activation disabled — Collie opens only via presentReport().",
            )
        }
    }

    private fun activatesOnShake(): Boolean =
        Collie.bugReportService?.configuration?.activatesOnShake != false

    // MARK: - Flow

    private fun handleShake() {
        Collie.bugReportService?.diag("Shake detected")
        // Explicit host choice (`CollieConfiguration.asksBeforeReporting`): ask first — a
        // shake may be accidental — or open the report screen straight away. Whether tool
        // switching is wired (`Collie.onLogoTap`) does NOT affect this.
        present(askFirst = Collie.bugReportService?.configuration?.asksBeforeReporting != false)
    }

    /**
     * Starts the report flow.
     *
     * @param askFirst Show the "Spotted a problem?" question before the form. A shake
     *   honours `asksBeforeReporting`, because a shake can be accidental. A deliberate
     *   entry — the host handing off from another diagnostics tool — passes `false`: the
     *   tester already chose to report, so asking again is a dead click.
     */
    fun present(askFirst: Boolean) {
        // Gate: show nothing when the service is absent (opt-in off) or capture is disabled.
        val service = Collie.bugReportService ?: return
        if (!service.isCaptureEnabled) return
        // Don't repeat while a banner/report screen is already up.
        if (bannerView != null) return
        val activity = currentActivity?.get() ?: return
        if (activity is CollieReportActivity || activity.isFinishing) return

        scope.launch {
            // Capture the screen before any Collie UI appears. This first image is the
            // report's screenshot 1; the tester adds the rest from the form.
            val captured = ScreenCapture.capture(activity)
            pendingScreenshot = captured
            draft = BugReportDraft(
                shots = listOfNotNull(
                    captured?.let {
                        BugReportShot(
                            bitmap = it,
                            event = CollieScreenshotEvent(
                                epochMillis = System.currentTimeMillis(),
                                source = CollieScreenshotEvent.Source.CAPTURED,
                            ),
                        )
                    },
                ),
            )
            if (askFirst) showBanner(activity) else openReportScreen(activity)
        }
    }

    private fun showBanner(activity: Activity) {
        val content = activity.findViewById<ViewGroup>(android.R.id.content) ?: return

        val view = ComposeView(activity).apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
            setContent {
                BugReportBanner(
                    onYes = {
                        dismissBanner()
                        currentActivity?.get()?.let(::openReportScreen)
                    },
                    onNo = { dismissBanner() },
                )
            }
        }
        // Bottom-pinned and wrap-content: everything outside the bubble belongs to the app,
        // which keeps the host interactive while the question is on screen.
        content.addView(
            view,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM,
            ),
        )
        bannerView = view

        autoDismissJob?.cancel()
        autoDismissJob = scope.launch {
            delay(AUTO_DISMISS_MILLIS)
            dismissBanner()
        }
    }

    private fun dismissBanner() {
        autoDismissJob?.cancel()
        autoDismissJob = null
        bannerView?.let { view -> (view.parent as? ViewGroup)?.removeView(view) }
        bannerView = null
    }

    private fun openReportScreen(activity: Activity) {
        dismissBanner()
        activity.startActivity(Intent(activity, CollieReportActivity::class.java))
    }

    // MARK: - Screenshot mode

    /**
     * Hands the app back to the tester with two controls on top of it: a bar that returns to
     * the report, and a shutter that photographs whatever is on screen.
     *
     * The form is finished but the flow is not — [draft] holds the sentence, the name and the
     * images already attached, so nothing about the report can be lost while the tester walks
     * around the app.
     */
    internal fun enterScreenshotMode() {
        inScreenshotMode = true
        currentActivity?.get()
            ?.takeIf { it !is CollieReportActivity && !it.isFinishing }
            ?.let(::attachScreenshotControls)
    }

    private fun leaveScreenshotMode() {
        inScreenshotMode = false
        detachScreenshotControls()
        currentActivity?.get()?.let(::openReportScreen)
    }

    private fun captureInScreenshotMode() {
        val activity = currentActivity?.get() ?: return
        val limit = Collie.bugReportService?.maxScreenshots ?: return
        if (draft.shots.size >= limit) return

        scope.launch {
            // The controls are part of the host's view hierarchy here — unlike iOS, where they
            // live in a window above the one being rendered — so they would appear in the
            // picture. Hide them, let a frame go by so the compositor has caught up (PixelCopy
            // reads what is actually on screen), then capture.
            setScreenshotControlsVisible(false)
            awaitFrame()
            awaitFrame()
            val bitmap = ScreenCapture.capture(activity)
            setScreenshotControlsVisible(true)

            if (bitmap == null) {
                Collie.bugReportService?.diag("Screenshot mode: nothing could be rendered.")
                return@launch
            }
            draft = draft.copy(
                shots = draft.shots + BugReportShot(
                    bitmap = bitmap,
                    event = CollieScreenshotEvent(
                        epochMillis = System.currentTimeMillis(),
                        source = CollieScreenshotEvent.Source.CAPTURED,
                    ),
                ),
            )
            // One tap, one picture, straight back to the report. Staying in the mode would
            // mean the tester's only confirmation is a counter in the corner — they would have
            // no idea *what* they just attached until they left.
            leaveScreenshotMode()
        }
    }

    /**
     * Two wrap-content views rather than one full-screen overlay: everything between them
     * belongs to the host app, which is what lets the tester navigate to the screen they came
     * to photograph. A full-screen view would swallow every touch.
     */
    private fun attachScreenshotControls(activity: Activity) {
        detachScreenshotControls()
        val content = activity.findViewById<ViewGroup>(android.R.id.content) ?: return
        val limit = Collie.bugReportService?.maxScreenshots ?: CollieConfiguration.MAX_SCREENSHOTS_LIMIT

        val bar = ComposeView(activity).apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
            setContent { ScreenshotModeBar(onExit = ::leaveScreenshotMode) }
        }
        content.addView(
            bar,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP,
            ),
        )

        val shutter = ComposeView(activity).apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
            setContent {
                ScreenshotModeShutter(
                    count = draft.shots.size,
                    limit = limit,
                    onCapture = ::captureInScreenshotMode,
                )
            }
        }
        content.addView(
            shutter,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.END,
            ),
        )

        screenshotBar = bar
        screenshotShutter = shutter
    }

    private fun detachScreenshotControls() {
        listOfNotNull(screenshotBar, screenshotShutter).forEach { view ->
            (view.parent as? ViewGroup)?.removeView(view)
        }
        screenshotBar = null
        screenshotShutter = null
    }

    private fun setScreenshotControlsVisible(visible: Boolean) {
        val visibility = if (visible) View.VISIBLE else View.INVISIBLE
        screenshotBar?.visibility = visibility
        screenshotShutter?.visibility = visibility
    }

    // MARK: - Outcome

    /** Called when the report flow ends, however it ended. */
    internal fun endReportFlow() {
        inScreenshotMode = false
        detachScreenshotControls()
        pendingScreenshot = null
        draft = BugReportDraft()
    }

    /** Shown once the report screen closes; runs on the activity that is up by then. */
    internal fun showToast(message: String) {
        scope.launch {
            withContext(Dispatchers.Main) {
                currentActivity?.get()?.let { activity ->
                    android.widget.Toast.makeText(activity, message, android.widget.Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    /**
     * Invoked after the Collie UI has fully closed, so the handler can safely present
     * another diagnostics tool.
     */
    internal fun handOffToOtherTool() {
        scope.launch { logoTapHandler?.invoke() }
    }
}

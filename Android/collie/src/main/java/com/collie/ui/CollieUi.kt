package com.collie.ui

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import com.collie.Collie
import kotlinx.coroutines.CoroutineScope
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

    /** The screenshot captured at shake time, handed to the report activity. */
    @Volatile
    internal var pendingScreenshot: Bitmap? = null

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
            }

            override fun onActivityPaused(activity: Activity) {
                dismissBanner()
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
            // Capture the screen before any Collie UI appears.
            pendingScreenshot = ScreenCapture.capture(activity)
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

    // MARK: - Outcome

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

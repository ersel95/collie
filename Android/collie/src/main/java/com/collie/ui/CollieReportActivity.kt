package com.collie.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import com.collie.Collie
import com.collie.CollieDeviceIdentity
import com.collie.CollieSubmitOutcome
import kotlinx.coroutines.launch

/**
 * Hosts the report form and the markup editor.
 *
 * Its own activity rather than an overlay on the host's: the form owns the keyboard, the
 * back gesture and the window insets while it is up, and none of that can be borrowed from
 * a host activity without fighting it. The banner, which must leave the app usable
 * underneath, is the one piece that stays an overlay.
 *
 * The screenshot travels through [CollieUi.pendingScreenshot] rather than the intent: a
 * full-resolution bitmap is far past the binder transaction limit, and an intent extra that
 * large crashes the app it was meant to diagnose.
 */
internal class CollieReportActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val service = Collie.bugReportService
        if (service == null) {
            // The reporter was switched off between the shake and this screen opening.
            finish()
            return
        }

        val screenshot = CollieUi.pendingScreenshot
        val requiresName = !CollieDeviceIdentity.hasStoredName(this)
        val hasLogoTapHandler = CollieUi.logoTapHandler != null

        setContent {
            var state by rememberSaveable(
                stateSaver = SubmitStateSaver,
            ) { mutableStateOf<SubmitState>(SubmitState.Idle) }
            val scope = rememberCoroutineScope()

            BugReportScreen(
                screenshot = screenshot,
                requiresName = requiresName,
                hasLogoTapHandler = hasLogoTapHandler,
                state = state,
                onSubmit = { whatHappened, testerName, image ->
                    state = SubmitState.Sending
                    scope.launch {
                        val outcome = BugReportComposer.send(
                            context = this@CollieReportActivity,
                            whatHappened = whatHappened,
                            testerName = testerName,
                            screenshot = image,
                        )
                        when (outcome) {
                            is CollieSubmitOutcome.Sent -> close(ReportOutcome.Sent(outcome.reportId))
                            is CollieSubmitOutcome.Queued -> close(ReportOutcome.Queued)
                            // A permanent failure stays on screen: the tester's words are still
                            // in the field, and closing would throw them away.
                            is CollieSubmitOutcome.Rejected -> state = SubmitState.Failed(outcome.reason)
                        }
                    }
                },
                onClose = ::close,
            )
        }
    }

    private fun close(outcome: ReportOutcome) {
        CollieUi.pendingScreenshot = null
        finish()

        when (outcome) {
            is ReportOutcome.Cancelled -> Unit
            is ReportOutcome.Sent ->
                // The report goes to the analyst panel, not straight to Jira — so there is no
                // issue key to show yet.
                CollieUi.showToast("Report sent — thanks!")

            is ReportOutcome.Queued ->
                CollieUi.showToast("Queued — will be sent once a connection is available")

            is ReportOutcome.SwitchTool -> CollieUi.handOffToOtherTool()
        }
    }
}

/** Keeps the inline error across a rotation; `Sending` is not resumable, so it resets. */
private val SubmitStateSaver = androidx.compose.runtime.saveable.Saver<SubmitState, String>(
    save = { state -> if (state is SubmitState.Failed) state.message else "" },
    restore = { saved -> if (saved.isEmpty()) SubmitState.Idle else SubmitState.Failed(saved) },
)

package com.collie.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp

/** Why the report screen closed (the caller shows a toast accordingly). */
internal sealed interface ReportOutcome {
    data object Cancelled : ReportOutcome
    data class Sent(val reportId: String) : ReportOutcome
    data object Queued : ReportOutcome

    /**
     * The logo in the top bar was tapped: close the Collie UI, then invoke the host's
     * switch-tool handler.
     */
    data object SwitchTool : ReportOutcome
}

/** Submission state, driving the send button and the inline error. */
internal sealed interface SubmitState {
    data object Idle : SubmitState
    data object Sending : SubmitState
    data class Failed(val message: String) : SubmitState
}

/**
 * The bug report screen. Reached from the banner's **Yes**.
 *
 * - One field: **"What happened?"**.
 * - On first use (no stored name) a **name** field is shown as well (one time only).
 * - Tapping the screenshot preview opens Collie's markup editor; what comes back replaces
 *   the image the rest of the flow uses.
 * - **Send** is active once the description — and, if required, the name — is filled.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun BugReportScreen(
    screenshot: Bitmap?,
    requiresName: Boolean,
    hasLogoTapHandler: Boolean,
    state: SubmitState,
    onSubmit: (whatHappened: String, testerName: String?, screenshot: Bitmap?) -> Unit,
    onClose: (ReportOutcome) -> Unit,
) {
    var whatHappened by remember { mutableStateOf("") }
    var testerName by remember { mutableStateOf("") }
    var currentScreenshot by remember { mutableStateOf(screenshot) }
    var markupImage by remember { mutableStateOf<Bitmap?>(null) }
    val focusManager = LocalFocusManager.current

    val sending = state is SubmitState.Sending
    val canSend = whatHappened.isNotBlank() && (!requiresName || testerName.isNotBlank()) && !sending

    // The markup editor takes the whole screen, the way the iOS full-screen cover does.
    markupImage?.let { image ->
        MarkupEditor(
            image = image,
            onDone = { marked ->
                // `null` means the tester cancelled — the screenshot stays as captured. The
                // editor only ever REPLACES the image the form holds, so the composer and the
                // queue stay markup-unaware.
                if (marked != null) currentScreenshot = marked
                markupImage = null
            },
        )
        return
    }

    CollieTheme {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            CollieLogo(
                                modifier = Modifier
                                    .size(22.dp)
                                    .then(
                                        if (hasLogoTapHandler) {
                                            Modifier
                                                .clickable(enabled = !sending) {
                                                    onClose(ReportOutcome.SwitchTool)
                                                }
                                                .semantics {
                                                    contentDescription = "Collie — switch tool"
                                                }
                                        } else {
                                            Modifier.semantics { contentDescription = "Collie" }
                                        },
                                    ),
                                tint = MaterialTheme.colorScheme.onSurface,
                            )
                            Spacer(Modifier.size(12.dp))
                            Text("Report a Problem")
                        }
                    },
                    navigationIcon = {
                        TextButton(
                            onClick = { onClose(ReportOutcome.Cancelled) },
                            enabled = !sending,
                        ) { Text("Cancel") }
                    },
                    actions = {
                        if (sending) {
                            CircularProgressIndicator(
                                modifier = Modifier
                                    .padding(end = 16.dp)
                                    .size(22.dp),
                                strokeWidth = 2.dp,
                            )
                        } else {
                            TextButton(
                                onClick = {
                                    focusManager.clearFocus()
                                    onSubmit(
                                        whatHappened.trim(),
                                        testerName.trim().takeIf { requiresName && it.isNotEmpty() },
                                        currentScreenshot,
                                    )
                                },
                                enabled = canSend,
                            ) { Text("Send") }
                        }
                    },
                )
            },
        ) { padding ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                if (requiresName) {
                    LabelledField(
                        title = "Your name",
                        placeholder = "Enter your name (asked only once)",
                        value = testerName,
                        onValueChange = { testerName = it },
                        enabled = !sending,
                        singleLine = true,
                        imeAction = ImeAction.Next,
                        onImeAction = { focusManager.moveFocus(androidx.compose.ui.focus.FocusDirection.Down) },
                    )
                }

                LabelledField(
                    title = "What happened?",
                    placeholder = "Describe the problem you ran into…",
                    value = whatHappened,
                    onValueChange = { whatHappened = it },
                    enabled = !sending,
                    singleLine = false,
                    imeAction = ImeAction.Default,
                    onImeAction = { focusManager.clearFocus() },
                )

                if (state is SubmitState.Failed) {
                    ErrorBanner(state.message)
                }

                // Below the inputs on purpose: the keyboard covers the bottom of the screen,
                // and what the tester needs to reach is the text field, not the thumbnail.
                currentScreenshot?.let { bitmap ->
                    ScreenshotPreview(
                        bitmap = bitmap,
                        enabled = !sending,
                        onTap = {
                            focusManager.clearFocus()
                            markupImage = bitmap
                        },
                    )
                }

                Spacer(Modifier.height(8.dp))
            }
        }
    }
}

@Composable
private fun LabelledField(
    title: String,
    placeholder: String,
    value: String,
    onValueChange: (String) -> Unit,
    enabled: Boolean,
    singleLine: Boolean,
    imeAction: ImeAction,
    onImeAction: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            placeholder = { Text(placeholder) },
            enabled = enabled,
            singleLine = singleLine,
            modifier = Modifier
                .fillMaxWidth()
                .then(if (singleLine) Modifier else Modifier.heightIn(min = 120.dp)),
            keyboardOptions = KeyboardOptions(imeAction = imeAction),
            keyboardActions = KeyboardActions(
                onNext = { onImeAction() },
                onDone = { onImeAction() },
            ),
        )
    }
}

/**
 * The screenshot preview. Tapping it opens the markup editor — the tester can circle the
 * problem instead of describing where it is.
 */
@Composable
private fun ScreenshotPreview(
    bitmap: Bitmap,
    enabled: Boolean,
    onTap: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            modifier = Modifier
                .heightIn(max = 220.dp)
                .clip(RoundedCornerShape(12.dp))
                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(12.dp))
                .clickable(enabled = enabled, onClick = onTap)
                .semantics { contentDescription = "Screenshot — tap to mark up" },
        ) {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Fit,
            )
        }
        Text(
            "Tap the screenshot to mark it up",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ErrorBanner(message: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Color(0x1FFF9800))
            .padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                "Could not send",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
            )
            Text(message, style = MaterialTheme.typography.bodySmall)
            Text(
                "This looks like a permanent error (configuration/permissions). If it persists, " +
                    "let the development team know.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

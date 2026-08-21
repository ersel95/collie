package com.collie.ui

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.collie.CollieScreenshotEvent

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

    /**
     * The tester wants to photograph the app: close the form — keeping everything in the
     * draft — and enter screenshot mode.
     */
    data object CaptureScreenshots : ReportOutcome
}

/** Submission state, driving the send button and the inline error. */
internal sealed interface SubmitState {
    data object Idle : SubmitState
    data object Sending : SubmitState
    data class Failed(val message: String) : SubmitState
}

/**
 * One image the report is carrying: the picture itself, plus when it arrived and where from —
 * the two facts the analyst needs and the tester never types.
 *
 * Identified rather than addressed by position: the tester can remove the second thumbnail
 * while the third is being marked up, and an index would then write the result onto the wrong
 * image.
 */
internal data class BugReportShot(
    val id: Long = nextId++,
    val bitmap: Bitmap,
    val event: CollieScreenshotEvent,
) {
    companion object {
        private var nextId: Long = 0
    }
}

/**
 * Everything the tester has entered so far.
 *
 * It lives outside the screen because the screen is **not** the only one in this flow: the
 * tester leaves it for screenshot mode, walks through the app, and comes back to a new
 * instance of the activity. What they had already written has to survive that.
 */
internal data class BugReportDraft(
    val whatHappened: String = "",
    val testerName: String = "",
    val shots: List<BugReportShot> = emptyList(),
)

/**
 * The bug report screen. Reached from the banner's **Yes**.
 *
 * The layout is the one a tester already knows from reporting a problem in a social app: a
 * title, the whole screen as one writing surface, and the evidence sitting on the keyboard
 * rather than competing with the text for room.
 *
 * - **Title**: "What happened?" — so the field itself needs no label.
 * - Everything below is **one text field**, focused on open, with the keyboard already up.
 *   The name, needed once per device, is asked in a dialog on the first **Send** — where
 *   there is room to say *why* it is being asked, which a placeholder never managed.
 * - Above the keyboard: the report's screenshots as thumbnails (each removable, each tappable
 *   into the markup editor), and two buttons — **Screenshot** hands the app back so the tester
 *   can photograph other screens, **Upload** opens the system photo picker. Both stop at
 *   [maxScreenshots].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun BugReportScreen(
    draft: BugReportDraft,
    maxScreenshots: Int,
    requiresName: Boolean,
    hasLogoTapHandler: Boolean,
    state: SubmitState,
    onDraftChanged: (BugReportDraft) -> Unit,
    onSubmit: (draft: BugReportDraft) -> Unit,
    onClose: (ReportOutcome) -> Unit,
) {
    var whatHappened by remember { mutableStateOf(draft.whatHappened) }
    var testerName by remember { mutableStateOf(draft.testerName) }
    val shots = remember { mutableStateListOf<BugReportShot>().apply { addAll(draft.shots) } }
    var markupShotId by remember { mutableStateOf<Long?>(null) }
    var isAskingName by remember { mutableStateOf(false) }
    /** What the picker returned, decoded off the main thread by the effect below. */
    var pickRequest by remember { mutableStateOf<PickRequest?>(null) }
    var nextPickId by remember { mutableStateOf(0L) }
    val focusManager = LocalFocusManager.current
    val context = LocalContext.current
    val editorFocus = remember { FocusRequester() }

    val sending = state is SubmitState.Sending
    val canSend = whatHappened.isNotBlank() && !sending
    val room = (maxScreenshots - shots.size).coerceAtLeast(0)

    fun currentDraft() = BugReportDraft(
        whatHappened = whatHappened,
        testerName = testerName,
        shots = shots.toList(),
    )

    // Decoding is I/O and can be slow for a full-resolution photo, so it never runs inside the
    // picker callback. The effect must NOT clear `pickRequest` on its way in: writing the state
    // it is keyed on cancels the very coroutine doing the decoding, and the picked images
    // silently never arrive.
    LaunchedEffect(pickRequest) {
        val uris = pickRequest?.uris ?: return@LaunchedEffect
        val space = (maxScreenshots - shots.size).coerceAtLeast(0)
        uris.take(space).forEach { uri ->
            // An image that cannot be decoded is skipped, not fatal: the rest of the selection
            // still reaches the form.
            ScreenshotPicker.load(context, uri)?.let { bitmap ->
                if (shots.size < maxScreenshots) {
                    shots += BugReportShot(
                        bitmap = bitmap,
                        // A gallery image was taken at some earlier, unknown time; what the
                        // stream can honestly record is when it was attached.
                        event = CollieScreenshotEvent(
                            epochMillis = System.currentTimeMillis(),
                            source = CollieScreenshotEvent.Source.GALLERY,
                        ),
                    )
                }
            }
        }
    }

    // Two contracts because the multi-item one rejects a limit of 1. With a single slot left
    // the tester gets the single-item picker instead of being offered a choice the form would
    // then have to throw half of away.
    val multiplePicker = rememberLauncherForActivityResult(
        remember(room) { ActivityResultContracts.PickMultipleVisualMedia(room.coerceAtLeast(2)) },
    ) { uris ->
        pickRequest = PickRequest(nextPickId, uris)
        nextPickId += 1
    }
    val singlePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        pickRequest = PickRequest(nextPickId, listOfNotNull(uri))
        nextPickId += 1
    }

    fun addScreenshots() {
        focusManager.clearFocus()
        val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
        if (room <= 1) singlePicker.launch(request) else multiplePicker.launch(request)
    }

    // The markup editor takes the whole screen, the way the iOS full-screen cover does.
    val markedShot = markupShotId?.let { id -> shots.firstOrNull { it.id == id } }
    if (markedShot != null) {
        MarkupEditor(
            image = markedShot.bitmap,
            onDone = { marked ->
                // `null` means the tester cancelled — the screenshot stays as captured. The
                // editor only ever REPLACES the image the form holds, so the composer and the
                // queue stay markup-unaware.
                //
                // Written by id: if the tester removed that thumbnail while the editor was up,
                // there is nothing to write it to and the marks go with it, rather than landing
                // on whichever image took its place.
                if (marked != null) {
                    val index = shots.indexOfFirst { it.id == markedShot.id }
                    if (index >= 0) shots[index] = markedShot.copy(bitmap = marked)
                }
                markupShotId = null
            },
        )
        return
    }

    LaunchedEffect(Unit) {
        // The tester came here to write a sentence; opening with the keyboard down costs them
        // a tap and hides the attachment bar, which lives above it.
        if (!sending) runCatching { editorFocus.requestFocus() }
    }

    if (isAskingName) {
        NameDialog(
            name = testerName,
            onNameChange = { testerName = it },
            onConfirm = {
                isAskingName = false
                onSubmit(currentDraft())
            },
            onDismiss = { isAskingName = false },
        )
    }

    CollieTheme {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            CollieLogo(
                                modifier = Modifier
                                    .size(20.dp)
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
                            Spacer(Modifier.size(10.dp))
                            Text("What happened?")
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
                                    // The name is asked for — and explained — after Send, and
                                    // the flow carries straight on from the dialog.
                                    if (requiresName && testerName.isBlank()) {
                                        isAskingName = true
                                    } else {
                                        onSubmit(currentDraft())
                                    }
                                },
                                enabled = canSend,
                            ) {
                                Text("Send", fontWeight = FontWeight.SemiBold)
                            }
                        }
                    },
                )
            },
            bottomBar = {
                // The attachment bar rides the keyboard: `imePadding` lifts it to sit directly
                // above the IME while typing, and it falls back to the navigation bar when the
                // keyboard goes away.
                if (maxScreenshots > 0) {
                    AttachmentBar(
                        shots = shots,
                        limit = maxScreenshots,
                        enabled = !sending,
                        onMarkUp = { shot ->
                            focusManager.clearFocus()
                            markupShotId = shot.id
                        },
                        onRemove = { shot -> shots.removeAll { it.id == shot.id } },
                        onCapture = {
                            focusManager.clearFocus()
                            onDraftChanged(currentDraft())
                            onClose(ReportOutcome.CaptureScreenshots)
                        },
                        onUpload = ::addScreenshots,
                    )
                }
            },
        ) { padding ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                if (state is SubmitState.Failed) {
                    ErrorBanner(state.message)
                }
                // The whole screen is the field — nothing above it, nothing beside it.
                TextField(
                    value = whatHappened,
                    onValueChange = { whatHappened = it },
                    placeholder = { Text("Describe what happened, or what did not work.") },
                    enabled = !sending,
                    modifier = Modifier
                        .fillMaxSize()
                        .focusRequester(editorFocus),
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Color.Transparent,
                        unfocusedContainerColor = Color.Transparent,
                        disabledContainerColor = Color.Transparent,
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                        disabledIndicatorColor = Color.Transparent,
                    ),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
                )
            }
        }
    }
}

/**
 * One trip through the photo picker, carrying its own id.
 *
 * The id is what makes it a *new* request every time rather than a value that happens to
 * differ: picking the same two images twice produces an equal URI list, and an effect keyed on
 * the list alone would not run the second time.
 */
private data class PickRequest(val id: Long, val uris: List<android.net.Uri>)

/**
 * The one-time name question.
 *
 * A dialog rather than a field, and raised by Send rather than by opening the form, because it
 * needs a sentence of *why*: a name asked for with no reason given reads as data collection,
 * and testers answer it with "a" and never look again.
 */
@Composable
private fun NameDialog(
    name: String,
    onNameChange: (String) -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("One thing first") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    "Reports from every test device land in one list. Your name says which " +
                        "one this came from — asked once, stored on this device.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                OutlinedTextField(
                    value = name,
                    onValueChange = onNameChange,
                    placeholder = { Text("Your name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onConfirm, enabled = name.isNotBlank()) {
                Text("Save and send")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

/**
 * The attached screenshots and the two ways to add another, directly above the keyboard.
 */
@Composable
private fun AttachmentBar(
    shots: List<BugReportShot>,
    limit: Int,
    enabled: Boolean,
    onMarkUp: (BugReportShot) -> Unit,
    onRemove: (BugReportShot) -> Unit,
    onCapture: () -> Unit,
    onUpload: () -> Unit,
) {
    val room = (limit - shots.size).coerceAtLeast(0)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainerLow)
            .imePadding()
            .navigationBarsPadding()
            .padding(vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (shots.isNotEmpty()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                shots.forEach { shot ->
                    ScreenshotThumbnail(
                        shot = shot,
                        enabled = enabled,
                        onMarkUp = { onMarkUp(shot) },
                        onRemove = { onRemove(shot) },
                    )
                }
            }
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            AttachmentButton("Screenshot", enabled && room > 0, onCapture, Modifier.weight(1f))
            AttachmentButton("Upload", enabled && room > 0, onUpload, Modifier.weight(1f))
        }
    }
}

@Composable
private fun AttachmentButton(
    title: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Text(
        text = title,
        style = MaterialTheme.typography.bodyMedium,
        fontWeight = FontWeight.Medium,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (enabled) 1f else 0.4f),
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 12.dp),
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
    )
}

@Composable
private fun ScreenshotThumbnail(
    shot: BugReportShot,
    enabled: Boolean,
    onMarkUp: () -> Unit,
    onRemove: () -> Unit,
) {
    Box(modifier = Modifier.size(width = THUMBNAIL_WIDTH, height = THUMBNAIL_HEIGHT)) {
        Image(
            bitmap = shot.bitmap.asImageBitmap(),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .fillMaxSize()
                .clip(RoundedCornerShape(8.dp))
                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(8.dp))
                .clickable(enabled = enabled, onClick = onMarkUp)
                .semantics { contentDescription = "Screenshot — tap to mark it up" },
        )
        Icon(
            imageVector = Icons.Filled.Edit,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onPrimary,
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(4.dp)
                .clip(RoundedCornerShape(50))
                .background(MaterialTheme.colorScheme.primary)
                .padding(3.dp)
                .size(11.dp),
        )
        // Drawn after the image, so it is the one that receives a tap on the corner it covers
        // — removing an image must never open the editor instead.
        Icon(
            imageVector = Icons.Filled.Close,
            contentDescription = "Remove screenshot",
            tint = Color.White,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(2.dp)
                .clip(RoundedCornerShape(50))
                .background(Color.Black.copy(alpha = 0.6f))
                .clickable(enabled = enabled, onClick = onRemove)
                .padding(2.dp)
                .size(13.dp),
        )
    }
}

/**
 * Small enough that a row of five fits above the keyboard without stealing the writing
 * surface, large enough to tell two screens of the same app apart.
 */
private val THUMBNAIL_WIDTH: Dp = 54.dp
private val THUMBNAIL_HEIGHT: Dp = 96.dp

@Composable
private fun ErrorBanner(message: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
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

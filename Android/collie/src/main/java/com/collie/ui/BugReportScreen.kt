package com.collie.ui

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
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
import androidx.compose.ui.unit.Dp
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
 * One attached image. Identified rather than addressed by position: the tester can remove
 * the second thumbnail while the third is being marked up, and an index would then write the
 * result onto the wrong image.
 */
private data class Shot(val id: Long, val bitmap: Bitmap)

/**
 * One trip through the photo picker, carrying its own id.
 *
 * The id is what makes it a *new* request every time rather than a value that happens to
 * differ: picking the same two images twice produces an equal URI list, and an effect keyed
 * on the list alone would not run the second time.
 */
private data class PickRequest(val id: Long, val uris: List<android.net.Uri>)

/**
 * The bug report screen. Reached from the banner's **Yes**.
 *
 * - One field: **"What happened?"**.
 * - On first use (no stored name) a **name** field is shown as well (one time only).
 * - **Screenshots**, up to [maxScreenshots] of them: the shake-time capture arrives already
 *   attached, and the tester can add more from the system photo picker, mark any of them up,
 *   or remove one. Tapping a thumbnail opens Collie's markup editor; what comes back
 *   replaces that thumbnail in place.
 * - **Send** is active once the description — and, if required, the name — is filled.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun BugReportScreen(
    screenshots: List<Bitmap>,
    maxScreenshots: Int,
    requiresName: Boolean,
    hasLogoTapHandler: Boolean,
    state: SubmitState,
    onSubmit: (whatHappened: String, testerName: String?, screenshots: List<Bitmap>) -> Unit,
    onClose: (ReportOutcome) -> Unit,
) {
    var whatHappened by remember { mutableStateOf("") }
    var testerName by remember { mutableStateOf("") }
    val shots = remember {
        mutableStateListOf<Shot>().apply {
            screenshots.forEachIndexed { index, bitmap -> add(Shot(index.toLong(), bitmap)) }
        }
    }
    var nextShotId by remember { mutableStateOf(screenshots.size.toLong()) }
    var markupShotId by remember { mutableStateOf<Long?>(null) }
    /** What the picker returned, decoded off the main thread by the effect below. */
    var pickRequest by remember { mutableStateOf<PickRequest?>(null) }
    var nextPickId by remember { mutableStateOf(0L) }
    val focusManager = LocalFocusManager.current
    val context = LocalContext.current

    val sending = state is SubmitState.Sending
    val canSend = whatHappened.isNotBlank() && (!requiresName || testerName.isNotBlank()) && !sending
    val room = (maxScreenshots - shots.size).coerceAtLeast(0)

    // Decoding is I/O and can be slow for a full-resolution photo, so it never runs inside
    // the picker callback: the result comes back as URIs and turns into bitmaps here.
    //
    // The effect must NOT clear `pickRequest` on its way in. Writing the state it is keyed on
    // cancels the very coroutine doing the decoding — which is exactly what happened, and the
    // picked images silently never arrived. The request simply stays put until the next one
    // replaces it.
    LaunchedEffect(pickRequest) {
        val uris = pickRequest?.uris ?: return@LaunchedEffect
        val space = (maxScreenshots - shots.size).coerceAtLeast(0)
        uris.take(space).forEach { uri ->
            // An image that cannot be decoded is skipped, not fatal: the rest of the
            // selection still reaches the form.
            ScreenshotPicker.load(context, uri)?.let { bitmap ->
                if (shots.size < maxScreenshots) {
                    shots += Shot(nextShotId, bitmap)
                    nextShotId += 1
                }
            }
        }
    }

    // Two contracts because the multi-item one rejects a limit of 1. With a single slot left
    // the tester gets the single-item picker instead of being offered a choice the form would
    // then have to throw half of away.
    val multiplePicker = rememberLauncherForActivityResult(
        remember(room) {
            ActivityResultContracts.PickMultipleVisualMedia(room.coerceAtLeast(2))
        },
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
        val request = androidx.activity.result.PickVisualMediaRequest(
            ActivityResultContracts.PickVisualMedia.ImageOnly,
        )
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
                                        shots.map { it.bitmap },
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
                // and what the tester needs to reach is the text field, not the thumbnails.
                //
                // Hidden entirely when the report may carry no image at all (a host or server
                // that turned them off): an empty row with a dead "Add" tile would be a
                // promise the transport does not keep.
                if (maxScreenshots > 0) {
                    ScreenshotRow(
                        shots = shots,
                        limit = maxScreenshots,
                        enabled = !sending,
                        onMarkUp = { shot ->
                            focusManager.clearFocus()
                            markupShotId = shot.id
                        },
                        onRemove = { shot -> shots.removeAll { it.id == shot.id } },
                        onAdd = ::addScreenshots,
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
 * The attached screenshots, in a row that scrolls when it outgrows the screen. Tapping one
 * opens the markup editor — the tester can circle the problem instead of describing where it
 * is — and the tile at the end adds more, until the limit is reached and it disappears.
 */
@Composable
private fun ScreenshotRow(
    shots: List<Shot>,
    limit: Int,
    enabled: Boolean,
    onMarkUp: (Shot) -> Unit,
    onRemove: (Shot) -> Unit,
    onAdd: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Screenshots",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            Text(
                "${shots.size}/$limit",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                // Room for the remove badge, which sits half outside the thumbnail.
                .padding(vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            shots.forEach { shot ->
                ScreenshotThumbnail(
                    shot = shot,
                    enabled = enabled,
                    onMarkUp = { onMarkUp(shot) },
                    onRemove = { onRemove(shot) },
                )
            }
            if (shots.size < limit) {
                AddScreenshotTile(enabled = enabled, onAdd = onAdd)
            }
        }
        Text(
            if (shots.isEmpty()) {
                "Add a screenshot to show what you saw."
            } else {
                "Tap a screenshot to mark it up."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ScreenshotThumbnail(
    shot: Shot,
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
                .clip(RoundedCornerShape(12.dp))
                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(12.dp))
                .clickable(enabled = enabled, onClick = onMarkUp)
                .semantics { contentDescription = "Screenshot — tap to mark up" },
        )
        Icon(
            imageVector = Icons.Filled.Edit,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onPrimary,
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(6.dp)
                .clip(RoundedCornerShape(50))
                .background(MaterialTheme.colorScheme.primary)
                .padding(4.dp)
                .size(14.dp),
        )
        // Drawn after the image, so it is the one that receives a tap on the corner it
        // covers — removing an image must never open the editor instead.
        Icon(
            imageVector = Icons.Filled.Close,
            contentDescription = "Remove screenshot",
            tint = Color.White,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(4.dp)
                .clip(RoundedCornerShape(50))
                .background(Color.Black.copy(alpha = 0.55f))
                .clickable(enabled = enabled, onClick = onRemove)
                .padding(3.dp)
                .size(16.dp),
        )
    }
}

@Composable
private fun AddScreenshotTile(enabled: Boolean, onAdd: () -> Unit) {
    Column(
        modifier = Modifier
            .size(width = THUMBNAIL_WIDTH, height = THUMBNAIL_HEIGHT)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(12.dp))
            .clickable(enabled = enabled, onClick = onAdd)
            .semantics { contentDescription = "Add a screenshot" },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.Add,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(28.dp),
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "Add",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.primary,
        )
    }
}

/**
 * Portrait-ish tiles: a phone screenshot at this size is still recognisable, and three of
 * them fit a phone's width without the row having to scroll.
 */
private val THUMBNAIL_WIDTH: Dp = 96.dp
private val THUMBNAIL_HEIGHT: Dp = 160.dp

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

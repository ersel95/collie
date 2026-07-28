package com.collie.ui

import android.graphics.Bitmap
import android.graphics.Canvas as AndroidCanvas
import android.graphics.Paint
import android.graphics.Path as AndroidPath
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlin.math.min

/**
 * Markup is **one screen, in Collie's own UI**: the screenshot, a drawing surface over it,
 * and a palette with pen / marker / eraser, three widths and six colours. Done flattens the
 * strokes into the screenshot at its native pixel size and returns; Cancel returns nothing
 * and the screenshot stays exactly as it was captured.
 *
 * This is drawn by Collie rather than handed to a system editor, for the same reason the iOS
 * SDK stopped using QuickLook and `PKToolPicker`: an editor Collie does not own puts its own
 * pages, its own chrome and its own window layering between the tester and the one thing
 * they came to do.
 *
 * The editor only ever hands back a **complete replacement image**. Marks a tester draws to
 * hide something must never travel separately from the pixels they cover, so nothing
 * downstream — composer, queue, envelope — knows markup exists.
 */
@Composable
internal fun MarkupEditor(
    image: Bitmap,
    onDone: (Bitmap?) -> Unit,
) {
    val strokes = remember { mutableStateListOf<MarkupStroke>() }
    var tool by remember { mutableStateOf(MarkupTool.PEN) }
    var width by remember { mutableStateOf(MarkupWidth.MEDIUM) }
    var color by remember { mutableStateOf(MarkupColors.first()) }
    // How much the screenshot is shrunk to fit the editor; Done needs it to put the strokes
    // back at full resolution.
    var displayScale by remember { mutableStateOf(1f) }

    CollieTheme {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black),
        ) {
            BoxWithConstraints(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(bottom = 120.dp),
                contentAlignment = Alignment.Center,
            ) {
                // The screenshot is letterboxed to fit, so the drawing surface has to use the
                // SAME rect — otherwise a stroke lands somewhere else once flattened.
                val maxWidthPx = with(androidx.compose.ui.platform.LocalDensity.current) {
                    maxWidth.toPx()
                }
                val maxHeightPx = with(androidx.compose.ui.platform.LocalDensity.current) {
                    maxHeight.toPx()
                }
                val scale = min(maxWidthPx / image.width, maxHeightPx / image.height)
                displayScale = scale
                val displayWidth = with(androidx.compose.ui.platform.LocalDensity.current) {
                    (image.width * scale).toDp()
                }
                val displayHeight = with(androidx.compose.ui.platform.LocalDensity.current) {
                    (image.height * scale).toDp()
                }

                Box(
                    modifier = Modifier.size(displayWidth, displayHeight),
                ) {
                    androidx.compose.foundation.Image(
                        bitmap = image.asImageBitmap(),
                        contentDescription = null,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxSize(),
                    )

                    Canvas(
                        modifier = Modifier
                            .fillMaxSize()
                            .semantics { contentDescription = "Markup canvas" }
                            .pointerInput(tool, width, color) {
                                detectDragGestures(
                                    onDragStart = { start ->
                                        if (tool == MarkupTool.ERASER) {
                                            eraseAt(strokes, start)
                                        } else {
                                            strokes.add(
                                                MarkupStroke(
                                                    points = mutableStateListOf(start),
                                                    color = color.value,
                                                    strokeWidth = width.value(marker = tool == MarkupTool.MARKER),
                                                    isMarker = tool == MarkupTool.MARKER,
                                                ),
                                            )
                                        }
                                    },
                                    onDrag = { change, _ ->
                                        change.consume()
                                        if (tool == MarkupTool.ERASER) {
                                            eraseAt(strokes, change.position)
                                        } else {
                                            // `points` is a snapshot list, so appending to it
                                            // is what redraws the canvas — no copy needed.
                                            strokes.lastOrNull()?.points?.add(change.position)
                                        }
                                    },
                                )
                            },
                    ) {
                        strokes.forEach { stroke -> drawStroke(stroke) }
                    }
                }
            }

            MarkupPalette(
                tool = tool,
                width = width,
                color = color,
                onToolChange = { tool = it },
                onWidthChange = { width = it },
                onColorChange = { color = it },
                onCancel = { onDone(null) },
                onDone = { onDone(flatten(image, strokes, displayScale)) },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(16.dp),
            )
        }
    }
}

// MARK: - Model

internal enum class MarkupTool(val label: String) {
    PEN("Pen"),
    MARKER("Marker"),
    ERASER("Eraser"),
}

/**
 * Thin / medium / thick, per tool — a marker stroke has to be far wider than a pen's to read
 * as a highlight. The values match the iOS palette so a report looks the same on both.
 */
internal enum class MarkupWidth(val label: String, val dotSize: Float) {
    THIN("thin", 8f),
    MEDIUM("medium", 13f),
    THICK("thick", 18f),
    ;

    fun value(marker: Boolean): Float = when (this) {
        THIN -> if (marker) 14f else 4f
        MEDIUM -> if (marker) 24f else 9f
        THICK -> if (marker) 38f else 16f
    }
}

/**
 * Bug-report colours: what a tester circles a defect with. Red first — it is what nearly
 * every annotation uses.
 */
internal data class MarkupColor(val name: String, val value: Color)

internal val MarkupColors: List<MarkupColor> = listOf(
    MarkupColor("Red", Color(0xFFFF3B30)),
    MarkupColor("Orange", Color(0xFFFF9500)),
    MarkupColor("Yellow", Color(0xFFFFCC00)),
    MarkupColor("Green", Color(0xFF34C759)),
    MarkupColor("Blue", Color(0xFF007AFF)),
    MarkupColor("Black", Color(0xFF000000)),
)

internal data class MarkupStroke(
    val points: MutableList<Offset>,
    val color: Color,
    val strokeWidth: Float,
    val isMarker: Boolean,
)

// MARK: - Drawing

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawStroke(stroke: MarkupStroke) {
    if (stroke.points.isEmpty()) return
    val path = androidx.compose.ui.graphics.Path().apply {
        moveTo(stroke.points.first().x, stroke.points.first().y)
        stroke.points.drop(1).forEach { lineTo(it.x, it.y) }
    }
    drawPath(
        path = path,
        color = if (stroke.isMarker) stroke.color.copy(alpha = 0.35f) else stroke.color,
        style = Stroke(
            width = stroke.strokeWidth,
            cap = StrokeCap.Round,
            join = StrokeJoin.Round,
        ),
    )
}

/**
 * The eraser removes whole strokes rather than pixels. A tester who wants a mark gone wants
 * it gone; a partial rub-out just leaves a smear they then have to erase again.
 */
private fun eraseAt(strokes: MutableList<MarkupStroke>, point: Offset) {
    val hit = strokes.indexOfLast { stroke ->
        stroke.points.any { (it - point).getDistance() <= (stroke.strokeWidth / 2f) + 12f }
    }
    if (hit >= 0) strokes.removeAt(hit)
}

/**
 * Flattens the strokes into a copy of the screenshot at its **native pixel size**, so the
 * uploaded image is the full-resolution capture with the marks burned in — not a
 * screen-sized re-render.
 *
 * [displayScale] is how much the screenshot was shrunk to fit the editor. Stroke
 * coordinates are in that shrunken space, so both the points and the stroke width are
 * divided by it on the way back to full resolution — otherwise a circle drawn around a
 * button lands somewhere else, thinner, in the uploaded image.
 */
private fun flatten(image: Bitmap, strokes: List<MarkupStroke>, displayScale: Float): Bitmap {
    if (strokes.isEmpty() || displayScale <= 0f) return image

    val output = image.copy(Bitmap.Config.ARGB_8888, true) ?: return image
    val canvas = AndroidCanvas(output)

    strokes.forEach { stroke ->
        if (stroke.points.isEmpty()) return@forEach
        val paint = Paint().apply {
            isAntiAlias = true
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            strokeWidth = stroke.strokeWidth / displayScale
            color = if (stroke.isMarker) {
                stroke.color.copy(alpha = 0.35f).toArgb()
            } else {
                stroke.color.toArgb()
            }
        }
        val path = AndroidPath().apply {
            val first = stroke.points.first()
            moveTo(first.x / displayScale, first.y / displayScale)
            stroke.points.drop(1).forEach { lineTo(it.x / displayScale, it.y / displayScale) }
        }
        canvas.drawPath(path, paint)
    }
    return output
}

// MARK: - Palette

/**
 * Collie's own markup palette: tool, stroke width and colour, living in the same window as
 * the canvas — which is the whole point.
 */
@Composable
private fun MarkupPalette(
    tool: MarkupTool,
    width: MarkupWidth,
    color: MarkupColor,
    onToolChange: (MarkupTool) -> Unit,
    onWidthChange: (MarkupWidth) -> Unit,
    onColorChange: (MarkupColor) -> Unit,
    onCancel: () -> Unit,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(26.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 3.dp,
        shadowElevation = 8.dp,
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onCancel) { Text("Cancel") }

                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    MarkupTool.entries.forEach { entry ->
                        ToolChip(
                            label = entry.label,
                            selected = entry == tool,
                            onClick = { onToolChange(entry) },
                        )
                    }
                }

                TextButton(onClick = onDone) { Text("Done") }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    MarkupWidth.entries.forEach { entry ->
                        Box(
                            modifier = Modifier
                                .size(30.dp)
                                .semantics { contentDescription = "${entry.label} stroke" }
                                .clickable { onWidthChange(entry) },
                            contentAlignment = Alignment.Center,
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(entry.dotSize.dp)
                                    .background(
                                        if (entry == width) {
                                            MaterialTheme.colorScheme.primary
                                        } else {
                                            MaterialTheme.colorScheme.onSurfaceVariant
                                        },
                                        CircleShape,
                                    ),
                            )
                        }
                    }
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    MarkupColors.forEach { entry ->
                        Box(
                            modifier = Modifier
                                .size(26.dp)
                                .background(entry.value, CircleShape)
                                .border(
                                    width = if (entry == color) 3.dp else 1.dp,
                                    color = if (entry == color) {
                                        MaterialTheme.colorScheme.primary
                                    } else {
                                        MaterialTheme.colorScheme.outlineVariant
                                    },
                                    shape = CircleShape,
                                )
                                .semantics { contentDescription = entry.name }
                                .clickable { onColorChange(entry) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ToolChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = if (selected) {
            MaterialTheme.colorScheme.primary
        } else {
            MaterialTheme.colorScheme.surfaceVariant
        },
        onClick = onClick,
    ) {
        Text(
            text = label,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            style = MaterialTheme.typography.labelLarge,
            color = if (selected) {
                MaterialTheme.colorScheme.onPrimary
            } else {
                MaterialTheme.colorScheme.onSurface
            },
        )
    }
}

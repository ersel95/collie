package com.collie.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope

/**
 * Collie's own colours, deliberately **not** the host's.
 *
 * A bug reporter that inherits the app's theme looks like part of the app, and a tester who
 * cannot tell the tool from the product files reports about the tool. Light/dark still
 * follows the system, so the overlay does not glare at night.
 */
@Composable
internal fun CollieTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) DarkScheme else LightScheme,
        content = content,
    )
}

private val CollieBlue = Color(0xFF2F6FED)

private val LightScheme = lightColorScheme(
    primary = CollieBlue,
    onPrimary = Color.White,
)

private val DarkScheme = darkColorScheme(
    primary = CollieBlue,
    onPrimary = Color.White,
)

/**
 * The paw mark, drawn rather than shipped as a drawable: one asset fewer to keep in sync
 * with iOS's SF Symbol, and nothing for a host's resource shrinker to strip by mistake.
 */
@Composable
internal fun CollieLogo(
    modifier: Modifier = Modifier,
    tint: Color = MaterialTheme.colorScheme.onSurface,
) {
    Canvas(modifier = modifier) { drawPaw(tint) }
}

private fun DrawScope.drawPaw(tint: Color) {
    val width = size.width
    val height = size.height

    // Pad: a wide rounded shape across the bottom half.
    drawOval(
        color = tint,
        topLeft = Offset(width * 0.18f, height * 0.45f),
        size = Size(width * 0.64f, height * 0.45f),
    )

    // Toes: three across the top, the outer two dropped slightly, as a paw reads.
    val toe = Size(width * 0.22f, width * 0.28f)
    drawOval(color = tint, topLeft = Offset(width * 0.06f, height * 0.22f), size = toe)
    drawOval(color = tint, topLeft = Offset(width * 0.39f, height * 0.06f), size = toe)
    drawOval(color = tint, topLeft = Offset(width * 0.72f, height * 0.22f), size = toe)
}

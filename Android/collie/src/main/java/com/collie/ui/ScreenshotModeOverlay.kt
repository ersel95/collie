package com.collie.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.border
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * **Screenshot mode**: the report form steps aside so the tester can walk back through the app
 * and photograph the screens that matter, one tap each.
 *
 * A bug is rarely one screen. The shake happens where the tester noticed the problem, but what
 * an analyst needs is often two screens back — the list they came from, the form they filled,
 * the notification that started it. Describing that in prose is what testers do when the tool
 * gives them one picture; this is the tool giving them five.
 *
 * Two controls and **nothing else**: a bar across the top that says the mode is on and returns
 * to the report, and a shutter in the bottom-right corner. They are attached to the host
 * activity as two separate wrap-content views rather than one full-screen overlay, which is
 * what keeps the app between them usable — a full-screen view would take every touch and
 * freeze the app the tester is trying to photograph. (iOS solves the same problem in its own
 * window with `hitTest`; here the layout params do it.)
 *
 * One tap on the shutter takes the picture and returns to the report, so the tester sees what
 * they attached instead of a counter ticking up in the corner.
 */
@Composable
internal fun ScreenshotModeBar(onExit: () -> Unit) {
    CollieTheme {
        Text(
            text = "Screenshot mode — tap to go back to your report",
            color = Color.White,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                // Background first, inset second: the red runs behind the status bar the way
                // a system banner does, while the text sits below it. The host may or may not
                // be edge-to-edge, and `statusBarsPadding` is a no-op when it is not.
                .background(SCREENSHOT_MODE_RED)
                .clickable(onClick = onExit)
                .semantics { contentDescription = "Leave screenshot mode" }
                .statusBarsPadding()
                .padding(horizontal = 12.dp, vertical = 9.dp),
        )
    }
}

/** The shutter, with the count of what the report already carries above it. */
@Composable
internal fun ScreenshotModeShutter(
    count: Int,
    limit: Int,
    onCapture: () -> Unit,
) {
    CollieTheme {
        Box(
            modifier = Modifier
                .navigationBarsPadding()
                .padding(end = 20.dp, bottom = 28.dp),
            contentAlignment = Alignment.BottomEnd,
        ) {
            Text(
                text = "$count/$limit",
                color = Color.White,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .clip(RoundedCornerShape(10.dp))
                    .background(Color.Black.copy(alpha = 0.72f))
                    .padding(horizontal = 8.dp, vertical = 2.dp),
            )
            Box(
                modifier = Modifier
                    .padding(top = 28.dp)
                    .size(64.dp)
                    .clip(CircleShape)
                    .background(SCREENSHOT_MODE_RED)
                    .clickable(onClick = onCapture)
                    .semantics { contentDescription = "Take a screenshot" },
                contentAlignment = Alignment.Center,
            ) {
                // A ring rather than a camera glyph: `material-icons-core` ships no camera,
                // and pulling in `material-icons-extended` for one symbol would put a few
                // thousand vectors into every host app. A ring is what a shutter looks like.
                Box(
                    Modifier
                        .size(30.dp)
                        .clip(CircleShape)
                        .border(2.5.dp, Color.White, CircleShape),
                )
            }
        }
    }
}

/**
 * Red, not the host's accent: the point of both controls is that the app is in a mode it did
 * not ask to be in, and a colour that blends into the host is the one thing they must not be.
 */
private val SCREENSHOT_MODE_RED = Color(0xFFE53935)

package com.collie.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/**
 * The Collie paw + a bubble sliding in from the bottom. [Yes] [No].
 *
 * Only the bubble occupies space — the composable is attached wrap-content — so every touch
 * outside it goes to the app underneath, exactly like the passthrough window on iOS.
 */
@Composable
internal fun BugReportBanner(
    onYes: () -> Unit,
    onNo: () -> Unit,
) {
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }

    val offset by animateFloatAsState(
        targetValue = if (appeared) 0f else 140f,
        animationSpec = spring(dampingRatio = 0.8f, stiffness = 380f),
        label = "banner-offset",
    )

    CollieTheme {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp)
                .graphicsLayer { translationY = offset }
                .alpha(if (appeared) 1f else 0f),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            CollieLogo(
                modifier = Modifier
                    .size(64.dp)
                    .background(MaterialTheme.colorScheme.primary, CircleShape)
                    .padding(17.dp)
                    .semantics { contentDescription = "Collie" },
                tint = MaterialTheme.colorScheme.onPrimary,
            )

            Surface(
                shape = RoundedCornerShape(16.dp),
                color = MaterialTheme.colorScheme.surface,
                tonalElevation = 3.dp,
                shadowElevation = 8.dp,
            ) {
                Box(Modifier.padding(14.dp)) {
                    androidx.compose.foundation.layout.Column(
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Text(
                            text = "Spotted a problem? Want to share it?",
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Button(
                                onClick = onYes,
                                shape = CircleShape,
                                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                                    horizontal = 18.dp,
                                    vertical = 8.dp,
                                ),
                            ) {
                                Text("Yes", style = MaterialTheme.typography.labelLarge)
                            }
                            TextButton(
                                onClick = onNo,
                                shape = CircleShape,
                                colors = ButtonDefaults.textButtonColors(
                                    containerColor = MaterialTheme.colorScheme.surfaceVariant,
                                    contentColor = MaterialTheme.colorScheme.onSurface,
                                ),
                            ) {
                                Text("No", style = MaterialTheme.typography.labelLarge)
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.width(0.dp))
        }
    }
}

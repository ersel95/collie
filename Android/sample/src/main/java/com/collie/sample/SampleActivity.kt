package com.collie.sample

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.collie.Collie

/**
 * The Android counterpart of `Examples/CollieHarness`.
 *
 * A shake cannot be triggered from a script on an emulator any more reliably than it can on
 * a simulator, so this puts the whole flow one tap away: the button calls
 * [Collie.presentReport], which opens the report form directly, and the screen has enough
 * content (text, a field, colours) that a screenshot of it is worth marking up.
 *
 * It is also the API-compatibility gate: CI compiles it against `:collie` **and** against
 * `:collie-no-op`, so the two artifacts cannot drift apart unnoticed.
 */
class SampleActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                var note by remember { mutableStateOf("") }

                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text("Collie sample", style = MaterialTheme.typography.headlineMedium)
                    Text(
                        "Shake the device, or use the button below — the button skips the " +
                            "\"Spotted a problem?\" question, the way a hand-off from another " +
                            "tool does.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    TextField(
                        value = note,
                        onValueChange = { note = it },
                        label = { Text("Something to appear in the screenshot") },
                    )
                    Button(onClick = { Collie.presentReport() }) {
                        Text("Report a problem")
                    }
                    Button(onClick = { Collie.flushPendingUploads() }) {
                        Text("Flush pending uploads")
                    }
                }
            }
        }
    }
}

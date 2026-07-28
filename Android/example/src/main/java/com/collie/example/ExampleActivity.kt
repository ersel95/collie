package com.collie.example

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.chuckerteam.chucker.api.Chucker
import com.collie.Collie
import kotlinx.coroutines.launch

/**
 * A small app that actually talks to the network, so there is real traffic to inspect in
 * Chucker and real log entries to travel inside a Collie report.
 *
 * The "Break something" button is the point of the whole example: it fires a request that
 * fails, which is what a tester would then shake the device to report — and the report they
 * file carries that exact failure in its log stream.
 */
class ExampleActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as ExampleApp
        val api = PostsApi(app.httpClient)

        app.logs.log(
            level = "info",
            category = "navigation",
            message = "ExampleActivity",
            metadata = mapOf("screen" to "ExampleActivity", "kind" to "appear"),
        )

        setContent {
            MaterialTheme {
                var posts by remember { mutableStateOf<List<Post>>(emptyList()) }
                var status by remember { mutableStateOf("Nothing loaded yet") }
                var loading by remember { mutableStateOf(false) }
                val scope = rememberCoroutineScope()

                fun run(label: String, block: suspend () -> String) {
                    scope.launch {
                        loading = true
                        status = "$label…"
                        status = runCatching { block() }
                            .getOrElse { error -> "$label failed: ${error.message}" }
                        loading = false
                    }
                }

                Scaffold { padding ->
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(padding)
                            .padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text("Posts", style = MaterialTheme.typography.headlineSmall)
                        Text(
                            status,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )

                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(
                                enabled = !loading,
                                onClick = {
                                    run("Loading posts") {
                                        posts = api.posts()
                                        "Loaded ${posts.size} posts"
                                    }
                                },
                            ) { Text("Load posts") }

                            Button(
                                enabled = !loading,
                                onClick = {
                                    run("Creating a post") {
                                        val created = api.createPost("Collie", "Filed from the example")
                                        "Created post #$created"
                                    }
                                },
                            ) { Text("Create post") }
                        }

                        OutlinedButton(
                            enabled = !loading,
                            modifier = Modifier.fillMaxWidth(),
                            onClick = {
                                app.logs.log("warning", "app", "Tester asked for a broken call")
                                run("Breaking something") {
                                    val code = api.brokenCall()
                                    "Server said $code — this is the bug to report"
                                }
                            },
                        ) { Text("Break something (then shake to report it)") }

                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(
                                modifier = Modifier.weight(1f),
                                onClick = { startActivity(Chucker.getLaunchIntent(this@ExampleActivity)) },
                            ) { Text("Open Chucker") }

                            OutlinedButton(
                                modifier = Modifier.weight(1f),
                                // Skips the "Spotted a problem?" question, exactly like a
                                // hand-off from another tool.
                                onClick = { Collie.presentReport() },
                            ) { Text("Report a bug") }
                        }

                        if (loading) CircularProgressIndicator()

                        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(posts) { post ->
                                Card(Modifier.fillMaxWidth()) {
                                    Column(Modifier.padding(12.dp)) {
                                        Text(
                                            post.title,
                                            style = MaterialTheme.typography.titleSmall,
                                            fontWeight = FontWeight.SemiBold,
                                        )
                                        Text(post.body, style = MaterialTheme.typography.bodySmall)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // A queued report (the tester was offline when they filed it) gets another chance
        // every time the app comes forward.
        Collie.flushPendingUploads()
    }

    /** Kept so the example's own deep links do not confuse the Chucker shortcut. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }
}

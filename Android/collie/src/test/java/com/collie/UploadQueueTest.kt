package com.collie

import com.collie.internal.UploadQueue
import kotlinx.coroutines.awaitCancellation
import org.json.JSONObject
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * The queue is what makes a report survive a tester who is offline, on the wrong VPN, or
 * closing the app mid-send. Mirrors `UploadQueueTests.swift`; the idempotency assertions
 * are the important ones — a retry must never create a second report.
 */
class UploadQueueTest {

    @get:Rule
    val folder: TemporaryFolder = TemporaryFolder()

    /** Records every attempt so the tests can assert on the idempotency keys. */
    private class FakeTransport(
        var outcomes: MutableList<CollieOperationResult<String>>,
    ) : ReportTransport {
        val reportIds = mutableListOf<String>()
        var uploads = 0

        override suspend fun upload(
            reportId: String,
            envelope: ByteArray,
            screenshots: List<ByteArray>,
        ): CollieOperationResult<String> {
            uploads += 1
            reportIds += reportId
            this.screenshots += screenshots
            return if (outcomes.size > 1) outcomes.removeAt(0) else outcomes.first()
        }

        /** The images seen on each attempt, so order and count are checkable. */
        val screenshots = mutableListOf<List<ByteArray>>()

        override suspend fun fetchRemoteConfig(): CollieRemoteConfig? = null
    }

    private class HangingTransport : ReportTransport {
        override suspend fun upload(
            reportId: String,
            envelope: ByteArray,
            screenshots: List<ByteArray>,
        ): CollieOperationResult<String> = awaitCancellation()

        override suspend fun fetchRemoteConfig(): CollieRemoteConfig? = null
    }

    private val configuration = CollieConfiguration(
        enabled = true,
        apiBaseUrl = "https://collie.example.com",
        apiKey = "key",
        maxRetryCount = 2,
        baseRetryDelayMillis = 0,
    )

    private fun queue(transport: ReportTransport) = UploadQueue(
        configuration = configuration,
        transport = transport,
        directory = folder.newFolder(),
    )

    private val body = """{"report":{}}""".toByteArray()

    // MARK: - Submit

    @Test
    fun `submit uploads the report with its screenshot`() = runTest {
        val transport = FakeTransport(mutableListOf(CollieOperationResult.Success("server-1")))
        val outcome = queue(transport).submit(body, listOf(byteArrayOf(1, 2, 3)))

        assertEquals(CollieSubmitOutcome.Sent("server-1"), outcome)
        assertEquals(1, transport.uploads)
        assertEquals(3, transport.screenshots.first().single().size)
    }

    @Test
    fun `submit without a screenshot still uploads`() = runTest {
        val transport = FakeTransport(mutableListOf(CollieOperationResult.Success("server-1")))
        val outcome = queue(transport).submit(body, emptyList())

        assertEquals(CollieSubmitOutcome.Sent("server-1"), outcome)
        assertEquals(emptyList<ByteArray>(), transport.screenshots.first())
    }

    @Test
    fun `a permanent failure is rejected and never queued`() = runTest {
        val transport = FakeTransport(mutableListOf(CollieOperationResult.PermanentFailure("401")))
        val queue = queue(transport)

        val outcome = queue.submit(body, emptyList())

        assertTrue(outcome is CollieSubmitOutcome.Rejected)
        assertEquals(0, queue.pendingCount())
    }

    @Test
    fun `a transient failure queues the report`() = runTest {
        val transport = FakeTransport(mutableListOf(CollieOperationResult.TransientFailure("offline")))
        val queue = queue(transport)

        assertEquals(CollieSubmitOutcome.Queued, queue.submit(body, emptyList()))
        assertEquals(1, queue.pendingCount())
    }

    @Test
    fun `an upload that exceeds the request timeout is queued`() = runTest {
        val queue = queue(HangingTransport())

        assertEquals(CollieSubmitOutcome.Queued, queue.submit(body, emptyList()))
        assertEquals(1, queue.pendingCount())
    }

    // MARK: - Drain

    @Test
    fun `drain completes a queued report`() = runTest {
        val transport = FakeTransport(
            mutableListOf(
                CollieOperationResult.TransientFailure("offline"),
                CollieOperationResult.Success("server-1"),
            ),
        )
        val queue = queue(transport)
        queue.submit(body, emptyList())

        queue.drain()

        assertEquals(0, queue.pendingCount())
        assertEquals(2, transport.uploads)
    }

    @Test
    fun `a queued report is dropped on a permanent failure`() = runTest {
        val transport = FakeTransport(
            mutableListOf(
                CollieOperationResult.TransientFailure("offline"),
                CollieOperationResult.PermanentFailure("400 malformed"),
            ),
        )
        val queue = queue(transport)
        queue.submit(body, emptyList())

        queue.drain()

        assertEquals(0, queue.pendingCount())
    }

    @Test
    fun `a report is dropped once it exceeds the retry limit`() = runTest {
        val transport = FakeTransport(mutableListOf(CollieOperationResult.TransientFailure("offline")))
        val queue = queue(transport)
        queue.submit(body, emptyList())

        // maxRetryCount = 2 → the third drain is the one that gives up.
        repeat(3) { queue.drain() }

        assertEquals(0, queue.pendingCount())
    }

    @Test
    fun `background retries retain a transient report beyond the foreground limit`() = runTest {
        val transport = FakeTransport(mutableListOf(CollieOperationResult.TransientFailure("vpn")))
        val queue = queue(transport)
        queue.submit(body, emptyList())

        repeat(5) { queue.drain(retainTransientFailures = true) }

        assertEquals(1, queue.pendingCount())
        transport.outcomes = mutableListOf(CollieOperationResult.Success("server-1"))
        queue.drain(retainTransientFailures = true)
        assertEquals(0, queue.pendingCount())
    }

    // MARK: - Idempotency

    @Test
    fun `a retry reuses the same idempotency key`() = runTest {
        val transport = FakeTransport(
            mutableListOf(
                CollieOperationResult.TransientFailure("offline"),
                CollieOperationResult.Success("server-1"),
            ),
        )
        val queue = queue(transport)
        queue.submit(body, emptyList())
        queue.drain()

        // A response lost in transit must resolve to the SAME report, not a second one.
        assertEquals(2, transport.reportIds.size)
        assertEquals(transport.reportIds[0], transport.reportIds[1])
    }

    @Test
    fun `distinct reports get distinct idempotency keys`() = runTest {
        val transport = FakeTransport(mutableListOf(CollieOperationResult.Success("server-1")))
        val queue = queue(transport)

        queue.submit(body, emptyList())
        queue.submit(body, emptyList())

        assertNotEquals(transport.reportIds[0], transport.reportIds[1])
    }

    // MARK: - Persistence

    @Test
    fun `the queue resumes from disk after a restart`() = runTest {
        val directory = folder.newFolder()
        val failing = FakeTransport(mutableListOf(CollieOperationResult.TransientFailure("offline")))
        UploadQueue(configuration, failing, directory).submit(body, listOf(byteArrayOf(9)))

        // A brand-new queue over the same directory — as after a process restart.
        val succeeding = FakeTransport(mutableListOf(CollieOperationResult.Success("server-1")))
        val restarted = UploadQueue(configuration, succeeding, directory)
        assertEquals(1, restarted.pendingCount())

        restarted.drain()

        assertEquals(0, restarted.pendingCount())
        // The screenshot came back off disk with the report it belongs to.
        assertEquals(1, succeeding.screenshots.first().single().size)
    }

    // MARK: - Several screenshots

    @Test
    fun `every screenshot survives the round trip to disk, in order`() = runTest {
        val directory = folder.newFolder()
        val images = listOf(byteArrayOf(1), byteArrayOf(2, 2), byteArrayOf(3, 3, 3))
        val failing = FakeTransport(mutableListOf(CollieOperationResult.TransientFailure("offline")))
        UploadQueue(configuration, failing, directory).submit(body, images)

        val succeeding = FakeTransport(mutableListOf(CollieOperationResult.Success("server-1")))
        UploadQueue(configuration, succeeding, directory).drain()

        // The panel numbers them by position, so a queue that reordered them would caption
        // the wrong picture.
        assertEquals(listOf(1, 2, 3), succeeding.screenshots.first().map { it.size })
        assertEquals(
            emptyList<String>(),
            directory.list()?.toList()?.sorted() ?: emptyList<String>(),
        )
    }

    /**
     * An envelope written by a build that predated multiple screenshots: `hasScreenshot` and
     * a single unsuffixed file, no `screenshotCount`. It has to be read back after the app
     * update, or a report queued off-VPN loses its image to the upgrade.
     */
    @Test
    fun `a legacy envelope on disk still finds its screenshot`() = runTest {
        val directory = folder.newFolder()
        val id = "6e6f2a30-0000-4000-8000-000000000001"
        val now = System.currentTimeMillis()
        val legacy = JSONObject()
            .put("id", id)
            .put("attempt", 0)
            .put("createdAt", now)
            .put("nextAttemptAt", now - 1)
            .put("hasScreenshot", true)
            .toString()
        File(directory, "$id.json").writeText(legacy)
        File(directory, "$id.report").writeBytes(body)
        File(directory, "$id.screenshot").writeBytes(byteArrayOf(7, 7))

        val transport = FakeTransport(mutableListOf(CollieOperationResult.Success("server-1")))
        UploadQueue(configuration, transport, directory).drain()

        assertEquals(listOf(2), transport.screenshots.first().map { it.size })
        // The old unsuffixed file must be cleaned up too.
        assertEquals(emptyList<String>(), directory.list()?.toList() ?: emptyList<String>())
    }

    /**
     * The same legacy envelope, but the retry fails: it is written back to disk, and it must
     * come back as legacy. Stamping a `screenshotCount` on it would point the next attempt at
     * `<id>.screenshot.0`, a file that build never wrote — and the image would disappear on
     * the retry rather than on the upgrade.
     */
    @Test
    fun `rewriting a legacy envelope does not lose its screenshot`() = runTest {
        val directory = folder.newFolder()
        val id = "6e6f2a30-0000-4000-8000-000000000002"
        val now = System.currentTimeMillis()
        val legacy = JSONObject()
            .put("id", id)
            .put("attempt", 0)
            .put("createdAt", now)
            .put("nextAttemptAt", now - 1)
            .put("hasScreenshot", true)
            .toString()
        File(directory, "$id.json").writeText(legacy)
        File(directory, "$id.report").writeBytes(body)
        File(directory, "$id.screenshot").writeBytes(byteArrayOf(7, 7))

        val failing = FakeTransport(mutableListOf(CollieOperationResult.TransientFailure("offline")))
        UploadQueue(configuration, failing, directory).drain()

        val succeeding = FakeTransport(mutableListOf(CollieOperationResult.Success("server-1")))
        UploadQueue(configuration, succeeding, directory).drain()

        assertEquals(listOf(2), succeeding.screenshots.first().map { it.size })
    }
}

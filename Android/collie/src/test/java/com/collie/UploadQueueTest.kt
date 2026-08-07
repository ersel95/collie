package com.collie

import com.collie.internal.UploadQueue
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

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
            screenshot: ByteArray?,
        ): CollieOperationResult<String> {
            uploads += 1
            reportIds += reportId
            screenshots += screenshot
            return if (outcomes.size > 1) outcomes.removeAt(0) else outcomes.first()
        }

        val screenshots = mutableListOf<ByteArray?>()

        override suspend fun fetchRemoteConfig(): CollieRemoteConfig? = null
    }

    private class HangingTransport : ReportTransport {
        override suspend fun upload(
            reportId: String,
            envelope: ByteArray,
            screenshot: ByteArray?,
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
        val outcome = queue(transport).submit(body, byteArrayOf(1, 2, 3))

        assertEquals(CollieSubmitOutcome.Sent("server-1"), outcome)
        assertEquals(1, transport.uploads)
        assertEquals(3, transport.screenshots.first()?.size)
    }

    @Test
    fun `submit without a screenshot still uploads`() = runTest {
        val transport = FakeTransport(mutableListOf(CollieOperationResult.Success("server-1")))
        val outcome = queue(transport).submit(body, null)

        assertEquals(CollieSubmitOutcome.Sent("server-1"), outcome)
        assertEquals(null, transport.screenshots.first())
    }

    @Test
    fun `a permanent failure is rejected and never queued`() = runTest {
        val transport = FakeTransport(mutableListOf(CollieOperationResult.PermanentFailure("401")))
        val queue = queue(transport)

        val outcome = queue.submit(body, null)

        assertTrue(outcome is CollieSubmitOutcome.Rejected)
        assertEquals(0, queue.pendingCount())
    }

    @Test
    fun `a transient failure queues the report`() = runTest {
        val transport = FakeTransport(mutableListOf(CollieOperationResult.TransientFailure("offline")))
        val queue = queue(transport)

        assertEquals(CollieSubmitOutcome.Queued, queue.submit(body, null))
        assertEquals(1, queue.pendingCount())
    }

    @Test
    fun `an upload that exceeds the request timeout is queued`() = runTest {
        val queue = queue(HangingTransport())

        assertEquals(CollieSubmitOutcome.Queued, queue.submit(body, null))
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
        queue.submit(body, null)

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
        queue.submit(body, null)

        queue.drain()

        assertEquals(0, queue.pendingCount())
    }

    @Test
    fun `a report is dropped once it exceeds the retry limit`() = runTest {
        val transport = FakeTransport(mutableListOf(CollieOperationResult.TransientFailure("offline")))
        val queue = queue(transport)
        queue.submit(body, null)

        // maxRetryCount = 2 → the third drain is the one that gives up.
        repeat(3) { queue.drain() }

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
        queue.submit(body, null)
        queue.drain()

        // A response lost in transit must resolve to the SAME report, not a second one.
        assertEquals(2, transport.reportIds.size)
        assertEquals(transport.reportIds[0], transport.reportIds[1])
    }

    @Test
    fun `distinct reports get distinct idempotency keys`() = runTest {
        val transport = FakeTransport(mutableListOf(CollieOperationResult.Success("server-1")))
        val queue = queue(transport)

        queue.submit(body, null)
        queue.submit(body, null)

        assertNotEquals(transport.reportIds[0], transport.reportIds[1])
    }

    // MARK: - Persistence

    @Test
    fun `the queue resumes from disk after a restart`() = runTest {
        val directory = folder.newFolder()
        val failing = FakeTransport(mutableListOf(CollieOperationResult.TransientFailure("offline")))
        UploadQueue(configuration, failing, directory).submit(body, byteArrayOf(9))

        // A brand-new queue over the same directory — as after a process restart.
        val succeeding = FakeTransport(mutableListOf(CollieOperationResult.Success("server-1")))
        val restarted = UploadQueue(configuration, succeeding, directory)
        assertEquals(1, restarted.pendingCount())

        restarted.drain()

        assertEquals(0, restarted.pendingCount())
        // The screenshot came back off disk with the report it belongs to.
        assertEquals(1, succeeding.screenshots.first()?.size)
    }
}

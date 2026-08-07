package com.collie.firebase

import com.google.android.gms.tasks.TaskCompletionSource
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertNull
import org.junit.Test

class TaskAwaitTest {

    @Test
    fun `a pending Firestore task cooperates with the upload timeout`() = runTest {
        val pendingTask = TaskCompletionSource<String>().task

        val result = withTimeoutOrNull(1_000) { pendingTask.await() }

        assertNull(result)
    }
}

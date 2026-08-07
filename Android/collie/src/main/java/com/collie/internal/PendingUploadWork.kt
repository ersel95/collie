package com.collie.internal

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.collie.Collie
import java.util.concurrent.TimeUnit

/** Enqueues one durable upload job for all reports currently waiting on disk. */
internal class PendingUploadScheduler(
    private val context: Context,
    private val diagnostics: (String) -> Unit,
) {

    fun schedule() {
        runCatching {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()
            val request = OneTimeWorkRequestBuilder<PendingUploadWorker>()
                .setConstraints(constraints)
                .setBackoffCriteria(
                    BackoffPolicy.LINEAR,
                    BACKOFF_MINUTES,
                    TimeUnit.MINUTES,
                )
                .addTag(WORK_NAME)
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(
                WORK_NAME,
                ExistingWorkPolicy.KEEP,
                request,
            )
        }.onFailure { error ->
            diagnostics(
                "Could not schedule pending report upload: " +
                    (error.message ?: error::class.java.simpleName),
            )
        }
    }

    internal companion object {
        internal const val WORK_NAME: String = "collie-pending-report-upload"
        private const val BACKOFF_MINUTES: Long = 15
    }
}

/**
 * Restarts the host process when necessary and drains Collie's disk queue in the background.
 *
 * The host must configure Collie from `Application.onCreate()`. Android creates the application
 * before invoking this worker, which reconstructs the host-selected transport (including
 * Firestore) before the queued report is read.
 */
internal class PendingUploadWorker(
    appContext: Context,
    workerParameters: WorkerParameters,
) : CoroutineWorker(appContext, workerParameters) {

    override suspend fun doWork(): Result {
        val service = Collie.bugReportService ?: return Result.retry()
        return if (service.retryPendingUploadsInBackground()) {
            Result.success()
        } else {
            Result.retry()
        }
    }
}

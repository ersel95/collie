package com.collie

/**
 * When one of a report's screenshots arrived, and where it came from.
 *
 * A report can carry several images taken minutes apart: the tester shakes, then walks back
 * through the app taking one more on each screen that matters. Without this, the analyst sees
 * a row of pictures with no idea which screen came first or when, while the log stream beside
 * them is timestamped to the second.
 *
 * So every image leaves a `collie` marker in the stream at the moment it was taken —
 * [markerEntries] builds them, and [BugReportService] merges them in at their chronological
 * positions like every other Collie marker. Reading the report becomes "screenshot 2 was taken
 * right here, after this request failed".
 *
 * Must stay in step with the iOS SDK's `CollieScreenshotEvent`: one panel reads both.
 */
public data class CollieScreenshotEvent(
    /** When the image was captured (or, for a gallery image, attached). */
    public val epochMillis: Long,
    public val source: Source,
) {
    /**
     * How the image got into the report. The distinction is worth keeping: a capture is
     * evidence of what the app was doing at that instant, while a gallery image was taken at
     * some earlier, unknown time and only *attached* now.
     */
    public enum class Source(internal val wireName: String) {
        /** Rendered from the running app — at shake time, or in screenshot mode. */
        CAPTURED("captured"),

        /** Picked from the device's gallery. */
        GALLERY("library"),
    }

    public companion object {
        /**
         * One `collie` log entry per image, numbered the way the panel numbers them.
         *
         * The number is the image's **position in the report as sent**, not the order it was
         * taken in: the tester can delete the second of three pictures, and a marker still
         * pointing at "screenshot 2" would then name the wrong one. Deleted images produce no
         * marker at all, because their event never reaches this function.
         */
        public fun markerEntries(events: List<CollieScreenshotEvent>): List<CollieLogEntry> =
            events.mapIndexed { index, event ->
                val number = index + 1
                CollieLogEntry(
                    epochMillis = event.epochMillis,
                    level = "info",
                    category = "collie",
                    message = if (event.source == Source.CAPTURED) {
                        "Screenshot $number captured"
                    } else {
                        "Screenshot $number attached from the photo library"
                    },
                    metadata = mapOf(
                        "screenshot" to number.toString(),
                        "source" to event.source.wireName,
                    ),
                )
            }
    }
}

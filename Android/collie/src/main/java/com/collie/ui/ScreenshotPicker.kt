package com.collie.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Turns the URIs the system photo picker hands back into bitmaps the report form can hold.
 *
 * **The picker itself needs no permission**, which is why the form uses it. Android's photo
 * picker (`ActivityResultContracts.PickVisualMedia`) runs outside the app and grants read
 * access only to the items the tester chose — `READ_MEDIA_IMAGES` is never required, so
 * Collie declares no storage permission in its manifest and raises no prompt. That is not a
 * convenience: the library's manifest merges into the host's, and a bug reporter that asks
 * for the photo library teaches testers to decline.
 */
internal object ScreenshotPicker {

    /**
     * Decodes one picked image, or `null` when it cannot be read — a URI whose grant has
     * already lapsed, or a file the decoder does not understand. The caller keeps the rest
     * of the selection either way.
     *
     * Decoded as a **software** bitmap on purpose: a hardware one cannot be drawn into the
     * markup editor's canvas, so the tester could attach an image and then not mark it up.
     */
    suspend fun load(context: Context, uri: Uri): Bitmap? = withContext(Dispatchers.IO) {
        runCatching {
            val source = ImageDecoder.createSource(context.contentResolver, uri)
            ImageDecoder.decodeBitmap(source) { decoder, _, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.isMutableRequired = false
            }
        }.getOrNull()
    }
}

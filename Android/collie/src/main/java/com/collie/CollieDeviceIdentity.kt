package com.collie

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.provider.Settings
import java.util.Locale
import java.util.UUID

/**
 * Identity of the device/person sending the report.
 *
 * - **id**: a persistent per-device identifier. `Settings.Secure.ANDROID_ID` — stable for
 *   the app across reinstalls (it is scoped per signing key + user since Android 8) and,
 *   unlike an advertising id, not a tracking identifier. When it is unavailable a random
 *   UUID is generated and kept in Collie's own preferences.
 * - **name**: the name entered **once** in the report sheet, stored afterwards and not
 *   asked again.
 * - Model / OS version / locale / screen are collected automatically with each report.
 *
 * Contains no real service names / secrets; fully generic.
 */
public data class CollieDeviceIdentity(
    public val id: String,
    public val name: String?,
    public val model: String,
    public val osVersion: String,
    public val locale: String,
    public val screen: String,
    public val bundleId: String,
    public val appVersion: String,
    public val appBuild: String,
) {
    public companion object {

        /** Collects the current identity (persistent id + stored name + device/app meta). */
        public fun current(context: Context): CollieDeviceIdentity {
            val app = context.applicationContext
            return CollieDeviceIdentity(
                id = persistentDeviceId(app),
                name = storedName(app),
                model = deviceModel(),
                osVersion = Build.VERSION.RELEASE ?: Build.VERSION.SDK_INT.toString(),
                locale = localeIdentifier(),
                screen = screenSize(app),
                bundleId = app.packageName,
                appVersion = packageInfo(app)?.versionName ?: "0",
                appBuild = packageInfo(app)?.let { info ->
                    @Suppress("DEPRECATION")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        info.longVersionCode.toString()
                    } else {
                        info.versionCode.toString()
                    }
                } ?: "0",
            )
        }

        /** Is a tester name stored? (Determines whether the sheet asks for a name on first use.) */
        public fun hasStoredName(context: Context): Boolean = !storedName(context).isNullOrEmpty()

        /**
         * Stores the one-time tester name. Empty/whitespace input is ignored.
         *
         * Android has no Keychain equivalent that survives an uninstall, so this lives in
         * Collie's own preferences: a reinstall asks for the name once more. That is a
         * strictly better trade than a hardware identifier the tester never consented to.
         */
        public fun storeName(context: Context, name: String) {
            val trimmed = name.trim()
            if (trimmed.isEmpty()) return
            preferences(context).edit().putString(KEY_TESTER_NAME, trimmed).apply()
        }

        internal fun storedName(context: Context): String? =
            preferences(context).getString(KEY_TESTER_NAME, null)?.trim()?.takeIf { it.isNotEmpty() }

        // MARK: - Persistent device id (ANDROID_ID → generated UUID)

        @SuppressLint("HardwareIds")
        private fun persistentDeviceId(context: Context): String {
            preferences(context).getString(KEY_DEVICE_ID, null)
                ?.takeIf { it.isNotBlank() }
                ?.let { return it }

            val androidId = runCatching {
                Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
            }.getOrNull()

            val generated = androidId?.takeIf { it.isNotBlank() } ?: UUID.randomUUID().toString()
            preferences(context).edit().putString(KEY_DEVICE_ID, generated).apply()
            return generated
        }

        // MARK: - Device meta

        /**
         * Android has no equivalent of Apple's `utsname.machine` → marketing-name table:
         * `Build.MODEL` already *is* the marketing name on most devices ("Pixel 9 Pro"),
         * and where it is not (Samsung's "SM-S928B") no table could keep up. The
         * manufacturer is prefixed when the model does not already start with it.
         */
        private fun deviceModel(): String {
            val manufacturer = Build.MANUFACTURER.orEmpty().trim()
            val model = Build.MODEL.orEmpty().trim()
            if (model.isEmpty()) return manufacturer.ifEmpty { "unknown" }
            if (manufacturer.isEmpty()) return model
            return if (model.startsWith(manufacturer, ignoreCase = true)) {
                model
            } else {
                "$manufacturer $model"
            }
        }

        /** `en_US`, matching the `Locale.current.identifier` the iOS SDK sends. */
        private fun localeIdentifier(): String {
            val locale = Locale.getDefault()
            return if (locale.country.isNullOrEmpty()) locale.language else "${locale.language}_${locale.country}"
        }

        /** Physical pixels, like iOS's `UIScreen.nativeBounds`. */
        private fun screenSize(context: Context): String {
            val metrics = context.resources.displayMetrics
            return "${metrics.widthPixels}x${metrics.heightPixels}"
        }

        private fun packageInfo(context: Context) = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0)
        }.getOrNull()

        // MARK: - Keys

        private const val PREFERENCES_NAME = "com.collie.bugreporter"
        private const val KEY_TESTER_NAME = "com.collie.testerName"
        private const val KEY_DEVICE_ID = "com.collie.deviceID"

        private fun preferences(context: Context): SharedPreferences =
            context.applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
    }
}

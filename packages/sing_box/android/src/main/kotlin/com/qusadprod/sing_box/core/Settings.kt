package com.qusadprod.sing_box.core

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Android options of `initialize` (contract: `android` map). */
internal data class NotificationOptions(
    val channelId: String = DEFAULT_CHANNEL_ID,
    val channelName: String = DEFAULT_CHANNEL_NAME,
    val title: String? = null,
    val content: String = DEFAULT_CONTENT,
    val icon: String? = null,
    val showTraffic: Boolean = true,
    val showStopAction: Boolean = true,
    val stopActionTitle: String = DEFAULT_STOP_TITLE,
    val sessionName: String? = null,
) {
    companion object {
        const val DEFAULT_CHANNEL_ID = "sing_box_vpn"
        const val DEFAULT_CHANNEL_NAME = "VPN"
        const val DEFAULT_CONTENT = "Connected"
        const val DEFAULT_STOP_TITLE = "Stop"

        /** Parses the `android` map; unknown keys and wrongly typed values are ignored. */
        fun fromMap(map: Map<*, *>?): NotificationOptions {
            if (map == null) return NotificationOptions()
            fun string(key: String): String? = (map[key] as? String)?.takeIf { it.isNotBlank() }
            fun bool(key: String, default: Boolean): Boolean = map[key] as? Boolean ?: default
            return NotificationOptions(
                channelId = string("notificationChannelId") ?: DEFAULT_CHANNEL_ID,
                channelName = string("notificationChannelName") ?: DEFAULT_CHANNEL_NAME,
                title = string("notificationTitle"),
                content = string("notificationContent") ?: DEFAULT_CONTENT,
                icon = string("notificationIcon"),
                showTraffic = bool("showTrafficInNotification", true),
                showStopAction = bool("showStopAction", true),
                stopActionTitle = string("stopActionTitle") ?: DEFAULT_STOP_TITLE,
                sessionName = string("sessionName"),
            )
        }
    }
}

/**
 * Persistent service settings (`SharedPreferences("sing_box_service")`). They
 * are persisted so that a service started without the Flutter engine (boot,
 * always-on VPN, Quick Settings tile) behaves like one started by the app.
 */
internal class ServiceSettings(context: Context) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    var logMaxLines: Int
        get() = prefs.getInt(KEY_LOG_MAX_LINES, DEFAULT_LOG_MAX_LINES)
        set(value) = prefs.edit().putInt(KEY_LOG_MAX_LINES, value).apply()

    var debug: Boolean
        get() = prefs.getBoolean(KEY_DEBUG, false)
        set(value) = prefs.edit().putBoolean(KEY_DEBUG, value).apply()

    var startOnBoot: Boolean
        get() = prefs.getBoolean(KEY_START_ON_BOOT, false)
        set(value) = prefs.edit().putBoolean(KEY_START_ON_BOOT, value).apply()

    var quickSettingsTile: Boolean
        get() = prefs.getBoolean(KEY_QS_TILE, false)
        set(value) = prefs.edit().putBoolean(KEY_QS_TILE, value).apply()

    var tileLabel: String?
        get() = prefs.getString(KEY_TILE_LABEL, null)
        set(value) = prefs.edit().putString(KEY_TILE_LABEL, value).apply()

    /** True while the user wants the VPN to run (set on start, cleared on user stop). */
    var wasRunning: Boolean
        get() = prefs.getBoolean(KEY_WAS_RUNNING, false)
        set(value) {
            // commit(): must survive the process being killed right after a start/stop.
            prefs.edit().putBoolean(KEY_WAS_RUNNING, value).commit()
        }

    var disableMemoryLimit: Boolean
        get() = prefs.getBoolean(KEY_DISABLE_MEMORY_LIMIT, false)
        set(value) = prefs.edit().putBoolean(KEY_DISABLE_MEMORY_LIMIT, value).apply()

    var notificationOptions: NotificationOptions
        get() = NotificationOptions(
            channelId = prefs.getString(KEY_N_CHANNEL_ID, null) ?: NotificationOptions.DEFAULT_CHANNEL_ID,
            channelName = prefs.getString(KEY_N_CHANNEL_NAME, null) ?: NotificationOptions.DEFAULT_CHANNEL_NAME,
            title = prefs.getString(KEY_N_TITLE, null),
            content = prefs.getString(KEY_N_CONTENT, null) ?: NotificationOptions.DEFAULT_CONTENT,
            icon = prefs.getString(KEY_N_ICON, null),
            showTraffic = prefs.getBoolean(KEY_N_SHOW_TRAFFIC, true),
            showStopAction = prefs.getBoolean(KEY_N_SHOW_STOP, true),
            stopActionTitle = prefs.getString(KEY_N_STOP_TITLE, null) ?: NotificationOptions.DEFAULT_STOP_TITLE,
            sessionName = prefs.getString(KEY_N_SESSION, null),
        )
        set(value) {
            prefs.edit()
                .putString(KEY_N_CHANNEL_ID, value.channelId)
                .putString(KEY_N_CHANNEL_NAME, value.channelName)
                .putString(KEY_N_TITLE, value.title)
                .putString(KEY_N_CONTENT, value.content)
                .putString(KEY_N_ICON, value.icon)
                .putBoolean(KEY_N_SHOW_TRAFFIC, value.showTraffic)
                .putBoolean(KEY_N_SHOW_STOP, value.showStopAction)
                .putString(KEY_N_STOP_TITLE, value.stopActionTitle)
                .putString(KEY_N_SESSION, value.sessionName)
                .apply()
        }

    companion object {
        const val PREFS_NAME = "sing_box_service"
        const val DEFAULT_LOG_MAX_LINES = 3000

        private const val KEY_LOG_MAX_LINES = "logMaxLines"
        private const val KEY_DEBUG = "debug"
        private const val KEY_START_ON_BOOT = "startOnBoot"
        private const val KEY_QS_TILE = "quickSettingsTile"
        private const val KEY_TILE_LABEL = "tileLabel"
        private const val KEY_WAS_RUNNING = "wasRunning"
        private const val KEY_DISABLE_MEMORY_LIMIT = "disableMemoryLimit"
        private const val KEY_N_CHANNEL_ID = "notification.channelId"
        private const val KEY_N_CHANNEL_NAME = "notification.channelName"
        private const val KEY_N_TITLE = "notification.title"
        private const val KEY_N_CONTENT = "notification.content"
        private const val KEY_N_ICON = "notification.icon"
        private const val KEY_N_SHOW_TRAFFIC = "notification.showTraffic"
        private const val KEY_N_SHOW_STOP = "notification.showStopAction"
        private const val KEY_N_STOP_TITLE = "notification.stopActionTitle"
        private const val KEY_N_SESSION = "notification.sessionName"
    }
}

/** File locations of the contract table "Files and directories". */
internal object Paths {
    fun baseDir(context: Context): File = context.applicationContext.filesDir

    fun workingDir(context: Context): File = File(baseDir(context), "sing-box")

    fun tempDir(context: Context): File = context.applicationContext.cacheDir

    fun lastConfigFile(context: Context): File = File(workingDir(context), "last_config.json")

    fun readLastConfig(context: Context): String? {
        val file = lastConfigFile(context)
        if (!file.isFile) return null
        val stored = file.readText().takeIf { it.isNotBlank() } ?: return null
        val config = SecureLocalCipher.decryptOrMigrate(stored)
        if (!stored.startsWith(SecureLocalCipher.PREFIX)) {
            writeLastConfig(context, config)
        }
        return config
    }

    fun writeLastConfig(context: Context, config: String) {
        val file = lastConfigFile(context)
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, "${file.name}.tmp")
        tmp.writeText(SecureLocalCipher.encrypt(config))
        if (!tmp.renameTo(file)) {
            file.writeText(SecureLocalCipher.encrypt(config))
            tmp.delete()
        }
    }
}

/** Keystore-encrypted key/value storage of the contract. */
internal class KeyValueStorage(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("sing_box", Context.MODE_PRIVATE)

    fun read(key: String): String? {
        val stored = prefs.getString(key, null) ?: return null
        val value = SecureLocalCipher.decryptOrMigrate(stored)
        if (!stored.startsWith(SecureLocalCipher.PREFIX)) write(key, value)
        return value
    }

    fun write(key: String, value: String?) {
        val editor = prefs.edit()
        if (value == null) editor.remove(key)
        else editor.putString(key, SecureLocalCipher.encrypt(value))
        editor.apply()
    }
}

/** AES-GCM encryption with a non-exportable Android Keystore key. */
private object SecureLocalCipher {
    const val PREFIX = "HGSEC1:"
    private const val KEY_ALIAS = "hourglass.singbox.storage.v1"
    private const val IV_LENGTH = 12

    fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val payload = cipher.iv + encrypted
        return PREFIX + Base64.encodeToString(payload, Base64.NO_WRAP)
    }

    fun decryptOrMigrate(value: String): String {
        if (!value.startsWith(PREFIX)) return value
        val payload = Base64.decode(value.removePrefix(PREFIX), Base64.NO_WRAP)
        require(payload.size > IV_LENGTH) { "Encrypted local data is invalid" }
        val iv = payload.copyOfRange(0, IV_LENGTH)
        val encrypted = payload.copyOfRange(IV_LENGTH, payload.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(encrypted), Charsets.UTF_8)
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }
}

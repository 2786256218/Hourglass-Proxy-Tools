package com.nebula.hourglass

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.io.ByteArrayOutputStream
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private val secureStorageChannel = "hourglass.secure_storage"
    private val installedAppsChannel = "hourglass.installed_apps"
    private val localFilesChannel = "hourglass.local_files"
    private val externalLinksChannel = "hourglass.external_links"
    private var pendingFilePickerResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, secureStorageChannel)
            .setMethodCallHandler { call, result ->
                try {
                    val key = call.argument<String>("key")
                        ?: throw IllegalArgumentException("Missing secure storage key")
                    val prefs = getSharedPreferences("hourglass_secure", Context.MODE_PRIVATE)
                    when (call.method) {
                        "read" -> {
                            val stored = prefs.getString(key, null)
                            if (stored == null) {
                                result.success(null)
                            } else if (stored.startsWith(ENCRYPTED_PREFIX)) {
                                result.success(decrypt(stored))
                            } else {
                                // Upgrade data written by older app builds on first access.
                                prefs.edit().putString(key, encrypt(stored)).commit()
                                result.success(stored)
                            }
                        }
                        "write" -> {
                            val value = call.argument<String>("value")
                                ?: throw IllegalArgumentException("Missing secure storage value")
                            val saved = prefs.edit().putString(key, encrypt(value)).commit()
                            if (saved) result.success(null)
                            else result.error("secure_storage", "Could not persist protected data", null)
                        }
                        "delete" -> {
                            prefs.edit().remove(key).commit()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    // Never include stored values or cipher details in platform logs/errors.
                    result.error("secure_storage", "Protected storage is unavailable", null)
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installedAppsChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "listInstalledApps") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val apps = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        packageManager.getInstalledApplications(
                            PackageManager.ApplicationInfoFlags.of(0),
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        packageManager.getInstalledApplications(0)
                    }
                    result.success(
                        apps.map { info ->
                            mapOf(
                                "packageName" to info.packageName,
                                "label" to packageManager.getApplicationLabel(info).toString(),
                            )
                        }.sortedWith(
                            compareBy<Map<String, String>, String>(String.CASE_INSENSITIVE_ORDER) { it["label"] ?: "" }
                                .thenBy { it["packageName"] ?: "" },
                        ),
                    )
                } catch (_: Exception) {
                    result.error("installed_apps", "无法读取已安装应用列表", null)
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, localFilesChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "pickYamlFile") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (pendingFilePickerResult != null) {
                    result.error("picker_busy", "文件选择器正在使用", null)
                    return@setMethodCallHandler
                }
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                }
                pendingFilePickerResult = result
                try {
                    startActivityForResult(intent, REQUEST_YAML_FILE)
                } catch (_: Exception) {
                    pendingFilePickerResult = null
                    result.error("file_picker", "无法打开系统文件选择器", null)
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, externalLinksChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "openUrl") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val uri = Uri.parse(call.argument<String>("url") ?: "")
                    if (uri.scheme != "https" || uri.host.isNullOrBlank()) {
                        result.error("invalid_url", "仅允许打开 HTTPS 仓库地址", null)
                        return@setMethodCallHandler
                    }
                    startActivity(Intent(Intent.ACTION_VIEW, uri))
                    result.success(true)
                } catch (_: Exception) {
                    result.error("open_url", "无法打开仓库链接", null)
                }
            }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_YAML_FILE) return
        val callback = pendingFilePickerResult ?: return
        pendingFilePickerResult = null
        if (resultCode != RESULT_OK || data?.data == null) {
            callback.success(null)
            return
        }
        try {
            val uri = data.data!!
            val name = contentResolver.query(uri, null, null, null, null)?.use { cursor: Cursor ->
                val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (column >= 0 && cursor.moveToFirst()) cursor.getString(column) else null
            } ?: uri.lastPathSegment ?: "config.yaml"
            val extension = name.substringAfterLast('.', "").lowercase()
            if (extension !in setOf("yaml", "yml", "yam")) {
                callback.error("unsupported_file", "请选择 .yaml、.yml 或 .yam 文件", null)
                return
            }
            val output = ByteArrayOutputStream()
            contentResolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArray(8192)
                var total = 0
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > MAX_YAML_BYTES) {
                        callback.error("file_too_large", "配置文件不能超过 16 MB", null)
                        return
                    }
                    output.write(buffer, 0, count)
                }
            } ?: throw IllegalStateException("文件内容无法读取")
            val content = output.toByteArray().toString(Charsets.UTF_8).removePrefix("\uFEFF")
            callback.success(mapOf("name" to name, "content" to content))
        } catch (_: Exception) {
            callback.error("file_read", "读取配置文件失败", null)
        }
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, storageKey())
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return ENCRYPTED_PREFIX + Base64.encodeToString(cipher.iv + encrypted, Base64.NO_WRAP)
    }

    private fun decrypt(value: String): String {
        val payload = Base64.decode(value.removePrefix(ENCRYPTED_PREFIX), Base64.NO_WRAP)
        require(payload.size > GCM_IV_LENGTH)
        val iv = payload.copyOfRange(0, GCM_IV_LENGTH)
        val encrypted = payload.copyOfRange(GCM_IV_LENGTH, payload.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, storageKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(encrypted), Charsets.UTF_8)
    }

    private fun storageKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
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

    private companion object {
        const val REQUEST_YAML_FILE = 8321
        const val MAX_YAML_BYTES = 16 * 1024 * 1024
        const val ENCRYPTED_PREFIX = "HGUSER1:"
        const val KEY_ALIAS = "hourglass.user.secrets.v1"
        const val GCM_IV_LENGTH = 12
    }
}

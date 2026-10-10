package com.anxcye.anx_reader

import android.content.pm.PackageManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.documentfile.provider.DocumentFile
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {

    private var pendingPickResult: MethodChannel.Result? = null

    // automation hook: `am start ... --es auto_tts_path <file>` makes the app
    // import the book and start narrating without UI interaction
    private var pendingAutoTtsPath: String? = null
    private var pendingAutoImportFolder: String? = null
    private val pendingAutoExtras = mutableMapOf<String, String>()

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        pendingAutoTtsPath = intent?.getStringExtra("auto_tts_path")
        pendingAutoImportFolder = intent?.getStringExtra("auto_import_folder")
        for (key in listOf("auto_tts_force_timeout", "auto_import_saf", "auto_tts_service")) {
            intent?.getStringExtra(key)?.let { pendingAutoExtras[key] = it }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Ensure the latest intent is stored so plugins relying on Activity#getIntent can read it.
        setIntent(intent)
        intent.getStringExtra("auto_tts_path")?.let { pendingAutoTtsPath = it }
        intent.getStringExtra("auto_import_folder")?.let { pendingAutoImportFolder = it }
        for (key in listOf("auto_tts_force_timeout", "auto_import_saf", "auto_tts_service")) {
            intent.getStringExtra(key)?.let { pendingAutoExtras[key] = it }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_PICK_DIR) {
            val uri = data?.data
            if (uri != null && resultCode == RESULT_OK) {
                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                } catch (_: SecurityException) {
                    // non-persistable grants still work for this session
                }
                pendingPickResult?.success(uri.toString())
            } else {
                pendingPickResult?.success(null)
            }
            pendingPickResult = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INSTALL_INFO_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstallInfo" -> {
                    try {
                        val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            packageManager.getPackageInfo(
                                packageName,
                                PackageManager.PackageInfoFlags.of(0),
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            packageManager.getPackageInfo(packageName, 0)
                        }
                        result.success(
                            hashMapOf(
                                "firstInstallTime" to packageInfo.firstInstallTime,
                                "lastUpdateTime" to packageInfo.lastUpdateTime,
                            ),
                        )
                    } catch (e: Exception) {
                        result.error("PACKAGE_INFO_ERROR", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        // Import foreground service bridge: keeps folder imports running
        // (with a progress notification + wake lock) while the app is in
        // the background.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            IMPORT_SERVICE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    ImportForegroundService.start(
                        this,
                        call.argument<String>("name") ?: "",
                        call.argument<Int>("total") ?: 0,
                    )
                    result.success(null)
                }
                "update" -> {
                    ImportForegroundService.updateLive(
                        this,
                        call.argument<String>("name") ?: "",
                        call.argument<Int>("imported") ?: 0,
                        call.argument<Int>("total") ?: 0,
                    )
                    result.success(null)
                }
                "stop" -> {
                    ImportForegroundService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // SAF tree access: Android folder pickers return content:// tree
        // URIs that dart:io cannot read, so enumerate and copy natively.
        // Handler runs on a BACKGROUND task queue thread at background
        // priority: enumerate/copy/MD5 of a 630-book import used to run on
        // the Android main thread itself (jank and ANR during imports).
        val safTaskQueue = flutterEngine.dartExecutor.makeBackgroundTaskQueue()
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SAF_TREE_CHANNEL,
            io.flutter.plugin.common.StandardMethodCodec.INSTANCE,
            safTaskQueue
        ).setMethodCallHandler { call, result ->
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            when (call.method) {
                "pickDirectory" -> {
                    // file_picker's getDirectoryPath converts the SAF tree
                    // uri into a plain path that scoped storage forbids us
                    // from listing, so expose the raw tree uri instead
                    runOnUiThread {
                        pendingPickResult = result
                        try {
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                            intent.addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                            )
                            startActivityForResult(intent, REQUEST_PICK_DIR)
                        } catch (e: Exception) {
                            pendingPickResult = null
                            result.error("PICK_DIR_ERROR", e.message, null)
                        }
                    }
                }

                "listBookFiles" -> {
                    try {
                        val treeUri = Uri.parse(call.argument<String>("treeUri"))
                        // With all-files access, enumerate through the plain
                        // file api: SAF uri grants are separate from
                        // MANAGE_EXTERNAL_STORAGE and ungranted trees return
                        // empty listings silently.
                        if (android.os.Environment.isExternalStorageManager()) {
                            val dir = treeUriToFile(treeUri)
                            if (dir != null && dir.exists()) {
                                val out = mutableListOf<Map<String, Any>>()
                                walkFileTree(dir, dir, out)
                                // the folder's display name is authoritative;
                                // the document id is only a fallback for
                                // volume labels ("primary", "内部存储", "0"...)
                                // — preferring the id (v1.15.24) made some
                                // third-party providers yield junk like "root"
                                val fastDocId = try {
                                    android.provider.DocumentsContract.getTreeDocumentId(treeUri)
                                } catch (e: Exception) { "" }
                                val fastDerived =
                                    fastDocId.substringAfterLast(':').substringAfterLast('/')
                                val fastName = if (isJunkRootName(dir.name, fastDocId)) {
                                    fastDerived.ifBlank { "imported" }
                                } else {
                                    dir.name ?: fastDerived.ifBlank { "imported" }
                                }
                                result.success(hashMapOf(
                                    "rootName" to fastName,
                                    "files" to out,
                                ))
                                return@setMethodCallHandler
                            }
                        }
                        val root = DocumentFile.fromTreeUri(applicationContext, treeUri)
                        if (root == null) {
                            result.error("SAF_ERROR", "cannot open tree", null)
                            return@setMethodCallHandler
                        }
                        val out = mutableListOf<Map<String, Any>>()
                        walkTree(root, out)
                        // root.name can be a volume label ("primary",
                        // "Internal storage", "内部存储") on some providers;
                        // derive the folder name from the document id instead
                        val docId = try {
                            android.provider.DocumentsContract.getTreeDocumentId(treeUri)
                        } catch (e: Exception) { "" }
                        val derived = docId.substringAfterLast(':').substringAfterLast('/')
                        val rawName = root.name
                        val rootName = if (isJunkRootName(rawName, docId)) {
                            derived.ifBlank { "imported" }
                        } else {
                            rawName!!
                        }
                        result.success(hashMapOf(
                            "rootName" to rootName,
                            "files" to out,
                        ))
                    } catch (e: Exception) {
                        result.error("SAF_ERROR", e.message, null)
                    }
                }

                // stream a SAF document straight into the app storage,
                // computing the MD5 while copying (single pass, no temp file)
                "copyToDir" -> {
                    try {
                        val uriStr = call.argument<String>("uri") ?: ""
                        val fileName = sanitizeFileName(
                            call.argument<String>("fileName") ?: "book")
                        val destDir = File(
                            call.argument<String>("destDir") ?: cacheDir.path)
                        if (!destDir.exists()) destDir.mkdirs()
                        val dest = File(destDir, fileName)
                        val digest = java.security.MessageDigest.getInstance("MD5")
                        val input: java.io.InputStream? =
                            if (!uriStr.startsWith("content:")) {
                                File(uriStr).inputStream()
                            } else {
                                contentResolver.openInputStream(Uri.parse(uriStr))
                            }
                        if (input == null) {
                            result.error("SAF_COPY_ERROR", "cannot open input stream", null)
                            return@setMethodCallHandler
                        }
                        input.use { src ->
                            dest.outputStream().use { out ->
                                val buf = ByteArray(64 * 1024)
                                while (true) {
                                    val n = src.read(buf)
                                    if (n < 0) break
                                    digest.update(buf, 0, n)
                                    out.write(buf, 0, n)
                                }
                            }
                        }
                        val md5 = digest.digest().joinToString("") {
                            "%02x".format(it)
                        }
                        result.success(hashMapOf(
                            "path" to dest.absolutePath,
                            "md5" to md5,
                            "size" to dest.length(),
                        ))
                    } catch (e: Exception) {
                        result.error("SAF_COPY_ERROR", e.message, null)
                    }
                }

                // all-files access (Android 11+) lets the app store books in
                // a user-visible folder such as /storage/emulated/0/AnxReader
                "hasAllFilesAccess" -> {
                    result.success(android.os.Environment.isExternalStorageManager())
                }

                // automation hook for adb-driven TTS tests
                "consumeAutoTtsPath" -> {
                    result.success(pendingAutoTtsPath.also { pendingAutoTtsPath = null })
                }

                "consumeAutoExtra" -> {
                    val key = call.arguments as? String ?: ""
                    val value = pendingAutoExtras.remove(key) ?: ""
                    result.success(value)
                }

                // automation hook for adb-driven folder import tests
                "consumeAutoImportFolder" -> {
                    result.success(pendingAutoImportFolder.also { pendingAutoImportFolder = null })
                }

                "requestAllFilesAccess" -> {
                    if (android.os.Environment.isExternalStorageManager()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    runOnUiThread {
                        try {
                            val intent = android.content.Intent(
                                android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                Uri.parse("package:$packageName"),
                            )
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                startActivity(android.content.Intent(
                                    android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION))
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("PERM_ERROR", e2.message, null)
                            }
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun sanitizeFileName(name: String): String =
        name.replace(Regex("[\\\\/:*?\"<>|]"), "_")

    /// Resolve a SAF tree uri of the external-storage provider into a real
    /// file path, e.g. tree/primary%3ATestBooks -> /storage/emulated/0/TestBooks
    /// True when [name] is a volume/storage label rather than a real folder
    /// name ("primary", "Internal storage", "内部存储", "0", "sdcard"...) or
    /// just echoes the document id.
    private fun isJunkRootName(name: String?, docId: String): Boolean {
        if (name.isNullOrBlank()) return true
        if (name == docId) return true
        val n = name.trim().lowercase()
        return n == "primary" || n == "internal storage" || n == "0" ||
            n == "sdcard" || n == "emulated" || name.contains("存储")
    }

    private fun treeUriToFile(uri: Uri): File? {
        if (uri.scheme != "content") return null
        val docId = try {
            android.provider.DocumentsContract.getTreeDocumentId(uri)
        } catch (e: Exception) {
            return null
        }
        val volume = docId.substringBefore(':', "")
        if (volume != "primary") return null
        val sub = docId.substringAfter(':', "")
        if (sub.isEmpty()) return null
        return File(android.os.Environment.getExternalStorageDirectory(), sub)
    }

    /// Plain-file enumeration used when all-files access is granted; the
    /// "uri" entries are real file paths.
    private fun walkFileTree(root: File, dir: File, out: MutableList<Map<String, Any>>) {
        val children = try {
            dir.listFiles()
        } catch (e: Exception) {
            null
        } ?: return
        for (f in children) {
            if (f.isDirectory) {
                walkFileTree(root, f, out)
            } else {
                val ext = f.name.substringAfterLast('.', "").lowercase()
                if (ext in bookExtensions) {
                    out.add(hashMapOf(
                        "uri" to f.absolutePath,
                        "name" to f.name,
                        "size" to f.length(),
                    ))
                }
            }
        }
    }

    private fun walkTree(dir: DocumentFile, out: MutableList<Map<String, Any>>) {
        val children = try {
            dir.listFiles()
        } catch (e: Exception) {
            emptyArray()
        }
        for (doc in children) {
            if (doc.isDirectory) {
                walkTree(doc, out)
            } else {
                val name = doc.name ?: continue
                val ext = name.substringAfterLast('.', "").lowercase()
                if (ext in bookExtensions) {
                    out.add(
                        hashMapOf(
                            "uri" to doc.uri.toString(),
                            "name" to name,
                            "size" to doc.length(),
                        )
                    )
                }
            }
        }
    }

    companion object {
        private const val INSTALL_INFO_CHANNEL = "com.anxcye.anx_reader/install_info"
        private const val IMPORT_SERVICE_CHANNEL = "com.anxcye.anx_reader/import_service"
        private const val SAF_TREE_CHANNEL = "com.anxcye.anx_reader/saf_tree"
        private const val REQUEST_PICK_DIR = 4711
        private val bookExtensions = setOf("epub", "mobi", "azw3", "fb2", "txt", "pdf")
    }
}

package com.qingling.app

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.Cursor
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.security.MessageDigest
import android.media.MediaScannerConnection
import android.os.Bundle
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.util.Log
import android.net.Uri
import java.net.URL
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingDeletePaths: List<String> = emptyList()
    // MediaStore 删除请求被用户取消时，直接删除的部分已删，需如实返回
    private var pendingDirectDeleted: List<String> = emptyList()
    private val deleteRequestCode = 1001
    // 文件系统直扫认的音频扩展名（与 Dart 层 audioExts 保持一致）
    private val fsAudioExts = setOf(
        "mp3", "flac", "wav", "m4a", "aac", "ogg", "wma", "opus", "aiff", "mp2"
    )
    private var debugChannel: MethodChannel? = null
    private var updateChannel: MethodChannel? = null
    @Volatile private var downloadCancelled = false
    private val debugReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                "com.qingling.app.DEBUG_SCAN" -> {
                    Log.d("song_dedup", "DEBUG_SCAN received, channel=${if (debugChannel == null) "null" else "ok"}")
                    debugChannel?.invokeMethod("startScan", null)
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureAudioPermission()
    }

    /// 申请音频读取运行时权限。没有它，MediaStore content URI 和直接文件
    /// 路径都打不开（appops 授权不够）。用户点一次"允许"即可。
    private fun ensureAudioPermission() {
        val perm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
        if (checkSelfPermission(perm) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(perm), 1002)
        }
    }

    /// 调系统安装器安装指定 APK（更新用）。FileProvider 授临时读权限，
    /// 首次安装系统会让用户确认允许「安装未知应用」。
    private fun installApk(path: String): Boolean {
        return try {
            val file = File(path)
            if (!file.exists()) return false
            val uri = FileProvider.getUriForFile(
                this, "${applicationContext.packageName}.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w("song_dedup", "installApk failed: ${e.message}")
            false
        }
    }

    /// 原生 HTTP GET（走 HttpURLConnection，用 Android 系统解析，能感知 VPN/Clash。
    /// Dart 的 HttpClient 走 Bionic getaddrinfo，手机系统 DNS 为空时解析不到
    /// github 域名，检查更新会报 Failed host lookup；原生这条路不受影响）。
    /// [followRedirects] 为 false 时不跟随重定向，返回 Location 供上层取 tag。
    /// 返回 map：status（Int）、location（String?）、body（String?）。
    /// 网络异常时 result.error("HTTP_ERROR", "异常类名: 信息", null)。
    private fun httpGet(url: String, followRedirects: Boolean, result: MethodChannel.Result) {
        Thread {
            try {
                val conn = URL(url).openConnection() as java.net.HttpURLConnection
                conn.instanceFollowRedirects = followRedirects
                conn.connectTimeout = 10000
                conn.readTimeout = 10000
                conn.setRequestProperty("User-Agent", "QingLing")
                conn.setRequestProperty("Accept", "application/vnd.github+json")
                conn.requestMethod = "GET"
                val status = conn.responseCode
                val location = conn.getHeaderField("Location")
                val stream = if (status in 200..299) conn.inputStream else conn.errorStream
                val body = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }
                conn.disconnect()
                val out = HashMap<String, Any?>()
                out["status"] = status
                out["location"] = location
                out["body"] = body
                result.success(out)
            } catch (e: Exception) {
                result.error("HTTP_ERROR", "${e.javaClass.simpleName}: ${e.message}", null)
            }
        }.start()
    }

    /// 原生下载文件（走 HttpURLConnection，跟随重定向）。
    /// 进度经 updateChannel 回推 Dart（downloadProgress：received/total 字节，
    /// total 为 -1 表示未知）；取消由 cancelDownload 置标志位，中断后删残文件。
    /// 成功返回 destPath，失败 result.error。
    private fun downloadFile(url: String, destPath: String, result: MethodChannel.Result) {
        Thread {
            try {
                val conn = URL(url).openConnection() as java.net.HttpURLConnection
                conn.instanceFollowRedirects = true
                conn.connectTimeout = 10000
                conn.readTimeout = 30000
                conn.setRequestProperty("User-Agent", "QingLing")
                conn.requestMethod = "GET"
                val status = conn.responseCode
                if (status != 200) {
                    conn.disconnect()
                    result.error("HTTP_ERROR", "下载失败：HTTP $status", null)
                    return@Thread
                }
                val total = conn.contentLengthLong
                val outFile = File(destPath)
                var received = 0L
                conn.inputStream.use { input ->
                    outFile.outputStream().use { output ->
                        val buf = ByteArray(8192)
                        var n: Int
                        while (input.read(buf).also { n = it } != -1) {
                            if (downloadCancelled) {
                                output.close()
                                outFile.delete()
                                conn.disconnect()
                                result.error("CANCELLED", "已取消", null)
                                return@Thread
                            }
                            output.write(buf, 0, n)
                            received += n
                            updateChannel?.invokeMethod(
                                "downloadProgress",
                                mapOf("received" to received, "total" to total),
                            )
                        }
                    }
                }
                conn.disconnect()
                result.success(destPath)
            } catch (e: Exception) {
                result.error("HTTP_ERROR", "${e.javaClass.simpleName}: ${e.message}", null)
            }
        }.start()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Debug channel: automation can trigger a scan with
        // `adb shell am broadcast -a com.qingling.app.DEBUG_SCAN`
        debugChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "song_dedup/debug")
        val debugFilter = IntentFilter().apply {
            addAction("com.qingling.app.DEBUG_SCAN")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(debugReceiver, debugFilter, Context.RECEIVER_EXPORTED) // debug receiver for adb testing; must be exported to receive shell broadcasts
        } else {
            registerReceiver(debugReceiver, debugFilter)
        }

        // Scanner channel（存引用，供后台扫描线程上报进度）
        val scannerChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "song_dedup/scanner")
        scannerChannel
            .setMethodCallHandler { call, result ->
                if (call.method == "querySongs") {
                    querySongs(result)
                } else if (call.method == "querySongsFromFs") {
                    @Suppress("UNCHECKED_CAST")
                    val dirs = (call.argument<List<String>>("dirs") ?: emptyList())
                    @Suppress("UNCHECKED_CAST")
                    val cached = (call.argument<Map<String, List<Int>>>("cached")
                        ?: emptyMap())
                    val expectedTotal =
                        (call.argument<Int>("expectedTotal") ?: 0)
                    querySongsFromFs(dirs, cached, expectedTotal, scannerChannel, result)
                } else if (call.method == "audioDetails") {
                    val id = call.argument<Number>("id")?.toLong() ?: 0L
                    val path = call.argument<String>("path")
                    if (path != null) {
                        audioDetails(id, path, result)
                    } else {
                        result.error("ARG_ERROR", "path null", null)
                    }
                } else if (call.method == "queryLrcFiles") {
                    queryLrcFiles(result)
                } else if (call.method == "fileContentHash") {
                    val id = call.argument<Number>("id")?.toLong() ?: 0L
                    val path = call.argument<String>("path")
                    if (path != null) {
                        fileContentHash(id, path, result)
                    } else {
                        result.error("ARG_ERROR", "path null", null)
                    }
                } else if (call.method == "deleteLrcFiles") {
                    val ids = (call.argument<List<Number>>("ids") ?: emptyList()).map { it.toLong() }
                    val paths = (call.argument<List<String>>("paths") ?: emptyList())
                    deleteLrcFiles(ids, paths, result)
                } else if (call.method == "mediaTags") {
                    val id = call.argument<Number>("id")?.toLong() ?: 0L
                    val path = call.argument<String>("path")
                    if (path != null) {
                        mediaTags(id, path, result)
                    } else {
                        result.error("ARG_ERROR", "path null", null)
                    }
                } else if (call.method == "chromaFingerprint") {
                    val id = call.argument<Number>("id")?.toLong() ?: 0L
                    val path = call.argument<String>("path")
                    if (path != null) {
                        chromaFingerprint(id, path, result)
                    } else {
                        result.error("ARG_ERROR", "path null", null)
                    }
                } else if (call.method == "spectralCutoff") {
                    val id = call.argument<Number>("id")?.toLong() ?: 0L
                    val path = call.argument<String>("path")
                    if (path != null) {
                        spectralCutoff(id, path, result)
                    } else {
                        result.error("ARG_ERROR", "path null", null)
                    }
                } else if (call.method == "shareText") {
                    val text = call.argument<String>("text")
                    val title = call.argument<String>("title") ?: "分享"
                    if (text != null) {
                        val intent = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, text)
                        }
                        startActivity(Intent.createChooser(intent, title))
                        result.success(true)
                    } else {
                        result.error("ARG_ERROR", "text null", null)
                    }
                } else if (call.method == "scanFile") {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        MediaScannerConnection.scanFile(this, arrayOf(path), null) { _, uri ->
                            // 确保 MediaStore 已入庫再返回，避免恢复后立即扫描扫不到
                            result.success(uri != null)
                        }
                    } else {
                        result.error("ARG_ERROR", "path null", null)
                    }
                } else if (call.method == "installApk") {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        result.success(installApk(path))
                    } else {
                        result.error("ARG_ERROR", "path null", null)
                    }
                } else if (call.method == "httpGet") {
                    val url = call.argument<String>("url")
                    val followRedirects = call.argument<Boolean>("followRedirects") ?: true
                    if (url != null) {
                        httpGet(url, followRedirects, result)
                    } else {
                        result.error("ARG_ERROR", "url null", null)
                    }
                } else {
                    result.notImplemented()
                }
            }

        // Delete channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "song_dedup/delete")
            .setMethodCallHandler { call, result ->
                if (call.method == "deleteSongs") {
                    @Suppress("UNCHECKED_CAST")
                    val ids = (call.argument<List<Int>>("ids") ?: emptyList())
                    val paths = (call.argument<List<String>>("paths") ?: emptyList())
                    handleDelete(ids, paths, result)
                } else {
                    result.notImplemented()
                }
            }

        // Update channel: 原生下载 APK（走 HttpURLConnection，与 httpGet 同理）。
        updateChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "song_dedup/update")
        updateChannel?.setMethodCallHandler { call, result ->
            if (call.method == "downloadFile") {
                val url = call.argument<String>("url")
                val destPath = call.argument<String>("destPath")
                if (url != null && destPath != null) {
                    downloadCancelled = false
                    downloadFile(url, destPath, result)
                } else {
                    result.error("ARG_ERROR", "url/destPath null", null)
                }
            } else if (call.method == "cancelDownload") {
                downloadCancelled = true
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }

    /// 查询所有 .lrc 歌词文件（MediaStore.Files）
    private fun queryLrcFiles(result: MethodChannel.Result) {
        try {
            val uri = MediaStore.Files.getContentUri("external")
            val projection = arrayOf(
                MediaStore.Files.FileColumns._ID,
                MediaStore.Files.FileColumns.DISPLAY_NAME,
                MediaStore.Files.FileColumns.SIZE,
                MediaStore.Files.FileColumns.DATA
            )
            val cursor = contentResolver.query(
                uri, projection,
                "${MediaStore.Files.FileColumns.DISPLAY_NAME} LIKE ?",
                arrayOf("%.lrc"), null
            )
            val list = mutableListOf<Map<String, Any>>()
            cursor?.use {
                val idCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                val nameCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
                val sizeCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
                val dataCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATA)
                while (it.moveToNext()) {
                    val map = hashMapOf<String, Any>()
                    map["id"] = it.getLong(idCol)
                    map["displayName"] = it.getString(nameCol) ?: ""
                    map["size"] = it.getLong(sizeCol)
                    map["path"] = it.getString(dataCol) ?: ""
                    list.add(map)
                }
            }
            result.success(list)
        } catch (e: Exception) {
            result.error("LRC_ERROR", e.message, null)
        }
    }

    /// 文件内容 SHA-256（经 FD 读取，LRC 文件小，直接读全文件）
    private fun fileContentHash(id: Long, path: String, result: MethodChannel.Result) {
        Thread {
            try {
                val pfd = openAudioFdById(id) ?: openAudioFd(path)
                    ?: throw IllegalArgumentException("cannot open")
                val digest = MessageDigest.getInstance("SHA-256")
                pfd.use {
                    val input = android.os.ParcelFileDescriptor.AutoCloseInputStream(pfd)
                    val buf = ByteArray(8192)
                    var n: Int
                    while (input.read(buf).also { n = it } != -1) {
                        digest.update(buf, 0, n)
                    }
                }
                val hex = digest.digest().joinToString("") { "%02x".format(it) }
                result.success(hex)
            } catch (e: Exception) {
                result.error("HASH_ERROR", e.message, null)
            }
        }.start()
    }

    /// 删除 LRC 文件（MediaStore.Files 集合，需系统确认）
    private fun deleteLrcFiles(ids: List<Long>, paths: List<String>, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val uris = ids.map { id ->
                    Uri.withAppendedPath(MediaStore.Files.getContentUri("external"), id.toString())
                }
                val pendingIntent = MediaStore.createDeleteRequest(contentResolver, uris)
                pendingResult = result
                pendingDeletePaths = paths
                startIntentSenderForResult(
                    pendingIntent.intentSender,
                    deleteRequestCode,
                    null, 0, 0, 0, null
                )
            } catch (e: Exception) {
                result.error("DELETE_ERROR", e.message, null)
            }
        } else {
            result.error("DELETE_ERROR", "need Android 11+", null)
        }
    }

    /// 文件系统直扫：对给定目录递归列文件，不依赖 MediaStore 枚举。
    ///
    /// 背景：MediaStore 经常漏索引文件（尤其是经 MTP/adb 拷入的 (1)~(5) 副本），
    /// total 始终 3133 而 /Music/ 下实际 3262 首。文件在磁盘上就一定能扫到。
    /// 元数据优先查 MediaStore（by path）；查不到的用 MediaMetadataRetriever
    /// 直接读文件；再查不到的从文件名解析 `歌手-标题`。
    /// dirs 为空 = 全部目录（扫描 /storage/emulated/0，跳过 Android/ 与隐藏目录）。
    /// 跑在后台线程，避免阻塞 UI。
    /// 文件系统直扫。`cached` 是 Dart 层传来的上次扫描缓存
    /// （path → [dateModified(秒), sizeBytes]）：mtime+size 都对上
    /// 的文件跳过读元数据、只回 path + cached 标记，Dart 层直接用
    /// 缓存的 SongFile；新增/变更的文件才走 metadataForFile。
    /// 处理中定期向 Dart 上报进度（scanProgress），供进度条实时推进。
    /// 文件系统直扫。`cached` 是 Dart 层传来的上次扫描缓存
    /// （path → [dateModified(秒), sizeBytes]）：mtime+size 都对上
    /// 的文件跳过读元数据、只回 path + cached 标记，Dart 层直接用
    /// 缓存的 SongFile；新增/变更的文件才走 metadataForFile。
    /// 处理中定期向 Dart 上报进度（scanProgress），供进度条实时推进。
    /// 遍历目录（walk，约占媒体扫描大半时间）与读元数据（meta）分两段上报，
    /// 否则遍历那 9 秒进度条一直停在 0。
    private fun querySongsFromFs(
        dirs: List<String>,
        cached: Map<String, List<Int>>,
        expectedTotal: Int,
        channel: MethodChannel,
        result: MethodChannel.Result
    ) {
        Thread {
            try {
                val roots = if (dirs.isEmpty()) {
                    listOf("/storage/emulated/0")
                } else {
                    dirs
                }
                val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
                fun reportProgress(stage: String, processed: Int, total: Int) {
                    mainHandler.post {
                        try {
                            channel.invokeMethod(
                                "scanProgress",
                                mapOf(
                                    "stage" to stage,
                                    "processed" to processed,
                                    "total" to total
                                )
                            )
                        } catch (_: Exception) {
                        }
                    }
                }
                val files = mutableListOf<java.io.File>()
                val visited = mutableSetOf<String>()
                // 遍历中每发现 50 个音频文件上报一次（分母用上次扫描总数估算）。
                // 间隔不能太大：总数 3187 时若每 200 报一次，3000 之后
                // 要到 3200 才再报、永远到不了，看着像卡在 3000。
                var found = 0
                for (root in roots) {
                    collectAudioFiles(java.io.File(root), files, visited) {
                        found++
                        if (found % 50 == 0) {
                            reportProgress("walk", found, expectedTotal)
                        }
                    }
                }
                val total = files.size
                reportProgress("walk", total, total)
                val list = mutableListOf<Map<String, Any>>()
                var processed = 0
                for (f in files) {
                    try {
                        val path = f.absolutePath
                        val entry = cached[path]
                        // mtime（秒）+ 大小都对上 → 未变，跳过读元数据
                        if (entry != null && entry.size >= 2 &&
                            (f.lastModified() / 1000) == entry[0].toLong() &&
                            f.length() == entry[1].toLong()
                        ) {
                            list.add(mapOf("path" to path, "cached" to true))
                        } else {
                            list.add(metadataForFile(f))
                        }
                    } catch (_: Exception) {
                        // 单个文件失败不影响整体
                    }
                    processed++
                    // 每 50 首上报一次，末尾必报
                    if (processed % 50 == 0 || processed == total) {
                        reportProgress("meta", processed, total)
                    }
                }
                result.success(list)
            } catch (e: Exception) {
                result.error("FS_QUERY_ERROR", e.message, null)
            }
        }.start()
    }

    /// 递归收集音频文件。跳过隐藏目录、Android/ 目录（应用私有数据，
    /// 无权访问且无音乐），用 canonical 路径去重防符号链接循环。
    /// 每发现一个音频文件调一次 [onFound]（供遍历进度上报）。
    private fun collectAudioFiles(
        dir: java.io.File,
        out: MutableList<java.io.File>,
        visited: MutableSet<String>,
        onFound: () -> Unit = {}
    ) {
        try {
            if (!dir.exists() || !dir.isDirectory) return
            val canon = try { dir.canonicalPath } catch (_: Exception) { dir.absolutePath }
            if (!visited.add(canon)) return
            val list = dir.listFiles() ?: return
            for (f in list) {
                try {
                    if (f.isDirectory) {
                        val name = f.name
                        if (name.startsWith(".")) continue
                        if (name == "Android") continue
                        collectAudioFiles(f, out, visited, onFound)
                    } else if (f.isFile) {
                        val lower = f.name.lowercase()
                        if (fsAudioExts.any { lower.endsWith(".$it") }) {
                            out.add(f)
                            onFound()
                        }
                    }
                } catch (_: Exception) {
                }
            }
        } catch (_: Exception) {
        }
    }

    /// 单个文件的元数据：MediaStore by path → MediaMetadataRetriever → 文件名解析。
    /// 返回的 map 与 querySongs 相同的 key，Dart 层共用解析逻辑。
    private fun metadataForFile(f: java.io.File): Map<String, Any> {
        val path = f.absolutePath
        // 1. MediaStore by path（时长有效才用）。MediaStore 有 13 首
        // MP3 的 duration 是 NULL（解析失败），直接返回会带 duration=0，
        // 被 Dart 层按无时长过滤掉；此时继续走 MMR 直接读文件取时长。
        // 注意：即使时长无效也要留住 MediaStore 的 id——MMR 兜底路径
        // 返回 id=0 的话，删除时会被分到直接删文件，而 App 无权直接删
        // 共享存储文件（静默失败），只能走 MediaStore 删除请求。
        val msRow = mediaStoreRowForPath(path)
        if (msRow != null && (msRow["duration"] as? Int ?: 0) > 0) {
            // MediaStore 的 DATE_MODIFIED / SIZE 不随文件实际修改更新
            // （adb touch / 改内容不触发 MediaScanner），用文件实际
            // mtime 与大小覆盖，否则增量扫描永远检不出变更。
            return msRow + mapOf(
                "dateModified" to (f.lastModified() / 1000),
                "size" to f.length().toInt()
            )
        }
        val msId = (msRow?.get("id") as? Int) ?: 0
        // 2. MediaMetadataRetriever 直接读文件
        var title = ""
        var artist = ""
        var album = ""
        var durationMs = 0L
        var bitrate = 0
        try {
            val mmr = MediaMetadataRetriever()
            try {
                mmr.setDataSource(path)
                title = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE) ?: ""
                artist = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST) ?: ""
                album = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM) ?: ""
                durationMs = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                bitrate = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull() ?: 0
            } finally {
                try { mmr.release() } catch (_: Exception) {}
            }
        } catch (_: Exception) {
        }
        // 3. MMR 也读不出时长时，从文件头直接读：
        // ASF/WMA（文件实际是 ASF/WMA 却标着 .mp3 后缀，MediaStore 与
        // MMR 都被后缀骗了）读 ASF 文件属性对象；AIFF（MMR 不支持）
        // 读 COMM 块的帧数 ÷ 采样率。仍为 0 才由 Dart 层按无时长过滤。
        if (durationMs <= 0) {
            durationMs = asfDurationMs(f)
        }
        if (durationMs <= 0) {
            durationMs = aiffDurationMs(f)
        }
        // 4. 文件名解析 `歌手-标题`
        if (title.isBlank()) {
            val (a, t) = parseFilename(f.name)
            if (artist.isBlank()) artist = a
            title = t
        }
        if (artist.isBlank()) artist = "<unknown>"
        return mapOf(
            "id" to msId,
            "displayName" to f.name,
            "title" to title,
            "artist" to artist,
            "album" to album,
            "duration" to durationMs.toInt(),
            "size" to f.length().toInt(),
            "path" to path,
            // File.lastModified() 是毫秒，MediaStore DATE_MODIFIED 是秒，统一成秒
            "dateModified" to (f.lastModified() / 1000),
            "bitrate" to bitrate
        )
    }

    /// MediaStore 按 DATA 列精确查一行。查到返回与 querySongs 同格式的 map，
    /// 查不到返回 null（文件未被 MediaStore 索引）。
    private fun mediaStoreRowForPath(path: String): Map<String, Any>? {
        val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.DATE_MODIFIED
        )
        try {
            contentResolver.query(
                uri, projection,
                "${MediaStore.Audio.Media.DATA} = ?",
                arrayOf(path), null
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return null
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val displayNameCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
                val titleCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
                val artistCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
                val albumCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
                val durationCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
                val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE)
                val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
                val dateModifiedCol = cursor.getColumnIndex(MediaStore.Audio.Media.DATE_MODIFIED)
                val bitrateCol = cursor.getColumnIndex("bitrate")
                val map = hashMapOf<String, Any>()
                map["id"] = cursor.getLong(idCol).toInt()
                map["displayName"] = cursor.getString(displayNameCol) ?: ""
                map["title"] = cursor.getString(titleCol) ?: ""
                map["artist"] = cursor.getString(artistCol) ?: "<unknown>"
                map["album"] = cursor.getString(albumCol) ?: ""
                map["duration"] = cursor.getLong(durationCol).toInt()
                map["size"] = cursor.getLong(sizeCol).toInt()
                map["path"] = cursor.getString(dataCol) ?: ""
                map["dateModified"] = if (dateModifiedCol != -1) cursor.getLong(dateModifiedCol) else 0L
                map["bitrate"] = if (bitrateCol != -1) cursor.getInt(bitrateCol) else 0
                return map
            }
        } catch (_: Exception) {
        }
        return null
    }

    /// ASF/WMA 文件被误标为 .mp3 时从 ASF 头读时长。文件可能先带一段
    /// ID3v2 标签，ASF 头在标签之后。时长在文件属性对象（File Properties
    /// Object）里，单位 100ns。不是 ASF 或读不到返回 0。
    private fun asfDurationMs(f: java.io.File): Long {
        // ASF Header Object GUID
        val asfGuid = byteArrayOf(
            0x30, 0x26, 0xB2.toByte(), 0x75, 0x8E.toByte(), 0x66,
            0xCF.toByte(), 0x11, 0xA6.toByte(), 0xD9.toByte(), 0x00,
            0xAA.toByte(), 0x00, 0x62, 0xCE.toByte(), 0x6C
        )
        // File Properties Object GUID
        val fpGuid = byteArrayOf(
            0xA1.toByte(), 0xDC.toByte(), 0xAB.toByte(), 0x8C.toByte(),
            0x47, 0xA9.toByte(), 0xCF.toByte(), 0x11, 0x8E.toByte(),
            0xE4.toByte(), 0x00, 0xC0.toByte(), 0x0C, 0x20, 0x53, 0x65
        )
        return try {
            val bytes = f.readBytes()
            var i = 0
            // 跳过 ID3v2 标签头（10 字节 + synchsafe 长度）
            if (bytes.size >= 10 && bytes[0] == 'I'.code.toByte() &&
                bytes[1] == 'D'.code.toByte() && bytes[2] == '3'.code.toByte()
            ) {
                val size = ((bytes[6].toInt() and 0x7f) shl 21) or
                    ((bytes[7].toInt() and 0x7f) shl 14) or
                    ((bytes[8].toInt() and 0x7f) shl 7) or
                    (bytes[9].toInt() and 0x7f)
                i = 10 + size
            }
            if (i + 30 > bytes.size) return 0L
            for (k in asfGuid.indices) {
                if (bytes[i + k] != asfGuid[k]) return 0L
            }
            // Header Object：size(8) @+16，子对象数(4) @+24，子对象从 +30 开始
            var hdrSize = 0L
            for (k in 0 until 8) {
                hdrSize = hdrSize or
                    ((bytes[i + 16 + k].toLong() and 0xFF) shl (8 * k))
            }
            var numObj = 0
            for (k in 0 until 4) {
                numObj = numObj or
                    ((bytes[i + 24 + k].toInt() and 0xFF) shl (8 * k))
            }
            val end = (i + hdrSize).coerceAtMost(bytes.size.toLong()).toInt()
            var p = i + 30
            repeat(numObj) {
                if (p + 24 > end) return 0L
                var sz = 0L
                for (k in 0 until 8) {
                    sz = sz or
                        ((bytes[p + 16 + k].toLong() and 0xFF) shl (8 * k))
                }
                var isFp = true
                for (k in fpGuid.indices) {
                    if (bytes[p + k] != fpGuid[k]) { isFp = false; break }
                }
                if (isFp) {
                    // File Properties：GUID(16)+size(8)+file_id(16)+
                    // file_size(8)+creation(8)+packets(8)+play_duration(8)
                    // +send_duration(8)+preroll(8)。
                    // play_duration 含编码器 preroll（ffmpeg 写的 WMA 会多
                    // 出约 3 秒），用 send_duration（真实音频时长）为准，
                    // 读不到再回落 play_duration。
                    var play = 0L
                    for (k in 0 until 8) {
                        play = play or
                            ((bytes[p + 64 + k].toLong() and 0xFF) shl (8 * k))
                    }
                    var send = 0L
                    for (k in 0 until 8) {
                        send = send or
                            ((bytes[p + 72 + k].toLong() and 0xFF) shl (8 * k))
                    }
                    val dur = if (send > 0) send else play
                    return dur / 10000 // 100ns -> ms
                }
                p += sz.toInt()
            }
            0L
        } catch (_: Exception) {
            0L
        }
    }

    /// AIFF 时长兜底：MMR 读不出 AIFF 时长（MediaStore 也是 NULL），
    /// 直接解析 AIFF 头：COMM 块里的帧数 ÷ 采样率。
    /// 采样率是 80 位 IEEE 扩展浮点（大端：符号 1 位 + 指数 15 位，
    /// 偏置 16383 + 尾数 64 位，含显式整数位）。
    private fun aiffDurationMs(f: java.io.File): Long {
        return try {
            val bytes = f.readBytes()
            if (bytes.size < 54) return 0L
            // FORM(4) + size(4) + AIFF/AIFC(4)
            if (!(bytes[0] == 'F'.code.toByte() && bytes[1] == 'O'.code.toByte() &&
                  bytes[2] == 'R'.code.toByte() && bytes[3] == 'M'.code.toByte())) return 0L
            val formType = String(bytes, 8, 4, Charsets.US_ASCII)
            if (formType != "AIFF" && formType != "AIFC") return 0L
            // 找 COMM 块（块大小大端，奇数补 1 字节对齐）
            var p = 12
            while (p + 8 <= bytes.size) {
                val id = String(bytes, p, 4, Charsets.US_ASCII)
                val sz = ((bytes[p + 4].toLong() and 0xFF) shl 24) or
                    ((bytes[p + 5].toLong() and 0xFF) shl 16) or
                    ((bytes[p + 6].toLong() and 0xFF) shl 8) or
                    (bytes[p + 7].toLong() and 0xFF)
                if (id == "COMM") {
                    // COMM 数据：channels(2) + frames(4) + sampleSize(2)
                    // + sampleRate(10)，共 18 字节
                    if (p + 26 > bytes.size) return 0L
                    val frames = ((bytes[p + 10].toLong() and 0xFF) shl 24) or
                        ((bytes[p + 11].toLong() and 0xFF) shl 16) or
                        ((bytes[p + 12].toLong() and 0xFF) shl 8) or
                        (bytes[p + 13].toLong() and 0xFF)
                    val rate = decodeExtended80(bytes, p + 16)
                    if (frames <= 0 || rate <= 0.0) return 0L
                    return (frames * 1000.0 / rate).toLong()
                }
                p += 8 + sz.toInt() + (if (sz % 2 == 1L) 1 else 0)
            }
            0L
        } catch (_: Exception) {
            0L
        }
    }

    /// 解 80 位 IEEE 扩展浮点（大端）。
    private fun decodeExtended80(bytes: ByteArray, off: Int): Double {
        if (off + 10 > bytes.size) return 0.0
        val sign = if (bytes[off].toInt() and 0x80 != 0) -1.0 else 1.0
        val exp = (((bytes[off].toInt() and 0x7F) shl 8) or
            (bytes[off + 1].toInt() and 0xFF)) - 16383
        // 尾数：64 位大端整数，实际值 = mant / 2^63 * 2^exp
        var mant = 0.0
        for (k in 0 until 8) {
            mant = mant * 256.0 + (bytes[off + 2 + k].toInt() and 0xFF)
        }
        return sign * mant * Math.pow(2.0, (exp - 63).toDouble())
    }

    /// 文件名解析 `歌手-标题`：优先 ` - `（空格-空格），其次第一个 `-`。
    /// 无分隔符时标题 = 去扩展名文件名，歌手 = <unknown>。
    /// 不去掉 (1) 等下载副本后缀——Dart 层版本标记会处理。
    private fun parseFilename(name: String): Pair<String, String> {
        val base = name.substringBeforeLast('.')
        val sep = when {
            base.contains(" - ") -> " - "
            base.contains("-") -> "-"
            else -> null
        }
        if (sep == null) return "<unknown>" to base.trim()
        val artist = base.substringBefore(sep).trim()
        val title = base.substringAfter(sep).trim()
        return (if (artist.isEmpty()) "<unknown>" else artist) to
            (if (title.isEmpty()) base.trim() else title)
    }

    private fun querySongs(result: MethodChannel.Result) {
        try {
            val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            val projection = arrayOf(
                MediaStore.Audio.Media._ID,
                MediaStore.Audio.Media.DISPLAY_NAME,
                MediaStore.Audio.Media.TITLE,
                MediaStore.Audio.Media.ARTIST,
                MediaStore.Audio.Media.ALBUM,
                MediaStore.Audio.Media.DURATION,
                MediaStore.Audio.Media.SIZE,
                MediaStore.Audio.Media.DATA,
                MediaStore.Audio.Media.DATE_MODIFIED
            )
            // 不再过滤 IS_MUSIC，避免 (1) 副本因标记问题漏扫；由 Dart 层按扩展名/时长过滤
            val selection: String? = null
            val cursor: Cursor? = contentResolver.query(
                collection, projection, selection, null,
                "${MediaStore.Audio.Media.TITLE} ASC"
            )
            val list = mutableListOf<Map<String, Any>>()
            cursor?.use {
                val idCol = it.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val displayNameCol = it.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
                val titleCol = it.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
                val artistCol = it.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
                val albumCol = it.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
                val durationCol = it.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
                val sizeCol = it.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE)
                val dataCol = it.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
                // DATE_MODIFIED（秒）：供 Dart 层缓存做有效性校验。
                // 直接 FileStat 走文件路径在 scoped storage 下可能无权限，
                // 用 MediaStore 列最可靠；取不到填 0
                val dateModifiedCol =
                    it.getColumnIndex(MediaStore.Audio.Media.DATE_MODIFIED)
                // bitrate 列：用原始列名查询，ROM/版本不支持时 getColumnIndex 返回 -1，
                // 此时填 0，Dart 层回退到估算值
                val bitrateCol = it.getColumnIndex("bitrate")

                while (it.moveToNext()) {
                    val map = hashMapOf<String, Any>()
                    map["id"] = it.getLong(idCol).toInt()
                    map["displayName"] = it.getString(displayNameCol) ?: ""
                    map["title"] = it.getString(titleCol) ?: ""
                    map["artist"] = it.getString(artistCol) ?: "<unknown>"
                    map["album"] = it.getString(albumCol) ?: ""
                    map["duration"] = it.getLong(durationCol).toInt()
                    map["size"] = it.getLong(sizeCol).toInt()
                    map["path"] = it.getString(dataCol) ?: ""
                    map["dateModified"] =
                        if (dateModifiedCol != -1) it.getLong(dateModifiedCol) else 0L
                    map["bitrate"] = if (bitrateCol != -1) it.getInt(bitrateCol) else 0
                    list.add(map)
                }
            }
            result.success(list)
        } catch (e: Exception) {
            result.error("QUERY_ERROR", e.message, null)
        }
    }

    /// 用 MediaStore content URI 打开音频文件的 FD。
    ///
    /// scoped storage 下直接文件路径可能无权限（Permission denied），
    /// content URI 走 MediaProvider 鉴权，只要有媒体读取授权就能打开。
    /// 找不到时返回 null，调用方回退到直接路径。
    /// 用 MediaStore ID 直接构造 content URI 打开 FD（最可靠，不依赖 DATA 列）。
    private fun openAudioFdById(id: Long): ParcelFileDescriptor? {
        return try {
            val contentUri = ContentUris.withAppendedId(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
            contentResolver.openFileDescriptor(contentUri, "r")
        } catch (e: Exception) {
            null
        }
    }

    private fun openAudioFd(path: String): ParcelFileDescriptor? {
        return try {
            // /sdcard 是符号链接，MediaStore DATA 列存的是规范路径
            val normPath = when {
                path.startsWith("/sdcard/") ->
                    "/storage/emulated/0/" + path.removePrefix("/sdcard/")
                else -> path
            }
            val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            val cursor = contentResolver.query(
                uri,
                arrayOf(MediaStore.Audio.Media._ID),
                "${MediaStore.Audio.Media.DATA}=?",
                arrayOf(normPath),
                null
            )
            var pfd: ParcelFileDescriptor? = null
            if (cursor != null) {
                if (cursor.moveToFirst()) {
                    val id = cursor.getLong(0)
                    val contentUri = ContentUris.withAppendedId(uri, id)
                    try {
                        pfd = contentResolver.openFileDescriptor(contentUri, "r")
                    } catch (e: Exception) {
                    }
                }
                cursor.close()
            }
            pfd
        } catch (e: Exception) {
            null
        }
    }

    /// 读音频技术元数据：采样率/声道。MediaExtractor 只读封装头，不解码，很快。
    private fun audioDetails(id: Long, path: String, result: MethodChannel.Result) {
        val pfd = openAudioFdById(id) ?: openAudioFd(path)
        try {
            val extractor = MediaExtractor()
            if (pfd != null) {
                extractor.setDataSource(pfd.fileDescriptor)
            } else {
                extractor.setDataSource(path)
            }
            var sampleRate = 0
            var channels = 0
            var mime = ""
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val m = f.getString(MediaFormat.KEY_MIME) ?: ""
                if (m.startsWith("audio/")) {
                    mime = m
                    if (f.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                        sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    }
                    if (f.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                        channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    }
                    break
                }
            }
            extractor.release()
            try { pfd?.close() } catch (_: Exception) {}
            result.success(mapOf(
                "sampleRate" to sampleRate,
                "channels" to channels,
                "mime" to mime
            ))
        } catch (e: Exception) {
            result.error("DETAILS_ERROR", e.message, null)
        }
    }

    /// 封面/歌词检测：内嵌封面 via MediaMetadataRetriever(FD)；
    /// 同目录同名 .lrc 是否被 MediaStore 索引。跑在后台线程。
    private fun mediaTags(id: Long, path: String, result: MethodChannel.Result) {
        Thread {
            try {
                result.success(doMediaTags(id, path))
            } catch (e: Exception) {
                result.error("TAGS_ERROR", e.message, null)
            }
        }.start()
    }

    private fun doMediaTags(id: Long, path: String): Map<String, Any> {
        var hasCover = false
        try {
            val pfd = openAudioFdById(id) ?: openAudioFd(path)
            if (pfd != null) {
                val mmr = MediaMetadataRetriever()
                try {
                    mmr.setDataSource(pfd.fileDescriptor)
                    hasCover = mmr.embeddedPicture != null
                } finally {
                    try { mmr.release() } catch (_: Exception) {}
                    try { pfd.close() } catch (_: Exception) {}
                }
            }
        } catch (_: Exception) { }
        var hasLyrics = false
        try {
            val dot = path.lastIndexOf('.')
            val base = if (dot > 0) path.substring(0, dot) else path
            val lrcPath = "$base.lrc"
            val uri = MediaStore.Files.getContentUri("external")
            contentResolver.query(
                uri,
                arrayOf(MediaStore.Files.FileColumns._ID),
                "${MediaStore.Files.FileColumns.DATA} = ?",
                arrayOf(lrcPath),
                null
            )?.use {
                hasLyrics = it.count > 0
            }
        } catch (_: Exception) { }
        return mapOf("hasCover" to hasCover, "hasLyrics" to hasLyrics)
    }

    private data class MonoSegment(val samples: FloatArray, val filled: Int, val sampleRate: Int)

    private fun decodeMonoSegment(id: Long, path: String, seekFraction: Double, maxSeconds: Int): MonoSegment {
        val pfd = openAudioFdById(id) ?: openAudioFd(path)
        val extractor = MediaExtractor()
        if (pfd != null) {
            extractor.setDataSource(pfd.fileDescriptor)
        } else {
            extractor.setDataSource(path)
        }
        val trackIndex = (0 until extractor.trackCount).firstOrNull {
            (extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME) ?: "")
                .startsWith("audio/")
        } ?: throw IllegalArgumentException("no audio track")
        extractor.selectTrack(trackIndex)
        val format = extractor.getTrackFormat(trackIndex)
        val mime = format.getString(MediaFormat.KEY_MIME)!!
        val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
            format.getLong(MediaFormat.KEY_DURATION)
        } else {
            0L
        }

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, null, null, 0)
        codec.start()
        if (durationUs > 0) {
            try {
                extractor.seekTo((durationUs * seekFraction).toLong(),
                    MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            } catch (_: Exception) {
            }
        }
        val maxSamples = sampleRate * maxSeconds
        val mono = FloatArray(maxSamples)
        var filled = 0
        val info = MediaCodec.BufferInfo()
        var sawEos = false
        var outEncoding = AudioFormat.ENCODING_PCM_16BIT
        var guard = 0
        while (!sawEos && filled < maxSamples && guard++ < 20000) {
            val inIndex = codec.dequeueInputBuffer(10000)
            if (inIndex >= 0) {
                val ib = codec.getInputBuffer(inIndex)!!
                val n = extractor.readSampleData(ib, 0)
                if (n < 0) {
                    codec.queueInputBuffer(inIndex, 0, 0, 0,
                        MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                } else {
                    codec.queueInputBuffer(inIndex, 0, n, extractor.sampleTime, 0)
                    extractor.advance()
                }
            }
            val outIndex = codec.dequeueOutputBuffer(info, 10000)
            if (outIndex >= 0) {
                val ob = codec.getOutputBuffer(outIndex)!!
                if (info.size > 0 &&
                    info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM == 0) {
                    if (outEncoding == AudioFormat.ENCODING_PCM_FLOAT) {
                        val fb = ob.asFloatBuffer()
                        val tmp = FloatArray(info.size / 4)
                        fb.get(tmp)
                        var i = 0
                        while (i < tmp.size && filled < maxSamples) {
                            var sum = 0f
                            for (ch in 0 until channelCount) {
                                val idx = i + ch
                                if (idx < tmp.size) sum += tmp[idx]
                            }
                            mono[filled++] = sum / channelCount
                            i += channelCount
                        }
                    } else {
                        val sb = ob.asShortBuffer()
                        val tmp = ShortArray(info.size / 2)
                        sb.get(tmp)
                        var i = 0
                        while (i < tmp.size && filled < maxSamples) {
                            var sum = 0f
                            for (ch in 0 until channelCount) {
                                val idx = i + ch
                                if (idx < tmp.size) sum += tmp[idx] / 32768f
                            }
                            mono[filled++] = sum / channelCount
                            i += channelCount
                        }
                    }
                }
                codec.releaseOutputBuffer(outIndex, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                    sawEos = true
                }
            } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                try {
                    val of = codec.outputFormat
                    if (of.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                        outEncoding = of.getInteger(MediaFormat.KEY_PCM_ENCODING)
                    }
                } catch (_: Exception) {
                }
            }
        }
        try {
            codec.stop()
        } catch (_: Exception) {
        }
        codec.release()
        extractor.release()
        try { pfd?.close() } catch (_: Exception) {}
        return MonoSegment(mono, filled, sampleRate)
    }

    private fun fft(re: DoubleArray, im: DoubleArray, n: Int) {
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) {
                j = j xor bit
                bit = bit shr 1
            }
            j = j xor bit
            if (i < j) {
                val tr = re[i]; re[i] = re[j]; re[j] = tr
                val ti = im[i]; im[i] = im[j]; im[j] = ti
            }
        }
        var len = 2
        while (len <= n) {
            val ang = -2.0 * kotlin.math.PI / len
            val wr = kotlin.math.cos(ang)
            val wi = kotlin.math.sin(ang)
            var i = 0
            while (i < n) {
                var curR = 1.0
                var curI = 0.0
                for (k in 0 until len / 2) {
                    val ur = re[i + k]
                    val ui = im[i + k]
                    val ar = re[i + k + len / 2]
                    val ai = im[i + k + len / 2]
                    val vr = ar * curR - ai * curI
                    val vi = ar * curI + ai * curR
                    re[i + k] = ur + vr
                    im[i + k] = ui + vi
                    re[i + k + len / 2] = ur - vr
                    im[i + k + len / 2] = ui - vi
                    val nR = curR * wr - curI * wi
                    curI = curR * wi + curI * wr
                    curR = nR
                }
                i += len
            }
            len = len shl 1
        }
    }


    /// Chroma 指纹：3 段 × 12 维音高类别能量向量，共 36 个 float（L2 归一化）。
    ///
    /// 同一录音转不同格式后 chroma 几乎不变；不同录音（现场版/重制版/不同歌）
    /// 的音高分布不同。只在同名组内做细分，不做全库比对。
    private fun chromaFingerprint(id: Long, path: String, result: MethodChannel.Result) {
        Thread {
            try {
                result.success(doChromaFingerprint(id, path))
            } catch (e: Exception) {
                result.error("CHROMA_ERROR", e.message, null)
            }
        }.start()
    }

    /// 频谱截止频率：假无损检测用。解码 3 段（25%/50%/75%，各 5 秒），
    /// 每窗 4096 点 Hann + FFT，找能量高于峰值 -60dB 的最高频点；
    /// 取全部窗口截止频率的 90 分位——真无损偶有高频、假无损从不
    /// 超过转码时的截止线，90 分位既抗静音段干扰又不被个别瞬态带偏。
    /// 返回 map：cutoffHz（90 分位）、sampleRate、windows（窗口数）。
    private fun spectralCutoff(id: Long, path: String, result: MethodChannel.Result) {
        Thread {
            try {
                result.success(doSpectralCutoff(id, path))
            } catch (e: Exception) {
                result.error("SPECTRAL_ERROR", e.message, null)
            }
        }.start()
    }

    private fun doSpectralCutoff(id: Long, path: String): Map<String, Any> {
        val cutoffs = mutableListOf<Double>()
        var sampleRate = 0
        for (f in doubleArrayOf(0.25, 0.5, 0.75)) {
            val seg = decodeMonoSegment(id, path, f, 5)
            sampleRate = seg.sampleRate
            cutoffs.addAll(spectralCutoffsOfSegment(seg))
        }
        if (cutoffs.isEmpty()) throw IllegalStateException("decoded too few samples")
        cutoffs.sort()
        val idx = ((cutoffs.size - 1) * 0.9).toInt()
        return mapOf(
            "cutoffHz" to cutoffs[idx],
            "sampleRate" to sampleRate,
            "windows" to cutoffs.size
        )
    }

    /// 单段各窗口的截止频率：4096 点 Hann + FFT，截止频点为能量高于
    /// 窗口峰值 -60dB（0.1%）的最高 bin 对应频率。
    private fun spectralCutoffsOfSegment(seg: MonoSegment): List<Double> {
        val n = 4096
        val hop = 2048
        val re = DoubleArray(n)
        val im = DoubleArray(n)
        val win = DoubleArray(n) { i ->
            0.5 - 0.5 * kotlin.math.cos(2.0 * kotlin.math.PI * i / (n - 1))
        }
        val out = mutableListOf<Double>()
        var pos = 0
        while (pos + n <= seg.filled) {
            for (i in 0 until n) {
                re[i] = seg.samples[pos + i] * win[i]
                im[i] = 0.0
            }
            fft(re, im, n)
            var peak = 0.0
            val mag = DoubleArray(n / 2)
            for (b in 1 until n / 2) {
                val m = kotlin.math.sqrt(re[b] * re[b] + im[b] * im[b])
                mag[b] = m
                if (m > peak) peak = m
            }
            if (peak > 0.0) {
                val thresh = peak * 0.001 // -60dB
                var cutoffBin = 0
                for (b in n / 2 - 1 downTo 1) {
                    if (mag[b] > thresh) { cutoffBin = b; break }
                }
                if (cutoffBin > 0) {
                    out.add(cutoffBin * seg.sampleRate.toDouble() / n)
                }
            }
            pos += hop
        }
        return out
    }

    private fun doChromaFingerprint(id: Long, path: String): Map<String, Any> {
        val out = mutableListOf<Double>()
        var windows = 0
        for (f in doubleArrayOf(0.25, 0.5, 0.75)) {
            val seg = decodeMonoSegment(id, path, f, 5)
            out.addAll(chromaOfSegment(seg).toList())
            windows++
        }
        return mapOf("chroma" to out, "windows" to windows)
    }

    /// 单段 5 秒音频的 12 维 chroma 向量（L2 归一化）。
    /// 分窗 4096 Hann + FFT，频点按最近 MIDI 音高折叠到 12 音级，
    /// 只统计 55Hz~4kHz（音乐音高主要区间）。
    private fun chromaOfSegment(seg: MonoSegment): DoubleArray {
        val n = 4096
        val hop = 2048
        val chroma = DoubleArray(12)
        val re = DoubleArray(n)
        val im = DoubleArray(n)
        val win = DoubleArray(n) { i ->
            0.5 - 0.5 * kotlin.math.cos(2.0 * kotlin.math.PI * i / (n - 1))
        }
        var pos = 0
        var frames = 0
        while (pos + n <= seg.filled) {
            for (i in 0 until n) {
                re[i] = seg.samples[pos + i] * win[i]
                im[i] = 0.0
            }
            fft(re, im, n)
            for (b in 1 until n / 2) {
                val mag = kotlin.math.sqrt(re[b] * re[b] + im[b] * im[b])
                if (mag <= 0.0) continue
                val freq = b * seg.sampleRate.toDouble() / n
                if (freq < 55.0 || freq > 4096.0) continue
                val midi = 69.0 + 12.0 * kotlin.math.log2(freq / 440.0)
                val pc = ((kotlin.math.round(midi).toInt() % 12) + 12) % 12
                chroma[pc] += mag
            }
            pos += hop
            frames++
        }
        if (frames == 0) throw IllegalStateException("decoded too few samples")
        var norm = 0.0
        for (v in chroma) norm += v * v
        norm = kotlin.math.sqrt(norm)
        if (norm > 0.0) for (i in chroma.indices) chroma[i] /= norm
        return chroma
    }

    private fun handleDelete(ids: List<Int>, paths: List<String>, result: MethodChannel.Result) {
        if (ids.isEmpty() || paths.isEmpty()) {
            result.success(emptyList<String>())
            return
        }

        // 文件系统直扫的文件可能不在 MediaStore 里（id=0），MediaStore 删除请求
        // 对它们无效。id<=0 的直接删文件，id>0 的走 MediaStore 删除请求。
        val paired = ids.zip(paths)
        val fsOnlyPaths = paired.filter { it.first <= 0 }.map { it.second }
        val directDeleted = directDelete(fsOnlyPaths).toMutableList()
        val valid = paired.filter { it.first > 0 }
        if (valid.isEmpty()) {
            result.success(directDeleted)
            return
        }
        val validIds = valid.map { it.first }
        val validPaths = valid.map { it.second }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val uris = validIds.map { id ->
                    Uri.withAppendedPath(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id.toString())
                }
                val pendingIntent = MediaStore.createDeleteRequest(contentResolver, uris)
                pendingResult = result
                // MediaStore 删除确认后返回全部已删路径（含直接删除的）
                pendingDeletePaths = validPaths + directDeleted
                pendingDirectDeleted = directDeleted
                startIntentSenderForResult(
                    pendingIntent.intentSender,
                    deleteRequestCode,
                    null, 0, 0, 0, null
                )
            } catch (e: Exception) {
                result.error("DELETE_ERROR", e.message, null)
            }
        } else if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
            try {
                val uris = validIds.map { id ->
                    Uri.withAppendedPath(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id.toString())
                }
                val pendingIntent = MediaStore.createDeleteRequest(contentResolver, uris)
                pendingResult = result
                pendingDeletePaths = validPaths + directDeleted
                pendingDirectDeleted = directDeleted
                startIntentSenderForResult(
                    pendingIntent.intentSender,
                    deleteRequestCode,
                    null, 0, 0, 0, null
                )
            } catch (e: Exception) {
                val deleted = directDelete(validPaths)
                result.success(deleted + directDeleted)
            }
        } else {
            val deleted = directDelete(validPaths)
            // 同时尝试通过 ContentResolver 删除 MediaStore 记录
            for (id in validIds) {
                try {
                    contentResolver.delete(
                        Uri.withAppendedPath(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id.toString()),
                        null, null
                    )
                } catch (_: Exception) {}
            }
            result.success(deleted + directDeleted)
        }
    }

    private fun directDelete(paths: List<String>): List<String> {
        val deleted = mutableListOf<String>()
        for (p in paths) {
            try {
                val f = java.io.File(p)
                if (f.exists() && f.delete()) {
                    deleted.add(p)
                }
            } catch (_: Exception) {}
        }
        return deleted;
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(debugReceiver)
        } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == deleteRequestCode) {
            if (resultCode == Activity.RESULT_OK) {
                pendingResult?.success(pendingDeletePaths)
            } else {
                // 用户取消：MediaStore 部分没删，但直接删除的已经删了，如实返回
                pendingResult?.success(pendingDirectDeleted)
            }
            pendingResult = null
            pendingDeletePaths = emptyList()
            pendingDirectDeleted = emptyList()
        }
    }
}

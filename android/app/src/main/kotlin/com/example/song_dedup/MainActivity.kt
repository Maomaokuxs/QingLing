package com.example.song_dedup

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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingDeletePaths: List<String> = emptyList()
    private val deleteRequestCode = 1001
    private var debugChannel: MethodChannel? = null
    private val debugReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                "com.example.song_dedup.DEBUG_SCAN" -> {
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Debug channel: automation can trigger a scan with
        // `adb shell am broadcast -a com.example.song_dedup.DEBUG_SCAN`
        debugChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "song_dedup/debug")
        val debugFilter = IntentFilter().apply {
            addAction("com.example.song_dedup.DEBUG_SCAN")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(debugReceiver, debugFilter, Context.RECEIVER_EXPORTED) // debug receiver for adb testing; must be exported to receive shell broadcasts
        } else {
            registerReceiver(debugReceiver, debugFilter)
        }

        // Scanner channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "song_dedup/scanner")
            .setMethodCallHandler { call, result ->
                if (call.method == "querySongs") {
                    querySongs(result)
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
    }

    private fun triggerScanForMissing() {
        try {
            fun collect(dir: java.io.File, out: MutableList<java.io.File>) {
                val list = dir.listFiles() ?: return
                for (f in list) {
                    if (f.isDirectory) collect(f, out)
                    else if (f.name.contains("(1)") && (f.name.endsWith(".mp3") || f.name.endsWith(".flac") || f.name.endsWith(".m4a") || f.name.endsWith(".wav"))) out.add(f)
                }
            }
            val musicDir = java.io.File("/storage/emulated/0/Music")
            if (musicDir.exists()) {
                val out = mutableListOf<java.io.File>()
                collect(musicDir, out)
                for (f in out.take(50)) {
                    MediaScannerConnection.scanFile(this, arrayOf(f.absolutePath), null, null)
                }
                // 给 MediaStore 一点时间入庫，避免本次查询仍漏掉
                try { Thread.sleep(400) } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
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

    private fun querySongs(result: MethodChannel.Result) {
        triggerScanForMissing()
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

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val uris = ids.map { id ->
                    Uri.withAppendedPath(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id.toString())
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
        } else if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
            try {
                val uris = ids.map { id ->
                    Uri.withAppendedPath(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id.toString())
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
                val deleted = directDelete(paths)
                result.success(deleted)
            }
        } else {
            val deleted = directDelete(paths)
            // 同时尝试通过 ContentResolver 删除 MediaStore 记录
            for (id in ids) {
                try {
                    contentResolver.delete(
                        Uri.withAppendedPath(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id.toString()),
                        null, null
                    )
                } catch (_: Exception) {}
            }
            result.success(deleted)
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
                pendingResult?.success(emptyList<String>())
            }
            pendingResult = null
            pendingDeletePaths = emptyList()
        }
    }
}

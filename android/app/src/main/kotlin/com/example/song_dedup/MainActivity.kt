package com.example.song_dedup

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.media.MediaScannerConnection
import android.os.Build
import android.provider.MediaStore
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingDeletePaths: List<String> = emptyList()
    private val deleteRequestCode = 1001

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Scanner channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "song_dedup/scanner")
            .setMethodCallHandler { call, result ->
                if (call.method == "querySongs") {
                    querySongs(result)
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
                MediaStore.Audio.Media.DATA
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
                    map["bitrate"] = if (bitrateCol != -1) it.getInt(bitrateCol) else 0
                    list.add(map)
                }
            }
            result.success(list)
        } catch (e: Exception) {
            result.error("QUERY_ERROR", e.message, null)
        }
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

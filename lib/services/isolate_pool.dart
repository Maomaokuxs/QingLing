import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 计算单个文件的内容指纹（worker isolate 内执行，必须是顶层函数）
/// 只用文件内容（前 32KB）+ 文件大小 + 扩展名。
/// 注意：不要混入 durationMs——MediaStore 读的时长同一文件可能差几毫秒，
/// 混入后同一音频文件的哈希会不同，Tier 4 抓不到字节相同的文件。
String _hashFile(String path, int sizeBytes, String ext) {
  try {
    final f = File(path);
    if (!f.existsSync()) return '';
    final raf = f.openSync();
    try {
      final len = min(32768, raf.lengthSync());
      final bytes = raf.readSync(len);
      final digest = sha256.convert([
        ...bytes,
        ...utf8.encode('$sizeBytes|$ext'),
      ]);
      return digest.toString().substring(0, 16);
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return '';
  }
}

/// worker isolate 入口：[initPort, resultPort]
void _workerEntry(List<SendPort> ports) {
  final initPort = ports[0];
  final resultPort = ports[1];
  final taskPort = ReceivePort();
  initPort.send(taskPort.sendPort);
  taskPort.listen((msg) {
    if (msg == null) {
      taskPort.close();
      return;
    }
    final m = msg as List;
    final fp = _hashFile(
      m[1] as String,
      m[2] as int,
      m[3] as String,
    );
    resultPort.send([m[0], fp]);
  });
}

class _Worker {
  final Isolate isolate;
  final SendPort sendPort;
  _Worker._(this.isolate, this.sendPort);

  static Future<_Worker> spawn(SendPort resultPort) async {
    final initPort = ReceivePort();
    final isolate = await Isolate.spawn(_workerEntry, [
      initPort.sendPort,
      resultPort,
    ]);
    final sendPort = await initPort.first as SendPort;
    initPort.close();
    return _Worker._(isolate, sendPort);
  }

  void send(Object? msg) => sendPort.send(msg);
  void dispose() => isolate.kill(priority: Isolate.immediate);
}

/// 常驻 isolate 工作池。
///
/// 原来每个文件一次 `Isolate.run()`：几千首歌就是几千次 isolate 启动
/// 开销。现在按 CPU 核心数常驻 N 个 worker，任务走队列分发。
class HashWorkerPool {
  final int size;
  final List<_Worker> _workers = [];
  final ReceivePort _resultPort = ReceivePort();
  final Map<int, Completer<String>> _pending = {};
  int _cursor = 0;
  int _nextId = 0;
  bool _started = false;

  HashWorkerPool({int? size}) : size = size ?? Platform.numberOfProcessors;

  Future<void> start() async {
    if (_started) return;
    _resultPort.listen((msg) {
      final m = msg as List;
      _pending.remove(m[0] as int)?.complete(m[1] as String);
    });
    for (var i = 0; i < size; i++) {
      _workers.add(await _Worker.spawn(_resultPort.sendPort));
    }
    _started = true;
  }

  /// 计算单个文件的指纹。池未启动或 worker 为空时退化为同步计算。
  Future<String> hashFile(
    String path,
    int sizeBytes,
    String ext,
  ) {
    if (!_started || _workers.isEmpty) {
      return Future.value(_hashFile(path, sizeBytes, ext));
    }
    final id = _nextId++;
    final c = Completer<String>();
    _pending[id] = c;
    final w = _workers[_cursor % _workers.length];
    _cursor++;
    w.send([id, path, sizeBytes, ext]);
    return c.future;
  }

  Future<void> stop() async {
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
    _resultPort.close();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete('');
    }
    _pending.clear();
    _started = false;
  }
}

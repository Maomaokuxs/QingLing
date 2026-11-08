import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 忽略分组：用户标记"这组不是重复"，持久化后以后扫描直接跳过。
/// key 取 DuplicateGroup.key（归一化标题/指纹等），跨扫描稳定。
class IgnoreService {
  static const _prefsKey = 'ignored_groups';
  static const _maxEntries = 5000;

  static final ValueNotifier<Set<String>> ignored = ValueNotifier({});

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      ignored.value = (prefs.getStringList(_prefsKey) ?? []).toSet();
    } catch (_) {}
  }

  static Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var list = ignored.value.toList();
      if (list.length > _maxEntries) {
        list = list.sublist(list.length - _maxEntries);
      }
      await prefs.setStringList(_prefsKey, list);
    } catch (_) {}
  }

  static bool isIgnored(String key) => ignored.value.contains(key);

  static Future<void> ignore(String key) async {
    if (ignored.value.contains(key)) return;
    ignored.value = {...ignored.value, key};
    await _save();
  }

  static Future<void> unignore(String key) async {
    if (!ignored.value.contains(key)) return;
    final next = {...ignored.value}..remove(key);
    ignored.value = next;
    await _save();
  }

  static Future<void> clear() async {
    ignored.value = {};
    await _save();
  }
}

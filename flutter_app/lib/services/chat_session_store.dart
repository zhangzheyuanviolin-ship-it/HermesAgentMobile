import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/chat_session_models.dart';
import 'native_bridge.dart';

class ChatSessionStore {
  static const String _storeFileName = 'chat_sessions_v1.json';

  Future<File> _storeFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_storeFileName');
  }

  Future<ChatStoreData> loadStore() async {
    try {
      final file = await _storeFile();
      if (!await file.exists()) {
        return const ChatStoreData();
      }

      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const ChatStoreData();
      }

      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) {
        return const ChatStoreData();
      }

      final sessionsRaw = data['sessions'];
      final sessions = <ChatSession>[];
      if (sessionsRaw is List) {
        for (final item in sessionsRaw) {
          if (item is Map<String, dynamic>) {
            sessions.add(ChatSession.fromJson(item));
          } else if (item is Map) {
            sessions.add(ChatSession.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      }

      sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      final lastSessionId = data['lastSessionId']?.toString();
      return ChatStoreData(
        sessions: sessions,
        lastSessionId: (lastSessionId?.isNotEmpty == true) ? lastSessionId : null,
      );
    } catch (_) {
      return const ChatStoreData();
    }
  }

  Future<void> saveStore({
    required List<ChatSession> sessions,
    String? lastSessionId,
  }) async {
    final file = await _storeFile();
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }

    final payload = {
      'version': 1,
      'lastSessionId': lastSessionId,
      'sessions': sessions.map((s) => s.toJson()).toList(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
  }

  Future<String?> exportSession(ChatSession session) async {
    final exportDir = await _resolveExportDir();
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }

    final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '').replaceAll('.', '');
    final safeTitle = _sanitizeFileName(session.title);
    final path = '${exportDir.path}/chat-$safeTitle-$timestamp.json';

    final file = File(path);
    final payload = {
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'session': session.toJson(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
    return file.path;
  }

  Future<Directory> _resolveExportDir() async {
    try {
      final hasStorage = await NativeBridge.hasStoragePermission();
      if (hasStorage) {
        final sdcard = await NativeBridge.getExternalStoragePath();
        return Directory('$sdcard/下载管理/HermesAgentMobile项目改造/聊天记录导出');
      }
    } catch (_) {}
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/聊天记录导出');
  }

  String _sanitizeFileName(String raw) {
    final sanitized = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    if (sanitized.isEmpty) return 'session';
    return sanitized.length > 40 ? sanitized.substring(0, 40) : sanitized;
  }
}

import 'package:flutter/material.dart';
import '../models/chat_session_models.dart';
import '../services/chat_session_store.dart';

class ChatSessionsScreen extends StatefulWidget {
  final String? currentSessionId;
  final ChatSessionStore store;

  const ChatSessionsScreen({
    super.key,
    required this.store,
    this.currentSessionId,
  });

  @override
  State<ChatSessionsScreen> createState() => _ChatSessionsScreenState();
}

class _ChatSessionsScreenState extends State<ChatSessionsScreen> {
  List<ChatSession> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await widget.store.loadStore();
    if (!mounted) return;
    setState(() {
      _sessions = data.sessions;
      _loading = false;
    });
  }

  Future<void> _renameSession(ChatSession session) async {
    final controller = TextEditingController(text: session.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改会话标题'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入新标题',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (newTitle == null || newTitle.isEmpty) return;
    final data = await widget.store.loadStore();
    final updated = data.sessions.map((s) {
      if (s.id != session.id) return s;
      return s.copyWith(
        title: newTitle,
        isTitleManuallySet: true,
        updatedAt: DateTime.now().toUtc(),
      );
    }).toList();
    await widget.store.saveStore(
      sessions: updated,
      lastSessionId: data.lastSessionId,
    );
    await _load();
  }

  Future<void> _deleteSession(ChatSession session) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定删除“${session.title}”吗？删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    final data = await widget.store.loadStore();
    final updated = data.sessions.where((s) => s.id != session.id).toList();
    final newLast = data.lastSessionId == session.id ? null : data.lastSessionId;
    await widget.store.saveStore(
      sessions: updated,
      lastSessionId: newLast,
    );
    await _load();
  }

  Future<void> _exportSession(ChatSession session) async {
    final path = await widget.store.exportSession(session);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导出到: $path')),
    );
  }

  Future<void> _showActions(ChatSession session) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('修改标题'),
              onTap: () async {
                Navigator.of(ctx).pop();
                await _renameSession(session);
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_upload_outlined),
              title: const Text('导出会话'),
              onTap: () async {
                Navigator.of(ctx).pop();
                await _exportSession(session);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除会话'),
              onTap: () async {
                Navigator.of(ctx).pop();
                await _deleteSession(session);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle(ChatSession session) {
    final local = session.updatedAt.toLocal();
    final turns = session.turns.length;
    return '更新: ${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}'
        '  ·  $turns 轮';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('聊天会话管理'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? const Center(child: Text('暂无会话记录'))
              : ListView.builder(
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    final selected = session.id == widget.currentSessionId;
                    return ListTile(
                      leading: Icon(
                        selected ? Icons.radio_button_checked : Icons.chat_bubble_outline,
                      ),
                      title: Text(session.title),
                      subtitle: Text(_subtitle(session)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).pop(session.id),
                      onLongPress: () => _showActions(session),
                    );
                  },
                ),
    );
  }
}

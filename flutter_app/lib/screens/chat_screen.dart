import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path_pkg;
import 'package:uuid/uuid.dart';
import '../models/chat_session_models.dart';
import '../services/chat_service.dart';
import '../services/chat_session_store.dart';
import '../services/native_bridge.dart';
import 'chat_sessions_screen.dart';

enum _RuntimeStatus {
  ready,
  running,
  completed,
  cancelled,
  error,
}

class _PendingAttachment {
  final String id;
  final String name;
  final String hostPath;
  final String guestPath;
  final int sizeBytes;

  const _PendingAttachment({
    required this.id,
    required this.name,
    required this.hostPath,
    required this.guestPath,
    required this.sizeBytes,
  });
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _chatService = ChatService();
  final _sessionStore = ChatSessionStore();
  final _uuid = const Uuid();
  final _imagePicker = ImagePicker();

  List<ChatSession> _sessions = [];
  String? _currentSessionId;
  List<ChatTurn> _turns = [];
  List<_PendingAttachment> _pendingAttachments = [];

  bool _loadingSessions = true;
  bool _sending = false;
  bool _showProcess = true;
  bool _showThinkingInFinal = false;
  _RuntimeStatus _runtimeStatus = _RuntimeStatus.ready;
  String _runtimeTitle = '已就绪';
  String _runtimeDetail = '可以发送消息';

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _chatService.dispose();
    super.dispose();
  }

  Future<void> _loadSessions({String? preferredSessionId}) async {
    final data = await _sessionStore.loadStore();
    var sessions = data.sessions;
    var targetId = preferredSessionId ?? data.lastSessionId;

    if (sessions.isEmpty) {
      final now = DateTime.now().toUtc();
      final first = ChatSession(
        id: _uuid.v4(),
        title: '新聊天',
        createdAt: now,
        updatedAt: now,
        turns: const [],
      );
      sessions = [first];
      targetId = first.id;
      await _sessionStore.saveStore(
        sessions: sessions,
        lastSessionId: targetId,
      );
    }

    ChatSession selected;
    if (targetId != null) {
      selected = sessions.firstWhere(
        (s) => s.id == targetId,
        orElse: () => sessions.first,
      );
    } else {
      selected = sessions.first;
    }

    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _currentSessionId = selected.id;
      _turns = List<ChatTurn>.from(selected.turns);
      _pendingAttachments = [];
      _loadingSessions = false;
    });
  }

  List<ChatHistoryMessage> _buildHistory() {
    final messages = <ChatHistoryMessage>[];
    for (final turn in _turns) {
      messages.add(ChatHistoryMessage(role: 'user', content: turn.userPrompt));
      if (turn.assistantFinal.trim().isNotEmpty) {
        messages.add(ChatHistoryMessage(role: 'assistant', content: turn.assistantFinal));
      }
    }
    return messages;
  }

  String _autoTitleFromTurns(ChatSession session) {
    if (session.isTitleManuallySet) return session.title;
    if (_turns.isEmpty) return '新聊天';
    final first = _turns.first.userPrompt
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (first.isEmpty) return '新聊天';
    return first.length > 18 ? '${first.substring(0, 18)}...' : first;
  }

  Future<void> _persistCurrentSession() async {
    if (_currentSessionId == null) return;
    final index = _sessions.indexWhere((s) => s.id == _currentSessionId);
    if (index < 0) return;

    final current = _sessions[index];
    final updated = current.copyWith(
      title: _autoTitleFromTurns(current),
      updatedAt: DateTime.now().toUtc(),
      turns: List<ChatTurn>.from(_turns),
    );

    _sessions[index] = updated;
    await _sessionStore.saveStore(
      sessions: _sessions,
      lastSessionId: _currentSessionId,
    );
  }

  Future<void> _openSessionManager() async {
    if (_sending) return;
    await _persistCurrentSession();
    if (!mounted) return;
    final selectedId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ChatSessionsScreen(
          store: _sessionStore,
          currentSessionId: _currentSessionId,
        ),
      ),
    );
    await _loadSessions(preferredSessionId: selectedId);
  }

  Future<void> _createNewSession() async {
    if (_sending) return;
    await _persistCurrentSession();
    final now = DateTime.now().toUtc();
    final session = ChatSession(
      id: _uuid.v4(),
      title: '新聊天',
      createdAt: now,
      updatedAt: now,
      turns: const [],
    );
    setState(() {
      _sessions = [session, ..._sessions];
      _currentSessionId = session.id;
      _turns = [];
      _pendingAttachments = [];
    });
    await _sessionStore.saveStore(
      sessions: _sessions,
      lastSessionId: session.id,
    );
  }

  Future<void> _send() async {
    if (_loadingSessions || _sending) return;

    final rawText = _inputController.text.trim();
    if (rawText.isEmpty && _pendingAttachments.isEmpty) return;

    final userText = rawText.isEmpty ? '请先分析我上传的附件，并告诉我关键结论。' : rawText;
    final attachments = List<_PendingAttachment>.from(_pendingAttachments);
    final prompt = _composePrompt(userText, attachments);
    final history = _buildHistory();

    _inputController.clear();
    setState(() {
      _pendingAttachments = [];
    });

    final newTurn = ChatTurn(
      id: _uuid.v4(),
      userPrompt: prompt,
      isStreaming: true,
    );

    setState(() {
      _sending = true;
      _turns.add(newTurn);
      _runtimeStatus = _RuntimeStatus.running;
      _runtimeTitle = '任务执行中';
      _runtimeDetail = '请求已发送，正在等待模型输出...';
    });
    await _persistCurrentSession();
    _scrollToBottom();

    try {
      await for (final update in _chatService.streamChat(
        history: history,
        userPrompt: prompt,
        model: 'hermes-agent',
      )) {
        final idx = _turns.indexWhere((t) => t.id == newTurn.id);
        if (idx < 0) break;

        setState(() {
          _turns[idx] = _turns[idx].copyWith(
            assistantProcess: update.assistantProcess,
            assistantFinal: update.assistantFinal,
            isStreaming: !update.done,
            clearError: true,
          );
          if (update.done) {
            _runtimeStatus = _RuntimeStatus.completed;
            _runtimeTitle = '任务已完成';
            _runtimeDetail = '已收到最终回复，可继续发送消息';
          } else {
            _runtimeStatus = _RuntimeStatus.running;
            _runtimeTitle = '任务执行中';
            _runtimeDetail = _progressDetailFromProcess(update.assistantProcess);
          }
        });
        _scrollToBottom();
      }
    } on ChatCancelledException {
      final idx = _turns.indexWhere((t) => t.id == newTurn.id);
      if (idx >= 0) {
        final existing = _turns[idx];
        setState(() {
          _turns[idx] = existing.copyWith(
            assistantProcess: _appendCancellationNote(existing.assistantProcess),
            isStreaming: false,
            clearError: true,
          );
          _runtimeStatus = _RuntimeStatus.cancelled;
          _runtimeTitle = '任务已取消';
          _runtimeDetail = '当前执行已停止，可立即发送新消息';
        });
      }
    } catch (e) {
      final idx = _turns.indexWhere((t) => t.id == newTurn.id);
      final status = _statusForError(e);
      if (idx >= 0) {
        setState(() {
          _turns[idx] = _turns[idx].copyWith(
            isStreaming: false,
            error: e.toString(),
          );
          _runtimeStatus = _RuntimeStatus.error;
          _runtimeTitle = status.$1;
          _runtimeDetail = status.$2;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          if (_runtimeStatus == _RuntimeStatus.running) {
            _runtimeStatus = _RuntimeStatus.ready;
            _runtimeTitle = '已就绪';
            _runtimeDetail = '可以继续发送消息';
          }
        });
      }
      await _persistCurrentSession();
      _scrollToBottom();
    }
  }

  void _cancelCurrentTask() {
    if (!_sending) return;
    _chatService.cancelActiveRequest();
    setState(() {
      _runtimeStatus = _RuntimeStatus.running;
      _runtimeTitle = '正在取消任务...';
      _runtimeDetail = '已发送取消请求，请稍候';
    });
  }

  String _composePrompt(String text, List<_PendingAttachment> attachments) {
    if (attachments.isEmpty) return text;
    final sb = StringBuffer();
    sb.writeln(text);
    sb.writeln();
    sb.writeln('[附件信息]');
    for (int i = 0; i < attachments.length; i++) {
      final a = attachments[i];
      sb.writeln('${i + 1}. 文件名: ${a.name}');
      sb.writeln('   容器路径: ${a.guestPath}');
      sb.writeln('   宿主路径: ${a.hostPath}');
    }
    sb.writeln();
    sb.writeln('请优先在“容器路径”读取附件。');
    sb.writeln('你运行在 Hermes Agent 的 Linux 容器环境里，可直接访问 /root 下路径。');
    sb.writeln('如需要检查共享存储，也可查看 /sdcard、/storage、/storage/emulated/0。');
    return sb.toString().trim();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  String _progressDetailFromProcess(String process) {
    final lines = process
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '模型正在执行任务...';
    final last = lines.last;
    return last.length > 80 ? '${last.substring(0, 80)}...' : last;
  }

  String _appendCancellationNote(String process) {
    final note = '用户已手动取消当前任务。';
    final trimmed = process.trim();
    if (trimmed.isEmpty) return note;
    if (trimmed.contains(note)) return trimmed;
    return '$trimmed\n\n$note';
  }

  String _extractFinalReplyOnly(String raw) {
    final normalized = raw.replaceAll('\r\n', '\n').trim();
    if (normalized.isEmpty) return '';

    var cleaned = normalized
        .replaceAll(
          RegExp(
            r'<(?:think|thinking|reasoning|thought)\b[^>]*>[\s\S]*?</(?:think|thinking|reasoning|thought)\s*>',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(r'</?(?:think|thinking|reasoning|thought)\b[^>]*>', caseSensitive: false),
          '',
        )
        .trim();
    if (cleaned.isEmpty) cleaned = normalized;

    final assistantFinal = _extractAssistantFinalBlock(cleaned);
    if (assistantFinal.isNotEmpty) {
      cleaned = assistantFinal;
    }

    final anchored = _extractFromFinalAnchorBlocks(cleaned);
    if (anchored.isNotEmpty) return anchored;

    final withoutLeadingThinking = _trimLeadingThinkingBlocks(cleaned);
    if (withoutLeadingThinking.isNotEmpty) return withoutLeadingThinking;

    return cleaned;
  }

  String _extractAssistantFinalBlock(String text) {
    final open = RegExp(r'<assistant_final\b[^>]*>', caseSensitive: false).firstMatch(text);
    if (open == null) return '';
    final close = RegExp(r'</assistant_final\s*>', caseSensitive: false).firstMatch(text);
    final start = open.end;
    var end = text.length;
    if (close != null && close.start >= start) {
      end = close.start;
    }
    if (end < start) return '';
    return text.substring(start, end).trim();
  }

  String _extractFromFinalAnchorBlocks(String text) {
    final blocks = text
        .split(RegExp(r'\n\s*\n+'))
        .map((b) => b.trim())
        .where((b) => b.isNotEmpty)
        .toList();
    if (blocks.length < 2) return '';

    for (var i = 0; i < blocks.length; i++) {
      if (_isFinalAnchorBlock(blocks[i])) {
        if (i == 0) return text.trim();
        return blocks.skip(i).join('\n\n').trim();
      }
    }
    return '';
  }

  String _trimLeadingThinkingBlocks(String text) {
    final blocks = text
        .split(RegExp(r'\n\s*\n+'))
        .map((b) => b.trim())
        .where((b) => b.isNotEmpty)
        .toList();
    if (blocks.length < 2) return '';

    var leadingThinkingCount = 0;
    for (final block in blocks) {
      if (_isFinalAnchorBlock(block)) break;
      if (_isThinkingBlock(block)) {
        leadingThinkingCount += 1;
      } else {
        break;
      }
    }

    if (leadingThinkingCount <= 0 || leadingThinkingCount >= blocks.length) {
      return '';
    }
    return blocks.skip(leadingThinkingCount).join('\n\n').trim();
  }

  bool _isFinalAnchorBlock(String block) {
    final firstLine = block.split('\n').first.trimLeft();
    final anchor = RegExp(
      r"^(#{1,6}\s*)?(以下是|这是|最终|结论|总结|汇报|报告|结果|答复|回复|完成情况|处理结果|here is|here's|final answer|summary|in summary|result|report|overall|to summarize)\b",
      caseSensitive: false,
    );
    if (anchor.hasMatch(firstLine)) return true;
    if (block.contains('以下是') || block.contains('Final answer')) return true;
    return false;
  }

  bool _isThinkingBlock(String block) {
    final firstLine = block.split('\n').first.trimLeft();
    final processLead = RegExp(
      r"^(the user wants|let me|i will|i need to|i should|i am going to|i'm going to|now i can|now i have|now i will|i can see|first[, ]|next[, ]|then[, ]|我来|我先|先|现在|接下来|然后|随后|让我|我将|我会|需要先|先执行|现在执行)\b",
      caseSensitive: false,
    );
    if (processLead.hasMatch(firstLine)) return true;
    if (block.contains('工具调用:')) return true;
    if (block.contains('Now I can see') || block.contains('Key models and their quotas')) return true;
    if (block.contains('现在我用自然语言总结这些数据')) return true;
    return false;
  }

  (String, String) _statusForError(Object error) {
    final text = error.toString();
    final lower = text.toLowerCase();
    final disconnected = lower.contains('failed host lookup') ||
        lower.contains('connection reset') ||
        lower.contains('connection closed') ||
        lower.contains('connection aborted') ||
        lower.contains('timed out') ||
        lower.contains('network') ||
        lower.contains('socket') ||
        lower.contains('http 502') ||
        lower.contains('http 503') ||
        lower.contains('http 504');
    if (disconnected) {
      return ('API连接已断开', '请检查网络或网关状态后重试');
    }
    return ('任务执行失败', text.length > 80 ? '${text.substring(0, 80)}...' : text);
  }

  Widget _buildRuntimeBanner(ThemeData theme) {
    final (IconData icon, Color color) = switch (_runtimeStatus) {
      _RuntimeStatus.ready => (Icons.check_circle_outline, Colors.green.shade700),
      _RuntimeStatus.running => (Icons.autorenew, Colors.blue.shade700),
      _RuntimeStatus.completed => (Icons.task_alt, Colors.green.shade800),
      _RuntimeStatus.cancelled => (Icons.cancel_outlined, Colors.orange.shade800),
      _RuntimeStatus.error => (Icons.error_outline, theme.colorScheme.error),
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '状态：$_runtimeTitle',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _runtimeDetail,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _escapeForBashSingleQuote(String input) {
    return input.replaceAll("'", "'\"'\"'");
  }

  String _safeName(String raw) {
    final name = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    if (name.isEmpty) return 'attachment.bin';
    return name.length > 60 ? name.substring(0, 60) : name;
  }

  Future<_PendingAttachment> _storeAttachment({
    String? sourcePath,
    Uint8List? bytes,
    required String originalName,
  }) async {
    if (_currentSessionId == null) {
      throw Exception('当前会话不可用，无法添加附件');
    }
    if (sourcePath == null && bytes == null) {
      throw Exception('附件数据为空');
    }

    final filesDir = await NativeBridge.getFilesDir();
    final safeName = _safeName(originalName);
    final unique = '${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 8)}';
    final fileName = '${unique}_$safeName';

    final hostDir = Directory(
      '$filesDir/rootfs/ubuntu/root/.hermes_mobile_uploads/$_currentSessionId',
    );
    await hostDir.create(recursive: true);

    final target = File('${hostDir.path}/$fileName');
    if (sourcePath != null) {
      await File(sourcePath).copy(target.path);
    } else {
      await target.writeAsBytes(bytes!, flush: true);
    }

    final guestPath = '/root/.hermes_mobile_uploads/$_currentSessionId/$fileName';
    final checkCmd = "test -f '${_escapeForBashSingleQuote(guestPath)}' && echo ok";
    await NativeBridge.runInProot(checkCmd, timeout: 30);

    final size = await target.length();
    return _PendingAttachment(
      id: _uuid.v4(),
      name: originalName,
      hostPath: target.path,
      guestPath: guestPath,
      sizeBytes: size,
    );
  }

  Future<void> _pickFromCamera() async {
    try {
      final file = await _imagePicker.pickImage(
        source: ImageSource.camera,
      );
      if (file == null) return;

      final attachment = await _storeAttachment(
        sourcePath: file.path,
        originalName: file.name.isNotEmpty ? file.name : path_pkg.basename(file.path),
      );
      if (!mounted) return;
      setState(() => _pendingAttachments = [..._pendingAttachments, attachment]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('拍照添加失败: $e')),
      );
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final type = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_outlined),
                title: const Text('选择照片'),
                onTap: () => Navigator.of(ctx).pop('image'),
              ),
              ListTile(
                leading: const Icon(Icons.videocam_outlined),
                title: const Text('选择视频'),
                onTap: () => Navigator.of(ctx).pop('video'),
              ),
            ],
          ),
        ),
      );
      if (!mounted || type == null) return;

      XFile? file;
      if (type == 'video') {
        file = await _imagePicker.pickVideo(
          source: ImageSource.gallery,
        );
      } else {
        file = await _imagePicker.pickImage(
          source: ImageSource.gallery,
        );
      }
      if (file == null) return;

      final attachment = await _storeAttachment(
        sourcePath: file.path,
        originalName: file.name.isNotEmpty ? file.name : path_pkg.basename(file.path),
      );
      if (!mounted) return;
      setState(() => _pendingAttachments = [..._pendingAttachments, attachment]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('相册添加失败: $e')),
      );
    }
  }

  Future<void> _pickFromFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final added = <_PendingAttachment>[];
      for (final file in result.files) {
        final name = file.name;
        if (file.path != null && file.path!.isNotEmpty) {
          added.add(await _storeAttachment(
            sourcePath: file.path!,
            originalName: name,
          ));
        } else if (file.bytes != null) {
          added.add(await _storeAttachment(
            bytes: file.bytes!,
            originalName: name,
          ));
        }
      }

      if (!mounted || added.isEmpty) return;
      setState(() => _pendingAttachments = [..._pendingAttachments, ...added]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('文件添加失败: $e')),
      );
    }
  }

  Future<void> _showAttachmentActions() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照添加'),
              onTap: () async {
                Navigator.of(ctx).pop();
                await _pickFromCamera();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () async {
                Navigator.of(ctx).pop();
                await _pickFromGallery();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('从文件选择器添加'),
              onTap: () async {
                Navigator.of(ctx).pop();
                await _pickFromFiles();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTurnCard(ChatTurn turn, ThemeData theme) {
    final processText = turn.assistantProcess.trim();
    final rawFinalText = turn.assistantFinal.trim();
    final filteredFinalText = _showThinkingInFinal
        ? rawFinalText
        : _extractFinalReplyOnly(rawFinalText);
    final finalText = filteredFinalText.isNotEmpty ? filteredFinalText : rawFinalText;
    final thinkingHidden = !_showThinkingInFinal &&
        rawFinalText.isNotEmpty &&
        finalText != rawFinalText;
    final isStreaming = turn.isStreaming;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '用户提示',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(turn.userPrompt),
            if (_showProcess) ...[
              const SizedBox(height: 12),
              Text(
                'AI 执行过程',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              SelectableText(
                processText.isNotEmpty ? processText : (isStreaming ? '正在分析与执行中...' : '（无过程输出）'),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'AI 最终回复',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(
              finalText.isNotEmpty ? finalText : (isStreaming ? '正在生成最终回复...' : '（无最终回复内容）'),
            ),
            if (thinkingHidden) ...[
              const SizedBox(height: 6),
              Text(
                '已隐藏思考内容，可在下方点击“显示思考内容”查看完整回复。',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (turn.error != null && turn.error!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '错误: ${turn.error}',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentChip(_PendingAttachment attachment) {
    final sizeKb = (attachment.sizeBytes / 1024).toStringAsFixed(1);
    return InputChip(
      label: Text('${attachment.name} (${sizeKb}KB)'),
      avatar: const Icon(Icons.attach_file, size: 18),
      onDeleted: _sending
          ? null
          : () {
              setState(() {
                _pendingAttachments = _pendingAttachments
                    .where((a) => a.id != attachment.id)
                    .toList();
              });
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentTitle = _sessions
            .firstWhere(
              (s) => s.id == _currentSessionId,
              orElse: () => ChatSession(
                id: '',
                title: '聊天',
                createdAt: DateTime.now().toUtc(),
                updatedAt: DateTime.now().toUtc(),
              ),
            )
            .title;

    return Scaffold(
      appBar: AppBar(
        title: Text(currentTitle),
        actions: [
          IconButton(
            tooltip: '会话管理',
            icon: const Icon(Icons.history),
            onPressed: _sending ? null : _openSessionManager,
          ),
          IconButton(
            tooltip: _showProcess ? '隐藏过程' : '显示过程',
            icon: Icon(_showProcess ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showProcess = !_showProcess),
          ),
          IconButton(
            tooltip: '新建聊天',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: _sending ? null : _createNewSession,
          ),
        ],
      ),
      body: _loadingSessions
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildRuntimeBanner(theme),
                Expanded(
                  child: _turns.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(20),
                            child: Text(
                              '先在首页启动 Gateway，并在“模型与 API 设置”里完成模型配置后，再在这里发送消息。',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(12),
                          itemCount: _turns.length,
                          itemBuilder: (context, index) {
                            return _buildTurnCard(_turns[index], theme);
                          },
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _sending ? null : _showAttachmentActions,
                          icon: const Icon(Icons.attach_file),
                          label: Text(
                            _pendingAttachments.isEmpty
                                ? '添加附件'
                                : '已添加 ${_pendingAttachments.length} 个附件',
                          ),
                        ),
                        const SizedBox(height: 6),
                        Semantics(
                          label: _showThinkingInFinal ? '当前显示思考内容' : '当前隐藏思考内容',
                          hint: _showThinkingInFinal
                              ? '双击可在最终回复中隐藏思考内容'
                              : '双击可在最终回复中显示思考内容',
                          button: true,
                          child: OutlinedButton.icon(
                            onPressed: _sending
                                ? null
                                : () => setState(() => _showThinkingInFinal = !_showThinkingInFinal),
                            icon: Icon(
                              _showThinkingInFinal
                                  ? Icons.psychology_alt_outlined
                                  : Icons.psychology_outlined,
                            ),
                            label: Text(_showThinkingInFinal ? '隐藏思考内容' : '显示思考内容'),
                          ),
                        ),
                        if (_pendingAttachments.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: _pendingAttachments.map(_buildAttachmentChip).toList(),
                          ),
                          const SizedBox(height: 8),
                        ],
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _inputController,
                                enabled: !_sending,
                                minLines: 1,
                                maxLines: 6,
                                textInputAction: TextInputAction.newline,
                                decoration: const InputDecoration(
                                  hintText: '输入您的任务或问题...',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Semantics(
                              label: _sending ? '取消当前任务' : '发送消息',
                              hint: _sending ? '双击可终止当前任务执行' : '双击可发送输入内容',
                              button: true,
                              child: FilledButton.icon(
                                onPressed: _sending ? _cancelCurrentTask : _send,
                                icon: Icon(
                                  _sending ? Icons.stop_circle_outlined : Icons.send,
                                ),
                                label: Text(_sending ? '取消' : '发送'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_session_models.dart';
import '../services/chat_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _chatService = ChatService();
  final _uuid = const Uuid();

  final List<ChatTurn> _turns = [];

  bool _sending = false;
  bool _showProcess = false;

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _chatService.dispose();
    super.dispose();
  }

  List<ChatHistoryMessage> _buildHistory() {
    final messages = <ChatHistoryMessage>[];
    for (final turn in _turns) {
      messages.add(ChatHistoryMessage(role: 'user', content: turn.userPrompt));
      if (turn.assistantFinal.trim().isNotEmpty) {
        messages.add(
          ChatHistoryMessage(role: 'assistant', content: turn.assistantFinal),
        );
      }
    }
    return messages;
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;

    final history = _buildHistory();
    _inputController.clear();

    final newTurn = ChatTurn(
      id: _uuid.v4(),
      userPrompt: text,
      isStreaming: true,
    );

    setState(() {
      _sending = true;
      _turns.add(newTurn);
    });

    _scrollToBottom();

    try {
      await for (final update in _chatService.streamChat(
        history: history,
        userPrompt: text,
        model: 'hermes-agent',
      )) {
        final idx = _turns.indexWhere((t) => t.id == newTurn.id);
        if (idx < 0) break;

        setState(() {
          _turns[idx] = _turns[idx].copyWith(
            assistantProcess: update.assistantProcess,
            assistantFinal: update.assistantFinal,
            isStreaming: !update.done,
          );
        });

        _scrollToBottom();
      }
    } catch (e) {
      final idx = _turns.indexWhere((t) => t.id == newTurn.id);
      if (idx >= 0) {
        setState(() {
          _turns[idx] = _turns[idx].copyWith(
            isStreaming: false,
            error: e.toString(),
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
      _scrollToBottom();
    }
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

  Widget _buildTurnCard(ChatTurn turn, ThemeData theme) {
    final processText = turn.assistantProcess.trim();
    final finalText = turn.assistantFinal.trim();
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
                processText.isNotEmpty
                    ? processText
                    : (isStreaming ? '正在分析与执行中...' : '（无过程输出）'),
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
              finalText.isNotEmpty
                  ? finalText
                  : (isStreaming ? '正在生成最终回复...' : '（无最终回复内容）'),
            ),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('聊天'),
        actions: [
          IconButton(
            tooltip: _showProcess ? '隐藏过程' : '显示过程',
            icon: Icon(_showProcess ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showProcess = !_showProcess),
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
            onPressed: _sending
                ? null
                : () => setState(() {
                      _turns.clear();
                    }),
          ),
        ],
      ),
      body: Column(
        children: [
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
              child: Row(
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
                  FilledButton(
                    onPressed: _sending ? null : _send,
                    child: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
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

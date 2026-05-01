import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../models/chat_session_models.dart';

class ChatStreamUpdate {
  final String assistantProcess;
  final String assistantThinking;
  final String assistantFinal;
  final bool done;

  const ChatStreamUpdate({
    required this.assistantProcess,
    required this.assistantThinking,
    required this.assistantFinal,
    this.done = false,
  });
}

class ChatCancelledException implements Exception {
  const ChatCancelledException();

  @override
  String toString() => '任务已取消';
}

class ChatService {
  ChatService();
  bool _cancelRequested = false;
  http.Client? _activeStreamingClient;

  void cancelActiveRequest() {
    _cancelRequested = true;
    _activeStreamingClient?.close();
    _activeStreamingClient = null;
  }

  Stream<ChatStreamUpdate> streamChat({
    required List<ChatHistoryMessage> history,
    required String userPrompt,
    required String model,
  }) async* {
    _cancelRequested = false;
    final messages = [
      {
        'role': 'system',
        'content': _systemPrompt,
      },
      ...history.map((m) => {
            'role': m.role,
            'content': m.content,
          }),
      {
        'role': 'user',
        'content': userPrompt,
      },
    ];

    final processLines = <String>[];
    var thinkingText = '';
    var finalText = '';

    final request = http.Request(
      'POST',
      Uri.parse('${AppConstants.apiServerUrl}/v1/chat/completions'),
    )
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode({
        'model': model,
        'stream': true,
        'messages': messages,
      });

    final requestClient = http.Client();
    _activeStreamingClient = requestClient;
    try {
      final response = await requestClient.send(request);
      if (_cancelRequested) {
        throw const ChatCancelledException();
      }
      if (response.statusCode >= 400) {
        final body = await response.stream.bytesToString();
        throw Exception('HTTP ${response.statusCode}: ${_extractErrorMessage(body)}');
      }

      var currentSseEvent = '';
      final currentSseData = StringBuffer();

      void resetSseFrame() {
        currentSseEvent = '';
        currentSseData.clear();
      }

      String currentProcessText() => _joinNonEmpty(processLines);

      (bool, ChatStreamUpdate?) handleSseFrame() {
        final payload = currentSseData.toString().trim();
        final eventType = currentSseEvent.trim();
        resetSseFrame();

        if (payload.isEmpty) return (false, null);
        if (payload == '[DONE]') return (true, null);

        if (eventType == 'hermes.tool.progress') {
          try {
            final obj = jsonDecode(payload);
            if (obj is Map<String, dynamic>) {
              final label = _extractAnyText(obj['label']);
              final tool = _extractAnyText(obj['tool']);
              final emoji = _extractAnyText(obj['emoji']);
              final line = _joinNonEmpty([
                if (label.isNotEmpty) '${emoji.isNotEmpty ? '$emoji ' : ''}$label',
                if (label.isEmpty && tool.isNotEmpty) '工具调用: $tool',
              ]);
              if (line.isNotEmpty) {
                processLines.add(line);
              }
            }
          } catch (_) {
            // Ignore malformed custom tool events.
          }
          return (
            false,
            ChatStreamUpdate(
              assistantProcess: currentProcessText(),
              assistantThinking: thinkingText.trim(),
              assistantFinal: finalText.trim(),
            ),
          );
        }

        if (eventType == 'hermes.thinking.final') {
          try {
            final data = jsonDecode(payload);
            if (data is Map<String, dynamic>) {
              thinkingText = _extractAnyText(data['text']).trim();
            }
          } catch (_) {}
          return (
            false,
            ChatStreamUpdate(
              assistantProcess: currentProcessText(),
              assistantThinking: thinkingText.trim(),
              assistantFinal: finalText.trim(),
            ),
          );
        }

        if (eventType == 'hermes.final.final') {
          try {
            final data = jsonDecode(payload);
            if (data is Map<String, dynamic>) {
              finalText = _extractAnyText(data['text']).trim();
            }
          } catch (_) {}
          return (
            false,
            ChatStreamUpdate(
              assistantProcess: currentProcessText(),
              assistantThinking: thinkingText.trim(),
              assistantFinal: finalText.trim(),
            ),
          );
        }

        Map<String, dynamic> data;
        try {
          data = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          return (false, null);
        }

        if (eventType == 'hermes.error' || data['error'] != null) {
          throw Exception(_extractErrorMessage(jsonEncode(data)));
        }

        final choices = data['choices'];
        if (choices is List && choices.isNotEmpty && choices.first is Map) {
          final choice = choices.first;
          final delta = (choice as Map)['delta'];
          if (delta is Map) {
            final toolCalls = _formatToolCalls(delta['tool_calls']);
            if (toolCalls.isNotEmpty) {
              processLines.add(toolCalls);
            }
          }
          final message = choice['message'];
          if (message is Map) {
            final msgToolCalls = _formatToolCalls(message['tool_calls']);
            if (msgToolCalls.isNotEmpty) {
              processLines.add(msgToolCalls);
            }
          }
        }

        return (
          false,
          ChatStreamUpdate(
            assistantProcess: currentProcessText(),
            assistantThinking: thinkingText.trim(),
            assistantFinal: finalText.trim(),
          ),
        );
      }

      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (_cancelRequested) {
          throw const ChatCancelledException();
        }
        if (line.isEmpty) {
          final (done, update) = handleSseFrame();
          if (update != null) {
            yield update;
          }
          if (done) break;
          continue;
        }
        if (line.startsWith('event:')) {
          currentSseEvent = line.substring(6).trim();
          continue;
        }
        if (line.startsWith('data:')) {
          currentSseData.writeln(line.substring(5).trim());
        }
      }
      if (currentSseData.isNotEmpty) {
        final (_, update) = handleSseFrame();
        if (update != null) {
          yield update;
        }
      }

      if (_cancelRequested) {
        throw const ChatCancelledException();
      }

      if (_cancelRequested) {
        throw const ChatCancelledException();
      }

      yield ChatStreamUpdate(
        assistantProcess: currentProcessText(),
        assistantThinking: thinkingText,
        assistantFinal: finalText,
        done: true,
      );
    } catch (_) {
      if (_cancelRequested) {
        throw const ChatCancelledException();
      }
      rethrow;
    } finally {
      requestClient.close();
      if (identical(_activeStreamingClient, requestClient)) {
        _activeStreamingClient = null;
      }
    }
  }

  String _formatToolCalls(dynamic toolCalls) {
    if (toolCalls is! List || toolCalls.isEmpty) return '';
    final rows = <String>[];
    for (final item in toolCalls) {
      if (item is! Map) continue;
      final fn = item['function'];
      if (fn is Map) {
        final name = (fn['name'] ?? '').toString();
        final args = (fn['arguments'] ?? '').toString();
        final prettyArgs = args.isEmpty ? '' : ' 参数: $args';
        if (name.isNotEmpty) {
          rows.add('工具调用: $name$prettyArgs');
        }
      }
    }
    return rows.join('\n').trim();
  }

  String _extractAnyText(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num || value is bool) return value.toString();

    if (value is List) {
      final parts = <String>[];
      for (final item in value) {
        if (item is String) {
          parts.add(item);
        } else if (item is Map) {
          final text = _extractAnyText(item['text']);
          if (text.isNotEmpty) {
            parts.add(text);
          } else {
            final content = _extractAnyText(item['content']);
            if (content.isNotEmpty) parts.add(content);
          }
        }
      }
      return parts.join();
    }

    if (value is Map) {
      final text = _extractAnyText(value['text']);
      if (text.isNotEmpty) return text;
      return _extractAnyText(value['content']);
    }

    return '';
  }

  String _joinNonEmpty(List<String> parts) {
    return parts.where((s) => s.trim().isNotEmpty).join('\n\n').trim();
  }

  String _extractErrorMessage(String rawBody) {
    try {
      final data = jsonDecode(rawBody);
      if (data is Map<String, dynamic>) {
        final err = data['error'];
        if (err is String && err.isNotEmpty) return err;
        if (err is Map) {
          final msg = err['message'];
          if (msg is String && msg.isNotEmpty) return msg;
          final detail = err['detail'];
          if (detail is String && detail.isNotEmpty) return detail;
        }
        final msg = data['message'];
        if (msg is String && msg.isNotEmpty) return msg;
      }
    } catch (_) {}
    return rawBody;
  }

  void dispose() {
    _activeStreamingClient?.close();
  }
}

const String _systemPrompt =
    '你是 Hermes Agent 在 Android 端的助手。'
    '请直接完成用户任务，并把面向用户的最终结论写清楚。'
    '系统会单独展示工具执行过程与内部思考内容，所以最终答复里不要重复工具日志、过程规划或标签说明。'
    '如果模型支持独立的 reasoning 或 thinking 通道，请把内部思考留在该通道，不要写入最终答复正文。'
    '如果需要访问用户文件，请优先检查 /sdcard、/storage、/storage/emulated/0。'
    '不要在未检查这些路径前直接说无法访问共享存储。';

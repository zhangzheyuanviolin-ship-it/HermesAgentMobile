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

class _SplitOutput {
  final String process;
  final String finalText;

  const _SplitOutput({required this.process, required this.finalText});
}

class _DisplayOutput {
  final String process;
  final String thinking;
  final String finalText;

  const _DisplayOutput({
    required this.process,
    required this.thinking,
    required this.finalText,
  });
}

class ChatService {
  ChatService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
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

    final rawAssistant = StringBuffer();
    final processFromChunks = StringBuffer();
    final thinkingFromChunks = StringBuffer();

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
                processFromChunks.write(line);
                processFromChunks.write('\n');
              }
            }
          } catch (_) {
            // Ignore malformed custom tool events.
          }
          final display = _buildDisplayOutput(
            rawAssistant: rawAssistant.toString(),
            processText: processFromChunks.toString(),
            thinkingText: thinkingFromChunks.toString(),
          );
          return (
            false,
            ChatStreamUpdate(
              assistantProcess: display.process,
              assistantThinking: display.thinking,
              assistantFinal: display.finalText,
            ),
          );
        }

        Map<String, dynamic> data;
        try {
          data = jsonDecode(payload) as Map<String, dynamic>;
        } catch (_) {
          return (false, null);
        }

        if (data['error'] != null) {
          throw Exception(_extractErrorMessage(jsonEncode(data)));
        }

        final choices = data['choices'];
        if (choices is! List || choices.isEmpty) return (false, null);
        final choice = choices.first;
        if (choice is! Map) return (false, null);

        final delta = choice['delta'];
        if (delta is Map) {
          final piece = _extractAnyText(delta['content']);
          if (piece.isNotEmpty) {
            rawAssistant.write(piece);
          }

          final reasoning = _joinNonEmpty([
            _extractAnyText(delta['reasoning']),
            _extractAnyText(delta['reasoning_content']),
            _extractAnyText(delta['thinking']),
          ]);
          if (reasoning.isNotEmpty) {
            thinkingFromChunks.write(reasoning);
            thinkingFromChunks.write('\n');
          }

          final toolCalls = _formatToolCalls(delta['tool_calls']);
          if (toolCalls.isNotEmpty) {
            processFromChunks.write(toolCalls);
            processFromChunks.write('\n');
          }
        }

        final message = choice['message'];
        if (message is Map) {
          final msgPiece = _extractAnyText(message['content']);
          if (msgPiece.isNotEmpty) {
            rawAssistant.write(msgPiece);
          }
          final msgToolCalls = _formatToolCalls(message['tool_calls']);
          if (msgToolCalls.isNotEmpty) {
            processFromChunks.write(msgToolCalls);
            processFromChunks.write('\n');
          }
        }

        final display = _buildDisplayOutput(
          rawAssistant: rawAssistant.toString(),
          processText: processFromChunks.toString(),
          thinkingText: thinkingFromChunks.toString(),
        );

        return (
          false,
          ChatStreamUpdate(
            assistantProcess: display.process,
            assistantThinking: display.thinking,
            assistantFinal: display.finalText,
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

      var display = _buildDisplayOutput(
        rawAssistant: rawAssistant.toString(),
        processText: processFromChunks.toString(),
        thinkingText: thinkingFromChunks.toString(),
      );
      var processText = display.process;
      var thinkingText = display.thinking;
      var finalText = display.finalText;

      // Fallback: some models stream only process/tool chunks and leave final empty.
      if (finalText.isEmpty) {
        final nonStreamText = await _fetchNonStream(
          messages,
          model,
          client: requestClient,
        );
        display = _buildDisplayOutput(
          rawAssistant: nonStreamText,
          processText: processFromChunks.toString(),
          thinkingText: thinkingFromChunks.toString(),
        );
        processText = display.process;
        thinkingText = display.thinking;
        finalText = display.finalText;
      }

      if (_cancelRequested) {
        throw const ChatCancelledException();
      }

      yield ChatStreamUpdate(
        assistantProcess: processText,
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

  Future<String> _fetchNonStream(
    List<Map<String, String>> messages,
    String model,
    {http.Client? client}
  ) async {
    final response = await (client ?? _client).post(
      Uri.parse('${AppConstants.apiServerUrl}/v1/chat/completions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': model,
        'stream': false,
        'messages': messages,
      }),
    );

    if (response.statusCode >= 400) {
      throw Exception('HTTP ${response.statusCode}: ${_extractErrorMessage(response.body)}');
    }

    final data = jsonDecode(response.body);
    if (data is Map<String, dynamic> && data['error'] != null) {
      throw Exception(_extractErrorMessage(response.body));
    }

    if (data is Map<String, dynamic>) {
      final choices = data['choices'];
      if (choices is List && choices.isNotEmpty && choices.first is Map) {
        final message = (choices.first as Map)['message'];
        if (message is Map) {
          final content = _extractAnyText(message['content']);
          if (content.isNotEmpty) return content;
        }
      }
    }

    return '';
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

  _DisplayOutput _buildDisplayOutput({
    required String rawAssistant,
    required String processText,
    required String thinkingText,
  }) {
    final rawSplit = _splitTaggedOutput(rawAssistant);
    final thinkingSplit = _splitThinkingOutput(thinkingText);

    var rawFinal = rawSplit.finalText.trim();
    if (rawFinal.isEmpty && rawSplit.process.trim().isEmpty) {
      rawFinal = rawAssistant.trim();
    }

    return _DisplayOutput(
      process: processText.trim(),
      thinking: _joinNonEmpty([
        thinkingSplit.process,
        rawSplit.process,
      ]),
      finalText: _joinUniqueNonEmpty([
        thinkingSplit.finalText,
        rawFinal,
      ]),
    );
  }

  _SplitOutput _splitTaggedOutput(String raw) {
    final normalized = _decodeTagEntities(raw);
    final structured = _splitStructuredTaggedOutput(normalized);
    if (structured.finalText.isNotEmpty || structured.process.isNotEmpty) {
      return structured;
    }

    final cleaned = _removeTagWrappers(normalized).trim();
    final heuristic = _splitHeuristicOutput(cleaned);
    return _SplitOutput(process: heuristic.process, finalText: heuristic.finalText);
  }

  _SplitOutput _splitThinkingOutput(String raw) {
    final normalized = _removeTagWrappers(_decodeTagEntities(raw)).trim();
    if (normalized.isEmpty) {
      return const _SplitOutput(process: '', finalText: '');
    }

    final blocks = normalized
        .split(RegExp(r'\n\s*\n+'))
        .map((b) => b.trim())
        .where((b) => b.isNotEmpty)
        .toList();
    if (blocks.isEmpty) {
      return const _SplitOutput(process: '', finalText: '');
    }

    for (var i = 0; i < blocks.length; i++) {
      if (_looksLikeFinalBlock(blocks[i])) {
        final thinking = blocks.take(i).join('\n\n').trim();
        final finalText = blocks.skip(i).join('\n\n').trim();
        return _SplitOutput(process: thinking, finalText: finalText);
      }
    }

    return _SplitOutput(process: normalized, finalText: '');
  }

  _SplitOutput _splitHeuristicOutput(String raw) {
    final normalized = raw.replaceAll('\r\n', '\n').trim();
    if (normalized.isEmpty) {
      return const _SplitOutput(process: '', finalText: '');
    }

    final blocks = normalized
        .split(RegExp(r'\n\s*\n+'))
        .map((b) => b.trim())
        .where((b) => b.isNotEmpty)
        .toList();

    if (blocks.length < 2) {
      return _splitLineHeuristicOutput(normalized);
    }

    var pivot = -1;
    for (var i = 0; i < blocks.length; i++) {
      if (_looksLikeFinalBlock(blocks[i])) {
        pivot = i;
        break;
      }
    }

    if (pivot == -1) {
      var leadingProcessCount = 0;
      for (final block in blocks) {
        if (_looksLikeProcessBlock(block)) {
          leadingProcessCount += 1;
        } else {
          break;
        }
      }

      if (leadingProcessCount > 0 && leadingProcessCount < blocks.length) {
        final remaining = blocks.skip(leadingProcessCount).join('\n\n');
        if (leadingProcessCount >= 2 || _containsFinalSignal(remaining)) {
          pivot = leadingProcessCount;
        }
      }
    }

    if (pivot <= 0 || pivot >= blocks.length) {
      return _splitLineHeuristicOutput(normalized);
    }

    final process = blocks.take(pivot).join('\n\n').trim();
    final finalText = blocks.skip(pivot).join('\n\n').trim();
    if (finalText.isEmpty) {
      return _splitLineHeuristicOutput(normalized);
    }
    return _SplitOutput(process: process, finalText: finalText);
  }

  _SplitOutput _splitLineHeuristicOutput(String raw) {
    final lines = raw.replaceAll('\r\n', '\n').split('\n');
    if (lines.isEmpty) {
      return const _SplitOutput(process: '', finalText: '');
    }

    final processLines = <String>[];
    final finalLines = <String>[];
    var inFinal = false;
    for (final original in lines) {
      final line = original.trimRight();
      final lineTrim = line.trim();
      if (lineTrim.isEmpty) {
        if (inFinal) {
          finalLines.add(line);
        } else if (processLines.isNotEmpty) {
          processLines.add(line);
        }
        continue;
      }

      if (!inFinal && _looksLikeFinalBlock(lineTrim)) {
        inFinal = true;
      }

      if (!inFinal && _looksLikeProcessBlock(lineTrim)) {
        processLines.add(line);
        continue;
      }

      if (inFinal) {
        finalLines.add(line);
      } else {
        // Once a non-process content appears, treat all following lines as final.
        inFinal = true;
        finalLines.add(line);
      }
    }

    final process = processLines.join('\n').trim();
    final finalText = finalLines.join('\n').trim();
    if (finalText.isEmpty) {
      return _SplitOutput(process: '', finalText: raw.trim());
    }
    return _SplitOutput(process: process, finalText: finalText);
  }

  _SplitOutput _splitStructuredTaggedOutput(String raw) {
    final processOpen = RegExp(r'<assistant_process\b[^>]*>', caseSensitive: false);
    final processClose = RegExp(r'</assistant_process\s*>', caseSensitive: false);
    final finalOpen = RegExp(r'<assistant_final\b[^>]*>', caseSensitive: false);
    final finalClose = RegExp(r'</assistant_final\s*>', caseSensitive: false);
    final thinkOpen = RegExp(r'<(?:think|thinking|reasoning|thought)\b[^>]*>', caseSensitive: false);
    final thinkClose = RegExp(r'</(?:think|thinking|reasoning|thought)\s*>', caseSensitive: false);

    final pOpen = processOpen.firstMatch(raw);
    final pClose = processClose.firstMatch(raw);
    final fOpen = finalOpen.firstMatch(raw);
    final fClose = finalClose.firstMatch(raw);

    String process = '';
    String finalText = '';

    if (pOpen != null) {
      final start = pOpen.end;
      var end = raw.length;
      if (pClose != null && pClose.start >= start) {
        end = pClose.start;
      } else if (fOpen != null && fOpen.start >= start) {
        end = fOpen.start;
      }
      if (end >= start) {
        process = raw.substring(start, end).trim();
      }
    }

    if (fOpen != null) {
      final start = fOpen.end;
      var end = raw.length;
      if (fClose != null && fClose.start >= start) {
        end = fClose.start;
      }
      if (end >= start) {
        finalText = raw.substring(start, end).trim();
      }
    }

    final thinkMatches = RegExp(
      r'<(?:think|thinking|reasoning|thought)\b[^>]*>([\s\S]*?)(?:</(?:think|thinking|reasoning|thought)\s*>|$)',
      caseSensitive: false,
    ).allMatches(raw);
    final thinkProcess = thinkMatches
        .map((m) => (m.group(1) ?? '').trim())
        .where((s) => s.isNotEmpty)
        .join('\n\n')
        .trim();
    if (thinkProcess.isNotEmpty) {
      process = _joinNonEmpty([process, thinkProcess]);
    }

    if (finalText.isEmpty && (pOpen != null || fOpen != null || thinkOpen.hasMatch(raw))) {
      var cleaned = raw;
      cleaned = cleaned.replaceAll(processOpen, '');
      cleaned = cleaned.replaceAll(processClose, '');
      cleaned = cleaned.replaceAll(finalOpen, '');
      cleaned = cleaned.replaceAll(finalClose, '');
      cleaned = cleaned.replaceAll(thinkOpen, '');
      cleaned = cleaned.replaceAll(thinkClose, '');
      finalText = cleaned.trim();
    }

    return _SplitOutput(
      process: process.trim(),
      finalText: finalText.trim(),
    );
  }

  String _removeTagWrappers(String raw) {
    var cleaned = raw;
    final tags = <RegExp>[
      RegExp(r'</?assistant_process\b[^>]*>', caseSensitive: false),
      RegExp(r'</?assistant_final\b[^>]*>', caseSensitive: false),
      RegExp(r'</?(?:think|thinking|reasoning|thought)\b[^>]*>', caseSensitive: false),
    ];
    for (final tag in tags) {
      cleaned = cleaned.replaceAll(tag, '');
    }
    return cleaned;
  }

  String _decodeTagEntities(String raw) {
    return raw
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
  }

  bool _looksLikeProcessBlock(String block) {
    final firstLine = _normalizeLeadLine(block.split('\n').first);
    const leadWords = [
      'the user wants',
      'let me',
      'i will',
      'i need to',
      'i should',
      'i am going to',
      "i'm going to",
      'i can see',
      'now i can',
      'now i have',
      'now i will',
      'first',
      'next',
      'then',
      'we need to',
      "i'll",
      '好的，我来',
      '我来操作',
      '我先',
      '我来检查',
      '我先检查',
      '我来加载',
      '先',
      '先查看',
      '先读取',
      '先检查',
      '现在',
      '现在执行',
      '接下来',
      '然后',
      '随后',
      '让我',
      '我将',
      '我会',
      '正在',
      '开始',
      '确认',
      '创建',
      '读取',
      '删除',
      '执行',
      '尝试',
    ];
    for (final w in leadWords) {
      if (firstLine.toLowerCase().startsWith(w.toLowerCase())) return true;
    }
    return block.contains('工具调用:');
  }

  bool _looksLikeFinalBlock(String block) {
    final firstLine = _normalizeLeadLine(block.split('\n').first);
    const cnStarts = [
      '以下是',
      '这是',
      '最终',
      '结论',
      '总结',
      '汇报',
      '报告',
      '结果',
      '答复',
      '回复',
      '输出',
      '建议',
      '测试报告',
      '测试结论',
      '环境详细报告',
      '详细报告',
      '完整汇报',
      '检查结果',
      '检查结果汇总',
      '总体来看',
    ];
    const enStarts = [
      'here is',
      "here's",
      'final answer',
      'summary',
      'in summary',
      'result',
      'results',
      'report',
      'overall',
      'to summarize',
    ];
    for (final word in cnStarts) {
      if (firstLine.startsWith(word)) return true;
    }
    final lowerFirstLine = firstLine.toLowerCase();
    for (final word in enStarts) {
      if (lowerFirstLine.startsWith(word)) return true;
    }
    if (block.contains('测试结论')) return true;
    if (block.contains('环境详细报告')) return true;
    if (block.contains('总体来看')) return true;
    if (block.contains('| 步骤 |')) return true;
    if (block.contains('|------|')) return true;
    if (block.contains('| 类别 |')) return true;
    if (block.contains('| 目标 |')) return true;
    if (block.contains('### ')) {
      if (block.contains('报告') || block.contains('汇报') || block.contains('总结') || block.contains('结果')) {
        return true;
      }
    }
    return false;
  }

  bool _containsFinalSignal(String text) {
    final signal = RegExp(r'(最终|结论|总结|报告|结果|建议|因此|综上|完成|summary|report|overall|final answer)', caseSensitive: false);
    return signal.hasMatch(text);
  }

  String _joinNonEmpty(List<String> parts) {
    return parts.where((s) => s.trim().isNotEmpty).join('\n\n').trim();
  }

  String _joinUniqueNonEmpty(List<String> parts) {
    final unique = <String>[];
    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;

      var merged = false;
      for (var i = 0; i < unique.length; i++) {
        final existing = unique[i];
        if (existing == trimmed || existing.contains(trimmed)) {
          merged = true;
          break;
        }
        if (trimmed.contains(existing)) {
          unique[i] = trimmed;
          merged = true;
          break;
        }
      }
      if (!merged) {
        unique.add(trimmed);
      }
    }
    return unique.join('\n\n').trim();
  }

  String _normalizeLeadLine(String rawLine) {
    var line = rawLine.trimLeft();
    line = line.replaceFirst(RegExp(r'^[#>\-\*\d\.\)\(\[\]\s]+'), '');
    line = line.replaceFirst(RegExp(r'^[^A-Za-z0-9\u4e00-\u9fff]+'), '');
    return line.trimLeft();
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
    _client.close();
  }
}

const String _systemPrompt =
    '你是 Hermes Agent 在 Android 端的助手。'
    '你必须严格按以下标签输出，且仅输出这两个区块：'
    '<assistant_process>...</assistant_process>'
    '<assistant_final>...</assistant_final>。'
    '在 assistant_process 中写执行过程、规划、工具动作；'
    '在 assistant_final 中只写最终答复和结论，禁止出现“先/然后/正在/我来操作”等过程描述。'
    '当需要执行 Android 系统级命令时，必须使用 system-shell <command>。'
    '禁止直接猜测或调用 shizuku、rish 等命令名。'
    '执行系统命令前优先使用 system-shell-status 检查 installed/running/granted/enabled。'
    '如果 system-shell 返回错误，先读取 error_code 再降级或重试。'
    '对于 ubuntu-shell、ubuntu-status 或 ANYCLAW_UBUNTU_BIN 相关命令，直接在本地 shell 执行，不要再套 system-shell。'
    '如果需要访问用户文件，请优先检查 /sdcard、/storage、/storage/emulated/0。'
    '不要在未检查这些路径前直接说无法访问共享存储。';

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../models/chat_session_models.dart';

class ChatStreamUpdate {
  final String assistantProcess;
  final String assistantFinal;
  final bool done;

  const ChatStreamUpdate({
    required this.assistantProcess,
    required this.assistantFinal,
    this.done = false,
  });
}

class _SplitOutput {
  final String process;
  final String finalText;

  const _SplitOutput({required this.process, required this.finalText});
}

class ChatService {
  ChatService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Stream<ChatStreamUpdate> streamChat({
    required List<ChatHistoryMessage> history,
    required String userPrompt,
    required String model,
  }) async* {
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

    final response = await _client.send(request);
    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      throw Exception('HTTP ${response.statusCode}: ${_extractErrorMessage(body)}');
    }

    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') break;

      Map<String, dynamic> data;
      try {
        data = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }

      if (data['error'] != null) {
        throw Exception(_extractErrorMessage(jsonEncode(data)));
      }

      final choices = data['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final choice = choices.first;
      if (choice is! Map) continue;

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
          processFromChunks.write(reasoning);
          processFromChunks.write('\n');
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

      final split = _splitTaggedOutput(rawAssistant.toString());
      final processText = _joinNonEmpty([
        processFromChunks.toString().trim(),
        split.process,
      ]);
      final finalText = split.finalText.isNotEmpty
          ? split.finalText
          : rawAssistant.toString().trim();

      yield ChatStreamUpdate(
        assistantProcess: processText,
        assistantFinal: finalText,
      );
    }

    var split = _splitTaggedOutput(rawAssistant.toString());
    var processText = _joinNonEmpty([
      processFromChunks.toString().trim(),
      split.process,
    ]);
    var finalText = split.finalText.isNotEmpty
        ? split.finalText
        : rawAssistant.toString().trim();

    // Fallback: some models stream only process/tool chunks and leave final empty.
    if (finalText.isEmpty) {
      final nonStreamText = await _fetchNonStream(messages, model);
      split = _splitTaggedOutput(nonStreamText);
      if (split.process.isNotEmpty) {
        processText = _joinNonEmpty([processText, split.process]);
      }
      if (split.finalText.isNotEmpty) {
        finalText = split.finalText;
      } else {
        finalText = nonStreamText.trim();
      }
    }

    yield ChatStreamUpdate(
      assistantProcess: processText,
      assistantFinal: finalText,
      done: true,
    );
  }

  Future<String> _fetchNonStream(
    List<Map<String, String>> messages,
    String model,
  ) async {
    final response = await _client.post(
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

  _SplitOutput _splitTaggedOutput(String raw) {
    final processRegex = RegExp(r'<assistant_process>([\s\S]*?)</assistant_process>');
    final finalRegex = RegExp(r'<assistant_final>([\s\S]*?)</assistant_final>');

    final process = processRegex
        .allMatches(raw)
        .map((m) => (m.group(1) ?? '').trim())
        .where((s) => s.isNotEmpty)
        .join('\n\n')
        .trim();

    final finalText = finalRegex
        .allMatches(raw)
        .map((m) => (m.group(1) ?? '').trim())
        .where((s) => s.isNotEmpty)
        .join('\n\n')
        .trim();

    if (finalText.isNotEmpty) {
      return _SplitOutput(process: process, finalText: finalText);
    }

    var cleaned = raw.replaceAll(processRegex, '').trim();
    cleaned = cleaned.replaceAll(finalRegex, '').trim();
    final heuristic = _splitHeuristicOutput(cleaned);
    return _SplitOutput(
      process: _joinNonEmpty([process, heuristic.process]),
      finalText: heuristic.finalText,
    );
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
      return _SplitOutput(process: '', finalText: normalized);
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
      return _SplitOutput(process: '', finalText: normalized);
    }

    final process = blocks.take(pivot).join('\n\n').trim();
    final finalText = blocks.skip(pivot).join('\n\n').trim();
    if (finalText.isEmpty) {
      return _SplitOutput(process: '', finalText: normalized);
    }
    return _SplitOutput(process: process, finalText: finalText);
  }

  bool _looksLikeProcessBlock(String block) {
    final firstLine = block.split('\n').first.trimLeft();
    const leadWords = [
      '好的，我来',
      '我来操作',
      '我先',
      '先',
      '现在',
      '接下来',
      '然后',
      '随后',
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
      if (firstLine.startsWith(w)) return true;
    }
    return block.contains('工具调用:');
  }

  bool _looksLikeFinalBlock(String block) {
    final firstLine = block.split('\n').first.trimLeft();
    final heading = RegExp(r'^(#{1,6}\s*)?(最终|结论|总结|报告|结果|答复|回复|输出|建议|测试报告|测试结论)');
    if (heading.hasMatch(firstLine)) return true;
    if (block.contains('测试结论')) return true;
    if (block.contains('| 步骤 |')) return true;
    if (block.contains('|------|')) return true;
    return false;
  }

  bool _containsFinalSignal(String text) {
    final signal = RegExp(r'(最终|结论|总结|报告|结果|建议|因此|综上|完成)');
    return signal.hasMatch(text);
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
    '如果需要访问用户文件，请优先检查 /sdcard、/storage、/storage/emulated/0。'
    '不要在未检查这些路径前直接说无法访问共享存储。';

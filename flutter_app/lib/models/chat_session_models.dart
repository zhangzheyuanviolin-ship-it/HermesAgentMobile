class ChatTurn {
  final String id;
  final String userPrompt;
  final String assistantProcess;
  final String assistantFinal;
  final bool isStreaming;
  final String? error;

  const ChatTurn({
    required this.id,
    required this.userPrompt,
    this.assistantProcess = '',
    this.assistantFinal = '',
    this.isStreaming = false,
    this.error,
  });

  ChatTurn copyWith({
    String? assistantProcess,
    String? assistantFinal,
    bool? isStreaming,
    String? error,
    bool clearError = false,
  }) {
    return ChatTurn(
      id: id,
      userPrompt: userPrompt,
      assistantProcess: assistantProcess ?? this.assistantProcess,
      assistantFinal: assistantFinal ?? this.assistantFinal,
      isStreaming: isStreaming ?? this.isStreaming,
      error: clearError ? null : (error ?? this.error),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userPrompt': userPrompt,
      'assistantProcess': assistantProcess,
      'assistantFinal': assistantFinal,
      'isStreaming': isStreaming,
      'error': error,
    };
  }

  factory ChatTurn.fromJson(Map<String, dynamic> json) {
    return ChatTurn(
      id: (json['id'] ?? '').toString(),
      userPrompt: (json['userPrompt'] ?? '').toString(),
      assistantProcess: (json['assistantProcess'] ?? '').toString(),
      assistantFinal: (json['assistantFinal'] ?? '').toString(),
      isStreaming: json['isStreaming'] == true,
      error: json['error']?.toString(),
    );
  }
}

class ChatSession {
  final String id;
  final String title;
  final bool isTitleManuallySet;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ChatTurn> turns;

  const ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.isTitleManuallySet = false,
    this.turns = const [],
  });

  ChatSession copyWith({
    String? title,
    bool? isTitleManuallySet,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatTurn>? turns,
  }) {
    return ChatSession(
      id: id,
      title: title ?? this.title,
      isTitleManuallySet: isTitleManuallySet ?? this.isTitleManuallySet,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      turns: turns ?? this.turns,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'isTitleManuallySet': isTitleManuallySet,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      'turns': turns.map((t) => t.toJson()).toList(),
    };
  }

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    final turnsRaw = json['turns'];
    final turns = <ChatTurn>[];
    if (turnsRaw is List) {
      for (final item in turnsRaw) {
        if (item is Map<String, dynamic>) {
          turns.add(ChatTurn.fromJson(item));
        } else if (item is Map) {
          turns.add(ChatTurn.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    final now = DateTime.now().toUtc();
    final createdAt = DateTime.tryParse((json['createdAt'] ?? '').toString())?.toUtc() ?? now;
    final updatedAt = DateTime.tryParse((json['updatedAt'] ?? '').toString())?.toUtc() ?? createdAt;

    return ChatSession(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '新聊天').toString(),
      isTitleManuallySet: json['isTitleManuallySet'] == true,
      createdAt: createdAt,
      updatedAt: updatedAt,
      turns: turns,
    );
  }
}

class ChatStoreData {
  final List<ChatSession> sessions;
  final String? lastSessionId;

  const ChatStoreData({
    this.sessions = const [],
    this.lastSessionId,
  });
}

class ChatHistoryMessage {
  final String role;
  final String content;

  const ChatHistoryMessage({required this.role, required this.content});
}

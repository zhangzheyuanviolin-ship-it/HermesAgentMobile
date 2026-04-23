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
}

class ChatHistoryMessage {
  final String role;
  final String content;

  const ChatHistoryMessage({required this.role, required this.content});
}

enum MessageRole { user, assistant, tool }

enum MessageStatus { sending, done, error }

/// App-level chat message (UI layer).
/// Not to be confused with Cactus's ChatMessage (LLM conversation format).
class AppMessage {
  final String id;
  final MessageRole role;
  final String content;
  final MessageStatus status;
  final String? toolName;     // set when role == tool
  final DateTime timestamp;

  const AppMessage({
    required this.id,
    required this.role,
    required this.content,
    this.status = MessageStatus.done,
    this.toolName,
    required this.timestamp,
  });

  AppMessage copyWith({
    String? content,
    MessageStatus? status,
  }) =>
      AppMessage(
        id: id,
        role: role,
        content: content ?? this.content,
        status: status ?? this.status,
        toolName: toolName,
        timestamp: timestamp,
      );

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;
}

enum MessageRole { user, assistant, tool }

enum MessageStatus { sending, done, error }

class ChatMessage {
  final String id;
  final MessageRole role;
  final String content;
  final MessageStatus status;
  final String? toolName;     // set when role == tool
  final DateTime timestamp;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.status = MessageStatus.done,
    this.toolName,
    required this.timestamp,
  });

  ChatMessage copyWith({
    String? content,
    MessageStatus? status,
  }) =>
      ChatMessage(
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

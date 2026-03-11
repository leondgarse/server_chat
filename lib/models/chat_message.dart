class ChatMessage {
  final String text;
  final bool isUser;
  // Optional flag to indicate if this is a special Claude command that needs buttons
  final bool isClaudePrompt;
  final List<String> availableActions;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.isClaudePrompt = false,
    this.availableActions = const [],
  });
}

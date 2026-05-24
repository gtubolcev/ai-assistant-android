import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import '../tools/caldav_tool.dart';
import '../tools/web_fetch_tool.dart';

/// All available tools — passed to Cactus for tool calling.
final _allTools = <CactusTool>[
  webFetchTool,
  listEventsTool,
  createEventTool,
  deleteEventTool,
];

/// System prompt — tells the model its capabilities and persona.
const _systemPrompt =
    'You are a helpful personal AI assistant running entirely on the user\'s '
    'device. You have access to tools: web_fetch (fetch any URL), '
    'caldav_list_events, caldav_create_event, caldav_delete_event. '
    'Always respond in the same language the user uses. '
    'Be concise — you run on a 1.2B parameter model.';

class ChatProvider extends ChangeNotifier {
  // ── Public state ───────────────────────────────────────────────────────────

  final List<AppMessage> messages = [];
  bool isLoading = false;
  bool isModelReady = false;
  String statusText = 'Загрузка модели…';
  String? errorText;

  // ── Internals ─────────────────────────────────────────────────────────────

  CactusLM? _lm;
  CalDavExecutor? _calDav;

  /// Conversation history passed to Cactus (system + alternating user/assistant).
  final List<ChatMessage> _history = [
    ChatMessage(role: 'system', content: _systemPrompt),
  ];

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> init() async {
    try {
      statusText = 'Загрузка модели LFM2.5-1.2B…';
      notifyListeners();

      _lm = CactusLM();
      await _lm!.downloadModel(model: 'lfm2.5-1.2b');
      await _lm!.initializeModel(
        params: CactusInitParams(contextSize: 4096),
      );

      // Load CalDAV config from SharedPreferences (set via settings screen).
      final prefs = await SharedPreferences.getInstance();
      final caldavUrl = prefs.getString('caldav_url');
      final caldavUser = prefs.getString('caldav_user');
      final caldavPass = prefs.getString('caldav_pass');
      final caldavPath = prefs.getString('caldav_path') ?? '/calendars/';

      if (caldavUrl != null && caldavUser != null && caldavPass != null) {
        _calDav = CalDavExecutor(CalDavConfig(
          serverUrl: caldavUrl,
          username: caldavUser,
          password: caldavPass,
          calendarPath: caldavPath,
        ));
      }

      isModelReady = true;
      statusText = 'Модель готова';
    } catch (e) {
      errorText = 'Ошибка инициализации: $e';
      statusText = 'Ошибка';
    }

    notifyListeners();
  }

  // ── Send message ──────────────────────────────────────────────────────────

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty || isLoading || !isModelReady) return;

    // Add user message to UI.
    _addMessage(AppMessage(
      id: _uid(),
      role: MessageRole.user,
      content: text.trim(),
      timestamp: DateTime.now(),
    ));

    // Add user turn to LLM history.
    _history.add(ChatMessage(role: 'user', content: text.trim()));

    // Placeholder assistant message (will be updated during streaming).
    final assistantId = _uid();
    _addMessage(AppMessage(
      id: assistantId,
      role: MessageRole.assistant,
      content: '',
      status: MessageStatus.sending,
      timestamp: DateTime.now(),
    ));

    isLoading = true;
    notifyListeners();

    try {
      await _runAgentLoop(assistantId);
    } catch (e) {
      _updateMessage(assistantId, 'Ошибка: $e', MessageStatus.error);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  // ── Agent loop ────────────────────────────────────────────────────────────

  Future<void> _runAgentLoop(String assistantId) async {
    final lm = _lm!;

    // ── First pass: streaming to fill UI in real-time ──────────────────────
    final streamResult = await lm.generateCompletionStream(
      messages: List.from(_history),
      params: CactusCompletionParams(
        tools: _allTools,
        temperature: 0.7,
        maxTokens: 512,
      ),
    );

    final buffer = StringBuffer();
    await for (final chunk in streamResult.stream) {
      buffer.write(chunk);
      _updateMessage(assistantId, buffer.toString(), MessageStatus.sending);
    }

    // Get final result (includes parsed tool calls).
    final finalResult = await streamResult.result;

    if (finalResult.toolCalls.isNotEmpty) {
      // ── Tool call round ────────────────────────────────────────────────
      // Add assistant's (possibly partial) thinking text to history.
      if (buffer.isNotEmpty) {
        _history.add(ChatMessage(role: 'assistant', content: buffer.toString()));
      }

      // Execute all tool calls.
      final toolResults = <String>[];
      for (final call in finalResult.toolCalls) {
        _updateMessage(
          assistantId,
          '${buffer.isEmpty ? '' : '${buffer.toString()}\n\n'}'
          '🔧 ${call.name}…',
          MessageStatus.sending,
        );

        final result = await _executeTool(call);
        toolResults.add('[${ call.name}] $result');

        // Add tool result message to history.
        _history.add(ChatMessage(
          role: 'tool',
          content: result,
        ));
      }

      // ── Second pass: final answer after tools ──────────────────────────
      final followUp = await lm.generateCompletion(
        messages: List.from(_history),
        params: CactusCompletionParams(temperature: 0.7, maxTokens: 512),
      );

      final finalText = followUp.response;
      _history.add(ChatMessage(role: 'assistant', content: finalText));
      _updateMessage(assistantId, finalText, MessageStatus.done);
    } else {
      // ── No tool calls: use streamed text directly ──────────────────────
      final text = buffer.toString();
      _history.add(ChatMessage(role: 'assistant', content: text));
      _updateMessage(assistantId, text, MessageStatus.done);
    }
  }

  // ── Tool executor ─────────────────────────────────────────────────────────

  Future<String> _executeTool(ToolCall call) async {
    switch (call.name) {
      case 'web_fetch':
        return executeWebFetch(call.arguments);

      case 'caldav_list_events':
      case 'caldav_create_event':
      case 'caldav_delete_event':
        if (_calDav == null) {
          return 'CalDAV не настроен. Укажи адрес сервера в настройках.';
        }
        return _calDav!.execute(call.name, call.arguments);

      default:
        return 'Unknown tool: ${call.name}';
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _addMessage(AppMessage msg) {
    messages.add(msg);
    notifyListeners();
  }

  void _updateMessage(String id, String content, MessageStatus status) {
    final i = messages.indexWhere((m) => m.id == id);
    if (i == -1) return;
    messages[i] = messages[i].copyWith(content: content, status: status);
    notifyListeners();
  }

  String _uid() => DateTime.now().microsecondsSinceEpoch.toString();

  // ── Settings ──────────────────────────────────────────────────────────────

  Future<void> saveCalDavConfig({
    required String url,
    required String user,
    required String pass,
    required String path,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('caldav_url', url);
    await prefs.setString('caldav_user', user);
    await prefs.setString('caldav_pass', pass);
    await prefs.setString('caldav_path', path);

    _calDav = CalDavExecutor(CalDavConfig(
      serverUrl: url,
      username: user,
      password: pass,
      calendarPath: path,
    ));
    notifyListeners();
  }

  @override
  void dispose() {
    _lm?.unload();
    _lm = null;
    super.dispose();
  }
}

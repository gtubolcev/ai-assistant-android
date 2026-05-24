import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:mcp_llm/mcp_llm.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import '../tools/caldav_tool.dart';
import '../tools/web_fetch_tool.dart';
import 'cactus_llm_provider.dart';

/// All available tools — registered both in Cactus and in the executor map.
final _toolDefs = [
  webFetchToolDef,
  listEventsTool,
  createEventTool,
  deleteEventTool,
];

class ChatProvider extends ChangeNotifier {
  // ── State ──────────────────────────────────────────────────────────────────

  final List<ChatMessage> messages = [];
  bool isLoading = false;
  bool isModelReady = false;
  String statusText = 'Загрузка модели…';
  String? errorText;

  // ── Internals ─────────────────────────────────────────────────────────────

  CactusLlmProvider? _localProvider;
  CalDavExecutor? _calDav;
  bool _useCloud = false;

  // LLM message history passed to the model (system + turns).
  final List<LlmMessage> _history = [
    LlmMessage.system(
      'You are a helpful personal AI assistant running entirely on the user\'s '
      'device. You have access to tools: web_fetch (fetch any URL), '
      'caldav_list_events, caldav_create_event, caldav_delete_event. '
      'Always respond in the same language the user uses. '
      'Be concise — you run on a 1.2B parameter model.',
    ),
  ];

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> init() async {
    try {
      _localProvider = CactusLlmProvider(
        modelId: 'lfm2.5-1.2b',
        contextLength: 4096,
      );

      statusText = 'Загрузка модели LFM2.5-1.2B…';
      notifyListeners();

      await _localProvider!.initialize(LlmConfiguration());

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

    // Check connectivity once per message for cloud fallback decision.
    // connectivity_plus 6.x returns List<ConnectivityResult>.
    final connectivityResults = await Connectivity().checkConnectivity();
    _useCloud = connectivityResults.any((r) => r != ConnectivityResult.none);

    // Add user message to UI.
    _addMessage(ChatMessage(
      id: _uid(),
      role: MessageRole.user,
      content: text.trim(),
      timestamp: DateTime.now(),
    ));

    // Add user turn to LLM history.
    _history.add(LlmMessage.user(text.trim()));

    // Add placeholder assistant message (streaming).
    final assistantId = _uid();
    _addMessage(ChatMessage(
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

  // ── Agent loop (supports one round of tool calls) ─────────────────────────

  Future<void> _runAgentLoop(String assistantId) async {
    final provider = _localProvider!;

    final request = LlmRequest(
      prompt: '',          // prompt is already in _history
      history: List.from(_history),
      parameters: {
        'tools': _toolDefs,
        'temperature': 0.7,
        'max_tokens': 512,
      },
    );

    // First pass: stream response to UI.
    final buffer = StringBuffer();
    await for (final chunk in provider.streamComplete(request)) {
      if (chunk.textChunk.isNotEmpty) {
        buffer.write(chunk.textChunk);
        _updateMessage(assistantId, buffer.toString(), MessageStatus.sending);
      }
    }

    String finalText = buffer.toString();

    // Second pass: check for tool calls in metadata via non-streaming complete.
    // (Streaming doesn't return tool call metadata; we do a second pass only
    //  if the streamed text looks like it contains a tool call marker.)
    if (_looksLikeToolCall(finalText)) {
      final result = await provider.complete(request);

      if (provider.hasToolCallMetadata(result.metadata)) {
        final toolCall = provider.extractToolCallFromMetadata(result.metadata);
        if (toolCall != null) {
          // Show "calling tool…" in UI.
          _updateMessage(
            assistantId,
            '🔧 Вызываю инструмент: ${toolCall.name}…',
            MessageStatus.sending,
          );

          final toolResult = await _executeTool(toolCall);

          // Add tool result to history and do a final completion.
          _history.add(LlmMessage(
            role: 'tool',
            content: toolResult,
            metadata: {'tool_use_id': toolCall.id ?? toolCall.name},
          ));

          final finalRequest = LlmRequest(
            prompt: '',
            history: List.from(_history),
            parameters: {'temperature': 0.7, 'max_tokens': 512},
          );

          final finalResult = await provider.complete(finalRequest);
          finalText = finalResult.text;
          _history.add(LlmMessage.assistant(finalText));
        }
      } else {
        _history.add(LlmMessage.assistant(finalText));
      }
    } else {
      _history.add(LlmMessage.assistant(finalText));
    }

    _updateMessage(assistantId, finalText, MessageStatus.done);
  }

  // ── Tool executor ─────────────────────────────────────────────────────────

  Future<String> _executeTool(LlmToolCall call) async {
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

  bool _looksLikeToolCall(String text) =>
      text.contains('<|tool_call_start|>') ||
      text.contains('"name"') && text.contains('"arguments"');

  void _addMessage(ChatMessage msg) {
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
    _localProvider?.close();
    super.dispose();
  }
}

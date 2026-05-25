import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import '../tools/mcp_bridge.dart';
import '../tools/web_fetch_tool.dart';

/// System prompt — tells the model its capabilities and persona.
const _systemPrompt =
    'You are a helpful personal AI assistant running entirely on the user\'s '
    'device. You have access to tools: '
    'web_fetch (fetch any URL and return its content), '
    'and a set of calendar/contacts/tasks tools via CalDAV (list, create, update, '
    'delete events, contacts, todos). '
    'Always respond in the same language the user uses. '
    'Be concise — you run on a 1.2B parameter model.';

class ChatProvider extends ChangeNotifier {
  // ── Public state ───────────────────────────────────────────────────────────

  final List<AppMessage> messages = [];
  bool isLoading = false;
  bool isModelReady = false;
  String statusText = 'Загрузка модели…';
  String? errorText;
  bool get isMcpConnected => _mcp?.isConnected ?? false;

  // ── Internals ─────────────────────────────────────────────────────────────

  CactusLM? _lm;
  McpBridge? _mcp;

  /// Tools available to Cactus: web_fetch (local) + all MCP tools.
  List<CactusTool> get _allTools => [
        webFetchTool,
        ...(_mcp?.tools ?? []),
      ];

  /// Conversation history passed to Cactus.
  final List<ChatMessage> _history = [
    ChatMessage(role: 'system', content: _systemPrompt),
  ];

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> init() async {
    try {
      statusText = 'Загрузка модели LFM2.5-1.2B…';
      notifyListeners();

      _lm = CactusLM();
      await _lm!.downloadModel(
        model: 'lfm2.5-1.2b-instruct',
        downloadProcessCallback: (progress, status, isError) {
          if (isError) {
            errorText = status;
          } else {
            final pct = progress != null
                ? ' ${(progress * 100).toStringAsFixed(0)}%'
                : '';
            statusText = 'Загрузка модели$pct';
          }
          notifyListeners();
        },
      );
      await _lm!.initializeModel(
        params: CactusInitParams(contextSize: 4096),
      );

      isModelReady = true;
      statusText = 'Модель готова';
      notifyListeners();

      // Connect to MCP server (non-blocking — failure is recoverable).
      await _connectMcp();
    } catch (e) {
      errorText = 'Ошибка инициализации: $e';
      statusText = 'Ошибка';
      notifyListeners();
    }
  }

  Future<void> _connectMcp() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('mcp_url');
    final token = prefs.getString('mcp_token');

    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      statusText = 'Модель готова (MCP не настроен)';
      notifyListeners();
      return;
    }

    try {
      statusText = 'Подключение к MCP…';
      notifyListeners();

      await _mcp?.disconnect();
      _mcp = McpBridge(serverUrl: url, bearerToken: token);
      await _mcp!.connect();

      statusText = 'Готово (${_mcp!.tools.length} инструментов)';
    } catch (e) {
      statusText = 'Модель готова (MCP недоступен: $e)';
      _mcp = null;
    }
    notifyListeners();
  }

  // ── Send message ──────────────────────────────────────────────────────────

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty || isLoading || !isModelReady) return;

    _addMessage(AppMessage(
      id: _uid(),
      role: MessageRole.user,
      content: text.trim(),
      timestamp: DateTime.now(),
    ));
    _history.add(ChatMessage(role: 'user', content: text.trim()));

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

    final finalResult = await streamResult.result;

    if (finalResult.toolCalls.isNotEmpty) {
      if (buffer.isNotEmpty) {
        _history.add(ChatMessage(role: 'assistant', content: buffer.toString()));
      }

      for (final call in finalResult.toolCalls) {
        _updateMessage(
          assistantId,
          '${buffer.isEmpty ? '' : '${buffer.toString()}\n\n'}'
          '🔧 ${call.name}…',
          MessageStatus.sending,
        );

        final result = await _executeTool(call);

        _history.add(ChatMessage(role: 'tool', content: result));
      }

      final followUp = await lm.generateCompletion(
        messages: List.from(_history),
        params: CactusCompletionParams(temperature: 0.7, maxTokens: 512),
      );

      final finalText = followUp.response;
      _history.add(ChatMessage(role: 'assistant', content: finalText));
      _updateMessage(assistantId, finalText, MessageStatus.done);
    } else {
      final text = buffer.toString();
      _history.add(ChatMessage(role: 'assistant', content: text));
      _updateMessage(assistantId, text, MessageStatus.done);
    }
  }

  // ── Tool executor ─────────────────────────────────────────────────────────

  Future<String> _executeTool(ToolCall call) async {
    // web_fetch is handled locally
    if (call.name == 'web_fetch') {
      return executeWebFetch(call.arguments);
    }

    // All other tools go through MCP
    final mcp = _mcp;
    if (mcp == null || !mcp.isConnected) {
      return 'MCP недоступен. Проверь настройки сервера.';
    }

    return mcp.executeTool(
      call.name,
      Map<String, dynamic>.from(call.arguments),
    );
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  Future<void> saveMcpConfig({
    required String url,
    required String token,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mcp_url', url);
    await prefs.setString('mcp_token', token);
    await _connectMcp();
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

  @override
  void dispose() {
    _mcp?.disconnect();
    _lm?.unload();
    _lm = null;
    super.dispose();
  }
}

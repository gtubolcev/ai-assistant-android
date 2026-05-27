import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import '../tools/mcp_bridge.dart';
import '../tools/web_fetch_tool.dart';

// SharedPreferences key for the saved GGUF model path.
const _kModelPathKey = 'llama_model_path';

// ── Provider ───────────────────────────────────────────────────────────────────

class ChatProvider extends ChangeNotifier {
  // ── Public state ───────────────────────────────────────────────────────────

  final List<AppMessage> messages = [];
  bool isLoading = false;
  bool isModelReady = false;
  String statusText = 'Инициализация…';
  String? errorText;
  bool get isMcpConnected => _mcp?.isConnected ?? false;

  /// Absolute path to the currently active GGUF model file.
  String get activeModelPath => _activeModelPath;

  /// Filename of the active model (basename of activeModelPath).
  String get activeModelName =>
      _activeModelPath.isEmpty ? '' : _activeModelPath.split('/').last;

  // ── Internals ─────────────────────────────────────────────────────────────

  LlamaEngine? _engine;
  EngineChat? _chat;
  McpBridge? _mcp;
  bool _stopRequested = false;
  String _activeModelPath = '';

  /// Request the current generation to stop at the next safe checkpoint.
  void stopGeneration() {
    _stopRequested = true;
    notifyListeners();
  }

  // ── Tool helpers ──────────────────────────────────────────────────────────

  /// All available tools: web_fetch + MCP tools.
  List<Map<String, dynamic>> get _allTools => [
        webFetchToolDef,
        ...(_mcp?.tools ?? []),
      ];

  /// Keyword-based tool selection — narrows the set passed in the system prompt
  /// to a relevant subset, keeping the prompt shorter.
  ///
  /// Always includes web_fetch.  Returns the full tool set when no keyword
  /// matches (so the model can pick any tool).
  List<Map<String, dynamic>> _toolsForMessage(String userMessage) {
    final m = userMessage.toLowerCase();
    final byName = {
      for (final t in _allTools) t['name'] as String: t,
    };

    List<Map<String, dynamic>> pick(List<String> names) =>
        names.map((n) => byName[n]).whereType<Map<String, dynamic>>().toList();

    if (_kw(m, ['http://', 'https://', 'fetch url', 'open url'])) {
      return [webFetchToolDef];
    }
    if (_kw(m, ['contact', 'phone', 'контакт', 'телефон', 'адресн'])) {
      return [webFetchToolDef, ...pick([
        'nc_contacts_list_contacts',
        'nc_contacts_get_contact',
        'nc_contacts_create_contact',
      ])];
    }
    if (_kw(m, ['note', 'notes', 'заметк', 'запис'])) {
      return [webFetchToolDef, ...pick([
        'nc_notes_list_notes',
        'nc_notes_create_note',
        'nc_notes_get_note',
      ])];
    }
    if (_kw(m, ['file', 'folder', 'файл', 'папк', 'документ'])) {
      return [webFetchToolDef, ...pick([
        'nc_files_list_files',
        'nc_files_upload_file',
        'nc_files_get_file_info',
      ])];
    }
    if (_kw(m, ['deck', 'board', 'kanban', 'card', 'борд', 'канбан'])) {
      return [webFetchToolDef, ...pick([
        'nc_deck_list_boards',
        'nc_deck_create_card',
        'nc_deck_list_cards',
      ])];
    }

    // Default: calendar + tasks (most common).
    return [webFetchToolDef, ...pick([
      'nc_calendar_list_calendars',
      'nc_calendar_get_upcoming_events',
      'nc_calendar_create_event',
      'nc_calendar_list_todos',
      'nc_calendar_create_todo',
    ])];
  }

  static bool _kw(String msg, List<String> words) =>
      words.any((w) => msg.contains(w));

  // ── System prompt ─────────────────────────────────────────────────────────

  String _buildSystemPrompt(List<Map<String, dynamic>> tools) {
    if (tools.isEmpty) {
      return 'You are a helpful AI assistant. Answer the user concisely.';
    }

    final toolsJson = const JsonEncoder.withIndent('  ').convert(tools);

    return '''You are a helpful AI assistant with access to tools.

To call a tool, respond with a JSON object on a single line:
{"tool": "tool_name", "arguments": {"param": "value"}}

After receiving the tool result, provide your final answer to the user.
If you don\'t need any tool, answer directly without JSON.

Available tools:
$toolsJson''';
  }

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> init() async {
    try {
      statusText = 'Инициализация…';
      notifyListeners();

      final prefs = await SharedPreferences.getInstance();
      _activeModelPath = prefs.getString(_kModelPathKey) ?? '';

      if (_activeModelPath.isEmpty ||
          !File(_activeModelPath).existsSync()) {
        statusText = 'Выберите модель в Настройках';
        notifyListeners();
        await _connectMcp();
        return;
      }

      await _loadEngine(_activeModelPath);
      await _connectMcp();
      _rebuildChat();
    } catch (e) {
      errorText = 'Ошибка инициализации: $e';
      statusText = 'Ошибка';
      notifyListeners();
    }
  }

  /// Spawns LlamaEngine and marks model as ready.
  /// Does NOT create the EngineChat — call [_rebuildChat] after MCP connects.
  Future<void> _loadEngine(String path) async {
    statusText = 'Загрузка модели…';
    notifyListeners();

    await _chat?.dispose();
    await _engine?.dispose();
    _chat = null;
    _engine = null;

    _engine = await LlamaEngine.spawn(
      libraryPath: 'libllama.so',   // Android uses basename; resolved via AAR
      modelParams: ModelParams(path: path, gpuLayers: 99),
      contextParams: const ContextParams(nCtx: 4096, nBatch: 512, nUbatch: 512),
    );

    isModelReady = true;
    _activeModelPath = path;
    statusText = 'Модель готова';
    notifyListeners();
  }

  /// (Re)creates the EngineChat with a fresh system prompt that includes
  /// the current MCP tool list.  Call after model load or MCP reconnect.
  void _rebuildChat() {
    if (_engine == null) return;

    // Fire-and-forget; caller may notifyListeners after.
    () async {
      await _chat?.dispose();
      _chat = await _engine!.createChat();
      final tools = _allTools;
      if (tools.isNotEmpty) {
        _chat!.addSystem(_buildSystemPrompt(tools));
      }
      debugPrint('[AI] Chat rebuilt. Tools: ${tools.map((t) => t['name']).toList()}');
    }();
  }

  // ── Import from local file ────────────────────────────────────────────────

  /// Loads a GGUF model from [filePath] and saves the path for next launch.
  Future<void> importModelFromFile(String filePath) async {
    isModelReady = false;
    errorText = null;
    statusText = 'Загрузка модели…';
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kModelPathKey, filePath);

      await _loadEngine(filePath);
      _rebuildChat();

      statusText = isMcpConnected
          ? 'Готово (${_mcp!.tools.length} инструментов)'
          : 'Модель загружена';
    } catch (e) {
      errorText = 'Ошибка загрузки модели: $e';
      statusText = 'Ошибка';
    }
    notifyListeners();
  }

  // ── MCP connection ────────────────────────────────────────────────────────

  Future<void> _connectMcp() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('mcp_url');

    if (url == null || url.isEmpty) {
      statusText = isModelReady
          ? 'Модель готова (MCP не настроен)'
          : 'Выберите модель в Настройках';
      notifyListeners();
      return;
    }

    try {
      statusText = 'Подключение к MCP…';
      notifyListeners();

      await _mcp?.disconnect();
      _mcp = McpBridge(
        serverUrl: url,
        username: prefs.getString('mcp_user') ?? '',
        password: prefs.getString('mcp_password') ?? '',
        bearerToken: prefs.getString('mcp_token') ?? '',
      );
      await _mcp!.connect();

      // Rebuild chat so the new tool list is included in the system prompt.
      _rebuildChat();

      statusText = isModelReady
          ? 'Готово (${_mcp!.tools.length} инструментов)'
          : 'Выберите модель в Настройках';
    } catch (e) {
      statusText = isModelReady
          ? 'Модель готова (MCP недоступен: $e)'
          : 'Выберите модель в Настройках';
      _mcp = null;
    }
    notifyListeners();
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  Future<void> saveMcpConfig({
    required String url,
    String token = '',
    String user = '',
    String password = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mcp_url', url);
    await prefs.setString('mcp_token', token);
    await prefs.setString('mcp_user', user);
    await prefs.setString('mcp_password', password);
    await _connectMcp();
  }

  Future<void> saveCaldavConfig({
    required String url,
    required String user,
    required String password,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('caldav_url', url.trim());
    await prefs.setString('caldav_user', user.trim());
    await prefs.setString('caldav_password', password);
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
      await _runAgentLoop(assistantId, userMessage: text.trim());
    } catch (e) {
      _updateMessage(assistantId, 'Ошибка: $e', MessageStatus.error);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  // ── Agent loop ────────────────────────────────────────────────────────────

  Future<void> _runAgentLoop(String assistantId,
      {required String userMessage}) async {
    // Ensure we have a chat (may be null if engine just loaded).
    if (_chat == null) {
      await _ensureChat();
    }
    final chat = _chat!;

    _stopRequested = false;
    final completedTools = <String>[];
    const maxIterations = 8;

    final tools = _toolsForMessage(userMessage);
    debugPrint('[AI] msg="$userMessage" tools=${tools.map((t) => t['name']).toList()}');

    // Add the user message to the engine chat context.
    chat.addUser(userMessage);

    for (int iter = 0; iter < maxIterations; iter++) {
      if (_stopRequested) {
        _stopRequested = false;
        _updateMessage(
          assistantId,
          _buildDisplay(completedTools, '⏹ остановлено', pending: false),
          MessageStatus.done,
        );
        return;
      }

      debugPrint('[AI] iter=$iter generating…');
      final buffer = StringBuffer();

      await for (final event in chat.generate(
        sampler: const SamplerParams(temperature: 0.0, topP: 1.0),
        maxTokens: 512,
      )) {
        if (_stopRequested) break;
        switch (event) {
          case TokenEvent():
            buffer.write(event.text);
            _updateMessage(
              assistantId,
              _buildDisplay(completedTools, _cleanOutput(buffer.toString()),
                  pending: true),
              MessageStatus.sending,
            );
          case DoneEvent():
            if (event.trailingText.isNotEmpty) {
              buffer.write(event.trailingText);
            }
            debugPrint('[AI] done reason=${event.reason} tokens=${event.generatedCount}');
          case ShiftEvent():
            debugPrint('[AI] context shift');
        }
      }

      if (_stopRequested) {
        _stopRequested = false;
        _updateMessage(
          assistantId,
          _buildDisplay(completedTools,
              '${_cleanOutput(buffer.toString())}\n⏹ остановлено'.trim(),
              pending: false),
          MessageStatus.done,
        );
        return;
      }

      final rawText = buffer.toString();
      final call = _parseToolCall(rawText);

      if (call == null) {
        // No tool call — this is the final answer.
        _updateMessage(
          assistantId,
          _buildDisplay(completedTools, _cleanOutput(rawText), pending: false),
          MessageStatus.done,
        );
        return;
      }

      // ── Execute tool ─────────────────────────────────────────────────────
      final (toolName, toolArgs) = call;
      debugPrint('[AI] tool call: $toolName($toolArgs)');

      completedTools.add('🔧 $toolName…');
      _updateMessage(
        assistantId,
        _buildDisplay(completedTools, '', pending: true),
        MessageStatus.sending,
      );

      final toolResult = await _executeTool(toolName, toolArgs);
      debugPrint(
          '[AI] tool result: ${toolResult.substring(0, toolResult.length.clamp(0, 200))}');

      completedTools[completedTools.length - 1] = '🔧 $toolName ✓';

      // Feed the result back as a user message so the model can continue.
      chat.addUser('<tool_result name="$toolName">\n$toolResult\n</tool_result>');
    }

    _updateMessage(
      assistantId,
      _buildDisplay(completedTools, '(превышен лимит итераций)', pending: false),
      MessageStatus.done,
    );
  }

  /// Waits up to 3 seconds for the async _rebuildChat to complete.
  Future<void> _ensureChat() async {
    for (int i = 0; i < 30 && _chat == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_chat == null && _engine != null) {
      // Fallback: create chat synchronously if _rebuildChat never fired.
      _chat = await _engine!.createChat();
      final tools = _allTools;
      if (tools.isNotEmpty) {
        _chat!.addSystem(_buildSystemPrompt(tools));
      }
    }
  }

  // ── Tool-call parser ──────────────────────────────────────────────────────

  /// Parses a tool call from [text], returning `(toolName, args)` or null.
  ///
  /// Supported formats:
  ///   1. JSON line: {"tool":"name","arguments":{...}}
  ///   2. Wrapped:   <tool_call>{"name":"name","arguments":{...}}</tool_call>
  ///   3. LFM2:      <|tool_call_start|>[func(arg="val")]<|tool_call_end|>
  (String, Map<String, dynamic>)? _parseToolCall(String text) {
    // Format 1 & 2: JSON-based (Qwen3, generic)
    final jsonMatch = RegExp(
            r'\{[^{}]*"tool"\s*:\s*"([^"]+)"[^{}]*"arguments"\s*:\s*(\{[^}]*\})',
            dotAll: true)
        .firstMatch(text);
    if (jsonMatch != null) {
      try {
        final name = jsonMatch.group(1)!;
        final argsJson = jsonMatch.group(2)!;
        final args =
            jsonDecode(argsJson) as Map<String, dynamic>;
        return (name, args);
      } catch (_) {}
    }

    // Format: {"name": "...", "arguments": {...}}
    final nameArgMatch = RegExp(
            r'\{[^{}]*"name"\s*:\s*"([^"]+)"[^{}]*"arguments"\s*:\s*(\{[^}]*\})',
            dotAll: true)
        .firstMatch(text);
    if (nameArgMatch != null) {
      try {
        final name = nameArgMatch.group(1)!;
        final argsJson = nameArgMatch.group(2)!;
        final args = jsonDecode(argsJson) as Map<String, dynamic>;
        return (name, args);
      } catch (_) {}
    }

    // Format 3: LFM2 <|tool_call_start|>[func(arg="val")]<|tool_call_end|>
    final lfm2Match = RegExp(
            r'<\|tool_call_start\|>\s*\[(\w+)\(([^)]*)\)\]\s*<\|tool_call_end\|>',
            dotAll: true)
        .firstMatch(text);
    if (lfm2Match != null) {
      final name = lfm2Match.group(1)!;
      final argsStr = lfm2Match.group(2)!;
      final args = _parsePythonKwargs(argsStr);
      return (name, args);
    }

    return null;
  }

  /// Parses Python-style kwargs: key="val", key=123, key=True
  static Map<String, dynamic> _parsePythonKwargs(String s) {
    final result = <String, dynamic>{};
    final re = RegExp(r'(\w+)\s*=\s*(?:"([^"]*)"|([\d.]+)|(true|false))');
    for (final m in re.allMatches(s)) {
      final key = m.group(1)!;
      if (m.group(2) != null) {
        result[key] = m.group(2)!;
      } else if (m.group(3) != null) {
        result[key] = num.tryParse(m.group(3)!) ?? m.group(3)!;
      } else if (m.group(4) != null) {
        result[key] = m.group(4) == 'true';
      }
    }
    return result;
  }

  // ── Tool executor ─────────────────────────────────────────────────────────

  Future<String> _executeTool(
      String name, Map<String, dynamic> args) async {
    if (name == 'web_fetch') {
      return executeWebFetch(args);
    }
    final mcp = _mcp;
    if (mcp == null || !mcp.isConnected) {
      return 'MCP недоступен. Проверь настройки сервера.';
    }
    return mcp.executeTool(name, args);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _buildDisplay(List<String> tools, String text,
      {required bool pending}) {
    final parts = <String>[];
    if (tools.isNotEmpty) parts.add(tools.join('\n'));
    if (text.isNotEmpty) parts.add(text);
    if (parts.isEmpty && pending) return '…';
    return parts.join('\n\n');
  }

  /// Strips model-specific special tokens that leak into the visible output.
  static String _cleanOutput(String text) {
    return text
        .replaceAll(
            RegExp(r'<\|tool_call_start\|>.*?<\|tool_call_end\|>',
                dotAll: true),
            '')
        .replaceAll(
            RegExp(r'<\|tool_call_start\|>.*$', dotAll: true), '')
        .replaceAll(
            RegExp(r'<tool_call>.*?</tool_call>', dotAll: true), '')
        .replaceAll(
            RegExp(r'\{[^{}]*"tool"\s*:\s*"[^"]*"[^{}]*"arguments"[^{}]*\}',
                dotAll: true),
            '')
        .replaceAll(
            RegExp(r'<\|im_end\|>|<\|im_start\|>|<\|tool_call_end\|>'), '')
        .trim();
  }

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
    _chat?.dispose();
    _engine?.dispose();
    super.dispose();
  }
}

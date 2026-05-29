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

  // Recent conversation history injected into each new chat context.
  // Keeps the model aware of what was just discussed without re-processing
  // tool results (those are reconstructed per-turn from fresh MCP calls).
  static const _kMaxHistory = 4;
  final _history = <({String user, String assistant})>[];

  /// Request the current generation to stop at the next safe checkpoint.
  void stopGeneration() {
    _stopRequested = true;
    notifyListeners();
  }

  /// Clears the in-memory conversation history (does not affect displayed messages).
  void clearHistory() {
    _history.clear();
  }

  // ── Tool helpers ──────────────────────────────────────────────────────────

  /// All available tools: web_fetch + MCP tools.
  List<Map<String, dynamic>> get _allTools => [
        webFetchToolDef,
        ...(_mcp?.tools ?? []),
      ];

  /// Returns the minimal set of tools needed for this message.
  ///
  /// Strategy: narrow sets prevent the model from picking the wrong tool.
  /// The model sees only 1-3 tools and picks from those; the less choice,
  /// the less hallucination. Default = no tools (conversational).
  List<Map<String, dynamic>> _toolsForMessage(String userMessage) {
    final m = userMessage.toLowerCase();
    final byName = {for (final t in _allTools) t['name'] as String: t};
    List<Map<String, dynamic>> pick(List<String> names) =>
        names.map((n) => byName[n]).whereType<Map<String, dynamic>>().toList();

    // ── Web ──────────────────────────────────────────────────────────────────
    if (_kw(m, ['http://', 'https://'])) return [webFetchToolDef];

    // ── Calendar: list which calendars exist ─────────────────────────────────
    if (_kw(m, ['list calendar', 'show calendar', 'what calendar',
                 'список календар', 'покажи календар'])) {
      return pick(['nc_calendar_list_calendars']);
    }

    // ── Calendar: upcoming events / agenda ───────────────────────────────────
    if (_kw(m, [
      'list event', 'show event', 'upcoming event', 'upcoming meeting',
      'what event', 'what meeting', 'my event', 'my meeting',
      "what's on", "what is on", 'agenda', 'schedule',
      'список событий', 'покажи события', 'что запланировано',
      'что сегодня', 'что завтра', 'что на неделе',
      'today', 'tomorrow', 'this week', 'next week',
      'сегодня', 'завтра', 'на неделе', 'расписани',
    ])) {
      return pick(['nc_calendar_get_upcoming_events', 'nc_calendar_list_events']);
    }

    // ── Calendar: create event ───────────────────────────────────────────────
    if (_kw(m, [
      'create event', 'add event', 'new event', 'schedule meeting',
      'создай событие', 'добавь событие', 'запланируй', 'встречу',
    ])) {
      return pick(['nc_calendar_create_event']);
    }

    // ── Tasks / todos ────────────────────────────────────────────────────────
    if (_kw(m, [
      'list task', 'show task', 'my task', 'list todo', 'show todo',
      'список задач', 'покажи задачи', 'мои задачи',
    ])) {
      // Only give list_calendars — LFM2-1.2B ignores multi-step instructions
      // and skips straight to list_todos with a made-up calendar name.
      // The agent loop auto-calls list_todos after list_calendars returns.
      return pick(['nc_calendar_list_calendars']);
    }

    if (_kw(m, [
      'create task', 'add task', 'new task', 'create todo', 'add todo',
      'создай задачу', 'добавь задачу',
    ])) {
      return pick(['nc_calendar_create_todo']);
    }

    // ── Calendar (generic — anything with 'calendar', 'event', 'meeting') ───
    if (_kw(m, ['calendar', 'event', 'meeting', 'appointment', 'remind',
                 'task', 'todo', 'deadline',
                 'календар', 'событи', 'встреч', 'напомн',
                 'задач', 'дедлайн', 'план'])) {
      return pick([
        'nc_calendar_get_upcoming_events',
        'nc_calendar_create_event',
        'nc_calendar_list_todos',
        'nc_calendar_create_todo',
        'nc_calendar_list_calendars',
      ]);
    }

    // ── Contacts ─────────────────────────────────────────────────────────────
    if (_kw(m, ['contact', 'phone number', 'контакт', 'телефон', 'адресн'])) {
      return pick([
        'nc_contacts_list_contacts',
        'nc_contacts_get_contact',
        'nc_contacts_create_contact',
      ]);
    }

    // ── Notes ────────────────────────────────────────────────────────────────
    if (_kw(m, ['note', 'notes', 'заметк', 'запис'])) {
      return pick([
        'nc_notes_list_notes',
        'nc_notes_create_note',
        'nc_notes_get_note',
      ]);
    }

    // ── Files ────────────────────────────────────────────────────────────────
    if (_kw(m, ['file', 'folder', 'файл', 'папк', 'документ'])) {
      return pick([
        'nc_files_list_files',
        'nc_files_upload_file',
        'nc_files_get_file_info',
      ]);
    }

    // ── Kanban ───────────────────────────────────────────────────────────────
    if (_kw(m, ['deck', 'board', 'kanban', 'card', 'борд', 'канбан'])) {
      return pick([
        'nc_deck_list_boards',
        'nc_deck_create_card',
        'nc_deck_list_cards',
      ]);
    }

    // ── Default: no tools → conversational response ──────────────────────────
    return [];
  }

  static bool _kw(String msg, List<String> words) =>
      words.any((w) => msg.contains(w));

  // ── System prompt ─────────────────────────────────────────────────────────

  static String _nowStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
  }

  String _buildSystemPrompt(List<Map<String, dynamic>> tools) {
    final dateStr = _nowStr();

    if (tools.isEmpty) {
      return 'You are a helpful AI assistant. /no_think\n'
          'Current date and time: $dateStr\n'
          'Answer concisely. Do not use <think> tags.';
    }

    // One line per tool: signature + first sentence of description.
    final toolLines = tools.map((t) {
      final name = t['name'] as String? ?? '?';
      final rawDesc = t['description'] as String? ?? '';
      final desc = rawDesc.split(RegExp(r'[.\n]')).first.trim();
      final schema = t['inputSchema'] as Map<String, dynamic>?
          ?? t['parameters'] as Map<String, dynamic>?;
      final props = schema?['properties'] as Map<String, dynamic>? ?? {};
      final required = (schema?['required'] as List?)?.cast<String>() ?? [];
      final params = props.entries.map((e) {
        final type = (e.value as Map?)?['type'] as String? ?? 'any';
        final opt = required.contains(e.key) ? '' : '?';
        return '${e.key}$opt:$type';
      }).join(', ');
      return desc.isNotEmpty
          ? '- $name($params) → $desc'
          : '- $name($params)';
    }).join('\n');

    return '''You are a helpful AI assistant. /no_think
Current date and time: $dateStr
Do NOT use <think> tags. Answer concisely in the same language as the user.

## Tool use rules
1. Call a tool ONLY when you need live data (calendar, contacts, files, etc.).
2. For greetings, general knowledge, or questions you can answer directly — do NOT call any tool.
3. Output EXACTLY one JSON line when calling a tool, nothing before or after:
{"tool":"tool_name","arguments":{"key":"value"}}
4. After receiving a <tool_result>, present the data to the user in a clear, friendly format. NEVER say the tool failed unless the result contains an explicit error. NEVER call the same tool again with the same arguments.
5. For nc_calendar_list_todos: ALWAYS call nc_calendar_list_calendars FIRST to get the exact calendar name, then use that exact name in nc_calendar_list_todos. NEVER guess a calendar name.

## Available tools
$toolLines''';
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
      modelParams: ModelParams(path: path, gpuLayers: 0),  // CPU-only: safer on MediaTek
      contextParams: const ContextParams(
        nCtx: 4096,
        nBatch: 512,
        nUbatch: 512,
        opOffload: false,  // disable op offload — GPU backend on MediaTek has invalid function pointers
        swaFull: false,    // don't allocate full SWA cache on memory-constrained device
      ),
    );

    isModelReady = true;
    _activeModelPath = path;
    statusText = 'Модель готова';
    notifyListeners();
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

      statusText = isMcpConnected
          ? 'Готово (${_mcp!.tools.length} инструментов)'
          : 'Модель загружена';
    } catch (e) {
      errorText = 'Ошибка загрузки модели: $e';
      statusText = 'Ошибка';
    }
    notifyListeners();
  }

  // ── Download model from URL ───────────────────────────────────────────────

  /// Download progress: null = idle, 0.0–1.0 = in progress, 1.0 = done.
  double? downloadProgress;

  HttpClient? _downloadClient;

  /// Downloads a GGUF model from [url], saves it to app storage as [filename],
  /// then loads it as the active model. Calls notifyListeners with progress.
  Future<void> downloadModelFromUrl(String url, String filename) async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDocDir.path}/downloaded_models');
    await dir.create(recursive: true);
    final file = File('${dir.path}/$filename');

    isModelReady = false;
    errorText = null;
    downloadProgress = 0.0;
    statusText = 'Загрузка 0%';
    notifyListeners();

    try {
      _downloadClient = HttpClient();
      _downloadClient!.userAgent = 'ai-assistant/1.0';

      // Follow redirects manually so we can track them.
      final request = await _downloadClient!.getUrl(Uri.parse(url));
      final response = await request.close();

      if (response.statusCode != 200) {
        throw Exception('Сервер вернул ${response.statusCode}');
      }

      final total = response.contentLength; // -1 if unknown
      var received = 0;
      final sink = file.openWrite();

      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          downloadProgress = received / total;
          statusText =
              'Загрузка ${(downloadProgress! * 100).toStringAsFixed(0)}%'
              ' (${(received / 1048576).toStringAsFixed(0)} / ${(total / 1048576).toStringAsFixed(0)} МБ)';
        } else {
          statusText =
              'Загрузка ${(received / 1048576).toStringAsFixed(0)} МБ…';
        }
        notifyListeners();
      }
      await sink.close();

      downloadProgress = null;
      _downloadClient = null;

      await importModelFromFile(file.path);
    } catch (e) {
      downloadProgress = null;
      _downloadClient = null;
      errorText = 'Ошибка загрузки: $e';
      statusText = 'Ошибка';
      if (await file.exists()) await file.delete();
      notifyListeners();
    }
  }

  /// Cancels an in-progress download.
  void cancelDownload() {
    _downloadClient?.close(force: true);
    _downloadClient = null;
    downloadProgress = null;
    statusText = 'Загрузка отменена';
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
      final answer = await _runAgentLoop(assistantId, userMessage: text.trim());
      if (answer != null && answer.isNotEmpty) {
        _history.add((user: text.trim(), assistant: answer));
        while (_history.length > _kMaxHistory) _history.removeAt(0);
      }
    } catch (e) {
      _updateMessage(assistantId, 'Ошибка: $e', MessageStatus.error);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  // ── Agent loop ────────────────────────────────────────────────────────────

  Future<String?> _runAgentLoop(String assistantId,
      {required String userMessage}) async {
    if (_engine == null) throw StateError('Engine not loaded');

    _stopRequested = false;
    final completedTools = <String>[];
    const maxIterations = 5;
    // Track (toolName, argsJson) to detect identical repeated calls.
    final calledTools = <String>{};
    // Prefix injected as a partial assistant message after a tool result,
    // to steer the model into producing text rather than another JSON call.
    String assistantPrefix = '';
    // Whether this request originally asked for tasks/todos.
    // Used to auto-call list_todos after list_calendars returns.
    final isTaskQuery = _kw(userMessage.toLowerCase(), [
      'list task', 'show task', 'my task', 'list todo', 'show todo',
      'список задач', 'покажи задачи', 'мои задачи',
    ]);

    // Select only the tools relevant to this message — keeps the system
    // prompt small so prefill stays fast on a phone CPU.
    final tools = _toolsForMessage(userMessage);
    debugPrint('[AI] msg="${userMessage.substring(0, userMessage.length.clamp(0, 60))}" '
        'tools=${tools.map((t) => t['name']).toList()}');

    // Reuse the same EngineChat across messages — creating a new one every
    // message causes the native ggml backend scheduler to enter an invalid
    // state (use-after-free, visible as pc=0xff80000000000000 / deadpool).
    // clearHistory() resets the Dart-side message list; the worker always
    // calls session.clear() + session.appendText(fullPrompt) at generate
    // time anyway, so the KV cache is fully re-prefilled from scratch.
    if (_chat == null) {
      _chat = await _engine!.createChat();
    }
    _chat!.clearHistory();
    _chat!.addSystem(_buildSystemPrompt(tools));
    final chat = _chat!;

    // Add the user message to the engine chat context.
    chat.addUser(userMessage);

    // ── Auto-trigger: task queries bypass model tool-call decision ───────────
    // LFM2-1.2B is too small to reliably call tools for multi-step tasks.
    // For task/todo queries we call nc_calendar_list_calendars ourselves,
    // then cascade to nc_calendar_list_todos, and feed the combined result
    // directly into the chat so the model only needs to format it.
    if (isTaskQuery) {
      completedTools.add('🔧 nc_calendar_list_calendars…');
      _updateMessage(assistantId, _buildDisplay(completedTools, '', pending: true),
          MessageStatus.sending);

      final calsResult = await _executeTool('nc_calendar_list_calendars', {});
      calledTools.add('nc_calendar_list_calendars:{}');
      completedTools[completedTools.length - 1] = '🔧 nc_calendar_list_calendars ✓';

      final calIds = _filterCalendarIds(_extractCalendars(calsResult), userMessage);
      completedTools.add('🔧 nc_calendar_list_todos…');
      _updateMessage(assistantId, _buildDisplay(completedTools, '', pending: true),
          MessageStatus.sending);

      final todoParts = <String>[];
      for (final id in calIds) {
        final todos = await _executeTool('nc_calendar_list_todos', {'calendar_name': id});
        if (!todos.startsWith('No tasks') && !todos.startsWith('Error') &&
            !todos.startsWith('Ошибка') && !todos.startsWith('MCP')) {
          todoParts.add(todos);
        }
      }
      final combined = todoParts.isEmpty ? 'No tasks found in any calendar.' : todoParts.join('\n');
      // Block these tools by name-only sentinel so the model can't re-call them
      // with any argument variation (model tends to re-call with {key:calendars}).
      calledTools.add('nc_calendar_list_todos');
      calledTools.add('nc_calendar_list_calendars');
      completedTools[completedTools.length - 1] = '🔧 nc_calendar_list_todos ✓';

      chat.addUser('<tool_result name="nc_calendar_list_todos">\n$combined\n</tool_result>');
      // Add an explicit summarize instruction so the model produces prose, not JSON.
      chat.addUser('Summarize the tasks above in a clear, human-readable list. '
          'Do not use JSON. Do not call any tools. Just list the tasks.');
      const taskPrefix = 'Here are your tasks:';
      chat.addAssistant(taskPrefix);
      assistantPrefix = taskPrefix;
    }

    for (int iter = 0; iter < maxIterations; iter++) {
      if (_stopRequested) {
        _stopRequested = false;
        _updateMessage(
          assistantId,
          _buildDisplay(completedTools, '⏹ остановлено', pending: false),
          MessageStatus.done,
        );
        return null;
      }

      debugPrint('[AI] iter=$iter generating… (nCtx=4096 cpu-only)');
      final buffer = StringBuffer();
      int tokenCount = 0;
      bool firstToken = true;

      // Wrap stream with a per-event timeout so a stuck model doesn't hang forever.
      final stream = chat
          .generate(
            sampler: const SamplerParams(temperature: 0.6, topP: 0.95),
            maxTokens: 512,
          )
          .timeout(
            const Duration(seconds: 120),
            onTimeout: (sink) {
              debugPrint('[AI] ⚠️ generation timeout after 120s — closing stream');
              sink.close();
            },
          );

      await for (final event in stream) {
        if (_stopRequested) break;
        switch (event) {
          case TokenEvent():
            buffer.write(event.text);
            tokenCount++;
            if (firstToken) {
              firstToken = false;
              debugPrint('[AI] first token: "${event.text}"');
            }
            // Log every 20 tokens so logcat shows the model IS working.
            if (tokenCount % 20 == 0) {
              final snippet = buffer.toString();
              final tail = snippet.length > 40
                  ? '…${snippet.substring(snippet.length - 40)}'
                  : snippet;
              debugPrint('[AI] tok=$tokenCount tail="$tail"');
            }
            final partial = assistantPrefix.isNotEmpty
                ? '$assistantPrefix ${buffer.toString()}'
                : buffer.toString();
            _updateMessage(
              assistantId,
              _buildDisplay(completedTools, _cleanOutput(partial),
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
        final stoppedText = assistantPrefix.isNotEmpty
            ? '$assistantPrefix ${buffer.toString()}'
            : buffer.toString();
        _updateMessage(
          assistantId,
          _buildDisplay(completedTools,
              '${_cleanOutput(stoppedText)}\n⏹ остановлено'.trim(),
              pending: false),
          MessageStatus.done,
        );
        return null;
      }

      final rawText = buffer.toString();
      // Include any injected prefix so the final display is complete.
      final displayText = assistantPrefix.isNotEmpty
          ? '$assistantPrefix $rawText'
          : rawText;
      final call = _parseToolCall(rawText);

      if (call == null) {
        // No tool call — this is the final answer.
        final cleanAnswer = _cleanOutput(displayText);
        _updateMessage(
          assistantId,
          _buildDisplay(completedTools, cleanAnswer, pending: false),
          MessageStatus.done,
        );
        return cleanAnswer;
      }

      // ── Execute tool ─────────────────────────────────────────────────────
      assistantPrefix = ''; // reset: the model chose to call a tool instead
      final (toolName, toolArgs) = call;
      final callKey = '$toolName:${jsonEncode(toolArgs)}';
      debugPrint('[AI] tool call: $toolName($toolArgs)');

      // Anti-loop: same tool + same args already called, OR tool blocked by
      // name-only sentinel (e.g. after auto-trigger) → treat as final answer.
      if (calledTools.contains(callKey) || calledTools.contains(toolName)) {
        debugPrint('[AI] ⚠️ duplicate tool call detected, stopping loop');
        final cleanAnswer = _cleanOutput(displayText);
        _updateMessage(
          assistantId,
          _buildDisplay(completedTools, cleanAnswer, pending: false),
          MessageStatus.done,
        );
        return cleanAnswer;
      }
      calledTools.add(callKey);

      completedTools.add('🔧 $toolName…');
      _updateMessage(
        assistantId,
        _buildDisplay(completedTools, '', pending: true),
        MessageStatus.sending,
      );

      final toolResult = await _executeTool(toolName, toolArgs);
      debugPrint(
          '[AI] tool result (${toolResult.length} chars): ${toolResult.substring(0, toolResult.length.clamp(0, 800))}');

      completedTools[completedTools.length - 1] = '🔧 $toolName ✓';

      // ── Auto-cascade: list_calendars → list_todos for task queries ──────────
      // LFM2-1.2B ignores multi-step instructions, so we do the second step
      // automatically: after the model lists calendars, we call list_todos for
      // each non-birthday calendar and combine results.
      if (toolName == 'nc_calendar_list_calendars' && isTaskQuery) {
        final calIds = _filterCalendarIds(_extractCalendars(toolResult), userMessage);
        completedTools.add('🔧 nc_calendar_list_todos…');
        _updateMessage(assistantId, _buildDisplay(completedTools, '', pending: true),
            MessageStatus.sending);
        final todoParts = <String>[];
        for (final id in calIds) {
          final todos = await _executeTool('nc_calendar_list_todos', {'calendar_name': id});
          if (!todos.startsWith('No tasks') && !todos.startsWith('Error') &&
              !todos.startsWith('Ошибка') && !todos.startsWith('MCP')) {
            todoParts.add(todos);
          }
        }
        final combined = todoParts.isEmpty ? 'No tasks found in any calendar.' : todoParts.join('\n');
        completedTools[completedTools.length - 1] = '🔧 nc_calendar_list_todos ✓';
        calledTools.add('nc_calendar_list_todos:{}'); // prevent model from re-calling

        // Feed combined todos to model for presentation.
        chat.addUser('<tool_result name="nc_calendar_list_todos">\n$combined\n</tool_result>');
        const prefix = 'Here is what I found:';
        chat.addAssistant(prefix);
        assistantPrefix = prefix;
        continue; // let model generate the final text answer
      }

      // Feed result, then add a partial assistant prefix so the model
      // continues with plain text instead of generating another JSON tool call.
      // Strip internal IDs from calendar list — the model echoes them and the
      // user doesn't need to see them (IDs are kept in toolResult for our code).
      final modelResult = toolName == 'nc_calendar_list_calendars'
          ? toolResult.replaceAll(RegExp(r' \(id: [^)]+\)'), '')
          : toolResult;
      chat.addUser(
        '<tool_result name="$toolName">\n$modelResult\n</tool_result>',
      );
      // Seed the assistant turn. For calendar list, force one-per-line format.
      final prefix = toolName == 'nc_calendar_list_calendars'
          ? 'Your calendars (one per line):\n'
          : 'Here is what I found:';
      chat.addAssistant(prefix);
      assistantPrefix = prefix;
    }

    _updateMessage(
      assistantId,
      _buildDisplay(completedTools, '(превышен лимит итераций)', pending: false),
      MessageStatus.done,
    );
    return null;
  }

  // ── Tool-call parser ──────────────────────────────────────────────────────

  /// Parses a tool call from [text], returning `(toolName, args)` or null.
  ///
  /// Supported formats:
  ///   1. <tool_call>{"name":"...","arguments":{...}}</tool_call>  — LFM2.5-Nova / ChatML
  ///   2. {"tool":"name","arguments":{...}}                        — generic JSON line
  ///   3. {"name":"...","arguments":{...}}                         — alternate JSON line
  ///   4. <|tool_call_start|>[func(arg="val")]<|tool_call_end|>    — LFM2 native
  (String, Map<String, dynamic>)? _parseToolCall(String text) {
    // Format 1: <tool_call>…</tool_call> — extract inner JSON fully
    final blockMatch =
        RegExp(r'<tool_call>\s*(\{[\s\S]*?\})\s*</tool_call>', dotAll: true)
            .firstMatch(text);
    if (blockMatch != null) {
      try {
        final json = jsonDecode(blockMatch.group(1)!) as Map<String, dynamic>;
        final name = json['name'] as String?;
        final args = (json['arguments'] as Map<String, dynamic>?) ?? {};
        if (name != null) return (name, args);
      } catch (_) {}
    }

    // Format 2 & 3: bare JSON object anywhere in text — use a bracket-counting
    // extractor so nested objects parse correctly.
    final extracted = _extractFirstJsonObject(text);
    if (extracted != null) {
      try {
        final json = jsonDecode(extracted) as Map<String, dynamic>;
        // Support both {"tool":...} and {"name":...} keys.
        final name = (json['tool'] ?? json['name']) as String?;
        // arguments may be omitted for no-arg tools — default to {}.
        final args = (json['arguments'] as Map<String, dynamic>?) ?? {};
        if (name != null) return (name, args);
      } catch (_) {}
    }

    // Format 4: LFM2 <|tool_call_start|>[func(key="val")]<|tool_call_end|>
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

  /// Finds the first `{…}` JSON object in [text] using bracket counting,
  /// so nested objects are included correctly.
  static String? _extractFirstJsonObject(String text) {
    int depth = 0;
    int start = -1;
    for (int i = 0; i < text.length; i++) {
      if (text[i] == '{') {
        if (depth == 0) start = i;
        depth++;
      } else if (text[i] == '}') {
        depth--;
        if (depth == 0 && start != -1) {
          return text.substring(start, i + 1);
        }
      }
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
    final raw = await mcp.executeTool(name, args);
    return _humanizeToolResult(name, raw);
  }

  /// Extracts (id, displayName) pairs from a humanized list_calendars result.
  ///
  /// Humanized format:
  ///   "Found N calendar(s):\n• DisplayName (id: calId)\n• ..."
  static List<(String, String)> _extractCalendars(String humanized) {
    final result = <(String, String)>[];
    final re = RegExp(r'•\s+(.+?)\s+\(id:\s*([^)]+)\)');
    for (final m in re.allMatches(humanized)) {
      result.add((m.group(2)!.trim(), m.group(1)!.trim())); // (id, displayName)
    }
    return result;
  }

  /// Returns calendar IDs to fetch todos from, based on the user message.
  ///
  /// If the user mentioned a specific calendar by name or ID, returns only that
  /// one. Otherwise returns all non-birthday calendars.
  static List<String> _filterCalendarIds(
      List<(String, String)> calendars, String userMessage) {
    final msg = userMessage.toLowerCase();
    for (final (id, name) in calendars) {
      final idLow = id.toLowerCase();
      final nameLow = name.toLowerCase();
      if (nameLow.length > 2 && msg.contains(nameLow) ||
          idLow.length > 2 && msg.contains(idLow)) {
        return [id];
      }
    }
    return calendars
        .where((c) =>
            !c.$1.contains('birthday') && !c.$1.contains('contact_birthday'))
        .map((c) => c.$1)
        .toList();
  }

  /// Converts raw MCP tool results to compact human-readable text.
  ///
  /// Small models like LFM2-1.2B cannot summarize large JSON — they echo it
  /// verbatim. This method pre-formats the data so the model only needs to
  /// repeat a short, structured description.
  static String _humanizeToolResult(String toolName, String raw) {
    // Don't touch explicit errors.
    if (raw.startsWith('Error') || raw.startsWith('Ошибка') ||
        raw.startsWith('MCP')) {
      return raw;
    }

    try {
      // Strip markdown code fences that some MCP servers wrap around JSON
      // (e.g. ```json\n{...}\n```).
      String src = raw.trim();
      if (src.startsWith('```')) {
        final nl = src.indexOf('\n');
        if (nl != -1) src = src.substring(nl + 1);
        if (src.endsWith('```')) src = src.substring(0, src.length - 3).trimRight();
      }
      final json = jsonDecode(src);

      // ── Calendar list ──────────────────────────────────────────────────────
      if (toolName == 'nc_calendar_list_calendars') {
        final cals = (json['calendars'] as List?) ?? [];
        if (cals.isEmpty) return 'No calendars found.';
        final lines = cals.map((c) {
          final displayName = c['display_name'] ?? c['name'] ?? '?';
          // Prefer 'name' (CalDAV collection slug, used by nc_calendar_list_todos).
          // Fall back to last segment of href if 'name' is absent.
          final id = (c['name'] as String?)?.isNotEmpty == true
              ? c['name'] as String
              : (c['href'] as String? ?? '').split('/').where((s) => s.isNotEmpty).last;
          return '• $displayName (id: $id)';
        }).join('\n');
        return 'Found ${cals.length} calendar(s):\n$lines';
      }

      // ── Upcoming events ────────────────────────────────────────────────────
      if (toolName == 'nc_calendar_get_upcoming_events' ||
          toolName == 'nc_calendar_list_events') {
        final events = (json['events'] as List?) ?? [];
        if (events.isEmpty) return 'No upcoming events found.';
        final lines = events.take(10).map((e) {
          final title = e['summary'] ?? e['title'] ?? '(no title)';
          final start = e['start'] ?? e['dtstart'] ?? '';
          return '• $title — $start';
        }).join('\n');
        return 'Found ${events.length} event(s):\n$lines';
      }

      // ── Todo / task list ───────────────────────────────────────────────────
      if (toolName == 'nc_calendar_list_todos') {
        final todos = (json['todos'] as List?) ??
            (json['tasks'] as List?) ?? [];
        // Filter out completed/cancelled tasks.
        final incomplete = todos.where((t) {
          final s = ((t['status'] as String?) ?? '').toUpperCase();
          return s != 'COMPLETED' && s != 'CANCELLED';
        }).toList();
        if (incomplete.isEmpty) return 'No incomplete tasks found.';
        final lines = incomplete.take(30).map((t) {
          final title = t['summary'] ?? t['title'] ?? '(no title)';
          final due = (t['due'] as String?) ?? '';
          return '• $title${due.isNotEmpty ? " (due: $due)" : ""}';
        }).join('\n');
        return 'Found ${incomplete.length} incomplete task(s):\n$lines';
      }

      // ── Contacts list ──────────────────────────────────────────────────────
      if (toolName == 'nc_contacts_list_contacts') {
        final contacts = (json['contacts'] as List?) ?? [];
        if (contacts.isEmpty) return 'No contacts found.';
        final lines = contacts.take(15).map((c) {
          final name = c['display_name'] ?? c['fn'] ?? '?';
          final phone = (c['phones'] as List?)?.first?['value'] ?? '';
          return '• $name${phone.isNotEmpty ? " — $phone" : ""}';
        }).join('\n');
        return 'Found ${contacts.length} contact(s):\n$lines';
      }

      // ── Notes list ─────────────────────────────────────────────────────────
      if (toolName == 'nc_notes_list_notes') {
        final notes = (json['notes'] as List?) ?? [];
        if (notes.isEmpty) return 'No notes found.';
        final lines = notes.take(10).map((n) {
          final title = n['title'] ?? n['name'] ?? '(untitled)';
          return '• $title';
        }).join('\n');
        return 'Found ${notes.length} note(s):\n$lines';
      }

      // ── Generic: if result is short enough, pass as-is; otherwise summarize top fields ──
      if (raw.length <= 400) return raw;

      // For large unknown responses: extract top-level non-nested fields only.
      if (json is Map) {
        final summary = json.entries
            .where((e) => e.value is! Map && e.value is! List)
            .take(8)
            .map((e) => '${e.key}: ${e.value}')
            .join('\n');
        return summary.isNotEmpty ? summary : raw.substring(0, 400);
      }
    } catch (_) {
      // Not JSON — pass through, truncated.
    }

    // Fallback: truncate to 400 chars.
    return raw.length > 400 ? '${raw.substring(0, 400)}\n[...]' : raw;
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

  /// Strips model-specific special tokens and reasoning blocks from output.
  static String _cleanOutput(String text) {
    return text
        // Qwen3 / DeepSeek thinking blocks (complete).
        .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '')
        // Partial <think> block still being generated — hide everything after it.
        .replaceAll(RegExp(r'<think>.*$', dotAll: true), '')
        // LFM2 tool call markers.
        .replaceAll(
            RegExp(r'<\|tool_call_start\|>.*?<\|tool_call_end\|>',
                dotAll: true),
            '')
        .replaceAll(
            RegExp(r'<\|tool_call_start\|>.*$', dotAll: true), '')
        // ChatML tool call blocks.
        .replaceAll(
            RegExp(r'<tool_call>.*?</tool_call>', dotAll: true), '')
        // Markdown code-fence blocks containing JSON (model echoes tool results).
        .replaceAll(RegExp(r'```(?:json)?\s*\{[\s\S]*?\}\s*```', dotAll: true), '')
        .replaceAll(RegExp(r'```(?:json)?\s*\{[\s\S]*$', dotAll: true), '')
        // Raw JSON tool call objects (with or without arguments field).
        .replaceAll(
            RegExp(r'\{[^{}]*"tool"\s*:\s*"[^"]*"[^{}]*\}', dotAll: true), '')
        .replaceAll(
            RegExp(r'\{[^{}]*"name"\s*:\s*"[^"]*"[^{}]*"arguments"[^{}]*\}',
                dotAll: true),
            '')
        // ChatML / LFM special tokens.
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

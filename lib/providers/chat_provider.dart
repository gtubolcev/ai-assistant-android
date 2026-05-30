import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import '../tools/caldav_tool.dart';
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
  CalDavExecutor? _caldav;
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

  /// All available tools: web_fetch + CalDAV tools (+ MCP if connected).
  List<Map<String, dynamic>> get _allTools => [
        webFetchToolDef,
        if (_caldav != null) ...calDavToolDefs,
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

    // ── Calendars list ───────────────────────────────────────────────────────
    if (_kw(m, ['list calendar', 'show calendar', 'what calendar',
                 'список календар', 'покажи календар'])) {
      return pick(['list_calendars']);
    }

    // ── Events / agenda ──────────────────────────────────────────────────────
    if (_kw(m, [
      'list event', 'show event', 'upcoming event', 'agenda', 'schedule',
      'what event', "what's on", 'event today', 'event tomorrow',
      'список событий', 'покажи события', 'что запланировано',
      'что сегодня', 'что завтра', 'что на неделе', 'расписани',
      'today', 'tomorrow', 'this week', 'next week', 'this month',
      'сегодня', 'завтра', 'на неделе', 'на месяц', 'на год',
    ])) {
      return pick(['list_events']);
    }

    // ── Create event ─────────────────────────────────────────────────────────
    if (_kw(m, [
      'create event', 'add event', 'new event', 'schedule meeting',
      'создай событие', 'добавь событие', 'запланируй встречу',
    ])) {
      return pick(['create_event']);
    }

    // ── Tasks: list ──────────────────────────────────────────────────────────
    if (_kw(m, [
      'list task', 'show task', 'my task', 'list todo', 'show todo',
      'список задач', 'покажи задачи', 'мои задачи',
    ])) {
      return pick(['list_tasks']);
    }

    // ── Tasks: create ────────────────────────────────────────────────────────
    if (_kw(m, [
      'create task', 'add task', 'new task', 'create todo', 'add todo',
      'создай задачу', 'добавь задачу', 'новая задача',
    ])) {
      return pick(['create_task']);
    }

    // ── Tasks: complete / update / delete ────────────────────────────────────
    if (_kw(m, ['complete task', 'finish task', 'mark done', 'mark as done',
                 'выполнить задачу', 'завершить задачу', 'отметить выполненной'])) {
      return pick(['complete_task']);
    }
    if (_kw(m, ['update task', 'edit task', 'change task', 'rename task',
                 'обновить задачу', 'изменить задачу'])) {
      return pick(['update_task']);
    }
    if (_kw(m, ['delete task', 'remove task', 'удалить задачу'])) {
      return pick(['delete_task']);
    }

    // ── Generic calendar/task/event ──────────────────────────────────────────
    if (_kw(m, ['calendar', 'event', 'meeting', 'appointment',
                 'task', 'todo', 'deadline', 'remind',
                 'календар', 'событи', 'встреч', 'напомн',
                 'задач', 'дедлайн', 'план'])) {
      return pick(['list_tasks', 'list_events', 'create_task', 'create_event']);
    }

    // ── MCP tools (if connected) ─────────────────────────────────────────────
    if (_mcp != null) {
      if (_kw(m, ['note', 'notes', 'заметк', 'запис'])) {
        return pick(['nc_notes_list_notes', 'nc_notes_create_note', 'nc_notes_get_note']);
      }
      if (_kw(m, ['file', 'folder', 'файл', 'папк', 'документ'])) {
        return pick(['nc_files_list_files', 'nc_files_upload_file']);
      }
    }

    // ── Default: conversational ──────────────────────────────────────────────
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
      final schema = (t['inputSchema'] as Map?)?.cast<String, dynamic>()
          ?? (t['parameters'] as Map?)?.cast<String, dynamic>();
      final props = (schema?['properties'] as Map?)?.cast<String, dynamic>() ?? {};
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

      // Initialise CalDAV client from saved settings.
      await _initCalDav(prefs);

      if (_activeModelPath.isEmpty ||
          !File(_activeModelPath).existsSync()) {
        statusText = _caldav != null
            ? 'Выберите модель в Настройках'
            : 'Выберите модель и настройте CalDAV';
        notifyListeners();
        return;
      }

      await _loadEngine(_activeModelPath);
    } catch (e) {
      errorText = 'Ошибка инициализации: $e';
      statusText = 'Ошибка';
      notifyListeners();
    }
  }

  Future<void> _initCalDav(SharedPreferences prefs) async {
    final url = prefs.getString('caldav_url') ?? '';
    final user = prefs.getString('caldav_user') ?? '';
    final pass = prefs.getString('caldav_password') ?? '';
    if (url.isEmpty || user.isEmpty) {
      _caldav = null;
      return;
    }
    _caldav = CalDavExecutor(CalDavClient(
      serverUrl: url,
      username: user,
      password: pass,
    ));
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
    await _initCalDav(prefs);
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
    String assistantPrefix = '';

    final tools = _toolsForMessage(userMessage);
    debugPrint('[AI] msg="${userMessage.substring(0, userMessage.length.clamp(0, 60))}" '
        'tools=${tools.map((t) => t['name']).toList()}');

    if (_chat == null) {
      _chat = await _engine!.createChat();
    }
    _chat!.clearHistory();
    _chat!.addSystem(_buildSystemPrompt(tools));
    final chat = _chat!;

    chat.addUser(userMessage);

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

      // CalDAV tools return pre-formatted output — show directly without model.
      if (CalDavExecutor.handles(toolName)) {
        final cleanAnswer = _cleanOutput(toolResult);
        _updateMessage(
          assistantId,
          _buildDisplay(completedTools, cleanAnswer, pending: false),
          MessageStatus.done,
        );
        return cleanAnswer;
      }

      // Feed result, then add a partial assistant prefix so the model
      // continues with plain text instead of generating another JSON tool call.
      chat.addUser(
        '<tool_result name="$toolName">\n$toolResult\n</tool_result>',
      );
      const prefix = 'Here is what I found:';
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
    if (name == 'web_fetch') return executeWebFetch(args);

    // CalDAV tools (our own implementation — returns pre-formatted strings).
    final caldav = _caldav;
    if (caldav != null && CalDavExecutor.handles(name)) {
      return caldav.execute(name, args);
    }

    // MCP fallback for other tools (notes, files, etc.).
    final mcp = _mcp;
    if (mcp == null || !mcp.isConnected) {
      return 'Инструмент "$name" недоступен. Проверь настройки.';
    }
    final raw = await mcp.executeTool(name, args);
    return _humanizeToolResult(name, raw);
  }

  /// Converts raw MCP tool results to compact human-readable text for the model.
  static String _humanizeToolResult(String toolName, String raw) {
    if (raw.startsWith('Error') || raw.startsWith('Ошибка') || raw.startsWith('MCP')) {
      return raw;
    }
    try {
      String src = raw.trim();
      if (src.startsWith('```')) {
        final nl = src.indexOf('\n');
        if (nl != -1) src = src.substring(nl + 1);
        if (src.endsWith('```')) src = src.substring(0, src.length - 3).trimRight();
      }
      final json = jsonDecode(src);

      if (toolName == 'nc_notes_list_notes') {
        final notes = (json['notes'] as List?) ?? [];
        if (notes.isEmpty) return 'No notes found.';
        return 'Found ${notes.length} note(s):\n'
            '${notes.take(10).map((n) => '• ${n['title'] ?? '(untitled)'}').join('\n')}';
      }

      if (raw.length <= 400) return raw;
      if (json is Map) {
        final summary = json.entries
            .where((e) => e.value is! Map && e.value is! List)
            .take(8)
            .map((e) => '${e.key}: ${e.value}')
            .join('\n');
        return summary.isNotEmpty ? summary : raw.substring(0, 400);
      }
    } catch (_) {}
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

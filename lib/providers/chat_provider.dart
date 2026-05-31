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
  /// Test-only: exercises the keyword/fuzzy router. Seeds an offline CalDAV
  /// executor so calendar/task/event tool defs are available for matching
  /// (the constructor performs no network I/O).
  @visibleForTesting
  List<Map<String, dynamic>> debugToolsForMessage(String userMessage) {
    _caldav ??= CalDavExecutor(
      CalDavClient(serverUrl: 'https://example.test', username: 'u', password: 'p'),
    );
    return _toolsForMessage(userMessage);
  }

  List<Map<String, dynamic>> _toolsForMessage(String userMessage) {
    final m = userMessage.toLowerCase();
    final byName = {for (final t in _allTools) t['name'] as String: t};
    List<Map<String, dynamic>> pick(List<String> names) =>
        names.map((n) => byName[n]).whereType<Map<String, dynamic>>().toList();

    // ── Web ──────────────────────────────────────────────────────────────────
    if (_kw(m, ['http://', 'https://'])) return [webFetchToolDef];

    // ── Concept detection ──────────────────────────────────────────────────
    // Token-level, typo-tolerant (edit distance ≤1), stem/prefix based — so
    // word order and small misspellings still match. "show me calendars",
    // "calenders", "my calendar" all route to list_calendars.
    final calendar = _hasConcept(m,
        ['calendar', 'calendars', 'календарь', 'календари', 'календар']);
    final task = _hasConcept(m,
        ['task', 'tasks', 'todo', 'todos', 'задача', 'задачи', 'задач']);
    final event = _hasConcept(m, [
      'event', 'events', 'meeting', 'meetings', 'appointment', 'appointments',
      'событие', 'события', 'событий', 'встреча', 'встречи', 'встречу',
    ]);
    final agenda = _hasConcept(m, [
      'agenda', 'schedule', 'today', 'tomorrow', 'upcoming',
      'расписание', 'сегодня', 'завтра', 'неделя', 'неделю', 'неделе',
    ]);

    final createVerb = _hasConcept(m, [
      'create', 'add', 'new', 'make', 'schedule',
      'создай', 'создать', 'добавь', 'добавить', 'новая', 'новый', 'новое',
    ]);
    final completeVerb = _hasConcept(m, [
      'complete', 'finish', 'done', 'выполни', 'выполнить', 'заверши', 'завершить',
    ]);
    final updateVerb = _hasConcept(m, [
      'update', 'edit', 'change', 'rename',
      'обнови', 'обновить', 'измени', 'изменить', 'переименуй', 'переименовать',
    ]);
    final deleteVerb = _hasConcept(m, ['delete', 'remove', 'удали', 'удалить']);

    // ── Calendars (collection-level) ─────────────────────────────────────────
    if (calendar && !task && !event) {
      if (createVerb) return pick(['create_calendar']);
      if (deleteVerb) return pick(['delete_calendar']);
      if (updateVerb) return pick(['rename_calendar']);
      // "what's on my calendar today/this week" → events, not the calendar list
      if (agenda) return pick(['list_events']);
      return pick(['list_calendars']);
    }

    // ── Tasks ────────────────────────────────────────────────────────────────
    if (task) {
      if (createVerb) return pick(['create_task']);
      if (completeVerb) return pick(['complete_task']);
      if (updateVerb) return pick(['update_task']);
      if (deleteVerb) return pick(['delete_task']);
      return pick(['list_tasks']);
    }

    // ── Events ───────────────────────────────────────────────────────────────
    if (event) {
      if (createVerb) return pick(['create_event']);
      if (updateVerb) return pick(['update_event']);
      if (deleteVerb) return pick(['delete_event']);
      return pick(['list_events']);
    }

    // ── Agenda / time-based without an explicit noun → events ────────────────
    if (agenda) return pick(['list_events']);

    // ── MCP tools (if connected) ─────────────────────────────────────────────
    if (_mcp != null) {
      if (_hasConcept(m, ['note', 'notes', 'заметка', 'заметки', 'запись', 'записи'])) {
        return pick(['nc_notes_list_notes', 'nc_notes_create_note', 'nc_notes_get_note']);
      }
      if (_hasConcept(m, ['file', 'files', 'folder', 'folders', 'файл', 'файлы', 'папка', 'документ'])) {
        return pick(['nc_files_list_files', 'nc_files_upload_file']);
      }
    }

    // ── Default: conversational ──────────────────────────────────────────────
    return [];
  }

  static bool _kw(String msg, List<String> words) =>
      words.any((w) => msg.contains(w));

  // ── Direct (no-LLM) execution for deterministic list operations ────────────

  /// Returns `(tool, args)` when [userMessage] maps to a list operation that
  /// can be run without the model, or null when the LLM is needed (e.g. a
  /// date range to parse). list_calendars is always direct (no args). For
  /// list_tasks/list_events we bypass only when there's no date/time phrasing;
  /// a calendar-name filter is extracted heuristically (executor falls back to
  /// all calendars if it doesn't match, so a wrong guess is harmless).
  (String, Map<String, dynamic>)? _directListCall(
      String userMessage, List<Map<String, dynamic>> tools) {
    if (tools.length != 1) return null;
    final name = tools.first['name'] as String;
    if (name != 'list_calendars' &&
        name != 'list_tasks' &&
        name != 'list_events') {
      return null;
    }
    final m = userMessage.toLowerCase();
    if (name != 'list_calendars') {
      // Date/time phrasing means the model must parse a range — don't bypass.
      final hasDate = _kw(m, [
        'today', 'tomorrow', 'week', 'month', 'year', 'date', 'yesterday',
        'сегодня', 'завтра', 'вчера', 'недел', 'месяц', 'год', 'число',
        'janu', 'febr', 'march', 'april', 'may', 'june', 'july', 'augu',
        'septe', 'octo', 'nove', 'dece',
      ]);
      if (hasDate) return null;
    }
    final args = <String, dynamic>{};
    if (name != 'list_calendars') {
      final cal = _extractCalendarName(userMessage);
      if (cal != null) args['calendar'] = cal;
    }
    return (name, args);
  }

  /// Best-effort calendar name from phrases like "in Tasks", "в Личный",
  /// "Work calendar", "календарь Работа". Returns null when nothing obvious.
  static String? _extractCalendarName(String msg) {
    final patterns = [
      RegExp(r'\b(?:in|from|в|из)\s+([\p{L}\p{N}_-]+)', unicode: true),
      RegExp(r'([\p{L}\p{N}_-]+)\s+(?:calendar|календар\w*)', unicode: true),
      RegExp(r'(?:calendar|календар\w*)\s+([\p{L}\p{N}_-]+)', unicode: true),
    ];
    const stop = {
      'my', 'the', 'a', 'all', 'me', 'мои', 'мой', 'моя', 'все', 'всех',
      'calendar', 'calendars', 'календарь', 'календари', 'tasks', 'task',
      'events', 'event', 'задачи', 'задач', 'события', 'событий',
    };
    for (final re in patterns) {
      for (final match in re.allMatches(msg)) {
        final cand = match.group(1)!.trim();
        if (cand.isNotEmpty && !stop.contains(cand.toLowerCase())) return cand;
      }
    }
    return null;
  }

  /// True if any token in [msg] matches any of [stems] by exact match,
  /// prefix (stem length ≥5), or Levenshtein edit distance ≤1 (stem length ≥5).
  /// Token-level so word order is irrelevant; the length floor keeps short
  /// verbs like "list"/"show" from fuzzy-matching "lost"/"shower".
  static bool _hasConcept(String msg, List<String> stems) {
    final tokens = msg
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((t) => t.isNotEmpty);
    for (final tok in tokens) {
      for (final stem in stems) {
        if (tok == stem) return true;
        if (stem.length >= 5 && tok.startsWith(stem)) return true;
        if (stem.length >= 5 && tok.length >= 4 && _editDistance(tok, stem) <= 1) {
          return true;
        }
      }
    }
    return false;
  }

  /// Levenshtein distance with an early-out: returns 2 when the answer is >1
  /// (callers only care about the ≤1 threshold).
  static int _editDistance(String a, String b) {
    final m = a.length, n = b.length;
    if ((m - n).abs() > 1) return 2;
    var prev = List<int>.generate(n + 1, (i) => i);
    var cur = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      cur[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        var min = cur[j - 1] + 1;
        if (prev[j] + 1 < min) min = prev[j] + 1;
        if (prev[j - 1] + cost < min) min = prev[j - 1] + cost;
        cur[j] = min;
      }
      final tmp = prev;
      prev = cur;
      cur = tmp;
    }
    return prev[n];
  }

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
          'Answer concisely in the same language as the user. '
          'Do not use <think> tags.\n'
          'You have NO tools or functions available in this turn. '
          'NEVER output tool calls, function calls, JSON such as '
          '{"tool":...} or {"name":...,"arguments":...}, or <tool_call> tags. '
          'If a request would need live calendar/task data you cannot reach, '
          'say so in one short sentence. Otherwise answer directly in plain text.';
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

    // Kept short on purpose: every extra line is CPU prefill before the first
    // token (~30s on this device). One format line + one example + the tools.
    return '''Calendar/task assistant. /no_think Now: $dateStr.
Reply concisely in the user's language. No <think> tags.
To use a tool, output ONLY JSON, nothing else: {"tool":"EXACT_NAME","arguments":{...}}
Use exact tool names below; no-arg tools use "arguments":{}. After <tool_result>, summarize it; never repeat a call. For non-data questions, answer directly.
Example — User: show my calendars → {"tool":"list_calendars","arguments":{}}

Tools:
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
    final defaultCal = prefs.getString('caldav_default_calendar') ?? '';
    if (url.isEmpty || user.isEmpty) {
      _caldav = null;
      return;
    }
    _caldav = CalDavExecutor(
      CalDavClient(serverUrl: url, username: user, password: pass),
      defaultCalendar: defaultCal,
    );
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
    String defaultCalendar = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('caldav_url', url.trim());
    await prefs.setString('caldav_user', user.trim());
    await prefs.setString('caldav_password', password);
    await prefs.setString('caldav_default_calendar', defaultCalendar.trim());
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

    // ── Fast path: skip the LLM for deterministic list operations ────────────
    // The router already classified the intent with 100% confidence; running a
    // ~30s CPU prefill just to emit list_calendars({}) is wasteful. Execute the
    // tool directly and show the pre-formatted result.
    final direct = _directListCall(userMessage, tools);
    if (direct != null) {
      final (toolName, toolArgs) = direct;
      debugPrint('[AI] direct (no-LLM) tool call: $toolName($toolArgs)');
      completedTools.add('🔧 $toolName…');
      _updateMessage(assistantId,
          _buildDisplay(completedTools, '', pending: true), MessageStatus.sending);
      final toolResult = await _executeTool(toolName, toolArgs);
      completedTools[completedTools.length - 1] = '🔧 $toolName ✓';
      final cleanAnswer = _cleanOutput(toolResult);
      _updateMessage(assistantId,
          _buildDisplay(completedTools, cleanAnswer, pending: false),
          MessageStatus.done);
      return cleanAnswer;
    }

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
      var (toolName, toolArgs) = call;

      // Small on-device models sometimes emit a sibling/hallucinated tool name
      // (e.g. list_tasks when asked to create one). When the router offered
      // exactly one tool, its intent classification is more reliable than the
      // model's choice — override to the offered tool.
      final offered = tools.map((t) => t['name'] as String).toList();
      if (tools.length == 1 && toolName != offered.first) {
        debugPrint('[AI] overriding hallucinated tool "$toolName" → "${offered.first}"');
        toolName = offered.first;
      }
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

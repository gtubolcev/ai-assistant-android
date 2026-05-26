import 'dart:io';

import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import '../tools/mcp_bridge.dart';
import '../tools/web_fetch_tool.dart';

/// Default Cactus model slug used when nothing else is configured.
const _kDefaultSlug = 'lfm2-1.2b-tool';

/// SharedPreferences key for the active model slug.
const _kActiveSlugKey = 'active_model_slug';


// NOTE: LFM2-1.2B-Tool requires the system message to contain ONLY the tool
// list in <|tool_list_start|>...<|tool_list_end|> format. The Cactus native
// layer injects this automatically — do NOT add a custom system message to
// _history or it will break the tool list format. See Cactus function_calling
// example: no system message, just user messages + tools in params.

// ── Available Cactus models (tool-calling capable) ─────────────────────────────

class CactusModelInfo {
  final String slug;
  final String name;
  final int sizeMb;
  final String description;
  /// Whether this model supports Cactus tool-calling format.
  /// FunctionGemma uses a different format and crashes with code -1 when tools
  /// are passed — mark it false so we skip tools for it entirely.
  final bool supportsToolCalling;

  const CactusModelInfo({
    required this.slug,
    required this.name,
    required this.sizeMb,
    required this.description,
    this.supportsToolCalling = true,
  });
}

const kAvailableCactusModels = <CactusModelInfo>[
  CactusModelInfo(
    slug: 'functiongemma-270m',
    name: 'FunctionGemma 3 270M',
    sizeMb: 182,
    description: 'Компактная, только текст (без tool calling)',
    supportsToolCalling: false,
  ),
  CactusModelInfo(
    slug: 'qwen3-0.6',
    name: 'Qwen3 0.6B',
    sizeMb: 394,
    description: 'Маленькая, хорошо работает с инструментами',
  ),
  CactusModelInfo(
    slug: 'lfm2-1.2b-tool',
    name: 'LFM2 1.2B Tool ★',
    sizeMb: 729,
    description: 'Рекомендуется — обучена специально для tool calling',
  ),
  CactusModelInfo(
    slug: 'qwen3-1.7',
    name: 'Qwen3 1.7B',
    sizeMb: 1161,
    description: 'Лучший tool calling, занимает больше памяти',
  ),
];

// ── Provider ───────────────────────────────────────────────────────────────────

class ChatProvider extends ChangeNotifier {
  // ── Public state ───────────────────────────────────────────────────────────

  final List<AppMessage> messages = [];
  bool isLoading = false;
  bool isModelReady = false;
  String statusText = 'Инициализация…';
  String? errorText;
  bool get isMcpConnected => _mcp?.isConnected ?? false;

  /// Slug of the currently active model (or empty if none loaded).
  String get activeModelSlug => _activeModelSlug;

  // ── Internals ─────────────────────────────────────────────────────────────

  CactusLM? _lm;
  McpBridge? _mcp;
  bool _stopRequested = false;
  String _activeModelSlug = _kDefaultSlug;

  /// Request the current generation to stop at the next safe checkpoint.
  void stopGeneration() {
    _stopRequested = true;
    notifyListeners();
  }

  /// Full MCP tool list (cached from connection).
  List<CactusTool> get _allMcpTools => _mcp?.tools ?? [];

  // ── Tool selection ────────────────────────────────────────────────────────
  //
  // No custom intent detection. We pick a small category of Nextcloud tools
  // based on broad keywords and let the MODEL decide which one to call.
  // After each call, the same category is offered again so the model can
  // chain calls or write a text answer (it will, once it has what it needs).

  /// Returns a small fixed set of tools for the current message.
  /// Always includes web_fetch. Never returns [].
  List<CactusTool> _toolsForMessage(String userMessage) {
    final m = userMessage.toLowerCase();
    final byName = {for (final t in _allMcpTools) t.name: t};

    List<CactusTool> pick(List<String> names) =>
        names.map((n) => byName[n]).whereType<CactusTool>().toList();

    // Web only
    if (_kw(m, ['http://', 'https://', 'fetch url', 'open url'])) {
      return [webFetchTool];
    }

    // Contacts
    if (_kw(m, ['contact', 'phone', 'контакт', 'телефон', 'адресн'])) {
      return [webFetchTool, ...pick([
        'nc_contacts_list_contacts', 'nc_contacts_get_contact', 'nc_contacts_create_contact',
      ])];
    }

    // Notes
    if (_kw(m, ['note', 'notes', 'заметк', 'запис'])) {
      return [webFetchTool, ...pick([
        'nc_notes_list_notes', 'nc_notes_create_note', 'nc_notes_get_note',
      ])];
    }

    // Files
    if (_kw(m, ['file', 'folder', 'файл', 'папк', 'документ'])) {
      return [webFetchTool, ...pick([
        'nc_files_list_files', 'nc_files_upload_file', 'nc_files_get_file_info',
      ])];
    }

    // Deck
    if (_kw(m, ['deck', 'board', 'kanban', 'card', 'борд', 'канбан'])) {
      return [webFetchTool, ...pick([
        'nc_deck_list_boards', 'nc_deck_create_card', 'nc_deck_list_cards',
      ])];
    }

    // Default: calendar + tasks (most common)
    return [webFetchTool, ...pick([
      'nc_calendar_list_calendars',
      'nc_calendar_get_upcoming_events',
      'nc_calendar_create_event',
      'nc_calendar_list_todos',
      'nc_calendar_create_todo',
    ])];
  }

  static bool _kw(String msg, List<String> words) =>
      words.any((w) => msg.contains(w));

  final List<ChatMessage> _history = [];

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> init() async {
    try {
      statusText = 'Инициализация…';
      notifyListeners();

      final prefs = await SharedPreferences.getInstance();
      _activeModelSlug = prefs.getString(_kActiveSlugKey) ?? _kDefaultSlug;

      _history
        ..clear();
      // Do NOT add a system message — LFM2 chat template puts the tool list
      // in the system slot via <|tool_list_start|>; our text would break it.

      // Disable Cactus built-in tool filtering — we do our own intent-based
      // filtering (_toolsFor) that already limits to ≤5 tools per request.
      _lm = CactusLM(enableToolFiltering: false);

      // Check if model is already available — do NOT auto-download.
      final cached = await _isModelCached(_activeModelSlug);
      if (!cached) {
        statusText = 'Выберите модель в Настройках';
        notifyListeners();
        // MCP can still connect independently of the model.
        await _connectMcp();
        return;
      }


      statusText = 'Инициализация модели…';
      notifyListeners();

      debugPrint('Initializing context with model: $_activeModelSlug');
      await _lm!.initializeModel(
        params: CactusInitParams(model: _activeModelSlug, contextSize: 4096),
      );

      isModelReady = true;
      statusText = 'Модель готова';
      notifyListeners();

      await _connectMcp();
    } catch (e) {
      errorText = 'Ошибка инициализации: $e';
      statusText = 'Ошибка';
      notifyListeners();
    }
  }

  /// Returns the set of model slugs that are already downloaded to internal storage.
  /// Imported local files are stored under their matching CDN slug directory,
  /// so they appear here the same way as CDN downloads.
  Future<Set<String>> downloadedModelSlugs() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final result = <String>{};
    for (final m in kAvailableCactusModels) {
      final dir = Directory('${appDocDir.path}/models/${m.slug}');
      if (await _dirHasFiles(dir)) result.add(m.slug);
    }
    return result;
  }

  /// Returns true if the model files are already present in internal storage.
  Future<bool> _isModelCached(String slug) async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final internalDir = Directory('${appDocDir.path}/models/$slug');
    return _dirHasFiles(internalDir);
  }

  // ── Download & load from Cactus CDN ──────────────────────────────────────

  /// Downloads a model by [slug] from the Cactus CDN (if not already cached)
  /// and initialises the LM.  Updates [statusText] / [errorText] throughout.
  Future<void> downloadAndLoadModel(String slug) async {
    isModelReady = false;
    errorText = null;
    notifyListeners();

    try {
      _activeModelSlug = slug;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kActiveSlugKey, slug);

      // Disable Cactus built-in tool filtering — we do our own intent-based
      // filtering (_toolsFor) that already limits to ≤5 tools per request.
      _lm = CactusLM(enableToolFiltering: false);

      // Download only if not already in internal storage.
      final appDocDir = await getApplicationDocumentsDirectory();
      final internalDir = Directory('${appDocDir.path}/models/$slug');
      if (!await _dirHasFiles(internalDir)) {
        statusText = 'Загрузка модели…';
        notifyListeners();

        await _lm!.downloadModel(
          model: slug,
          downloadProcessCallback: (progress, status, isError) {
            if (isError) {
              errorText = status;
            } else {
              final pct = progress != null
                  ? ' ${(progress * 100).toStringAsFixed(0)}%'
                  : '';
              statusText = 'Загрузка$pct';
            }
            notifyListeners();
          },
        );
      }

      statusText = 'Инициализация модели…';
      notifyListeners();

      await _lm!.initializeModel(
        params: CactusInitParams(model: slug, contextSize: 4096),
      );

      isModelReady = true;
      statusText = isMcpConnected
          ? 'Готово (${_mcp!.tools.length} инструментов)'
          : 'Модель загружена';
    } catch (e) {
      errorText = 'Ошибка загрузки: $e';
      statusText = 'Ошибка';
    }
    notifyListeners();
  }

  // ── Import from local file ────────────────────────────────────────────────

  /// Maps a GGUF filename to the Cactus CDN slug it belongs to.
  // ── Import from local file (NOT SUPPORTED with Cactus) ───────────────────

  /// Cactus uses its own proprietary model format (config.txt + custom weight
  /// files) — it does NOT support llama.cpp GGUF files at all.
  ///
  /// This method always shows an explanatory error so the user understands
  /// why the feature doesn't work and what to do instead.
  Future<void> importModelFromFile(String filePath) async {
    isModelReady = false;
    statusText = 'Ошибка';
    errorText =
        'Импорт GGUF-файлов не поддерживается.\n\n'
        'Cactus SDK использует собственный формат моделей (config.txt + '
        'файлы весов), несовместимый с llama.cpp GGUF.\n\n'
        'Пожалуйста, скачайте модель из списка выше — '
        'они хранятся на CDN Cactus в нужном формате.';
    notifyListeners();
    return;
  }

  Future<bool> _dirHasFiles(Directory dir) async {
    if (!await dir.exists()) return false;
    return await dir.list().any((_) => true);
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
    final lm = _lm!;
    const maxIterations = 8;
    final completedTools = <String>[];
    _stopRequested = false;

    // Check whether the active model supports Cactus tool-calling format.
    final activeModelInfo = kAvailableCactusModels
        .where((m) => m.slug == _activeModelSlug)
        .firstOrNull;
    final modelSupportsTools = activeModelInfo?.supportsToolCalling ?? true;

    // Warn early if MCP not connected (only relevant when tools are supported).
    if (modelSupportsTools && _allMcpTools.isEmpty) {
      debugPrint('[AI] WARNING: MCP tools empty — server not configured?');
      _updateMessage(
        assistantId,
        '⚠️ MCP не подключён. Настройте сервер в Настройках.',
        MessageStatus.error,
      );
      return;
    }

    final tools = modelSupportsTools ? _toolsForMessage(userMessage) : <CactusTool>[];
    debugPrint('[AI] msg="$userMessage" tools=${tools.map((t) => t.name).toList()}');

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

      debugPrint('[AI] iter=$iter tools=${tools.map((t) => t.name).toList()}');

      final streamResult = await lm.generateCompletionStream(
        messages: List.from(_history),
        params: CactusCompletionParams(
          tools: tools,
          // LFM2-1.2B-Tool authors recommend temperature=0 (greedy decoding)
          // for reliable tool calling. For conversational replies without tools
          // a small value is still fine, but 0 works well universally here.
          temperature: 0,
          maxTokens: 512,
        ),
      );

      final buffer = StringBuffer();
      // Cactus SDK may call controller.addError(CactusCompletionResult) on
      // failure — catch it here so we can still await streamResult.result below.
      try {
        await for (final chunk in streamResult.stream) {
          if (_stopRequested) break;
          buffer.write(chunk);
          _updateMessage(
            assistantId,
            _buildDisplay(completedTools, _stripToolMarkup(buffer.toString()),
                pending: true),
            MessageStatus.sending,
          );
        }
      } catch (_) {
        // Stream error: result Future will have success=false with the message.
      }

      if (_stopRequested) {
        _stopRequested = false;
        final partial = buffer.toString();
        if (partial.isNotEmpty) {
          _history.add(ChatMessage(role: 'assistant', content: partial));
        }
        _updateMessage(
          assistantId,
          _buildDisplay(
              completedTools,
              '${_stripToolMarkup(partial)}\n⏹ остановлено'.trim(),
              pending: false),
          MessageStatus.done,
        );
        return;
      }

      final iterResult = await streamResult.result;

      // Surface native-side errors in a human-readable form.
      if (!iterResult.success) {
        final msg = iterResult.response?.isNotEmpty == true
            ? iterResult.response!
            : 'Неизвестная ошибка генерации';
        _updateMessage(
          assistantId,
          _buildDisplay(completedTools, '⚠️ $msg', pending: false),
          MessageStatus.error,
        );
        return;
      }

      debugPrint('[AI] iter=$iter success=${iterResult.success} toolCalls=${iterResult.toolCalls.map((c) => "${c.name}(${c.arguments})").toList()} response="${iterResult.response?.substring(0, iterResult.response!.length.clamp(0, 120))}"');

      if (iterResult.toolCalls.isEmpty) {
        final text = buffer.toString();
        _history.add(ChatMessage(role: 'assistant', content: text));
        _updateMessage(
          assistantId,
          _buildDisplay(completedTools, _stripToolMarkup(text), pending: false),
          MessageStatus.done,
        );
        return;
      }

      if (buffer.isNotEmpty) {
        _history.add(ChatMessage(role: 'assistant', content: buffer.toString()));
      }

      for (final call in iterResult.toolCalls) {
        if (_stopRequested) break;
        completedTools.add('🔧 ${call.name}…');
        _updateMessage(
          assistantId,
          _buildDisplay(completedTools, '', pending: true),
          MessageStatus.sending,
        );
        final toolResult = await _executeTool(call);
        debugPrint('[AI] tool ${call.name} result="${toolResult.substring(0, toolResult.length.clamp(0, 200))}"');
        completedTools[completedTools.length - 1] = '🔧 ${call.name} ✓';
        _history.add(ChatMessage(role: 'tool', content: toolResult));
      }
    }

    _updateMessage(
      assistantId,
      _buildDisplay(completedTools, '(превышен лимит итераций)', pending: false),
      MessageStatus.done,
    );
  }

  static String _buildDisplay(List<String> tools, String text,
      {required bool pending}) {
    final parts = <String>[];
    if (tools.isNotEmpty) parts.add(tools.join('\n'));
    if (text.isNotEmpty) parts.add(text);
    if (parts.isEmpty && pending) return '…';
    return parts.join('\n\n');
  }

  // ── Tool executor ─────────────────────────────────────────────────────────

  Future<String> _executeTool(ToolCall call) async {
    if (call.name == 'web_fetch') {
      return executeWebFetch(call.arguments);
    }
    final mcp = _mcp;
    if (mcp == null || !mcp.isConnected) {
      return 'MCP недоступен. Проверь настройки сервера.';
    }
    return mcp.executeTool(
      call.name,
      Map<String, dynamic>.from(call.arguments),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _stripToolMarkup(String text) {
    var result = text.replaceAll(
      RegExp(r'<\|tool_call_start\|>.*?<\|tool_call_end\|>', dotAll: true),
      '',
    );
    result = result.replaceAll(
        RegExp(r'<\|tool_call_start\|>.*$', dotAll: true), '');
    result = result.replaceAll(
        RegExp(r'<\|im_end\|>|<\|im_start\|>|<\|tool_call_end\|>'), '');
    return result.trim();
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
    _lm?.unload();
    _lm = null;
    super.dispose();
  }
}

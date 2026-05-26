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

/// Slug used for user-imported local GGUF files.
const _kLocalSlug = 'local';

/// SharedPreferences key for the last imported file path.
const _kModelSourceKey = 'model_source_path';

/// Builds the system prompt for the on-device LLM.
String _buildSystemPrompt() {
  return 'You are a helpful personal AI assistant running entirely on the user\'s '
      'device. You have access to tools: '
      'web_fetch (fetch any URL and return its content), '
      'and Nextcloud tools (nc_calendar_*, nc_contacts_*, nc_notes_*, nc_deck_*, nc_files_*, etc.) '
      'for calendar events, todos/tasks, contacts, notes, files, and more. '
      'IMPORTANT: for any calendar or task operation, ALWAYS call '
      'nc_calendar_list_calendars first to discover available calendar names, '
      'then use those exact names in the calendar_name argument. '
      'Never guess or invent calendar names or URLs. '
      'Always respond in the same language the user uses. '
      'Be concise.';
}

// ── Available Cactus models (tool-calling capable) ─────────────────────────────

class CactusModelInfo {
  final String slug;
  final String name;
  final int sizeMb;
  final String description;

  const CactusModelInfo({
    required this.slug,
    required this.name,
    required this.sizeMb,
    required this.description,
  });
}

const kAvailableCactusModels = <CactusModelInfo>[
  CactusModelInfo(
    slug: 'functiongemma-270m',
    name: 'FunctionGemma 3 270M',
    sizeMb: 182,
    description: 'Самая компактная, быстрее всего отвечает',
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

  /// Returns a context-filtered tool list for the given user message.
  ///
  /// A small model can't reliably choose from 134 tools — show only the
  /// relevant subset (≤ ~20) based on keywords in the message.
  List<CactusTool> _toolsFor(String userMessage) {
    final m = userMessage.toLowerCase();

    // ── Keyword groups (EN + RU) ───────────────────────────────────────────
    final wantsCalendar = _kw(m, [
      'calendar', 'event', 'meeting', 'schedule', 'remind',
      'calendars', 'upcoming', 'appointment',
      'календар', 'событи', 'встреч', 'расписан', 'напомин',
    ]);
    final wantsTodo = _kw(m, [
      'task', 'todo', 'tasks', 'todos',
      'задач', 'задание', 'список дел',
    ]);
    final wantsContact = _kw(m, [
      'contact', 'address', 'phone', 'email',
      'контакт', 'адрес', 'телефон', 'почт',
    ]);
    final wantsNote = _kw(m, [
      'note', 'notes',
      'заметк', 'запис',
    ]);
    final wantsFile = _kw(m, [
      'file', 'folder', 'upload', 'download', 'document',
      'файл', 'папк', 'загруз', 'документ',
    ]);
    final wantsDeck = _kw(m, [
      'deck', 'board', 'kanban', 'card', 'stack',
      'борд', 'канбан', 'карточк',
    ]);

    final prefixes = <String>[];
    if (wantsCalendar || wantsTodo) prefixes.add('nc_calendar');
    if (wantsContact) prefixes.add('nc_contacts');
    if (wantsNote) prefixes.add('nc_notes');
    if (wantsFile) prefixes.add('nc_files');
    if (wantsDeck) prefixes.add('nc_deck');

    List<CactusTool> mcpSelected;
    if (prefixes.isEmpty) {
      const core = {
        'nc_calendar_list_calendars',
        'nc_calendar_get_upcoming_events',
        'nc_calendar_list_events',
        'nc_calendar_create_event',
        'nc_calendar_list_todos',
        'nc_calendar_create_todo',
        'nc_contacts_list_contacts',
        'nc_notes_list_notes',
        'nc_notes_create_note',
      };
      mcpSelected = _allMcpTools.where((t) => core.contains(t.name)).toList();
    } else {
      mcpSelected = _allMcpTools
          .where((t) => prefixes.any((p) => t.name.startsWith(p)))
          .toList();
    }

    return [webFetchTool, ...mcpSelected];
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
        ..clear()
        ..add(ChatMessage(role: 'system', content: _buildSystemPrompt()));

      _lm = CactusLM();

      // Check if model is already available — do NOT auto-download.
      final cached = await _isModelCached(_activeModelSlug);
      if (!cached) {
        statusText = 'Выберите модель в Настройках';
        notifyListeners();
        // MCP can still connect independently of the model.
        await _connectMcp();
        return;
      }

      // Handle custom path import if needed.
      await _ensureCustomPathImported(prefs);

      statusText = 'Инициализация модели…';
      notifyListeners();

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
  Future<Set<String>> downloadedModelSlugs() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final result = <String>{};
    for (final m in kAvailableCactusModels) {
      final dir = Directory('${appDocDir.path}/models/${m.slug}');
      if (await _dirHasFiles(dir)) result.add(m.slug);
    }
    // Also add local if present
    final localDir = Directory('${appDocDir.path}/models/$_kLocalSlug');
    if (await _dirHasFiles(localDir)) result.add(_kLocalSlug);
    return result;
  }

  /// Returns true if the model files are already present in internal storage
  /// or a valid custom path is saved.
  Future<bool> _isModelCached(String slug) async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final internalDir = Directory('${appDocDir.path}/models/$slug');
    if (await _dirHasFiles(internalDir)) return true;

    final prefs = await SharedPreferences.getInstance();
    final customPath = (prefs.getString('model_path') ?? '').trim();
    if (customPath.isNotEmpty) {
      final source = await _resolveModelSource(customPath);
      if (source != null) return true;
    }

    return false;
  }

  /// If a custom model_path is set, imports it to internal storage if not
  /// already done for that exact source path.
  Future<void> _ensureCustomPathImported(SharedPreferences prefs) async {
    final customPath = (prefs.getString('model_path') ?? '').trim();
    if (customPath.isEmpty) return;

    final appDocDir = await getApplicationDocumentsDirectory();
    final internalDir = Directory('${appDocDir.path}/models/$_activeModelSlug');
    final cachedSource = prefs.getString(_kModelSourceKey) ?? '';

    if (cachedSource == customPath && await _dirHasFiles(internalDir)) {
      debugPrint('Model already imported from $customPath — using cache');
      return;
    }

    final source = await _resolveModelSource(customPath);
    if (source == null) {
      errorText = 'Модель не найдена: $customPath';
      notifyListeners();
      return;
    }

    statusText = 'Копирование модели…';
    notifyListeners();
    if (await internalDir.exists()) await internalDir.delete(recursive: true);
    await _importModelToInternal(source, internalDir);
    await prefs.setString(_kModelSourceKey, customPath);
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

      _lm = CactusLM();

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

  /// Imports a GGUF file chosen by the user via the file picker.
  ///
  /// Copies the file to the [_kLocalSlug] model directory and re-initialises
  /// Cactus.  Only llama.cpp-compatible GGUFs will work.
  Future<void> importModelFromFile(String filePath) async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final internalDir = Directory('${appDocDir.path}/models/$_kLocalSlug');
    final prefs = await SharedPreferences.getInstance();

    isModelReady = false;
    statusText = 'Копирование модели…';
    errorText = null;
    notifyListeners();

    try {
      // Wipe old local model, copy new one.
      if (await internalDir.exists()) await internalDir.delete(recursive: true);
      await _importModelToInternal(File(filePath), internalDir);

      final files = await internalDir.list().toList();
      if (files.isEmpty) {
        throw Exception(
            'Файл скопирован, но директория пуста — '
            'проверьте разрешения или выберите файл снова');
      }
      debugPrint('Imported: ${files.map((f) => f.path).join(', ')}');

      // Switch to local slug.
      _activeModelSlug = _kLocalSlug;
      await prefs.setString(_kActiveSlugKey, _kLocalSlug);
      await prefs.setString(_kModelSourceKey, filePath);

      statusText = 'Инициализация модели…';
      notifyListeners();

      _lm = CactusLM();
      await _lm!.initializeModel(
        params: CactusInitParams(model: _kLocalSlug, contextSize: 4096),
      );

      isModelReady = true;
      statusText = isMcpConnected
          ? 'Готово (${_mcp!.tools.length} инструментов)'
          : 'Модель загружена';
    } catch (e) {
      errorText = 'Не удалось загрузить выбранный файл.\n'
          'Файл должен быть совместим с llama.cpp.\n'
          'Рекомендуем скачать модель из списка в Настройках.\n'
          'Детали: $e';
      statusText = 'Ошибка';
    }
    notifyListeners();
  }

  // ── Model resolution helpers ──────────────────────────────────────────────

  Future<FileSystemEntity?> _resolveModelSource(String path) async {
    final f = File(path);
    if (await f.exists() && path.toLowerCase().endsWith('.gguf')) return f;
    final d = Directory(path);
    if (await d.exists() && await _dirHasFiles(d)) return d;
    return null;
  }

  Future<void> _importModelToInternal(
      FileSystemEntity source, Directory dest) async {
    await dest.create(recursive: true);

    if (source is File) {
      final name = source.path.split('/').last;
      statusText = 'Копирование модели…';
      notifyListeners();
      await source.copy('${dest.path}/$name');
    } else if (source is Directory) {
      final entities = await source.list().toList();
      final files = entities.whereType<File>().toList();
      for (int i = 0; i < files.length; i++) {
        final name = files[i].path.split('/').last;
        statusText = 'Копирование модели… (${i + 1}/${files.length})';
        notifyListeners();
        await files[i].copy('${dest.path}/$name');
      }
    }
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

  Future<void> saveModelPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('model_path', path.trim());
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
      await _runAgentLoop(assistantId, tools: _toolsFor(text.trim()));
    } catch (e) {
      _updateMessage(assistantId, 'Ошибка: $e', MessageStatus.error);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  // ── Agent loop ────────────────────────────────────────────────────────────

  Future<void> _runAgentLoop(String assistantId,
      {List<CactusTool> tools = const []}) async {
    final lm = _lm!;
    const maxIterations = 8;
    final completedTools = <String>[];
    _stopRequested = false;

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

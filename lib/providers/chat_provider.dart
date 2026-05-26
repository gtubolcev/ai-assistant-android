import 'dart:io';

import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import '../tools/mcp_bridge.dart';
import '../tools/web_fetch_tool.dart';

/// Cactus model slug to use.
const _kModelSlug = 'lfm2-1.2b-tool';

/// Builds the system prompt, embedding CalDAV connection details when configured
/// so the model passes correct calendar_url / addressbook_url / credentials.
String _buildSystemPrompt({
  String? caldavUrl,
  String? caldavUser,
  String? caldavPassword,
}) {
  String caldavHint = '';
  if (caldavUrl != null && caldavUrl.isNotEmpty) {
    caldavHint = ' CalDAV base URL: $caldavUrl.';
    if (caldavUser != null && caldavUser.isNotEmpty) {
      caldavHint += ' Username: $caldavUser.';
      // Derive the default calendar URL from base + username if not a full path.
      final defaultCalUrl = caldavUrl.endsWith('/')
          ? '${caldavUrl}calendars/$caldavUser/'
          : '$caldavUrl/calendars/$caldavUser/';
      caldavHint += ' Default calendars root: $defaultCalUrl.';
    }
    if (caldavPassword != null && caldavPassword.isNotEmpty) {
      caldavHint += ' Password: $caldavPassword.';
    }
    caldavHint += ' Use list_calendars to discover specific calendar URLs,'
        ' then use those exact URLs in calendar_url arguments.';
  } else {
    caldavHint = ' IMPORTANT: never guess calendar_url — always call'
        ' list_calendars first to discover available calendars.';
  }
  return 'You are a helpful personal AI assistant running entirely on the user\'s '
      'device. You have access to tools: '
      'web_fetch (fetch any URL and return its content), '
      'and CalDAV tools for calendar/contacts/tasks (list, create, update, delete).$caldavHint '
      'Always respond in the same language the user uses. '
      'Be concise — you run on a 1.2B parameter model.';
}

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
  final List<ChatMessage> _history = [];

  // ── Initialisation ────────────────────────────────────────────────────────

  Future<void> init() async {
    try {
      statusText = 'Поиск модели…';
      notifyListeners();

      // Build system prompt with CalDAV credentials if configured.
      final prefs = await SharedPreferences.getInstance();
      _history
        ..clear()
        ..add(ChatMessage(
          role: 'system',
          content: _buildSystemPrompt(
            caldavUrl: prefs.getString('caldav_url'),
            caldavUser: prefs.getString('caldav_user'),
            caldavPassword: prefs.getString('caldav_password'),
          ),
        ));

      _lm = CactusLM();

      // Ensure model is present (from settings path, external storage, or download).
      await _ensureModelAvailable();

      statusText = 'Инициализация модели…';
      notifyListeners();

      await _lm!.initializeModel(
        params: CactusInitParams(model: _kModelSlug, contextSize: 4096),
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

  // ── Model resolution ───────────────────────────────────────────────────────

  /// SharedPreferences key that records which source path was last imported.
  /// Used to avoid re-copying when the app restarts with the same custom path.
  static const _kModelSourceKey = 'model_source_path';

  /// Ensures the model is in Cactus's internal directory.
  ///
  /// Priority:
  ///   1. User-specified path (settings) — always wins; re-imports if path changed.
  ///   2. Internal cache — used when no custom path is set.
  ///   3. Auto-search in external (package-scoped) storage.
  ///   4. Download from Cactus servers.
  Future<void> _ensureModelAvailable() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final internalDir = Directory('${appDocDir.path}/models/$_kModelSlug');
    final prefs = await SharedPreferences.getInstance();

    // 1. Custom path from settings takes priority.
    final customPath = (prefs.getString('model_path') ?? '').trim();
    if (customPath.isNotEmpty) {
      final cachedSource = prefs.getString(_kModelSourceKey) ?? '';
      // Skip re-import if the cache was already built from this exact path.
      if (cachedSource == customPath && await _dirHasFiles(internalDir)) {
        debugPrint('Model already imported from $customPath — using cache');
        return;
      }
      statusText = 'Поиск модели: $customPath';
      notifyListeners();
      final source = await _resolveModelSource(customPath);
      if (source != null) {
        // Clear stale cache, then import from the new source.
        if (await internalDir.exists()) await internalDir.delete(recursive: true);
        await _importModelToInternal(source, internalDir);
        await prefs.setString(_kModelSourceKey, customPath);
        return;
      }
      // Path is set but nothing found — warn and fall through.
      errorText = 'Модель не найдена: $customPath';
      notifyListeners();
    }

    // 2. Already cached internally (from a previous download or import)?
    if (await _dirHasFiles(internalDir)) {
      debugPrint('Model found in internal cache: ${internalDir.path}');
      return;
    }

    // 3. Auto-search in external (package-scoped) storage.
    statusText = 'Поиск модели во внешнем хранилище…';
    notifyListeners();
    final extSource = await _searchExternalStorage();
    if (extSource != null) {
      debugPrint('Model found in external storage: ${extSource.path}');
      await _importModelToInternal(extSource, internalDir);
      return;
    }

    // 4. Download from Cactus servers.
    errorText = null;
    await _lm!.downloadModel(
      model: _kModelSlug,
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
  }

  /// Resolves a user-supplied path to a model source (File or Directory).
  /// Returns null if nothing usable is found at that path.
  Future<FileSystemEntity?> _resolveModelSource(String path) async {
    // Single GGUF file.
    final f = File(path);
    if (await f.exists() && path.toLowerCase().endsWith('.gguf')) return f;

    // Directory containing model files.
    final d = Directory(path);
    if (await d.exists() && await _dirHasFiles(d)) return d;

    return null;
  }

  /// Searches package-specific external storage for a compatible model.
  ///
  /// Looks in:
  ///   <external>/models/<slug>/   — exact slug folder
  ///   <external>/models/          — any *.gguf file in the root
  Future<FileSystemEntity?> _searchExternalStorage() async {
    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir == null) return null;

      // Exact slug directory.
      final slugDir = Directory('${extDir.path}/models/$_kModelSlug');
      if (await _dirHasFiles(slugDir)) return slugDir;

      // Any .gguf directly in <external>/models/.
      final modelsDir = Directory('${extDir.path}/models');
      if (await modelsDir.exists()) {
        await for (final entity in modelsDir.list()) {
          if (entity is File && entity.path.toLowerCase().endsWith('.gguf')) {
            return entity;
          }
        }
      }
    } catch (e) {
      debugPrint('External storage search failed: $e');
    }
    return null;
  }

  /// Copies a GGUF file or directory of files into [dest] (Cactus model dir).
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
      final files =
          entities.whereType<File>().toList();
      for (int i = 0; i < files.length; i++) {
        final name = files[i].path.split('/').last;
        statusText =
            'Копирование модели… (${i + 1}/${files.length})';
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
    final token = prefs.getString('mcp_token');

    if (url == null || url.isEmpty) {
      statusText = 'Модель готова (MCP не настроен)';
      notifyListeners();
      return;
    }

    try {
      statusText = 'Подключение к MCP…';
      notifyListeners();

      await _mcp?.disconnect();
      // Token is optional — servers without auth (e.g. single_user_basic) work fine.
      _mcp = McpBridge(serverUrl: url, bearerToken: token ?? '');
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
      // Strip tool-call markup from the live display; Cactus parses it separately.
      _updateMessage(
          assistantId, _stripToolMarkup(buffer.toString()), MessageStatus.sending);
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

  /// Saves the user-specified model path.
  /// Empty string clears the override (use auto-detection).
  Future<void> saveModelPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('model_path', path.trim());
  }

  /// Saves CalDAV connection details used to build the system prompt.
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

  /// Returns the path where the model should be placed in external storage
  /// for auto-detection on next launch (shown as a hint to the user).
  Future<String> externalModelHintPath() async {
    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        return '${extDir.path}/models/$_kModelSlug/';
      }
    } catch (_) {}
    return '/sdcard/Android/data/<pkg>/files/models/$_kModelSlug/';
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Removes LFM/ChatML special tokens from text before displaying it.
  /// Handles both complete and still-open (streaming) tool-call blocks.
  static String _stripToolMarkup(String text) {
    // Remove complete <|tool_call_start|>...<|tool_call_end|> blocks.
    var result = text.replaceAll(
      RegExp(r'<\|tool_call_start\|>.*?<\|tool_call_end\|>', dotAll: true),
      '',
    );
    // Remove an open (not-yet-closed) block that started but hasn't ended.
    result = result.replaceAll(
        RegExp(r'<\|tool_call_start\|>.*$', dotAll: true), '');
    // Remove stray ChatML / LFM control tokens.
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

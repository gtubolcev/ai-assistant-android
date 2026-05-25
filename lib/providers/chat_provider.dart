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
      statusText = 'Поиск модели…';
      notifyListeners();

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

  /// Ensures the model is in Cactus's internal directory.
  /// Priority: internal cache → user-specified path → external storage → download.
  Future<void> _ensureModelAvailable() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final internalDir = Directory('${appDocDir.path}/models/$_kModelSlug');

    // 1. Already cached internally?
    if (await _dirHasFiles(internalDir)) {
      debugPrint('Model found in internal cache: ${internalDir.path}');
      return;
    }

    // 2. Custom path from settings?
    final prefs = await SharedPreferences.getInstance();
    final customPath = (prefs.getString('model_path') ?? '').trim();
    if (customPath.isNotEmpty) {
      statusText = 'Поиск модели: $customPath';
      notifyListeners();
      final source = await _resolveModelSource(customPath);
      if (source != null) {
        await _importModelToInternal(source, internalDir);
        return;
      }
      // Path is set but nothing found — let the user know and fall through.
      errorText = 'Модель не найдена: $customPath';
      notifyListeners();
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

  /// Saves the user-specified model path.
  /// Empty string clears the override (use auto-detection).
  Future<void> saveModelPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('model_path', path.trim());
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

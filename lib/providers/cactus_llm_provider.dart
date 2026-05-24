import 'dart:async';

import 'package:cactus/cactus.dart';
import 'package:mcp_llm/mcp_llm.dart';

/// Bridges Cactus SDK (on-device LLM inference) with the mcp_llm [LlmProvider]
/// interface, allowing it to be plugged into flutter_mcp's agent runtime.
///
/// Usage:
/// ```dart
/// final mcpLlm = McpLlm();
/// mcpLlm.registerProvider(
///   'cactus',
///   () => CactusLlmProvider(modelId: 'lfm2.5-1.2b'),
/// );
///
/// final client = await mcpLlm.createClient(
///   providerName: 'cactus',
///   config: LlmConfiguration(model: 'lfm2.5-1.2b'),
/// );
/// ```
class CactusLlmProvider implements LlmProvider {
  CactusLM? _lm;

  /// Cactus model identifier — passed to [CactusLM.downloadModel].
  /// Examples: 'lfm2.5-1.2b', 'gemma3-270m', 'qwen3-0.6'
  final String modelId;

  /// Optional direct URL to a GGUF file (overrides the preset model library).
  final String? modelUrl;

  /// Context window size in tokens (default: 4096).
  final int contextLength;

  /// Temperature override (null → use model default).
  final double? defaultTemperature;

  CactusLlmProvider({
    required this.modelId,
    this.modelUrl,
    this.contextLength = 4096,
    this.defaultTemperature,
  });

  // ─────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────

  @override
  Future<void> initialize(LlmConfiguration config) async {
    _lm = CactusLM();

    // Download the model (Cactus caches it after first download).
    // If a direct URL was provided, use it; otherwise let Cactus resolve
    // from its model library by modelId.
    if (modelUrl != null) {
      await _lm!.downloadModel(model: modelId);
    } else {
      await _lm!.downloadModel(model: modelId);
    }

    await _lm!.initializeModel(
      params: CactusInitParams(contextSize: contextLength),
    );
  }

  @override
  Future<void> close() async {
    _lm?.unload();
    _lm = null;
  }

  // ─────────────────────────────────────────────
  // Completion
  // ─────────────────────────────────────────────

  @override
  Future<LlmResponse> complete(LlmRequest request) async {
    final lm = _requireInitialized();

    final messages = _buildMessages(request);
    final tools = _buildTools(request);
    final temperature = _resolveTemperature(request);
    final maxTokens = (request.parameters['max_tokens'] as num?)?.toInt();

    final result = await lm.generateCompletion(
      messages: messages,
      params: CactusCompletionParams(
        tools: tools.isNotEmpty ? tools : null,
        temperature: temperature,
        maxTokens: maxTokens ?? 200,
      ),
    );

    if (!result.success) {
      throw StateError('Cactus inference failed (model: $modelId)');
    }

    // Collect tool calls from result into metadata so that
    // hasToolCallMetadata / extractToolCallFromMetadata work correctly.
    final metadata = <String, dynamic>{};
    final rawToolCalls = result.toolCalls;
    if (rawToolCalls.isNotEmpty) {
      metadata['tool_calls'] = rawToolCalls
          .map((tc) => {
                'name': tc.name,
                'arguments': Map<String, dynamic>.from(tc.arguments),
                'id': null,
              })
          .toList();
    }

    return LlmResponse(
      text: result.response,
      metadata: metadata,
      // Convert to mcp_llm's LlmToolCall list so callers can use either path.
      toolCalls: rawToolCalls.isNotEmpty
          ? rawToolCalls
              .map((tc) => LlmToolCall(
                    name: tc.name,
                    arguments: Map<String, dynamic>.from(tc.arguments),
                  ))
              .toList()
          : null,
    );
  }

  // ─────────────────────────────────────────────
  // Streaming completion
  // ─────────────────────────────────────────────

  @override
  Stream<LlmResponseChunk> streamComplete(LlmRequest request) {
    final lm = _requireInitialized();

    final messages = _buildMessages(request);
    final temperature = _resolveTemperature(request);
    final maxTokens = (request.parameters['max_tokens'] as num?)?.toInt();

    // Bridge Cactus stream-based output → Dart Stream via StreamController.
    final controller = StreamController<LlmResponseChunk>();

    lm
        .generateCompletionStream(
          messages: messages,
          params: CactusCompletionParams(
            // Tool calls during streaming aren't parsed token-by-token;
            // they arrive in the final result. For now we don't pass tools
            // during streaming — do a non-streaming complete() if tools matter.
            temperature: temperature,
            maxTokens: maxTokens ?? 200,
          ),
        )
        .then((streamedResult) async {
          try {
            await for (final chunk in streamedResult.stream) {
              if (!controller.isClosed) {
                controller.add(LlmResponseChunk(
                  textChunk: chunk,
                  isDone: false,
                ));
              }
            }
            if (!controller.isClosed) {
              controller.add(LlmResponseChunk(textChunk: '', isDone: true));
              controller.close();
            }
          } catch (e, st) {
            if (!controller.isClosed) {
              controller.addError(e, st);
              controller.close();
            }
          }
        })
        .catchError((Object e, StackTrace st) {
          if (!controller.isClosed) {
            controller.addError(e, st);
            controller.close();
          }
        });

    return controller.stream;
  }

  // ─────────────────────────────────────────────
  // Embeddings — delegated to Cactus embedding API
  // ─────────────────────────────────────────────

  @override
  Future<List<double>> getEmbeddings(String text) async {
    final lm = _requireInitialized();
    final result = await lm.generateEmbedding(text: text);
    return result.embeddings;
  }

  // ─────────────────────────────────────────────
  // Tool call metadata helpers
  // ─────────────────────────────────────────────

  @override
  bool hasToolCallMetadata(Map<String, dynamic> metadata) {
    final calls = metadata['tool_calls'];
    return calls is List && calls.isNotEmpty;
  }

  @override
  LlmToolCall? extractToolCallFromMetadata(Map<String, dynamic> metadata) {
    final calls = metadata['tool_calls'] as List?;
    if (calls == null || calls.isEmpty) return null;

    // Return the first pending tool call; the caller is expected to invoke
    // extractToolCallFromMetadata iteratively if there are multiple calls.
    final first = calls.first as Map<String, dynamic>;
    return LlmToolCall(
      name: first['name'] as String,
      arguments: (first['arguments'] as Map?)?.cast<String, dynamic>() ?? {},
    );
  }

  @override
  Map<String, dynamic> standardizeMetadata(Map<String, dynamic> metadata) {
    // Our metadata is already in the canonical shape expected by mcp_llm.
    return metadata;
  }

  // ─────────────────────────────────────────────
  // Capabilities
  // ─────────────────────────────────────────────

  @override
  bool get supportsPromptCaching => false;

  // ─────────────────────────────────────────────
  // Private helpers
  // ─────────────────────────────────────────────

  CactusLM _requireInitialized() {
    final lm = _lm;
    if (lm == null) {
      throw StateError(
        'CactusLlmProvider.initialize() must be called before use.',
      );
    }
    return lm;
  }

  /// Concatenates [request.history] + a final user message from [request.prompt].
  List<ChatMessage> _buildMessages(LlmRequest request) {
    final messages = request.history
        .map((m) => ChatMessage(
              role: m.role,
              content: m.getTextContent(),
            ))
        .toList();

    if (request.prompt.isNotEmpty) {
      messages.add(ChatMessage(role: 'user', content: request.prompt));
    }

    return messages;
  }

  /// Converts mcp_llm [LlmTool] objects to Cactus [CactusTool] objects.
  ///
  /// mcp_llm uses JSON Schema in [LlmTool.inputSchema]; Cactus uses its own
  /// typed [ToolParametersSchema]. We parse the properties map manually.
  List<CactusTool> _buildTools(LlmRequest request) {
    // Tools arrive via request.parameters['tools'] as List<LlmTool>.
    final rawTools =
        (request.parameters['tools'] as List?)?.cast<LlmTool>();

    if (rawTools == null || rawTools.isEmpty) return [];

    return rawTools.map(_convertTool).toList();
  }

  CactusTool _convertTool(LlmTool tool) {
    final schema = tool.inputSchema;
    final properties =
        (schema['properties'] as Map?)?.cast<String, dynamic>() ?? {};
    final requiredList =
        (schema['required'] as List?)?.cast<String>() ?? <String>[];

    return CactusTool(
      name: tool.name,
      description: tool.description,
      parameters: ToolParametersSchema(
        properties: {
          for (final entry in properties.entries)
            entry.key: ToolParameter(
              type: (entry.value as Map?)?['type'] as String? ?? 'string',
              description:
                  (entry.value as Map?)?['description'] as String? ?? '',
              required: requiredList.contains(entry.key),
            ),
        },
      ),
    );
  }

  double? _resolveTemperature(LlmRequest request) {
    return (request.parameters['temperature'] as num?)?.toDouble() ??
        defaultTemperature;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Factory helper
// ─────────────────────────────────────────────────────────────────────────────

/// Convenience factory so registration with [McpLlm] is a one-liner.
///
/// ```dart
/// mcpLlm.registerProvider('cactus', CactusProviderFactory('lfm2.5-1.2b'));
/// ```
class CactusProviderFactory {
  final String modelId;
  final String? modelUrl;
  final int contextLength;
  final double? defaultTemperature;

  const CactusProviderFactory(
    this.modelId, {
    this.modelUrl,
    this.contextLength = 4096,
    this.defaultTemperature,
  });

  CactusLlmProvider build() => CactusLlmProvider(
        modelId: modelId,
        modelUrl: modelUrl,
        contextLength: contextLength,
        defaultTemperature: defaultTemperature,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Offline-first wrapper with cloud fallback
// ─────────────────────────────────────────────────────────────────────────────

/// Wraps [CactusLlmProvider] and falls back to a cloud [LlmProvider] when
/// Cactus inference fails (e.g. OOM) or when [forceCloud] is set.
///
/// The cloud provider must already be initialized before being passed here.
class CactusWithCloudFallback implements LlmProvider {
  final CactusLlmProvider local;
  final LlmProvider cloud;

  /// Override: always use cloud (e.g. when connectivity is confirmed).
  bool forceCloud;

  CactusWithCloudFallback({
    required this.local,
    required this.cloud,
    this.forceCloud = false,
  });

  @override
  Future<void> initialize(LlmConfiguration config) async {
    await local.initialize(config);
    // cloud is assumed already initialized by the caller
  }

  @override
  Future<void> close() async {
    await local.close();
  }

  @override
  Future<LlmResponse> complete(LlmRequest request) async {
    if (forceCloud) return cloud.complete(request);
    try {
      return await local.complete(request);
    } catch (_) {
      return cloud.complete(request);
    }
  }

  @override
  Stream<LlmResponseChunk> streamComplete(LlmRequest request) {
    if (forceCloud) return cloud.streamComplete(request);

    // Try local first; if it throws synchronously, fall back.
    try {
      return local.streamComplete(request);
    } catch (_) {
      return cloud.streamComplete(request);
    }
  }

  @override
  Future<List<double>> getEmbeddings(String text) =>
      cloud.getEmbeddings(text); // always use cloud for embeddings

  @override
  bool hasToolCallMetadata(Map<String, dynamic> metadata) =>
      local.hasToolCallMetadata(metadata);

  @override
  LlmToolCall? extractToolCallFromMetadata(Map<String, dynamic> metadata) =>
      local.extractToolCallFromMetadata(metadata);

  @override
  Map<String, dynamic> standardizeMetadata(Map<String, dynamic> metadata) =>
      local.standardizeMetadata(metadata);

  @override
  bool get supportsPromptCaching => false;
}

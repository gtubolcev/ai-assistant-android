import 'package:cactus/cactus.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Connects to a remote MCP server (dav-mcp) via StreamableHTTP,
/// fetches the tool list, and routes tool calls.
class McpBridge {
  final String serverUrl;  // e.g. https://mcp.rakulka.ru/mcp
  final String bearerToken;

  McpClient? _client;
  final List<CactusTool> _tools = [];

  McpBridge({required this.serverUrl, required this.bearerToken});

  /// All tools fetched from the MCP server, in CactusTool format.
  List<CactusTool> get tools => List.unmodifiable(_tools);

  bool get isConnected => _client != null;

  // ── Connect ────────────────────────────────────────────────────────────────

  Future<void> connect() async {
    _client = McpClient(
      Implementation(name: 'ai-assistant', version: '1.0.0'),
    );

    // Only add Authorization header if a token is configured.
    final Map<String, dynamic>? requestInit = bearerToken.isNotEmpty
        ? <String, dynamic>{
            'headers': <String, dynamic>{
              'Authorization': 'Bearer $bearerToken',
            },
          }
        : null;

    final transport = StreamableHttpClientTransport(
      Uri.parse(serverUrl),
      opts: StreamableHttpClientTransportOptions(requestInit: requestInit),
    );

    await _client!.connect(transport);
    await _fetchTools();
  }

  // ── Fetch & convert tools ─────────────────────────────────────────────────

  Future<void> _fetchTools() async {
    final response = await _client!.listTools();
    _tools.clear();
    for (final tool in response.tools) {
      _tools.add(_convertTool(tool));
    }
  }

  CactusTool _convertTool(Tool tool) {
    // tool.inputSchema is a sealed JsonSchema (concrete type: JsonObject, etc.).
    // Casting directly to Map<String, dynamic> throws at runtime — use toJson().
    final schema = tool.inputSchema.toJson();
    final props = schema['properties'] as Map<String, dynamic>? ?? {};
    final requiredList = (schema['required'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toSet();

    return CactusTool(
      name: tool.name,
      description: tool.description ?? '',
      parameters: ToolParametersSchema(
        properties: props.map((key, value) {
          final prop = value as Map<String, dynamic>? ?? {};
          return MapEntry(
            key,
            ToolParameter(
              type: prop['type'] as String? ?? 'string',
              description: prop['description'] as String? ?? '',
              required: requiredList.contains(key),
            ),
          );
        }),
      ),
    );
  }

  // ── Execute tool call ─────────────────────────────────────────────────────

  Future<String> executeTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    final client = _client;
    if (client == null) return 'MCP не подключён';

    try {
      final result = await client.callTool(
        CallToolRequest(name: name, arguments: args),
      );

      // Extract text from content list (MCP spec: TextContent items)
      final parts = <String>[];
      for (final item in result.content) {
        if (item is TextContent) {
          parts.add(item.text);
        } else {
          parts.add(item.toString());
        }
      }

      return parts.isEmpty ? '(no content)' : parts.join('\n');
    } catch (e) {
      return 'Ошибка MCP инструмента "$name": $e';
    }
  }

  // ── Disconnect ────────────────────────────────────────────────────────────

  Future<void> disconnect() async {
    await _client?.close();
    _client = null;
    _tools.clear();
  }
}

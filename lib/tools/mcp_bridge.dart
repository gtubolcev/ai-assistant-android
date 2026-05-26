import 'dart:convert';

import 'package:cactus/cactus.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Connects to a remote MCP server via StreamableHTTP,
/// fetches the tool list, and routes tool calls.
///
/// Supports two auth modes:
///   - Bearer token  (e.g. dav-mcp with BEARER_TOKEN)
///   - HTTP Basic    (e.g. nextcloud-mcp in multi_user_basic mode)
///
/// Pass [username] + [password] for Basic Auth, or [bearerToken] for Bearer.
/// Leave all empty for unauthenticated servers.
class McpBridge {
  final String serverUrl;
  final String bearerToken;
  final String username;
  final String password;

  McpClient? _client;
  final List<CactusTool> _tools = [];

  McpBridge({
    required this.serverUrl,
    this.bearerToken = '',
    this.username = '',
    this.password = '',
  });

  List<CactusTool> get tools => List.unmodifiable(_tools);
  bool get isConnected => _client != null;

  // ── Connect ────────────────────────────────────────────────────────────────

  Future<void> connect() async {
    _client = McpClient(
      Implementation(name: 'ai-assistant', version: '1.0.0'),
    );

    final authHeader = _buildAuthHeader();
    final Map<String, dynamic>? requestInit = authHeader != null
        ? <String, dynamic>{
            'headers': <String, dynamic>{'Authorization': authHeader},
          }
        : null;

    final transport = StreamableHttpClientTransport(
      Uri.parse(serverUrl),
      opts: StreamableHttpClientTransportOptions(requestInit: requestInit),
    );

    await _client!.connect(transport);
    await _fetchTools();
  }

  /// Returns the Authorization header value, or null if no auth configured.
  String? _buildAuthHeader() {
    // Basic Auth takes priority when username is set.
    if (username.isNotEmpty) {
      final creds = base64Encode(utf8.encode('$username:$password'));
      return 'Basic $creds';
    }
    if (bearerToken.isNotEmpty) {
      return 'Bearer $bearerToken';
    }
    return null;
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
    // tool.inputSchema is a sealed JsonSchema — use toJson() to get a plain map.
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

  Future<String> executeTool(String name, Map<String, dynamic> args) async {
    final client = _client;
    if (client == null) return 'MCP не подключён';

    try {
      final result = await client.callTool(
        CallToolRequest(name: name, arguments: args),
      );

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

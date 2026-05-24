import 'package:cactus/cactus.dart';
import 'package:http/http.dart' as http;

/// Tool definition for the web_fetch tool (Cactus format).
final CactusTool webFetchTool = CactusTool(
  name: 'web_fetch',
  description:
      'Fetch the text content of a web page. Use for reading articles, '
      'documentation, or any URL the user mentions.',
  parameters: ToolParametersSchema(
    properties: {
      'url': ToolParameter(
        type: 'string',
        description: 'The full URL to fetch (must start with http/https)',
        required: true,
      ),
    },
  ),
);

/// Executes the web_fetch tool.
Future<String> executeWebFetch(Map<String, String> args) async {
  final url = args['url'];
  if (url == null || url.isEmpty) return 'Error: url is required';

  try {
    final response = await http
        .get(Uri.parse(url), headers: {'User-Agent': 'AiAssistant/0.1'})
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      return 'Error: HTTP ${response.statusCode}';
    }

    // Strip HTML tags, collapse whitespace — good enough for 1.2B models.
    final text = response.body
        .replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true), '')
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true), '')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'&nbsp;'), ' ')
        .replaceAll(RegExp(r'&amp;'), '&')
        .replaceAll(RegExp(r'&lt;'), '<')
        .replaceAll(RegExp(r'&gt;'), '>')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();

    // Truncate to ~4000 chars so we don't overflow the 4096-token context.
    return text.length > 4000 ? '${text.substring(0, 4000)}…' : text;
  } catch (e) {
    return 'Error fetching $url: $e';
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_assistant/providers/chat_provider.dart';

// Verifies the keyword/fuzzy router maps user phrases to the right tool set.
// Regression guard for: "show me calendars" (extra word) and "calenders"
// (typo) both used to fall through to tools=[] → model hallucinated get_calendar.
void main() {
  final p = ChatProvider();

  List<String> toolsFor(String msg) =>
      p.debugToolsForMessage(msg).map((t) => t['name'] as String).toList();

  group('calendars', () {
    for (final msg in [
      'show calendars',
      'show me calendars',          // extra word between verb and noun
      'show me my calendars',
      'list calendars',
      'what calendars do I have',
      'calenders',                  // typo (edit distance 1)
      'show me calenders',          // typo + extra word
      'покажи мои календари',
      'какие у меня календари',
    ]) {
      test('"$msg" → list_calendars', () {
        expect(toolsFor(msg), contains('list_calendars'));
      });
    }
  });

  group('tasks', () {
    test('"show me my tasks" → list_tasks', () {
      expect(toolsFor('show me my tasks'), contains('list_tasks'));
    });
    test('"create a task" → create_task', () {
      expect(toolsFor('create a task'), contains('create_task'));
    });
    test('"мои задачи" → list_tasks', () {
      expect(toolsFor('мои задачи'), contains('list_tasks'));
    });
  });

  group('events / agenda', () {
    test('"what events are coming up" → list_events', () {
      expect(toolsFor('what events are coming up'), contains('list_events'));
    });
    test('"what is on my calendar today" → list_events (not list_calendars)', () {
      final tools = toolsFor('what is on my calendar today');
      expect(tools, contains('list_events'));
    });
    test('"schedule a meeting" → create_event', () {
      expect(toolsFor('schedule a meeting'), contains('create_event'));
    });
  });

  group('conversational', () {
    test('"hello how are you" → no tools', () {
      expect(toolsFor('hello how are you'), isEmpty);
    });
    test('"what is the capital of France" → no tools', () {
      expect(toolsFor('what is the capital of France'), isEmpty);
    });
  });

  group('tool-call parsing', () {
    (String, Map<String, dynamic>)? parse(String t) => p.debugParseToolCall(t);

    test('well-formed JSON parses', () {
      final r = parse('{"tool":"list_calendars","arguments":{}}');
      expect(r?.$1, 'list_calendars');
    });

    test('truncated JSON (missing closing braces) is repaired', () {
      // Model hit StopEog right after a value, leaving the object unterminated.
      final r = parse(
          '{"tool":"create_task","arguments":{"title":"buy some more milk","due":null}');
      expect(r?.$1, 'create_task');
      expect(r?.$2['title'], 'buy some more milk');
    });

    test('truncated mid-nested-object is repaired', () {
      final r = parse('{"tool":"create_task","arguments":{"title":"x"');
      expect(r?.$1, 'create_task');
      expect(r?.$2['title'], 'x');
    });

    test('braces inside string values do not confuse extraction', () {
      final r = parse('{"tool":"create_task","arguments":{"title":"a } b { c"}}');
      expect(r?.$1, 'create_task');
      expect(r?.$2['title'], 'a } b { c');
    });

    test('<tool_call> wrapper parses', () {
      final r = parse('<tool_call>{"name":"list_tasks","arguments":{}}</tool_call>');
      expect(r?.$1, 'list_tasks');
    });

    test('plain text without a tool call returns null', () {
      expect(parse('Sure, I can help with that.'), isNull);
    });
  });
}

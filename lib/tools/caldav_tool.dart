import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mcp_llm/mcp_llm.dart';
import 'package:xml/xml.dart';

/// CalDAV credentials — set via app settings screen.
/// In a real app, store in FlutterSecureStorage.
class CalDavConfig {
  final String serverUrl;   // e.g. https://nextcloud.example.com/remote.php/dav
  final String username;
  final String password;
  final String calendarPath; // e.g. /calendars/user/personal/

  const CalDavConfig({
    required this.serverUrl,
    required this.username,
    required this.password,
    required this.calendarPath,
  });

  Map<String, String> get authHeaders => {
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$username:$password'))}',
        'Content-Type': 'application/xml; charset=utf-8',
      };
}

// ── Tool definitions ──────────────────────────────────────────────────────────

final LlmTool listEventsTool = LlmTool(
  name: 'caldav_list_events',
  description: 'List calendar events and tasks (VTODO) from the CalDAV server '
      'for a given date range.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'start': {
        'type': 'string',
        'description': 'Start date in ISO 8601 format, e.g. 2026-05-24',
      },
      'end': {
        'type': 'string',
        'description': 'End date in ISO 8601 format, e.g. 2026-05-31',
      },
    },
    'required': ['start', 'end'],
  },
);

final LlmTool createEventTool = LlmTool(
  name: 'caldav_create_event',
  description: 'Create a new calendar event or task (VTODO) on the CalDAV '
      'server.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'title': {'type': 'string', 'description': 'Event title'},
      'start': {
        'type': 'string',
        'description': 'Start datetime in ISO 8601, e.g. 2026-05-25T14:00:00',
      },
      'end': {
        'type': 'string',
        'description': 'End datetime in ISO 8601, e.g. 2026-05-25T15:00:00',
      },
      'description': {
        'type': 'string',
        'description': 'Optional event description',
      },
      'is_task': {
        'type': 'boolean',
        'description': 'If true, creates a VTODO task instead of VEVENT',
      },
    },
    'required': ['title', 'start', 'end'],
  },
);

final LlmTool deleteEventTool = LlmTool(
  name: 'caldav_delete_event',
  description: 'Delete a calendar event or task by its UID.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'uid': {'type': 'string', 'description': 'The UID of the event to delete'},
    },
    'required': ['uid'],
  },
);

// ── Executor ──────────────────────────────────────────────────────────────────

class CalDavExecutor {
  final CalDavConfig config;
  CalDavExecutor(this.config);

  Future<String> execute(String toolName, Map<String, dynamic> args) {
    return switch (toolName) {
      'caldav_list_events' => _listEvents(args),
      'caldav_create_event' => _createEvent(args),
      'caldav_delete_event' => _deleteEvent(args),
      _ => Future.value('Unknown CalDAV tool: $toolName'),
    };
  }

  // ── List events via REPORT ──────────────────────────────────────────────────

  Future<String> _listEvents(Map<String, dynamic> args) async {
    final start = _toCalDateTime(args['start'] as String);
    final end = _toCalDateTime(args['end'] as String);

    final body = '''<?xml version="1.0" encoding="utf-8"?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:getetag/>
    <c:calendar-data/>
  </d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT">
        <c:time-range start="$start" end="$end"/>
      </c:comp-filter>
    </c:comp-filter>
  </c:filter>
</c:calendar-query>''';

    try {
      final response = await http
          .Request(
            'REPORT',
            Uri.parse('${config.serverUrl}${config.calendarPath}'),
          )
          .also((r) {
            r.headers.addAll(config.authHeaders);
            r.headers['Depth'] = '1';
            r.body = body;
          })
          .send()
          .then(http.Response.fromStream);

      if (response.statusCode != 207) {
        return 'CalDAV error: HTTP ${response.statusCode}';
      }

      return _parseEventList(response.body);
    } catch (e) {
      return 'CalDAV list error: $e';
    }
  }

  String _parseEventList(String xml) {
    final doc = XmlDocument.parse(xml);
    final events = <String>[];

    for (final response in doc.findAllElements('response')) {
      final data = response.findAllElements('calendar-data').firstOrNull;
      if (data == null) continue;

      final cal = data.innerText;
      final summary = _icsField(cal, 'SUMMARY');
      final dtstart = _icsField(cal, 'DTSTART');
      final uid = _icsField(cal, 'UID');

      if (summary != null) {
        events.add('• [$dtstart] $summary (UID: $uid)');
      }
    }

    return events.isEmpty ? 'No events found.' : events.join('\n');
  }

  // ── Create event via PUT ────────────────────────────────────────────────────

  Future<String> _createEvent(Map<String, dynamic> args) async {
    final title = args['title'] as String;
    final start = args['start'] as String;
    final end = args['end'] as String;
    final description = args['description'] as String? ?? '';
    final isTask = args['is_task'] as bool? ?? false;

    final uid = DateTime.now().millisecondsSinceEpoch.toString();
    final dtStart = _toCalDateTime(start);
    final dtEnd = _toCalDateTime(end);
    final now = _toCalDateTime(DateTime.now().toIso8601String());

    final component = isTask
        ? '''BEGIN:VTODO
UID:$uid
DTSTAMP:$now
SUMMARY:$title
DESCRIPTION:$description
STATUS:NEEDS-ACTION
DUE:$dtEnd
END:VTODO'''
        : '''BEGIN:VEVENT
UID:$uid
DTSTAMP:$now
DTSTART:$dtStart
DTEND:$dtEnd
SUMMARY:$title
DESCRIPTION:$description
END:VEVENT''';

    final ics = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\n$component\r\nEND:VCALENDAR';
    final url = '${config.serverUrl}${config.calendarPath}$uid.ics';

    try {
      final response = await http.put(
        Uri.parse(url),
        headers: config.authHeaders,
        body: ics,
      );

      return response.statusCode == 201 || response.statusCode == 204
          ? 'Created: $title (UID: $uid)'
          : 'CalDAV PUT error: HTTP ${response.statusCode}';
    } catch (e) {
      return 'CalDAV create error: $e';
    }
  }

  // ── Delete event via DELETE ─────────────────────────────────────────────────

  Future<String> _deleteEvent(Map<String, dynamic> args) async {
    final uid = args['uid'] as String;
    final url = '${config.serverUrl}${config.calendarPath}$uid.ics';

    try {
      final response = await http.delete(
        Uri.parse(url),
        headers: config.authHeaders,
      );

      return response.statusCode == 204
          ? 'Deleted event UID: $uid'
          : 'CalDAV DELETE error: HTTP ${response.statusCode}';
    } catch (e) {
      return 'CalDAV delete error: $e';
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// Converts ISO 8601 string to iCalendar basic format: 20260524T140000Z
  String _toCalDateTime(String iso) {
    final dt = DateTime.tryParse(iso) ?? DateTime.now();
    final utc = dt.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}'
        '${utc.month.toString().padLeft(2, '0')}'
        '${utc.day.toString().padLeft(2, '0')}T'
        '${utc.hour.toString().padLeft(2, '0')}'
        '${utc.minute.toString().padLeft(2, '0')}'
        '${utc.second.toString().padLeft(2, '0')}Z';
  }

  String? _icsField(String ics, String field) {
    final match = RegExp('^$field[^:]*:(.+)\$', multiLine: true).firstMatch(ics);
    return match?.group(1)?.trim();
  }
}

// ── Extension helper ─────────────────────────────────────────────────────────

extension _Also<T> on T {
  T also(void Function(T) block) {
    block(this);
    return this;
  }
}

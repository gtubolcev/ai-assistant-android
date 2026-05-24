import 'dart:convert';

import 'package:cactus/cactus.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// CalDAV credentials — set via app settings screen.
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

// ── Tool definitions (Cactus format) ─────────────────────────────────────────

final CactusTool listEventsTool = CactusTool(
  name: 'caldav_list_events',
  description: 'List calendar events and tasks (VTODO) from the CalDAV server '
      'for a given date range.',
  parameters: ToolParametersSchema(
    properties: {
      'start': ToolParameter(
        type: 'string',
        description: 'Start date in ISO 8601 format, e.g. 2026-05-24',
        required: true,
      ),
      'end': ToolParameter(
        type: 'string',
        description: 'End date in ISO 8601 format, e.g. 2026-05-31',
        required: true,
      ),
    },
  ),
);

final CactusTool createEventTool = CactusTool(
  name: 'caldav_create_event',
  description: 'Create a new calendar event or task (VTODO) on the CalDAV server.',
  parameters: ToolParametersSchema(
    properties: {
      'title': ToolParameter(
        type: 'string',
        description: 'Event title',
        required: true,
      ),
      'start': ToolParameter(
        type: 'string',
        description: 'Start datetime in ISO 8601, e.g. 2026-05-25T14:00:00',
        required: true,
      ),
      'end': ToolParameter(
        type: 'string',
        description: 'End datetime in ISO 8601, e.g. 2026-05-25T15:00:00',
        required: true,
      ),
      'description': ToolParameter(
        type: 'string',
        description: 'Optional event description',
        required: false,
      ),
      'is_task': ToolParameter(
        type: 'string',
        description: 'Pass "true" to create a VTODO task instead of VEVENT',
        required: false,
      ),
    },
  ),
);

final CactusTool deleteEventTool = CactusTool(
  name: 'caldav_delete_event',
  description: 'Delete a calendar event or task by its UID.',
  parameters: ToolParametersSchema(
    properties: {
      'uid': ToolParameter(
        type: 'string',
        description: 'The UID of the event to delete',
        required: true,
      ),
    },
  ),
);

// ── Executor ──────────────────────────────────────────────────────────────────

class CalDavExecutor {
  final CalDavConfig config;
  CalDavExecutor(this.config);

  Future<String> execute(String toolName, Map<String, String> args) {
    return switch (toolName) {
      'caldav_list_events' => _listEvents(args),
      'caldav_create_event' => _createEvent(args),
      'caldav_delete_event' => _deleteEvent(args),
      _ => Future.value('Unknown CalDAV tool: $toolName'),
    };
  }

  // ── List events via REPORT ──────────────────────────────────────────────────

  Future<String> _listEvents(Map<String, String> args) async {
    final start = _toCalDateTime(args['start'] ?? DateTime.now().toIso8601String());
    final end = _toCalDateTime(args['end'] ?? DateTime.now().add(const Duration(days: 7)).toIso8601String());

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
      final request = http.Request(
        'REPORT',
        Uri.parse('${config.serverUrl}${config.calendarPath}'),
      );
      request.headers.addAll(config.authHeaders);
      request.headers['Depth'] = '1';
      request.body = body;

      final response = await http.Response.fromStream(await request.send());

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

  Future<String> _createEvent(Map<String, String> args) async {
    final title = args['title'] ?? 'Untitled';
    final start = args['start'] ?? DateTime.now().toIso8601String();
    final end = args['end'] ?? DateTime.now().add(const Duration(hours: 1)).toIso8601String();
    final description = args['description'] ?? '';
    final isTask = (args['is_task'] ?? '').toLowerCase() == 'true';

    final uid = DateTime.now().millisecondsSinceEpoch.toString();
    final dtStart = _toCalDateTime(start);
    final dtEnd = _toCalDateTime(end);
    final now = _toCalDateTime(DateTime.now().toIso8601String());

    final component = isTask
        ? 'BEGIN:VTODO\r\nUID:$uid\r\nDTSTAMP:$now\r\nSUMMARY:$title\r\n'
            'DESCRIPTION:$description\r\nSTATUS:NEEDS-ACTION\r\nDUE:$dtEnd\r\nEND:VTODO'
        : 'BEGIN:VEVENT\r\nUID:$uid\r\nDTSTAMP:$now\r\nDTSTART:$dtStart\r\n'
            'DTEND:$dtEnd\r\nSUMMARY:$title\r\nDESCRIPTION:$description\r\nEND:VEVENT';

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

  Future<String> _deleteEvent(Map<String, String> args) async {
    final uid = args['uid'] ?? '';
    if (uid.isEmpty) return 'Error: uid is required';

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

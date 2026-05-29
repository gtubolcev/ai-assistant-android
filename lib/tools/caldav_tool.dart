import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

// ── Models ────────────────────────────────────────────────────────────────────

class CalDavCalendar {
  final String id;    // URL segment, e.g. "personal"
  final String href;  // Full path, e.g. /remote.php/dav/calendars/user/personal/
  final String name;

  const CalDavCalendar({required this.id, required this.href, required this.name});
}

class CalDavTask {
  final String uid;
  final String calendarHref;
  final String calendarName;
  final String title;
  final String status; // NEEDS-ACTION, IN-PROCESS, COMPLETED, CANCELLED
  final DateTime? due;
  final int priority;  // 0=unset, 1=high, 5=medium, 9=low
  final String notes;
  final String rawIcs;

  const CalDavTask({
    required this.uid,
    required this.calendarHref,
    this.calendarName = '',
    required this.title,
    this.status = 'NEEDS-ACTION',
    this.due,
    this.priority = 0,
    this.notes = '',
    this.rawIcs = '',
  });

  bool get isDone => status == 'COMPLETED' || status == 'CANCELLED';
}

class CalDavEvent {
  final String uid;
  final String calendarHref;
  final String calendarName;
  final String title;
  final DateTime start;
  final DateTime? end;
  final bool isTask;
  final String location;
  final String attendee;
  final String notes;

  const CalDavEvent({
    required this.uid,
    required this.calendarHref,
    this.calendarName = '',
    required this.title,
    required this.start,
    this.end,
    this.isTask = false,
    this.location = '',
    this.attendee = '',
    this.notes = '',
  });
}

// ── CalDAV HTTP Client ────────────────────────────────────────────────────────

class CalDavClient {
  final String serverUrl; // e.g. https://cloud.example.com
  final String username;
  final String password;

  CalDavClient({
    required this.serverUrl,
    required this.username,
    required this.password,
  });

  // Normalise: strip trailing slash, ensure no double-slash in paths
  String get _base {
    var url = serverUrl.trimRight();
    while (url.endsWith('/')) url = url.substring(0, url.length - 1);
    // Nextcloud: if URL already ends with /remote.php/dav, keep it; otherwise append
    if (!url.contains('/remote.php/dav') && !url.contains('/dav/')) {
      url = '$url/remote.php/dav';
    }
    return url;
  }

  String get _calendarsBase => '$_base/calendars/$username/';

  Map<String, String> get _authHeaders => {
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$username:$password'))}',
        'Content-Type': 'application/xml; charset=utf-8',
      };

  // ── Calendars ───────────────────────────────────────────────────────────────

  Future<List<CalDavCalendar>> listCalendars() async {
    const body = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
        '<d:prop><d:displayname/><d:resourcetype/></d:prop>'
        '</d:propfind>';

    final req = http.Request('PROPFIND', Uri.parse(_calendarsBase));
    req.headers.addAll(_authHeaders);
    req.headers['Depth'] = '1';
    req.body = body;

    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode != 207) {
      throw Exception('listCalendars failed: HTTP ${res.statusCode}');
    }

    final doc = XmlDocument.parse(res.body);
    final result = <CalDavCalendar>[];

    for (final resp in doc.findAllElements('response')) {
      final hasCalendar = resp.findAllElements('calendar').isNotEmpty;
      if (!hasCalendar) continue;

      final href = resp.findAllElements('href').firstOrNull?.innerText.trim() ?? '';
      final name = resp.findAllElements('displayname').firstOrNull?.innerText.trim() ?? '';
      if (name.isEmpty) continue;

      final parts = href.split('/').where((s) => s.isNotEmpty).toList();
      final id = parts.isNotEmpty ? parts.last : href;

      result.add(CalDavCalendar(id: id, href: href, name: name));
    }
    return result;
  }

  Future<String> createCalendar(String name) async {
    final id = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');
    final href = '$_calendarsBase$id/';

    const mkcolBody = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:mkcol xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
        '<d:set><d:prop>'
        '<d:resourcetype><d:collection/><c:calendar/></d:resourcetype>'
        '</d:prop></d:set>'
        '</d:mkcol>';

    final req = http.Request('MKCOL', Uri.parse('$serverUrl$href'));
    req.headers.addAll(_authHeaders);
    req.body = mkcolBody;
    final res = await http.Response.fromStream(await req.send());

    if (res.statusCode != 201) {
      return 'Error creating calendar: HTTP ${res.statusCode}';
    }

    // Set display name via PROPPATCH
    await _proppatchDisplayName(href, name);
    return 'Calendar "$name" created.';
  }

  Future<String> renameCalendar(String href, String newName) async {
    await _proppatchDisplayName(href, newName);
    return 'Calendar renamed to "$newName".';
  }

  Future<void> _proppatchDisplayName(String href, String name) async {
    final body = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propertyupdate xmlns:d="DAV:"><d:set><d:prop>'
        '<d:displayname>${_escapeXml(name)}</d:displayname>'
        '</d:prop></d:set></d:propertyupdate>';

    final req = http.Request('PROPPATCH', Uri.parse('$serverUrl$href'));
    req.headers.addAll(_authHeaders);
    req.body = body;
    await req.send();
  }

  Future<String> deleteCalendar(String href) async {
    final res = await http.delete(Uri.parse('$serverUrl$href'), headers: _authHeaders);
    return res.statusCode == 204
        ? 'Calendar deleted.'
        : 'Error: HTTP ${res.statusCode}';
  }

  // ── Tasks (VTODO) ───────────────────────────────────────────────────────────

  Future<List<CalDavTask>> listTasks(
    CalDavCalendar calendar, {
    bool includeDone = false,
    DateTime? from,
    DateTime? to,
  }) async {
    final statusFilter = includeDone
        ? ''
        : '<c:prop-filter name="STATUS">'
            '<c:text-match negate-condition="yes">COMPLETED</c:text-match>'
            '</c:prop-filter>';

    final timeFilter = (from != null || to != null)
        ? '<c:time-range'
            '${from != null ? ' start="${_dt(from)}"' : ''}'
            '${to != null ? ' end="${_dt(to)}"' : ''}/>'
        : '';

    final body = '<?xml version="1.0" encoding="utf-8"?>'
        '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
        '<d:prop><d:getetag/><c:calendar-data/></d:prop>'
        '<c:filter><c:comp-filter name="VCALENDAR">'
        '<c:comp-filter name="VTODO">$statusFilter$timeFilter</c:comp-filter>'
        '</c:comp-filter></c:filter>'
        '</c:calendar-query>';

    final req = http.Request('REPORT', Uri.parse('$serverUrl${calendar.href}'));
    req.headers.addAll(_authHeaders);
    req.headers['Depth'] = '1';
    req.body = body;

    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode != 207) return [];

    return _parseTasks(res.body, calendar);
  }

  List<CalDavTask> _parseTasks(String xml, CalDavCalendar calendar) {
    final doc = XmlDocument.parse(xml);
    final tasks = <CalDavTask>[];

    for (final resp in doc.findAllElements('response')) {
      final data = resp.findAllElements('calendar-data').firstOrNull;
      if (data == null) continue;

      final ics = _unfold(data.innerText);
      final todo = _component(ics, 'VTODO');
      if (todo == null) continue;

      tasks.add(CalDavTask(
        uid: _field(todo, 'UID') ?? '',
        calendarHref: calendar.href,
        calendarName: calendar.name,
        title: _field(todo, 'SUMMARY') ?? '(no title)',
        status: _field(todo, 'STATUS') ?? 'NEEDS-ACTION',
        due: _parseDate(_field(todo, 'DUE')),
        priority: int.tryParse(_field(todo, 'PRIORITY') ?? '') ?? 0,
        notes: _field(todo, 'DESCRIPTION') ?? '',
        rawIcs: ics,
      ));
    }
    return tasks;
  }

  Future<CalDavTask?> findTask(String query, List<CalDavCalendar> calendars) async {
    final q = query.toLowerCase();
    for (final cal in calendars) {
      final tasks = await listTasks(cal, includeDone: true);
      for (final t in tasks) {
        if (t.uid == query || t.title.toLowerCase().contains(q)) return t;
      }
    }
    return null;
  }

  Future<String> createTask({
    required CalDavCalendar calendar,
    required String title,
    DateTime? due,
    int priority = 0,
    String notes = '',
  }) async {
    final uid = _uid();
    final now = _dt(DateTime.now());
    final buf = StringBuffer()
      ..write('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//AI Assistant//EN\r\n')
      ..write('BEGIN:VTODO\r\n')
      ..write('UID:$uid\r\n')
      ..write('DTSTAMP:$now\r\n')
      ..write('SUMMARY:${_escapeIcs(title)}\r\n')
      ..write('STATUS:NEEDS-ACTION\r\n');
    if (due != null) buf.write('DUE;VALUE=DATE:${_date(due)}\r\n');
    if (priority > 0) buf.write('PRIORITY:$priority\r\n');
    if (notes.isNotEmpty) buf.write('DESCRIPTION:${_escapeIcs(notes)}\r\n');
    buf.write('END:VTODO\r\nEND:VCALENDAR');

    final res = await _put(calendar.href, uid, buf.toString());
    return res ? 'Task "$title" created (UID: $uid).' : 'Error creating task.';
  }

  Future<String> updateTask(
    CalDavTask task, {
    String? title,
    DateTime? due,
    String? status,
    String? notes,
    int? priority,
  }) async {
    var ics = task.rawIcs;
    if (title != null) ics = _setField(ics, 'SUMMARY', _escapeIcs(title));
    if (status != null) ics = _setField(ics, 'STATUS', status);
    if (due != null) ics = _setField(ics, 'DUE;VALUE=DATE', _date(due));
    if (notes != null) ics = _setField(ics, 'DESCRIPTION', _escapeIcs(notes));
    if (priority != null) ics = _setField(ics, 'PRIORITY', priority.toString());
    // Update DTSTAMP
    ics = _setField(ics, 'DTSTAMP', _dt(DateTime.now()));

    final res = await _put(task.calendarHref, task.uid, ics);
    return res ? 'Task updated.' : 'Error updating task.';
  }

  Future<String> deleteTask(CalDavTask task) => _delete(task.calendarHref, task.uid);

  // ── Events (VEVENT) ─────────────────────────────────────────────────────────

  Future<List<CalDavEvent>> listEvents(
    CalDavCalendar calendar, {
    DateTime? from,
    DateTime? to,
  }) async {
    final startStr = _dt(from ?? DateTime.now().copyWith(hour: 0, minute: 0, second: 0));
    final endStr = _dt(to ?? DateTime.now().add(const Duration(days: 365)));

    final body = '<?xml version="1.0" encoding="utf-8"?>'
        '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
        '<d:prop><d:getetag/><c:calendar-data/></d:prop>'
        '<c:filter><c:comp-filter name="VCALENDAR">'
        '<c:comp-filter name="VEVENT">'
        '<c:time-range start="$startStr" end="$endStr"/>'
        '</c:comp-filter>'
        '</c:comp-filter></c:filter>'
        '</c:calendar-query>';

    final req = http.Request('REPORT', Uri.parse('$serverUrl${calendar.href}'));
    req.headers.addAll(_authHeaders);
    req.headers['Depth'] = '1';
    req.body = body;

    final res = await http.Response.fromStream(await req.send());
    final events = res.statusCode == 207 ? _parseEvents(res.body, calendar) : <CalDavEvent>[];

    // Also include tasks with DUE in range (tasks appear in calendar view)
    try {
      final tasks = await listTasks(calendar, from: from, to: to, includeDone: false);
      for (final t in tasks) {
        if (t.due != null) {
          events.add(CalDavEvent(
            uid: t.uid,
            calendarHref: calendar.href,
            calendarName: calendar.name,
            title: t.title,
            start: t.due!,
            isTask: true,
            notes: t.notes,
          ));
        }
      }
    } catch (_) {}

    events.sort((a, b) => a.start.compareTo(b.start));
    return events;
  }

  List<CalDavEvent> _parseEvents(String xml, CalDavCalendar calendar) {
    final doc = XmlDocument.parse(xml);
    final events = <CalDavEvent>[];

    for (final resp in doc.findAllElements('response')) {
      final data = resp.findAllElements('calendar-data').firstOrNull;
      if (data == null) continue;

      final ics = _unfold(data.innerText);
      final vevent = _component(ics, 'VEVENT');
      if (vevent == null) continue;

      final startStr = _field(vevent, 'DTSTART');
      if (startStr == null) continue;
      final start = _parseDate(startStr);
      if (start == null) continue;

      events.add(CalDavEvent(
        uid: _field(vevent, 'UID') ?? '',
        calendarHref: calendar.href,
        calendarName: calendar.name,
        title: _field(vevent, 'SUMMARY') ?? '(no title)',
        start: start,
        end: _parseDate(_field(vevent, 'DTEND')),
        location: _field(vevent, 'LOCATION') ?? '',
        attendee: _field(vevent, 'ATTENDEE') ?? '',
        notes: _field(vevent, 'DESCRIPTION') ?? '',
      ));
    }
    return events;
  }

  Future<CalDavEvent?> findEvent(String query, List<CalDavCalendar> calendars) async {
    final q = query.toLowerCase();
    for (final cal in calendars) {
      final events = await listEvents(cal);
      for (final e in events) {
        if (e.uid == query || e.title.toLowerCase().contains(q)) return e;
      }
    }
    return null;
  }

  Future<String> createEvent({
    required CalDavCalendar calendar,
    required String title,
    required DateTime start,
    required DateTime end,
    String location = '',
    String attendee = '',
    String notes = '',
  }) async {
    final uid = _uid();
    final now = _dt(DateTime.now());
    final buf = StringBuffer()
      ..write('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//AI Assistant//EN\r\n')
      ..write('BEGIN:VEVENT\r\n')
      ..write('UID:$uid\r\n')
      ..write('DTSTAMP:$now\r\n')
      ..write('DTSTART:${_dt(start)}\r\n')
      ..write('DTEND:${_dt(end)}\r\n')
      ..write('SUMMARY:${_escapeIcs(title)}\r\n');
    if (location.isNotEmpty) buf.write('LOCATION:${_escapeIcs(location)}\r\n');
    if (attendee.isNotEmpty) buf.write('ATTENDEE;CN=${_escapeIcs(attendee)}:mailto:unknown@unknown\r\n');
    if (notes.isNotEmpty) buf.write('DESCRIPTION:${_escapeIcs(notes)}\r\n');
    buf.write('END:VEVENT\r\nEND:VCALENDAR');

    final res = await _put(calendar.href, uid, buf.toString());
    return res ? 'Event "$title" created (UID: $uid).' : 'Error creating event.';
  }

  Future<String> updateEvent(
    CalDavEvent event,
    String rawIcs, {
    String? title,
    DateTime? start,
    DateTime? end,
    String? location,
    String? notes,
  }) async {
    var ics = rawIcs;
    if (title != null) ics = _setField(ics, 'SUMMARY', _escapeIcs(title));
    if (start != null) ics = _setField(ics, 'DTSTART', _dt(start));
    if (end != null) ics = _setField(ics, 'DTEND', _dt(end));
    if (location != null) ics = _setField(ics, 'LOCATION', _escapeIcs(location));
    if (notes != null) ics = _setField(ics, 'DESCRIPTION', _escapeIcs(notes));
    ics = _setField(ics, 'DTSTAMP', _dt(DateTime.now()));

    final res = await _put(event.calendarHref, event.uid, ics);
    return res ? 'Event updated.' : 'Error updating event.';
  }

  Future<String> deleteEvent(CalDavEvent event) =>
      _delete(event.calendarHref, event.uid);

  // ── Raw ICS fetch (for updates) ─────────────────────────────────────────────

  Future<String?> fetchRawIcs(String calendarHref, String uid) async {
    final url = '$serverUrl${calendarHref}$uid.ics';
    final res = await http.get(Uri.parse(url), headers: _authHeaders);
    return res.statusCode == 200 ? res.body : null;
  }

  // ── Low-level helpers ───────────────────────────────────────────────────────

  Future<bool> _put(String calendarHref, String uid, String ics) async {
    final headers = Map<String, String>.from(_authHeaders);
    headers['Content-Type'] = 'text/calendar; charset=utf-8';
    final url = '$serverUrl${calendarHref}$uid.ics';
    final res = await http.put(Uri.parse(url), headers: headers, body: ics);
    return res.statusCode == 201 || res.statusCode == 204;
  }

  Future<String> _delete(String calendarHref, String uid) async {
    final url = '$serverUrl${calendarHref}$uid.ics';
    final res = await http.delete(Uri.parse(url), headers: _authHeaders);
    return res.statusCode == 204 ? 'Deleted.' : 'Error: HTTP ${res.statusCode}';
  }

  // ── ICS text helpers ────────────────────────────────────────────────────────

  String _unfold(String ics) =>
      ics.replaceAll(RegExp(r'\r\n[ \t]'), '').replaceAll(RegExp(r'\n[ \t]'), '');

  String? _component(String ics, String name) {
    final m = RegExp('BEGIN:$name\\r?\\n(.*?)END:$name', dotAll: true).firstMatch(ics);
    return m != null ? 'BEGIN:$name\r\n${m.group(1)}END:$name' : null;
  }

  String? _field(String block, String name) {
    // Matches NAME, NAME;PARAM=val, NAME;VALUE=DATE, etc.
    final m = RegExp('^${RegExp.escape(name)}(?:;[^:]*)?:(.+)\$', multiLine: true)
        .firstMatch(block);
    return m?.group(1)?.trim();
  }

  String _setField(String ics, String name, String value) {
    final re = RegExp('^${RegExp.escape(name)}(?:;[^:]*)?:.*\$', multiLine: true);
    if (re.hasMatch(ics)) return ics.replaceFirst(re, '$name:$value');
    // Insert before END:VTODO or END:VEVENT
    return ics.replaceFirstMapped(
        RegExp(r'END:(VTODO|VEVENT)'), (m) => '$name:$value\r\nEND:${m.group(1)}');
  }

  DateTime? _parseDate(String? s) {
    if (s == null) return null;
    // Strip TZID=... prefix if any
    final clean = s.contains(':') ? s.split(':').last : s;
    try {
      if (clean.length == 8) {
        return DateTime(int.parse(clean.substring(0, 4)),
            int.parse(clean.substring(4, 6)), int.parse(clean.substring(6, 8)));
      }
      if (clean.length >= 15) {
        return DateTime.utc(
          int.parse(clean.substring(0, 4)),
          int.parse(clean.substring(4, 6)),
          int.parse(clean.substring(6, 8)),
          int.parse(clean.substring(9, 11)),
          int.parse(clean.substring(11, 13)),
          int.parse(clean.substring(13, 15)),
        ).toLocal();
      }
    } catch (_) {}
    return null;
  }

  String _dt(DateTime d) {
    final u = d.toUtc();
    return '${_p4(u.year)}${_p2(u.month)}${_p2(u.day)}T${_p2(u.hour)}${_p2(u.minute)}${_p2(u.second)}Z';
  }

  String _date(DateTime d) =>
      '${_p4(d.year)}${_p2(d.month)}${_p2(d.day)}';

  String _p2(int n) => n.toString().padLeft(2, '0');
  String _p4(int n) => n.toString().padLeft(4, '0');

  String _uid() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  String _escapeIcs(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll('\n', '\\n')
      .replaceAll(',', '\\,')
      .replaceAll(';', '\\;');

  String _escapeXml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

// ── Tool definitions (JSON schema for the agent) ──────────────────────────────

const List<Map<String, dynamic>> calDavToolDefs = [
  {
    'name': 'list_calendars',
    'description': 'List all available calendars.',
    'inputSchema': {'type': 'object', 'properties': {}, 'required': []},
  },
  {
    'name': 'create_calendar',
    'description': 'Create a new calendar.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': 'Calendar name'},
      },
      'required': ['name'],
    },
  },
  {
    'name': 'rename_calendar',
    'description': 'Rename an existing calendar.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'calendar': {'type': 'string', 'description': 'Current calendar name or ID'},
        'new_name': {'type': 'string', 'description': 'New display name'},
      },
      'required': ['calendar', 'new_name'],
    },
  },
  {
    'name': 'delete_calendar',
    'description':
        'Delete a calendar and all its contents. Requires confirm="yes, delete".',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'calendar': {'type': 'string', 'description': 'Calendar name or ID'},
        'confirm': {
          'type': 'string',
          'description': 'Must be "yes, delete" to confirm deletion',
        },
      },
      'required': ['calendar', 'confirm'],
    },
  },
  {
    'name': 'list_tasks',
    'description': 'List tasks (VTODO). Optionally filter by calendar and date range.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'calendar': {'type': 'string', 'description': 'Calendar name or ID (omit for all)'},
        'from': {'type': 'string', 'description': 'Start date ISO 8601, e.g. 2026-06-01'},
        'to': {'type': 'string', 'description': 'End date ISO 8601'},
        'include_done': {
          'type': 'boolean',
          'description': 'Include completed/cancelled tasks (default false)',
        },
      },
      'required': [],
    },
  },
  {
    'name': 'create_task',
    'description': 'Create a new task (VTODO).',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': 'Task title'},
        'calendar': {'type': 'string', 'description': 'Calendar name or ID'},
        'due': {'type': 'string', 'description': 'Due date ISO 8601, e.g. 2026-06-15'},
        'priority': {
          'type': 'integer',
          'description': '1=high, 5=medium, 9=low (default 0=unset)',
        },
        'notes': {'type': 'string', 'description': 'Task notes'},
      },
      'required': ['title', 'calendar'],
    },
  },
  {
    'name': 'update_task',
    'description': 'Update an existing task.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'Task title (partial) or UID'},
        'calendar': {'type': 'string', 'description': 'Calendar name or ID (helps narrow search)'},
        'title': {'type': 'string', 'description': 'New title'},
        'due': {'type': 'string', 'description': 'New due date ISO 8601'},
        'status': {
          'type': 'string',
          'description': 'NEEDS-ACTION, IN-PROCESS, COMPLETED, CANCELLED',
        },
        'notes': {'type': 'string', 'description': 'New notes'},
        'priority': {'type': 'integer', 'description': '1=high, 5=medium, 9=low'},
      },
      'required': ['query'],
    },
  },
  {
    'name': 'complete_task',
    'description': 'Mark a task as COMPLETED.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'Task title (partial) or UID'},
        'calendar': {'type': 'string', 'description': 'Calendar name or ID'},
      },
      'required': ['query'],
    },
  },
  {
    'name': 'delete_task',
    'description': 'Delete a task. Requires confirm="yes, delete".',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'Task title (partial) or UID'},
        'calendar': {'type': 'string', 'description': 'Calendar name or ID'},
        'confirm': {
          'type': 'string',
          'description': 'Must be "yes, delete" to confirm',
        },
      },
      'required': ['query', 'confirm'],
    },
  },
  {
    'name': 'list_events',
    'description':
        'List calendar events (VEVENT) and tasks with a due date for a time range. '
        'Tasks with a due date appear alongside events (same as Nextcloud calendar view).',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'calendar': {'type': 'string', 'description': 'Calendar name or ID (omit for all)'},
        'from': {
          'type': 'string',
          'description': 'Start date ISO 8601. Omit for "from now".',
        },
        'to': {
          'type': 'string',
          'description': 'End date ISO 8601. Omit for "from start to +1 year".',
        },
      },
      'required': [],
    },
  },
  {
    'name': 'create_event',
    'description': 'Create a new calendar event (VEVENT).',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': 'Event title'},
        'start': {'type': 'string', 'description': 'Start datetime ISO 8601'},
        'end': {'type': 'string', 'description': 'End datetime ISO 8601'},
        'calendar': {'type': 'string', 'description': 'Calendar name or ID'},
        'location': {'type': 'string', 'description': 'Event location'},
        'attendee': {'type': 'string', 'description': 'Attendee name'},
        'notes': {'type': 'string', 'description': 'Event description'},
      },
      'required': ['title', 'start', 'end', 'calendar'],
    },
  },
  {
    'name': 'update_event',
    'description': 'Update an existing calendar event.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'Event title (partial) or UID'},
        'calendar': {'type': 'string', 'description': 'Calendar name or ID'},
        'title': {'type': 'string', 'description': 'New title'},
        'start': {'type': 'string', 'description': 'New start datetime ISO 8601'},
        'end': {'type': 'string', 'description': 'New end datetime ISO 8601'},
        'location': {'type': 'string', 'description': 'New location'},
        'notes': {'type': 'string', 'description': 'New description'},
      },
      'required': ['query'],
    },
  },
  {
    'name': 'delete_event',
    'description': 'Delete a calendar event. Requires confirm="yes, delete".',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'Event title (partial) or UID'},
        'calendar': {'type': 'string', 'description': 'Calendar name or ID'},
        'confirm': {
          'type': 'string',
          'description': 'Must be "yes, delete" to confirm',
        },
      },
      'required': ['query', 'confirm'],
    },
  },
];

// ── Tool executor ─────────────────────────────────────────────────────────────

class CalDavExecutor {
  final CalDavClient _client;

  CalDavExecutor(this._client);

  static bool handles(String toolName) =>
      calDavToolDefs.any((t) => t['name'] == toolName);

  Future<String> execute(String toolName, Map<String, dynamic> args) async {
    try {
      return await _dispatch(toolName, args);
    } catch (e) {
      return 'CalDAV error: $e';
    }
  }

  Future<String> _dispatch(String name, Map<String, dynamic> args) async {
    final calendars = await _client.listCalendars();

    switch (name) {
      // ── Calendars ──────────────────────────────────────────────────────────
      case 'list_calendars':
        if (calendars.isEmpty) return 'No calendars found.';
        return 'Your calendars:\n${calendars.map((c) => '• ${c.name}').join('\n')}';

      case 'create_calendar':
        return _client.createCalendar(_str(args, 'name'));

      case 'rename_calendar':
        final cal = _findCalendar(calendars, _str(args, 'calendar'));
        if (cal == null) return 'Calendar not found: ${args['calendar']}';
        return _client.renameCalendar(cal.href, _str(args, 'new_name'));

      case 'delete_calendar':
        if (_str(args, 'confirm') != 'yes, delete') {
          return 'Please confirm deletion by passing confirm="yes, delete".';
        }
        final cal = _findCalendar(calendars, _str(args, 'calendar'));
        if (cal == null) return 'Calendar not found: ${args['calendar']}';
        // Warn if non-empty
        final tasks = await _client.listTasks(cal, includeDone: true);
        final events = await _client.listEvents(cal);
        if (tasks.isNotEmpty || events.isNotEmpty) {
          final count = tasks.length + events.length;
          return 'Calendar "${cal.name}" has $count item(s). '
              'To delete it with all contents, call again with confirm="yes, delete". '
              '(You already confirmed — proceeding.)\n'
              '${await _client.deleteCalendar(cal.href)}';
        }
        return _client.deleteCalendar(cal.href);

      // ── Tasks ──────────────────────────────────────────────────────────────
      case 'list_tasks':
        final calFilter = args['calendar'] as String?;
        final targetCals = calFilter != null
            ? [_findCalendar(calendars, calFilter)].whereType<CalDavCalendar>().toList()
            : calendars;
        final from = _date(args['from']);
        final to = _date(args['to']);
        final includeDone = args['include_done'] == true;

        final all = <CalDavTask>[];
        for (final cal in targetCals) {
          all.addAll(await _client.listTasks(cal, from: from, to: to, includeDone: includeDone));
        }
        if (all.isEmpty) return 'No tasks found.';
        all.sort((a, b) => _taskSort(a, b));
        return _formatTasks(all, showCalendar: calFilter == null && calendars.length > 1);

      case 'create_task':
        final cal = _findCalendar(calendars, _str(args, 'calendar'));
        if (cal == null) return 'Calendar not found: ${args['calendar']}';
        return _client.createTask(
          calendar: cal,
          title: _str(args, 'title'),
          due: _date(args['due']),
          priority: (args['priority'] as num?)?.toInt() ?? 0,
          notes: _str(args, 'notes'),
        );

      case 'update_task':
        final task = await _client.findTask(
          _str(args, 'query'),
          _calList(calendars, args['calendar'] as String?),
        );
        if (task == null) return 'Task not found: ${args['query']}';
        return _client.updateTask(
          task,
          title: args['title'] as String?,
          due: _date(args['due']),
          status: args['status'] as String?,
          notes: args['notes'] as String?,
          priority: (args['priority'] as num?)?.toInt(),
        );

      case 'complete_task':
        final task = await _client.findTask(
          _str(args, 'query'),
          _calList(calendars, args['calendar'] as String?),
        );
        if (task == null) return 'Task not found: ${args['query']}';
        return _client.updateTask(task, status: 'COMPLETED');

      case 'delete_task':
        if (_str(args, 'confirm') != 'yes, delete') {
          return 'Please confirm deletion with confirm="yes, delete".';
        }
        final task = await _client.findTask(
          _str(args, 'query'),
          _calList(calendars, args['calendar'] as String?),
        );
        if (task == null) return 'Task not found: ${args['query']}';
        return _client.deleteTask(task);

      // ── Events ─────────────────────────────────────────────────────────────
      case 'list_events':
        final calFilter = args['calendar'] as String?;
        final targetCals = calFilter != null
            ? [_findCalendar(calendars, calFilter)].whereType<CalDavCalendar>().toList()
            : calendars;
        final from = _date(args['from']) ?? DateTime.now();
        final to = _date(args['to']);

        final all = <CalDavEvent>[];
        for (final cal in targetCals) {
          all.addAll(await _client.listEvents(cal, from: from, to: to));
        }
        if (all.isEmpty) return 'No events found.';
        all.sort((a, b) => a.start.compareTo(b.start));
        return _formatEvents(all, showCalendar: calFilter == null && calendars.length > 1);

      case 'create_event':
        final cal = _findCalendar(calendars, _str(args, 'calendar'));
        if (cal == null) return 'Calendar not found: ${args['calendar']}';
        final start = _date(args['start']) ?? DateTime.now();
        final end = _date(args['end']) ?? start.add(const Duration(hours: 1));
        return _client.createEvent(
          calendar: cal,
          title: _str(args, 'title'),
          start: start,
          end: end,
          location: _str(args, 'location'),
          attendee: _str(args, 'attendee'),
          notes: _str(args, 'notes'),
        );

      case 'update_event':
        final event = await _client.findEvent(
          _str(args, 'query'),
          _calList(calendars, args['calendar'] as String?),
        );
        if (event == null) return 'Event not found: ${args['query']}';
        final raw = await _client.fetchRawIcs(event.calendarHref, event.uid) ?? '';
        return _client.updateEvent(
          event, raw,
          title: args['title'] as String?,
          start: _date(args['start']),
          end: _date(args['end']),
          location: args['location'] as String?,
          notes: args['notes'] as String?,
        );

      case 'delete_event':
        if (_str(args, 'confirm') != 'yes, delete') {
          return 'Please confirm deletion with confirm="yes, delete".';
        }
        final event = await _client.findEvent(
          _str(args, 'query'),
          _calList(calendars, args['calendar'] as String?),
        );
        if (event == null) return 'Event not found: ${args['query']}';
        return _client.deleteEvent(event);

      default:
        return 'Unknown CalDAV tool: $name';
    }
  }

  // ── Formatting ──────────────────────────────────────────────────────────────

  String _formatTasks(List<CalDavTask> tasks, {bool showCalendar = false}) {
    final lines = tasks.map((t) {
      final due = t.due != null ? ' (due: ${_fmtDate(t.due!)})' : '';
      final cal = showCalendar ? ' [${t.calendarName}]' : '';
      final prio = t.priority == 1 ? ' ⚡' : t.priority == 9 ? ' ↓' : '';
      return '• ${t.title}$due$prio$cal';
    });
    return 'Found ${tasks.length} task(s):\n${lines.join('\n')}';
  }

  String _formatEvents(List<CalDavEvent> events, {bool showCalendar = false}) {
    final lines = events.map((e) {
      final end = e.end != null ? ' – ${_fmtTime(e.end!)}' : '';
      final loc = e.location.isNotEmpty ? ' @ ${e.location}' : '';
      final cal = showCalendar ? ' [${e.calendarName}]' : '';
      final tag = e.isTask ? ' ☑' : '';
      return '• ${_fmtDateTime(e.start)}$end — ${e.title}$loc$tag$cal';
    });
    return 'Found ${events.length} item(s):\n${lines.join('\n')}';
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${_p2(d.month)}-${_p2(d.day)}';

  String _fmtDateTime(DateTime d) =>
      '${d.year}-${_p2(d.month)}-${_p2(d.day)} ${_p2(d.hour)}:${_p2(d.minute)}';

  String _fmtTime(DateTime d) => '${_p2(d.hour)}:${_p2(d.minute)}';

  String _p2(int n) => n.toString().padLeft(2, '0');

  // ── Lookup helpers ──────────────────────────────────────────────────────────

  CalDavCalendar? _findCalendar(List<CalDavCalendar> cals, String query) {
    final q = query.toLowerCase();
    return cals.firstWhere(
      (c) => c.name.toLowerCase() == q || c.id.toLowerCase() == q,
      orElse: () => cals.firstWhere(
        (c) => c.name.toLowerCase().contains(q) || c.id.toLowerCase().contains(q),
        orElse: () => throw Exception('not found'),
      ),
    );
  }

  List<CalDavCalendar> _calList(List<CalDavCalendar> all, String? filter) {
    if (filter == null || filter.isEmpty) return all;
    final found = _findCalendar(all, filter);
    return found != null ? [found] : all;
  }

  String _str(Map<String, dynamic> args, String key) =>
      (args[key] as String?) ?? '';

  DateTime? _date(dynamic val) {
    if (val == null || val.toString().isEmpty) return null;
    return DateTime.tryParse(val.toString());
  }

  int _taskSort(CalDavTask a, CalDavTask b) {
    if (a.due == null && b.due == null) return a.title.compareTo(b.title);
    if (a.due == null) return 1;
    if (b.due == null) return -1;
    return a.due!.compareTo(b.due!);
  }
}

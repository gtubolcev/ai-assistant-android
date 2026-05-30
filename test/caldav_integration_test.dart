/// Integration tests for CalDavClient against the real cloud.rakulka.ru server.
/// Run with: flutter test test/caldav_integration_test.dart
///
/// Requires network access. Uses the dedicated test account:
///   server: https://cloud.rakulka.ru  user: claude
///
/// Each test cleans up after itself. Tests are silently skipped when the
/// server is unreachable (e.g. in CI without external network access).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ai_assistant/tools/caldav_tool.dart';

// ── Credentials ───────────────────────────────────────────────────────────────

const _kServer = 'https://cloud.rakulka.ru';
const _kUser   = 'claude';
const _kPass   = '25Hi7-yrNKC-ibzTJ-wbimD-B7J9R';

CalDavClient _client() =>
    CalDavClient(serverUrl: _kServer, username: _kUser, password: _kPass);

// ── Helpers ───────────────────────────────────────────────────────────────────

String _tag() => 'test-${DateTime.now().millisecondsSinceEpoch}';

bool _reachable = false;

/// Like test() but silently passes when the server is not reachable.
void _t(String name, Future<void> Function() body) {
  test(name, () async {
    if (!_reachable) return;
    await body();
  });
}

Future<bool> _checkReachable() async {
  try {
    // Do an actual HTTP OPTIONS to verify the server responds, not just DNS.
    final req = http.Request(
        'OPTIONS',
        Uri.parse('$_kServer/remote.php/dav/calendars/$_kUser/'))
      ..headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('$_kUser:$_kPass'))}';
    final res = await http.Response.fromStream(
            await req.send().timeout(const Duration(seconds: 8)))
        .timeout(const Duration(seconds: 10));
    return res.statusCode < 500;
  } catch (_) {
    return false;
  }
}

// ── Suite ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() async {
    _reachable = await _checkReachable();
    if (!_reachable) {
      // ignore: avoid_print
      print('⚠️  cloud.rakulka.ru not reachable — all integration tests skipped');
    }
  });

  // ── Calendars ───────────────────────────────────────────────────────────────

  group('Calendars', () {
    _t('listCalendars returns at least Personal or Tasks calendar', () async {
      final cals = await _client().listCalendars();
      expect(cals, isNotEmpty);
      expect(
        cals.any((c) =>
            c.name.toLowerCase().contains('personal') ||
            c.name.toLowerCase().contains('task')),
        isTrue,
      );
    });

    _t('create → visible in list → delete', () async {
      final client = _client();
      final name = 'TestCal-${_tag()}';

      expect(await client.createCalendar(name), contains('created'));

      final cals = await client.listCalendars();
      final created = cals.firstWhere((c) => c.name == name,
          orElse: () => throw TestFailure('Calendar not found after creation'));

      expect(await client.deleteCalendar(created.href), contains('deleted'));

      final after = await client.listCalendars();
      expect(after.any((c) => c.name == name), isFalse);
    });

    _t('renameCalendar changes display name', () async {
      final client = _client();
      final name  = 'Rename-${_tag()}';
      final name2 = 'Renamed-${_tag()}';

      await client.createCalendar(name);
      var cals = await client.listCalendars();
      final cal = cals.firstWhere((c) => c.name == name);

      await client.renameCalendar(cal.href, name2);

      cals = await client.listCalendars();
      expect(cals.any((c) => c.name == name2), isTrue);
      expect(cals.any((c) => c.name == name),  isFalse);

      await client.deleteCalendar(
          cals.firstWhere((c) => c.name == name2).href);
    });
  });

  // ── Tasks ───────────────────────────────────────────────────────────────────

  group('Tasks', () {
    late CalDavCalendar tasksCal;

    setUpAll(() async {
      if (!_reachable) return;
      final cals = await _client().listCalendars();
      tasksCal = cals.firstWhere(
        (c) => c.id.toLowerCase() == 'tasks',
        orElse: () => throw TestFailure(
            'Tasks calendar not found — run the app once to create it'),
      );
    });

    _t('create → visible in listTasks', () async {
      final client = _client();
      final title = 'Task-${_tag()}';

      expect(
        await client.createTask(calendar: tasksCal, title: title, notes: 'test'),
        contains('created'),
      );

      final tasks = await client.listTasks(tasksCal, includeDone: false);
      expect(tasks.any((t) => t.title == title), isTrue);

      await client.deleteTask(tasks.firstWhere((t) => t.title == title));
    });

    _t('due date is preserved after round-trip', () async {
      final client = _client();
      final title = 'DueTask-${_tag()}';
      final due   = DateTime.now().add(const Duration(days: 3));

      await client.createTask(calendar: tasksCal, title: title, due: due);
      final tasks = await client.listTasks(tasksCal, includeDone: true);
      final task  = tasks.firstWhere((t) => t.title == title);

      expect(task.due?.year,  due.year);
      expect(task.due?.month, due.month);
      expect(task.due?.day,   due.day);

      await client.deleteTask(task);
    });

    _t('updateTask changes title and status', () async {
      final client = _client();
      final title  = 'Update-${_tag()}';
      final title2 = '$title-v2';

      await client.createTask(calendar: tasksCal, title: title);
      var tasks = await client.listTasks(tasksCal, includeDone: false);
      await client.updateTask(
          tasks.firstWhere((t) => t.title == title),
          title: title2, status: 'IN-PROCESS');

      tasks = await client.listTasks(tasksCal, includeDone: true);
      final updated = tasks.firstWhere((t) => t.title == title2,
          orElse: () => throw TestFailure('Updated task not found'));
      expect(updated.status, 'IN-PROCESS');

      await client.deleteTask(updated);
    });

    _t('completed task disappears from active list', () async {
      final client = _client();
      final title  = 'Complete-${_tag()}';

      await client.createTask(calendar: tasksCal, title: title);
      var tasks = await client.listTasks(tasksCal, includeDone: false);
      await client.updateTask(
          tasks.firstWhere((t) => t.title == title), status: 'COMPLETED');

      expect(
        (await client.listTasks(tasksCal, includeDone: false))
            .any((t) => t.title == title),
        isFalse,
      );

      final all = await client.listTasks(tasksCal, includeDone: true);
      final done = all.firstWhere((t) => t.title == title);
      expect(done.isDone, isTrue);
      await client.deleteTask(done);
    });

    _t('deleteTask removes task permanently', () async {
      final client = _client();
      final title  = 'Delete-${_tag()}';

      await client.createTask(calendar: tasksCal, title: title);
      var tasks = await client.listTasks(tasksCal, includeDone: true);

      expect(
        await client.deleteTask(tasks.firstWhere((t) => t.title == title)),
        contains('Deleted'),
      );

      tasks = await client.listTasks(tasksCal, includeDone: true);
      expect(tasks.any((t) => t.title == title), isFalse);
    });

    _t('findTask by title substring', () async {
      final client = _client();
      final unique = _tag();
      final title  = 'Find-$unique';

      await client.createTask(calendar: tasksCal, title: title);
      final cals  = await client.listCalendars();
      final found = await client.findTask(unique, cals);

      expect(found, isNotNull);
      expect(found!.title, title);
      await client.deleteTask(found);
    });
  });

  // ── Events ──────────────────────────────────────────────────────────────────

  group('Events', () {
    late CalDavCalendar personalCal;

    setUpAll(() async {
      if (!_reachable) return;
      final cals = await _client().listCalendars();
      personalCal = cals.firstWhere(
        (c) => c.id.toLowerCase() == 'personal',
        orElse: () => throw TestFailure('Personal calendar not found'),
      );
    });

    _t('create → visible in listEvents', () async {
      final client = _client();
      final title  = 'Event-${_tag()}';
      final start  = DateTime.now().add(const Duration(hours: 1));
      final end    = start.add(const Duration(hours: 2));

      expect(
        await client.createEvent(
            calendar: personalCal, title: title, start: start, end: end,
            location: 'Test location', notes: 'integration test'),
        contains('created'),
      );

      final events = await client.listEvents(personalCal,
          from: start.subtract(const Duration(minutes: 5)),
          to:   end.add(const Duration(minutes: 5)));
      expect(events.any((e) => e.title == title), isTrue);

      final event = await client.findEvent(title, await client.listCalendars());
      if (event != null) await client.deleteEvent(event);
    });

    _t('updateEvent changes title and location', () async {
      final client = _client();
      final title  = 'UpdEvent-${_tag()}';
      final start  = DateTime.now().add(const Duration(hours: 2));
      final end    = start.add(const Duration(hours: 1));

      await client.createEvent(
          calendar: personalCal, title: title, start: start, end: end);

      final cals  = await client.listCalendars();
      final event = await client.findEvent(title, cals);
      expect(event, isNotNull);

      final raw = await client.fetchRawIcs(event!.calendarHref, event.uid);
      expect(raw, isNotNull);

      final title2 = '$title-v2';
      await client.updateEvent(event, raw!,
          title: title2, location: 'New place');

      final updated = await client.findEvent(title2, cals);
      expect(updated, isNotNull);
      expect(updated!.location, 'New place');
      await client.deleteEvent(updated);
    });

    _t('deleteEvent removes event permanently', () async {
      final client = _client();
      final title  = 'DelEvent-${_tag()}';
      final start  = DateTime.now().add(const Duration(hours: 3));

      await client.createEvent(
          calendar: personalCal, title: title,
          start: start, end: start.add(const Duration(hours: 1)));

      final cals  = await client.listCalendars();
      final event = await client.findEvent(title, cals);
      expect(event, isNotNull);

      expect(await client.deleteEvent(event!), contains('Deleted'));
      expect(await client.findEvent(title, cals), isNull);
    });
  });

  // ── CalDavExecutor (tool dispatch) ───────────────────────────────────────────

  group('CalDavExecutor', () {
    late CalDavExecutor executor;
    setUp(() { executor = CalDavExecutor(_client()); });

    _t('list_calendars returns non-empty result', () async {
      final r = await executor.execute('list_calendars', {});
      expect(r, isNotEmpty);
      expect(r.toLowerCase(), contains('calendar'));
    });

    _t('list_tasks returns result without error', () async {
      final r = await executor.execute('list_tasks', {});
      expect(r, isNot(contains('CalDAV error')));
    });

    _t('create + complete + delete round-trip via executor', () async {
      final title = 'Exec-${_tag()}';

      expect(
        await executor.execute('create_task',
            {'title': title, 'calendar': 'tasks'}),
        contains('created'),
      );
      expect(
        await executor.execute('complete_task', {'query': title}),
        contains('updated'),
      );
      expect(
        await executor.execute('delete_task',
            {'query': title, 'confirm': 'yes, delete'}),
        contains('Deleted'),
      );
    });

    _t('unknown tool returns error message', () async {
      expect(
        await executor.execute('nonexistent_tool', {}),
        contains('Unknown'),
      );
    });
  });
}

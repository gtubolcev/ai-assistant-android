/// Integration tests for CalDavClient against the real cloud.rakulka.ru server.
/// Run with: flutter test test/caldav_integration_test.dart
///
/// Requires network access. Uses the dedicated test account:
///   server: https://cloud.rakulka.ru
///   user:   claude
///   pass:   (app-password stored in test constants below)
///
/// Each test cleans up after itself — no permanent side effects.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_assistant/tools/caldav_tool.dart';

// ── Test credentials ──────────────────────────────────────────────────────────

const _kServer = 'https://cloud.rakulka.ru';
const _kUser   = 'claude';
const _kPass   = '25Hi7-yrNKC-ibzTJ-wbimD-B7J9R';

CalDavClient _client() =>
    CalDavClient(serverUrl: _kServer, username: _kUser, password: _kPass);

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Unique prefix for test-created objects so we can identify and clean them up.
String _tag() => 'test-${DateTime.now().millisecondsSinceEpoch}';

void main() {
  // ── Calendars ───────────────────────────────────────────────────────────────

  group('Calendars', () {
    test('listCalendars returns at least the Tasks calendar', () async {
      final cals = await _client().listCalendars();
      expect(cals, isNotEmpty);
      expect(cals.any((c) => c.name.toLowerCase().contains('task') ||
                             c.name.toLowerCase().contains('personal')),
             isTrue);
    });

    test('createCalendar → visible in list → deleteCalendar', () async {
      final client = _client();
      final name = 'TestCal-${_tag()}';

      final msg = await client.createCalendar(name);
      expect(msg, contains('created'));

      final cals = await client.listCalendars();
      final created = cals.firstWhere((c) => c.name == name,
          orElse: () => throw TestFailure('Calendar "$name" not found after creation'));

      final del = await client.deleteCalendar(created.href);
      expect(del, contains('deleted'));

      final after = await client.listCalendars();
      expect(after.any((c) => c.name == name), isFalse);
    });

    test('renameCalendar changes display name', () async {
      final client = _client();
      final name  = 'RenameTest-${_tag()}';
      final name2 = 'RenameTest2-${_tag()}';

      await client.createCalendar(name);
      final cals = await client.listCalendars();
      final cal = cals.firstWhere((c) => c.name == name);

      await client.renameCalendar(cal.href, name2);

      final after = await client.listCalendars();
      expect(after.any((c) => c.name == name2), isTrue);
      expect(after.any((c) => c.name == name),  isFalse);

      // cleanup
      final updated = after.firstWhere((c) => c.name == name2);
      await client.deleteCalendar(updated.href);
    });
  });

  // ── Tasks ───────────────────────────────────────────────────────────────────

  group('Tasks', () {
    late CalDavClient client;
    late CalDavCalendar tasksCal;

    setUpAll(() async {
      client = _client();
      final cals = await client.listCalendars();
      tasksCal = cals.firstWhere(
        (c) => c.id.toLowerCase() == 'tasks',
        orElse: () => throw TestFailure(
            'Tasks calendar not found — run the app first to create it'),
      );
    });

    test('createTask → visible in listTasks', () async {
      final title = 'Task-${_tag()}';
      final msg = await client.createTask(
        calendar: tasksCal,
        title: title,
        notes: 'integration test',
      );
      expect(msg, contains('created'));

      final tasks = await client.listTasks(tasksCal, includeDone: false);
      expect(tasks.any((t) => t.title == title), isTrue);

      // cleanup
      final task = tasks.firstWhere((t) => t.title == title);
      await client.deleteTask(task);
    });

    test('createTask with due date → due field preserved', () async {
      final title = 'DueTask-${_tag()}';
      final due = DateTime.now().add(const Duration(days: 3));

      await client.createTask(calendar: tasksCal, title: title, due: due);

      final tasks = await client.listTasks(tasksCal, includeDone: true);
      final task = tasks.firstWhere((t) => t.title == title);
      expect(task.due, isNotNull);
      expect(task.due!.year,  due.year);
      expect(task.due!.month, due.month);
      expect(task.due!.day,   due.day);

      await client.deleteTask(task);
    });

    test('updateTask title and status', () async {
      final title = 'UpdateTask-${_tag()}';
      await client.createTask(calendar: tasksCal, title: title);

      var tasks = await client.listTasks(tasksCal, includeDone: false);
      var task  = tasks.firstWhere((t) => t.title == title);

      final newTitle = '$title-updated';
      await client.updateTask(task, title: newTitle, status: 'IN-PROCESS');

      tasks = await client.listTasks(tasksCal, includeDone: true);
      task  = tasks.firstWhere((t) => t.title == newTitle,
          orElse: () => throw TestFailure('Updated task not found'));
      expect(task.status, 'IN-PROCESS');

      await client.deleteTask(task);
    });

    test('complete task via updateTask(status: COMPLETED)', () async {
      final title = 'CompleteTask-${_tag()}';
      await client.createTask(calendar: tasksCal, title: title);

      var tasks = await client.listTasks(tasksCal, includeDone: false);
      var task  = tasks.firstWhere((t) => t.title == title);
      await client.updateTask(task, status: 'COMPLETED');

      // Should NOT appear in active tasks
      final active = await client.listTasks(tasksCal, includeDone: false);
      expect(active.any((t) => t.title == title), isFalse);

      // Should appear in all tasks
      final all = await client.listTasks(tasksCal, includeDone: true);
      task = all.firstWhere((t) => t.title == title);
      expect(task.isDone, isTrue);

      await client.deleteTask(task);
    });

    test('deleteTask removes task permanently', () async {
      final title = 'DeleteTask-${_tag()}';
      await client.createTask(calendar: tasksCal, title: title);

      var tasks = await client.listTasks(tasksCal, includeDone: true);
      final task = tasks.firstWhere((t) => t.title == title);

      final msg = await client.deleteTask(task);
      expect(msg, contains('Deleted'));

      tasks = await client.listTasks(tasksCal, includeDone: true);
      expect(tasks.any((t) => t.title == title), isFalse);
    });

    test('findTask by title substring', () async {
      final unique = _tag();
      final title = 'FindMe-$unique';
      await client.createTask(calendar: tasksCal, title: title);

      final cals = await client.listCalendars();
      final found = await client.findTask(unique, cals);
      expect(found, isNotNull);
      expect(found!.title, title);

      await client.deleteTask(found);
    });
  });

  // ── Events ──────────────────────────────────────────────────────────────────

  group('Events', () {
    late CalDavClient client;
    late CalDavCalendar personalCal;

    setUpAll(() async {
      client = _client();
      final cals = await client.listCalendars();
      personalCal = cals.firstWhere(
        (c) => c.id.toLowerCase() == 'personal',
        orElse: () => throw TestFailure('Personal calendar not found'),
      );
    });

    test('createEvent → visible in listEvents', () async {
      final title = 'Event-${_tag()}';
      final start = DateTime.now().add(const Duration(hours: 1));
      final end   = start.add(const Duration(hours: 2));

      final msg = await client.createEvent(
        calendar: personalCal,
        title: title,
        start: start,
        end: end,
        location: 'Test location',
        notes: 'integration test event',
      );
      expect(msg, contains('created'));

      final events = await client.listEvents(personalCal,
          from: start.subtract(const Duration(minutes: 5)),
          to: end.add(const Duration(minutes: 5)));
      expect(events.any((e) => e.title == title), isTrue);

      // cleanup
      final cals = await client.listCalendars();
      final event = await client.findEvent(title, cals);
      if (event != null) await client.deleteEvent(event);
    });

    test('updateEvent title and location', () async {
      final title = 'UpdateEvent-${_tag()}';
      final start = DateTime.now().add(const Duration(hours: 2));
      final end   = start.add(const Duration(hours: 1));

      await client.createEvent(
          calendar: personalCal, title: title, start: start, end: end);

      final cals  = await client.listCalendars();
      final event = await client.findEvent(title, cals);
      expect(event, isNotNull);

      final raw = await client.fetchRawIcs(event!.calendarHref, event.uid);
      expect(raw, isNotNull);

      final newTitle = '$title-renamed';
      await client.updateEvent(event, raw!, title: newTitle, location: 'New place');

      final updated = await client.findEvent(newTitle, cals);
      expect(updated, isNotNull);
      expect(updated!.location, 'New place');

      await client.deleteEvent(updated);
    });

    test('deleteEvent removes event permanently', () async {
      final title = 'DeleteEvent-${_tag()}';
      final start = DateTime.now().add(const Duration(hours: 3));
      final end   = start.add(const Duration(hours: 1));

      await client.createEvent(
          calendar: personalCal, title: title, start: start, end: end);

      final cals  = await client.listCalendars();
      final event = await client.findEvent(title, cals);
      expect(event, isNotNull);

      final msg = await client.deleteEvent(event!);
      expect(msg, contains('Deleted'));

      final gone = await client.findEvent(title, cals);
      expect(gone, isNull);
    });
  });

  // ── CalDavExecutor (tool dispatch layer) ────────────────────────────────────

  group('CalDavExecutor', () {
    late CalDavExecutor executor;

    setUp(() {
      executor = CalDavExecutor(_client());
    });

    test('list_calendars returns non-empty string', () async {
      final result = await executor.execute('list_calendars', {});
      expect(result, isNotEmpty);
      expect(result.toLowerCase(), contains('calendar'));
    });

    test('list_tasks returns result without error', () async {
      final result = await executor.execute('list_tasks', {});
      expect(result, isNot(contains('Error')));
      expect(result, isNot(contains('CalDAV error')));
    });

    test('create_task + complete_task + delete_task round-trip', () async {
      final title = 'ExecTask-${_tag()}';

      var r = await executor.execute('create_task',
          {'title': title, 'calendar': 'tasks'});
      expect(r, contains('created'));

      r = await executor.execute('complete_task', {'query': title});
      expect(r, contains('updated'));

      r = await executor.execute('delete_task',
          {'query': title, 'confirm': 'yes, delete'});
      expect(r, contains('Deleted'));
    });

    test('unknown tool returns error message', () async {
      final r = await executor.execute('nonexistent_tool', {});
      expect(r, contains('Unknown'));
    });
  });
}

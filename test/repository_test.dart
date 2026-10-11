import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sync_task_app/main.dart';
import 'package:sync_task_app/session.dart';
import 'package:sync_task_app/assistant.dart';

void main() {
  late Directory dir;
  var online = false;
  final records = <String, Map<String, dynamic>>{};
  final requests = <http.Request>[];
  String user = 'aaaaaaaaaaaaaaa';
  String jwt({bool expired = false}) =>
      'e30.${base64Url.encode(utf8.encode(jsonEncode({'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + (expired ? -1 : 3600)}))).replaceAll('=', '')}.sig';
  void signIn(String id) {
    user = id;
    pb.authStore.save(
      jwt(),
      RecordModel({'id': id, 'collectionName': 'users'}),
    );
  }

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('task-tests');
    Hive.init(dir.path);
    await Hive.openBox(tasksCacheBoxName);
    await Hive.openBox(pendingChangesBoxName);
    pb = PocketBase(
      'http://localhost',
      httpClientFactory: () => MockClient((request) async {
        requests.add(request);
        if (!online) throw const SocketException('Offline');
        final last = request.url.path.split('/').last;
        if (last == 'auth-refresh') {
          return http.Response(
            jsonEncode({
              'token': jwt(),
              'record': {'id': user, 'collectionName': 'users'},
            }),
            200,
          );
        }
        if (request.method == 'GET' && last == 'records') {
          return http.Response(
            jsonEncode({
              'items': records.values.where((r) => r['user'] == user).toList(),
              'page': 1,
              'perPage': 500,
              'totalPages': 1,
              'totalItems': records.length,
            }),
            200,
          );
        }
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode(records[last] ?? {}),
            records.containsKey(last) ? 200 : 404,
          );
        }
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (records.containsKey(body['id'])) return http.Response('{}', 400);
          records[body['id']] = body;
          return http.Response(jsonEncode(body), 200);
        }
        if (request.method == 'PATCH') {
          records[last]!.addAll(
            jsonDecode(request.body) as Map<String, dynamic>,
          );
          return http.Response(jsonEncode(records[last]), 200);
        }
        records.remove(last);
        return http.Response('', 204);
      }),
    );
  });
  setUp(() async {
    online = false;
    records.clear();
    requests.clear();
    await Hive.box(tasksCacheBoxName).clear();
    await Hive.box(pendingChangesBoxName).clear();
    signIn('aaaaaaaaaaaaaaa');
  });
  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test(
    'Scheduling metadata survives legacy maps and offline serialization',
    () {
      final legacy = AppTask.fromMap({'id': 'x', 'title': 'Exam'});
      expect(legacy.dueAt, '');
      final task = legacy.copyWith(
        dueAt: '2026-10-12T12:00:00Z',
        estimatedMinutes: 60,
        category: 'Study',
      );
      expect(AppTask.fromMap(task.toMap()).estimatedMinutes, 60);
    },
  );
  test(
    'Offline create edit complete survives refresh and synchronizes once',
    () async {
      final repo = TaskRepository();
      final task = await repo.createTask(
        title: 'Exam',
        description: 'Study',
        priority: TaskPriority.normal,
      );
      final updated = task.copyWith(
        title: 'Circuits exam',
        isCompleted: true,
        completedAt: '2026-10-11T00:00:00Z',
      );
      await repo.updateTask(updated);
      expect((await repo.loadTasks()).single.title, 'Circuits exam');
      online = true;
      await repo.syncPendingChanges();
      await repo.syncPendingChanges();
      expect(records.length, 1);
      expect(records.values.single['is_completed'], true);
      expect(Hive.box(pendingChangesBoxName).isEmpty, true);
    },
  );
  test('Server reload overlays pending local edits', () async {
    final repo = TaskRepository();
    online = true;
    final task = await repo.createTask(
      title: 'Old',
      description: '',
      priority: TaskPriority.normal,
    );
    online = false;
    await repo.updateTask(task.copyWith(title: 'Offline edit'));
    online = true;
    expect((await repo.loadTasks()).single.title, 'Offline edit');
  });
  test('Queued changes and cache never cross accounts', () async {
    final repo = TaskRepository();
    await repo.createTask(
      title: 'Private A',
      description: '',
      priority: TaskPriority.high,
    );
    signIn('ccccccccccccccc');
    final other = TaskRepository();
    expect(await other.loadTasks(), isEmpty);
    online = true;
    await other.syncPendingChanges();
    expect(records, isEmpty);
    signIn('aaaaaaaaaaaaaaa');
    await TaskRepository().syncPendingChanges();
    expect(records.values.single['user'], 'aaaaaaaaaaaaaaa');
  });
  test('Offline deletes stay hidden after server reload', () async {
    final repo = TaskRepository();
    online = true;
    final task = await repo.createTask(
      title: 'Delete me',
      description: '',
      priority: TaskPriority.normal,
    );
    online = false;
    await repo.deleteTask(task);
    online = true;
    expect(await repo.loadTasks(), isEmpty);
    await repo.syncPendingChanges();
    expect(records, isEmpty);
  });
  test('Lost create response retries with stable record id', () async {
    final repo = TaskRepository();
    final task = await repo.createTask(
      title: 'Once',
      description: '',
      priority: TaskPriority.normal,
    );
    records[task.id] = task.toServerBody(user)..['id'] = task.id;
    online = true;
    await repo.syncPendingChanges();
    expect(records.length, 1);
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
  });
  test('Network outage keeps authentication for offline tasks', () async {
    await refreshSession(pb);
    expect(pb.authStore.record?.id, user);
  });
  test('Server revocation clears the session', () async {
    final denied = PocketBase(
      'http://localhost',
      httpClientFactory: () =>
          MockClient((_) async => http.Response('{}', 401)),
    );
    denied.authStore.save(jwt(), RecordModel({'id': user}));
    await refreshSession(denied);
    expect(denied.authStore.record, isNull);
  });
  test('Assistant rejects expired token before sending it', () async {
    final expired = PocketBase('http://localhost');
    expired.authStore.save(jwt(expired: true), RecordModel({'id': user}));
    final client = AssistantClient(
      expired,
      endpoint: 'https://assistant.example',
      transport: MockClient((_) async {
        fail('No request expected');
      }),
    );
    await expectLater(client.request('/conversations'), throwsStateError);
    client.close();
  });
}

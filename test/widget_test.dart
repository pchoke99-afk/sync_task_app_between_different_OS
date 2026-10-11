import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sync_task_app/main.dart';
import 'package:sync_task_app/assistant.dart';

String token() =>
    '${base64Url.encode(utf8.encode('{}'))}.${base64Url.encode(utf8.encode(jsonEncode({'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600}))).replaceAll('=', '')}.signature';

void main() {
  setUpAll(() {
    pb = PocketBase('http://localhost');
  });
  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets(
      '$platform dictation creates a draft without sending a request',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        const channel = MethodChannel('sync_task/assistant_media');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method == 'startSpeech')
              return 'Add a task to study circuits';
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: AssistantScreen(client: AssistantClient(pb, endpoint: '')),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Dictate message'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Add a task to study circuits',
        );
        expect(find.text('You'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('Signed-out app shows working login form', (tester) async {
    await tester.pumpWidget(const SyncTaskApp());
    await tester.pump();
    expect(find.text('Log in'), findsNWidgets(2));
    expect(find.byType(TextField), findsNWidgets(2));
  });
  testWidgets('Assistant explains cloud availability when unconfigured', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantScreen(client: AssistantClient(pb, endpoint: '')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('not configured'), findsOneWidget);
    expect(
      find.textContaining('approve changes before they are saved'),
      findsOneWidget,
    );
  });
  testWidgets(
    'Assistant previews a delete and only applies after dialog confirmation',
    (tester) async {
      final client = PocketBase('http://localhost');
      client.authStore.save(token(), RecordModel({'id': 'aaaaaaaaaaaaaaa'}));
      var decisions = 0;
      var sent = false;
      final proposal = {
        'id': 'proposal',
        'status': 'pending',
        'operations': [
          {
            'name': 'delete_task',
            'preview_title': 'Circuits homework',
            'arguments': {'task_id': 'bbbbbbbbbbbbbbb'},
          },
        ],
      };
      final transport = MockClient((request) async {
        expect(request.headers['Authorization'], startsWith('Bearer '));
        Map<String, dynamic> result;
        if (request.url.path == '/chat') {
          sent = true;
          result = {
            'conversation_id': 'chat',
            'answer': 'Review deletion',
            'proposal': proposal,
          };
        } else if (request.url.path.contains('/decision')) {
          decisions++;
          proposal['status'] = 'applied';
          result = {'status': 'applied'};
        } else if (request.url.path == '/conversations') {
          result = {
            'conversations': sent
                ? [
                    {'id': 'chat', 'title': 'Delete circuits homework'},
                  ]
                : [],
          };
        } else {
          result = {
            'messages': [
              {'role': 'assistant', 'content': 'Review deletion'},
            ],
            'proposals': [proposal],
          };
        }
        return http.Response(jsonEncode(result), 200);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: AssistantScreen(
            client: AssistantClient(
              client,
              transport: transport,
              endpoint: 'https://assistant.example',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'Delete circuits homework',
      );
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      expect(decisions, 0);
      await tester.tap(find.text('Review and apply'));
      await tester.pumpAndSettle();
      expect(decisions, 0);
      expect(find.text('Apply these task changes?'), findsOneWidget);
      await tester.tap(find.text('Confirm changes'));
      await tester.pumpAndSettle();
      expect(decisions, 1);
    },
  );
  testWidgets('Earlier conversation messages can be loaded on a phone layout', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = PocketBase('http://localhost');
    client.authStore.save(token(), RecordModel({'id': 'aaaaaaaaaaaaaaa'}));
    var loadedEarlier = false;
    final transport = MockClient((request) async {
      Map<String, dynamic> data;
      if (request.url.path == '/chat') {
        data = {'conversation_id': 'saved'};
      } else if (request.url.path == '/conversations') {
        data = {
          'conversations': [
            {'id': 'saved', 'title': 'Study planning'},
          ],
        };
      } else {
        final earlier = request.url.queryParameters['before_message'] == '16';
        loadedEarlier = loadedEarlier || earlier;
        data = {
          'messages': List.generate(
            earlier ? 15 : 40,
            (i) => {
              'id': i + (earlier ? 1 : 16),
              'role': 'user',
              'content': 'Message ${i + (earlier ? 1 : 16)}',
            },
          ),
          'proposals': [],
          'has_more': !earlier,
        };
      }
      return http.Response(jsonEncode(data), 200);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantScreen(
          client: AssistantClient(
            client,
            transport: transport,
            endpoint: 'https://assistant.example',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Continue our planning');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load earlier messages'));
    await tester.pumpAndSettle();
    expect(loadedEarlier, true);
    expect(find.text('Message 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

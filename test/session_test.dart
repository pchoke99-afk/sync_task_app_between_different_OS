import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/testing.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sync_task_app/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Legacy authentication migrates to secure storage before preferences are removed', () async {
    final legacy = jsonEncode({
      'token': 'legacy-test-token',
      'model': {'id': 'aaaaaaaaaaaaaaa'},
    });
    SharedPreferences.setMockInitialValues({'pb_auth': legacy});
    FlutterSecureStorage.setMockInitialValues({});
    final auth = await createAuthStore();
    expect(auth.record?.id, 'aaaaaaaaaaaaaaa');
    expect(await secureAuth.read(key: 'pb_auth'), legacy);
    expect(
      (await SharedPreferences.getInstance()).containsKey('pb_auth'),
      false,
    );
  });
  testWidgets('Logout discards assistant routes and returns to login', (
    tester,
  ) async {
    final client = PocketBase(
      'http://localhost',
      httpClientFactory: () =>
          MockClient((_) async => throw const SocketException('offline')),
    );
    client.authStore.save('test-token', RecordModel({'id': 'aaaaaaaaaaaaaaa'}));
    await tester.pumpWidget(
      MaterialApp(
        home: SessionGate(
          client: client,
          signedIn: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const Scaffold(body: Text('Private assistant history')),
                ),
              ),
              child: const Text('Open assistant'),
            ),
          ),
          signedOut: const Text('Login required'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open assistant'));
    await tester.pumpAndSettle();
    expect(find.text('Private assistant history'), findsOneWidget);
    client.authStore.clear();
    await tester.pumpAndSettle();
    expect(find.text('Private assistant history'), findsNothing);
    expect(find.text('Login required'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

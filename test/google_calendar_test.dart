import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sync_task_app/google_calendar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, String> savedTokens(String user, {bool expired = false}) => {
    'google_calendar_tokens_$user': jsonEncode({
      'access_token': 'test-access',
      'refresh_token': 'test-refresh',
      'expires_at':
          DateTime.now().millisecondsSinceEpoch + (expired ? -1000 : 3600000),
    }),
    'google_calendar_desktop_client': jsonEncode({
      'client_id': 'test.apps.googleusercontent.com',
      'client_secret': 'test-client',
    }),
  };

  test('Calendar tokens stay isolated by task account', () async {
    FlutterSecureStorage.setMockInitialValues(savedTokens('alice'));
    final alice = GoogleCalendarConnection('alice');
    final bob = GoogleCalendarConnection('bob');
    expect(await alice.isConnected, isTrue);
    expect(await bob.isConnected, isFalse);
    await bob.disconnect();
    expect(await alice.isConnected, isTrue);
    alice.close();
    bob.close();
  });

  test('Calendar reads primary busy times without event titles or tokens in result', () async {
    FlutterSecureStorage.setMockInitialValues(savedTokens('alice'));
    final client = GoogleCalendarConnection(
      'alice',
      transport: MockClient((request) async {
        expect(request.url.path, '/calendar/v3/freeBusy');
        expect(request.headers['Authorization'], 'Bearer test-access');
        final body = jsonDecode(request.body) as Map;
        expect(body['items'], [
          {'id': 'primary'},
        ]);
        return http.Response(
          jsonEncode({
            'calendars': {
              'primary': {'busy': []},
            },
          }),
          200,
        );
      }),
    );
    final data = await client.availability();
    expect(data.keys.toSet(), {'time_min', 'time_max', 'busy'});
    expect(data.toString(), isNot(contains('test-access')));
    client.close();
  });

  test('Expired Calendar tokens refresh without exposing credentials to Calendar requests', () async {
    FlutterSecureStorage.setMockInitialValues(
      savedTokens('alice', expired: true),
    );
    var refreshed = false;
    final client = GoogleCalendarConnection(
      'alice',
      transport: MockClient((request) async {
        if (request.url.host == 'oauth2.googleapis.com') {
          expect(request.body, contains('grant_type=refresh_token'));
          refreshed = true;
          return http.Response(
            jsonEncode({'access_token': 'new-access', 'expires_in': 3600}),
            200,
          );
        }
        expect(refreshed, isTrue);
        expect(request.headers['Authorization'], 'Bearer new-access');
        expect(request.body, isNot(contains('test-client')));
        return http.Response(
          jsonEncode({
            'calendars': {
              'primary': {'busy': []},
            },
          }),
          200,
        );
      }),
    );
    await client.availability();
    client.close();
  });
}

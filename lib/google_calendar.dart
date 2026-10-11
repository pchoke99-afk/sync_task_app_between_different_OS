import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'session.dart';

/// Desktop OAuth with PKCE. Credentials and tokens never reach the AI server.
class GoogleCalendarConnection {
  GoogleCalendarConnection(this.userId, {http.Client? transport})
    : _transport = transport ?? http.Client();

  final String userId;
  final http.Client _transport;
  static const scope = 'https://www.googleapis.com/auth/calendar.freebusy';
  static const _browser = MethodChannel('sync_task/assistant_media');
  String get _tokenKey => 'google_calendar_tokens_$userId';

  Future<bool> get isConnected async =>
      userId.isNotEmpty && await secureAuth.read(key: _tokenKey) != null;

  Future<Map<String, String>?> get configuration async {
    final saved = await secureAuth.read(key: 'google_calendar_desktop_client');
    if (saved == null) return null;
    return Map<String, String>.from(jsonDecode(saved) as Map);
  }

  Future<void> configure(String clientId, String clientSecret) async {
    if (!clientId.endsWith('.apps.googleusercontent.com') ||
        clientSecret.isEmpty) {
      throw StateError(
        'Enter the client ID and client secret from a Desktop app OAuth client.',
      );
    }
    await secureAuth.write(
      key: 'google_calendar_desktop_client',
      value: jsonEncode({
        'client_id': clientId.trim(),
        'client_secret': clientSecret.trim(),
      }),
    );
  }

  String _randomToken() => base64Url
      .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');

  Future<void> connect() async {
    if (userId.isEmpty) throw StateError('Sign in to your task account first.');
    final config = await configuration;
    if (config == null) {
      throw StateError('Set up your Google OAuth client first.');
    }
    final verifier = _randomToken();
    final state = _randomToken();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}/';
    final code = Completer<String>();
    final subscription = server.listen((request) async {
      final params = request.uri.queryParameters;
      if (request.uri.path != '/' || params['state'] != state) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('Invalid authorization response.');
      } else {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<html><body>You can return to Sync Task App.</body></html>',
        );
        if (!code.isCompleted) {
          if (params['code']?.isNotEmpty == true) {
            code.complete(params['code']);
          } else {
            code.completeError(
              StateError('Google Calendar access was not granted.'),
            );
          }
        }
      }
      await request.response.close();
    });
    try {
      final uri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': config['client_id']!,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': scope,
        'state': state,
        'code_challenge': base64Url
            .encode(sha256.convert(utf8.encode(verifier)).bytes)
            .replaceAll('=', ''),
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'consent select_account',
      });
      await _browser.invokeMethod<void>('openGoogleUrl', uri.toString());
      final authorizationCode = await code.future.timeout(
        const Duration(minutes: 3),
      );
      final tokens = await _tokenRequest({
        ...config,
        'code': authorizationCode,
        'code_verifier': verifier,
        'redirect_uri': redirect,
        'grant_type': 'authorization_code',
      });
      if (!(tokens['scope'] as String? ?? '').split(' ').contains(scope)) {
        throw StateError('Google did not grant calendar availability access.');
      }
      await _saveTokens(tokens);
    } on TimeoutException {
      throw StateError('Google sign-in timed out. Please reconnect Calendar.');
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _tokenRequest(Map<String, String> body) async {
    final response = await _transport
        .post(Uri.https('oauth2.googleapis.com', '/token'), body: body)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError(
        'Google authorization failed. Check your Desktop OAuth credentials or reconnect Calendar.',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> _saveTokens(Map<String, dynamic> tokens) async {
    if (tokens['access_token'] is! String || tokens['expires_in'] is! num) {
      throw StateError('Google returned an invalid authorization response.');
    }
    tokens['expires_at'] =
        DateTime.now().millisecondsSinceEpoch +
        ((tokens['expires_in'] as num).toInt() - 60) * 1000;
    await secureAuth.write(key: _tokenKey, value: jsonEncode(tokens));
  }

  Future<String> _accessToken() async {
    final saved = await secureAuth.read(key: _tokenKey);
    if (saved == null) throw StateError('Connect Google Calendar first.');
    final tokens = jsonDecode(saved) as Map<String, dynamic>;
    if ((tokens['expires_at'] as int) > DateTime.now().millisecondsSinceEpoch) {
      return tokens['access_token'] as String;
    }
    final config = await configuration;
    final refresh = tokens['refresh_token'] as String?;
    if (config == null || refresh == null) {
      throw StateError('Reconnect Google Calendar to refresh access.');
    }
    final updated = await _tokenRequest({
      ...config,
      'refresh_token': refresh,
      'grant_type': 'refresh_token',
    });
    updated['refresh_token'] = refresh;
    await _saveTokens(updated);
    return updated['access_token'] as String;
  }

  /// Only busy intervals from the primary calendar are shared, never event titles.
  Future<Map<String, dynamic>> availability() async {
    final start = DateTime.now().toUtc();
    final end = start.add(const Duration(days: 14));
    final response = await _transport
        .post(
          Uri.https('www.googleapis.com', '/calendar/v3/freeBusy'),
          headers: {
            'Authorization': 'Bearer ${await _accessToken()}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'timeMin': start.toIso8601String(),
            'timeMax': end.toIso8601String(),
            'items': [
              {'id': 'primary'},
            ],
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError(
        'Calendar availability could not be read. Reconnect Calendar or disconnect it to continue without it.',
      );
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final primary = (data['calendars'] as Map)['primary'] as Map;
    if ((primary['errors'] as List? ?? []).isNotEmpty) {
      throw StateError('Google could not read your primary calendar.');
    }
    return {
      'time_min': start.toIso8601String(),
      'time_max': end.toIso8601String(),
      'busy': primary['busy'],
    };
  }

  Future<void> disconnect() => secureAuth.delete(key: _tokenKey);
  void close() => _transport.close();
}

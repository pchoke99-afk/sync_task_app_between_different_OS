import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

const secureAuth = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);

Future<AuthStore> createAuthStore() async {
  final prefs = await SharedPreferences.getInstance();
  var saved = await secureAuth.read(key: 'pb_auth');
  final legacy = prefs.getString('pb_auth');
  if (saved == null && legacy != null) {
    await secureAuth.write(key: 'pb_auth', value: legacy);
    saved = await secureAuth.read(key: 'pb_auth');
    if (saved != legacy) {
      throw StateError('Unable to securely migrate session.');
    }
  }
  if (saved != null) await prefs.remove('pb_auth');
  return AsyncAuthStore(
    initial: saved,
    save: (data) => secureAuth.write(key: 'pb_auth', value: data),
    clear: () => secureAuth.delete(key: 'pb_auth'),
  );
}

Future<void> refreshSession(PocketBase client) async {
  if (client.authStore.record == null) return;
  try {
    await client
        .collection('users')
        .authRefresh()
        .timeout(const Duration(seconds: 10));
  } on ClientException catch (error) {
    // authRefresh rejects invalid/revoked/expired tokens; transport failures retain offline access.
    if ([400, 401, 403].contains(error.statusCode)) client.authStore.clear();
  } on TimeoutException {
    // Keep the local session during a network outage.
  }
}

class SessionGate extends StatefulWidget {
  const SessionGate({
    super.key,
    required this.client,
    required this.signedIn,
    required this.signedOut,
  });
  final PocketBase client;
  final Widget signedIn;
  final Widget signedOut;
  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> with WidgetsBindingObserver {
  StreamSubscription<AuthStoreEvent>? _subscription;
  Timer? _timer;
  bool _refreshing = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = widget.client.authStore.onChange.listen((_) {
      if (mounted) setState(() {});
    });
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _refresh());
    _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await refreshSession(widget.client);
    } finally {
      _refreshing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _subscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.client.authStore.record?.id;
    // Rebuild the nested navigator on logout so assistant routes cannot survive sign-out.
    return Navigator(
      key: ValueKey(user),
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => user == null ? widget.signedOut : widget.signedIn,
      ),
    );
  }
}

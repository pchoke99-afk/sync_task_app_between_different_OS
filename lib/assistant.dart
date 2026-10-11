import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

const sahurMascotAsset = 'assets/assistant/tung_tung_sahur.png';

const assistantUrl = String.fromEnvironment('AI_BACKEND_URL');
String operationLabel(dynamic name) =>
    const {
      'create_task': 'Create',
      'update_task': 'Update',
      'complete_task': 'Complete',
      'delete_task': 'Delete',
    }[name] ??
    'Task change';
String fieldLabel(dynamic name) =>
    const {
      'title': 'Title',
      'description': 'Description',
      'priority': 'Priority',
      'due_at': 'Due date',
      'estimated_minutes': 'Estimated minutes',
      'category': 'Category',
      'scheduled_at': 'Scheduled start',
    }[name] ??
    'Details';
String proposalStatus(dynamic status) =>
    const {
      'pending': 'Awaiting confirmation',
      'applied': 'Applied',
      'cancelled': 'Cancelled',
      'executing': 'Applying changes',
      'partial_or_failed': 'Review required',
    }[status] ??
    'Review required';

class AssistantClient {
  AssistantClient(this.pb, {http.Client? transport, String? endpoint})
    : transport = transport ?? http.Client(),
      endpoint = endpoint ?? assistantUrl;
  final PocketBase pb;
  final http.Client transport;
  final String endpoint;

  Future<Map<String, dynamic>> request(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (endpoint.isEmpty) {
      throw StateError('AI is not configured. Your tasks still work offline.');
    }
    final base = Uri.parse(endpoint);
    if (base.scheme != 'https' &&
        !(base.scheme == 'http' &&
            ['localhost', '127.0.0.1'].contains(base.host))) {
      throw StateError('The assistant requires a secure HTTPS server address.');
    }
    final user = pb.authStore.record?.id;
    final token = pb.authStore.token;
    if (user == null || !pb.authStore.isValid) {
      throw StateError('Sign in online again to use the AI assistant.');
    }
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    final uri = Uri.parse('${endpoint.replaceFirst(RegExp(r'/$'), '')}$path');
    final response =
        await (body == null
                ? transport.get(uri, headers: headers)
                : transport.post(uri, headers: headers, body: jsonEncode(body)))
            .timeout(const Duration(seconds: 100));
    if (pb.authStore.record?.id != user) {
      throw StateError('Session changed. Please reopen the assistant.');
    }
    if (response.statusCode == 401) {
      pb.authStore.clear();
      throw StateError('Your session expired. Please sign in again.');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw StateError(
        data['error']?.toString() ?? 'AI unavailable. Please try again.',
      );
    }
    return data;
  }

  void close() => transport.close();
}

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, required this.client});
  final AssistantClient client;
  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _input = TextEditingController();
  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _proposals = [];
  List<Map<String, dynamic>> _conversations = [];
  String? _conversation;
  String? _error;
  bool _busy = false;
  bool _hasOlder = false;
  @override
  void initState() {
    super.initState();
    _run(_list);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is StateError ? error.message.toString() : 'Cloud AI is unavailable. Check Tailscale and your internet connection. Cached tasks remain available.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _list() async {
    final data = await widget.client.request('/conversations');
    if (mounted) {
      setState(
        () => _conversations = List<Map<String, dynamic>>.from(
          data['conversations'],
        ),
      );
    }
  }

  Future<void> _open(String id) async {
    final data = await widget.client.request('/conversations/$id');
    if (!mounted) return;
    setState(() {
      _conversation = id;
      _hasOlder = data['has_more'] == true;
      _messages = List<Map<String, dynamic>>.from(data['messages']);
      _proposals = List<Map<String, dynamic>>.from(data['proposals']);
    });
  }

  Future<void> _older() async {
    if (_conversation == null || _messages.isEmpty) return;
    final before = _messages.first['id'];
    final data = await widget.client.request(
      '/conversations/$_conversation?before_message=$before',
    );
    if (!mounted) return;
    setState(() {
      _messages = [
        ...List<Map<String, dynamic>>.from(data['messages']),
        ..._messages,
      ];
      _hasOlder = data['has_more'] == true;
    });
  }

  Future<void> _send() async {
    final message = _input.text.trim();
    if (message.isEmpty) return;
    final now = DateTime.now();
    final data = await widget.client.request(
      '/chat',
      body: {
        'message': message,
        'conversation_id': _conversation,
        'local_time': now.toIso8601String() + _offset(now.timeZoneOffset),
        'time_zone': now.timeZoneName,
      },
    );
    if (!mounted) return;
    _input.clear();
    await _open(data['conversation_id'] as String);
    await _list();
  }

  String _offset(Duration value) {
    final minutes = value.inMinutes.abs();
    return '${value.isNegative ? '-' : '+'}${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _decide(Map<String, dynamic> proposal, bool confirm) async {
    if (confirm) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Apply these task changes?'),
          content: Text(
            (proposal['operations'] as List)
                .map(
                  (op) =>
                      '${operationLabel(op['name'])}: ${op['preview_title']}',
                )
                .join('\n'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm changes'),
            ),
          ],
        ),
      );
      if (approved != true) return;
    }
    await _run(() async {
      final result = await widget.client.request(
        '/proposals/${proposal['id']}/decision',
        body: {'confirm': confirm},
      );
      if (!mounted) return;
      await _open(_conversation!);
      if (result['status'] == 'partial_or_failed' && mounted) {
        setState(
          () => _error = 'Some changes could not be applied. Review the results and current tasks before requesting a new proposal.',
        );
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    widget.client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFD99746),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF17110E),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF211812)),
      cardTheme: const CardThemeData(color: Color(0xFF2B211A), elevation: 0),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF2B211A),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
      ),
    );
    return Theme(
      data: theme,
      child: Builder(builder: (context) => _buildChat(context)),
    );
  }

  Widget _buildChat(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Row(
        children: [
          _SahurAvatar(size: 40),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tung Tung Sahur',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                Text(
                  'Your task assistant',
                  style: TextStyle(fontSize: 12, color: Color(0xFFCEBBA5)),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'New conversation',
          onPressed: _busy
              ? null
              : () => setState(() {
                  _conversation = null;
                  _messages = [];
                  _proposals = [];
                  _hasOlder = false;
                }),
          icon: const Icon(Icons.add_comment_outlined),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(_conversation),
                      initialValue:
                          _conversations.any((c) => c['id'] == _conversation)
                          ? _conversation
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Conversations',
                        border: OutlineInputBorder(),
                      ),
                      items: _conversations
                          .map(
                            (c) => DropdownMenuItem(
                              value: c['id'] as String,
                              child: Text(
                                c['title'] as String,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (id) {
                              if (id != null) _run(() => _open(id));
                            },
                      isExpanded: true,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh history',
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await _list();
                            if (_conversation != null) {
                              await _open(_conversation!);
                            }
                          }),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_busy) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_messages.isEmpty)
                    Column(
                      children: [
                        const SizedBox(height: 8),
                        Image.asset(
                          sahurMascotAsset,
                          height: 190,
                          cacheWidth: 384,
                          semanticLabel: 'Tung Tung Sahur, a smiling wooden character holding a bat',
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Tung tung! Let’s get things done.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFFE5AE6D),
                              ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: 14,
                            horizontal: 12,
                          ),
                          child: Text(
                            'Ask what to work on today, plan a study schedule, or propose new tasks. You review and confirm every task change. Cloud AI needs an online connection.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Color(0xFFCEBBA5)),
                          ),
                        ),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final suggestion in [
                              'What should I work on today?',
                              'Help me plan my study time',
                              'Organize my tasks',
                            ])
                              ActionChip(
                                label: Text(suggestion),
                                avatar: const Icon(
                                  Icons.auto_awesome,
                                  size: 16,
                                ),
                                onPressed: _busy
                                    ? null
                                    : () => _input.text = suggestion,
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  if (_hasOlder)
                    TextButton(
                      onPressed: _busy ? null : () => _run(_older),
                      child: const Text('Load earlier messages'),
                    ),
                  ..._messages.map(
                    (m) => Align(
                      alignment: m['role'] == 'user'
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 660),
                        child: Card(
                          color: m['role'] == 'user'
                              ? const Color(0xFF483322)
                              : const Color(0xFF2B211A),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (m['role'] != 'user') ...[
                                      const _SahurAvatar(size: 30),
                                      const SizedBox(width: 8),
                                    ],
                                    Text(
                                      m['role'] == 'user'
                                          ? 'You'
                                          : 'Tung Tung Sahur',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFFE5AE6D),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                SelectableText(m['content'] as String),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  ..._proposals.map(
                    (p) => Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Task changes • ${proposalStatus(p['status'])}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            ...(p['operations'] as List).map(
                              (op) => Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${operationLabel(op['name'])}: ${op['preview_title']}',
                                    ),
                                    if (op['arguments']['fields'] != null)
                                      ...(op['arguments']['fields'] as Map)
                                          .entries
                                          .map(
                                            (e) => Text(
                                              '${fieldLabel(e.key)}: ${e.value.toString().isEmpty ? 'None' : e.value}',
                                            ),
                                          ),
                                  ],
                                ),
                              ),
                            ),
                            if (p['status'] == 'pending')
                              Wrap(
                                spacing: 12,
                                children: [
                                  FilledButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _decide(p, true),
                                    child: const Text('Review and apply'),
                                  ),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _decide(p, false),
                                    child: const Text('Cancel proposal'),
                                  ),
                                ],
                              ),
                            if (p['result'] != null)
                              ...((p['result'] as Map)['results'] as List? ??
                                      [])
                                  .map(
                                    (result) => Text(
                                      result['ok'] == true
                                          ? '${operationLabel(result['name'])}: done'
                                          : result['error']?.toString() ?? 'This change could not be applied.',
                                    ),
                                  ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 5,
                        maxLength: 4000,
                        decoration: const InputDecoration(
                          hintText: 'Ask Tung Tung Sahur…',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _run(_send),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: 'Send message',
                      onPressed: _busy ? null : () => _run(_send),
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SahurAvatar extends StatelessWidget {
  const _SahurAvatar({required this.size});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: const Color(0xFF4C3522),
      border: Border.all(color: const Color(0xFFA9723B)),
    ),
    child: ClipOval(
      child: Image.asset(
        sahurMascotAsset,
        fit: BoxFit.cover,
        alignment: const Alignment(0, -0.75),
        cacheWidth: 128,
        semanticLabel: 'Tung Tung Sahur',
      ),
    ),
  );
}

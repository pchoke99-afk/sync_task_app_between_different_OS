import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import 'assistant_media.dart';
import 'google_calendar.dart';

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
            .timeout(const Duration(seconds: 500));
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
  late final GoogleCalendarConnection _calendar;
  bool _calendarConnected = false;

  Future<void> _connectCalendar() async {
    final config = await _calendar.configuration;
    if (!mounted) return;
    final id = TextEditingController(text: config?['client_id']);
    final secret = TextEditingController(text: config?['client_secret']);
    try {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Connect Google Calendar'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Use a Desktop app OAuth client from Google Cloud. This connection reads busy times from your primary calendar; it cannot edit calendar events.',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: id,
                    decoration: const InputDecoration(
                      labelText: 'OAuth client ID',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: secret,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Desktop client secret',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Credentials and Google tokens are stored in your Mac Keychain. Only busy times are shared with your local assistant.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue with Google'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
      await _calendar.configure(id.text.trim(), secret.text.trim());
      await _calendar.connect();
      if (mounted) setState(() => _calendarConnected = true);
    } finally {
      id.dispose();
      secret.dispose();
    }
  }

  Future<void> _calendarSettings() async {
    if (!_calendarConnected) {
      await _connectCalendar();
      return;
    }
    final disconnect = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Google Calendar connected'),
        content: const Text(
          'Sahur uses busy times from your primary calendar for the next 14 days. Event titles and Google tokens are not shared. Disconnect removes this task account’s saved Google tokens from the Mac.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep connected'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (disconnect == true) {
      await _calendar.disconnect();
      if (mounted) setState(() => _calendarConnected = false);
    }
  }

  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _proposals = [];
  List<Map<String, dynamic>> _conversations = [];
  String? _conversation;
  String? _error;
  bool _busy = false;
  bool _hasOlder = false;
  final _media = const AssistantMedia();
  Uint8List? _image;
  String _imageText = '';
  bool _listening = false;
  bool _mediaBusy = false;
  bool get _supportsMedia => _media.isSupported;
  bool get _supportsCalendar =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  Future<void> _pasteImage() async {
    if (_mediaBusy || _busy) return;
    setState(() => _mediaBusy = true);
    try {
      final data = await _media.pasteImage();
      if (!mounted || data == null) return;
      setState(() {
        _image = data.bytes;
        _imageText = data.text;
        _error = _imageText.isEmpty
            ? 'No readable text found. Describe this image in your message; the local model cannot see pictures.'
            : null;
      });
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _mediaBusy = false);
    }
  }

  Future<void> _toggleMicrophone() async {
    if (_listening) {
      await _media.stopDictation();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final draft = _input.text;
    setState(() {
      _listening = true;
      _error = null;
    });
    try {
      final text = await _media.dictate();
      if (mounted && text != null && text.isNotEmpty) {
        _input.text = [draft, text].where((part) => part.isNotEmpty).join(' ');
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _calendar = GoogleCalendarConnection(
      widget.client.pb.authStore.record?.id ?? '',
    );
    _run(() async {
      await _list();
      if (_supportsCalendar) {
        final connected = await _calendar.isConnected;
        if (mounted) setState(() => _calendarConnected = connected);
      }
    });
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
          () => _error = error is StateError ? error.message.toString() : 'The assistant is unavailable. Check your server connection and try again.',
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
    final message = [
      _input.text.trim(),
      if (_imageText.isNotEmpty)
        'Text extracted from an attached image (may contain errors):\n$_imageText',
    ].where((part) => part.isNotEmpty).join('\n\n');
    if (message.length > 4000) {
      throw StateError(
        'The message and image text exceed 4,000 characters. Shorten the message or use a smaller screenshot.',
      );
    }
    if (message.isEmpty) return;
    final availability = _calendarConnected
        ? await _calendar.availability()
        : null;
    final now = DateTime.now();
    final data = await widget.client.request(
      '/chat',
      body: {
        'message': message,
        'conversation_id': _conversation,
        'local_time': now.toIso8601String() + _offset(now.timeZoneOffset),
        'time_zone': now.timeZoneName,
        'calendar_availability': ?availability,
      },
    );
    if (!mounted) return;
    _input.clear();
    setState(() {
      _image = null;
      _imageText = '';
    });
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
    if (_listening) _media.stopDictation();
    _input.dispose();
    _calendar.close();
    widget.client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _buildChat(context);
  }

  Widget _buildChat(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.surface,
    appBar: AppBar(
      backgroundColor: Theme.of(context).colorScheme.surface,
      leading: IconButton(
        tooltip: 'Close chat',
        icon: const Icon(Icons.close),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
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
                  style: TextStyle(fontSize: 12, color: Color(0xFF625D6B)),
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
            if (_supportsCalendar)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: TextButton.icon(
                    icon: Icon(
                      _calendarConnected
                          ? Icons.event_available
                          : Icons.calendar_month,
                      size: 18,
                    ),
                    label: Text(
                      _calendarConnected
                          ? 'Calendar connected'
                          : 'Connect Google Calendar',
                    ),
                    onPressed: _busy ? null : () => _run(_calendarSettings),
                  ),
                ),
              ),
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
            if (_busy) ...[
              const LinearProgressIndicator(),
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'Working on your request… local AI can take a few minutes.',
                ),
              ),
            ],
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
                          height: 100,
                          cacheWidth: 384,
                          semanticLabel: 'Tung Tung Sahur, a smiling wooden character holding a bat',
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'What can I help you with?',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: 14,
                            horizontal: 12,
                          ),
                          child: Text(
                            'Create tasks, update your plans, or choose what to work on next. You approve changes before they are saved.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Color(0xFF625D6B)),
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
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerLow,
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
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
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
            if (_image != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        _image!,
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _imageText.isEmpty
                            ? 'Image attached · add a description'
                            : 'Image attached · text extracted',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove image',
                      onPressed: () => setState(() {
                        _image = null;
                        _imageText = '';
                      }),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            if (_imageText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ExpansionTile(
                  title: const Text('Review extracted text'),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    SizedBox(
                      height: 100,
                      child: SingleChildScrollView(
                        child: SelectableText(_imageText),
                      ),
                    ),
                  ],
                ),
              ),
            if (_listening)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Listening… tap the microphone to finish.'),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (_supportsMedia) ...[
                      IconButton(
                        tooltip: 'Paste image',
                        onPressed: _busy || _mediaBusy ? null : _pasteImage,
                        icon: const Icon(Icons.content_paste),
                      ),
                      IconButton(
                        tooltip: _listening
                            ? 'Finish recording'
                            : 'Dictate message',
                        onPressed: _busy ? null : _toggleMicrophone,
                        icon: Icon(
                          _listening ? Icons.stop_circle : Icons.mic_none,
                        ),
                        color: _listening
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ],
                    Expanded(
                      child: CallbackShortcuts(
                        bindings: {
                          if (_supportsMedia)
                            const SingleActivator(
                              LogicalKeyboardKey.keyV,
                              meta: true,
                            ): () async {
                              final hasImage = await _media.hasClipboardImage();
                              if (hasImage) {
                                await _pasteImage();
                              } else {
                                final text = await Clipboard.getData(
                                  Clipboard.kTextPlain,
                                );
                                if (mounted && text?.text != null) {
                                  final selection = _input.selection;
                                  final start = selection.isValid
                                      ? selection.start
                                      : _input.text.length;
                                  final end = selection.isValid
                                      ? selection.end
                                      : start;
                                  _input.value = TextEditingValue(
                                    text: _input.text.replaceRange(
                                      start,
                                      end,
                                      text!.text!,
                                    ),
                                    selection: TextSelection.collapsed(
                                      offset: start + text.text!.length,
                                    ),
                                  );
                                }
                              }
                            },
                        },
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 5,
                          maxLength: 4000,
                          decoration: const InputDecoration(
                            hintText: 'Ask Tung Tung Sahur…',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) {
                            if (!_listening && !_mediaBusy) _run(_send);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: 'Send message',
                      onPressed: _busy || _listening || _mediaBusy
                          ? null
                          : () => _run(_send),
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
      color: Theme.of(context).colorScheme.primaryContainer,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
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

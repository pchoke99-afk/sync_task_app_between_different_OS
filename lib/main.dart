import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:pocketbase/pocketbase.dart';

import 'dart:async';
import 'dart:math';

import 'assistant.dart';
import 'session.dart';

const pocketBaseUrl = String.fromEnvironment(
  'POCKETBASE_URL',
  defaultValue: 'http://100.117.123.116:8090',
);
const tasksCollection = 'tasks';
const usersCollection = 'users';
const tasksCacheBoxName = 'tasks_cache';
const pendingChangesBoxName = 'pending_changes';

late final PocketBase pb;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();
  await Hive.openBox(tasksCacheBoxName);
  await Hive.openBox(pendingChangesBoxName);

  AuthStore authStore;
  try {
    authStore = await createAuthStore();
  } catch (_) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Secure sign-in storage could not be opened. Unlock your device and try again. Your task data has been preserved.',
                  ),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: main, child: const Text('Try again')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return;
  }

  pb = PocketBase(pocketBaseUrl, authStore: authStore);
  runApp(const SyncTaskApp());
}

class SyncTaskApp extends StatelessWidget {
  const SyncTaskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sync Task App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: SessionGate(
        client: pb,
        signedIn: const TaskScreen(),
        signedOut: const LoginScreen(),
      ),
    );
  }
}

enum TaskPriority {
  high,
  normal,
  low;

  String get label {
    switch (this) {
      case TaskPriority.high:
        return 'High priority';
      case TaskPriority.normal:
        return 'Normal priority';
      case TaskPriority.low:
        return 'Low priority';
    }
  }

  int get sortOrder {
    switch (this) {
      case TaskPriority.high:
        return 0;
      case TaskPriority.normal:
        return 1;
      case TaskPriority.low:
        return 2;
    }
  }

  static TaskPriority fromString(String value) {
    return TaskPriority.values.firstWhere(
      (priority) => priority.name == value,
      orElse: () => TaskPriority.normal,
    );
  }
}

class AppTask {
  const AppTask({
    required this.id,
    required this.title,
    required this.description,
    required this.priority,
    required this.isCompleted,
    required this.completedAt,
    required this.createdAt,
    this.dueAt = '',
    this.estimatedMinutes = 0,
    this.category = '',
    this.scheduledAt = '',
  });

  final String id;
  final String title;
  final String description;
  final TaskPriority priority;
  final bool isCompleted;
  final String completedAt;
  final String createdAt;
  final String dueAt;
  final int estimatedMinutes;
  final String category;
  final String scheduledAt;

  bool get isLocal => id.startsWith('local_');

  AppTask copyWith({
    String? id,
    String? title,
    String? description,
    TaskPriority? priority,
    bool? isCompleted,
    String? completedAt,
    String? createdAt,
    String? dueAt,
    int? estimatedMinutes,
    String? category,
    String? scheduledAt,
  }) {
    return AppTask(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      priority: priority ?? this.priority,
      isCompleted: isCompleted ?? this.isCompleted,
      completedAt: completedAt ?? this.completedAt,
      createdAt: createdAt ?? this.createdAt,
      dueAt: dueAt ?? this.dueAt,
      estimatedMinutes: estimatedMinutes ?? this.estimatedMinutes,
      category: category ?? this.category,
      scheduledAt: scheduledAt ?? this.scheduledAt,
    );
  }

  factory AppTask.fromRecord(RecordModel record) {
    return AppTask(
      id: record.id,
      title: record.getStringValue('title'),
      description: record.getStringValue('description'),
      priority: TaskPriority.fromString(record.getStringValue('priority')),
      isCompleted: record.getBoolValue('is_completed'),
      completedAt: record.getStringValue('completed_at'),
      createdAt: record.getStringValue('created'),
      dueAt: record.getStringValue('due_at'),
      estimatedMinutes: record.getIntValue('estimated_minutes'),
      category: record.getStringValue('category'),
      scheduledAt: record.getStringValue('scheduled_at'),
    );
  }

  factory AppTask.fromMap(Map<String, dynamic> map) {
    return AppTask(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      priority: TaskPriority.fromString(
        map['priority']?.toString() ?? 'normal',
      ),
      isCompleted: map['is_completed'] == true,
      completedAt: map['completed_at']?.toString() ?? '',
      createdAt: map['created_at']?.toString() ?? '',
      dueAt: map['due_at']?.toString() ?? '',
      estimatedMinutes: (map['estimated_minutes'] as num?)?.toInt() ?? 0,
      category: map['category']?.toString() ?? '',
      scheduledAt: map['scheduled_at']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'priority': priority.name,
      'is_completed': isCompleted,
      'completed_at': completedAt,
      'created_at': createdAt,
      ...schedulingBody(),
    };
  }

  Map<String, dynamic> schedulingBody() => {
    'due_at': dueAt,
    'estimated_minutes': estimatedMinutes,
    'category': category,
    'scheduled_at': scheduledAt,
  };

  Map<String, dynamic> toServerBody(String userId) {
    return {
      'title': title,
      'description': description,
      'priority': priority.name,
      'is_completed': isCompleted,
      'completed_at': completedAt,
      'user': userId,
      if (const bool.fromEnvironment('TASK_SCHEDULING_ENABLED'))
        ...schedulingBody(),
    };
  }
}

class TaskRepository {
  TaskRepository() : userId = pb.authStore.record?.id;
  final String? userId;
  final Box _cacheBox = Hive.box(tasksCacheBoxName);
  final Box _pendingBox = Hive.box(pendingChangesBoxName);
  Future<void> _queue = Future<void>.value();
  String get _cacheKey => 'tasks:$userId';
  String _key(String id) => '$userId:$id';

  void _checkSession() {
    if (userId == null || pb.authStore.record?.id != userId) {
      throw StateError('Session changed.');
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) {
      _checkSession();
      return action();
    });
    _queue = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<T> _network<T>(Future<T> Function() action) async {
    _checkSession();
    try {
      final result = await action().timeout(const Duration(seconds: 12));
      _checkSession();
      return result;
    } on ClientException catch (error) {
      if (error.statusCode == 401) pb.authStore.clear();
      rethrow;
    }
  }

  List<AppTask> _loadCache() {
    final raw = _cacheBox.get(_cacheKey);
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((m) => AppTask.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<void> _saveCache(List<AppTask> tasks) =>
      _cacheBox.put(_cacheKey, tasks.map((t) => t.toMap()).toList());

  Future<void> _upsert(AppTask task) async {
    final tasks = _loadCache();
    final index = tasks.indexWhere((t) => t.id == task.id);
    if (index < 0) {
      tasks.add(task);
    } else {
      tasks[index] = task;
    }
    await _saveCache(tasks);
  }

  Iterable<MapEntry<dynamic, Map<String, dynamic>>> _changes() sync* {
    for (final key in List<dynamic>.from(_pendingBox.keys)) {
      final raw = _pendingBox.get(key);
      if (raw is Map && raw['owner'] == userId) {
        yield MapEntry(key, Map<String, dynamic>.from(raw));
      }
    }
  }

  Future<void> _recoverLegacy(List<RecordModel> records) async {
    final owned = {for (final record in records) record.id: record};
    final cached = _cacheBox.get('tasks');
    final legacyCache = cached is List
        ? cached
              .whereType<Map>()
              .map((m) => AppTask.fromMap(Map<String, dynamic>.from(m)))
              .toList()
        : <AppTask>[];
    // Only online-verified server records and explicitly user-tagged creates are migrated.
    // The old shared boxes remain intact as a recovery backup.
    for (final key in List<dynamic>.from(_pendingBox.keys)) {
      final raw = _pendingBox.get(key);
      if (raw is! Map || raw.containsKey('owner')) continue;
      final marker = 'legacy:$userId:$key';
      if (_pendingBox.get(marker) == true) continue;
      final change = Map<String, dynamic>.from(raw);
      final oldId = (change['temp_id'] ?? change['task_id'] ?? key).toString();
      AppTask? task;
      if (change['type'] == 'create' && change['user'] == userId) {
        final chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
        final random = Random.secure();
        final idKey = 'legacy-id:$userId:$key';
        final id =
            _pendingBox.get(idKey) as String? ??
            List.generate(
              15,
              (_) => chars[random.nextInt(chars.length)],
            ).join();
        await _pendingBox.put(idKey, id);
        task = AppTask.fromMap({
          ...change,
          'id': id,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
      } else if (['update', 'delete'].contains(change['type']) &&
          owned.containsKey(oldId)) {
        final record = owned[oldId]!;
        task = AppTask.fromMap({
          ...AppTask.fromRecord(record).toMap(),
          ...change,
          'id': oldId,
        });
      }
      if (task == null) continue;
      // Do not replace edits already made with this version of the app.
      if (!_pendingBox.containsKey(_key(task.id))) {
        await _pendingBox.put(_key(task.id), {
          'owner': userId,
          'type': change['type'],
          'task': task.toMap(),
        });
        if (change['type'] != 'delete') await _upsert(task);
      }
      await _pendingBox.put(marker, true);
    }
    for (final task in legacyCache) {
      if (owned.containsKey(task.id) &&
          !_pendingBox.containsKey(_key(task.id))) {
        await _upsert(task);
      }
    }
  }

  Future<List<AppTask>> loadTasks() => _serial(() async {
    try {
      final records = await _network(
        () => pb
            .collection(tasksCollection)
            .getFullList(
              filter: pb.filter('user = {:user}', {'user': userId}),
              sort: '-created',
            ),
      );
      await _recoverLegacy(records);
      final merged = {for (final r in records) r.id: AppTask.fromRecord(r)};
      for (final entry in _changes()) {
        final change = entry.value;
        final task = AppTask.fromMap(
          Map<String, dynamic>.from(change['task'] as Map),
        );
        if (change['type'] == 'delete') {
          merged.remove(task.id);
        } else {
          merged[task.id] = task;
        }
      }
      final tasks = merged.values.toList();
      await _saveCache(tasks);
      return tasks;
    } catch (_) {
      _checkSession();
      return _loadCache();
    }
  });

  Future<AppTask> createTask({
    required String title,
    required String description,
    required TaskPriority priority,
    String dueAt = '',
    int estimatedMinutes = 0,
    String category = '',
    String scheduledAt = '',
  }) => _serial(() async {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    final recordId = List.generate(
      15,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
    final task = AppTask(
      id: recordId,
      title: title,
      description: description,
      priority: priority,
      isCompleted: false,
      completedAt: '',
      createdAt: DateTime.now().toUtc().toIso8601String(),
      dueAt: dueAt,
      estimatedMinutes: estimatedMinutes,
      category: category,
      scheduledAt: scheduledAt,
    );
    await _upsert(task);
    await _pendingBox.put(_key(task.id), {
      'owner': userId,
      'type': 'create',
      'task': task.toMap(),
    });
    await _sync();
    return _loadCache().firstWhere((t) => t.id == task.id, orElse: () => task);
  });

  Future<void> updateTask(AppTask task) => _serial(() async {
    await _upsert(task);
    final existing = _pendingBox.get(_key(task.id));
    await _pendingBox.put(_key(task.id), {
      'owner': userId,
      'type': existing is Map && existing['type'] == 'create'
          ? 'create'
          : 'update',
      'task': task.toMap(),
    });
    await _sync();
  });

  Future<void> deleteTask(AppTask task) => _serial(() async {
    await _saveCache(_loadCache()..removeWhere((t) => t.id == task.id));
    // A lost create response may have left a server record. Always reconcile a deletion.
    await _pendingBox.put(_key(task.id), {
      'owner': userId,
      'type': 'delete',
      'task': task.toMap(),
    });
    await _sync();
  });

  Future<void> syncPendingChanges() => _serial(_sync);

  Future<void> _sync() async {
    for (final entry in _changes().toList()) {
      final task = AppTask.fromMap(
        Map<String, dynamic>.from(entry.value['task'] as Map),
      );
      try {
        RecordModel? remote;
        try {
          remote = await _network(
            () => pb.collection(tasksCollection).getOne(task.id),
          );
        } on ClientException catch (error) {
          if (error.statusCode != 404) rethrow;
        }
        if (remote != null && remote.getStringValue('user') != userId) {
          throw StateError('Task ownership mismatch.');
        }
        switch (entry.value['type']) {
          case 'create':
            if (remote == null) {
              remote = await _network(
                () => pb
                    .collection(tasksCollection)
                    .create(
                      body: {'id': task.id, ...task.toServerBody(userId!)},
                    ),
              );
            } else {
              // Stable record IDs make a retry after a lost response idempotent.
              remote = await _network(
                () => pb
                    .collection(tasksCollection)
                    .update(task.id, body: task.toServerBody(userId!)),
              );
            }
            await _upsert(AppTask.fromRecord(remote!));
            break;
          case 'update':
            if (remote == null) {
              throw StateError(
                'Task was deleted on another device; pending edit retained.',
              );
            }
            await _network(
              () => pb
                  .collection(tasksCollection)
                  .update(task.id, body: task.toServerBody(userId!)),
            );
            break;
          case 'delete':
            if (remote != null) {
              await _network(
                () => pb.collection(tasksCollection).delete(task.id),
              );
            }
            break;
          default:
            throw StateError('Unknown pending change.');
        }
        await _pendingBox.delete(entry.key);
      } catch (error) {
        // Retain rejected and offline changes. Never silently discard unsynchronized data.
        _checkSession();
        if (error is TimeoutException ||
            (error is ClientException &&
                (error.statusCode == 0 || error.statusCode >= 500))) {
          break;
        }
      }
    }
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isLoading = false;
  String _message = '';

  Future<void> _login() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _message = '';
    });

    try {
      await pb
          .collection(usersCollection)
          .authWithPassword(
            _emailController.text.trim(),
            _passwordController.text,
          );

      if (!mounted) return;
    } catch (error) {
      debugPrint('Login error: $error');
      if (!mounted) return;

      setState(() {
        _message = 'Login failed. Check your email and password.';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sync Task App')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Log in',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  onSubmitted: (_) => _login(),
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _login,
                    child: _isLoading
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Log in'),
                  ),
                ),
                if (_message.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(_message),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TaskScreen extends StatefulWidget {
  const TaskScreen({super.key});

  @override
  State<TaskScreen> createState() => _TaskScreenState();
}

class _TaskScreenState extends State<TaskScreen> with WidgetsBindingObserver {
  final _repository = TaskRepository();

  late final ConfettiController _confettiController;

  List<AppTask> _tasks = [];
  bool _isLoading = true;
  bool _showCelebrationGif = false;
  int _celebrationGeneration = 0;
  Timer? _syncTimer;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _confettiController = ConfettiController(
      duration: const Duration(milliseconds: 1800),
    );
    WidgetsBinding.instance.addObserver(this);
    _syncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _initialize(),
    );
    _initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _initialize();
  }

  Future<void> _initialize() async {
    if (_syncing) return;
    _syncing = true;
    try {
      await _repository.syncPendingChanges();
      await _reloadTasks();
      if (mounted) {
        try {
          await pb
              .collection(tasksCollection)
              .subscribe('*', (_) => _reloadTasks());
        } catch (_) {
          /* Timer and resume retry while offline. */
        }
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _reloadTasks() async {
    List<AppTask> tasks;
    try {
      tasks = await _repository.loadTasks();
    } catch (_) {
      return;
    }
    if (!mounted) return;

    setState(() {
      _tasks = _sortTasks(tasks);
      _isLoading = false;
    });
  }

  List<AppTask> _sortTasks(Iterable<AppTask> tasks) {
    final sorted = List<AppTask>.from(tasks);

    sorted.sort((a, b) {
      final priorityCompare = a.priority.sortOrder.compareTo(
        b.priority.sortOrder,
      );

      if (priorityCompare != 0) return priorityCompare;

      if (a.isCompleted != b.isCompleted) {
        return a.isCompleted ? 1 : -1;
      }

      return b.createdAt.compareTo(a.createdAt);
    });

    return sorted;
  }

  void _replaceTask(AppTask updated) {
    setState(() {
      final index = _tasks.indexWhere((task) => task.id == updated.id);

      if (index == -1) {
        _tasks.add(updated);
      } else {
        _tasks[index] = updated;
      }

      _tasks = _sortTasks(_tasks);
    });
  }

  Future<void> _showTaskDialog({AppTask? task}) async {
    final titleController = TextEditingController(text: task?.title ?? '');
    final descriptionController = TextEditingController(
      text: task?.description ?? '',
    );

    var selectedPriority = task?.priority ?? TaskPriority.normal;
    final dueController = TextEditingController(text: task?.dueAt ?? '');
    final durationController = TextEditingController(
      text: (task?.estimatedMinutes ?? 0).toString(),
    );
    final categoryController = TextEditingController(
      text: task?.category ?? '',
    );
    String? metadataError;

    final result = await showDialog<_TaskFormResult>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(task == null ? 'Add Task' : 'Edit Task'),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: titleController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Title',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: descriptionController,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<TaskPriority>(
                        initialValue: selectedPriority,
                        decoration: const InputDecoration(
                          labelText: 'Priority',
                          border: OutlineInputBorder(),
                        ),
                        items: TaskPriority.values
                            .map(
                              (priority) => DropdownMenuItem(
                                value: priority,
                                child: Text(priority.label),
                              ),
                            )
                            .toList(),
                        onChanged: (priority) {
                          if (priority == null) return;
                          setDialogState(() => selectedPriority = priority);
                        },
                      ),
                      if (const bool.fromEnvironment(
                        'TASK_SCHEDULING_ENABLED',
                      )) ...[
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.event_outlined),
                                label: Text(
                                  dueController.text.isEmpty
                                      ? 'Choose due date (optional)'
                                      : 'Due: ${DateTime.tryParse(dueController.text)?.toLocal() ?? dueController.text}',
                                ),
                                onPressed: () async {
                                  final now = DateTime.now();
                                  final current =
                                      DateTime.tryParse(dueController.text)
                                          ?.toLocal() ??
                                      now;
                                  final selected = await showDatePicker(
                                    context: context,
                                    initialDate: current,
                                    firstDate: DateTime(2000),
                                    lastDate: DateTime(2100),
                                  );
                                  if (selected == null || !context.mounted) {
                                    return;
                                  }
                                  final time = await showTimePicker(
                                    context: context,
                                    initialTime: TimeOfDay.fromDateTime(
                                      current,
                                    ),
                                  );
                                  if (time == null || !context.mounted) return;
                                  setDialogState(
                                    () => dueController.text = DateTime(
                                      selected.year,
                                      selected.month,
                                      selected.day,
                                      time.hour,
                                      time.minute,
                                    ).toUtc().toIso8601String(),
                                  );
                                },
                              ),
                            ),
                            IconButton(
                              tooltip: 'Clear due date',
                              onPressed: () =>
                                  setDialogState(() => dueController.clear()),
                              icon: const Icon(Icons.clear),
                            ),
                          ],
                        ),
                        TextField(
                          controller: durationController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Estimated minutes (0 if unknown)',
                          ),
                        ),
                        TextField(
                          controller: categoryController,
                          maxLength: 80,
                          decoration: const InputDecoration(
                            labelText: 'Category',
                          ),
                        ),
                        if (metadataError != null) Text(metadataError!),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    FocusScope.of(dialogContext).unfocus();
                    Navigator.of(dialogContext).pop();
                  },
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final title = titleController.text.trim();
                    if (title.isEmpty) return;

                    final due = dueController.text.trim();
                    final minutes = int.tryParse(durationController.text);
                    if (const bool.fromEnvironment('TASK_SCHEDULING_ENABLED')) {
                      final parsed = DateTime.tryParse(due);
                      if ((due.isNotEmpty &&
                              (parsed == null ||
                                  !RegExp(r'(Z|[+-]\d{2}:\d{2})$')
                                      .hasMatch(due))) ||
                          minutes == null ||
                          minutes < 0 ||
                          minutes > 10080) {
                        setDialogState(
                          () => metadataError = 'Choose a due date and enter a duration from 0 to 10080 minutes.',
                        );
                        return;
                      }
                    }
                    final result = _TaskFormResult(
                      title: title,
                      description: descriptionController.text.trim(),
                      priority: selectedPriority,
                      dueAt: due.isEmpty
                          ? ''
                          : DateTime.parse(due).toUtc().toIso8601String(),
                      estimatedMinutes: minutes ?? 0,
                      category: categoryController.text.trim(),
                    );

                    FocusScope.of(dialogContext).unfocus();
                    Navigator.of(dialogContext).pop(result);
                  },
                  child: Text(task == null ? 'Add Task' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );

    await Future<void>.delayed(const Duration(milliseconds: 100));
    titleController.dispose();
    descriptionController.dispose();
    dueController.dispose();
    durationController.dispose();
    categoryController.dispose();

    if (result == null || !mounted) return;

    if (task == null) {
      final created = await _repository.createTask(
        title: result.title,
        description: result.description,
        priority: result.priority,
        dueAt: result.dueAt,
        estimatedMinutes: result.estimatedMinutes,
        category: result.category,
      );

      if (!mounted) return;
      _replaceTask(created);
      return;
    }

    final updated = task.copyWith(
      title: result.title,
      description: result.description,
      priority: result.priority,
      dueAt: result.dueAt,
      estimatedMinutes: result.estimatedMinutes,
      category: result.category,
    );

    _replaceTask(updated);
    await _repository.updateTask(updated);
  }

  Future<void> _toggleTask(AppTask task, bool isCompleted) async {
    final updated = task.copyWith(
      isCompleted: isCompleted,
      completedAt: isCompleted ? DateTime.now().toUtc().toIso8601String() : '',
    );

    // Update the checkbox first so the UI responds instantly.
    _replaceTask(updated);

    // Fire celebration immediately after the task becomes complete.
    if (isCompleted) {
      _startCelebration();
    }

    await _repository.updateTask(updated);
  }

  void _startCelebration() {
    if (!mounted) return;

    // Restarting the controller makes every completion trigger immediately,
    // even when a previous burst is still finishing.
    _confettiController
      ..stop()
      ..play();

    final generation = ++_celebrationGeneration;

    setState(() => _showCelebrationGif = true);

    Future<void>.delayed(const Duration(milliseconds: 1800), () {
      if (!mounted || generation != _celebrationGeneration) return;
      setState(() => _showCelebrationGif = false);
    });
  }

  Future<void> _deleteTaskWithUndo(AppTask task) async {
    final originalIndex = _tasks.indexWhere((item) => item.id == task.id);
    if (originalIndex == -1) return;

    setState(() => _tasks.removeAt(originalIndex));
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    var undone = false;

    final controller = ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Task deleted'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () {
            undone = true;
            if (!mounted) return;

            setState(() {
              _tasks.add(task);
              _tasks = _sortTasks(_tasks);
            });
          },
        ),
      ),
    );

    await controller.closed;

    if (!undone) {
      await _repository.deleteTask(task);
    }
  }

  int get _completedTaskCount =>
      _tasks.where((task) => task.isCompleted).length;

  double get _completionProgress =>
      _tasks.isEmpty ? 0 : _completedTaskCount / _tasks.length;

  @override
  void dispose() {
    _syncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    pb.collection(tasksCollection).unsubscribe('*').catchError((_) {});
    _confettiController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: const Text('My Tasks'),
            actions: [
              IconButton(
                tooltip: 'AI Assistant',
                icon: const Icon(Icons.auto_awesome),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          AssistantScreen(client: AssistantClient(pb)),
                    ),
                  );
                  if (mounted) await _initialize();
                },
              ),
              IconButton(
                tooltip: 'Sync tasks',
                icon: const Icon(Icons.sync),
                onPressed: _initialize,
              ),
              IconButton(
                tooltip: 'Sign out',
                icon: const Icon(Icons.logout),
                onPressed: () => pb.authStore.clear(),
              ),
            ],
          ),
          body: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    _ProgressHeader(
                      completed: _completedTaskCount,
                      total: _tasks.length,
                      progress: _completionProgress,
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: _tasks.isEmpty
                          ? const Center(child: Text('No tasks yet'))
                          : ListView.builder(
                              itemCount: _tasks.length,
                              itemBuilder: (context, index) {
                                final task = _tasks[index];

                                return _TaskTile(
                                  task: task,
                                  onChanged: (value) {
                                    if (value == null) return;
                                    _toggleTask(task, value);
                                  },
                                  onEdit: () => _showTaskDialog(task: task),
                                  onDelete: () => _deleteTaskWithUndo(task),
                                );
                              },
                            ),
                    ),
                  ],
                ),
          floatingActionButton: FloatingActionButton(
            onPressed: _showTaskDialog,
            child: const Icon(Icons.add),
          ),
        ),

        // The confetti widget stays mounted permanently. Only the controller
        // starts/stops it. This removes the delayed first burst.
        Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: ConfettiWidget(
                confettiController: _confettiController,
                blastDirectionality: BlastDirectionality.explosive,
                shouldLoop: false,
                numberOfParticles: 90,
                emissionFrequency: 0.12,
                gravity: 0.16,
                maxBlastForce: 38,
                minBlastForce: 18,
              ),
            ),
          ),
        ),

        if (_showCelebrationGif)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Image.asset(
                  'assets/animations/tungtungscuba.gif',
                  width: 260,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _TaskFormResult {
  const _TaskFormResult({
    required this.title,
    required this.description,
    required this.priority,
    required this.dueAt,
    required this.estimatedMinutes,
    required this.category,
  });
  final String title;
  final String description;
  final TaskPriority priority;
  final String dueAt;
  final int estimatedMinutes;
  final String category;
}

class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({
    required this.completed,
    required this.total,
    required this.progress,
  });

  final int completed;
  final int total;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$completed of $total tasks completed',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress),
              duration: const Duration(milliseconds: 400),
              builder: (context, value, _) {
                return LinearProgressIndicator(value: value, minHeight: 14);
              },
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${(progress * 100).round()}%',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.onChanged,
    required this.onEdit,
    required this.onDelete,
  });

  final AppTask task;
  final ValueChanged<bool?> onChanged;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: CheckboxListTile(
            value: task.isCompleted,
            onChanged: onChanged,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              task.title,
              style: TextStyle(
                decoration: task.isCompleted
                    ? TextDecoration.lineThrough
                    : TextDecoration.none,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (task.description.isNotEmpty) Text(task.description),
                if (task.dueAt.isNotEmpty)
                  Text(
                    'Due: ${DateTime.tryParse(task.dueAt)?.toLocal() ?? task.dueAt}',
                  ),
                if (task.estimatedMinutes > 0)
                  Text('${task.estimatedMinutes} min estimated'),
                if (task.category.isNotEmpty) Text(task.category),
                if (task.scheduledAt.isNotEmpty)
                  Text(
                    'Scheduled: ${DateTime.tryParse(task.scheduledAt)?.toLocal() ?? task.scheduledAt}',
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    task.priority.label,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'Edit task',
          onPressed: onEdit,
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete task',
          onPressed: onDelete,
        ),
        const SizedBox(width: 12),
      ],
    );
  }
}

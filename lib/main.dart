import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

const pocketBaseUrl = 'http://100.117.123.116:8090';
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

  final prefs = await SharedPreferences.getInstance();
  final authStore = AsyncAuthStore(
    initial: prefs.getString('pb_auth'),
    save: (data) => prefs.setString('pb_auth', data),
    clear: () => prefs.remove('pb_auth'),
  );

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
      home: pb.authStore.isValid ? const TaskScreen() : const LoginScreen(),
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
  });

  final String id;
  final String title;
  final String description;
  final TaskPriority priority;
  final bool isCompleted;
  final String completedAt;
  final String createdAt;

  bool get isLocal => id.startsWith('local_');

  AppTask copyWith({
    String? id,
    String? title,
    String? description,
    TaskPriority? priority,
    bool? isCompleted,
    String? completedAt,
    String? createdAt,
  }) {
    return AppTask(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      priority: priority ?? this.priority,
      isCompleted: isCompleted ?? this.isCompleted,
      completedAt: completedAt ?? this.completedAt,
      createdAt: createdAt ?? this.createdAt,
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
    };
  }

  Map<String, dynamic> toServerBody(String userId) {
    return {
      'title': title,
      'description': description,
      'priority': priority.name,
      'is_completed': isCompleted,
      'completed_at': completedAt,
      'user': userId,
    };
  }
}

class TaskRepository {
  final Box _cacheBox = Hive.box(tasksCacheBoxName);
  final Box _pendingBox = Hive.box(pendingChangesBoxName);

  String? get _userId => pb.authStore.record?.id;

  Future<List<AppTask>> loadTasks() async {
    final userId = _userId;
    if (userId == null) return const [];

    try {
      final records = await pb.collection(tasksCollection).getFullList(
            filter: 'user = "$userId"',
            sort: '-created',
          );

      final tasks = records.map(AppTask.fromRecord).toList();
      await _saveCache(tasks);
      return tasks;
    } catch (error) {
      debugPrint('Loading cached tasks because PocketBase is unavailable: $error');
      return _loadCache();
    }
  }

  Future<AppTask> createTask({
    required String title,
    required String description,
    required TaskPriority priority,
  }) async {
    final userId = _userId;
    if (userId == null) throw StateError('No authenticated user.');

    final tempId = 'local_${DateTime.now().microsecondsSinceEpoch}';
    final task = AppTask(
      id: tempId,
      title: title,
      description: description,
      priority: priority,
      isCompleted: false,
      completedAt: '',
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );

    await _upsertCacheTask(task);
    await _pendingBox.put(tempId, {
      'type': 'create',
      'temp_id': tempId,
      ...task.toServerBody(userId),
    });

    try {
      final record = await pb.collection(tasksCollection).create(
            body: task.toServerBody(userId),
          );

      await _pendingBox.delete(tempId);
      await _removeCacheTask(tempId);

      final serverTask = AppTask.fromRecord(record);
      await _upsertCacheTask(serverTask);
      return serverTask;
    } catch (error) {
      debugPrint('New task saved locally and waiting to sync: $error');
      return task;
    }
  }

  Future<void> updateTask(AppTask task) async {
    final userId = _userId;
    if (userId == null) throw StateError('No authenticated user.');

    await _upsertCacheTask(task);

    if (task.isLocal) {
      final pending = _mapFromDynamic(_pendingBox.get(task.id));
      if (pending != null) {
        pending
          ..['title'] = task.title
          ..['description'] = task.description
          ..['priority'] = task.priority.name
          ..['is_completed'] = task.isCompleted
          ..['completed_at'] = task.completedAt;
        await _pendingBox.put(task.id, pending);
      }
      return;
    }

    final body = {
      'title': task.title,
      'description': task.description,
      'priority': task.priority.name,
      'is_completed': task.isCompleted,
      'completed_at': task.completedAt,
    };

    try {
      await pb.collection(tasksCollection).update(task.id, body: body);
      await _pendingBox.delete(task.id);
    } catch (error) {
      await _pendingBox.put(task.id, {
        'type': 'update',
        'task_id': task.id,
        ...body,
      });
      debugPrint('Task update saved locally and waiting to sync: $error');
    }
  }

  Future<void> deleteTask(AppTask task) async {
    await _removeCacheTask(task.id);

    if (task.isLocal) {
      await _pendingBox.delete(task.id);
      return;
    }

    await _pendingBox.put(task.id, {
      'type': 'delete',
      'task_id': task.id,
    });

    try {
      await pb.collection(tasksCollection).delete(task.id);
      await _pendingBox.delete(task.id);
    } catch (error) {
      debugPrint('Task deletion is waiting to sync: $error');
    }
  }

  Future<void> syncPendingChanges() async {
    final userId = _userId;
    if (userId == null) return;

    for (final key in List<dynamic>.from(_pendingBox.keys)) {
      final change = _mapFromDynamic(_pendingBox.get(key));
      if (change == null) continue;

      try {
        switch (change['type']) {
          case 'create':
            await pb.collection(tasksCollection).create(
              body: {
                'title': change['title'],
                'description': change['description'],
                'priority': change['priority'] ?? 'normal',
                'is_completed': change['is_completed'] ?? false,
                'completed_at': change['completed_at'] ?? '',
                'user': change['user'] ?? userId,
              },
            );
            break;

          case 'update':
            await pb.collection(tasksCollection).update(
              change['task_id'].toString(),
              body: {
                'title': change['title'],
                'description': change['description'],
                'priority': change['priority'] ?? 'normal',
                'is_completed': change['is_completed'] ?? false,
                'completed_at': change['completed_at'] ?? '',
              },
            );
            break;

          case 'delete':
            await pb.collection(tasksCollection).delete(
              change['task_id'].toString(),
            );
            break;
        }

        await _pendingBox.delete(key);
      } catch (error) {
        debugPrint('Pending change could not sync yet: $error');
      }
    }
  }

  Future<void> _saveCache(List<AppTask> tasks) async {
    await _cacheBox.put(
      'tasks',
      tasks.map((task) => task.toMap()).toList(),
    );
  }

  List<AppTask> _loadCache() {
    final raw = _cacheBox.get('tasks');
    if (raw is! List) return [];

    return raw
        .whereType<Map>()
        .map((item) => AppTask.fromMap(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<void> _upsertCacheTask(AppTask task) async {
    final tasks = _loadCache();
    final index = tasks.indexWhere((item) => item.id == task.id);

    if (index == -1) {
      tasks.add(task);
    } else {
      tasks[index] = task;
    }

    await _saveCache(tasks);
  }

  Future<void> _removeCacheTask(String id) async {
    final tasks = _loadCache()..removeWhere((task) => task.id == id);
    await _saveCache(tasks);
  }

  Map<String, dynamic>? _mapFromDynamic(dynamic value) {
    if (value is! Map) return null;
    return Map<String, dynamic>.from(value);
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
      await pb.collection(usersCollection).authWithPassword(
            _emailController.text.trim(),
            _passwordController.text,
          );

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TaskScreen()),
      );
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
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                  ),
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

class _TaskScreenState extends State<TaskScreen> {
  final _repository = TaskRepository();

  late final ConfettiController _confettiController;

  List<AppTask> _tasks = [];
  bool _isLoading = true;
  bool _showCelebrationGif = false;
  int _celebrationGeneration = 0;

  @override
  void initState() {
    super.initState();
    _confettiController = ConfettiController(
      duration: const Duration(milliseconds: 1800),
    );
    _initialize();
  }

  Future<void> _initialize() async {
    await _repository.syncPendingChanges();
    await _reloadTasks();
    await _subscribeToTasks();
  }

  Future<void> _subscribeToTasks() async {
    await pb.collection(tasksCollection).subscribe(
      '*',
      (_) => _reloadTasks(),
    );
  }

  Future<void> _reloadTasks() async {
    final tasks = await _repository.loadTasks();
    if (!mounted) return;

    setState(() {
      _tasks = _sortTasks(tasks);
      _isLoading = false;
    });
  }

  List<AppTask> _sortTasks(Iterable<AppTask> tasks) {
    final sorted = List<AppTask>.from(tasks);

    sorted.sort((a, b) {
      final priorityCompare =
          a.priority.sortOrder.compareTo(b.priority.sortOrder);

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
    final descriptionController =
        TextEditingController(text: task?.description ?? '');

    var selectedPriority = task?.priority ?? TaskPriority.normal;

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
                        value: selectedPriority,
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

                    final result = _TaskFormResult(
                      title: title,
                      description: descriptionController.text.trim(),
                      priority: selectedPriority,
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

    if (result == null || !mounted) return;

    if (task == null) {
      final created = await _repository.createTask(
        title: result.title,
        description: result.description,
        priority: result.priority,
      );

      if (!mounted) return;
      _replaceTask(created);
      return;
    }

    final updated = task.copyWith(
      title: result.title,
      description: result.description,
      priority: result.priority,
    );

    _replaceTask(updated);
    await _repository.updateTask(updated);
  }

  Future<void> _toggleTask(AppTask task, bool isCompleted) async {
    final updated = task.copyWith(
      isCompleted: isCompleted,
      completedAt: isCompleted
          ? DateTime.now().toUtc().toIso8601String()
          : '',
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

    Future<void>.delayed(
      const Duration(milliseconds: 1800),
      () {
        if (!mounted || generation != _celebrationGeneration) return;
        setState(() => _showCelebrationGif = false);
      },
    );
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
    pb.collection(tasksCollection).unsubscribe('*');
    _confettiController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(title: const Text('My Tasks')),
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
  });

  final String title;
  final String description;
  final TaskPriority priority;
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
                return LinearProgressIndicator(
                  value: value,
                  minHeight: 14,
                );
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
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    task.priority.label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
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

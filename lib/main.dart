import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

late final PocketBase pb;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

await Hive.initFlutter();

  await Hive.openBox('tasks_cache');
  await Hive.openBox('pending_changes');

  final prefs = await SharedPreferences.getInstance();

  final authStore = AsyncAuthStore(
    save: (String data) async {
      await prefs.setString('pb_auth', data);
    },
    initial: prefs.getString('pb_auth'),
    clear: () async {
      await prefs.remove('pb_auth');
    },
  );

  pb = PocketBase(
    'http://100.117.123.116:8090',
    authStore: authStore,
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sync Task App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
        ),
        useMaterial3: true,
      ),
      home: pb.authStore.isValid
    ? const TaskScreen()
    : const LoginScreen(),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool isLoading = false;
  String message = '';

  Future<void> login() async {
    setState(() {
      isLoading = true;
      message = '';
    });

    try {
      await pb.collection('users').authWithPassword(
        emailController.text.trim(),
        passwordController.text,
      );

      if (!mounted) return;

      setState(() {
        message = 'Login successful';
      });

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => const TaskScreen(),
        ),
      );
    } catch (error) {
      setState(() {
        message = 'Login failed. Check your email and password.';
      });
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync Task App'),
      ),
      body: Center(
        child: SizedBox(
          width: 400,
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
                  controller: emailController,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 16),

                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: isLoading ? null : login,
                    child: isLoading
                        ? const CircularProgressIndicator()
                        : const Text('Log in'),
                  ),
                ),

                const SizedBox(height: 16),

                Text(message),
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
  List<RecordModel> tasks = [];
  bool isLoading = true;
  bool showCelebration = false;

@override
void initState() {
  super.initState();
  initializeTasks();
}
Future<void> initializeTasks() async {
  await syncPendingChanges();
  await loadTasks();
  await subscribeToTasks();
}
Future<void> subscribeToTasks() async {
  await pb.collection('tasks').subscribe('*', (event) {
    loadTasks();
  });
}
@override
void dispose() {
  pb.collection('tasks').unsubscribe('*');
  super.dispose();
}
  Future<void> loadTasks() async {
  final cacheBox = Hive.box('tasks_cache');

  try {
    final user = pb.authStore.record;
    if (user == null) return;

    final records = await pb.collection('tasks').getFullList(
      filter: 'user = "${user.id}"',
      sort: '-created',
    );

    // Save a local copy of the tasks into Hive.
   final cachedTasks = records.map((task) {
  return {
    'id': task.id,
    'title': task.getStringValue('title'),
    'description': task.getStringValue('description'),
    'is_completed': task.getBoolValue('is_completed'),
    'completed_at': task.getStringValue('completed_at'),
  };
}).toList();

    await cacheBox.put('tasks', cachedTasks);

    if (!mounted) return;

    setState(() {
      tasks = records;
      isLoading = false;
    });
  } catch (error) {
    debugPrint('PocketBase unavailable. Loading cached tasks instead.');

    final cachedTasks = cacheBox.get('tasks');

    if (cachedTasks != null) {
final localRecords = (cachedTasks as List).map((task) {
  return RecordModel.fromJson({
    'id': task['id'],
    'title': task['title'],
    'description': task['description'],
    'is_completed': task['is_completed'],
    'completed_at': task['completed_at'] ?? '',
  });
}).toList();

      if (!mounted) return;

      setState(() {
        tasks = localRecords;
        isLoading = false;
      });
    } else {
      if (!mounted) return;

      setState(() {
        isLoading = false;
      });
    }

    debugPrint('Load error: $error');
  }
}

  Future<void> showAddTaskDialog() async {
  final titleController = TextEditingController();
  final descriptionController = TextEditingController();

  await showDialog(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('Add Task'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
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
            onPressed: () async {
              final title = titleController.text.trim();
              final description =
                  descriptionController.text.trim();

              if (title.isEmpty) {
                return;
              }

              // Remove keyboard focus before closing the dialog.
              FocusScope.of(dialogContext).unfocus();

              // Close the dialog first.
              Navigator.of(dialogContext).pop();

              // Then create the task.
              await createTask(
                title: title,
                description: description,
              );
            },
            child: const Text('Add Task'),
          ),
        ],
      );
    },
  );

  // Give Android's text input/focus system time to detach
  // before destroying the controllers.
  await Future<void>.delayed(
    const Duration(milliseconds: 100),
  );

  titleController.dispose();
  descriptionController.dispose();
}

 Future<void> createTask({
  required String title,
  required String description,
}) async {
  final user = pb.authStore.record;

  if (user == null) {
    return;
  }

  final tempId =
      'local_${DateTime.now().microsecondsSinceEpoch}';

  final localTask = {
  'id': tempId,
  'title': title,
  'description': description,
  'is_completed': false,
  'completed_at': '',
};

  final cacheBox = Hive.box('tasks_cache');
  final pendingBox = Hive.box('pending_changes');

  // 1. Save the new task locally.
  final cachedTasks =
      List<dynamic>.from(cacheBox.get('tasks') ?? []);

  cachedTasks.insert(0, localTask);

  await cacheBox.put('tasks', cachedTasks);

  // 2. Queue it for synchronization BEFORE contacting PocketBase.
  await pendingBox.put(
    tempId,
    {
      'type': 'create',
      'temp_id': tempId,
      'title': title,
      'description': description,
      'is_completed': false,
      'completed_at': '',
      'user': user.id,
    },
  );

  // 3. Show the task immediately.
  final localRecord = RecordModel.fromJson(localTask);

  if (mounted) {
    setState(() {
      tasks.insert(0, localRecord);
    });
  }

  try {
    // 4. Try creating it on PocketBase.
    await pb.collection('tasks').create(
      body: {
        'title': title,
        'description': description,
        'is_completed': false,
        'user': user.id,
      },
    );

    // 5. PocketBase received it, so remove the queued operation.
    await pendingBox.delete(tempId);

    // Reload so we get PocketBase's real record ID.
    await loadTasks();

    debugPrint(
      'New task created on PocketBase successfully.',
    );
  } catch (error) {
    // Do NOT remove it from pending_changes.
    debugPrint(
      'Server unavailable. New task is waiting to sync.',
    );
  }
}
Future<void> updateTaskLocally(
  RecordModel task,
  bool newValue,
  String completedAt,
) async {
  final cacheBox = Hive.box('tasks_cache');

  final updatedTask = RecordModel.fromJson({
    'id': task.id,
    'title': task.getStringValue('title'),
    'description': task.getStringValue('description'),
    'is_completed': newValue,
    'completed_at': completedAt,
  });

  final index = tasks.indexWhere(
    (item) => item.id == task.id,
  );

  if (index != -1 && mounted) {
    setState(() {
      tasks[index] = updatedTask;
    });
  }

  final cachedTasks =
      List<dynamic>.from(cacheBox.get('tasks') ?? []);

  final updatedCache = cachedTasks.map((item) {
    final taskMap =
        Map<String, dynamic>.from(item as Map);

    if (taskMap['id'] == task.id) {
      taskMap['is_completed'] = newValue;
      taskMap['completed_at'] = completedAt;
    }

    return taskMap;
  }).toList();

  await cacheBox.put('tasks', updatedCache);
}
Future<void> savePendingTaskUpdate(
  String taskId,
  bool newValue,
  String completedAt,
) async {
  final pendingBox = Hive.box('pending_changes');

  await pendingBox.put(
    taskId,
    {
      'type': 'update',
      'task_id': taskId,
      'is_completed': newValue,
      'completed_at': completedAt,
    },
  );
}
Future<void> syncPendingChanges() async {
  final pendingBox = Hive.box('pending_changes');

  final pendingKeys = List<dynamic>.from(
    pendingBox.keys,
  );

  if (pendingKeys.isEmpty) {
    debugPrint('No pending changes to sync.');
    return;
  }

  for (final key in pendingKeys) {
    final rawChange = pendingBox.get(key);

    if (rawChange == null) {
      continue;
    }

    final change = Map<String, dynamic>.from(
      rawChange as Map,
    );

    try {
      // Existing task was changed while offline.
      if (change['type'] == 'update') {
        await pb.collection('tasks').update(
          change['task_id'],
          body: {
  'is_completed': change['is_completed'],
  'completed_at': change['completed_at'],
},
        );

        await pendingBox.delete(key);

        debugPrint(
          'Pending task ${change['task_id']} synced successfully.',
        );
      }

      // Brand-new task was created while offline.
      else if (change['type'] == 'create') {
        await pb.collection('tasks').create(
          body: {
            'title': change['title'],
            'description': change['description'],
            'is_completed': change['is_completed'],
            'completed_at': change['completed_at'] ?? '',
            'user': change['user'],
          },
        );

        await pendingBox.delete(key);

        debugPrint(
          'Offline task "${change['title']}" created on PocketBase.',
        );
      }
      else if (change['type'] == 'delete') {
  await pb.collection('tasks').delete(
    change['task_id'],
  );

  await pendingBox.delete(key);

  debugPrint(
    'Pending task deletion synced successfully.',
  );
}
    } catch (error) {
      debugPrint(
        'Could not sync pending changes yet: $error',
      );

      continue;
    }
  }
}
Future<void> toggleTask(
  RecordModel task,
  bool newValue,
) async {
  // If checked, record the current UTC time.
  // If unchecked, clear the completion time.
  final completedAt = newValue
      ? DateTime.now().toUtc().toIso8601String()
      : '';
      if (newValue) {
  showTaskCelebration();
}

  await updateTaskLocally(
    task,
    newValue,
    completedAt,
  );

  final pendingBox = Hive.box('pending_changes');

  // Task was created while offline.
  if (task.id.startsWith('local_')) {
    final rawPending = pendingBox.get(task.id);

    if (rawPending != null) {
      final pendingCreate =
          Map<String, dynamic>.from(rawPending as Map);

      pendingCreate['is_completed'] = newValue;
      pendingCreate['completed_at'] = completedAt;

      await pendingBox.put(
        task.id,
        pendingCreate,
      );
    }

    return;
  }

  try {
    await pb.collection('tasks').update(
      task.id,
      body: {
        'is_completed': newValue,
        'completed_at': completedAt,
      },
    );

    await pendingBox.delete(task.id);
  } catch (error) {
    await savePendingTaskUpdate(
      task.id,
      newValue,
      completedAt,
    );

    debugPrint(
      'Server unavailable. Task update saved locally.',
    );
  }
}
Future<void> showTaskCelebration() async {
  if (!mounted) return;

  setState(() {
    showCelebration = true;
  });

  await Future.delayed(
    const Duration(seconds: 2),
  );

  if (!mounted) return;

  setState(() {
    showCelebration = false;
  });
}
Future<void> deleteTask(RecordModel task) async {
  final cacheBox = Hive.box('tasks_cache');
  final pendingBox = Hive.box('pending_changes');

  // Remove from the screen immediately.
  if (mounted) {
    setState(() {
      tasks.removeWhere(
        (item) => item.id == task.id,
      );
    });
  }

  // Remove from Hive cache.
  final cachedTasks =
      List<dynamic>.from(cacheBox.get('tasks') ?? []);

  cachedTasks.removeWhere(
    (item) => item['id'] == task.id,
  );

  await cacheBox.put('tasks', cachedTasks);

  // If the task only exists locally, just remove
  // its pending create operation.
  if (task.id.startsWith('local_')) {
    await pendingBox.delete(task.id);

    debugPrint(
      'Offline-created task deleted locally.',
    );

    return;
  }

  // Queue deletion before contacting PocketBase.
  await pendingBox.put(
    task.id,
    {
      'type': 'delete',
      'task_id': task.id,
    },
  );

  try {
    await pb.collection('tasks').delete(task.id);

    await pendingBox.delete(task.id);

    debugPrint(
      'Task deleted from PocketBase successfully.',
    );
  } catch (error) {
    debugPrint(
      'Server unavailable. Task deletion waiting to sync.',
    );
  }
}
  int get completedTaskCount {
    return tasks
        .where(
          (task) => task.getBoolValue('is_completed'),
        )
        .length;
  }

  double get completionProgress {
    if (tasks.isEmpty) {
      return 0;
    }

    return completedTaskCount / tasks.length;
  }

  @override
  Widget build(BuildContext context) {
return Stack(
  children: [
    Scaffold(
      appBar: AppBar(
        title: const Text('My Tasks'),
      ),
      body: isLoading
          ? const Center(
              child: CircularProgressIndicator(),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    24,
                    20,
                    24,
                    12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$completedTaskCount of ${tasks.length} tasks completed',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium,
                      ),

                      const SizedBox(height: 10),

                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(
                            begin: 0,
                            end: completionProgress,
                          ),
                          duration:
                              const Duration(milliseconds: 500),
                          builder: (context, value, child) {
                            return LinearProgressIndicator(
                              value: value,
                              minHeight: 14,
                            );
                          },
                        ),
                      ),

                      const SizedBox(height: 8),

                      Text(
                        '${(completionProgress * 100).round()}%',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium,
                      ),
                    ],
                  ),
                ),

                const Divider(height: 1),

                Expanded(
                  child: tasks.isEmpty
                      ? const Center(
                          child: Text('No tasks yet'),
                        )
                      : ListView.builder(
                          itemCount: tasks.length,
                          itemBuilder: (context, index) {
                            final task = tasks[index];

                            final title =
                                task.getStringValue('title');

                            final description =
                                task.getStringValue(
                              'description',
                            );

                            final isCompleted =
                                task.getBoolValue(
                              'is_completed',
                            );

                return Row(
  children: [
    Expanded(
      child: CheckboxListTile(
        value: isCompleted,
        onChanged: (value) {
          if (value == null) {
            return;
          }

          toggleTask(
            task,
            value,
          );
        },
        title: Text(
          title,
          style: TextStyle(
            decoration: isCompleted
                ? TextDecoration.lineThrough
                : TextDecoration.none,
          ),
        ),
        subtitle: description.isEmpty
            ? null
            : Text(description),
        controlAffinity:
            ListTileControlAffinity.leading,
      ),
    ),

    IconButton(
      icon: const Icon(Icons.delete_outline),
      tooltip: 'Delete task',
      onPressed: () {
        deleteTask(task);
      },
    ),

    const SizedBox(width: 12),
  ],
);
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: showAddTaskDialog,
        child: const Icon(Icons.add),
      ),
    ),

    if (showCelebration)
      Positioned.fill(
        child: IgnorePointer(
          child: Center(
            child: Image.asset(
              'assets/animations/tungtungscuba.gif',
              width: 260,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
  ],
);
  }
}
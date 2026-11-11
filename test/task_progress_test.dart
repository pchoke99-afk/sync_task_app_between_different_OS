import 'package:flutter_test/flutter_test.dart';
import 'package:sync_task_app/task_progress.dart';

void main() {
  final now = DateTime(2026, 11, 10, 23, 59);
  final task = (id: 'a', completed: true, completedAt: now.toIso8601String());

  test(
    'Daily wins survive deletion and restore, but reopening reverses a win',
    () {
      final progress = DailyTaskProgress(null);
      progress.observe([task], now);
      progress.observe([], now);
      final restored = DailyTaskProgress(progress.toMap());
      expect(restored.completedOn(now), 1);
      restored.observe([task], now);
      expect(restored.completedOn(now), 1);
      restored.observe([(id: 'a', completed: false, completedAt: '')], now);
      expect(restored.completedOn(now), 0);
    },
  );

  test(
    'Local midnight resets the goal and ignores old or malformed timestamps',
    () {
      final progress = DailyTaskProgress(null);
      progress.observe([task], now);
      final tomorrow = DateTime(2026, 11, 11, 0, 1);
      expect(progress.completedOn(tomorrow), 0);
      progress.observe([
        task,
        (id: 'bad', completed: true, completedAt: 'oops'),
      ], tomorrow);
      expect(progress.completedOn(tomorrow), 0);
      final utcTask = (
        id: 'utc',
        completed: true,
        completedAt: tomorrow.toUtc().toIso8601String(),
      );
      progress.observe([utcTask], tomorrow);
      expect(progress.completedOn(tomorrow), 1);
    },
  );
}

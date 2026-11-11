import 'package:flutter/foundation.dart';

class DailyTaskProgress {
  DailyTaskProgress(Object? saved) {
    if (saved is Map && saved['day'] is String && saved['ids'] is List) {
      _day = saved['day'] as String;
      _ids.addAll((saved['ids'] as List).whereType<String>());
    }
  }

  static const goal = 3;
  String _day = '';
  final _ids = <String>{};

  static String _localDay(DateTime date) {
    final local = date.toLocal();
    return '${local.year}-${local.month}-${local.day}';
  }

  int completedOn(DateTime date) => _day == _localDay(date) ? _ids.length : 0;

  bool observe(
    Iterable<({String id, bool completed, String completedAt})> tasks,
    DateTime now,
  ) {
    final day = _localDay(now);
    final previous = _ids.toSet();
    final dayChanged = _day != day;
    if (dayChanged) {
      _day = day;
      _ids.clear();
    }
    // A missing task keeps its credit. An observed reopened task loses it.
    for (final task in tasks) {
      final date = task.completed ? DateTime.tryParse(task.completedAt) : null;
      if (date != null && _localDay(date) == day) {
        _ids.add(task.id);
      } else {
        _ids.remove(task.id);
      }
    }
    return dayChanged || !setEquals(previous, _ids);
  }

  Map<String, Object> toMap() => {'day': _day, 'ids': _ids.toList()};
}

import 'dart:convert';

/// Raised when the server holds encrypted data. Grace has no key, so it cannot read it.
class EncryptedSyncException implements Exception {
  @override
  String toString() =>
      'The sync data is end-to-end encrypted. Grace cannot read it, turn the encryption off in Super Productivity.';
}

const inboxProjectId = 'INBOX_PROJECT';

const _fullStateOps = {'SYNC_IMPORT', 'BACKUP_IMPORT', 'REPAIR'};

/// The tasks, projects and tags of a Super Productivity account, rebuilt from the operations
/// the SuperSync server holds.
///
/// The server stores what the apps did (add a task, change a title, ...), not the result, so
/// the current state is the last full-state operation with every later operation applied on
/// top. Only the operations that change tasks, projects and tags are understood. Others are
/// counted in [ignoredActions] so a gap can be reported.
class SyncState {
  SyncState();

  /// Entities by id. The maps keep every field the app stored, also the unknown ones.
  final Map<String, Map<String, dynamic>> tasks = {};
  final Map<String, Map<String, dynamic>> projects = {};
  final Map<String, Map<String, dynamic>> tags = {};

  /// Highest server sequence number that was applied.
  int lastSeq = 0;

  /// Highest counter seen for every client. A new operation that carries this clock, with its
  /// own counter raised, is newer than everything on the server.
  final Map<String, int> clock = {};

  /// Action types that were skipped, with the number of operations.
  final Map<String, int> ignoredActions = {};

  void reset() {
    tasks.clear();
    projects.clear();
    tags.clear();
    ignoredActions.clear();
  }

  Map<String, dynamic> toJson() => {
    'lastSeq': lastSeq,
    'clock': clock,
    'tasks': tasks,
    'projects': projects,
    'tags': tags,
    'ignored': ignoredActions,
  };

  static SyncState fromJson(Map<String, dynamic> json) {
    final s = SyncState()..lastSeq = (json['lastSeq'] as num?)?.toInt() ?? 0;
    void fill(Map target, Object? source) {
      if (source is! Map) return;
      source.forEach((k, v) {
        if (v is Map) target['$k'] = Map<String, dynamic>.from(v);
      });
    }

    fill(s.tasks, json['tasks']);
    fill(s.projects, json['projects']);
    fill(s.tags, json['tags']);
    (json['clock'] as Map?)?.forEach(
      (k, v) => s.clock['$k'] = (v as num).toInt(),
    );
    (json['ignored'] as Map?)?.forEach(
      (k, v) => s.ignoredActions['$k'] = (v as num).toInt(),
    );
    return s;
  }

  /// Applies one operation as the server sent it ({serverSeq, op, receivedAt}).
  void applyServerOp(Map<String, dynamic> entry) {
    final op = (entry['op'] as Map).cast<String, dynamic>();
    final seq = (entry['serverSeq'] as num).toInt();

    final opClock = op['vectorClock'];
    if (opClock is Map) {
      opClock.forEach((k, v) {
        if (v is num && v.toInt() > (clock['$k'] ?? 0)) clock['$k'] = v.toInt();
      });
    }

    if (op['isPayloadEncrypted'] == true || op['payload'] is String) {
      throw EncryptedSyncException();
    }

    _apply(op);
    if (seq > lastSeq) lastSeq = seq;
  }

  void _apply(Map<String, dynamic> op) {
    final opType = '${op['opType']}';
    final actionType = '${op['actionType']}';
    final entityType = '${op['entityType']}';
    final payload = op['payload'];

    if (_fullStateOps.contains(opType)) {
      _applyFullState(payload);
      return;
    }

    final lww = RegExp(r'^\[(\w+)\] LWW Update$').firstMatch(actionType);
    if (lww != null) {
      _applyLww(lww.group(1)!, op, payload);
      return;
    }

    if (entityType != 'TASK' &&
        entityType != 'PROJECT' &&
        entityType != 'TAG') {
      return;
    }

    final p = _actionPayload(payload);
    switch (actionType) {
      case '[Task Shared] addTask':
        _setTask(p['task']);
      case '[Task Shared] updateTask':
        _updateTask(p['task']);
      case '[Task Shared] updateTasks':
        for (final u in _list(p['tasks'])) {
          _updateTask(u);
        }
      case '[Task Shared] deleteTask':
        _deleteTaskTree(_idOf(p['task']));
      case '[Task Shared] deleteTasks':
        for (final id in _list(p['taskIds'])) {
          _deleteTaskTree('$id');
        }
      case '[Task Shared] moveToArchive':
        for (final t in _list(p['tasks'])) {
          _deleteTaskTree(_idOf(t));
        }
      case '[Task Shared] restoreTask':
        _setTask(p['task']);
        for (final sub in _list(p['subTasks'])) {
          _setTask(sub);
        }
      case '[Task Shared] scheduleTaskWithTime':
      case '[Task Shared] reScheduleTaskWithTime':
        _patch(_idOf(p['task']), {
          'dueWithTime': p['dueWithTime'],
          'dueDay': null,
          'remindAt': p['remindAt'],
        });
      case '[Task Shared] unscheduleTask':
        _patch('${p['id']}', {
          'dueWithTime': null,
          'dueDay': p['isLeaveInToday'] == true ? p['today'] : null,
          'remindAt': null,
        });
      case '[Task Shared] planTasksForToday':
        final today = p['today'];
        if (today is String) {
          for (final id in _list(p['taskIds'])) {
            _patch('$id', {'dueDay': today, 'dueWithTime': null});
          }
        }
      case '[Task Shared] moveToOtherProject':
        final target = p['targetProjectId'];
        if (target is String) {
          final task = p['task'];
          _patch(_idOf(task), {'projectId': target});
          if (task is Map) {
            for (final id in _list(task['subTaskIds'])) {
              _patch('$id', {'projectId': target});
            }
          }
        }
      case '[Task Shared] convertToSubTask':
        _patch('${p['taskId']}', {'parentId': p['targetParentId']});
      case '[Task Shared] setDeadline':
        _patch('${p['taskId']}', {
          'deadlineDay': p['deadlineDay'],
          'deadlineWithTime': p['deadlineWithTime'],
        });
      case '[Task Shared] removeDeadline':
        _patch('${p['taskId']}', {
          'deadlineDay': null,
          'deadlineWithTime': null,
        });
      case '[Task Shared] addTagToTask':
        final task = tasks['${p['taskId']}'];
        final tagId = p['tagId'];
        if (task != null && tagId is String) {
          final ids = [..._list(task['tagIds']).map((e) => '$e')];
          if (!ids.contains(tagId)) task['tagIds'] = [...ids, tagId];
        }
      default:
        // Time tracking, ordering inside lists and similar do not change what a task says
        if (!_harmless.contains(actionType)) {
          ignoredActions[actionType] = (ignoredActions[actionType] ?? 0) + 1;
        }
    }
  }

  static const _harmless = {
    '[TimeTracking] Sync time spent',
    '[Task Shared] moveTaskInTodayTagList',
    '[Task Shared] dismissReminderOnly',
    '[Task Shared] clearDeadlineReminder',
    '[Task] Move up',
    '[Task] Move down',
    '[Task] Move to top',
    '[Task] Move to bottom',
    '[Task] Move sub task',
    '[Task] Update Task Ui',
  };

  void _applyFullState(Object? payload) {
    final data = payload is Map && payload['appDataComplete'] is Map
        ? payload['appDataComplete'] as Map
        : payload;
    if (data is! Map) return;
    reset();

    void load(String key, Map<String, Map<String, dynamic>> target) {
      final entities = (data[key] is Map
          ? (data[key] as Map)['entities']
          : null);
      if (entities is! Map) return;
      entities.forEach((id, value) {
        if (value is Map) target['$id'] = _copy(value);
      });
    }

    load('task', tasks);
    load('project', projects);
    load('tag', tags);
  }

  void _applyLww(String group, Map<String, dynamic> op, Object? payload) {
    final target = switch (group) {
      'TASK' => tasks,
      'PROJECT' => projects,
      'TAG' => tags,
      _ => null,
    };
    if (target == null) return;

    final id = '${op['entityId']}';
    final p = _actionPayload(payload);
    final fields = _copy(p)..['id'] = id;
    final mode = payload is Map ? payload['lwwUpdateMode'] : null;
    final cleared = payload is Map ? _list(payload['clearedFields']) : const [];

    final existing = target[id];
    if (mode == 'patch') {
      if (existing == null) return;
      existing.addAll(fields);
      for (final key in cleared) {
        existing[key.toString()] = null;
      }
    } else {
      target[id] = fields;
    }
  }

  void _setTask(Object? task) {
    if (task is! Map || task['id'] == null) return;
    tasks['${task['id']}'] = _copy(task)..remove('subTasks');
  }

  void _updateTask(Object? update) {
    if (update is! Map) return;
    final changes = update['changes'];
    if (changes is Map) _patch('${update['id']}', _copy(changes));
  }

  void _patch(String id, Map<String, dynamic> changes) {
    final task = tasks[id];
    if (task == null) return;
    task.addAll(changes);
  }

  void _deleteTaskTree(String id) {
    final task = tasks.remove(id);
    if (task == null) return;
    for (final sub in _list(task['subTaskIds'])) {
      tasks.remove('$sub');
    }
  }

  static String _idOf(Object? entity) => entity is Map ? '${entity['id']}' : '';

  static List _list(Object? v) => v is List ? v : const [];

  static Map<String, dynamic> _actionPayload(Object? payload) {
    if (payload is Map && payload['actionPayload'] is Map) {
      return (payload['actionPayload'] as Map).cast<String, dynamic>();
    }
    return payload is Map ? payload.cast<String, dynamic>() : {};
  }

  static Map<String, dynamic> _copy(Map source) =>
      jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
}

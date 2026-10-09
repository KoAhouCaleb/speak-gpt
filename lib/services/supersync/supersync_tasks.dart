import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'payload_crypto.dart';
import 'supersync_client.dart';
import 'sync_state.dart';

/// Version of the operation format the server stores. Operations with a higher version are
/// refused by the apps, so this must match what Super Productivity writes.
const supersyncSchemaVersion = 4;

/// A task as Super Productivity shows it.
class SyncedTask {
  SyncedTask(this.data, this.projectTitle);

  final Map<String, dynamic> data;
  final String? projectTitle;

  String get id => '${data['id']}';
  String get title => '${data['title'] ?? ''}';
  String get notes => '${data['notes'] ?? ''}';
  bool get isDone => data['isDone'] == true;
  String? get parentId => data['parentId'] as String?;
  String? get projectId => data['projectId'] as String?;
  List<String> get tagIds => [
    for (final t in (data['tagIds'] as List? ?? const [])) '$t',
  ];

  /// Due date, with the time if the task has one, in local time.
  DateTime? get due {
    final withTime = data['dueWithTime'];
    if (withTime is num) {
      return DateTime.fromMillisecondsSinceEpoch(withTime.toInt());
    }
    final day = data['dueDay'];
    return day is String ? DateTime.tryParse(day) : null;
  }

  bool get dueHasTime => data['dueWithTime'] is num;
}

/// Reads and changes the tasks of a Super Productivity account through its SuperSync server.
///
/// The server is the only storage. A copy of the rebuilt state is cached in a file so that
/// only new operations are fetched the next time.
class SuperSyncTasks {
  SuperSyncTasks({
    required this.client,
    required this.cacheFile,
    this.crypto,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SuperSyncClient client;

  /// Decrypts what the server sends and encrypts what is uploaded. SuperSync servers accept
  /// nothing else, so without the encryption password nothing works.
  final PayloadCrypto? crypto;
  final File cacheFile;
  final DateTime Function() _now;

  SyncState? _state;

  // ---- Reading ----------------------------------------------------------------------------

  /// Brings the cached state up to date with the server.
  Future<SyncState> sync() async {
    var state = _state ?? await _readCache() ?? SyncState();
    var restarted = false;

    while (true) {
      final page = await client.download(state.lastSeq, limit: 1000);

      if (page['gapDetected'] == true && state.lastSeq > 0 && !restarted) {
        // The server dropped operations we have not seen, start from its snapshot
        state = SyncState();
        restarted = true;
        continue;
      }

      final entries = (page['ops'] as List? ?? const []).whereType<Map>();
      for (final entry in entries) {
        state.applyServerOp(await _decrypted(entry.cast<String, dynamic>()));
      }
      final snapshotClock = page['snapshotVectorClock'];
      if (snapshotClock is Map) {
        snapshotClock.forEach((k, v) {
          if (v is num && v.toInt() > (state.clock['$k'] ?? 0)) {
            state.clock['$k'] = v.toInt();
          }
        });
      }
      final latest = (page['latestSeq'] as num?)?.toInt() ?? state.lastSeq;
      if (page['hasMore'] != true) {
        if (latest > state.lastSeq) state.lastSeq = latest;
        break;
      }
    }

    _state = state;
    await _writeCache(state);
    return state;
  }

  /// The entry with its payload decrypted. Plaintext entries are returned as they are.
  Future<Map<String, dynamic>> _decrypted(Map<String, dynamic> entry) async {
    final op = (entry['op'] as Map).cast<String, dynamic>();
    final payload = op['payload'];
    if (op['isPayloadEncrypted'] != true || payload is! String) return entry;

    final c = crypto;
    if (c == null) {
      throw SuperSyncException(
        'The data on the server is encrypted. Enter the sync encryption password of Super Productivity in the tool settings.',
      );
    }
    final clear = jsonDecode(await c.decrypt(payload));
    return {
      ...entry,
      'op': {...op, 'payload': clear, 'isPayloadEncrypted': false},
    };
  }

  Future<SyncState?> _readCache() async {
    try {
      if (!await cacheFile.exists()) return null;
      return SyncState.fromJson(
        jsonDecode(await cacheFile.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(SyncState state) async {
    try {
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsString(jsonEncode(state.toJson()));
    } catch (_) {
      // The cache only saves time
    }
  }

  /// Open tasks (and finished ones when asked for), parents before their subtasks.
  Future<List<SyncedTask>> list({
    bool includeDone = false,
    String? project,
    String? search,
  }) async {
    final state = await sync();
    final projectId = project == null ? null : _projectId(state, project);
    final query = search?.toLowerCase();

    final result = <SyncedTask>[];
    final tasks = state.tasks.values.toList()
      ..sort(
        (a, b) => ((a['created'] as num?) ?? 0).compareTo(
          (b['created'] as num?) ?? 0,
        ),
      );
    for (final t in tasks) {
      if (t['parentId'] != null) continue;
      final parentShown = _matches(t, includeDone, projectId, query);
      final subs = [
        for (final id in (t['subTaskIds'] as List? ?? const []))
          if (state.tasks['$id'] != null) state.tasks['$id']!,
      ];
      final shownSubs = subs
          .where((s) => _matches(s, includeDone, projectId, query))
          .toList();
      if (!parentShown && shownSubs.isEmpty) continue;
      result.add(SyncedTask(t, _projectTitle(state, t)));
      for (final s in shownSubs) {
        result.add(SyncedTask(s, _projectTitle(state, s)));
      }
    }
    return result;
  }

  bool _matches(
    Map<String, dynamic> t,
    bool includeDone,
    String? projectId,
    String? query,
  ) {
    if (!includeDone && t['isDone'] == true) return false;
    if (projectId != null && t['projectId'] != projectId) return false;
    if (query != null &&
        !'${t['title']} ${t['notes'] ?? ''}'.toLowerCase().contains(query)) {
      return false;
    }
    return true;
  }

  static String? _projectTitle(SyncState state, Map<String, dynamic> task) {
    final id = task['projectId'];
    final project = id == null ? null : state.projects['$id'];
    return project?['title'] as String?;
  }

  static String? _projectId(SyncState state, String name) {
    final wanted = name.trim().toLowerCase();
    for (final e in state.projects.entries) {
      if (e.key.toLowerCase() == wanted) return e.key;
    }
    for (final e in state.projects.entries) {
      if ('${e.value['title']}'.toLowerCase() == wanted) return e.key;
    }
    for (final e in state.projects.entries) {
      if ('${e.value['title']}'.toLowerCase().contains(wanted)) return e.key;
    }
    throw SuperSyncException(
      'No project matches "$name". Projects: ${state.projects.values.map((p) => p['title']).join(', ')}',
    );
  }

  /// Finds one task by id, else by title. Throws if nothing or several match.
  Future<SyncedTask> find({String? id, String? title}) async {
    final state = await sync();
    return _find(state, id: id, title: title);
  }

  /// Finds one task by its id or by its exact title (ignoring case). A title that only
  /// resembles a task is an error with suggestions: changing the wrong task silently is worse
  /// than asking the model to try again.
  SyncedTask _find(SyncState state, {String? id, String? title}) {
    SyncedTask wrap(Map<String, dynamic> t) =>
        SyncedTask(t, _projectTitle(state, t));

    final wantedId = id?.trim();
    if (wantedId != null && wantedId.isNotEmpty) {
      final byId = state.tasks[wantedId];
      if (byId != null) return wrap(byId);
      if (title == null || title.trim().isEmpty) {
        throw SuperSyncException(
          'No task has the id "$wantedId". Use list_tasks to see the ids.',
        );
      }
    }

    final query = (title ?? '').trim().toLowerCase();
    if (query.isEmpty) {
      throw SuperSyncException('Give the id or the exact title of the task');
    }

    final exact = state.tasks.values
        .where((t) => '${t['title']}'.trim().toLowerCase() == query)
        .toList();
    // The same title can exist as a finished and an open task: the open one is meant
    final open = exact.where((t) => t['isDone'] != true).toList();
    final matches = open.isNotEmpty ? open : exact;

    if (matches.length == 1) return wrap(matches.single);
    if (matches.length > 1) {
      throw SuperSyncException(
        'Several tasks are titled "$title", use the id: ${matches.map((t) => '[${t['id']}] ${t['title']}').join('; ')}',
      );
    }

    final words = query
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 2)
        .toSet();
    final similar = state.tasks.values
        .where((t) {
          final name = '${t['title']}'.toLowerCase();
          return name.contains(query) ||
              query.contains(name) ||
              words.any(name.contains);
        })
        .take(5)
        .toList();
    throw SuperSyncException(
      similar.isEmpty
          ? 'No task is titled "$title". Use list_tasks to see the tasks.'
          : 'No task is titled "$title". Similar tasks (use the id): ${similar.map((t) => '[${t['id']}] ${t['title']}${t['isDone'] == true ? ' (done)' : ''}').join('; ')}',
    );
  }

  // ---- Writing ----------------------------------------------------------------------------

  /// Creates a task. [dueDay] is a date, [dueWithTime] a moment, at most one of them.
  Future<SyncedTask> add(
    String title, {
    String? notes,
    String? project,
    String? dueDay,
    DateTime? dueWithTime,
  }) async {
    final id = _uuidV7();
    late Map<String, dynamic> task;
    await _write((state) {
      final projectId = project == null
          ? (state.projects.containsKey(inboxProjectId) ||
                    state.projects.isEmpty
                ? inboxProjectId
                : state.projects.keys.first)
          : _projectId(state, project)!;
      task = {
        'id': id,
        'title': title,
        'subTaskIds': <String>[],
        'timeSpentOnDay': <String, num>{},
        'timeSpent': 0,
        'timeEstimate': 0,
        'isDone': false,
        'tagIds': <String>[],
        'created': _now().millisecondsSinceEpoch,
        'attachments': <Object>[],
        'projectId': projectId,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
        if (dueWithTime != null)
          'dueWithTime': dueWithTime.millisecondsSinceEpoch
        else if (dueDay != null)
          'dueDay': dueDay,
      };
      return [_lwwOp(state, id, task, 'replace')];
    });
    return SyncedTask(task, _projectTitle(_state!, task));
  }

  /// Changes the given fields of a task. Pass [clearDue] to remove its due date.
  Future<SyncedTask> update(
    SyncedTask target, {
    String? title,
    String? notes,
    bool? isDone,
    String? project,
    String? dueDay,
    DateTime? dueWithTime,
    bool clearDue = false,
  }) async {
    final changes = <String, dynamic>{};
    await _write((state) {
      changes.clear();
      if (title != null) changes['title'] = title;
      if (notes != null) changes['notes'] = notes;
      if (isDone != null) {
        changes['isDone'] = isDone;
        changes['doneOn'] = isDone ? _now().millisecondsSinceEpoch : null;
      }
      if (project != null) changes['projectId'] = _projectId(state, project);
      if (clearDue) {
        changes['dueDay'] = null;
        changes['dueWithTime'] = null;
      } else if (dueWithTime != null) {
        changes['dueWithTime'] = dueWithTime.millisecondsSinceEpoch;
        changes['dueDay'] = null;
      } else if (dueDay != null) {
        changes['dueDay'] = dueDay;
        changes['dueWithTime'] = null;
      }
      if (changes.isEmpty) {
        throw SuperSyncException('Nothing to change');
      }
      if (state.tasks[target.id] == null) {
        throw SuperSyncException('The task no longer exists');
      }
      return [_lwwOp(state, target.id, changes, 'patch')];
    });
    return SyncedTask(
      _state!.tasks[target.id] ?? target.data,
      target.projectTitle,
    );
  }

  /// Deletes a task together with its subtasks.
  Future<void> delete(SyncedTask target) async {
    await _write((state) {
      if (state.tasks[target.id] == null) {
        throw SuperSyncException('The task no longer exists');
      }
      final ids = [target.id];
      return [
        _op(
          state,
          actionType: '[Task Shared] deleteTasks',
          opType: 'DEL',
          entityId: ids.first,
          entityIds: ids,
          payload: {
            'actionPayload': {'taskIds': ids},
            'entityChanges': <Object>[],
          },
        ),
      ];
    });
  }

  Map<String, dynamic> _lwwOp(
    SyncState state,
    String id,
    Map<String, dynamic> fields,
    String mode,
  ) {
    final cleared = [
      for (final e in fields.entries)
        if (e.value == null) e.key,
    ];
    return _op(
      state,
      actionType: '[TASK] LWW Update',
      opType: 'UPD',
      entityId: id,
      payload: {
        'actionPayload': {...fields, 'id': id},
        'entityChanges': <Object>[],
        'lwwUpdateMode': mode,
        if (mode == 'patch' && cleared.isNotEmpty) 'clearedFields': cleared,
      },
    );
  }

  Map<String, dynamic> _op(
    SyncState state, {
    required String actionType,
    required String opType,
    required String entityId,
    List<String>? entityIds,
    required Map<String, dynamic> payload,
  }) {
    // Newer than everything on the server: the clock seen so far, own counter raised
    final clock = {...state.clock};
    final own = client.clientId;
    clock[own] = (clock[own] ?? 0) + 1;
    state.clock[own] = clock[own]!;

    return {
      'id': _uuidV7(),
      'clientId': own,
      'actionType': actionType,
      'opType': opType,
      'entityType': 'TASK',
      'entityId': entityId,
      'entityIds': ?entityIds,
      'payload': payload,
      'vectorClock': clock,
      'timestamp': _now().millisecondsSinceEpoch,
      'schemaVersion': supersyncSchemaVersion,
    };
  }

  /// Syncs, builds the operations from the fresh state, uploads them and syncs again. A
  /// refusal because of a concurrent change is retried once from the newer state.
  Future<void> _write(
    List<Map<String, dynamic>> Function(SyncState state) build,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final state = await sync();
      final ops = await _encrypted(build(state));
      final response = await client.upload(ops);

      final results = (response['results'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      final rejected = results.where((r) => r['accepted'] != true).toList();
      if (rejected.isEmpty) {
        await sync();
        return;
      }

      final isConflict = rejected.any(
        (r) => '${r['errorCode']}'.contains('CONFLICT'),
      );
      if (isConflict && attempt == 0) {
        // Another device changed the task meanwhile. Start from its newer clock.
        _state = null;
        continue;
      }
      throw SuperSyncException(
        'The task server refused the change: ${rejected.first['error'] ?? rejected.first['errorCode']}',
      );
    }
  }

  Future<List<Map<String, dynamic>>> _encrypted(
    List<Map<String, dynamic>> ops,
  ) async {
    final c = crypto;
    if (c == null) {
      throw SuperSyncException(
        'The task server only accepts encrypted data. Enter the sync encryption password of Super Productivity in the tool settings.',
      );
    }
    return [
      for (final op in ops)
        {
          ...op,
          'payload': await c.encrypt(jsonEncode(op['payload'])),
          'isPayloadEncrypted': true,
        },
    ];
  }

  /// Number of operations of kinds that are not understood, for a hint in tool answers.
  int get ignoredOperations =>
      _state?.ignoredActions.values.fold<int>(0, (a, b) => a + b) ?? 0;

  /// Checks the connection and the token without reading any data.
  Future<String> check() async {
    final status = await client.status();
    return 'Connected. ${status['latestSeq']} operations on the server.';
  }
}

String _uuidV7() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  final ms = DateTime.now().millisecondsSinceEpoch;
  for (var i = 0; i < 6; i++) {
    bytes[i] = (ms >> (8 * (5 - i))) & 0xff;
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// File name of the cache for a server and account, so another server never reuses it.
String supersyncCacheName(String url, String clientId) =>
    'supersync_${sha256.convert(utf8.encode('$url|$clientId')).toString().substring(0, 16)}.json';

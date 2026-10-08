import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/storage.dart';
import '../services/tools.dart';
import 'form_dialogs.dart';

/// The to-do list the assistant reads and changes through its tools.
class TodosScreen extends StatelessWidget {
  const TodosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();
    final items = storage.todos;
    // Open tasks first, then by due date, tasks without one last
    items.sort((a, b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      if (a.due == null && b.due == null) return 0;
      if (a.due == null) return 1;
      if (b.due == null) return -1;
      return a.due!.compareTo(b.due!);
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tasks'),
        actions: [
          if (items.any((t) => t.done))
            IconButton(
              tooltip: 'Clear finished tasks',
              icon: const Icon(Icons.playlist_remove),
              onPressed: storage.clearDoneTodos,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add task',
        onPressed: () => _edit(context, storage, null),
        child: const Icon(Icons.add),
      ),
      body: items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No tasks. Add some here, or ask the assistant to add them for you.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, i) {
                final t = items[i];
                return Dismissible(
                  key: ValueKey(t.id),
                  background: Container(
                    color: Theme.of(context).colorScheme.errorContainer,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: const Icon(Icons.delete_outline),
                  ),
                  direction: DismissDirection.endToStart,
                  onDismissed: (_) => storage.deleteTodo(t.id),
                  child: CheckboxListTile(
                    value: t.done,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      t.title,
                      style: t.done
                          ? const TextStyle(
                              decoration: TextDecoration.lineThrough,
                            )
                          : null,
                    ),
                    subtitle: _subtitle(t),
                    secondary: IconButton(
                      tooltip: 'Edit task',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _edit(context, storage, t),
                    ),
                    onChanged: (v) {
                      t.done = v ?? false;
                      storage.saveTodo(t);
                    },
                  ),
                );
              },
            ),
    );
  }

  Widget? _subtitle(TodoItem t) {
    final parts = [
      if (t.due != null) 'Due ${formatMoment(t.due!).replaceFirst('T', ' ')}',
      if (t.notes.isNotEmpty) t.notes,
    ];
    return parts.isEmpty ? null : Text(parts.join('\n'));
  }

  Future<void> _edit(
    BuildContext context,
    Storage storage,
    TodoItem? existing,
  ) async {
    final result = await showTodoDialog(context, existing);
    if (result != null) await storage.saveTodo(result);
  }
}

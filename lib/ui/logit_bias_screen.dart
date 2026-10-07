import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/storage.dart';
import 'dialogs.dart';

class LogitBiasListScreen extends StatelessWidget {
  const LogitBiasListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();
    final sets = storage.logitBiasSets;

    return Scaffold(
      appBar: AppBar(title: const Text('Logit bias sets')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add set',
        onPressed: () async {
          final name = await promptText(
            context,
            title: 'New set',
            label: 'Name',
            validator: (v) =>
                v.trim().isEmpty ? 'Name must not be empty' : null,
          );
          if (name == null) return;
          final set = LogitBiasSet(
            id: sha256Hex('${DateTime.now().microsecondsSinceEpoch}$name'),
            name: name.trim(),
          );
          await storage.saveLogitBiasSet(set);
          if (context.mounted) _open(context, set);
        },
        child: const Icon(Icons.add),
      ),
      body: sets.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'A logit bias set makes chosen tokens more or less likely. Token ids depend on the model.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: sets.length,
              itemBuilder: (context, i) => ListTile(
                title: Text(sets[i].name),
                subtitle: Text('${sets[i].biases.length} tokens'),
                onTap: () => _open(context, sets[i]),
                onLongPress: () async {
                  final ok = await confirm(
                    context,
                    title: 'Delete set',
                    message: 'Delete "${sets[i].name}"?',
                  );
                  if (ok) await storage.deleteLogitBiasSet(sets[i].id);
                },
              ),
            ),
    );
  }

  void _open(BuildContext context, LogitBiasSet set) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LogitBiasEditScreen(set: set)),
    );
  }
}

class LogitBiasEditScreen extends StatelessWidget {
  const LogitBiasEditScreen({super.key, required this.set});

  final LogitBiasSet set;

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<Storage>();
    final current = storage.logitBiasSetById(set.id) ?? set;
    final entries = current.biases.entries.toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(current.name),
        actions: [
          IconButton(
            tooltip: 'Rename',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final name = await promptText(
                context,
                title: 'Rename set',
                label: 'Name',
                initial: current.name,
                validator: (v) =>
                    v.trim().isEmpty ? 'Name must not be empty' : null,
              );
              if (name != null) {
                current.name = name.trim();
                await storage.saveLogitBiasSet(current);
              }
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add token',
        onPressed: () => _editEntry(context, storage, current, null),
        child: const Icon(Icons.add),
      ),
      body: ListView.builder(
        itemCount: entries.length,
        itemBuilder: (context, i) => ListTile(
          title: Text('Token ${entries[i].key}'),
          trailing: Text('${entries[i].value}'),
          onTap: () => _editEntry(context, storage, current, entries[i].key),
          onLongPress: () async {
            current.biases.remove(entries[i].key);
            await storage.saveLogitBiasSet(current);
          },
        ),
      ),
    );
  }

  Future<void> _editEntry(
    BuildContext context,
    Storage storage,
    LogitBiasSet current,
    String? token,
  ) async {
    final tokenController = TextEditingController(text: token ?? '');
    final biasController = TextEditingController(
      text: token == null ? '' : '${current.biases[token]}',
    );
    String? error;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(token == null ? 'Add token' : 'Edit token'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: tokenController,
                enabled: token == null,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Token id'),
              ),
              TextField(
                controller: biasController,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'-?\d*')),
                ],
                decoration: InputDecoration(
                  labelText: 'Bias (-100 to 100)',
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final bias = int.tryParse(biasController.text);
                if (tokenController.text.isEmpty ||
                    bias == null ||
                    bias < -100 ||
                    bias > 100) {
                  setState(
                    () =>
                        error = 'Enter a token id and a bias from -100 to 100',
                  );
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      current.biases[tokenController.text] = int.parse(biasController.text);
      await storage.saveLogitBiasSet(current);
    }
    tokenController.dispose();
    biasController.dispose();
  }
}

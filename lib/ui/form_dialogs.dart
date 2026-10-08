import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';

// Every dialog here owns its text controllers in a State object. Disposing controllers
// right after showDialog returns breaks the dialog's closing animation (red error screen).

/// Add or edit an API endpoint. Returns null if cancelled.
Future<ApiEndpoint?> showEndpointDialog(
  BuildContext context, [
  ApiEndpoint? existing,
]) {
  return showDialog<ApiEndpoint>(
    context: context,
    builder: (_) => _EndpointDialog(existing: existing),
  );
}

class _EndpointDialog extends StatefulWidget {
  const _EndpointDialog({this.existing});

  final ApiEndpoint? existing;

  @override
  State<_EndpointDialog> createState() => _EndpointDialogState();
}

class _EndpointDialogState extends State<_EndpointDialog> {
  late final _label = TextEditingController(text: widget.existing?.label ?? '');
  late final _host = TextEditingController(
    text: widget.existing?.host ?? 'https://api.openai.com/v1/',
  );
  late final _key = TextEditingController(text: widget.existing?.apiKey ?? '');
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _host.dispose();
    _key.dispose();
    super.dispose();
  }

  void _save() {
    if (_label.text.trim().isEmpty || _host.text.trim().isEmpty) {
      setState(() => _error = 'Label and base URL are required');
      return;
    }
    Navigator.pop(
      context,
      ApiEndpoint(
        label: _label.text.trim(),
        host: _host.text.trim(),
        apiKey: _key.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add endpoint' : 'Edit endpoint'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _label,
              enabled: widget.existing == null,
              decoration: const InputDecoration(labelText: 'Label'),
            ),
            TextField(
              controller: _host,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Base URL'),
            ),
            TextField(
              controller: _key,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'API key',
                errorText: _error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Add or edit a saved prompt. Returns null if cancelled.
Future<({String title, String text})?> showPromptDialog(
  BuildContext context, [
  SavedPrompt? existing,
]) {
  return showDialog<({String title, String text})>(
    context: context,
    builder: (_) => _PromptDialog(existing: existing),
  );
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({this.existing});

  final SavedPrompt? existing;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _text = TextEditingController(text: widget.existing?.text ?? '');

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add prompt' : 'Edit prompt'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            TextField(
              controller: _text,
              minLines: 4,
              maxLines: 10,
              decoration: const InputDecoration(labelText: 'Prompt'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_title.text.trim().isEmpty || _text.text.trim().isEmpty) return;
            Navigator.pop(context, (
              title: _title.text.trim(),
              text: _text.text.trim(),
            ));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Add or edit one token bias. Returns null if cancelled.
Future<({String token, int bias})?> showLogitBiasEntryDialog(
  BuildContext context, {
  String? token,
  int? bias,
}) {
  return showDialog<({String token, int bias})>(
    context: context,
    builder: (_) => _LogitBiasEntryDialog(token: token, bias: bias),
  );
}

class _LogitBiasEntryDialog extends StatefulWidget {
  const _LogitBiasEntryDialog({this.token, this.bias});

  final String? token;
  final int? bias;

  @override
  State<_LogitBiasEntryDialog> createState() => _LogitBiasEntryDialogState();
}

class _LogitBiasEntryDialogState extends State<_LogitBiasEntryDialog> {
  late final _token = TextEditingController(text: widget.token ?? '');
  late final _bias = TextEditingController(
    text: widget.bias == null ? '' : '${widget.bias}',
  );
  String? _error;

  @override
  void dispose() {
    _token.dispose();
    _bias.dispose();
    super.dispose();
  }

  void _save() {
    final bias = int.tryParse(_bias.text);
    if (_token.text.isEmpty || bias == null || bias < -100 || bias > 100) {
      setState(() => _error = 'Enter a token id and a bias from -100 to 100');
      return;
    }
    Navigator.pop(context, (token: _token.text, bias: bias));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.token == null ? 'Add token' : 'Edit token'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _token,
            enabled: widget.token == null,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Token id'),
          ),
          TextField(
            controller: _bias,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'-?\d*')),
            ],
            decoration: InputDecoration(
              labelText: 'Bias (-100 to 100)',
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Add or edit a to-do. Returns null if cancelled.
Future<TodoItem?> showTodoDialog(BuildContext context, [TodoItem? existing]) {
  return showDialog<TodoItem>(
    context: context,
    builder: (_) => _TodoDialog(existing: existing),
  );
}

class _TodoDialog extends StatefulWidget {
  const _TodoDialog({this.existing});

  final TodoItem? existing;

  @override
  State<_TodoDialog> createState() => _TodoDialogState();
}

class _TodoDialogState extends State<_TodoDialog> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late DateTime? _due = widget.existing?.due;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  String _dueLabel() {
    final d = _due;
    if (d == null) return 'No due date';
    final date =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final hasTime = d.hour != 0 || d.minute != 0;
    return hasTime
        ? '$date ${TimeOfDay.fromDateTime(d).format(context)}'
        : date;
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _due ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_due ?? now),
    );
    if (!mounted) return;
    setState(() {
      _due = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? 0,
        time?.minute ?? 0,
      );
    });
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'A title is required');
      return;
    }
    Navigator.pop(
      context,
      TodoItem(
        id:
            widget.existing?.id ??
            DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        title: title,
        notes: _notes.text.trim(),
        due: _due,
        done: widget.existing?.done ?? false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add task' : 'Edit task'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Task'),
            ),
            TextField(
              controller: _notes,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(labelText: 'Notes'),
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(_dueLabel()),
              onTap: _pickDue,
              trailing: _due == null
                  ? null
                  : IconButton(
                      tooltip: 'Remove due date',
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _due = null),
                    ),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

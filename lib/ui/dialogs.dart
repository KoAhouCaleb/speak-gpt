import 'package:flutter/material.dart';

import '../services/tools.dart';

Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String? Function(String value)? validator,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PromptTextDialog(
      title: title,
      label: label,
      initial: initial,
      validator: validator,
    ),
  );
}

// The controller lives in the dialog's State so it is only disposed once the dialog has
// left the tree. Disposing it after showDialog returns breaks the closing animation.
class _PromptTextDialog extends StatefulWidget {
  const _PromptTextDialog({
    required this.title,
    required this.label,
    required this.initial,
    this.validator,
  });

  final String title;
  final String label;
  final String initial;
  final String? Function(String value)? validator;

  @override
  State<_PromptTextDialog> createState() => _PromptTextDialogState();
}

class _PromptTextDialogState extends State<_PromptTextDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final problem = widget.validator?.call(_controller.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.pop(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label, errorText: _error),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Asks whether the assistant may run a tool. Closing the dialog counts as no.
Future<bool> confirmToolDialog(
  BuildContext context,
  AssistantTool tool,
  Map<String, dynamic> args,
) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Allow this action?'),
      content: Text(tool.describeCall(args)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Deny'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Allow'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

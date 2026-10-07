import 'package:flutter/material.dart';

Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String? Function(String value)? validator,
}) {
  final controller = TextEditingController(text: initial);
  String? error;

  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label, errorText: error),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final problem = validator?.call(controller.text);
              if (problem != null) {
                setState(() => error = problem);
                return;
              }
              Navigator.pop(ctx, controller.text);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    ),
  );
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

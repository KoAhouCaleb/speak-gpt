import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/model_list_client.dart';
import '../services/storage.dart';

class ChatSettingsScreen extends StatefulWidget {
  const ChatSettingsScreen({super.key, this.chat});

  /// The chat to edit, or null to edit the defaults copied into new chats.
  final ChatInfo? chat;

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  late final Storage _storage;
  late ChatSettings _s;
  late final TextEditingController _model;
  late final TextEditingController _system;
  late final TextEditingController _name;
  late final TextEditingController _seed;
  late final TextEditingController _maxTokens;
  late final TextEditingController _prefix;
  late final TextEditingController _endSeparator;
  bool _loadingModels = false;

  @override
  void initState() {
    super.initState();
    _storage = context.read<Storage>();
    _s = widget.chat == null
        ? _storage.defaultChatSettings
        : _storage.chatSettings(widget.chat!.id);
    _model = TextEditingController(text: _s.model);
    _system = TextEditingController(text: _s.systemMessage);
    _name = TextEditingController(text: _s.assistantName);
    _seed = TextEditingController(text: _s.seed);
    _maxTokens = TextEditingController(text: '${_s.maxTokens}');
    _prefix = TextEditingController(text: _s.prefix);
    _endSeparator = TextEditingController(text: _s.endSeparator);
  }

  @override
  void dispose() {
    _save();
    for (final c in [
      _model,
      _system,
      _name,
      _seed,
      _maxTokens,
      _prefix,
      _endSeparator,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    _s
      ..model = _model.text.trim().isEmpty ? _s.model : _model.text.trim()
      ..systemMessage = _system.text
      ..assistantName = _name.text.trim().isEmpty ? 'Grace' : _name.text.trim()
      ..seed = _seed.text.trim()
      ..maxTokens = int.tryParse(_maxTokens.text.trim()) ?? _s.maxTokens
      // Not trimmed: a trailing space or newline is often the point of a separator
      ..prefix = _prefix.text
      ..endSeparator = _endSeparator.text;
    if (widget.chat == null) {
      _storage.saveDefaultChatSettings(_s);
    } else {
      _storage.saveChatSettings(widget.chat!.id, _s);
    }
  }

  Future<void> _pickModel() async {
    final endpoint = _storage.endpointById(_s.endpointId);
    if (endpoint == null) return;
    setState(() => _loadingModels = true);
    try {
      final models = await ModelListClient.fetchModels(
        endpoint.host,
        endpoint.apiKey,
      );
      if (!mounted) return;
      final picked = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (ctx, controller) => ListView.builder(
            controller: controller,
            itemCount: models.length,
            itemBuilder: (ctx, i) => ListTile(
              title: Text(models[i]),
              selected: models[i] == _model.text,
              onTap: () => Navigator.pop(ctx, models[i]),
            ),
          ),
        ),
      );
      if (picked != null) setState(() => _model.text = picked);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not load models: $e')));
      }
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final endpoints = _storage.endpoints;
    final selected = endpoints.any((e) => e.id == _s.endpointId)
        ? _s.endpointId
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.chat == null ? 'Default chat settings' : 'Chat settings',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            initialValue: selected,
            decoration: const InputDecoration(
              labelText: 'API endpoint',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final e in endpoints)
                DropdownMenuItem(value: e.id, child: Text(e.label)),
            ],
            onChanged: (v) =>
                setState(() => _s.endpointId = v ?? _s.endpointId),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _model,
            decoration: InputDecoration(
              labelText: 'Model',
              border: const OutlineInputBorder(),
              suffixIcon: _loadingModels
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      tooltip: 'Load models from endpoint',
                      icon: const Icon(Icons.list),
                      onPressed: _pickModel,
                    ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Assistant name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _system,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'System message',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _prefix,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Message prefix',
              helperText:
                  'Put before every message you send. Not shown in the chat.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _endSeparator,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'End separator',
              helperText:
                  'Put after every message you send. Not shown in the chat.',
              border: OutlineInputBorder(),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Tools'),
            subtitle: const Text(
              'Send Grace\'s own tools (search, navigation, calls, apps...) to the model. '
              'Choose which ones in Settings > Tools. The model must support function calling. '
              'When this is off no tools are sent, and a server that adds tools of its own (such as Open WebUI) '
              'will offer the model those instead.',
            ),
            value: _s.functionCalling,
            onChanged: (v) => setState(() => _s.functionCalling = v),
          ),
          DropdownButtonFormField<String>(
            initialValue: _storage.logitBiasSetById(_s.logitBiasSetId) == null
                ? ''
                : _s.logitBiasSetId,
            decoration: const InputDecoration(
              labelText: 'Logit bias set',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(value: '', child: Text('None')),
              for (final set in _storage.logitBiasSets)
                DropdownMenuItem(value: set.id, child: Text(set.name)),
            ],
            onChanged: (v) => setState(() => _s.logitBiasSetId = v ?? ''),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Silent mode'),
            subtitle: const Text(
              'Do not read answers aloud after dictated messages',
            ),
            value: _s.silentMode,
            onChanged: (v) => setState(() => _s.silentMode = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Always speak'),
            subtitle: const Text(
              'Read every answer aloud, also after typed messages. Wins over silent mode.',
            ),
            value: _s.alwaysSpeak,
            onChanged: (v) => setState(() => _s.alwaysSpeak = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('/imagine command'),
            subtitle: const Text(
              'A message that starts with /imagine generates an image',
            ),
            value: _s.imagineCommand,
            onChanged: (v) => setState(() => _s.imagineCommand = v),
          ),
          const SizedBox(height: 24),
          _slider(
            'Temperature',
            _s.temperature,
            0,
            2,
            (v) => _s.temperature = v,
          ),
          _slider('Top P', _s.topP, 0, 1, (v) => _s.topP = v),
          _slider(
            'Frequency penalty',
            _s.frequencyPenalty,
            -2,
            2,
            (v) => _s.frequencyPenalty = v,
          ),
          _slider(
            'Presence penalty',
            _s.presencePenalty,
            -2,
            2,
            (v) => _s.presencePenalty = v,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _seed,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'-?\d*')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Seed (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _maxTokens,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Max tokens',
                    helperText: '0 = server default',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${value.toStringAsFixed(2)}'),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: ((max - min) * 20).round(),
          onChanged: (v) =>
              setState(() => onChanged(double.parse(v.toStringAsFixed(2)))),
        ),
      ],
    );
  }
}

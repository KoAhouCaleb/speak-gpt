import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/speech_server_client.dart';
import '../services/speech_service.dart';
import '../services/storage.dart';

/// Configure self-hosted speech to text and text to speech servers.
class SpeechServersScreen extends StatelessWidget {
  const SpeechServersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Speech servers')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          Text(
            'Use your own OpenAI-compatible servers for voice. When a server is on, it replaces the built-in '
            'engine. Plain http addresses and certificates from a private certificate authority installed on '
            'this device are supported.',
          ),
          SizedBox(height: 16),
          _ServerCard(type: Storage.speechStt),
          SizedBox(height: 16),
          _ServerCard(type: Storage.speechTts),
        ],
      ),
    );
  }
}

class _ServerCard extends StatefulWidget {
  const _ServerCard({required this.type});

  final String type;

  @override
  State<_ServerCard> createState() => _ServerCardState();
}

class _ServerCardState extends State<_ServerCard> {
  late final Storage _storage;
  late SpeechServerConfig _config;
  late final TextEditingController _host;
  late final TextEditingController _key;
  late final TextEditingController _model;
  late final TextEditingController _voice;
  late final TextEditingController _language;
  bool _busy = false;
  String? _status;

  bool get _isStt => widget.type == Storage.speechStt;

  @override
  void initState() {
    super.initState();
    _storage = context.read<Storage>();
    _config = _storage.speechServer(widget.type);
    _host = TextEditingController(
      text: _config.host.isEmpty
          ? (_isStt
                ? 'http://192.168.1.2:8000/v1/'
                : 'http://192.168.1.2:8880/v1/')
          : _config.host,
    );
    _key = TextEditingController(text: _config.apiKey);
    _model = TextEditingController(text: _config.model);
    _voice = TextEditingController(text: _config.voice);
    _language = TextEditingController(text: _config.language);
  }

  @override
  void dispose() {
    for (final c in [_host, _key, _model, _voice, _language]) {
      c.dispose();
    }
    super.dispose();
  }

  SpeechServerConfig _current() => SpeechServerConfig(
    enabled: _config.enabled,
    host: _host.text.trim(),
    apiKey: _key.text.trim(),
    model: _model.text.trim(),
    voice: _voice.text.trim(),
    language: _language.text.trim(),
  );

  Future<void> _save() async {
    _config = _current();
    await _storage.saveSpeechServer(widget.type, _config);
  }

  Future<void> _run(Future<String> Function() action) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await _save();
      final message = await action();
      if (mounted) setState(() => _status = message);
    } catch (e) {
      if (mounted) setState(() => _status = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadVoices() => _run(() async {
    final voices = await SpeechServerClient.listVoices(_config);
    if (!mounted || voices.isEmpty) return 'The server returned no voices.';
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, controller) => ListView.builder(
          controller: controller,
          itemCount: voices.length,
          itemBuilder: (ctx, i) => ListTile(
            title: Text(voices[i]),
            onTap: () => Navigator.pop(ctx, voices[i]),
          ),
        ),
      ),
    );
    if (picked != null) {
      _voice.text = picked;
      await _save();
    }
    return '${voices.length} voices found.';
  });

  Future<void> _testTts() => _run(() async {
    final speech = SpeechService(_storage);
    try {
      final error = await speech.speak(
        'This is Grace, speaking from your own server.',
      );
      return error == null ? 'Playing the sample.' : 'Failed: $error';
    } finally {
      // Let the sample play before the player is released
      Future<void>.delayed(const Duration(seconds: 15), speech.dispose);
    }
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                _isStt ? 'Speech to text server' : 'Text to speech server',
              ),
              subtitle: Text(
                _isStt ? 'POST /audio/transcriptions' : 'POST /audio/speech',
              ),
              value: _config.enabled,
              onChanged: (v) async {
                setState(() => _config.enabled = v);
                await _save();
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _host,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                helperText: 'Including /v1/',
                border: OutlineInputBorder(),
              ),
              onEditingComplete: _save,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API key (optional)',
                border: OutlineInputBorder(),
              ),
              onEditingComplete: _save,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _model,
              decoration: const InputDecoration(
                labelText: 'Model',
                border: OutlineInputBorder(),
              ),
              onEditingComplete: _save,
            ),
            const SizedBox(height: 12),
            if (_isStt)
              TextField(
                controller: _language,
                decoration: const InputDecoration(
                  labelText: 'Language (optional)',
                  helperText: 'For example en. Empty lets the server decide.',
                  border: OutlineInputBorder(),
                ),
                onEditingComplete: _save,
              )
            else
              TextField(
                controller: _voice,
                decoration: InputDecoration(
                  labelText: 'Voice',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Load voices from the server',
                    icon: const Icon(Icons.list),
                    onPressed: _busy ? null : _loadVoices,
                  ),
                ),
                onEditingComplete: _save,
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (!_isStt)
                  FilledButton.tonal(
                    onPressed: _busy ? null : _testTts,
                    child: const Text('Play a sample'),
                  ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(left: 16),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_status!),
              ),
          ],
        ),
      ),
    );
  }
}

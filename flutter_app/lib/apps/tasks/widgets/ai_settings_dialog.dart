import 'package:flutter/material.dart';
import '../services/agent_api_service.dart';

/// Lets a user bring their own LLM provider key (OpenAI, Gemini, Claude, or any
/// OpenAI-compatible endpoint). The key is stored encrypted on the server and
/// never displayed back in full.
class AiSettingsDialog extends StatefulWidget {
  const AiSettingsDialog({super.key});

  @override
  State<AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiProviderPreset {
  final String label;
  final String baseUrl;
  final String model;
  const _AiProviderPreset(this.label, this.baseUrl, this.model);
}

const _presets = <_AiProviderPreset>[
  _AiProviderPreset('OpenAI', 'https://api.openai.com/v1', 'gpt-4o-mini'),
  _AiProviderPreset('Google Gemini',
      'https://generativelanguage.googleapis.com/v1beta/openai/', 'gemini-2.0-flash'),
  _AiProviderPreset('Anthropic Claude',
      'https://api.anthropic.com/v1/', 'claude-sonnet-4-20250514'),
];

class _AiSettingsDialogState extends State<AiSettingsDialog> {
  final _keyCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _obscureKey = true;
  bool _usingOwnKey = false;
  String? _keyHint;
  String? _serverModel;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _baseUrlCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await AgentApiService.getSettings();
      if (!mounted) return;
      setState(() {
        _usingOwnKey = s['using_own_key'] == true;
        _keyHint = s['key_hint']?.toString();
        _serverModel = s['server_model']?.toString();
        _baseUrlCtrl.text = (s['base_url'] ?? '').toString();
        _modelCtrl.text = (s['model'] ?? '').toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _applyPreset(_AiProviderPreset p) {
    setState(() {
      _baseUrlCtrl.text = p.baseUrl;
      _modelCtrl.text = p.model;
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await AgentApiService.updateSettings(
        apiKey: _keyCtrl.text.isEmpty ? null : _keyCtrl.text.trim(),
        baseUrl: _baseUrlCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  Future<void> _clear() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await AgentApiService.clearSettings();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('AI provider settings'),
      content: SizedBox(
        width: 420,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _usingOwnKey
                          ? 'Using your own key${_keyHint != null ? ' ($_keyHint)' : ''}.'
                          : 'Using the shared server key (subject to the spending cap).',
                      style: TextStyle(color: Theme.of(context).colorScheme.primary),
                    ),
                    const SizedBox(height: 12),
                    const Text('Quick presets', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final p in _presets)
                          OutlinedButton(
                            onPressed: () => _applyPreset(p),
                            child: Text(p.label),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _keyCtrl,
                      obscureText: _obscureKey,
                      decoration: InputDecoration(
                        labelText: 'API key',
                        hintText: _usingOwnKey ? 'Leave blank to keep current key' : 'sk-…',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        suffixIcon: IconButton(
                          icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => _obscureKey = !_obscureKey),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _baseUrlCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Base URL',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _modelCtrl,
                      decoration: InputDecoration(
                        labelText: 'Model',
                        hintText: _serverModel ?? 'gpt-4o-mini',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Your key is stored encrypted and never shown again. When you '
                      'use your own key, you pay your provider directly and the shared '
                      'spending cap no longer applies to you.',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        if (_usingOwnKey)
          TextButton(
            onPressed: _saving ? null : _clear,
            child: const Text('Use server key'),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}

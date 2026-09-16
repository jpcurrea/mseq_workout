import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/widgets/agent_chat_panel.dart';
import '../../tasks/widgets/ai_settings_dialog.dart';
import '../services/workout_agent_api_service.dart';

/// Full-screen conversation with the workout coach agent.
///
/// The coach can search the exercise database, create/update workouts, log
/// scores and regenerate the m-sequence routine. Mutating tools can be gated
/// behind an approval step (on by default) so nothing changes without a tap.
class CoachScreen extends StatefulWidget {
  const CoachScreen({super.key});

  @override
  State<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends State<CoachScreen> {
  static const _approvalPrefsKey = 'workout_coach_require_approval';

  final List<AgentChatEntry> _entries = [];
  final List<Map<String, String>> _history = [];
  final ScrollController _scrollCtrl = ScrollController();

  bool _loading = false;
  bool _hasMemory = false;
  bool _requireApproval = true;

  /// Set to true when the coach changed data, so the previous screen can refresh.
  bool _dataChanged = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadConversation();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _requireApproval = prefs.getBool(_approvalPrefsKey) ?? true;
    });
  }

  Future<void> _setRequireApproval(bool value) async {
    setState(() => _requireApproval = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_approvalPrefsKey, value);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _loadConversation() async {
    try {
      final data = await WorkoutAgentApiService.getConversation();
      final msgs = data['messages'] as List<Map<String, dynamic>>? ?? [];
      if (!mounted) return;
      setState(() {
        _entries.clear();
        _history.clear();
        for (final m in msgs) {
          final role = m['role']?.toString() ?? 'user';
          final content = m['content']?.toString() ?? '';
          if (role == 'user' || role == 'assistant') {
            _entries.add(AgentChatEntry(role: role, content: content));
            _history.add({'role': role, 'content': content});
          }
        }
        _hasMemory = data['has_memory'] == true;
      });
      _scrollToBottom();
    } catch (_) {
      // Start a fresh conversation if history can't be loaded.
    }
  }

  Future<void> _clearConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear conversation?'),
        content: const Text(
          'This deletes the saved chat history and everything your coach '
          'remembers about you. Your workouts and schedule are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await WorkoutAgentApiService.clearConversation();
    if (!mounted) return;
    setState(() {
      _entries.clear();
      _history.clear();
      _hasMemory = false;
    });
  }

  Future<void> _send(String text) async {
    if (text.isEmpty) return;
    setState(() {
      _entries.add(AgentChatEntry(role: 'user', content: text));
      _history.add({'role': 'user', 'content': text});
      _loading = true;
    });
    _scrollToBottom();

    try {
      final resp = await WorkoutAgentApiService.chat(
        messages: List.from(_history),
        requireApproval: _requireApproval,
      );
      if (!mounted) return;
      setState(() {
        _entries.add(AgentChatEntry(role: 'assistant', content: resp.reply));
        _history.add({'role': 'assistant', 'content': resp.reply});
        _hasMemory = true; // the server persists the thread after each exchange
        _loading = false;
        if (resp.mutatedData) _dataChanged = true;
      });
      _scrollToBottom();

      if (resp.pendingApproval && resp.proposedToolCalls.isNotEmpty) {
        await _reviewProposedActions(resp.proposedToolCalls);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entries.add(AgentChatEntry(role: 'error', content: e.toString()));
        _loading = false;
      });
      _scrollToBottom();
    }
  }

  Future<void> _reviewProposedActions(
    List<Map<String, dynamic>> proposed,
  ) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Apply these changes?'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final call in proposed)
                ListTile(
                  dense: true,
                  leading: Icon(_iconForAction(call['name']?.toString())),
                  title: Text(_describeAction(call)),
                  subtitle: _isDestructive(call['name']?.toString())
                      ? const Text(
                          'Destructive',
                          style: TextStyle(color: Colors.redAccent),
                        )
                      : null,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Discard'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );

    if (approved != true) {
      if (!mounted) return;
      setState(() {
        _entries.add(const AgentChatEntry(
          role: 'error',
          content: 'Changes discarded — nothing was applied.',
        ));
      });
      _scrollToBottom();
      return;
    }

    try {
      final results = await WorkoutAgentApiService.applyActions(proposed);
      final ok = results.where((r) => r['ok'] == true).length;
      final failures =
          results.where((r) => r['ok'] != true).map((r) => r['error']).join('; ');
      if (!mounted) return;
      setState(() {
        if (ok > 0) _dataChanged = true;
        _entries.add(AgentChatEntry(
          role: failures.isEmpty ? 'assistant' : 'error',
          content: failures.isEmpty
              ? 'Applied $ok change(s).'
              : 'Applied $ok change(s). Problems: $failures',
        ));
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => _entries.add(AgentChatEntry(role: 'error', content: e.toString())));
      _scrollToBottom();
    }
  }

  static bool _isDestructive(String? action) =>
      action == 'delete_workout' || action == 'generate_routine';

  static IconData _iconForAction(String? action) {
    switch (action) {
      case 'create_workout':
        return Icons.add_circle_outline;
      case 'update_workout':
        return Icons.edit_outlined;
      case 'delete_workout':
        return Icons.delete_outline;
      case 'log_score':
        return Icons.check_circle_outline;
      case 'generate_routine':
        return Icons.event_repeat;
      default:
        return Icons.bolt_outlined;
    }
  }

  static String _describeAction(Map<String, dynamic> call) {
    final args = (call['args'] as Map?)?.cast<String, dynamic>() ?? const {};
    switch (call['name']) {
      case 'create_workout':
        return 'Add "${args['name']}" — ${args['goal']} ${args['units']}';
      case 'update_workout':
        final renamed = args['new_name'];
        final target = renamed == null ? args['name'] : '${args['name']} → $renamed';
        return 'Update $target';
      case 'delete_workout':
        return 'Delete "${args['name']}" and its scheduled sessions';
      case 'log_score':
        return 'Log ${args['score']} for "${args['workout']}" on ${args['date']}';
      case 'generate_routine':
        return 'Regenerate the whole schedule (erases existing sessions)';
      default:
        return '${call['name']} $args';
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _dataChanged);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Coach'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          actions: [
            IconButton(
              icon: Icon(_requireApproval ? Icons.lock_outline : Icons.lock_open),
              tooltip: _requireApproval
                  ? 'Approval required before changes'
                  : 'Coach applies changes immediately',
              onPressed: () => _setRequireApproval(!_requireApproval),
            ),
          ],
        ),
        body: AgentChatPanel(
          title: 'Workout Coach',
          entries: _entries,
          isLoading: _loading,
          isExpanded: true,
          fillHeight: true,
          hasMemory: _hasMemory,
          requiresApproval: _requireApproval,
          scrollController: _scrollCtrl,
          emptyStateHint:
              'Tell me your goals, the equipment you have, and how much time you '
              'can train.\nI\'ll build a routine around it.',
          onToggleExpand: () {},
          onSend: _send,
          onClear: _clearConversation,
          onOpenAiSettings: () => showDialog(
            context: context,
            builder: (_) => const AiSettingsDialog(),
          ),
        ),
      ),
    );
  }
}

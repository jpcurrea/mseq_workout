import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import '../models/task.dart';
import '../models/project.dart';
import '../services/task_api_service.dart';
import '../services/project_api_service.dart';
import '../services/agent_api_service.dart';
import '../widgets/task_card.dart';
import '../widgets/ai_settings_dialog.dart';
import 'task_form_screen.dart';

class TaskPlansScreen extends StatefulWidget {
  const TaskPlansScreen({super.key});

  @override
  State<TaskPlansScreen> createState() => _TaskPlansScreenState();
}

class _TaskPlansScreenState extends State<TaskPlansScreen> {
  List<PlanSummary> _plans = [];
  Project? _project;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final project = await ProjectApiService.getActiveProject();
      final plans = await TaskApiService.getPlans(projectId: project.id);
      setState(() { _project = project; _plans = plans; _isLoading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  void _navigateTo(String route) => Navigator.of(context).pushReplacementNamed(route);

  Future<void> _createPlan() async {
    final titleCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Plan'),
        content: TextField(
          controller: titleCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Plan title'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create')),
        ],
      ),
    );
    if (ok != true || titleCtrl.text.trim().isEmpty) return;
    try {
      final plan = await TaskApiService.createPlan(
        titleCtrl.text.trim(),
        projectId: _project!.id,
      );
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => _PlanEditorScreen(planId: plan.id, title: plan.title)),
        );
        _load();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _deletePlan(PlanSummary plan) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete plan?'),
        content: Text('Delete "${plan.title}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await TaskApiService.deletePlan(plan.id);
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _renamePlan(PlanSummary plan) async {
    final titleCtrl = TextEditingController(text: plan.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename Plan'),
        content: TextField(
          controller: titleCtrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, titleCtrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newTitle == null || newTitle.isEmpty || newTitle == plan.title) return;
    try {
      await TaskApiService.updatePlan(plan.id, title: newTitle);
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plans'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu),
            onSelected: (v) {
              if (v == 'plans') return;
              if (v == 'todo') {
                Navigator.of(context).pop();
              } else {
                _navigateTo('/tasks/$v');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'todo', child: ListTile(leading: Icon(Icons.check_circle_outline), title: Text('Todo'))),
              PopupMenuItem(value: 'calendar', child: ListTile(leading: Icon(Icons.calendar_month), title: Text('Calendar'))),
              PopupMenuItem(value: 'gantt', child: ListTile(leading: Icon(Icons.view_timeline), title: Text('Gantt'))),
              PopupMenuItem(value: 'plans', child: ListTile(leading: Icon(Icons.description_outlined), title: Text('Plans'))),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
              : _plans.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.description_outlined, size: 64, color: Colors.grey),
                          SizedBox(height: 16),
                          Text('No plans yet — tap + to create one', style: TextStyle(color: Colors.grey)),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: _plans.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (_, i) {
                        final plan = _plans[i];
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.description_outlined),
                            title: Text(plan.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              'Updated ${DateFormat('MMM d, y').format(plan.updatedAt)}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert),
                              onSelected: (v) {
                                if (v == 'rename') _renamePlan(plan);
                                if (v == 'delete') _deletePlan(plan);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename'))),
                                PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline, color: Colors.red), title: Text('Delete'))),
                              ],
                            ),
                            onTap: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => _PlanEditorScreen(planId: plan.id, title: plan.title),
                                ),
                              );
                              _load();
                            },
                          ),
                        );
                      },
                    ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createPlan,
        tooltip: 'New plan',
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ── Plan editor ───────────────────────────────────────────────────────────────

class _PlanEditorScreen extends StatefulWidget {
  final int planId;
  final String title;

  const _PlanEditorScreen({required this.planId, required this.title});

  @override
  State<_PlanEditorScreen> createState() => _PlanEditorScreenState();
}

class _PlanEditorScreenState extends State<_PlanEditorScreen> {
  Plan? _plan;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isEditMode = false;
  late final TextEditingController _contentCtrl;
  final _scrollCtrl = ScrollController();
  bool _hasChanges = false;
  String _timeUnit = 'hours';
  final Set<int> _activeSessions = {};
  TaskViewMode _previewViewMode = TaskViewMode.topLevelPreview;
  late final TextEditingController _chatCtrl;
  final List<_AgentChatEntry> _chatEntries = [];
  final _chatScrollCtrl = ScrollController();
  final List<_PendingAttachment> _pendingAttachments = [];
  bool _isSendingChat = false;
  bool _chatExpanded = false;
  bool _agentRequireApproval = true;
  bool _agentHasMemory = false;

  @override
  void initState() {
    super.initState();
    _contentCtrl = TextEditingController();
    _chatCtrl = TextEditingController();
    _load();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _timeUnit = p.getString('task_time_unit') ?? 'hours';
      _agentRequireApproval = p.getBool('task_agent_require_approval') ?? true;
    });
  }

  @override
  void dispose() {
    _contentCtrl.dispose();
    _chatCtrl.dispose();
    _scrollCtrl.dispose();
    _chatScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final plan = await TaskApiService.getPlan(widget.planId);
      setState(() {
        _plan = plan;
        _contentCtrl.text = plan.content;
        _isLoading = false;
      });
      await _restoreConversation();
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _restoreConversation() async {
    if (_plan == null) return;
    try {
      final convo = await AgentApiService.getConversation(
        mode: 'planning',
        projectId: _plan!.projectId,
        planId: _plan!.id,
      );
      final messages = (convo['messages'] as List?) ?? const [];
      if (messages.isEmpty) return;
      if (!mounted) return;
      setState(() {
        _chatEntries
          ..clear()
          ..addAll(messages.map((m) => _AgentChatEntry(
                role: (m['role'] ?? 'assistant').toString(),
                content: (m['content'] ?? '').toString(),
              )));
        _agentHasMemory = convo['has_memory'] == true;
      });
      _scrollChatToBottom();
    } catch (_) {
      // Non-fatal: a missing/failed restore just starts an empty chat.
    }
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScrollCtrl.hasClients) return;
      _chatScrollCtrl.jumpTo(_chatScrollCtrl.position.maxScrollExtent);
    });
  }

  Future<void> _copyMessage(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Message copied'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      await TaskApiService.updatePlan(widget.planId, content: _contentCtrl.text);
      setState(() { _hasChanges = false; _isSaving = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Plan saved'), duration: Duration(seconds: 1)),
        );
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _showHistory() async {
    List<Map<String, dynamic>> revisions;
    try {
      revisions = await TaskApiService.getPlanHistory(widget.planId);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      return;
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        builder: (_, sc) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  const Icon(Icons.history),
                  const SizedBox(width: 8),
                  Text('Save history (${revisions.length})',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const Divider(height: 1),
            if (revisions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text('No history yet — save the plan to start tracking changes.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey)),
              )
            else
              Expanded(
                child: ListView.separated(
                  controller: sc,
                  padding: const EdgeInsets.all(12),
                  itemCount: revisions.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final rev = revisions[i];
                    final savedAt = DateTime.tryParse(rev['saved_at'] ?? '') ?? DateTime.now();
                    final diff = (rev['diff'] as String? ?? '').trim();
                    final lines = diff.split('\n');
                    final added = lines.where((l) => l.startsWith('+')).length;
                    final removed = lines.where((l) => l.startsWith('-')).length;
                    return ExpansionTile(
                      leading: const Icon(Icons.save_outlined, size: 20),
                      title: Text(
                        _formatDateTime(savedAt),
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        '+$added  −$removed lines',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(ctx).colorScheme.secondary,
                        ),
                      ),
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                          child: SelectableText(
                            diff,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: Theme.of(ctx).colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);
    final timeStr = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (diff.inDays == 0) return 'Today $timeStr';
    if (diff.inDays == 1) return 'Yesterday $timeStr';
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} $timeStr';
  }

  Future<void> _insertTaskWidget() async {
    List<Task> tasks = [];
    try {
      if (_plan != null) {
        tasks = await TaskApiService.getTasks(projectId: _plan!.projectId);
      }
    } catch (_) {}
    if (!mounted) return;

    final selected = await showDialog<Task>(
      context: context,
      builder: (_) => _TaskPickerDialog(tasks: tasks),
    );
    if (selected == null) return;

    final token = '{{task:${selected.id}}}';
    final pos = _contentCtrl.selection.baseOffset;
    final text = _contentCtrl.text;
    final newText = pos >= 0
        ? '${text.substring(0, pos)}$token${text.substring(pos)}'
        : '$text$token';
    _contentCtrl.text = newText;
    setState(() {
      // Make the inserted task renderable in the live preview immediately,
      // before the next save/reload repopulates the plan's task map.
      _plan?.tasks[selected.id.toString()] = selected;
      _hasChanges = true;
    });
  }

  IconData _previewModeIcon() {
    switch (_previewViewMode) {
      case TaskViewMode.topLevelPreview: return Icons.notes;
      case TaskViewMode.allPreview:      return Icons.format_list_bulleted;
      case TaskViewMode.allExpanded:     return Icons.view_agenda;
    }
  }

  String _previewModeLabel() {
    switch (_previewViewMode) {
      case TaskViewMode.topLevelPreview: return 'Top-level only';
      case TaskViewMode.allPreview:      return 'All levels (compact)';
      case TaskViewMode.allExpanded:     return 'All levels (expanded)';
    }
  }

  // ── Preview: task operations ───────────────────────────────────────────────

  Future<void> _toggleComplete(Task task) async {
    try {
      await TaskApiService.toggleComplete(task.id);
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _openTaskEditor(Task task) async {
    if (_plan == null) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TaskFormScreen(
          editTask: task,
          projectId: _plan!.projectId,
        ),
      ),
    );
    if (saved == true) await _load();
  }

  Future<void> _startSession(Task task) async {
    try {
      await TaskApiService.startSession(task.id);
      setState(() => _activeSessions.add(task.id));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _stopSession(Task task) async {
    try {
      await TaskApiService.stopSession(task.id);
      setState(() => _activeSessions.remove(task.id));
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _openAiSettings() async {
    await showDialog<bool>(
      context: context,
      builder: (_) => const AiSettingsDialog(),
    );
  }

  Future<void> _pickAttachments() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
        type: FileType.custom,
        allowedExtensions: const [
          'pdf', 'txt', 'md', 'markdown', 'csv', 'json', 'log', 'yaml', 'yml', 'tsv',
          'png', 'jpg', 'jpeg', 'webp', 'gif',
        ],
      );
      if (result == null) return;
      const maxBytes = 10 * 1024 * 1024;
      final added = <_PendingAttachment>[];
      final skipped = <String>[];
      for (final f in result.files) {
        final bytes = f.bytes;
        if (bytes == null) {
          skipped.add('${f.name} (unreadable)');
          continue;
        }
        if (bytes.length > maxBytes) {
          skipped.add('${f.name} (>10 MB)');
          continue;
        }
        added.add(_PendingAttachment(
          filename: f.name,
          bytes: bytes,
          mimeType: _mimeForExtension(f.extension),
        ));
      }
      if (added.isNotEmpty) {
        setState(() {
          final room = 5 - _pendingAttachments.length;
          _pendingAttachments.addAll(added.take(room < 0 ? 0 : room));
        });
      }
      if (mounted && skipped.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Skipped: ${skipped.join(', ')}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not pick files: $e')));
      }
    }
  }

  String? _mimeForExtension(String? ext) {
    switch ((ext ?? '').toLowerCase()) {
      case 'pdf':
        return 'application/pdf';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'txt':
      case 'log':
        return 'text/plain';
      case 'md':
      case 'markdown':
        return 'text/markdown';
      case 'csv':
        return 'text/csv';
      case 'json':
        return 'application/json';
      default:
        return null;
    }
  }

  Future<void> _sendAgentMessage() async {
    final text = _chatCtrl.text.trim();
    if ((text.isEmpty && _pendingAttachments.isEmpty) || _plan == null || _isSendingChat) {
      return;
    }

    if (_isEditMode && _hasChanges) {
      await _save();
    }

    final attachments = _pendingAttachments
        .map((a) => {
              'filename': a.filename,
              if (a.mimeType != null) 'mime_type': a.mimeType,
              'data_base64': base64Encode(a.bytes),
            })
        .toList();
    final attachmentNames = _pendingAttachments.map((a) => a.filename).toList();
    final displayText = attachmentNames.isEmpty
        ? text
        : (text.isEmpty
            ? '📎 ${attachmentNames.join(', ')}'
            : '$text\n📎 ${attachmentNames.join(', ')}');

    setState(() {
      _chatEntries.add(_AgentChatEntry(role: 'user', content: displayText));
      _chatCtrl.clear();
      _pendingAttachments.clear();
      _isSendingChat = true;
    });
    _scrollChatToBottom();

    try {
      final payloadMessages = _chatEntries
          .where((m) => m.role == 'user' || m.role == 'assistant')
          .map((m) => {'role': m.role, 'content': m.content})
          .toList();

      final res = await AgentApiService.planningChat(
        projectId: _plan!.projectId,
        planId: _plan!.id,
        messages: payloadMessages,
        requireApproval: _agentRequireApproval,
        attachments: attachments,
      );

      setState(() {
        _chatEntries.add(_AgentChatEntry(role: 'assistant', content: res.reply));
      });
      _scrollChatToBottom();

      if (res.attachmentNotes.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.attachmentNotes.join('\n'))),
        );
      }

      if (res.pendingApproval && res.proposedToolCalls.isNotEmpty) {
        final approved = await _confirmApplyToolCalls(res.proposedToolCalls);
        if (approved == true) {
          final applied = await AgentApiService.applyPlanningActions(
            projectId: _plan!.projectId,
            planId: _plan!.id,
            toolCalls: res.proposedToolCalls,
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Applied ${applied.length} approved agent action(s).')),
            );
          }
          try {
            await _load();
          } catch (_) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Reply received, but refresh failed. Pull to refresh if needed.')),
              );
            }
          }
          setState(() => _hasChanges = false);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Agent changes were not applied.')),
            );
          }
        }
        return;
      }

      if (res.actions.any((a) => a['ok'] == true)) {
        try {
          await _load();
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Reply received, but refresh failed. Pull to refresh if needed.')),
            );
          }
        }
        setState(() {
          _hasChanges = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) {
        setState(() => _isSendingChat = false);
      }
    }
  }

  String _describeProposedCall(Map<String, dynamic> call) {
    final name = (call['name'] ?? '').toString();
    final args = call['args'] is Map<String, dynamic>
        ? call['args'] as Map<String, dynamic>
        : <String, dynamic>{};

    switch (name) {
      case 'create_task':
        return 'Create task: ${args['title'] ?? '(untitled)'}';
      case 'update_task':
        return 'Update task #${args['task_id'] ?? '?'}';
      case 'delete_task':
        return 'Delete task #${args['task_id'] ?? '?'}';
      case 'write_plan':
        return 'Write plan content${args['append'] == true ? ' (append)' : ''}';
      case 'create_plan':
        return 'Create plan: ${args['title'] ?? '(untitled)'}';
      case 'insert_task_into_plan':
        return 'Embed task #${args['task_id'] ?? '?'} into plan';
      default:
        return '$name ${args.isNotEmpty ? args.toString() : ''}'.trim();
    }
  }

  Future<bool?> _confirmApplyToolCalls(List<Map<String, dynamic>> calls) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve Agent Changes'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('The agent proposed these actions:'),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: calls.length,
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.bolt, size: 16),
                    title: Text(_describeProposedCall(calls[i])),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Approve & Apply')),
        ],
      ),
    );
  }

  Future<void> _showAgentSettings() async {
    bool requireApproval = _agentRequireApproval;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('Settings'),
          content: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Require approval before agent changes'),
            subtitle: const Text('When on, the agent proposes changes and waits for your approval.'),
            value: requireApproval,
            onChanged: (v) => setDlgState(() => requireApproval = v),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );

    if (saved == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('task_agent_require_approval', requireApproval);
      if (!mounted) return;
      setState(() => _agentRequireApproval = requireApproval);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _showAgentSettings,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Save history',
            onPressed: _showHistory,
          ),
          // Edit / Preview toggle
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isEditMode ? Icons.edit_outlined : Icons.preview_outlined,
                size: 16,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 4),
              Switch(
                value: _isEditMode,
                onChanged: (val) {
                  if (!val && _hasChanges) _save();
                  setState(() => _isEditMode = val);
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: 4),
            ],
          ),
          // View-mode toggle (only in preview)
          if (!_isEditMode)
            IconButton(
              icon: Icon(_previewModeIcon()),
              tooltip: _previewModeLabel(),
              onPressed: () => setState(() {
                _previewViewMode = TaskViewMode.values[
                  (_previewViewMode.index + 1) % TaskViewMode.values.length
                ];
              }),
            ),
          if (_isEditMode && _plan != null)
            IconButton(
              icon: const Icon(Icons.add_box_outlined),
              tooltip: 'Insert task widget',
              onPressed: _insertTaskWidget,
            ),
          if (_isEditMode && _hasChanges)
            _isSaving
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    icon: const Icon(Icons.save),
                    tooltip: 'Save',
                    onPressed: _save,
                  ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: _isEditMode ? _buildEditor() : _buildPreview(),
                ),
                _buildAgentChatBox(),
              ],
            ),
    );
  }

  Widget _buildAgentChatBox() {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        color: theme.colorScheme.surface,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _chatExpanded = !_chatExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome_outlined, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Planning Agent',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (_agentRequireApproval)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text('Approval On', style: TextStyle(fontSize: 11)),
                    ),
                  if (_agentHasMemory) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Earlier turns are summarized into memory',
                      child: Icon(Icons.psychology_outlined,
                          size: 16, color: theme.colorScheme.primary),
                    ),
                  ],
                  if (_isSendingChat)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  IconButton(
                    icon: const Icon(Icons.tune, size: 18),
                    tooltip: 'AI provider settings',
                    visualDensity: VisualDensity.compact,
                    onPressed: _openAiSettings,
                  ),
                  const SizedBox(width: 8),
                  Icon(_chatExpanded ? Icons.expand_more : Icons.chevron_right),
                ],
              ),
            ),
          ),
          if (_chatExpanded) ...[
            SizedBox(
              height: 180,
              child: _chatEntries.isEmpty
                  ? const Center(
                      child: Text(
                        'Ask me to create tasks, edit tasks, or rewrite this plan.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      controller: _chatScrollCtrl,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      itemCount: _chatEntries.length,
                      itemBuilder: (_, i) {
                        final m = _chatEntries[i];
                        final isUser = m.role == 'user';
                        return Align(
                          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                          child: GestureDetector(
                            onLongPress: () => _copyMessage(m.content),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              constraints: const BoxConstraints(maxWidth: 560),
                              decoration: BoxDecoration(
                                color: isUser
                                    ? theme.colorScheme.primaryContainer
                                    : theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: SelectableText(
                                m.content,
                                contextMenuBuilder: (context, editableState) {
                                  return AdaptiveTextSelectionToolbar.editableText(
                                    editableTextState: editableState,
                                  );
                                },
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_pendingAttachments.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (int i = 0; i < _pendingAttachments.length; i++)
                            Chip(
                              avatar: const Icon(Icons.attach_file, size: 16),
                              label: Text(
                                _pendingAttachments[i].filename,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onDeleted: _isSendingChat
                                  ? null
                                  : () => setState(() => _pendingAttachments.removeAt(i)),
                            ),
                        ],
                      ),
                    ),
                  Row(
                    children: [
                      IconButton(
                        onPressed: (_isSendingChat || _pendingAttachments.length >= 5)
                            ? null
                            : _pickAttachments,
                        icon: const Icon(Icons.attach_file),
                        tooltip: 'Attach files (PDF, text, images)',
                      ),
                      Expanded(
                        child: Focus(
                          onKeyEvent: (node, event) {
                            if (event is KeyDownEvent &&
                                event.logicalKey == LogicalKeyboardKey.enter &&
                                !HardwareKeyboard.instance.isShiftPressed) {
                              if (!_isSendingChat) _sendAgentMessage();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          child: TextField(
                            controller: _chatCtrl,
                            minLines: 1,
                            maxLines: 4,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            decoration: const InputDecoration(
                              hintText: 'Example: Break this plan into 6 tasks and insert task widgets.',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _isSendingChat ? null : _sendAgentMessage,
                        icon: const Icon(Icons.send),
                        tooltip: 'Send to planning agent',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: _contentCtrl,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: const InputDecoration(
          hintText: 'Write your plan here...\n\nUse the ⊞ button to embed task widgets as {{task:ID}}.',
          border: OutlineInputBorder(),
        ),
        onChanged: (_) => setState(() => _hasChanges = true),
      ),
    );
  }

  Widget _buildPreview() {
    if (_plan == null) return const SizedBox();
    return _PlanPreviewView(
      content: _contentCtrl.text,
      tasks: _plan!.tasks,
      activeSessions: _activeSessions,
      timeUnit: _timeUnit,
      viewMode: _previewViewMode,
      onComplete: _toggleComplete,
      onStartSession: _startSession,
      onStopSession: _stopSession,
      onEdit: _openTaskEditor,
    );
  }
}

// ── Plan preview (rendered markdown + interactive task widgets) ────────────────

/// Splits plan content on {{task:ID}} tokens.
/// Text segments → MarkdownBody; task tokens → interactive TaskCardTree.
class _PlanPreviewView extends StatelessWidget {
  final String content;
  final Map<String, Task> tasks;
  final Set<int> activeSessions;
  final String timeUnit;
  final TaskViewMode viewMode;
  final Future<void> Function(Task) onComplete;
  final Future<void> Function(Task) onStartSession;
  final Future<void> Function(Task) onStopSession;
  final Future<void> Function(Task) onEdit;

  const _PlanPreviewView({
    required this.content,
    required this.tasks,
    required this.activeSessions,
    required this.timeUnit,
    required this.viewMode,
    required this.onComplete,
    required this.onStartSession,
    required this.onStopSession,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final widgets = _parse(context);
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: widgets.length,
      itemBuilder: (_, i) => widgets[i],
    );
  }

  List<Widget> _parse(BuildContext context) {
    final result = <Widget>[];
    final tokenRegex = RegExp(r'\{\{task:(\d+)\}\}');
    int lastEnd = 0;

    for (final match in tokenRegex.allMatches(content)) {
      if (match.start > lastEnd) {
        final text = content.substring(lastEnd, match.start);
        if (text.trim().isNotEmpty) {
          result.add(Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: MarkdownBody(
              data: text,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
            ),
          ));
        }
      }

      final taskId = match.group(1)!;
      final task = tasks[taskId];
      if (task != null) {
        result.add(Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TaskCardTree(
            task: task,
            activeSessions: {for (final id in activeSessions) id: true},
            viewMode: viewMode,
            timeUnit: timeUnit,
            onComplete: (t) { onComplete(t); },
            onStartSession: (t) { onStartSession(t); },
            onStopSession: (t) { onStopSession(t); },
            onEdit: (t) { onEdit(t); },
          ),
        ));
      } else {
        result.add(Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey[300]!),
            ),
            child: Text('Task #$taskId not found',
                style: TextStyle(color: Colors.grey[500], fontSize: 12)),
          ),
        ));
      }

      lastEnd = match.end;
    }

    if (lastEnd < content.length) {
      final text = content.substring(lastEnd);
      if (text.trim().isNotEmpty) {
        result.add(MarkdownBody(
          data: text,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
        ));
      }
    }

    if (result.isEmpty) {
      return [
        const Center(
          child: Padding(
            padding: EdgeInsets.only(top: 48),
            child: Text('Nothing to preview yet.', style: TextStyle(color: Colors.grey)),
          ),
        ),
      ];
    }

    return result;
  }
}

// ── Task picker dialog ────────────────────────────────────────────────────────

class _TaskPickerDialog extends StatefulWidget {
  final List<Task> tasks;
  const _TaskPickerDialog({required this.tasks});

  @override
  State<_TaskPickerDialog> createState() => _TaskPickerDialogState();
}

class _TaskPickerDialogState extends State<_TaskPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.tasks
        .where((t) => t.title.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return AlertDialog(
      title: const Text('Insert task'),
      content: SizedBox(
        width: 300,
        height: 320,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Search tasks...', prefixIcon: Icon(Icons.search)),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (_, i) => ListTile(
                  title: Text(filtered[i].title),
                  subtitle: filtered[i].dueDate != null
                      ? Text(DateFormat('MMM d').format(filtered[i].dueDate!))
                      : null,
                  onTap: () => Navigator.pop(context, filtered[i]),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    );
  }
}

class _AgentChatEntry {
  final String role;
  final String content;

  const _AgentChatEntry({required this.role, required this.content});
}

class _PendingAttachment {
  final String filename;
  final Uint8List bytes;
  final String? mimeType;

  const _PendingAttachment({
    required this.filename,
    required this.bytes,
    this.mimeType,
  });
}

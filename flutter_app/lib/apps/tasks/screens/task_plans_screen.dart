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
import '../widgets/task_list_view.dart';
import '../widgets/ai_settings_dialog.dart';
import 'task_form_screen.dart';

/// Shows a persistent error dialog with a Copy button.
void _showError(BuildContext context, String message) {
  showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade700),
          const SizedBox(width: 8),
          const Text('Error'),
        ],
      ),
      content: SingleChildScrollView(
        child: SelectableText(
          message,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('Copy'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: message));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Error copied'), duration: Duration(seconds: 1)),
            );
          },
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

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
      if (mounted) _showError(context, e.toString());
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
      if (mounted) _showError(context, e.toString());
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
      if (mounted) _showError(context, e.toString());
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
      if (mounted) _showError(context, e.toString());
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
      if (mounted) _showError(context, e.toString());
    }
  }

  Future<void> _showHistory() async {
    List<Map<String, dynamic>> revisions;
    try {
      revisions = await TaskApiService.getPlanHistory(widget.planId);
    } catch (e) {
      if (mounted) _showError(context, e.toString());
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

  /// Entry point for the toolbar "+" button. If the caret sits inside an
  /// existing `{{tasklist ...}}` block, a chosen task is appended to that block.
  /// Otherwise the user picks whether to insert a single task or a task-list.
  Future<void> _onInsertPressed() async {
    if (_plan == null) return;
    final blockRange = _enclosingTaskListRange(_contentCtrl.selection.baseOffset);
    if (blockRange != null) {
      final task = await _pickOrCreateTask();
      if (task != null) _addTaskToList(blockRange, task);
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.check_box_outlined),
              title: const Text('Insert task'),
              subtitle: const Text('Embed a single interactive task card'),
              onTap: () => Navigator.pop(context, 'task'),
            ),
            ListTile(
              leading: const Icon(Icons.format_list_bulleted),
              title: const Text('Insert task-list'),
              subtitle: const Text('A sortable, draggable list of tasks'),
              onTap: () => Navigator.pop(context, 'tasklist'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'task') {
      final task = await _pickOrCreateTask();
      if (task != null) _insertTaskToken(task);
    } else if (choice == 'tasklist') {
      _insertTaskListBlock();
    }
  }

  /// Shows the task picker (existing tasks + "create new") and returns the
  /// chosen or newly created [Task], or null if cancelled.
  Future<Task?> _pickOrCreateTask() async {
    List<Task> tasks = [];
    try {
      if (_plan != null) {
        tasks = await TaskApiService.getTasks(projectId: _plan!.projectId);
      }
    } catch (_) {}
    if (!mounted) return null;

    final result = await showDialog<Object>(
      context: context,
      builder: (_) => _TaskPickerDialog(tasks: tasks),
    );
    if (result == _kCreateNewTaskSentinel) {
      if (_plan == null || !mounted) return null;
      final created = await Navigator.of(context).push<Object>(
        MaterialPageRoute(
          builder: (_) => TaskFormScreen(
            projectId: _plan!.projectId,
            returnCreatedTask: true,
          ),
        ),
      );
      return created is Task ? created : null;
    }
    return result is Task ? result : null;
  }

  /// Returns the [start, end) character range of the `{{tasklist ...}}` block
  /// enclosing [offset], or null if the caret is not inside one.
  ({int start, int end})? _enclosingTaskListRange(int offset) {
    if (offset < 0) return null;
    final re = RegExp(r'\{\{tasklist[\s\S]*?\}\}');
    for (final m in re.allMatches(_contentCtrl.text)) {
      if (offset >= m.start && offset <= m.end) {
        return (start: m.start, end: m.end);
      }
    }
    return null;
  }

  /// Inserts an empty task-list block at the cursor and positions the caret
  /// inside it so subsequent inserts append to this block.
  void _insertTaskListBlock() {
    const header = '{{tasklist sort=manual\n';
    const footer = '}}';
    final block = '$header$footer';
    final pos = _contentCtrl.selection.baseOffset;
    final text = _contentCtrl.text;
    final at = pos >= 0 ? pos : text.length;
    final newText = '${text.substring(0, at)}$block${text.substring(at)}';
    _contentCtrl.text = newText;
    // Place caret just after the header newline (inside the block).
    final caret = at + header.length;
    _contentCtrl.selection = TextSelection.collapsed(offset: caret);
    setState(() => _hasChanges = true);
  }

  /// Appends a `- task:ID  Title` line just before the closing `}}` of the
  /// task-list block at [range], and registers the task for live preview.
  void _addTaskToList(({int start, int end}) range, Task task) {
    final text = _contentCtrl.text;
    final block = text.substring(range.start, range.end);
    final closeRel = block.lastIndexOf('}}');
    if (closeRel < 0) return;
    final closeAbs = range.start + closeRel;
    // Ensure the inserted line starts on its own line.
    final before = text.substring(0, closeAbs);
    final needsNewline = before.isNotEmpty && !before.endsWith('\n');
    final line = '${needsNewline ? '\n' : ''}- task:${task.id}  ${task.title}\n';
    final newText = '$before$line${text.substring(closeAbs)}';
    _contentCtrl.text = newText;
    setState(() {
      _plan?.tasks[task.id.toString()] = task;
      _hasChanges = true;
    });
  }

  /// Inserts a `{{task:ID}}` widget token for [task] at the cursor and makes it
  /// renderable in the live preview immediately.
  void _insertTaskToken(Task task) {
    final token = '{{task:${task.id}}}';
    final pos = _contentCtrl.selection.baseOffset;
    final text = _contentCtrl.text;
    final newText = pos >= 0
        ? '${text.substring(0, pos)}$token${text.substring(pos)}'
        : '$text$token';
    _contentCtrl.text = newText;
    setState(() {
      // Make the inserted task renderable in the live preview immediately,
      // before the next save/reload repopulates the plan's task map.
      _plan?.tasks[task.id.toString()] = task;
      _hasChanges = true;
    });
  }

  /// Persists a new manual order for tasks reordered inside an embedded
  /// task-list, then refreshes the plan's task map to reflect new sort values.
  Future<void> _reorderPlanTasks(List<int> orderedIds) async {
    if (_plan == null) return;
    try {
      await TaskApiService.reorderTasks(
        projectId: _plan!.projectId,
        orderedIds: orderedIds,
      );
      await _refreshPlanTasks();
    } catch (e) {
      if (mounted) _showError(context, e.toString());
    }
  }

  /// Re-fetches the plan to refresh its embedded task map (e.g. after a
  /// reorder) without disturbing the editor text.
  Future<void> _refreshPlanTasks() async {
    if (_plan == null) return;
    try {
      final fresh = await TaskApiService.getPlan(_plan!.id);
      if (!mounted) return;
      setState(() {
        _plan!.tasks
          ..clear()
          ..addAll(fresh.tasks);
      });
    } catch (_) {}
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
    String? note;
    if (!task.isCompleted) {
      final ctrl = TextEditingController();
      note = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('Complete "${task.title}"'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              hintText: 'Any observations or follow-ups…',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => Navigator.pop(context, ctrl.text.trim()),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Done'),
            ),
          ],
        ),
      );
      if (note == null) return;
    }
    try {
      await TaskApiService.toggleComplete(task.id, note: note?.isEmpty == true ? null : note);
      await _load();
    } catch (e) {
      if (mounted) _showError(context, e.toString());
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
      if (mounted) _showError(context, e.toString());
    }
  }

  Future<void> _stopSession(Task task) async {
    try {
      await TaskApiService.stopSession(task.id);
      setState(() => _activeSessions.remove(task.id));
      await _load();
    } catch (e) {
      if (mounted) _showError(context, e.toString());
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
      // Only send the most recent 20 turns — the backend stores older history
      // as a compressed summary, so replaying the full log bloats the request.
      const _maxSendMessages = 20;
      final allMessages = _chatEntries
          .where((m) => m.role == 'user' || m.role == 'assistant')
          .map((m) => {'role': m.role, 'content': m.content})
          .toList();
      final payloadMessages = allMessages.length > _maxSendMessages
          ? allMessages.sublist(allMessages.length - _maxSendMessages)
          : allMessages;

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
        _showError(context, e.toString());
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
    final resolvedTitle = (call['resolved_title'] ?? '').toString();

    switch (name) {
      case 'create_task':
        return 'Create task: "${args['title'] ?? '(untitled)'}"';
      case 'update_task':
        final fields = args.keys.where((k) => k != 'task_id').join(', ');
        return resolvedTitle.isNotEmpty
            ? 'Update task: "$resolvedTitle"${fields.isNotEmpty ? ' ($fields)' : ''}'
            : 'Update task #${args['task_id'] ?? '?'}${fields.isNotEmpty ? ' ($fields)' : ''}';
      case 'delete_task':
        return resolvedTitle.isNotEmpty
            ? 'DELETE: "$resolvedTitle"'
            : 'DELETE task #${args['task_id'] ?? '?'}';
      case 'write_plan':
        return 'Write plan content${args['append'] == true ? ' (append)' : ''}';
      case 'create_plan':
        return 'Create plan: "${args['title'] ?? '(untitled)'}"';
      case 'insert_task_into_plan':
        return 'Embed task #${args['task_id'] ?? '?'} into plan';
      default:
        return '$name ${args.isNotEmpty ? args.toString() : ''}'.trim();
    }
  }

  Future<bool?> _confirmApplyToolCalls(List<Map<String, dynamic>> calls) {
    final hasDestructive = calls.any((c) => c['name'] == 'delete_task');
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
              if (hasDestructive)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    border: Border.all(color: Colors.red.shade300),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.red.shade700, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'This includes permanent task deletions. Review carefully.',
                          style: TextStyle(color: Colors.red.shade800, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              const Text('The agent proposed these actions:'),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: calls.length,
                  itemBuilder: (_, i) {
                    final call = calls[i];
                    final isDelete = call['name'] == 'delete_task';
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        isDelete ? Icons.delete_forever : Icons.bolt,
                        size: 16,
                        color: isDelete ? Colors.red : null,
                      ),
                      title: Text(
                        _describeProposedCall(call),
                        style: isDelete
                            ? const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)
                            : null,
                      ),
                    );
                  },
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
              tooltip: 'Insert task or task-list',
              onPressed: _onInsertPressed,
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
            onTap: () {
              final wasCollapsed = !_chatExpanded;
              setState(() => _chatExpanded = !_chatExpanded);
              if (wasCollapsed) _scrollChatToBottom();
            },
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
    // NOTE: We deliberately avoid `expands: true` here. When the editable's
    // content is taller than the viewport, an expanding TextField scrolls
    // *internally*, and on mobile its tap→text-offset mapping drifts further
    // the lower you tap (the offset grows with distance down and only appears
    // once the text exceeds the screen). Instead we let the field size to its
    // content and scroll in an OUTER SingleChildScrollView, so the editable
    // never scrolls internally and hit-testing stays accurate. `minLines` is
    // derived from the viewport so the bordered box still fills the pane when
    // the plan is short.
    const lineHeightPx = 13.0 * 1.4; // fontSize * height
    return LayoutBuilder(
      builder: (context, constraints) {
        final usableHeight = constraints.maxHeight - 24; // vertical padding
        final minLines =
            usableHeight.isFinite && usableHeight > lineHeightPx
                ? (usableHeight / lineHeightPx).floor().clamp(1, 1000)
                : 1;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _contentCtrl,
            maxLines: null,
            minLines: minLines,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
            // Force a deterministic line-box height so the caret/tap hit-test
            // lines up with the rendered glyphs across platforms.
            strutStyle: const StrutStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.4,
              forceStrutHeight: true,
            ),
            decoration: const InputDecoration(
              hintText: 'Write your plan here...\n\nUse the ⊞ button to embed a task ({{task:ID}}) or a sortable task-list ({{tasklist ...}}).',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _hasChanges = true),
          ),
        );
      },
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
      onReorderTasks: _reorderPlanTasks,
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
  final Future<void> Function(List<int> orderedIds) onReorderTasks;

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
    required this.onReorderTasks,
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
    // Matches either a {{tasklist ...}} block (greedy until its closing }})
    // or a standalone {{task:ID}} token. Block is tried first via alternation.
    final tokenRegex = RegExp(r'\{\{tasklist[\s\S]*?\}\}|\{\{task:(\d+)\}\}');
    int lastEnd = 0;

    void addMarkdown(String text) {
      if (text.trim().isEmpty) return;
      result.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: MarkdownBody(
          data: text,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
        ),
      ));
    }

    for (final match in tokenRegex.allMatches(content)) {
      if (match.start > lastEnd) {
        addMarkdown(content.substring(lastEnd, match.start));
      }

      final raw = match.group(0)!;
      if (raw.startsWith('{{tasklist')) {
        result.add(Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _buildTaskList(context, raw),
        ));
      } else {
        result.add(Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _buildTaskCard(context, match.group(1)!),
        ));
      }

      lastEnd = match.end;
    }

    if (lastEnd < content.length) {
      addMarkdown(content.substring(lastEnd));
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

  /// Renders a single `{{task:ID}}` token as an interactive card.
  Widget _buildTaskCard(BuildContext context, String taskId) {
    final task = tasks[taskId];
    if (task == null) return _notFound(taskId);
    return TaskCardTree(
      task: task,
      activeSessions: {for (final id in activeSessions) id: true},
      viewMode: viewMode,
      timeUnit: timeUnit,
      onComplete: (t) { onComplete(t); },
      onStartSession: (t) { onStartSession(t); },
      onStopSession: (t) { onStopSession(t); },
      onEdit: (t) { onEdit(t); },
    );
  }

  /// Renders a `{{tasklist ...}}` block as an embedded, sortable task-list.
  Widget _buildTaskList(BuildContext context, String raw) {
    // Member task IDs, in document order.
    final ids = RegExp(r'task:(\d+)')
        .allMatches(raw)
        .map((m) => m.group(1)!)
        .toList();
    final members = <Task>[];
    final seen = <String>{};
    for (final id in ids) {
      if (!seen.add(id)) continue;
      final t = tasks[id];
      if (t != null) members.add(t);
    }

    // Honor an optional `sort=` directive on first render.
    final sortMatch = RegExp(r'sort=(\w+)').firstMatch(raw);
    final initialSort = _sortModeFromName(sortMatch?.group(1));

    // Unique tags drawn from the member tasks (and their subtasks).
    final tags = _collectTags(members);

    // Stable per-block preferences key from the first member id.
    final keySuffix = ids.isNotEmpty ? ids.first : 'empty';

    if (members.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey[300]!),
        ),
        child: Text('Empty task-list',
            style: TextStyle(color: Colors.grey[500], fontSize: 12)),
      );
    }

    return TaskListView(
      tasks: members,
      tags: tags,
      activeSessions: activeSessions,
      timeUnit: timeUnit,
      embedded: true,
      prefsKeyPrefix: 'plan_tasklist_$keySuffix',
      initialSortMode: initialSort,
      onComplete: (t) { onComplete(t); },
      onStartSession: (t) { onStartSession(t); },
      onStopSession: (t) { onStopSession(t); },
      onEdit: (t) { onEdit(t); },
      onReorder: (orderedIds) => onReorderTasks(orderedIds),
    );
  }

  TaskSortMode? _sortModeFromName(String? name) {
    if (name == null) return null;
    for (final m in TaskSortMode.values) {
      if (m.name == name) return m;
    }
    return null;
  }

  List<Tag> _collectTags(List<Task> tasks) {
    final byId = <int, Tag>{};
    void visit(Task t) {
      for (final tag in t.tags) {
        byId[tag.id] = tag;
      }
      for (final sub in t.subtasks) {
        visit(sub);
      }
    }
    for (final t in tasks) {
      visit(t);
    }
    return byId.values.toList();
  }

  Widget _notFound(String taskId) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Text('Task #$taskId not found',
          style: TextStyle(color: Colors.grey[500], fontSize: 12)),
    );
  }
}

// ── Task picker dialog ────────────────────────────────────────────────────────

/// Returned by [_TaskPickerDialog] when the user chooses to create a new task
/// rather than pick an existing one.
const Object _kCreateNewTaskSentinel = 'create_new_task';

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
            ListTile(
              leading: const Icon(Icons.add_task),
              title: const Text('Create new task'),
              onTap: () => Navigator.pop(context, _kCreateNewTaskSentinel),
            ),
            const Divider(height: 1),
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

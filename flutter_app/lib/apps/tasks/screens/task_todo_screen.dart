import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/task.dart';
import '../models/project.dart';
import '../services/task_api_service.dart';
import '../services/project_api_service.dart';
import '../services/agent_api_service.dart';
import '../widgets/task_list_view.dart';
import '../widgets/agent_chat_panel.dart';
import 'task_form_screen.dart';

class TaskTodoScreen extends StatefulWidget {
  const TaskTodoScreen({super.key});

  @override
  State<TaskTodoScreen> createState() => _TaskTodoScreenState();
}

class _TaskTodoScreenState extends State<TaskTodoScreen> {
  List<Task> _tasks = [];
  List<Tag> _tags = [];
  List<Project> _projects = [];
  Project? _activeProject;
  bool _isLoading = true;
  String? _error;
  bool _noProjects = false;
  bool _showCompleted = false;
  final Set<int> _activeSessions = {};
  final Set<int> _completingTaskIds = {};
  String _timeUnit = 'hours';
  bool _agentRequireApproval = true;

  /// The currently displayed (filtered + sorted) task list, mirrored from the
  /// embedded [TaskListView] so selection-mode "select all" can operate on it.
  List<Task> _visibleTasks = [];

  // ── Multi-select state ──────────────────────────────────────────────────────
  bool _selectionMode = false;
  final Set<int> _selectedTaskIds = {};

  // ── Agent (todo mode) state ─────────────────────────────────────────────────
  bool _agentExpanded = false;
  bool _agentLoading = false;
  bool _agentHasMemory = false;
  final List<AgentChatEntry> _agentEntries = [];
  final ScrollController _agentScrollCtrl = ScrollController();
  final List<Map<String, String>> _agentHistory = [];

  @override
  void initState() {
    super.initState();
    _loadPrefs().then((_) => _loadProjectThenTasks());
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _timeUnit = prefs.getString('task_time_unit') ?? 'hours';
      _agentRequireApproval = prefs.getBool('task_agent_require_approval') ?? true;
    });
  }

  @override
  void dispose() {
    _agentScrollCtrl.dispose();
    super.dispose();
  }

  // ── Agent helpers ───────────────────────────────────────────────────────────

  void _agentScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_agentScrollCtrl.hasClients) {
        _agentScrollCtrl.animateTo(
          _agentScrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _loadAgentConversation() async {
    if (_activeProject == null) return;
    try {
      final data = await AgentApiService.getConversation(
        mode: 'todo',
        projectId: _activeProject!.id,
      );
      final msgs = data['messages'] as List<Map<String, dynamic>>? ?? [];
      setState(() {
        _agentEntries.clear();
        _agentHistory.clear();
        for (final m in msgs) {
          final role = m['role']?.toString() ?? 'user';
          final content = m['content']?.toString() ?? '';
          if (role == 'user' || role == 'assistant') {
            _agentEntries.add(AgentChatEntry(role: role, content: content));
            _agentHistory.add({'role': role, 'content': content});
          }
        }
        _agentHasMemory = data['has_memory'] == true;
      });
      _agentScrollToBottom();
    } catch (_) {
      // silently fail — start fresh
    }
  }

  Future<void> _clearAgentConversation() async {
    if (_activeProject == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear conversation?'),
        content: const Text('This will delete the saved chat history.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed != true) return;
    await AgentApiService.clearConversation(mode: 'todo', projectId: _activeProject!.id);
    setState(() {
      _agentEntries.clear();
      _agentHistory.clear();
    });
  }

  Future<void> _sendAgentMessage(String text) async {
    if (_activeProject == null || text.isEmpty) return;
    setState(() {
      _agentEntries.add(AgentChatEntry(role: 'user', content: text));
      _agentHistory.add({'role': 'user', 'content': text});
      _agentLoading = true;
    });
    _agentScrollToBottom();
    try {
      final resp = await AgentApiService.todoChat(
        projectId: _activeProject!.id,
        messages: List.from(_agentHistory),
      );
      setState(() {
        _agentEntries.add(AgentChatEntry(role: 'assistant', content: resp.reply));
        _agentHistory.add({'role': 'assistant', 'content': resp.reply});
        _agentHasMemory = true; // server persists after first exchange
        _agentLoading = false;
      });
      // If agent modified tasks, reload the list.
      if (resp.actions.any((a) => a['ok'] == true)) {
        await _loadTasks();
      }
    } catch (e) {
      setState(() {
        _agentEntries.add(AgentChatEntry(role: 'error', content: e.toString()));
        _agentLoading = false;
      });
    }
    _agentScrollToBottom();
  }

  Future<void> _loadProjectThenTasks() async {
    setState(() { _isLoading = true; _error = null; _noProjects = false; });
    try {
      final results = await Future.wait([
        ProjectApiService.getActiveProject(),
        ProjectApiService.getProjects(),
      ]);
      _activeProject = results[0] as Project;
      _projects = results[1] as List<Project>;
      await _loadTasks();
    } catch (e) {
      final msg = e.toString();
      // Backend returns 404 with "No projects found" when user has no projects yet
      if (msg.contains('No projects found') || msg.contains('404')) {
        setState(() { _noProjects = true; _isLoading = false; });
      } else {
        setState(() { _error = msg; _isLoading = false; });
      }
    }
  }

  Future<void> _load() => _loadProjectThenTasks();

  /// Re-fetch tasks WITHOUT the full-screen loading spinner so the list,
  /// scroll position, and each card's expansion state are preserved. Used
  /// after session start/stop/restart where only individual cards change.
  Future<void> _quietRefreshTasks() async {
    if (_activeProject == null) return;
    try {
      final tasks = await TaskApiService.getTasks(
        projectId: _activeProject!.id,
        includeCompleted: _showCompleted,
      );
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _activeSessions
          ..clear()
          ..addAll(_collectActiveSessionIds(_tasks));
      });
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  Future<void> _loadTasks() async {
    if (_activeProject == null) return;
    setState(() { _isLoading = true; _error = null; });
    try {
      final results = await Future.wait([
        TaskApiService.getTasks(
          projectId: _activeProject!.id,
          includeCompleted: _showCompleted,
        ),
        TaskApiService.getTags(projectId: _activeProject!.id),
      ]);
      setState(() {
        _tasks = results[0] as List<Task>;
        _tags = results[1] as List<Tag>;
        // Derive active-session state from the backend so a session started on
        // another device is reflected here too.
        _activeSessions
          ..clear()
          ..addAll(_collectActiveSessionIds(_tasks));
        _isLoading = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  Future<_CompletionResult?> _showCompletionDialog(Task task, {String actionLabel = 'Complete'}) {
    return showDialog<_CompletionResult>(
      context: context,
      builder: (_) => _CompletionDialog(task: task, actionLabel: actionLabel),
    );
  }

  Future<void> _toggleComplete(Task task) async {
    try {
      Task updated;
      if (task.isCompleted) {
        // Un-completing never needs the dialog.
        updated = await TaskApiService.toggleComplete(task.id);
      } else {
        final res = await _showCompletionDialog(task);
        if (res == null) return; // user cancelled
        updated = await TaskApiService.toggleComplete(
          task.id,
          note: res.note,
          startedAt: res.startedAt,
          endedAt: res.endedAt,
          recurrenceAdvanceMode: res.advanceMode,
        );
      }
      setState(() {
        final idx = _tasks.indexWhere((t) => t.id == task.id);
        if (idx >= 0) _tasks[idx] = updated;
        // If hiding completed tasks, queue the animation then remove after it finishes.
        if (updated.isCompleted && !_showCompleted) {
          _completingTaskIds.add(updated.id);
        }
      });
    } catch (e) {
      _showError(e.toString());
    }
  }

  void _onCompletionAnimationDone(int taskId) {
    if (!mounted) return;
    setState(() {
      _completingTaskIds.remove(taskId);
      _tasks.removeWhere((t) => t.id == taskId);
    });
  }

  Future<void> _skipTask(Task task) async {
    final res = await _showCompletionDialog(task, actionLabel: 'Skip');
    if (res == null) return; // user cancelled
    try {
      await TaskApiService.skipTask(
        task.id,
        note: res.note,
        startedAt: res.startedAt,
        endedAt: res.endedAt,
        recurrenceAdvanceMode: res.advanceMode,
      );
      await _load();
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _deleteTask(Task task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete task?'),
        content: Text('Delete "${task.title}" and all its subtasks?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await TaskApiService.deleteTask(task.id);
      setState(() => _tasks.removeWhere((t) => t.id == task.id));
    } catch (e) {
      _showError(e.toString());
    }
  }

  // ── Multi-select helpers ────────────────────────────────────────────────────

  void _enterSelectionMode(int taskId) {
    setState(() {
      _selectionMode = true;
      _selectedTaskIds.add(taskId);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedTaskIds.clear();
    });
  }

  void _toggleTaskSelection(int taskId) {
    setState(() {
      if (_selectedTaskIds.contains(taskId)) {
        _selectedTaskIds.remove(taskId);
        if (_selectedTaskIds.isEmpty) _selectionMode = false;
      } else {
        _selectedTaskIds.add(taskId);
      }
    });
  }

  Future<void> _batchDelete() async {
    if (_activeProject == null || _selectedTaskIds.isEmpty) return;
    final count = _selectedTaskIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete selected tasks?'),
        content: Text(
          'Permanently delete $count task${count == 1 ? '' : 's'}? '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await TaskApiService.batchDeleteTasks(
        projectId: _activeProject!.id,
        taskIds: _selectedTaskIds.toList(),
      );
      _exitSelectionMode();
      await _loadTasks();
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _batchEdit() async {
    if (_activeProject == null || _selectedTaskIds.isEmpty) return;
    final result = await showDialog<_BatchEditResult>(
      context: context,
      builder: (_) => _BatchEditDialog(tags: _tags),
    );
    if (result == null) return;
    try {
      await TaskApiService.batchUpdateTasks(
        projectId: _activeProject!.id,
        taskIds: _selectedTaskIds.toList(),
        tagIds: result.tagIds,
        tagNames: result.tagNames,
        tagMode: result.tagMode,
        dueDate: result.dueDate,
        durationMinutes: result.durationMinutes,
        isRecurring: result.isRecurring,
        recurrenceRule: result.recurrenceRule,
      );
      _exitSelectionMode();
      await _loadTasks();
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _batchComplete({required String status}) async {
    if (_activeProject == null || _selectedTaskIds.isEmpty) return;
    final n = _selectedTaskIds.length;
    final label = status == 'skipped' ? 'Skip' : 'Complete';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('$label selected tasks?'),
        content: Text(
          '$label $n task${n == 1 ? '' : 's'}? '
          'Recurring tasks will advance to their next occurrence.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(label),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await TaskApiService.batchCompleteTasks(
        projectId: _activeProject!.id,
        taskIds: _selectedTaskIds.toList(),
        status: status,
      );
      _exitSelectionMode();
      await _loadTasks();
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _startSession(Task task) async {
    try {
      await TaskApiService.startSession(task.id);
      setState(() => _activeSessions.add(task.id));
      await _quietRefreshTasks();
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _stopSession(Task task) async {
    try {
      await TaskApiService.stopSession(task.id);
      setState(() => _activeSessions.remove(task.id));
      await _quietRefreshTasks();
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _restartSession(Task task, String mode, DateTime? startedAt) async {
    try {
      await TaskApiService.restartSession(task.id, mode: mode, startedAt: startedAt);
      setState(() => _activeSessions.add(task.id));
      await _quietRefreshTasks();
    } catch (e) {
      _showError(e.toString());
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _navigateTo(String route) {
    // Other task views are branches off the todo list; push so that
    // pressing back returns here to the main todo interface.
    Navigator.of(context).pushNamed(route);
  }

  /// Persist a new manual order after a drag inside the embedded list.
  Future<void> _reorderTasks(List<int> orderedIds) async {
    if (_activeProject == null) return;
    try {
      await TaskApiService.reorderTasks(
        projectId: _activeProject!.id,
        orderedIds: orderedIds,
      );
      await _quietRefreshTasks();
    } catch (e) {
      _showError(e.toString());
    }
  }

  /// Mirrors the embedded list's current displayed tasks so selection-mode
  /// "select all" can operate on exactly what the user sees.
  void _onDisplayedTasksChanged(List<Task> tasks) {
    if (!mounted) return;
    setState(() => _visibleTasks = tasks);
  }

  /// Collect the ids of every task (at any depth) with an active work session.
  Set<int> _collectActiveSessionIds(List<Task> tasks) {
    final ids = <int>{};
    void visit(Task t) {
      if (t.isSessionActive) ids.add(t.id);
      for (final s in t.subtasks) {
        visit(s);
      }
    }
    for (final t in tasks) {
      visit(t);
    }
    return ids;
  }

  Future<void> _showSettings() async {
    String selected = _timeUnit;
    bool requireApproval = _agentRequireApproval;
    final confirmed = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('Settings'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Duration display unit', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                RadioListTile<String>(
                  title: const Text('Hours (e.g. 1h 30m)'),
                  value: 'hours',
                  groupValue: selected,
                  onChanged: (v) => setDlgState(() => selected = v!),
                ),
                RadioListTile<String>(
                  title: const Text('Minutes (e.g. 90m)'),
                  value: 'minutes',
                  groupValue: selected,
                  onChanged: (v) => setDlgState(() => selected = v!),
                ),
                const Divider(height: 20),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Require approval for agent changes'),
                  subtitle: const Text('Planning agent proposes actions first, then you approve.'),
                  value: requireApproval,
                  onChanged: (v) => setDlgState(() => requireApproval = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, {
                'timeUnit': selected,
                'agentRequireApproval': requireApproval,
              }),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != null) {
      final newUnit = (confirmed['timeUnit'] as String?) ?? _timeUnit;
      final newApproval = (confirmed['agentRequireApproval'] as bool?) ?? _agentRequireApproval;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('task_time_unit', newUnit);
      await prefs.setBool('task_agent_require_approval', newApproval);
      setState(() {
        _timeUnit = newUnit;
        _agentRequireApproval = newApproval;
      });
    }
  }

  Future<void> _openForm({Task? task}) async {
    if (_activeProject == null) return;
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => TaskFormScreen(
        editTask: task,
        projectId: _activeProject!.id,
      )),
    );
    if (created == true) _loadTasks();
  }

  Future<void> _switchProject(Project project) async {
    try {
      await ProjectApiService.setActiveProject(project.id);
      setState(() => _activeProject = project);
      await _loadTasks();
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _showProjectSwitcher() async {
    final selected = await showModalBottomSheet<Project>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _ProjectSwitcherSheet(
        projects: _projects,
        activeProjectId: _activeProject?.id,
        onSwitch: (p) => Navigator.pop(context, p),
        onRename: (p) {
          Navigator.pop(context);
          _showRenameProject(p);
        },
        onDelete: (p) {
          Navigator.pop(context);
          _deleteProject(p);
        },
        onCreateNew: () => Navigator.pop(context, null),
        onJoin: () => Navigator.pop(context, _activeProject), // sentinel
      ),
    );
    if (selected == null) {
      // Create new project
      await _showCreateProject();
    } else if (selected.id != _activeProject?.id) {
      await _switchProject(selected);
    }
  }

  Future<void> _showRenameProject(Project project) async {
    final nameCtrl = TextEditingController(text: project.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename Project'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, nameCtrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == project.name) return;
    try {
      final updated = await ProjectApiService.updateProject(project.id, name: newName);
      final projects = await ProjectApiService.getProjects();
      setState(() {
        _projects = projects;
        if (_activeProject?.id == updated.id) _activeProject = updated;
      });
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _deleteProject(Project project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Project'),
        content: Text(
          'Delete "${project.name}"? This permanently removes the project and '
          'all of its tasks, plans, and history. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ProjectApiService.deleteProject(project.id);
      final projects = await ProjectApiService.getProjects();
      final wasActive = _activeProject?.id == project.id;
      Project? nextActive = _activeProject;
      if (wasActive) {
        nextActive = projects.isNotEmpty ? projects.first : null;
        if (nextActive != null) {
          await ProjectApiService.setActiveProject(nextActive.id);
        }
      }
      setState(() {
        _projects = projects;
        _activeProject = nextActive;
      });
      if (wasActive) await _loadTasks();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "${project.name}"')),
        );
      }
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _showCreateProject() async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Project'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, autofocus: true,
                decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            TextField(controller: descCtrl,
                decoration: const InputDecoration(labelText: 'Description (optional)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create')),
        ],
      ),
    );
    if (ok != true || nameCtrl.text.trim().isEmpty) return;
    try {
      final project = await ProjectApiService.createProject(
        nameCtrl.text.trim(),
        description: descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
      );
      await ProjectApiService.setActiveProject(project.id);
      final projects = await ProjectApiService.getProjects();
      setState(() { _activeProject = project; _projects = projects; });
      await _loadTasks();
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _showJoinProject() async {
    final tokenCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Join Project'),
        content: TextField(
          controller: tokenCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Invite code',
            hintText: 'Paste the code from your colleague',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Join')),
        ],
      ),
    );
    if (ok != true || tokenCtrl.text.trim().isEmpty) return;
    try {
      final result = await ProjectApiService.redeemInvite(tokenCtrl.text.trim());
      final projectId = result['project_id'] as int;
      final projects = await ProjectApiService.getProjects();
      final joined = projects.firstWhere((p) => p.id == projectId, orElse: () => projects.first);
      await ProjectApiService.setActiveProject(joined.id);
      setState(() { _activeProject = joined; _projects = projects; });
      await _loadTasks();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Joined "${result['project_name']}"')),
        );
      }
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _showInvite() async {
    if (_activeProject == null || !_activeProject!.canWrite) return;
    try {
      final invite = await ProjectApiService.createInvite(_activeProject!.id);
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Share Project'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Share this code with your colleague to invite them as ${invite.roleToGrant}:'),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(invite.token, style: const TextStyle(
                        fontFamily: 'monospace', fontWeight: FontWeight.bold,
                      )),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: invite.token));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
          ],
        ),
      );
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _importCsv() async {
    if (_activeProject == null || _activeProject!.canWrite != true) {
      _showError('Only editors/owners can import tasks');
      return;
    }

    try {
      final dryRun = await _showCsvImportDialog();
      if (dryRun == null) return;

      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;

      final result = await TaskApiService.importTasksCsv(
        projectId: _activeProject!.id,
        file: picked.files.single,
        dryRun: dryRun,
      );

      if (!dryRun) {
        await _loadTasks();
      }
      if (!mounted) return;

      final created = result['created'] ?? 0;
      final skipped = result['skipped'] ?? 0;
      final createdTags = result['created_tags'] ?? 0;
      final totalErrors = result['total_errors'] ?? 0;

      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(dryRun ? 'CSV preview complete' : 'CSV import complete'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(dryRun ? 'Would create tasks: $created' : 'Created tasks: $created'),
              Text(dryRun ? 'Would create tags: $createdTags' : 'Created tags: $createdTags'),
              Text('Skipped rows: $skipped'),
              Text('Errors: $totalErrors'),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
          ],
        ),
      );
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<bool?> _showCsvImportDialog() {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Import Tasks from CSV'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('Required: one title column (any alias below).'),
                SizedBox(height: 8),
                Text('Title aliases: title, task, name, heading, todo, summary, item'),
                SizedBox(height: 6),
                Text('Description: description, notes, detail, body'),
                Text('Due date: due_date, due, deadline, scheduled, date'),
                Text('Duration: duration, duration_minutes, estimate, effort, minutes, time'),
                Text('Status: status, state, done, completed, todo'),
                Text('Tags: tags, tag, labels, categories'),
                Text('Parent: parent, parent_task, parent_title, parent_name'),
                SizedBox(height: 10),
                Text('Examples:'),
                Text('- due date: 2026-06-20 or 2026-06-20T14:30:00'),
                Text('- duration: 90, 1:30, 1h 30m'),
                Text('- tags: :work:deep: or work,deep'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Preview (Dry Run)')),
          ElevatedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Import')),
        ],
      ),
    );
  }

  // ── AppBar builders ─────────────────────────────────────────────────────────

  PreferredSizeWidget _buildNormalAppBar() {
    return AppBar(
      title: GestureDetector(
        onTap: _showProjectSwitcher,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _activeProject?.name ?? 'Tasks',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          } else {
            Navigator.of(context).pushReplacementNamed('/hub');
          }
        },
      ),
      actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        PopupMenuButton<String>(
          icon: const Icon(Icons.menu),
          onSelected: (v) {
            switch (v) {
              case 'todo':    break;
              case 'calendar': _navigateTo('/tasks/calendar'); break;
              case 'gantt':    _navigateTo('/tasks/gantt'); break;
              case 'plans':    _navigateTo('/tasks/plans'); break;
              case 'history':  _navigateTo('/tasks/completions'); break;
              case 'settings': _showSettings(); break;
              case 'share':    _showInvite(); break;
              case 'join':     _showJoinProject(); break;
              case 'import_csv': _importCsv(); break;
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'todo', child: ListTile(leading: Icon(Icons.check_circle_outline), title: Text('Todo'))),
            const PopupMenuItem(value: 'calendar', child: ListTile(leading: Icon(Icons.calendar_month), title: Text('Calendar'))),
            const PopupMenuItem(value: 'gantt', child: ListTile(leading: Icon(Icons.view_timeline), title: Text('Gantt'))),
            const PopupMenuItem(value: 'plans', child: ListTile(leading: Icon(Icons.description_outlined), title: Text('Plans'))),
            const PopupMenuItem(value: 'history', child: ListTile(leading: Icon(Icons.history), title: Text('Completion history'))),
            const PopupMenuDivider(),
            if (_activeProject?.canWrite == true)
              const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share_outlined), title: Text('Share project'))),
            if (_activeProject?.canWrite == true)
              const PopupMenuItem(value: 'import_csv', child: ListTile(leading: Icon(Icons.upload_file_outlined), title: Text('Import CSV'))),
            const PopupMenuItem(value: 'join', child: ListTile(leading: Icon(Icons.group_add_outlined), title: Text('Join project'))),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'settings', child: ListTile(leading: Icon(Icons.settings_outlined), title: Text('Settings'))),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    final n = _selectedTaskIds.length;
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Cancel selection',
        onPressed: _exitSelectionMode,
      ),
      title: Text('$n selected'),
      actions: [
        if (_activeProject?.canWrite == true) ...[
          IconButton(
            icon: const Icon(Icons.check_circle_outline),
            tooltip: 'Mark selected as complete',
            onPressed: () => _batchComplete(status: 'completed'),
          ),
          IconButton(
            icon: const Icon(Icons.skip_next_outlined),
            tooltip: 'Skip selected (recurring: advance to next)',
            onPressed: () => _batchComplete(status: 'skipped'),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Batch edit',
            onPressed: _batchEdit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete selected',
            onPressed: _batchDelete,
          ),
        ],
        // Select-all / deselect-all
        IconButton(
          icon: Icon(
            _selectedTaskIds.length == _visibleTasks.length
                ? Icons.deselect
                : Icons.select_all,
          ),
          tooltip: _selectedTaskIds.length == _visibleTasks.length
              ? 'Deselect all'
              : 'Select all',
          onPressed: () {
            setState(() {
              if (_selectedTaskIds.length == _visibleTasks.length) {
                _selectedTaskIds.clear();
                _selectionMode = false;
              } else {
                _selectedTaskIds
                  ..clear()
                  ..addAll(_visibleTasks.map((t) => t.id));
              }
            });
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
      body: Column(
        children: [
          // ── Body with the new-task button floated over it, kept directly
          // above the AI panel so it stays reachable even when the assistant
          // is expanded. The button overlays the task list (rather than
          // occupying its own full-width row) so tasks remain visible behind
          // it instead of an opaque band. ──────────────────────────────────
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _buildBody()),
                Positioned(
                  right: 16,
                  bottom: 8,
                  child: FloatingActionButton(
                    heroTag: 'todo_new_task_fab',
                    onPressed: () => _openForm(),
                    tooltip: 'New task',
                    child: const Icon(Icons.add),
                  ),
                ),
              ],
            ),
          ),
          // ── AI Assistant panel ────────────────────────────────────────────
          AgentChatPanel(
            title: 'AI Assistant',
            entries: _agentEntries,
            isLoading: _agentLoading,
            isExpanded: _agentExpanded,
            scrollController: _agentScrollCtrl,
            hasMemory: _agentHasMemory,
            emptyStateHint: 'Ask me what to work on, to add tasks, or what\'s overdue.',
            onClear: _clearAgentConversation,
            onSend: _sendAgentMessage,
            onToggleExpand: () {
              final wasCollapsed = !_agentExpanded;
              setState(() => _agentExpanded = !_agentExpanded);
              if (wasCollapsed) {
                if (_agentEntries.isEmpty) _loadAgentConversation();
                else _agentScrollToBottom();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    if (_noProjects) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.folder_open, size: 72, color: Colors.grey),
              const SizedBox(height: 20),
              const Text(
                'No projects yet',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Create a project to start managing tasks, or join an existing one with an invite code.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Create a Project'),
                onPressed: _showCreateProject,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.group_add_outlined),
                label: const Text('Join with Invite Code'),
                onPressed: _showJoinProject,
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_tasks.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('No tasks yet — tap + to add one', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    return TaskListView(
      tasks: _tasks,
      tags: _tags,
      activeSessions: _activeSessions,
      timeUnit: _timeUnit,
      showCompleted: _showCompleted,
      onToggleCompleted: (val) {
        setState(() => _showCompleted = val);
        _load();
      },
      onComplete: _toggleComplete,
      onSkip: _skipTask,
      onEdit: (t) => _openForm(task: t),
      onDelete: _deleteTask,
      onStartSession: _startSession,
      onStopSession: _stopSession,
      onRestartSession: _restartSession,
      onReorder: _reorderTasks,
      onRefresh: _load,
      selectionMode: _selectionMode,
      selectedTaskIds: _selectedTaskIds,
      onEnterSelection: _enterSelectionMode,
      onToggleSelection: _toggleTaskSelection,
      completingTaskIds: _completingTaskIds,
      onCompletionDone: _onCompletionAnimationDone,
      onDisplayedTasksChanged: _onDisplayedTasksChanged,
    );
  }
}

// ── Batch-edit dialog data ─────────────────────────────────────────────────────

class _BatchEditResult {
  final List<int>? tagIds;
  final List<String>? tagNames; // new tags to create
  final String tagMode;
  final String? dueDate;
  final int? durationMinutes;
  final bool? isRecurring;
  final String? recurrenceRule;

  const _BatchEditResult({
    this.tagIds,
    this.tagNames,
    this.tagMode = 'overwrite',
    this.dueDate,
    this.durationMinutes,
    this.isRecurring,
    this.recurrenceRule,
  });
}

/// Dialog for batch-editing multiple tasks.
/// The user can choose to update tags (with overwrite or add mode) and
/// optionally other scalar fields. Only fields whose toggle is enabled are sent.
class _BatchEditDialog extends StatefulWidget {
  final List<Tag> tags;

  const _BatchEditDialog({required this.tags});

  @override
  State<_BatchEditDialog> createState() => _BatchEditDialogState();
}

class _BatchEditDialogState extends State<_BatchEditDialog> {
  // Tags
  bool _editTags = false;
  String _tagMode = 'overwrite';
  final Set<int> _chosenTagIds = {};
  final TextEditingController _newTagCtrl = TextEditingController();
  // Names typed by the user (not yet in the project's tag list)
  final List<String> _newTagNames = [];

  // Due date
  bool _editDueDate = false;
  DateTime? _dueDate;

  // Duration
  bool _editDuration = false;
  final TextEditingController _durationCtrl = TextEditingController();

  // Recurrence
  bool _editRecurrence = false;
  bool _isRecurring = false;
  String _recurrenceRule = 'DAILY';

  @override
  void dispose() {
    _newTagCtrl.dispose();
    _durationCtrl.dispose();
    super.dispose();
  }

  void _addNewTag() {
    final name = _newTagCtrl.text.trim();
    if (name.isEmpty) return;
    // Avoid duplicates with existing project tags
    final alreadyExists = widget.tags.any(
      (t) => t.name.toLowerCase() == name.toLowerCase(),
    );
    if (alreadyExists) {
      // Auto-select it instead of adding a duplicate entry
      final tag = widget.tags.firstWhere(
        (t) => t.name.toLowerCase() == name.toLowerCase(),
      );
      setState(() => _chosenTagIds.add(tag.id));
    } else if (!_newTagNames.any((n) => n.toLowerCase() == name.toLowerCase())) {
      setState(() => _newTagNames.add(name));
    }
    _newTagCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final hasAnyEdit = _editTags || _editDueDate || _editDuration || _editRecurrence;
    return AlertDialog(
      title: const Text('Batch Edit'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Tags ──
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Edit tags'),
              value: _editTags,
              onChanged: (v) => setState(() => _editTags = v),
            ),
            if (_editTags) ...[
              const SizedBox(height: 4),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'overwrite', label: Text('Overwrite')),
                  ButtonSegment(value: 'add', label: Text('Add')),
                ],
                selected: {_tagMode},
                onSelectionChanged: (s) => setState(() => _tagMode = s.first),
              ),
              const SizedBox(height: 8),
              // Existing project tags
              if (widget.tags.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: widget.tags.map((tag) {
                    final selected = _chosenTagIds.contains(tag.id);
                    return FilterChip(
                      label: Text(tag.name),
                      selected: selected,
                      onSelected: (v) => setState(() {
                        if (v) _chosenTagIds.add(tag.id);
                        else _chosenTagIds.remove(tag.id);
                      }),
                    );
                  }).toList(),
                ),
              // New tags typed by the user
              if (_newTagNames.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: _newTagNames.map((name) => Chip(
                    label: Text(name),
                    avatar: const Icon(Icons.add, size: 14),
                    onDeleted: () => setState(() => _newTagNames.remove(name)),
                  )).toList(),
                ),
              const SizedBox(height: 6),
              // Input to add a new tag name
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newTagCtrl,
                      decoration: const InputDecoration(
                        labelText: 'New tag name',
                        hintText: 'Type and press +',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _addNewTag(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: 'Add tag',
                    onPressed: _addNewTag,
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],

            // ── Due date ──
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Edit due date'),
              value: _editDueDate,
              onChanged: (v) => setState(() => _editDueDate = v),
            ),
            if (_editDueDate) ...[
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(
                  _dueDate == null
                      ? 'Pick date/time'
                      : '${_dueDate!.year}-${_dueDate!.month.toString().padLeft(2, '0')}-${_dueDate!.day.toString().padLeft(2, '0')} '
                        '${_dueDate!.hour.toString().padLeft(2, '0')}:${_dueDate!.minute.toString().padLeft(2, '0')}',
                ),
                onPressed: () async {
                  final now = DateTime.now();
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _dueDate ?? now,
                    firstDate: DateTime(now.year - 1),
                    lastDate: DateTime(now.year + 5),
                  );
                  if (d == null) return;
                  final t = await showTimePicker(
                    // ignore: use_build_context_synchronously
                    context: context,
                    initialTime: TimeOfDay.fromDateTime(_dueDate ?? now),
                  );
                  setState(() {
                    _dueDate = DateTime(
                      d.year, d.month, d.day,
                      t?.hour ?? 0, t?.minute ?? 0,
                    );
                  });
                },
              ),
              const SizedBox(height: 8),
            ],

            // ── Duration ──
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Edit duration (minutes)'),
              value: _editDuration,
              onChanged: (v) => setState(() => _editDuration = v),
            ),
            if (_editDuration) ...[
              TextField(
                controller: _durationCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Duration (minutes)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
            ],

            // ── Recurrence ──
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Edit recurrence'),
              value: _editRecurrence,
              onChanged: (v) => setState(() => _editRecurrence = v),
            ),
            if (_editRecurrence) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Recurring'),
                value: _isRecurring,
                onChanged: (v) => setState(() => _isRecurring = v),
              ),
              if (_isRecurring)
                DropdownButtonFormField<String>(
                  value: _recurrenceRule,
                  decoration: const InputDecoration(labelText: 'Rule', isDense: true, border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'DAILY', child: Text('Daily')),
                    DropdownMenuItem(value: 'WEEKDAYS', child: Text('Every weekday (Mon–Fri)')),
                    DropdownMenuItem(value: 'WEEKLY', child: Text('Weekly')),
                    DropdownMenuItem(value: 'MONTHLY', child: Text('Monthly')),
                  ],
                  onChanged: (v) => setState(() => _recurrenceRule = v ?? _recurrenceRule),
                ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: hasAnyEdit
              ? () {
                  final duration = _editDuration
                      ? int.tryParse(_durationCtrl.text.trim())
                      : null;
                  Navigator.pop(
                    context,
                    _BatchEditResult(
                      tagIds: _editTags ? _chosenTagIds.toList() : null,
                      tagNames: (_editTags && _newTagNames.isNotEmpty)
                          ? List.unmodifiable(_newTagNames)
                          : null,
                      tagMode: _tagMode,
                      dueDate: _editDueDate ? _dueDate?.toIso8601String() : null,
                      durationMinutes: _editDuration ? duration : null,
                      isRecurring: _editRecurrence ? _isRecurring : null,
                      recurrenceRule: (_editRecurrence && _isRecurring) ? _recurrenceRule : null,
                    ),
                  );
                }
              : null,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

// ── Project switcher placeholder removed (now in task_list_view.dart) ─────────

// ── Project switcher bottom sheet ─────────────────────────────────────────────

class _ProjectSwitcherSheet extends StatelessWidget {
  final List<Project> projects;
  final int? activeProjectId;
  final void Function(Project) onSwitch;
  final void Function(Project) onRename;
  final void Function(Project) onDelete;
  final VoidCallback onCreateNew;
  final VoidCallback onJoin;

  const _ProjectSwitcherSheet({
    required this.projects,
    required this.activeProjectId,
    required this.onSwitch,
    required this.onRename,
    required this.onDelete,
    required this.onCreateNew,
    required this.onJoin,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Switch Project', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...projects.map((p) => ListTile(
            leading: Icon(
              p.isOwner ? Icons.folder : Icons.folder_shared,
              color: p.id == activeProjectId ? Theme.of(context).colorScheme.primary : null,
            ),
            title: Text(p.name, style: TextStyle(
              fontWeight: p.id == activeProjectId ? FontWeight.bold : FontWeight.normal,
            )),
            subtitle: Text('${p.memberCount} member${p.memberCount != 1 ? 's' : ''} · ${p.role}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (p.canWrite)
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    tooltip: 'Rename project',
                    onPressed: () => onRename(p),
                  ),
                if (p.isOwner)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Delete project',
                    onPressed: () => onDelete(p),
                  ),
                if (p.id == activeProjectId)
                  Icon(Icons.check, color: Theme.of(context).colorScheme.primary),
              ],
            ),
            onTap: () => onSwitch(p),
          )),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.add_circle_outline),
            title: const Text('New Project'),
            onTap: onCreateNew,
          ),
          ListTile(
            leading: const Icon(Icons.group_add_outlined),
            title: const Text('Join Project with Code'),
            onTap: onJoin,
          ),
        ],
      ),
    );
  }
}

// ── Completion dialog ──────────────────────────────────────────────────────────

/// Result of the completion dialog: an optional note, the start/stop times to
/// record for the work interval, and (for recurring tasks) the chosen
/// recurrence-advancement mode ("now" or "stop").
class _CompletionResult {
  final String? note;
  final DateTime startedAt;
  final DateTime endedAt;
  final String? advanceMode; // null for non-recurring tasks

  const _CompletionResult({
    this.note,
    required this.startedAt,
    required this.endedAt,
    this.advanceMode,
  });
}

/// Dialog shown when marking a task done (or skipping it). Lets the user review
/// and edit the assumed start/stop times, add a note, and — for recurring tasks
/// — choose how the next occurrence is scheduled.
class _CompletionDialog extends StatefulWidget {
  final Task task;
  final String actionLabel; // "Complete" | "Skip"

  const _CompletionDialog({required this.task, this.actionLabel = 'Complete'});

  @override
  State<_CompletionDialog> createState() => _CompletionDialogState();
}

class _CompletionDialogState extends State<_CompletionDialog> {
  static final DateFormat _fmt = DateFormat('MMM d, yyyy · h:mm a');

  final TextEditingController _noteCtrl = TextEditingController();
  late DateTime _start;
  late DateTime _end;
  late String _advanceMode;
  String? _error;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    // Default the start to the running session's start (if any), otherwise now.
    _start = widget.task.activeSessionStartedAt?.toLocal() ?? now;
    _end = now;
    _advanceMode = widget.task.recurrenceAdvanceMode; // "now" by default
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<DateTime?> _pickDateTime(DateTime initial) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: initial.isAfter(now) ? now : initial,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      // ignore: use_build_context_synchronously
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  void _validate() {
    final now = DateTime.now().add(const Duration(minutes: 1)); // small skew
    if (_end.isBefore(_start)) {
      _error = 'Stop time cannot be before start time.';
    } else if (_start.isAfter(now) || _end.isAfter(now)) {
      _error = 'Times cannot be in the future.';
    } else {
      _error = null;
    }
  }

  void _submit() {
    setState(_validate);
    if (_error != null) return;
    final note = _noteCtrl.text.trim();
    Navigator.pop(
      context,
      _CompletionResult(
        note: note.isEmpty ? null : note,
        startedAt: _start,
        endedAt: _end,
        advanceMode: widget.task.isRecurring ? _advanceMode : null,
      ),
    );
  }

  Widget _timeRow(String label, DateTime value, ValueChanged<DateTime> onPicked) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.schedule, size: 16),
              label: Text(_fmt.format(value), style: const TextStyle(fontSize: 13)),
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              onPressed: () async {
                final picked = await _pickDateTime(value);
                if (picked != null) setState(() => onPicked(picked));
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.actionLabel} "${widget.task.title}"'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.task.isSessionActive
                  ? 'Adjust the work interval if needed.'
                  : 'This task was never started — defaults to now. Adjust if you '
                    'finished it earlier.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            _timeRow('Start', _start, (v) => _start = v),
            _timeRow('Stop', _end, (v) => _end = v),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _noteCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                hintText: 'Any observations or follow-ups…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (widget.task.isRecurring) ...[
              const Divider(height: 24),
              const Text('Next occurrence', style: TextStyle(fontWeight: FontWeight.w600)),
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: 'now',
                groupValue: _advanceMode,
                onChanged: (v) => setState(() => _advanceMode = v!),
                title: const Text('Next time from now'),
                subtitle: const Text('Skip any missed occurrences and schedule the next one after today.'),
              ),
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: 'stop',
                groupValue: _advanceMode,
                onChanged: (v) => setState(() => _advanceMode = v!),
                title: const Text('Next time after the stop time'),
                subtitle: const Text('Schedule the next occurrence right after the stop time above.'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(onPressed: _submit, child: Text(widget.actionLabel)),
      ],
    );
  }
}

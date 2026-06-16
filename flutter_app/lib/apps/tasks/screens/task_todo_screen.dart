import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/task.dart';
import '../models/project.dart';
import '../services/task_api_service.dart';
import '../services/project_api_service.dart';
import '../widgets/task_card.dart';
import 'task_form_screen.dart';

/// How the top-level task list is ordered in the todo view.
enum TaskSortMode {
  /// Least time until the due date first (most urgent).
  timeLeft,
  /// Longest estimated duration first.
  duration,
  /// Soonest due date first.
  dueDate,
  /// Time left divided by duration — lowest (most dire) first.
  direness,
}

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
  final Set<int> _selectedTagIds = {};
  bool _showCompleted = false;
  final Set<int> _activeSessions = {};
  final Set<int> _completingTaskIds = {};
  String _timeUnit = 'hours';
  bool _agentRequireApproval = true;
  bool _expandAll = false;
  bool _flatView = false;
  TaskSortMode _sortMode = TaskSortMode.timeLeft;

  // ── Multi-select state ──────────────────────────────────────────────────────
  bool _selectionMode = false;
  final Set<int> _selectedTaskIds = {};

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
      _expandAll = prefs.getBool('task_expand_all') ?? false;
      _flatView = prefs.getBool('task_flat_view') ?? false;
      final sortName = prefs.getString('task_sort_mode');
      _sortMode = TaskSortMode.values.firstWhere(
        (m) => m.name == sortName,
        orElse: () => TaskSortMode.timeLeft,
      );
    });
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
        _isLoading = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  Future<String?> _askCompletionNote(String taskTitle) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Complete "$taskTitle"'),
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
  }

  Future<void> _toggleComplete(Task task) async {
    // Only prompt for a note when marking done (not when un-completing).
    String? note;
    if (!task.isCompleted) {
      note = await _askCompletionNote(task.title);
      if (note == null) return; // user cancelled
    }
    try {
      final updated = await TaskApiService.toggleComplete(task.id, note: note?.isEmpty == true ? null : note);
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
    final note = await _askCompletionNote(task.title);
    if (note == null) return; // user cancelled
    try {
      await TaskApiService.skipTask(task.id, note: note.isEmpty ? null : note);
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
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _stopSession(Task task) async {
    try {
      await TaskApiService.stopSession(task.id);
      setState(() => _activeSessions.remove(task.id));
      await _load();
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

  Future<void> _setExpandAll(bool value) async {
    setState(() => _expandAll = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('task_expand_all', value);
  }

  Future<void> _setFlatView(bool value) async {
    setState(() => _flatView = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('task_flat_view', value);
  }

  String _sortModeLabel(TaskSortMode mode) {
    switch (mode) {
      case TaskSortMode.timeLeft: return 'Time left (most urgent)';
      case TaskSortMode.duration: return 'Duration (longest first)';
      case TaskSortMode.dueDate:  return 'Due date (soonest first)';
      case TaskSortMode.direness: return 'Direness (time left ÷ duration)';
    }
  }

  Future<void> _setSortMode(TaskSortMode mode) async {
    setState(() => _sortMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('task_sort_mode', mode.name);
  }

  // ── Sorting / filtering helpers ─────────────────────────────────────────────

  bool get _sortAscending => _sortMode != TaskSortMode.duration;

  /// "Direness" = remaining time relative to the work required.
  /// Lower (or negative) = more dire. Null when due date or duration is missing.
  double? _direness(Task t, DateTime now) {
    if (t.dueDate == null || t.durationMinutes == null || t.durationMinutes! <= 0) {
      return null;
    }
    return t.dueDate!.difference(now).inMinutes / t.durationMinutes!;
  }

  /// The raw metric for a single task under the active sort mode (null if N/A).
  num? _metric(Task t, DateTime now) {
    switch (_sortMode) {
      case TaskSortMode.timeLeft: return t.dueDate?.difference(now).inMinutes;
      case TaskSortMode.duration: return t.durationMinutes;
      case TaskSortMode.dueDate:  return t.dueDate?.millisecondsSinceEpoch;
      case TaskSortMode.direness: return _direness(t, now);
    }
  }

  int _cmpNullable(num? a, num? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1; // nulls last
    if (b == null) return -1;
    return _sortAscending ? a.compareTo(b) : b.compareTo(a);
  }

  /// The "most prominent" metric across a task and all its descendants,
  /// i.e. the value that would sort first under the current mode.
  num? _representativeMetric(Task t, DateTime now) {
    num? best;
    void visit(Task x) {
      final m = _metric(x, now);
      if (m != null) {
        if (best == null) {
          best = m;
        } else {
          best = _sortAscending ? math.min(best!, m) : math.max(best!, m);
        }
      }
      for (final s in x.subtasks) {
        visit(s);
      }
    }
    visit(t);
    return best;
  }

  /// Comparator that orders individual tasks by their own metric.
  Comparator<Task> get _taskComparator {
    final now = DateTime.now();
    return (a, b) => _cmpNullable(_metric(a, now), _metric(b, now));
  }

  bool _matchesTagFilter(Task t) {
    if (_selectedTagIds.isEmpty) return true;
    return t.tags.any((tag) => _selectedTagIds.contains(tag.id));
  }

  bool _treeMatchesTagFilter(Task t) {
    if (_matchesTagFilter(t)) return true;
    return t.subtasks.any(_treeMatchesTagFilter);
  }

  void _flatten(Task t, List<Task> out) {
    out.add(t);
    for (final s in t.subtasks) {
      _flatten(s, out);
    }
  }

  /// The task list to render given the active view + sort + tag filter.
  /// In grouped mode: top-level tasks sorted by their most-dire descendant.
  /// In flat mode: every task (all levels) sorted individually.
  List<Task> get _displayTasks {
    final now = DateTime.now();
    if (_flatView) {
      final all = <Task>[];
      for (final t in _tasks) {
        _flatten(t, all);
      }
      final filtered = all.where(_matchesTagFilter).toList();
      filtered.sort((a, b) => _cmpNullable(_metric(a, now), _metric(b, now)));
      return filtered;
    }
    final roots = _tasks.where(_treeMatchesTagFilter).toList();
    roots.sort((a, b) => _cmpNullable(
          _representativeMetric(a, now),
          _representativeMetric(b, now),
        ));
    return roots;
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
        IconButton(
          icon: Icon(_flatView ? Icons.view_list : Icons.account_tree),
          tooltip: _flatView
              ? 'Flat view (all tasks individually)'
              : 'Grouped view (subtasks nested)',
          onPressed: () => _setFlatView(!_flatView),
        ),
        IconButton(
          icon: Icon(_expandAll ? Icons.unfold_less : Icons.unfold_more),
          tooltip: _expandAll ? 'Collapse all' : 'Expand all',
          onPressed: () => _setExpandAll(!_expandAll),
        ),
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
            _selectedTaskIds.length == _displayTasks.length
                ? Icons.deselect
                : Icons.select_all,
          ),
          tooltip: _selectedTaskIds.length == _displayTasks.length
              ? 'Deselect all'
              : 'Select all',
          onPressed: () {
            setState(() {
              if (_selectedTaskIds.length == _displayTasks.length) {
                _selectedTaskIds.clear();
                _selectionMode = false;
              } else {
                _selectedTaskIds
                  ..clear()
                  ..addAll(_displayTasks.map((t) => t.id));
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
          // Tag filter + completed toggle
          _FilterBar(
            tags: _tags,
            selectedTagIds: _selectedTagIds,
            showCompleted: _showCompleted,
            onTagsChanged: (ids) {
              setState(() {
                _selectedTagIds
                  ..clear()
                  ..addAll(ids);
              });
            },
            onToggleCompleted: (val) {
              setState(() => _showCompleted = val);
              _load();
            },
          ),
          _SortBar(
            sortMode: _sortMode,
            labelFor: _sortModeLabel,
            onSortSelected: _setSortMode,
          ),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        tooltip: 'New task',
        child: const Icon(Icons.add),
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
    return RefreshIndicator(
      onRefresh: _load,
      child: Builder(
        builder: (_) {
          final sorted = _displayTasks;
          if (sorted.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(32),
              children: const [
                SizedBox(height: 80),
                Icon(Icons.filter_alt_off, size: 56, color: Colors.grey),
                SizedBox(height: 16),
                Center(
                  child: Text('No tasks match the current filters',
                      style: TextStyle(color: Colors.grey)),
                ),
              ],
            );
          }
          final subtaskSort = _taskComparator;
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: sorted.length,
            itemBuilder: (_, i) {
              final task = sorted[i];
              final isSelected = _selectedTaskIds.contains(task.id);
              final cardTree = TaskCardTree(
                task: task,
                activeSessions: {for (final id in _activeSessions) id: true},
                expandAll: _expandAll,
                renderSubtasks: !_flatView,
                subtaskSort: subtaskSort,
                timeUnit: _timeUnit,
                onComplete: _selectionMode ? null : _toggleComplete,
                onSkip: _selectionMode ? null : _skipTask,
                onEdit: _selectionMode ? null : (t) => _openForm(task: t),
                onDelete: _selectionMode ? null : _deleteTask,
                onStartSession: _selectionMode ? null : _startSession,
                onStopSession: _selectionMode ? null : _stopSession,
              );
              return GestureDetector(
                onLongPress: _selectionMode ? null : () => _enterSelectionMode(task.id),
                onTap: _selectionMode ? () => _toggleTaskSelection(task.id) : null,
                child: _TaskCompletionWrapper(
                  key: ValueKey(task.id),
                  completing: _completingTaskIds.contains(task.id),
                  onDismissed: () => _onCompletionAnimationDone(task.id),
                  child: _selectionMode
                      ? Stack(
                          children: [
                            // Tint when selected
                            if (isSelected)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Checkbox(
                                  value: isSelected,
                                  onChanged: (_) => _toggleTaskSelection(task.id),
                                ),
                                Expanded(child: cardTree),
                              ],
                            ),
                          ],
                        )
                      : cardTree,
                ),
              );
            },
          );
        },
      ),
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

// ── Completion exit animation ──────────────────────────────────────────────────

/// Wraps a task list item. When [completing] flips to true it plays a brief
/// green flash followed by a fade + height-collapse, then calls [onDismissed]
/// so the parent can remove the task from state.
class _TaskCompletionWrapper extends StatefulWidget {
  final bool completing;
  final VoidCallback? onDismissed;
  final Widget child;

  const _TaskCompletionWrapper({
    super.key,
    required this.completing,
    required this.child,
    this.onDismissed,
  });

  @override
  State<_TaskCompletionWrapper> createState() => _TaskCompletionWrapperState();
}

class _TaskCompletionWrapperState extends State<_TaskCompletionWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  // Green overlay: ramps up to 20% opacity in first 20%, gone by 45%.
  late final Animation<double> _flash = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.20), weight: 20),
    TweenSequenceItem(tween: Tween(begin: 0.20, end: 0.0), weight: 25),
    TweenSequenceItem(tween: ConstantTween(0.0), weight: 55),
  ]).animate(_ctrl);

  // Content fades out from t=40% to t=100%.
  late final Animation<double> _fade = TweenSequence<double>([
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 60),
  ]).animate(_ctrl);

  // Height collapses from t=50% to t=100%.
  late final Animation<double> _size = TweenSequence<double>([
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 50),
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 50,
    ),
  ]).animate(_ctrl);

  @override
  void didUpdateWidget(_TaskCompletionWrapper old) {
    super.didUpdateWidget(old);
    if (widget.completing && !old.completing) {
      _ctrl.forward().whenComplete(() => widget.onDismissed?.call());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      child: widget.child,
      builder: (context, child) => SizeTransition(
        sizeFactor: _size,
        axisAlignment: -1.0,
        child: Opacity(
          opacity: _fade.value,
          child: Stack(
            children: [
              child!,
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: _flash.value),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SortBar extends StatelessWidget {  final TaskSortMode sortMode;
  final String Function(TaskSortMode) labelFor;
  final void Function(TaskSortMode) onSortSelected;

  const _SortBar({
    required this.sortMode,
    required this.labelFor,
    required this.onSortSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          const Icon(Icons.sort, size: 18),
          const SizedBox(width: 8),
          const Text('Sort by', style: TextStyle(fontSize: 13)),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<TaskSortMode>(
              value: sortMode,
              isExpanded: true,
              isDense: true,
              underline: const SizedBox.shrink(),
              onChanged: (mode) {
                if (mode != null) onSortSelected(mode);
              },
              items: TaskSortMode.values
                  .map((m) => DropdownMenuItem(
                        value: m,
                        child: Text(labelFor(m), style: const TextStyle(fontSize: 13)),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  final List<Tag> tags;
  final Set<int> selectedTagIds;
  final bool showCompleted;
  final void Function(Set<int>) onTagsChanged;
  final void Function(bool) onToggleCompleted;

  const _FilterBar({
    required this.tags,
    required this.selectedTagIds,
    required this.showCompleted,
    required this.onTagsChanged,
    required this.onToggleCompleted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: _TagFilterDropdown(
              tags: tags,
              selectedTagIds: selectedTagIds,
              onChanged: onTagsChanged,
            ),
          ),
          const SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Done', style: TextStyle(fontSize: 12)),
              Switch(
                value: showCompleted,
                onChanged: onToggleCompleted,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A dropdown button that opens a searchable, multi-select checkbox list of tags.
class _TagFilterDropdown extends StatelessWidget {
  final List<Tag> tags;
  final Set<int> selectedTagIds;
  final void Function(Set<int>) onChanged;

  const _TagFilterDropdown({
    required this.tags,
    required this.selectedTagIds,
    required this.onChanged,
  });

  String _buttonLabel() {
    if (selectedTagIds.isEmpty) return 'All tags';
    if (selectedTagIds.length == 1) {
      final match = tags.where((t) => t.id == selectedTagIds.first);
      if (match.isNotEmpty) return match.first.name;
    }
    return '${selectedTagIds.length} tags';
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        icon: const Icon(Icons.filter_list, size: 18),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_buttonLabel()),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          visualDensity: VisualDensity.compact,
        ),
        onPressed: tags.isEmpty
            ? null
            : () async {
                final result = await showModalBottomSheet<Set<int>>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => _TagFilterSheet(
                    tags: tags,
                    selectedTagIds: selectedTagIds,
                  ),
                );
                if (result != null) onChanged(result);
              },
      ),
    );
  }
}

/// Bottom-sheet content with a search field + checkbox list for tag selection.
class _TagFilterSheet extends StatefulWidget {
  final List<Tag> tags;
  final Set<int> selectedTagIds;

  const _TagFilterSheet({required this.tags, required this.selectedTagIds});

  @override
  State<_TagFilterSheet> createState() => _TagFilterSheetState();
}

class _TagFilterSheetState extends State<_TagFilterSheet> {
  late final Set<int> _selected = {...widget.selectedTagIds};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.tags
        .where((t) => t.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Filter by tags',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  if (_selected.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(_selected.clear),
                      child: const Text('Clear'),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search tags…',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const SizedBox(height: 4),
            Flexible(
              child: filtered.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No matching tags',
                          style: TextStyle(color: Colors.grey)),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: filtered
                          .map((tag) => CheckboxListTile(
                                dense: true,
                                value: _selected.contains(tag.id),
                                title: Text(tag.name),
                                secondary: CircleAvatar(
                                  radius: 8,
                                  backgroundColor: tag.flutterColor,
                                ),
                                onChanged: (checked) => setState(() {
                                  if (checked == true) {
                                    _selected.add(tag.id);
                                  } else {
                                    _selected.remove(tag.id);
                                  }
                                }),
                              ))
                          .toList(),
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, _selected),
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Project switcher bottom sheet ─────────────────────────────────────────────

class _ProjectSwitcherSheet extends StatelessWidget {
  final List<Project> projects;
  final int? activeProjectId;
  final void Function(Project) onSwitch;
  final void Function(Project) onRename;
  final VoidCallback onCreateNew;
  final VoidCallback onJoin;

  const _ProjectSwitcherSheet({
    required this.projects,
    required this.activeProjectId,
    required this.onSwitch,
    required this.onRename,
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

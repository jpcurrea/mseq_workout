import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/task.dart';
import '../services/task_api_service.dart';
import '../widgets/urgency_color.dart';

/// Three view modes for task lists.
enum TaskViewMode {
  topLevelPreview, // root tasks only, compact (tap to expand)
  allPreview,      // all levels, compact (tap to expand)
  allExpanded,     // all levels, fully expanded
}

/// Reusable task card widget with:
///   - Urgency color bar on the left
///   - Title, due date, tag chips
///   - Progress bar (actual vs estimated duration)
///   - Start / Stop work session button
///   - Expand arrow for recursive subtasks
///   - Punctuality badge for completed tasks
class TaskCard extends StatefulWidget {
  final Task task;
  final bool isSessionActive;
  final int depth;
  final bool isPreview;
  final bool isExpanded;
  final VoidCallback? onToggleExpand;
  final String timeUnit;
  final VoidCallback? onComplete;
  final VoidCallback? onSkip;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onStartSession;
  final VoidCallback? onStopSession;
  final void Function(String mode, DateTime? startedAt)? onRestartSession;

  const TaskCard({
    super.key,
    required this.task,
    this.isSessionActive = false,
    this.depth = 0,
    this.isPreview = true,
    this.isExpanded = false,
    this.onToggleExpand,
    this.timeUnit = 'hours',
    this.onComplete,
    this.onSkip,
    this.onEdit,
    this.onDelete,
    this.onStartSession,
    this.onStopSession,
    this.onRestartSession,
  });

  @override
  State<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<TaskCard> {
  /// True when the user tapped an individual card to expand it from preview mode.
  bool _isCardExpanded = false;

  // Completion history (loaded once when the full card is first shown).
  List<Map<String, dynamic>>? _completions;
  bool _historyExpanded = false;
  bool _historyLoading = false;

  // Live work-session history for non-recurring tasks.
  List<Map<String, dynamic>>? _sessions;
  bool _sessionsExpanded = false;
  bool _sessionsLoading = false;

  /// Ticks while a work session is active and the full card is visible so the
  /// progress bar reflects elapsed time without needing a server round-trip.
  Timer? _liveTimer;

  @override
  void initState() {
    super.initState();
    _syncLiveTimer();
  }

  @override
  void didUpdateWidget(covariant TaskCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isSessionActive != widget.isSessionActive ||
        oldWidget.isPreview != widget.isPreview) {
      _syncLiveTimer();
    }
    // A start/stop changes the live work-session list — refresh it if loaded.
    if (oldWidget.isSessionActive != widget.isSessionActive &&
        !widget.task.isRecurring &&
        _sessions != null) {
      _reloadSessions();
    }
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    super.dispose();
  }

  /// Start/stop the 10-second refresh timer depending on whether a live session
  /// is running and the detailed (non-preview) card is shown.
  void _syncLiveTimer() {
    final showingFullCard = !widget.isPreview || _isCardExpanded;
    final shouldRun = widget.isSessionActive && showingFullCard;
    if (shouldRun && _liveTimer == null) {
      _liveTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (mounted) setState(() {});
      });
    } else if (!shouldRun && _liveTimer != null) {
      _liveTimer!.cancel();
      _liveTimer = null;
    }
  }

  Color get _urgencyColor => urgencyColor(widget.task.startBy, widget.task.durationMinutes);

  void _maybeLoadHistory() {
    final task = widget.task;
    if (_completions != null || _historyLoading) return;
    if (task.projectId == null) return;
    setState(() => _historyLoading = true);
    TaskApiService.getCompletions(projectId: task.projectId!, taskId: task.id)
        .then((rows) {
          if (mounted) setState(() { _completions = rows as List<Map<String, dynamic>>; _historyLoading = false; });
        })
        .catchError((_) {
          if (mounted) setState(() { _completions = []; _historyLoading = false; });
        });
  }

  /// Force-refreshes the completion history from the server (used after an edit).
  Future<void> _reloadHistory() async {
    final task = widget.task;
    if (task.projectId == null) return;
    try {
      final rows = await TaskApiService.getCompletions(
          projectId: task.projectId!, taskId: task.id);
      if (mounted) {
        setState(() => _completions = rows);
      }
    } catch (_) {
      // Keep the existing rows on a transient failure.
    }
  }

  void _maybeLoadSessions() {
    if (_sessions != null || _sessionsLoading) return;
    setState(() => _sessionsLoading = true);
    TaskApiService.getTaskSessions(widget.task.id)
        .then((rows) {
          if (mounted) setState(() { _sessions = rows; _sessionsLoading = false; });
        })
        .catchError((_) {
          if (mounted) setState(() { _sessions = []; _sessionsLoading = false; });
        });
  }

  /// Force-refreshes the live work-session history (used after an edit).
  Future<void> _reloadSessions() async {
    try {
      final rows = await TaskApiService.getTaskSessions(widget.task.id);
      if (mounted) setState(() => _sessions = rows);
    } catch (_) {
      // Keep the existing rows on a transient failure.
    }
  }

  /// Blocking dialog offering the three restart modes. Calls [onRestartSession]
  /// with the chosen mode (and a custom start time for the "custom" mode).
  Future<void> _showRestartDialog(BuildContext context) async {
    final cb = widget.onRestartSession;
    if (cb == null) return;
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Restart timer'),
        content: const Text(
          'Choose how to restart timekeeping for this task. The session stays active.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'session'),
            child: const Text('Restart session'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'task'),
            child: const Text('Restart task'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'custom'),
            child: const Text('Custom start time'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == 'custom') {
      final picked = await _pickCustomStart(context);
      if (picked == null) return;
      cb('custom', picked);
    } else {
      cb(choice, null);
    }
  }

  /// Date + time picker for the "custom start time" restart mode. Returns null
  /// if the user cancels at any step. Future times are not allowed.
  Future<DateTime?> _pickCustomStart(BuildContext context) async {
    final now = DateTime.now();
    final start = widget.task.activeSessionStartedAt?.toLocal() ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: start.isAfter(now) ? now : start,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (date == null) return null;
    if (!context.mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(start),
    );
    if (time == null) return null;
    final result = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    return result.isAfter(now) ? now : result;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isPreview && !_isCardExpanded) return _buildPreviewCard(context);
    return _buildFullCard(context);
  }

  /// Compact single-row card. Tapping anywhere opens the full card.
  Widget _buildPreviewCard(BuildContext context) {
    final task = widget.task;
    final indent = widget.depth * 16.0;
    return Padding(
      padding: EdgeInsets.only(left: indent, bottom: 4),
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() { _isCardExpanded = true; _syncLiveTimer(); }),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 4,
                      color: task.isCompleted ? Colors.grey[300] : _urgencyColor,
                    ),
                    GestureDetector(
                      onTap: widget.onComplete,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Icon(
                          task.isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
                          color: task.isCompleted ? Colors.green : Colors.grey,
                          size: 20,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Text(
                          task.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            decoration: task.isCompleted ? TextDecoration.lineThrough : null,
                            color: task.isCompleted ? Colors.grey : null,
                          ),
                        ),
                      ),
                    ),
                    _MetricColumns(
                      task: task,
                      timeUnit: widget.timeUnit,
                      timeLeftDueDate:
                          task.subtasks.isNotEmpty ? task.mostDireDueDate : null,
                    ),
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.only(left: 4, right: 6),
                        child: Icon(Icons.expand_more, size: 16, color: Colors.grey),
                      ),
                    ),
                  ],
                ),
              ),
              _BottomProgressLine(task: task),
            ],
          ),
        ),
      ),
    );
  }

  /// Full detailed card.
  Widget _buildFullCard(BuildContext context) {
    final task = widget.task;
    final indent = widget.depth * 16.0;
    if (task.isRecurring) {
      _maybeLoadHistory();
    } else {
      _maybeLoadSessions();
    }

    return Padding(
      padding: EdgeInsets.only(left: indent, bottom: 8),
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Urgency color bar
                  Container(
                    width: 5,
                    color: task.isCompleted ? Colors.grey[300] : _urgencyColor,
                  ),
                  Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // Completion checkbox
                          GestureDetector(
                            onTap: widget.onComplete,
                            child: Icon(
                              task.isCompleted
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              color: task.isCompleted ? Colors.green : Colors.grey,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Title
                          Expanded(
                            child: Text(
                              task.title,
                              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    decoration: task.isCompleted
                                        ? TextDecoration.lineThrough
                                        : null,
                                    color: task.isCompleted ? Colors.grey : null,
                                  ),
                            ),
                          ),
                          // Collapse back to preview (only shown when card was tapped open)
                          if (widget.isPreview)
                            GestureDetector(
                              onTap: () => setState(() { _isCardExpanded = false; _syncLiveTimer(); }),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 4),
                                child: Icon(Icons.expand_less, size: 18, color: Colors.grey),
                              ),
                            ),
                          // Action menu
                          PopupMenuButton<String>(
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            onSelected: (v) {
                              if (v == 'edit') widget.onEdit?.call();
                              if (v == 'skip') widget.onSkip?.call();
                              if (v == 'delete') widget.onDelete?.call();
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(value: 'edit', child: Text('Edit')),
                              if (task.isRecurring && !task.isCompleted && widget.onSkip != null)
                                const PopupMenuItem(value: 'skip', child: Text('Skip to next')),
                              const PopupMenuItem(value: 'delete', child: Text('Delete')),
                            ],
                          ),
                        ],
                      ),

                      // Description (full card only)
                      if (task.description != null && task.description!.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6, left: 30),
                          child: Text(
                            task.description!.trim(),
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: task.isCompleted
                                      ? Colors.grey
                                      : Colors.grey[700],
                                ),
                          ),
                        ),

                      // Due date + tags row
                      if (task.dueDate != null || task.durationMinutes != null || task.tags.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4, left: 30),
                          child: Wrap(
                            spacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (task.dueDate != null)
                                _DueDateChip(task: task, urgencyColor: _urgencyColor),
                              if (task.durationMinutes != null && task.durationMinutes! > 0)
                                _DurationChip(
                                  minutes: task.durationMinutes!,
                                  timeUnit: widget.timeUnit,
                                ),
                              ...task.tags.map((tag) => _TagChip(tag: tag)),
                            ],
                          ),
                        ),

                      // Progress bar
                      if (task.durationMinutes != null && task.durationMinutes! > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 6, left: 30),
                          child: _ProgressBar(task: task, timeUnit: widget.timeUnit),
                        ),

                      // Punctuality badge (completed tasks)
                      if (task.punctualityLabel != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4, left: 30),
                          child: _PunctualityBadge(task: task),
                        ),

                      // Work history: recurring tasks show their completion
                      // record; non-recurring tasks show their live work
                      // sessions (start/stop/duration), both tappable to edit.
                      if (task.isRecurring) ...[
                        if (_historyLoading)
                          const Padding(
                            padding: EdgeInsets.only(top: 6, left: 30),
                            child: SizedBox(height: 16, width: 16,
                                child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        else if (_completions != null && _completions!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6, left: 30),
                            child: _CompletionHistoryTable(
                              rows: _completions!,
                              expanded: _historyExpanded,
                              timeUnit: widget.timeUnit,
                              onToggle: () => setState(() => _historyExpanded = !_historyExpanded),
                              onEdited: _reloadHistory,
                            ),
                          ),
                      ] else ...[
                        if (_sessionsLoading)
                          const Padding(
                            padding: EdgeInsets.only(top: 6, left: 30),
                            child: SizedBox(height: 16, width: 16,
                                child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        else if (_sessions != null && _sessions!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6, left: 30),
                            child: _SessionHistoryTable(
                              taskId: task.id,
                              sessions: _sessions!,
                              expanded: _sessionsExpanded,
                              timeUnit: widget.timeUnit,
                              onToggle: () => setState(() => _sessionsExpanded = !_sessionsExpanded),
                              onEdited: _reloadSessions,
                            ),
                          ),
                      ],

                      // Start / Stop button + subtask expand
                      Padding(
                        padding: const EdgeInsets.only(top: 6, left: 30),
                        child: Row(
                          children: [
                            if (!task.isCompleted)
                              _SessionButton(
                                isActive: widget.isSessionActive,
                                onStart: widget.onStartSession,
                                onStop: widget.onStopSession,
                                onRestart: widget.onRestartSession == null
                                    ? null
                                    : () => _showRestartDialog(context),
                              ),
                            const Spacer(),
                            if (task.subtasks.isNotEmpty && widget.onToggleExpand != null)
                              GestureDetector(
                                onTap: widget.onToggleExpand,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '${task.subtasks.length} subtask${task.subtasks.length > 1 ? 's' : ''}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: Colors.grey[600]),
                                    ),
                                    Icon(
                                      widget.isExpanded ? Icons.expand_less : Icons.expand_more,
                                      size: 18,
                                      color: Colors.grey[600],
                                    ),
                                  ],
                                ),
                              ),
                            // In allExpanded mode there's no toggle — just show the count
                            if (task.subtasks.isNotEmpty && widget.onToggleExpand == null)
                              Text(
                                '${task.subtasks.length} subtask${task.subtasks.length > 1 ? 's' : ''}',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: Colors.grey[600]),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        _BottomProgressLine(task: task),
          ],
        ),
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

/// Collapsible completion history table shown in the expanded task card.
class _CompletionHistoryTable extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final bool expanded;
  final String timeUnit;
  final VoidCallback onToggle;

  /// Called after a completion's work sessions have been edited so the parent
  /// can reload the history from the server.
  final Future<void> Function()? onEdited;

  const _CompletionHistoryTable({
    required this.rows,
    required this.expanded,
    required this.onToggle,
    this.timeUnit = 'hours',
    this.onEdited,
  });

  static final _dateFmt = DateFormat('MM-dd-yy');

  String _fmtDate(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso);
    return dt == null ? iso : _dateFmt.format(dt.toLocal());
  }

  String _fmtDuration(Object? minutes) {
    if (minutes is! num) return '—';
    return formatTaskDuration(minutes.round(), timeUnit);
  }

  /// Opens the work-session editor for a single completion row.
  Future<void> _editRow(BuildContext context, Map<String, dynamic> r) async {
    final completionId = r['id'] as int?;
    if (completionId == null) return;
    final rawSessions = (r['work_sessions'] is List)
        ? List<Map<String, dynamic>>.from(
            (r['work_sessions'] as List).whereType<Map>())
        : <Map<String, dynamic>>[];
    final actual = r['actual_minutes'];
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _EditWorkSessionsDialog(
        initialSessions: rawSessions,
        fallbackEnd: DateTime.tryParse('${r['completed_at']}'),
        fallbackMinutes: (actual is num && actual > 0) ? actual.round() : 0,
        timeUnit: timeUnit,
        onSave: (sessions) =>
            TaskApiService.updateCompletionSessions(completionId, sessions),
      ),
    );
    if (saved == true && onEdited != null) {
      await onEdited!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header toggle row
        GestureDetector(
          onTap: onToggle,
          behavior: HitTestBehavior.opaque,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16, color: Colors.grey[600]),
              const SizedBox(width: 4),
              Text(
                'History (${rows.length})',
                style: TextStyle(fontSize: 12, color: Colors.grey[600], fontWeight: FontWeight.w500),
              ),
              if (expanded) ...[
                const SizedBox(width: 6),
                Text(
                  '· tap a row to edit times',
                  style: TextStyle(fontSize: 10, color: Colors.grey[500], fontStyle: FontStyle.italic),
                ),
              ],
            ],
          ),
        ),
        if (expanded) ...[
          const SizedBox(height: 6),
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),   // status icon
              1: IntrinsicColumnWidth(),   // date
              2: IntrinsicColumnWidth(),   // duration
              3: FlexColumnWidth(),        // note
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              // Header row
              TableRow(
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.grey[300]!)),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4, right: 8),
                    child: Text('', style: TextStyle(fontSize: 10, color: Colors.grey[500])),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4, right: 12),
                    child: Text('Date', style: TextStyle(fontSize: 10, color: Colors.grey[500], fontWeight: FontWeight.w600)),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4, right: 12),
                    child: Text('Duration', style: TextStyle(fontSize: 10, color: Colors.grey[500], fontWeight: FontWeight.w600)),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('Note', style: TextStyle(fontSize: 10, color: Colors.grey[500], fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              // Data rows
              for (final r in rows) ...[
                TableRow(
                  children: [
                    TableRowInkWell(
                      onTap: () => _editRow(context, r),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
                        child: _statusIcon(r['status'] as String?),
                      ),
                    ),
                    TableRowInkWell(
                      onTap: () => _editRow(context, r),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 3, bottom: 3, right: 24),
                        child: Text(
                          _fmtDate(r['completed_at'] as String?),
                          style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface),
                        ),
                      ),
                    ),
                    TableRowInkWell(
                      onTap: () => _editRow(context, r),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 3, bottom: 3, right: 12),
                        child: Text(
                          _fmtDuration(r['actual_minutes']),
                          style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                        ),
                      ),
                    ),
                    TableRowInkWell(
                      onTap: () => _editRow(context, r),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          (r['note'] as String?)?.trim().isNotEmpty == true
                              ? r['note'] as String
                              : '',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[600],
                            fontStyle: (r['note'] as String?)?.trim().isNotEmpty == true
                                ? FontStyle.normal
                                : FontStyle.italic,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _statusIcon(String? status) {
    switch (status) {
      case 'skipped':
        return const Tooltip(
          message: 'Skipped',
          child: Icon(Icons.close, size: 14, color: Colors.orange),
        );
      case 'completed':
        return const Tooltip(
          message: 'Completed',
          child: Icon(Icons.check, size: 14, color: Colors.green),
        );
      default:
        return Tooltip(
          message: 'Unknown',
          child: Icon(Icons.check_box_outline_blank, size: 14, color: Colors.grey[400]),
        );
    }
  }
}

/// Live work-session history for a non-recurring task: one row per work
/// session worked so far (start, stop, duration). Tapping the table opens the
/// same interval editor used for completed tasks.
class _SessionHistoryTable extends StatelessWidget {
  final int taskId;
  final List<Map<String, dynamic>> sessions;
  final bool expanded;
  final String timeUnit;
  final VoidCallback onToggle;

  /// Called after the task's work sessions have been edited so the parent can
  /// reload them from the server.
  final Future<void> Function()? onEdited;

  const _SessionHistoryTable({
    required this.taskId,
    required this.sessions,
    required this.expanded,
    required this.onToggle,
    this.timeUnit = 'hours',
    this.onEdited,
  });

  static final _dateFmt = DateFormat('MM-dd-yy');
  static final _timeFmt = DateFormat('h:mm a');

  String _fmtDate(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso);
    return dt == null ? iso : _dateFmt.format(dt.toLocal());
  }

  String _fmtTimeRange(Map<String, dynamic> s) {
    final start = DateTime.tryParse('${s['started_at']}')?.toLocal();
    if (start == null) return '—';
    final end = DateTime.tryParse('${s['ended_at']}')?.toLocal();
    if (end == null) return '${_timeFmt.format(start)} – running';
    return '${_timeFmt.format(start)} – ${_timeFmt.format(end)}';
  }

  String _fmtDuration(Object? minutes) {
    if (minutes is! num) return '—';
    return formatTaskDuration(minutes.round(), timeUnit);
  }

  /// Opens the interval editor seeded with the task's completed sessions.
  Future<void> _edit(BuildContext context) async {
    final completed = sessions
        .where((s) => s['ended_at'] != null)
        .map((s) => <String, dynamic>{
              'started_at': s['started_at'],
              'ended_at': s['ended_at'],
              'notes': s['notes'],
            })
        .toList();
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _EditWorkSessionsDialog(
        initialSessions: completed,
        timeUnit: timeUnit,
        onSave: (s) => TaskApiService.updateTaskSessions(taskId, s),
      ),
    );
    if (saved == true && onEdited != null) {
      await onEdited!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header toggle row
        GestureDetector(
          onTap: onToggle,
          behavior: HitTestBehavior.opaque,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16, color: Colors.grey[600]),
              const SizedBox(width: 4),
              Text(
                'Sessions (${sessions.length})',
                style: TextStyle(fontSize: 12, color: Colors.grey[600], fontWeight: FontWeight.w500),
              ),
              if (expanded) ...[
                const SizedBox(width: 6),
                Text(
                  '· tap a row to edit times',
                  style: TextStyle(fontSize: 10, color: Colors.grey[500], fontStyle: FontStyle.italic),
                ),
              ],
            ],
          ),
        ),
        if (expanded) ...[
          const SizedBox(height: 6),
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),   // status icon
              1: IntrinsicColumnWidth(),   // date
              2: IntrinsicColumnWidth(),   // time range
              3: FlexColumnWidth(),        // duration
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              // Header row
              TableRow(
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.grey[300]!)),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4, right: 8),
                    child: Text('', style: TextStyle(fontSize: 10, color: Colors.grey[500])),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4, right: 12),
                    child: Text('Date', style: TextStyle(fontSize: 10, color: Colors.grey[500], fontWeight: FontWeight.w600)),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4, right: 12),
                    child: Text('Start – Stop', style: TextStyle(fontSize: 10, color: Colors.grey[500], fontWeight: FontWeight.w600)),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('Duration', style: TextStyle(fontSize: 10, color: Colors.grey[500], fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              // Data rows
              for (final s in sessions)
                TableRow(
                  children: [
                    TableRowInkWell(
                      onTap: () => _edit(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
                        child: (s['active'] == true)
                            ? const Tooltip(
                                message: 'Running',
                                child: Icon(Icons.play_arrow, size: 14, color: Colors.blue),
                              )
                            : const Tooltip(
                                message: 'Completed',
                                child: Icon(Icons.check, size: 14, color: Colors.green),
                              ),
                      ),
                    ),
                    TableRowInkWell(
                      onTap: () => _edit(context),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 3, bottom: 3, right: 24),
                        child: Text(
                          _fmtDate(s['started_at'] as String?),
                          style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface),
                        ),
                      ),
                    ),
                    TableRowInkWell(
                      onTap: () => _edit(context),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 3, bottom: 3, right: 24),
                        child: Text(
                          _fmtTimeRange(s),
                          style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                        ),
                      ),
                    ),
                    TableRowInkWell(
                      onTap: () => _edit(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          _fmtDuration(s['duration_minutes']),
                          style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// One editable work-session interval inside the completion editor.
class _SessionDraft {
  DateTime start;
  DateTime end;
  String? notes;
  _SessionDraft({required this.start, required this.end, this.notes});

  int get durationMinutes {
    final d = end.difference(start).inSeconds;
    return d <= 0 ? 0 : (d / 60).round();
  }
}

/// Dialog that lets the user edit a set of work-session intervals. Start/stop
/// times are editable per interval; durations and the total are recomputed on
/// save. Used both for past completions and for a task's live work sessions —
/// the caller supplies the initial intervals and the [onSave] handler.
class _EditWorkSessionsDialog extends StatefulWidget {
  /// Initial intervals. Each entry may contain `started_at` / `ended_at` as ISO
  /// strings (intervals without both ends are skipped).
  final List<Map<String, dynamic>> initialSessions;

  /// Persists the edited intervals. Each entry contains `started_at` and
  /// `ended_at` as `DateTime` objects and may include `notes`.
  final Future<void> Function(List<Map<String, dynamic>> sessions) onSave;

  /// Seed for a single interval when [initialSessions] yields nothing.
  final DateTime? fallbackEnd;
  final int fallbackMinutes;
  final String timeUnit;

  const _EditWorkSessionsDialog({
    required this.initialSessions,
    required this.onSave,
    this.fallbackEnd,
    this.fallbackMinutes = 0,
    this.timeUnit = 'hours',
  });

  @override
  State<_EditWorkSessionsDialog> createState() =>
      _EditWorkSessionsDialogState();
}

class _EditWorkSessionsDialogState
    extends State<_EditWorkSessionsDialog> {
  static final _fmt = DateFormat('MMM d, yyyy · h:mm a');

  late List<_SessionDraft> _sessions;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sessions = _initialSessions();
  }

  List<_SessionDraft> _initialSessions() {
    final result = <_SessionDraft>[];
    for (final item in widget.initialSessions) {
      final start = DateTime.tryParse('${item['started_at']}')?.toLocal();
      final end = DateTime.tryParse('${item['ended_at']}')?.toLocal();
      if (start == null || end == null) continue;
      result.add(_SessionDraft(
        start: start,
        end: end,
        notes: item['notes'] as String?,
      ));
    }
    if (result.isEmpty) {
      // Legacy / single-shot records: seed one interval from the fallback end
      // and recorded total so the user has something to edit.
      final end = widget.fallbackEnd?.toLocal() ?? DateTime.now();
      final minutes = widget.fallbackMinutes;
      result.add(_SessionDraft(
        start: end.subtract(Duration(minutes: minutes)),
        end: end,
      ));
    }
    return result;
  }

  int get _totalMinutes =>
      _sessions.fold(0, (sum, s) => sum + s.durationMinutes);

  Future<DateTime?> _pickDateTime(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(
        date.year, date.month, date.day, time.hour, time.minute);
  }

  String? _validate() {
    final now = DateTime.now().add(const Duration(minutes: 1));
    for (var i = 0; i < _sessions.length; i++) {
      final s = _sessions[i];
      if (s.end.isBefore(s.start)) {
        return 'Interval ${i + 1}: stop time is before the start time.';
      }
      if (s.start.isAfter(now) || s.end.isAfter(now)) {
        return 'Interval ${i + 1}: times cannot be in the future.';
      }
    }
    return null;
  }

  Future<void> _save() async {
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        _sessions
            .map((s) => {
                  'started_at': s.start,
                  'ended_at': s.end,
                  if (s.notes != null) 'notes': s.notes,
                })
            .toList(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Failed to save: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit work sessions'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < _sessions.length; i++) ...[
                _buildSessionTile(i),
                const SizedBox(height: 8),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _saving
                      ? null
                      : () {
                          final last = _sessions.isNotEmpty
                              ? _sessions.last.end
                              : DateTime.now();
                          setState(() {
                            _sessions.add(_SessionDraft(start: last, end: last));
                            _error = null;
                          });
                        },
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add interval'),
                ),
              ),
              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Total',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  Text(formatTaskDuration(_totalMinutes, widget.timeUnit),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: TextStyle(color: Colors.red[700], fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Widget _buildSessionTile(int index) {
    final s = _sessions[index];
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey[300]!),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Interval ${index + 1}',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(formatTaskDuration(s.durationMinutes, widget.timeUnit),
                  style: TextStyle(fontSize: 12, color: Colors.grey[700])),
              if (_sessions.length > 1)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  tooltip: 'Remove interval',
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                            _sessions.removeAt(index);
                            _error = null;
                          }),
                  icon: Icon(Icons.delete_outline, color: Colors.red[400]),
                ),
            ],
          ),
          _buildTimeRow(
            label: 'Start',
            value: s.start,
            onPick: () async {
              final picked = await _pickDateTime(s.start);
              if (picked != null) {
                setState(() {
                  s.start = picked;
                  _error = null;
                });
              }
            },
          ),
          _buildTimeRow(
            label: 'Stop',
            value: s.end,
            onPick: () async {
              final picked = await _pickDateTime(s.end);
              if (picked != null) {
                setState(() {
                  s.end = picked;
                  _error = null;
                });
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTimeRow({
    required String label,
    required DateTime value,
    required VoidCallback onPick,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ),
          Expanded(
            child: OutlinedButton(
              onPressed: _saving ? null : onPick,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                alignment: Alignment.centerLeft,
              ),
              child: Text(_fmt.format(value),
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Formats a minute count for display, honoring the user's time-unit preference.
String formatTaskDuration(int minutes, String timeUnit) {
  if (timeUnit == 'hours') {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }
  return '${minutes}m';
}

/// "Time left" value from an explicit due date (used when a collapsed parent
/// should reflect its most-dire subtask instead of its own due date).
String _timeLeftShortFromDate(DateTime? due) {
  if (due == null) return '—';
  final dueLocal = due.toLocal();
  final now = DateTime.now();
  // Compare by calendar day, not a rolling 24-hour window, so a task due early
  // tomorrow doesn't read as "Today" just because it's <24h away.
  final dueDay = DateTime(dueLocal.year, dueLocal.month, dueLocal.day);
  final today = DateTime(now.year, now.month, now.day);
  final dayDiff = dueDay.difference(today).inDays;
  if (dayDiff < 0) return '${-dayDiff}d late';
  if (dayDiff == 0) return 'Today';
  return '${dayDiff}d';
}

/// Two compact columns ("Time left" / "Duration") with small headers, shown on
/// the right edge of the preview card in place of the old chips.
class _MetricColumns extends StatelessWidget {
  final Task task;
  final String timeUnit;

  /// When set, the "Time left" column uses this date instead of the task's own
  /// due date. Lets a collapsed parent show its most-dire subtask's urgency.
  final DateTime? timeLeftDueDate;

  const _MetricColumns({
    required this.task,
    required this.timeUnit,
    this.timeLeftDueDate,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveDue = timeLeftDueDate ?? task.dueDate;
    final fromSubtask =
        timeLeftDueDate != null && timeLeftDueDate != task.dueDate;
    final hasDue = effectiveDue != null;
    final hasDuration = task.durationMinutes != null && task.durationMinutes! > 0;
    if (!hasDue && !hasDuration) return const SizedBox.shrink();

    final isOverdue =
        hasDue && DateTime.now().isAfter(effectiveDue) && !task.isCompleted;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasDue)
            _MetricColumn(
              header: fromSubtask ? 'Time left ↘' : 'Time left',
              value: _timeLeftShortFromDate(effectiveDue),
              valueColor: isOverdue ? Colors.red[600] : null,
            ),
          if (hasDue && hasDuration) const SizedBox(width: 12),
          if (hasDuration)
            _MetricColumn(
              header: 'Duration',
              value: formatTaskDuration(task.durationMinutes!, timeUnit),
            ),
        ],
      ),
    );
  }
}

class _MetricColumn extends StatelessWidget {
  final String header;
  final String value;
  final Color? valueColor;
  const _MetricColumn({required this.header, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          header,
          style: TextStyle(
            fontSize: 8,
            color: Colors.grey[500],
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: valueColor ?? Colors.grey[800],
          ),
        ),
      ],
    );
  }
}

/// A thin progress line that hugs the bottom edge of the card. Stays visible
/// when the card is collapsed, as long as the task has an estimated duration.
class _BottomProgressLine extends StatelessWidget {
  final Task task;
  const _BottomProgressLine({required this.task});

  @override
  Widget build(BuildContext context) {
    if (task.durationMinutes == null || task.durationMinutes! <= 0) {
      return const SizedBox.shrink();
    }
    final progress = task.progressFraction;
    return LinearProgressIndicator(
      value: progress,
      minHeight: 3,
      backgroundColor: Colors.grey[200],
      color: task.isCompleted
          ? Colors.green
          : (progress >= 1.0 ? Colors.orange : Colors.blueGrey),
    );
  }
}

class _DurationChip extends StatelessWidget {
  final int minutes;
  final String timeUnit;
  const _DurationChip({required this.minutes, required this.timeUnit});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(Icons.timer_outlined, size: 14, color: Colors.grey[600]),
      label: Text(
        formatTaskDuration(minutes, timeUnit),
        style: TextStyle(fontSize: 11, color: Colors.grey[800]),
      ),
      backgroundColor: Colors.grey[100],
      padding: const EdgeInsets.symmetric(horizontal: 2),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _DueDateChip extends StatelessWidget {
  final Task task;
  final Color urgencyColor;
  const _DueDateChip({required this.task, required this.urgencyColor});

  @override
  Widget build(BuildContext context) {
    final isOverdue = task.dueDate != null && DateTime.now().isAfter(task.dueDate!) && !task.isCompleted;
    return Chip(
      label: Text(
        task.dueDateLabel,
        style: TextStyle(
          fontSize: 11,
          color: isOverdue ? Colors.white : Colors.grey[800],
          fontWeight: isOverdue ? FontWeight.bold : null,
        ),
      ),
      backgroundColor: isOverdue ? urgencyColor : Colors.grey[100],
      padding: const EdgeInsets.symmetric(horizontal: 2),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _TagChip extends StatelessWidget {
  final Tag tag;
  const _TagChip({required this.tag});

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(tag.name, style: const TextStyle(fontSize: 11, color: Colors.white)),
      backgroundColor: tag.flutterColor,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final Task task;
  final String timeUnit;
  const _ProgressBar({required this.task, this.timeUnit = 'hours'});

  String _fmt(int minutes) {
    if (timeUnit == 'hours') {
      final h = minutes ~/ 60;
      final m = minutes % 60;
      if (h == 0) return '${m}m';
      if (m == 0) return '${h}h';
      return '${h}h ${m}m';
    }
    return '${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final progress = task.progressFraction;
    final actualMin = task.liveActualMinutes.round();
    final estMin = task.durationMinutes ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 5,
            backgroundColor: Colors.grey[200],
            color: progress >= 1.0 ? Colors.orange : Colors.blueGrey,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${_fmt(actualMin)} / ${_fmt(estMin)}'
          '${task.isSessionActive ? ' · running' : ''}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[500]),
        ),
      ],
    );
  }
}

class _PunctualityBadge extends StatelessWidget {
  final Task task;
  const _PunctualityBadge({required this.task});

  @override
  Widget build(BuildContext context) {
    final label = task.punctualityLabel!;
    final isOnTime = task.punctuallyCompleted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isOnTime ? Colors.green[50] : Colors.red[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isOnTime ? Colors.green[300]! : Colors.red[200]!,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: isOnTime ? Colors.green[700] : Colors.red[700],
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _SessionButton extends StatelessWidget {
  final bool isActive;
  final VoidCallback? onStart;
  final VoidCallback? onStop;
  final VoidCallback? onRestart;
  const _SessionButton({required this.isActive, this.onStart, this.onStop, this.onRestart});

  @override
  Widget build(BuildContext context) {
    if (!isActive) {
      return OutlinedButton.icon(
        onPressed: onStart,
        icon: const Icon(Icons.play_circle_outline, size: 16),
        label: const Text('Start', style: TextStyle(fontSize: 12)),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: Colors.blueGrey[600],
          side: BorderSide(color: Colors.blueGrey[300]!),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton.icon(
          onPressed: onStop,
          icon: const Icon(Icons.stop_circle_outlined, size: 16),
          label: const Text('Stop', style: TextStyle(fontSize: 12)),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: Colors.orange[700],
            side: BorderSide(color: Colors.orange[400]!),
          ),
        ),
        if (onRestart != null) ...[
          const SizedBox(width: 6),
          OutlinedButton.icon(
            onPressed: onRestart,
            icon: const Icon(Icons.restart_alt, size: 16),
            label: const Text('Restart', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: Colors.blueGrey[600],
              side: BorderSide(color: Colors.blueGrey[300]!),
            ),
          ),
        ],
      ],
    );
  }
}

/// Recursively renders a task and its subtasks.
/// [viewMode] controls compactness and depth of the tree.
class TaskCardTree extends StatelessWidget {
  final Task task;
  final Map<int, bool> activeSessions;
  final void Function(Task)? onComplete;
  final void Function(Task)? onSkip;
  final void Function(Task)? onEdit;
  final void Function(Task)? onDelete;
  final void Function(Task)? onStartSession;
  final void Function(Task)? onStopSession;
  final void Function(Task task, String mode, DateTime? startedAt)? onRestartSession;
  final int depth;
  final String timeUnit;
  final TaskViewMode viewMode;

  /// When non-null, overrides [viewMode] expansion behavior: cards render as
  /// compact previews whose subtask dropdowns default to this value and always
  /// offer a manual toggle.
  final bool? expandAll;

  /// When false, nested subtasks are never rendered inline (flat list mode);
  /// the card instead shows a subtask-count label.
  final bool renderSubtasks;

  /// Optional comparator used to order subtasks before rendering.
  final Comparator<Task>? subtaskSort;

  const TaskCardTree({
    super.key,
    required this.task,
    this.activeSessions = const {},
    this.onComplete,
    this.onSkip,
    this.onEdit,
    this.onDelete,
    this.onStartSession,
    this.onStopSession,
    this.onRestartSession,
    this.depth = 0,
    this.timeUnit = 'hours',
    this.viewMode = TaskViewMode.topLevelPreview,
    this.expandAll,
    this.renderSubtasks = true,
    this.subtaskSort,
  });

  @override
  Widget build(BuildContext context) {
    return _ExpandableTaskCard(
      task: task,
      isSessionActive: activeSessions[task.id] ?? false,
      depth: depth,
      timeUnit: timeUnit,
      viewMode: viewMode,
      expandAll: expandAll,
      renderSubtasks: renderSubtasks,
      subtaskSort: subtaskSort,
      onComplete: onComplete != null ? () => onComplete!(task) : null,
      onSkip: onSkip != null ? () => onSkip!(task) : null,
      onEdit: onEdit != null ? () => onEdit!(task) : null,
      onDelete: onDelete != null ? () => onDelete!(task) : null,
      onStartSession: onStartSession != null ? () => onStartSession!(task) : null,
      onStopSession: onStopSession != null ? () => onStopSession!(task) : null,
      onRestartSession: onRestartSession != null
          ? (mode, startedAt) => onRestartSession!(task, mode, startedAt)
          : null,
      buildSubtasks: (subtask) => TaskCardTree(
        task: subtask,
        activeSessions: activeSessions,
        onComplete: onComplete,
        onSkip: onSkip,
        onEdit: onEdit,
        onDelete: onDelete,
        onStartSession: onStartSession,
        onStopSession: onStopSession,
        onRestartSession: onRestartSession,
        depth: depth + 1,
        timeUnit: timeUnit,
        viewMode: viewMode,
        expandAll: expandAll,
        renderSubtasks: renderSubtasks,
        subtaskSort: subtaskSort,
      ),
    );
  }
}

class _ExpandableTaskCard extends StatefulWidget {
  final Task task;
  final bool isSessionActive;
  final int depth;
  final String timeUnit;
  final TaskViewMode viewMode;
  final bool? expandAll;
  final bool renderSubtasks;
  final Comparator<Task>? subtaskSort;
  final VoidCallback? onComplete;
  final VoidCallback? onSkip;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onStartSession;
  final VoidCallback? onStopSession;
  final void Function(String mode, DateTime? startedAt)? onRestartSession;
  final Widget Function(Task) buildSubtasks;

  const _ExpandableTaskCard({
    required this.task,
    required this.isSessionActive,
    required this.depth,
    required this.buildSubtasks,
    this.timeUnit = 'hours',
    this.viewMode = TaskViewMode.topLevelPreview,
    this.expandAll,
    this.renderSubtasks = true,
    this.subtaskSort,
    this.onComplete,
    this.onSkip,
    this.onEdit,
    this.onDelete,
    this.onStartSession,
    this.onStopSession,
    this.onRestartSession,
  });

  @override
  State<_ExpandableTaskCard> createState() => _ExpandableTaskCardState();
}

class _ExpandableTaskCardState extends State<_ExpandableTaskCard> {
  bool _expanded = false;

  /// True when the two-toggle (todo screen) behavior is active.
  bool get _usesExpandAll => widget.expandAll != null;

  @override
  void initState() {
    super.initState();
    _expanded = widget.expandAll ?? false;
  }

  @override
  void didUpdateWidget(covariant _ExpandableTaskCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep local expansion in sync when the global "expand all" toggle flips.
    if (widget.expandAll != null && widget.expandAll != oldWidget.expandAll) {
      _expanded = widget.expandAll!;
    }
  }

  bool get _isPreview =>
      _usesExpandAll ? true : widget.viewMode != TaskViewMode.allExpanded;

  bool get _showSubtasks {
    if (!widget.renderSubtasks) return false;
    if (_usesExpandAll) return _expanded;
    switch (widget.viewMode) {
      case TaskViewMode.topLevelPreview: return false;
      case TaskViewMode.allPreview:      return _expanded;
      case TaskViewMode.allExpanded:     return true;
    }
  }

  /// Toggle is offered when the user controls expansion per card.
  VoidCallback? get _toggleExpand {
    if (!widget.renderSubtasks) return null;
    if (_usesExpandAll) {
      return () => setState(() => _expanded = !_expanded);
    }
    return widget.viewMode == TaskViewMode.allPreview
        ? () => setState(() => _expanded = !_expanded)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final subtasks = widget.subtaskSort != null
        ? (List<Task>.from(widget.task.subtasks)..sort(widget.subtaskSort!))
        : widget.task.subtasks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TaskCard(
          task: widget.task,
          isSessionActive: widget.isSessionActive,
          depth: widget.depth,
          isPreview: _isPreview,
          isExpanded: _showSubtasks,
          onToggleExpand: _toggleExpand,
          timeUnit: widget.timeUnit,
          onComplete: widget.onComplete,
          onSkip: widget.onSkip,
          onEdit: widget.onEdit,
          onDelete: widget.onDelete,
          onStartSession: widget.onStartSession,
          onStopSession: widget.onStopSession,
          onRestartSession: widget.onRestartSession,
        ),
        if (_showSubtasks)
          Column(
            children: subtasks.map(widget.buildSubtasks).toList(),
          ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../models/task.dart';
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
  });

  @override
  State<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<TaskCard> {
  /// True when the user tapped an individual card to expand it from preview mode.
  bool _isCardExpanded = false;

  Color get _urgencyColor => urgencyColor(widget.task.startBy, widget.task.durationMinutes);

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
          onTap: () => setState(() => _isCardExpanded = true),
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
                              onTap: () => setState(() => _isCardExpanded = false),
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
  final diff = due.difference(DateTime.now());
  if (diff.isNegative) {
    final d = (-diff).inDays;
    return d > 0 ? '${d}d late' : 'Late';
  }
  if (diff.inDays == 0) return 'Today';
  return '${diff.inDays}d';
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
    final actualMin = task.actualDurationMinutes?.toInt() ?? 0;
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
          '${_fmt(actualMin)} / ${_fmt(estMin)}',
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
  const _SessionButton({required this.isActive, this.onStart, this.onStop});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: isActive ? onStop : onStart,
      icon: Icon(isActive ? Icons.stop_circle_outlined : Icons.play_circle_outline, size: 16),
      label: Text(isActive ? 'Stop' : 'Start', style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: isActive ? Colors.orange[700] : Colors.blueGrey[600],
        side: BorderSide(color: isActive ? Colors.orange[400]! : Colors.blueGrey[300]!),
      ),
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
      buildSubtasks: (subtask) => TaskCardTree(
        task: subtask,
        activeSessions: activeSessions,
        onComplete: onComplete,
        onSkip: onSkip,
        onEdit: onEdit,
        onDelete: onDelete,
        onStartSession: onStartSession,
        onStopSession: onStopSession,
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
        ),
        if (_showSubtasks)
          Column(
            children: subtasks.map(widget.buildSubtasks).toList(),
          ),
      ],
    );
  }
}

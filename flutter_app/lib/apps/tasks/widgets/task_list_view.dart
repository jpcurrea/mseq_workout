import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/task.dart';
import 'task_card.dart';

/// How a task list is ordered.
enum TaskSortMode {
  /// Least time until the due date first (most urgent).
  timeLeft,
  /// Longest estimated duration first.
  duration,
  /// Soonest due date first.
  dueDate,
  /// Time left divided by duration — lowest (most dire) first.
  direness,
  /// Manual drag-defined order (by each task's sortOrder).
  manual,
}

String taskSortModeLabel(TaskSortMode mode) {
  switch (mode) {
    case TaskSortMode.timeLeft: return 'Time left (most urgent)';
    case TaskSortMode.duration: return 'Duration (longest first)';
    case TaskSortMode.dueDate:  return 'Due date (soonest first)';
    case TaskSortMode.direness: return 'Direness (time left ÷ duration)';
    case TaskSortMode.manual:   return 'Manual (drag to reorder)';
  }
}

/// A reusable task list with the same search / sort / filter / group / expand
/// behaviour as the main to-do list, plus manual drag-to-reorder. It is
/// presentation-only: the host supplies the tasks and action callbacks.
class TaskListView extends StatefulWidget {
  final List<Task> tasks;
  final List<Tag> tags;
  final Set<int> activeSessions;
  final String timeUnit;

  /// Whether completed tasks are shown. When [onToggleCompleted] is null the
  /// "Done" toggle is hidden (the host controls completed-task fetching).
  final bool showCompleted;
  final ValueChanged<bool>? onToggleCompleted;

  // Task action callbacks (match TaskCardTree signatures).
  final void Function(Task)? onComplete;
  final void Function(Task)? onSkip;
  final void Function(Task)? onEdit;
  final void Function(Task)? onDelete;
  final void Function(Task)? onStartSession;
  final void Function(Task)? onStopSession;
  final void Function(Task task, String mode, DateTime? startedAt)? onRestartSession;

  /// Persist a new manual order (top-level ids, in order). When null, drag
  /// reordering is disabled.
  final Future<void> Function(List<int> orderedIds)? onReorder;

  /// Optional pull-to-refresh handler (ignored when [embedded] is true).
  final Future<void> Function()? onRefresh;

  /// Prefix for SharedPreferences keys so independent lists keep separate
  /// sort/view preferences.
  final String prefsKeyPrefix;

  /// Sort mode applied when no preference has been stored yet (e.g. honoring a
  /// plan block's `sort=` directive on first render).
  final TaskSortMode? initialSortMode;

  /// When true the list renders inline (shrink-wrapped, no internal scroll or
  /// RefreshIndicator) so it can be embedded inside another scroll view.
  final bool embedded;

  // ── Multi-select support (optional) ──────────────────────────────────────────
  // When [selectionMode] is true the cards show selection checkboxes/tints and
  // their action callbacks are suppressed. The host drives the selection set.

  /// Whether the list is currently in multi-select mode.
  final bool selectionMode;

  /// Ids of the currently selected tasks (only meaningful in selection mode).
  final Set<int> selectedTaskIds;

  /// Called on long-press of a card to enter selection mode. When null,
  /// long-press selection is disabled.
  final ValueChanged<int>? onEnterSelection;

  /// Called when a card is tapped (or its checkbox toggled) while in
  /// selection mode.
  final ValueChanged<int>? onToggleSelection;

  /// Ids of tasks currently playing the completion (flash + collapse) animation.
  final Set<int> completingTaskIds;

  /// Called once a task's completion animation finishes so the host can remove
  /// it from the list.
  final ValueChanged<int>? onCompletionDone;

  /// Notifies the host whenever the displayed (filtered + sorted) task list
  /// changes, so it can support "select all".
  final ValueChanged<List<Task>>? onDisplayedTasksChanged;

  const TaskListView({
    super.key,
    required this.tasks,
    this.tags = const [],
    this.activeSessions = const {},
    this.timeUnit = 'hours',
    this.showCompleted = false,
    this.onToggleCompleted,
    this.onComplete,
    this.onSkip,
    this.onEdit,
    this.onDelete,
    this.onStartSession,
    this.onStopSession,
    this.onRestartSession,
    this.onReorder,
    this.onRefresh,
    this.prefsKeyPrefix = 'task',
    this.initialSortMode,
    this.embedded = false,
    this.selectionMode = false,
    this.selectedTaskIds = const {},
    this.onEnterSelection,
    this.onToggleSelection,
    this.completingTaskIds = const {},
    this.onCompletionDone,
    this.onDisplayedTasksChanged,
  });

  @override
  State<TaskListView> createState() => _TaskListViewState();
}

class _TaskListViewState extends State<TaskListView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  final Set<int> _selectedTagIds = {};
  TaskSortMode _sortMode = TaskSortMode.timeLeft;
  bool _flatView = false;
  bool _expandAll = false;

  /// Ids last reported via [TaskListView.onDisplayedTasksChanged]; used to avoid
  /// redundant notifications.
  List<int> _lastNotifiedIds = const [];

  String get _kSort => '${widget.prefsKeyPrefix}_sort_mode';
  String get _kFlat => '${widget.prefsKeyPrefix}_flat_view';
  String get _kExpand => '${widget.prefsKeyPrefix}_expand_all';

  @override
  void initState() {
    super.initState();
    if (widget.initialSortMode != null) _sortMode = widget.initialSortMode!;
    _loadPrefs();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _flatView = prefs.getBool(_kFlat) ?? false;
      _expandAll = prefs.getBool(_kExpand) ?? false;
      final sortName = prefs.getString(_kSort);
      _sortMode = TaskSortMode.values.firstWhere(
        (m) => m.name == sortName,
        orElse: () => widget.initialSortMode ?? TaskSortMode.timeLeft,
      );
    });
  }

  Future<void> _setSortMode(TaskSortMode mode) async {
    setState(() => _sortMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSort, mode.name);
  }

  Future<void> _setFlatView(bool value) async {
    setState(() => _flatView = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kFlat, value);
  }

  Future<void> _setExpandAll(bool value) async {
    setState(() => _expandAll = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kExpand, value);
  }

  // ── Sorting / filtering helpers ─────────────────────────────────────────────

  bool get _sortAscending => _sortMode != TaskSortMode.duration;

  /// "Direness" = remaining time relative to the work required.
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
      case TaskSortMode.manual:   return t.sortOrder;
    }
  }

  int _cmpNullable(num? a, num? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1; // nulls last
    if (b == null) return -1;
    return _sortAscending ? a.compareTo(b) : b.compareTo(a);
  }

  /// Comparator for individual tasks under the active mode. Manual mode keeps a
  /// stable tie-break by id so unset positions don't jump around.
  int _cmpTask(Task a, Task b, DateTime now) {
    if (_sortMode == TaskSortMode.manual) {
      final c = _cmpNullable(a.sortOrder, b.sortOrder);
      return c != 0 ? c : a.id.compareTo(b.id);
    }
    return _cmpNullable(_metric(a, now), _metric(b, now));
  }

  Comparator<Task> get _subtaskComparator {
    final now = DateTime.now();
    return (a, b) => _cmpTask(a, b, now);
  }

  /// The "most prominent" metric across a task and all its descendants.
  num? _representativeMetric(Task t, DateTime now) {
    if (_sortMode == TaskSortMode.manual) return t.sortOrder;
    num? best;
    void visit(Task x) {
      final m = _metric(x, now);
      if (m != null) {
        best = best == null
            ? m
            : (_sortAscending ? math.min(best!, m) : math.max(best!, m));
      }
      for (final s in x.subtasks) {
        visit(s);
      }
    }
    visit(t);
    return best;
  }

  bool _matchesTagFilter(Task t) {
    if (_selectedTagIds.isEmpty) return true;
    return t.tags.any((tag) => _selectedTagIds.contains(tag.id));
  }

  bool _treeMatchesTagFilter(Task t) {
    if (_matchesTagFilter(t)) return true;
    return t.subtasks.any(_treeMatchesTagFilter);
  }

  // ── Search matching ─────────────────────────────────────────────────────────

  String _searchHaystack(Task t) {
    final parts = <String>[
      t.title,
      t.description ?? '',
      ...t.tags.map((tag) => tag.name),
    ];
    if (t.dueDate != null) {
      final d = t.dueDate!;
      parts.add(
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}-'
        '${(d.year % 100).toString().padLeft(2, '0')}',
      );
      parts.add(t.dueDateLabel);
    }
    return parts.join(' ').toLowerCase();
  }

  List<_SearchToken> _tokenizeSearch(String query) {
    final tokens = <_SearchToken>[];
    final buf = StringBuffer();
    bool inQuotes = false;
    bool quoted = false;

    void flush() {
      final text = buf.toString();
      buf.clear();
      if (text.isEmpty) {
        if (quoted) tokens.add(const _SearchToken.term(''));
        quoted = false;
        return;
      }
      if (!quoted) {
        final upper = text.toUpperCase();
        if (upper == 'AND') { tokens.add(const _SearchToken.op('AND')); quoted = false; return; }
        if (upper == 'OR') { tokens.add(const _SearchToken.op('OR')); quoted = false; return; }
      }
      tokens.add(_SearchToken.term(text.toLowerCase()));
      quoted = false;
    }

    for (final rune in query.runes) {
      final ch = String.fromCharCode(rune);
      if (ch == '"') {
        if (inQuotes) { inQuotes = false; flush(); }
        else { flush(); inQuotes = true; quoted = true; }
      } else if (!inQuotes && ch.trim().isEmpty) {
        flush();
      } else {
        buf.write(ch);
      }
    }
    flush();
    return tokens.where((t) => !(t.isTerm && t.value.isEmpty)).toList();
  }

  /// OR-of-ANDs — explicit AND binds tighter than OR; adjacent terms default OR.
  bool _searchMatches(String haystack, List<_SearchToken> tokens) {
    if (tokens.isEmpty) return true;
    final groups = <List<String>>[];
    var current = <String>[];
    var pendingOp = 'OR';
    for (final tok in tokens) {
      if (tok.isOp) {
        pendingOp = tok.value;
        continue;
      }
      if (current.isEmpty) {
        current.add(tok.value);
      } else if (pendingOp == 'AND') {
        current.add(tok.value);
      } else {
        groups.add(current);
        current = [tok.value];
      }
      pendingOp = 'OR';
    }
    if (current.isNotEmpty) groups.add(current);
    if (groups.isEmpty) return true;
    return groups.any((group) => group.every(haystack.contains));
  }

  bool _matchesSearch(Task t) {
    final tokens = _tokenizeSearch(_searchQuery);
    if (tokens.isEmpty) return true;
    return _searchMatches(_searchHaystack(t), tokens);
  }

  bool _treeMatchesSearch(Task t) {
    if (_searchQuery.trim().isEmpty) return true;
    if (_matchesSearch(t)) return true;
    return t.subtasks.any(_treeMatchesSearch);
  }

  void _flatten(Task t, List<Task> out) {
    out.add(t);
    for (final s in t.subtasks) {
      _flatten(s, out);
    }
  }

  /// The task list to render given the active view + sort + tag filter.
  List<Task> get _displayTasks {
    final now = DateTime.now();
    if (_flatView) {
      final all = <Task>[];
      for (final t in widget.tasks) {
        _flatten(t, all);
      }
      final filtered =
          all.where((t) => _matchesTagFilter(t) && _matchesSearch(t)).toList();
      filtered.sort((a, b) => _cmpTask(a, b, now));
      return filtered;
    }
    final roots = widget.tasks
        .where((t) => _treeMatchesTagFilter(t) && _treeMatchesSearch(t))
        .toList();
    roots.sort((a, b) {
      if (_sortMode == TaskSortMode.manual) {
        final c = _cmpNullable(a.sortOrder, b.sortOrder);
        return c != 0 ? c : a.id.compareTo(b.id);
      }
      return _cmpNullable(_representativeMetric(a, now), _representativeMetric(b, now));
    });
    return roots;
  }

  // ── Drag reorder ────────────────────────────────────────────────────────────

  /// Drag is available only in grouped (top-level) mode and when the host
  /// provides an [onReorder] persister. Disabled while selecting.
  bool get _canReorder =>
      widget.onReorder != null && !_flatView && !widget.selectionMode;

  Future<void> _handleReorder(int oldIndex, int newIndex) async {
    final list = List<Task>.from(_displayTasks);
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    final orderedIds = list.map((t) => t.id).toList();
    // First drag after a parameter sort seeds the manual order from the
    // current arrangement, then switches into Manual mode.
    if (_sortMode != TaskSortMode.manual) {
      await _setSortMode(TaskSortMode.manual);
    }
    await widget.onReorder?.call(orderedIds);
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final List<Widget> children;
    if (widget.embedded) {
      // Compact layout for plan-embedded lists: a single row with the search
      // box first, then the sort dropdown and view toggles. Tag filtering is
      // omitted to keep the embed lightweight.
      children = [_buildCompactBar(context)];
    } else {
      children = [
        _TaskSearchBar(
          controller: _searchCtrl,
          onChanged: (v) => setState(() => _searchQuery = v),
          onClear: () => setState(() {
            _searchCtrl.clear();
            _searchQuery = '';
          }),
        ),
        _TaskSortBar(
          sortMode: _sortMode,
          onSortSelected: _setSortMode,
          flatView: _flatView,
          onToggleFlat: () => _setFlatView(!_flatView),
          expandAll: _expandAll,
          onToggleExpandAll: () => _setExpandAll(!_expandAll),
        ),
        _TaskFilterBar(
          tags: widget.tags,
          selectedTagIds: _selectedTagIds,
          showCompleted: widget.showCompleted,
          onToggleCompleted: widget.onToggleCompleted,
          onTagsChanged: (sel) => setState(() {
            _selectedTagIds
              ..clear()
              ..addAll(sel);
          }),
        ),
      ];
    }

    if (widget.embedded) {
      children.add(_buildList(shrinkWrap: true));
      return Column(mainAxisSize: MainAxisSize.min, children: children);
    }

    children.add(Expanded(child: _buildList(shrinkWrap: false)));
    return Column(children: children);
  }

  /// A single-row control bar used in embedded mode: search field, then the
  /// sort dropdown, flat/grouped toggle, and expand-all toggle.
  Widget _buildCompactBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _searchQuery = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search…',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        tooltip: 'Clear search',
                        onPressed: () => setState(() {
                          _searchCtrl.clear();
                          _searchQuery = '';
                        }),
                      ),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.sort, size: 18),
          const SizedBox(width: 4),
          DropdownButton<TaskSortMode>(
            value: _sortMode,
            isDense: true,
            underline: const SizedBox.shrink(),
            onChanged: (mode) {
              if (mode != null) _setSortMode(mode);
            },
            items: TaskSortMode.values
                .map((m) => DropdownMenuItem(
                      value: m,
                      child: Text(taskSortModeLabel(m),
                          style: const TextStyle(fontSize: 13)),
                    ))
                .toList(),
          ),
          IconButton(
            icon: Icon(_flatView ? Icons.view_list : Icons.account_tree, size: 20),
            tooltip: _flatView
                ? 'Flat view (all tasks individually)'
                : 'Grouped view (subtasks nested)',
            visualDensity: VisualDensity.compact,
            onPressed: () => _setFlatView(!_flatView),
          ),
          IconButton(
            icon: Icon(_expandAll ? Icons.unfold_less : Icons.unfold_more, size: 20),
            tooltip: _expandAll ? 'Collapse subtasks' : 'Expand subtasks',
            visualDensity: VisualDensity.compact,
            onPressed: () => _setExpandAll(!_expandAll),
          ),
        ],
      ),
    );
  }

  Widget _buildList({required bool shrinkWrap}) {
    final sorted = _displayTasks;
    _maybeNotifyDisplayed(sorted);
    if (widget.tasks.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: Text('No tasks yet', style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    if (sorted.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: Text('No tasks match the current filters',
              style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    final subtaskSort = _subtaskComparator;
    final selecting = widget.selectionMode;
    Widget cardFor(Task task) => TaskCardTree(
          key: ValueKey(task.id),
          task: task,
          activeSessions: {for (final id in widget.activeSessions) id: true},
          expandAll: _expandAll,
          renderSubtasks: !_flatView,
          subtaskSort: subtaskSort,
          timeUnit: widget.timeUnit,
          onComplete: selecting ? null : widget.onComplete,
          onSkip: selecting ? null : widget.onSkip,
          onEdit: selecting ? null : widget.onEdit,
          onDelete: selecting ? null : widget.onDelete,
          onStartSession: selecting ? null : widget.onStartSession,
          onStopSession: selecting ? null : widget.onStopSession,
          onRestartSession: selecting ? null : widget.onRestartSession,
        );

    const padding = EdgeInsets.symmetric(horizontal: 12, vertical: 8);

    Widget list;
    if (_canReorder) {
      list = ReorderableListView.builder(
        padding: padding,
        shrinkWrap: shrinkWrap,
        physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
        buildDefaultDragHandles: false,
        itemCount: sorted.length,
        onReorder: _handleReorder,
        itemBuilder: (_, i) => Padding(
          key: ValueKey(sorted[i].id),
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ReorderableDragStartListener(
                index: i,
                child: const Padding(
                  padding: EdgeInsets.only(top: 12, right: 2),
                  child: Icon(Icons.drag_handle, size: 20, color: Colors.grey),
                ),
              ),
              Expanded(child: _decorateCard(sorted[i], cardFor(sorted[i]))),
            ],
          ),
        ),
      );
    } else {
      list = ListView.builder(
        padding: padding,
        shrinkWrap: shrinkWrap,
        physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
        itemCount: sorted.length,
        itemBuilder: (_, i) => _decorateCard(sorted[i], cardFor(sorted[i])),
      );
    }

    if (shrinkWrap || widget.onRefresh == null) return list;
    return RefreshIndicator(onRefresh: widget.onRefresh!, child: list);
  }

  /// Fires [TaskListView.onDisplayedTasksChanged] (post-frame) when the visible
  /// list changes, so the host can support "select all".
  void _maybeNotifyDisplayed(List<Task> display) {
    if (widget.onDisplayedTasksChanged == null) return;
    final ids = display.map((t) => t.id).toList();
    if (listEquals(ids, _lastNotifiedIds)) return;
    _lastNotifiedIds = ids;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onDisplayedTasksChanged!(display);
    });
  }

  /// Wraps a task card with the optional selection visuals (checkbox + tint +
  /// long-press / tap gestures) and the completion (flash + collapse) animation.
  Widget _decorateCard(Task task, Widget card) {
    Widget content = card;

    if (widget.selectionMode) {
      final isSelected = widget.selectedTaskIds.contains(task.id);
      content = Stack(
        children: [
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
                onChanged: (_) => widget.onToggleSelection?.call(task.id),
              ),
              Expanded(child: card),
            ],
          ),
        ],
      );
    }

    if (widget.onEnterSelection != null || widget.onToggleSelection != null) {
      content = GestureDetector(
        onLongPress: widget.selectionMode
            ? null
            : () => widget.onEnterSelection?.call(task.id),
        onTap: widget.selectionMode
            ? () => widget.onToggleSelection?.call(task.id)
            : null,
        child: content,
      );
    }

    if (widget.onCompletionDone != null) {
      content = _TaskCompletionWrapper(
        key: ValueKey('completion_${task.id}'),
        completing: widget.completingTaskIds.contains(task.id),
        onDismissed: () => widget.onCompletionDone?.call(task.id),
        child: content,
      );
    }

    return content;
  }
}

// ── Completion animation wrapper ──────────────────────────────────────────────

/// Plays a brief green flash then collapses the card's height when [completing]
/// flips to true, invoking [onDismissed] once the animation finishes.
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

// ── Search token ────────────────────────────────────────────────────────────

class _SearchToken {
  final bool isOp;
  final String value;

  const _SearchToken.term(this.value) : isOp = false;
  const _SearchToken.op(this.value) : isOp = true;

  bool get isTerm => !isOp;
}

// ── Bars ──────────────────────────────────────────────────────────────────────

class _TaskSearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _TaskSearchBar({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search title, description, tags, dates…',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: controller.text.isEmpty
              ? Tooltip(
                  message: 'Use "quotes" for phrases and AND / OR for advanced queries',
                  child: Icon(Icons.info_outline, size: 18, color: Colors.grey[500]),
                )
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  tooltip: 'Clear search',
                  onPressed: onClear,
                ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    );
  }
}

class _TaskSortBar extends StatelessWidget {
  final TaskSortMode sortMode;
  final void Function(TaskSortMode) onSortSelected;
  final bool flatView;
  final VoidCallback onToggleFlat;
  final bool expandAll;
  final VoidCallback onToggleExpandAll;

  const _TaskSortBar({
    required this.sortMode,
    required this.onSortSelected,
    required this.flatView,
    required this.onToggleFlat,
    required this.expandAll,
    required this.onToggleExpandAll,
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
                        child: Text(taskSortModeLabel(m),
                            style: const TextStyle(fontSize: 13)),
                      ))
                  .toList(),
            ),
          ),
          IconButton(
            icon: Icon(flatView ? Icons.view_list : Icons.account_tree, size: 20),
            tooltip: flatView
                ? 'Flat view (all tasks individually)'
                : 'Grouped view (subtasks nested)',
            visualDensity: VisualDensity.compact,
            onPressed: onToggleFlat,
          ),
          IconButton(
            icon: Icon(expandAll ? Icons.unfold_less : Icons.unfold_more, size: 20),
            tooltip: expandAll ? 'Collapse subtasks' : 'Expand subtasks',
            visualDensity: VisualDensity.compact,
            onPressed: onToggleExpandAll,
          ),
        ],
      ),
    );
  }
}

class _TaskFilterBar extends StatelessWidget {
  final List<Tag> tags;
  final Set<int> selectedTagIds;
  final bool showCompleted;
  final void Function(Set<int>) onTagsChanged;
  final void Function(bool)? onToggleCompleted;

  const _TaskFilterBar({
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
            child: _TaskTagFilterDropdown(
              tags: tags,
              selectedTagIds: selectedTagIds,
              onChanged: onTagsChanged,
            ),
          ),
          if (onToggleCompleted != null) ...[
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
        ],
      ),
    );
  }
}

/// A dropdown button that opens a searchable, multi-select checkbox list of tags.
class _TaskTagFilterDropdown extends StatelessWidget {
  final List<Tag> tags;
  final Set<int> selectedTagIds;
  final void Function(Set<int>) onChanged;

  const _TaskTagFilterDropdown({
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
                  builder: (_) => _TaskTagFilterSheet(
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
class _TaskTagFilterSheet extends StatefulWidget {
  final List<Tag> tags;
  final Set<int> selectedTagIds;

  const _TaskTagFilterSheet({required this.tags, required this.selectedTagIds});

  @override
  State<_TaskTagFilterSheet> createState() => _TaskTagFilterSheetState();
}

class _TaskTagFilterSheetState extends State<_TaskTagFilterSheet> {
  late final Set<int> _selected = {...widget.selectedTagIds};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.tags
        .where((t) => t.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
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
                                onChanged: (v) => setState(() {
                                  if (v == true) {
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

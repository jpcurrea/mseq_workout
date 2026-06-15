import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:intl/intl.dart';
import '../models/task.dart';
import '../services/task_api_service.dart';
import '../services/project_api_service.dart';
import '../widgets/urgency_color.dart';

class TaskGanttScreen extends StatefulWidget {
  const TaskGanttScreen({super.key});

  @override
  State<TaskGanttScreen> createState() => _TaskGanttScreenState();
}

class _TaskGanttScreenState extends State<TaskGanttScreen> {
  List<GanttTask> _tasks = [];
  bool _isLoading = true;
  String? _error;

  static const double _rowHeight = 44.0;
  static const double _labelWidth = 160.0;
  static const double _headerHeight = 40.0;

  // Zoom: pixels per day. Smaller = more zoomed out (years fit on screen).
  static const double _minDayWidth = 0.25;
  static const double _maxDayWidth = 80.0;
  double _dayWidth = 12.0;
  bool _showZoomBar = true;

  // Date range computed from the task set.
  late DateTime _startDate;
  int _totalDays = 60;

  // Scroll controllers. Header mirrors the body's horizontal scroll.
  final ScrollController _vBody = ScrollController();
  final ScrollController _hBody = ScrollController();
  final ScrollController _hHeader = ScrollController();

  // Pinch-to-zoom tracking.
  final Map<int, Offset> _pointers = {};
  double? _pinchBaseDist;
  double? _pinchBaseDayWidth;

  @override
  void initState() {
    super.initState();
    _startDate = DateTime.now().subtract(const Duration(days: 7));
    _hBody.addListener(_syncHeaderToBody);
    _load();
  }

  @override
  void dispose() {
    _hBody.removeListener(_syncHeaderToBody);
    _vBody.dispose();
    _hBody.dispose();
    _hHeader.dispose();
    super.dispose();
  }

  void _syncHeaderToBody() {
    if (!_hHeader.hasClients || !_hBody.hasClients) return;
    final target = _hBody.offset.clamp(
      _hHeader.position.minScrollExtent,
      _hHeader.position.maxScrollExtent,
    );
    if ((_hHeader.offset - target).abs() > 0.5) {
      _hHeader.jumpTo(target);
    }
  }

  Future<void> _load() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final project = await ProjectApiService.getActiveProject();
      final tasks = await TaskApiService.getGanttTasks(projectId: project.id);
      setState(() {
        _tasks = tasks;
        _computeRange();
        _isLoading = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  /// Fit the timeline to the span of all dated tasks (plus padding) so plans
  /// extending over years are fully visible.
  void _computeRange() {
    final today = DateTime.now();
    DateTime min = today;
    DateTime max = today;
    for (final t in _tasks) {
      for (final d in [t.startBy, t.dueDate]) {
        if (d == null) continue;
        if (d.isBefore(min)) min = d;
        if (d.isAfter(max)) max = d;
      }
    }
    final span = max.difference(min).inDays;
    final pad = math.max(7, (span * 0.05).round());
    _startDate =
        DateTime(min.year, min.month, min.day).subtract(Duration(days: pad));
    final end = DateTime(max.year, max.month, max.day).add(Duration(days: pad));
    _totalDays = math.max(30, end.difference(_startDate).inDays + 1);
    _dayWidth = _dayWidth.clamp(_minDayWidth, _maxDayWidth);
  }

  void _setZoom(double dw, {Offset? focalLocal}) {
    final clamped = dw.clamp(_minDayWidth, _maxDayWidth);
    final oldWidth = _dayWidth;
    if (oldWidth == clamped) return;
    double? newOffset;
    if (_hBody.hasClients && oldWidth > 0) {
      final focalX = focalLocal?.dx ?? (_hBody.position.viewportDimension / 2);
      final contentX = _hBody.offset + focalX;
      newOffset = contentX * (clamped / oldWidth) - focalX;
    }
    setState(() => _dayWidth = clamped);
    if (newOffset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_hBody.hasClients) return;
        _hBody.jumpTo(newOffset!.clamp(
          _hBody.position.minScrollExtent,
          _hBody.position.maxScrollExtent,
        ));
      });
    }
  }

  // ── Pinch-to-zoom (two fingers) ──────────────────────────────────────────
  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 2) {
      _pinchBaseDist = _pointerDistance();
      _pinchBaseDayWidth = _dayWidth;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 2 &&
        _pinchBaseDist != null &&
        _pinchBaseDayWidth != null) {
      final dist = _pointerDistance();
      if (dist <= 0 || _pinchBaseDist! <= 0) return;
      final scale = dist / _pinchBaseDist!;
      _setZoom(_pinchBaseDayWidth! * scale, focalLocal: _pinchFocal());
    }
  }

  void _onPointerEnd(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2) {
      _pinchBaseDist = null;
      _pinchBaseDayWidth = null;
    }
  }

  double _pointerDistance() {
    final pts = _pointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  Offset _pinchFocal() {
    final pts = _pointers.values.toList();
    final mid = (pts[0] + pts[1]) / 2;
    // Focal relative to the chart area (subtract the fixed label column).
    return Offset(mid.dx - _labelWidth, mid.dy);
  }

  void _navigateTo(String route) => Navigator.of(context).pushReplacementNamed(route);

  void _showTaskPopup(GanttTask task) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(task.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (task.startBy != null)
              Text('Start by: ${DateFormat('MMM d, y').format(task.startBy!)}'),
            if (task.dueDate != null)
              Text('Due: ${DateFormat('MMM d, y').format(task.dueDate!)}'),
            if (task.durationMinutes != null)
              Text('Estimated: ${task.durationMinutes} min'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: task.tags.map((t) => Chip(
                label: Text(t.name, style: const TextStyle(fontSize: 11, color: Colors.white)),
                backgroundColor: t.flutterColor,
                visualDensity: VisualDensity.compact,
              )).toList(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gantt'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: Icon(_showZoomBar ? Icons.zoom_in : Icons.zoom_in_outlined),
            tooltip: 'Time scale',
            onPressed: () => setState(() => _showZoomBar = !_showZoomBar),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu),
            onSelected: (v) {
              if (v == 'gantt') return;
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
              : _tasks.isEmpty
                  ? const Center(child: Text('No tasks with deadlines', style: TextStyle(color: Colors.grey)))
                  : _buildGantt(),
    );
  }

  Widget _buildGantt() {
    final totalWidth = _totalDays * _dayWidth;
    final today = DateTime.now();
    final todayOffset =
        today.difference(_startDate).inMinutes / 60 / 24 * _dayWidth;

    // Group: top-level tasks first, then subtasks under their parent
    final topLevel = _tasks.where((t) => t.parentTaskId == null).toList();
    final List<GanttTask> ordered = [];
    for (final top in topLevel) {
      ordered.add(top);
      ordered.addAll(_tasks.where((t) => t.parentTaskId == top.id));
    }
    for (final t in _tasks) {
      if (!ordered.contains(t)) ordered.add(t);
    }

    final bodyHeight = ordered.length * _rowHeight;

    return Column(
      children: [
        // ── Date header (fixed vertically, mirrors body horizontal scroll) ──
        Row(
          children: [
            Container(
              width: _labelWidth,
              height: _headerHeight,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.grey[300]!)),
              ),
              child: const Text('Task',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: _hHeader,
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: SizedBox(
                  width: totalWidth,
                  height: _headerHeight,
                  child: CustomPaint(
                    size: Size(totalWidth, _headerHeight),
                    painter: _TimelinePainter(
                      startDate: _startDate,
                      totalDays: _totalDays,
                      dayWidth: _dayWidth,
                      todayOffset: todayOffset,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        // ── Body (scrolls vertically; chart scrolls horizontally) ──
        Expanded(
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerEnd,
            onPointerCancel: _onPointerEnd,
            child: SingleChildScrollView(
              controller: _vBody,
              scrollDirection: Axis.vertical,
              child: SizedBox(
                height: bodyHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Fixed label column.
                    SizedBox(
                      width: _labelWidth,
                      child: Column(
                        children: [
                          for (int i = 0; i < ordered.length; i++)
                            _buildLabelCell(ordered[i], i),
                        ],
                      ),
                    ),
                    // Horizontally scrollable chart.
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _hBody,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: totalWidth,
                          height: bodyHeight,
                          child: Column(
                            children: [
                              for (int i = 0; i < ordered.length; i++)
                                _GanttRow(
                                  task: ordered[i],
                                  startDate: _startDate,
                                  dayWidth: _dayWidth,
                                  rowHeight: _rowHeight,
                                  totalWidth: totalWidth,
                                  todayOffset: todayOffset,
                                  isEven: i.isEven,
                                  onTap: () => _showTaskPopup(ordered[i]),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_showZoomBar) _buildZoomBar(),
      ],
    );
  }

  Widget _buildLabelCell(GanttTask t, int i) {
    final isSubtask = t.parentTaskId != null;
    return Container(
      height: _rowHeight,
      alignment: Alignment.centerLeft,
      padding: EdgeInsets.only(left: isSubtask ? 20 : 8, right: 4),
      decoration: BoxDecoration(
        color: i.isEven ? Colors.grey[50] : Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
      ),
      child: Text(
        t.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontStyle: isSubtask ? FontStyle.italic : FontStyle.normal,
        ),
      ),
    );
  }

  Widget _buildZoomBar() {
    final sliderVal = (math.log(_dayWidth / _minDayWidth) /
            math.log(_maxDayWidth / _minDayWidth))
        .clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        border: Border(top: BorderSide(color: Colors.grey[300]!)),
      ),
      child: Row(
        children: [
          const Icon(Icons.zoom_out, size: 18, color: Colors.grey),
          Expanded(
            child: Slider(
              value: sliderVal,
              onChanged: (v) {
                final dw = _minDayWidth *
                    math.pow(_maxDayWidth / _minDayWidth, v).toDouble();
                _setZoom(dw);
              },
            ),
          ),
          const Icon(Icons.zoom_in, size: 18, color: Colors.grey),
          const SizedBox(width: 6),
          _presetChip('Y', 0.7),
          _presetChip('M', 3.5),
          _presetChip('W', 12.0),
          _presetChip('D', 40.0),
        ],
      ),
    );
  }

  Widget _presetChip(String label, double dayWidth) {
    final selected = (_dayWidth - dayWidth).abs() < 0.5;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onSelected: (_) => _setZoom(dayWidth),
      ),
    );
  }
}

class _GanttRow extends StatelessWidget {
  final GanttTask task;
  final DateTime startDate;
  final double dayWidth;
  final double rowHeight;
  final double totalWidth;
  final double todayOffset;
  final bool isEven;
  final VoidCallback onTap;

  const _GanttRow({
    required this.task,
    required this.startDate,
    required this.dayWidth,
    required this.rowHeight,
    required this.totalWidth,
    required this.todayOffset,
    required this.isEven,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final barColor = urgencyColorFromScore(
      task.urgencyScore,
      overdue: task.urgencyScore >= 1.0,
      durationMinutes: task.durationMinutes,
    );

    double? barLeft;
    double? barWidth;

    final barStart = task.startBy ?? task.dueDate;
    final barEnd = task.dueDate;

    if (barStart != null && barEnd != null) {
      final leftDays = barStart.difference(startDate).inMinutes / 60 / 24;
      final rightDays = barEnd.difference(startDate).inMinutes / 60 / 24;
      barLeft = leftDays * dayWidth;
      barWidth = (rightDays - leftDays) * dayWidth;
      if (barWidth < 8) barWidth = 8; // minimum visible width
    } else if (barEnd != null) {
      // No start_by — show a thin vertical tick on due_date
      final days = barEnd.difference(startDate).inMinutes / 60 / 24;
      barLeft = days * dayWidth - 4;
      barWidth = 8;
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: rowHeight,
        width: totalWidth,
        color: isEven ? Colors.grey[50] : Colors.white,
        child: Stack(
          children: [
            // Today line
            Positioned(
              left: todayOffset,
              top: 0,
              bottom: 0,
              child: Container(width: 1.5, color: Colors.blue.withOpacity(0.5)),
            ),
            // Task bar
            if (barLeft != null && barWidth != null)
              Positioned(
                left: barLeft.clamp(0.0, math.max(0.0, totalWidth - barWidth)),
                top: rowHeight * 0.25,
                height: rowHeight * 0.5,
                width: barWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: barColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  alignment: Alignment.center,
                  child: barWidth > 30
                      ? Text(
                          task.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        )
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  final DateTime startDate;
  final int totalDays;
  final double dayWidth;
  final double todayOffset;

  _TimelinePainter({
    required this.startDate,
    required this.totalDays,
    required this.dayWidth,
    required this.todayOffset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final monthLine = Paint()..color = Colors.grey[300]!..strokeWidth = 1;
    final yearLine = Paint()..color = Colors.grey[500]!..strokeWidth = 1.2;
    final todayPaint = Paint()..color = Colors.blue.withOpacity(0.5)..strokeWidth = 1.5;
    final tp = TextPainter(textDirection: ui.TextDirection.ltr);

    final monthPx = 30 * dayWidth;
    final showMonthLabel = monthPx >= 26;
    final showDayNumbers = dayWidth >= 14;

    void label(String text, double x, double y, TextStyle style) {
      tp.text = TextSpan(text: text, style: style);
      tp.layout();
      tp.paint(canvas, Offset(x + 3, y));
    }

    const monthStyle = TextStyle(fontSize: 10, color: Colors.black54);
    const yearStyle = TextStyle(fontSize: 11, color: Colors.black87, fontWeight: FontWeight.bold);
    const dayStyle = TextStyle(fontSize: 9, color: Colors.grey);

    for (int d = 0; d <= totalDays; d++) {
      final date = startDate.add(Duration(days: d));
      final x = d * dayWidth;
      final isMonthStart = date.day == 1;
      final isYearStart = date.month == 1 && date.day == 1;

      if (isYearStart) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), yearLine);
        label(date.year.toString(), x, 2, yearStyle);
        if (showMonthLabel) label('Jan', x, 20, monthStyle);
      } else if (isMonthStart) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), monthLine);
        if (showMonthLabel) {
          label(DateFormat('MMM').format(date), x, showDayNumbers ? 2 : 20, monthStyle);
        }
      }

      if (showDayNumbers && d % 7 == 0) {
        canvas.drawLine(Offset(x, size.height - 12), Offset(x, size.height), monthLine);
        label(DateFormat('M/d').format(date), x, 24, dayStyle);
      }
    }

    if (todayOffset >= 0 && todayOffset <= size.width) {
      canvas.drawLine(Offset(todayOffset, 0), Offset(todayOffset, size.height), todayPaint);
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.startDate != startDate ||
      old.totalDays != totalDays ||
      old.dayWidth != dayWidth ||
      old.todayOffset != todayOffset;
}

import 'package:flutter/material.dart';
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

  // Viewport: show 60 days around today
  static const int _daysBefore = 7;
  static const int _daysAfter = 53;
  static const double _dayWidth = 40.0;
  static const double _rowHeight = 44.0;
  static const double _labelWidth = 160.0;

  late final DateTime _startDate;

  @override
  void initState() {
    super.initState();
    _startDate = DateTime.now().subtract(const Duration(days: _daysBefore));
    _load();
  }

  Future<void> _load() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final project = await ProjectApiService.getActiveProject();
      final tasks = await TaskApiService.getGanttTasks(projectId: project.id);
      setState(() { _tasks = tasks; _isLoading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _isLoading = false; });
    }
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
          onPressed: () => Navigator.of(context).pushReplacementNamed('/hub'),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu),
            onSelected: (v) {
              if (v == 'todo') _navigateTo('/tasks');
              else if (v != 'gantt') _navigateTo('/tasks/$v');
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
    final totalDays = _daysBefore + _daysAfter;
    final totalWidth = totalDays * _dayWidth;
    final today = DateTime.now();
    final todayOffset = _daysBefore * _dayWidth;

    // Group: top-level tasks first, then subtasks under their parent
    final topLevel = _tasks.where((t) => t.parentTaskId == null).toList();
    final List<GanttTask> ordered = [];
    for (final top in topLevel) {
      ordered.add(top);
      ordered.addAll(_tasks.where((t) => t.parentTaskId == top.id));
    }
    // Any orphan subtasks (parent not in result set)
    for (final t in _tasks) {
      if (!ordered.contains(t)) ordered.add(t);
    }

    return Row(
      children: [
        // Fixed label column
        SizedBox(
          width: _labelWidth,
          child: Column(
            children: [
              Container(
                height: 36,
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.grey[300]!)),
                ),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: const Text('Task', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              Expanded(
                child: ListView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: ordered.length,
                  itemBuilder: (_, i) {
                    final t = ordered[i];
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
                  },
                ),
              ),
            ],
          ),
        ),
        // Scrollable chart
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: totalWidth,
              child: Column(
                children: [
                  // Date header
                  SizedBox(
                    height: 36,
                    child: CustomPaint(
                      size: Size(totalWidth, 36),
                      painter: _DateHeaderPainter(
                        startDate: _startDate,
                        totalDays: totalDays,
                        dayWidth: _dayWidth,
                        todayOffset: todayOffset,
                      ),
                    ),
                  ),
                  // Rows
                  Expanded(
                    child: ListView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: ordered.length,
                      itemBuilder: (_, i) {
                        final t = ordered[i];
                        return _GanttRow(
                          task: t,
                          startDate: _startDate,
                          dayWidth: _dayWidth,
                          rowHeight: _rowHeight,
                          totalWidth: totalWidth,
                          todayOffset: todayOffset,
                          isEven: i.isEven,
                          onTap: () => _showTaskPopup(t),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
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
                left: barLeft.clamp(0, totalWidth - barWidth),
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

class _DateHeaderPainter extends CustomPainter {
  final DateTime startDate;
  final int totalDays;
  final double dayWidth;
  final double todayOffset;

  _DateHeaderPainter({
    required this.startDate,
    required this.totalDays,
    required this.dayWidth,
    required this.todayOffset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()..color = Colors.grey[300]!..strokeWidth = 1;
    final todayPaint = Paint()..color = Colors.blue.withOpacity(0.5)..strokeWidth = 1.5;
    final textPainter = TextPainter(textDirection: ui.TextDirection.ltr);

    DateTime? lastMonth;

    for (int d = 0; d <= totalDays; d++) {
      final date = startDate.add(Duration(days: d));
      final x = d * dayWidth;

      // Month label when month changes
      if (lastMonth == null || date.month != lastMonth.month) {
        lastMonth = date;
        textPainter.text = TextSpan(
          text: DateFormat('MMM y').format(date),
          style: const TextStyle(fontSize: 10, color: Colors.black87, fontWeight: FontWeight.bold),
        );
        textPainter.layout();
        textPainter.paint(canvas, Offset(x + 2, 2));
      }

      // Day number every 7 days
      if (d % 7 == 0) {
        textPainter.text = TextSpan(
          text: date.day.toString(),
          style: const TextStyle(fontSize: 9, color: Colors.grey),
        );
        textPainter.layout();
        textPainter.paint(canvas, Offset(x + 2, 20));
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
      }
    }

    // Today line
    canvas.drawLine(Offset(todayOffset, 0), Offset(todayOffset, size.height), todayPaint);
  }

  @override
  bool shouldRepaint(_) => false;
}

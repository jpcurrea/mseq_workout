import 'package:flutter/material.dart';

import 'package:table_calendar/table_calendar.dart';
import '../models/task.dart';
import '../services/task_api_service.dart';
import '../services/project_api_service.dart';
import '../widgets/urgency_color.dart';

class TaskCalendarScreen extends StatefulWidget {
  const TaskCalendarScreen({super.key});

  @override
  State<TaskCalendarScreen> createState() => _TaskCalendarScreenState();
}

class _TaskCalendarScreenState extends State<TaskCalendarScreen> {
  // keyed by date (year/month/day only) → list of calendar task maps
  final Map<DateTime, List<Map<String, dynamic>>> _eventsByDay = {};
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedDay = DateTime.now();
    _load();
  }

  Future<void> _load() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final project = await ProjectApiService.getActiveProject();
      final tasks = await TaskApiService.getCalendarTasks(projectId: project.id);
      final Map<DateTime, List<Map<String, dynamic>>> byDay = {};
      for (final t in tasks) {
        final due = DateTime.parse(t['due_date'] as String);
        final key = _dateOnly(due);
        byDay.putIfAbsent(key, () => []).add(t);
      }
      setState(() { _eventsByDay
        ..clear()
        ..addAll(byDay);
        _isLoading = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  DateTime _dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  List<Map<String, dynamic>> _eventsFor(DateTime day) =>
      _eventsByDay[_dateOnly(day)] ?? [];

  void _navigateTo(String route) {
    Navigator.of(context).pushReplacementNamed(route);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu),
            onSelected: (v) {
              if (v == 'calendar') return;
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
              : Column(
                  children: [
                    TableCalendar<Map<String, dynamic>>(
                      firstDay: DateTime.now().subtract(const Duration(days: 365)),
                      lastDay: DateTime.now().add(const Duration(days: 730)),
                      focusedDay: _focusedDay,
                      selectedDayPredicate: (d) => isSameDay(_selectedDay, d),
                      eventLoader: _eventsFor,
                      calendarFormat: CalendarFormat.month,
                      headerStyle: const HeaderStyle(formatButtonVisible: false),
                      calendarBuilders: CalendarBuilders(
                        markerBuilder: (ctx, day, events) {
                          if (events.isEmpty) return null;
                          return Positioned(
                            bottom: 1,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: events.take(4).map((e) {
                                final score = (e['urgency_score'] as num?)?.toDouble() ?? 0;
                                final overdue = score >= 1.0;
                                final c = urgencyColorFromScore(score, overdue: overdue);
                                return Container(
                                  width: 6,
                                  height: 6,
                                  margin: const EdgeInsets.symmetric(horizontal: 1),
                                  decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                                );
                              }).toList(),
                            ),
                          );
                        },
                      ),
                      onDaySelected: (selected, focused) {
                        setState(() { _selectedDay = selected; _focusedDay = focused; });
                      },
                    ),
                    const Divider(height: 1),
                    Expanded(child: _buildDayList()),
                  ],
                ),
    );
  }

  Widget _buildDayList() {
    final events = _selectedDay != null ? _eventsFor(_selectedDay!) : [];
    if (events.isEmpty) {
      return const Center(
        child: Text('No tasks due on this day', style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: events.length,
      itemBuilder: (_, i) {
        final e = events[i];
        final score = (e['urgency_score'] as num?)?.toDouble() ?? 0;
        final overdue = score >= 1.0;
        final chipColor = urgencyColorFromScore(score, overdue: overdue);
        final tags = (e['tags'] as List? ?? []).map((t) => Tag.fromJson(t)).toList();

        return Card(
          child: ListTile(
            leading: Container(
              width: 10,
              height: 40,
              decoration: BoxDecoration(
                color: chipColor,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            title: Text(e['title'] as String),
            subtitle: tags.isEmpty
                ? null
                : Wrap(
                    spacing: 4,
                    children: tags.map((t) => Chip(
                      label: Text(t.name, style: const TextStyle(fontSize: 10, color: Colors.white)),
                      backgroundColor: t.flutterColor,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                    )).toList(),
                  ),
            trailing: e['is_completed'] == true
                ? const Icon(Icons.check_circle, color: Colors.green)
                : null,
          ),
        );
      },
    );
  }
}

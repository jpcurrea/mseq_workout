import 'package:flutter/material.dart';

class Tag {
  final int id;
  final String name;
  final String color; // hex, e.g. "#6366f1"

  const Tag({required this.id, required this.name, required this.color});

  factory Tag.fromJson(Map<String, dynamic> json) => Tag(
        id: json['id'],
        name: json['name'],
        color: json['color'] ?? '#6366f1',
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': color};

  Color get flutterColor {
    final hex = color.replaceFirst('#', '');
    return Color(int.parse('FF$hex', radix: 16));
  }
}

class Task {
  final int id;
  final int? projectId;
  final String title;
  final String? description;
  final DateTime? dueDate;
  final int? durationMinutes;
  final DateTime? startBy;        // computed by backend
  final bool isCompleted;
  final DateTime? completedAt;
  final bool isRecurring;
  final String? recurrenceRule;
  final String recurrenceAdvanceMode;  // "now" | "stop"
  final List<Tag> tags;
  final List<Task> subtasks;
  final double urgencyScore;      // 0=neutral, 1=overdue/max-urgency
  final double? actualDurationMinutes;
  final DateTime? activeSessionStartedAt;  // non-null while a work session is running
  final int? parentTaskId;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Task({
    required this.id,
    this.projectId,
    required this.title,
    this.description,
    this.dueDate,
    this.durationMinutes,
    this.startBy,
    required this.isCompleted,
    this.completedAt,
    required this.isRecurring,
    this.recurrenceRule,
    this.recurrenceAdvanceMode = 'now',
    required this.tags,
    required this.subtasks,
    required this.urgencyScore,
    this.actualDurationMinutes,
    this.activeSessionStartedAt,
    this.parentTaskId,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Task.fromJson(Map<String, dynamic> json) => Task(
        id: json['id'],
      projectId: json['project_id'],
        title: json['title'],
        description: json['description'],
        dueDate: json['due_date'] != null ? DateTime.parse(json['due_date']) : null,
        durationMinutes: json['duration_minutes'],
        startBy: json['start_by'] != null ? DateTime.parse(json['start_by']) : null,
        isCompleted: json['is_completed'] ?? false,
        completedAt: json['completed_at'] != null ? DateTime.parse(json['completed_at']) : null,
        isRecurring: json['is_recurring'] ?? false,
        recurrenceRule: json['recurrence_rule'],
        recurrenceAdvanceMode: json['recurrence_advance_mode'] ?? 'now',
        tags: (json['tags'] as List? ?? []).map((t) => Tag.fromJson(t)).toList(),
        subtasks: (json['subtasks'] as List? ?? []).map((t) => Task.fromJson(t)).toList(),
        urgencyScore: (json['urgency_score'] as num?)?.toDouble() ?? 0.0,
        actualDurationMinutes: (json['actual_duration_minutes'] as num?)?.toDouble(),
        activeSessionStartedAt: json['active_session_started_at'] != null
            ? DateTime.parse(json['active_session_started_at'])
            : null,
        parentTaskId: json['parent_task_id'],
        createdAt: DateTime.parse(json['created_at']),
        updatedAt: DateTime.parse(json['updated_at']),
      );

  /// True while a work session is currently running for this task.
  bool get isSessionActive => activeSessionStartedAt != null;

  /// Actual minutes worked including time elapsed in the currently-active
  /// session (the backend's [actualDurationMinutes] only counts ended sessions).
  double get liveActualMinutes {
    final base = actualDurationMinutes ?? 0.0;
    if (activeSessionStartedAt == null) return base;
    final elapsed = DateTime.now().difference(activeSessionStartedAt!).inSeconds / 60.0;
    return base + (elapsed > 0 ? elapsed : 0.0);
  }

  /// Progress fraction for the progress bar [0, 1] using actual vs estimated duration.
  double get progressFraction {
    if (durationMinutes == null || durationMinutes! <= 0) return 0.0;
    if (actualDurationMinutes == null && activeSessionStartedAt == null) return 0.0;
    return (liveActualMinutes / durationMinutes!).clamp(0.0, 1.0);
  }

  String get dueDateLabel {
    if (dueDate == null) return '';
    final now = DateTime.now();
    final diff = dueDate!.difference(now);
    if (diff.isNegative) {
      final days = (-diff.inDays);
      return days > 0 ? '${days}d overdue' : 'Overdue today';
    }
    if (diff.inDays == 0) return 'Due today';
    if (diff.inDays == 1) return 'Due tomorrow';
    return 'Due in ${diff.inDays}d';
  }

  /// Punctuality badge text for completed tasks.
  String? get punctualityLabel {
    if (!isCompleted || completedAt == null || dueDate == null) return null;
    final diff = completedAt!.difference(dueDate!);
    if (diff.isNegative || diff.inMinutes == 0) {
      final hrs = (-diff.inMinutes) ~/ 60;
      return hrs > 0 ? '✓ ${hrs}h early' : '✓ On time';
    }
    final hrs = diff.inMinutes ~/ 60;
    return hrs > 0 ? '${hrs}h late' : '${diff.inMinutes}m late';
  }

  bool get punctuallyCompleted =>
      isCompleted && completedAt != null && dueDate != null && !completedAt!.isAfter(dueDate!);

  /// The due date of the most "dire" task in this subtree (this task plus all
  /// descendants), i.e. the incomplete task with the least time remaining
  /// (earliest due date). Completed tasks and tasks without a due date are
  /// ignored. Used so a collapsed parent reflects the same urgency that drives
  /// its position in grouped-mode sorting.
  DateTime? get mostDireDueDate {
    DateTime? best;
    void visit(Task t) {
      if (!t.isCompleted && t.dueDate != null) {
        if (best == null || t.dueDate!.isBefore(best!)) {
          best = t.dueDate;
        }
      }
      for (final s in t.subtasks) {
        visit(s);
      }
    }
    visit(this);
    return best;
  }
}

class GanttTask {
  final int id;
  final String title;
  final int? parentTaskId;
  final DateTime? dueDate;
  final DateTime? startBy;
  final int? durationMinutes;
  final double urgencyScore;
  final List<Tag> tags;

  const GanttTask({
    required this.id,
    required this.title,
    this.parentTaskId,
    this.dueDate,
    this.startBy,
    this.durationMinutes,
    required this.urgencyScore,
    required this.tags,
  });

  factory GanttTask.fromJson(Map<String, dynamic> json) => GanttTask(
        id: json['id'],
        title: json['title'],
        parentTaskId: json['parent_task_id'],
        dueDate: json['due_date'] != null ? DateTime.parse(json['due_date']) : null,
        startBy: json['start_by'] != null ? DateTime.parse(json['start_by']) : null,
        durationMinutes: json['duration_minutes'],
        urgencyScore: (json['urgency_score'] as num?)?.toDouble() ?? 0.0,
        tags: (json['tags'] as List? ?? []).map((t) => Tag.fromJson(t)).toList(),
      );
}

class Plan {
  final int id;
  final int projectId;
  final String title;
  final String content;
  final Map<String, Task> tasks;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Plan({
    required this.id,
    required this.projectId,
    required this.title,
    required this.content,
    required this.tasks,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Plan.fromJson(Map<String, dynamic> json) => Plan(
        id: json['id'],
        projectId: json['project_id'] ?? 0,
        title: json['title'],
        content: json['content'] ?? '',
        tasks: (json['tasks'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, Task.fromJson(v))),
        createdAt: DateTime.parse(json['created_at']),
        updatedAt: DateTime.parse(json['updated_at']),
      );
}

class PlanSummary {
  final int id;
  final String title;
  final DateTime updatedAt;

  const PlanSummary({required this.id, required this.title, required this.updatedAt});

  factory PlanSummary.fromJson(Map<String, dynamic> json) => PlanSummary(
        id: json['id'],
        title: json['title'],
        updatedAt: DateTime.parse(json['updated_at']),
      );
}

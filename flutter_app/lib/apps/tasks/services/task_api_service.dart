import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import '../models/task.dart';
import '../../../shared/services/auth_service.dart';

class TaskApiService {
  static const String _baseUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'https://workout-backend-h6pd.onrender.com',
  );

  static Future<Map<String, String>> _headers() async {
    final token = await AuthService.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static Future<Map<String, String>> _authHeaders() async {
    final token = await AuthService.getToken();
    return {
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static Exception _err(http.Response r, String fallback) {
    try {
      final body = json.decode(r.body);
      if (body is Map && body['detail'] != null) return Exception(body['detail']);
    } catch (_) {}
    return Exception('$fallback: ${r.statusCode}');
  }

  // ── Tasks ──────────────────────────────────────────────────────────────────

  static Future<List<Task>> getTasks({required int projectId, bool includeCompleted = false, int? tagId}) async {
    final uri = Uri.parse('$_baseUrl/tasks').replace(queryParameters: {
      'project_id': projectId.toString(),
      'include_completed': includeCompleted.toString(),
      if (tagId != null) 'tag_id': tagId.toString(),
    });
    final r = await http.get(uri, headers: await _headers());
    if (r.statusCode == 200) {
      return (json.decode(r.body) as List).map((t) => Task.fromJson(t)).toList();
    }
    throw _err(r, 'Failed to load tasks');
  }

  static Future<Task> getTask(int id) async {
    final r = await http.get(Uri.parse('$_baseUrl/tasks/$id'), headers: await _headers());
    if (r.statusCode == 200) return Task.fromJson(json.decode(r.body));
    throw _err(r, 'Failed to load task');
  }

  static Future<Task> createTask({
    required int projectId,
    required String title,
    String? description,
    String? dueDate,
    int? durationMinutes,
    int? parentTaskId,
    bool isRecurring = false,
    String? recurrenceRule,
    List<int> tagIds = const [],
  }) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/tasks'),
      headers: await _headers(),
      body: json.encode({
        'project_id': projectId,
        'title': title,
        if (description != null) 'description': description,
        if (dueDate != null) 'due_date': dueDate,
        if (durationMinutes != null) 'duration_minutes': durationMinutes,
        if (parentTaskId != null) 'parent_task_id': parentTaskId,
        'is_recurring': isRecurring,
        if (recurrenceRule != null) 'recurrence_rule': recurrenceRule,
        'tag_ids': tagIds,
      }),
    );
    if (r.statusCode == 200) return Task.fromJson(json.decode(r.body));
    throw _err(r, 'Failed to create task');
  }

  static Future<Map<String, dynamic>> importTasksCsv({
    required int projectId,
    required PlatformFile file,
    bool dryRun = false,
  }) async {
    if (file.bytes == null) {
      throw Exception('Could not read file bytes for upload');
    }

    final uri = Uri.parse('$_baseUrl/tasks/import-csv').replace(
      queryParameters: {
        'project_id': projectId.toString(),
        'dry_run': dryRun.toString(),
      },
    );

    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll(await _authHeaders())
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          file.bytes!,
          filename: file.name,
        ),
      );

    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
      return json.decode(body) as Map<String, dynamic>;
    }

    try {
      final parsed = json.decode(body);
      if (parsed is Map && parsed['detail'] != null) {
        throw Exception(parsed['detail']);
      }
    } catch (_) {}
    throw Exception('Failed to import CSV: ${streamed.statusCode}');
  }

  static Future<Task> updateTask(
    int id, {
    String? title,
    String? description,
    String? dueDate,
    int? durationMinutes,
    int? parentTaskId,
    bool? isRecurring,
    String? recurrenceRule,
    List<int>? tagIds,
  }) async {
    final body = <String, dynamic>{};
    if (title != null) body['title'] = title;
    if (description != null) body['description'] = description;
    if (dueDate != null) body['due_date'] = dueDate;
    if (durationMinutes != null) body['duration_minutes'] = durationMinutes;
    if (parentTaskId != null) body['parent_task_id'] = parentTaskId;
    if (isRecurring != null) body['is_recurring'] = isRecurring;
    if (recurrenceRule != null) body['recurrence_rule'] = recurrenceRule;
    if (tagIds != null) body['tag_ids'] = tagIds;

    final r = await http.put(
      Uri.parse('$_baseUrl/tasks/$id'),
      headers: await _headers(),
      body: json.encode(body),
    );
    if (r.statusCode == 200) return Task.fromJson(json.decode(r.body));
    throw _err(r, 'Failed to update task');
  }

  static Future<void> deleteTask(int id) async {
    final r = await http.delete(Uri.parse('$_baseUrl/tasks/$id'), headers: await _headers());
    if (r.statusCode != 200) throw _err(r, 'Failed to delete task');
  }

  static Future<Task> toggleComplete(int id) async {
    final r = await http.post(Uri.parse('$_baseUrl/tasks/$id/complete'), headers: await _headers());
    if (r.statusCode == 200) return Task.fromJson(json.decode(r.body));
    throw _err(r, 'Failed to toggle complete');
  }

  static Future<Task> skipTask(int id) async {
    final r = await http.post(Uri.parse('$_baseUrl/tasks/$id/skip'), headers: await _headers());
    if (r.statusCode == 200) return Task.fromJson(json.decode(r.body));
    throw _err(r, 'Failed to skip task');
  }

  static Future<void> startSession(int taskId) async {
    final r = await http.post(Uri.parse('$_baseUrl/tasks/$taskId/start'), headers: await _headers());
    if (r.statusCode != 200) throw _err(r, 'Failed to start session');
  }

  static Future<Map<String, dynamic>> stopSession(int taskId, {String? notes}) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/tasks/$taskId/stop'),
      headers: await _headers(),
      body: json.encode({'notes': notes}),
    );
    if (r.statusCode == 200) return json.decode(r.body) as Map<String, dynamic>;
    throw _err(r, 'Failed to stop session');
  }

  // ── Tags ───────────────────────────────────────────────────────────────────

  static Future<List<Tag>> getTags({required int projectId}) async {
    final uri = Uri.parse('$_baseUrl/tasks/tags')
        .replace(queryParameters: {'project_id': projectId.toString()});
    final r = await http.get(uri, headers: await _headers());
    if (r.statusCode == 200) {
      return (json.decode(r.body) as List).map((t) => Tag.fromJson(t)).toList();
    }
    throw _err(r, 'Failed to load tags');
  }

  static Future<Tag> createTag(String name, {String color = '#6366f1'}) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/tasks/tags'),
      headers: await _headers(),
      body: json.encode({'name': name, 'color': color}),
    );
    if (r.statusCode == 200) return Tag.fromJson(json.decode(r.body));
    throw _err(r, 'Failed to create tag');
  }

  static Future<void> deleteTag(int tagId) async {
    final r = await http.delete(Uri.parse('$_baseUrl/tasks/tags/$tagId'), headers: await _headers());
    if (r.statusCode != 200) throw _err(r, 'Failed to delete tag');
  }

  // ── Plans ──────────────────────────────────────────────────────────────────

  static Future<List<PlanSummary>> getPlans({required int projectId}) async {
    final uri = Uri.parse('$_baseUrl/plans')
        .replace(queryParameters: {'project_id': projectId.toString()});
    final r = await http.get(uri, headers: await _headers());
    if (r.statusCode == 200) {
      return (json.decode(r.body) as List).map((p) => PlanSummary.fromJson(p)).toList();
    }
    throw _err(r, 'Failed to load plans');
  }

  static Future<Plan> getPlan(int id) async {
    final r = await http.get(Uri.parse('$_baseUrl/plans/$id'), headers: await _headers());
    if (r.statusCode == 200) return Plan.fromJson(json.decode(r.body));
    throw _err(r, 'Failed to load plan');
  }

  static Future<Plan> createPlan(String title, {required int projectId, String content = ''}) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/plans'),
      headers: await _headers(),
      body: json.encode({'project_id': projectId, 'title': title, 'content': content}),
    );
    if (r.statusCode == 200) return Plan.fromJson(json.decode(r.body));
    throw _err(r, 'Failed to create plan');
  }

  static Future<void> updatePlan(int id, {String? title, String? content}) async {
    final r = await http.put(
      Uri.parse('$_baseUrl/plans/$id'),
      headers: await _headers(),
      body: json.encode({
        if (title != null) 'title': title,
        if (content != null) 'content': content,
      }),
    );
    if (r.statusCode != 200) throw _err(r, 'Failed to update plan');
  }

  static Future<void> deletePlan(int id) async {
    final r = await http.delete(Uri.parse('$_baseUrl/plans/$id'), headers: await _headers());
    if (r.statusCode != 200) throw _err(r, 'Failed to delete plan');
  }

  // ── Calendar / Gantt ───────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getCalendarTasks({required int projectId}) async {
    final uri = Uri.parse('$_baseUrl/tasks/calendar')
        .replace(queryParameters: {'project_id': projectId.toString()});
    final r = await http.get(uri, headers: await _headers());
    if (r.statusCode == 200) return List<Map<String, dynamic>>.from(json.decode(r.body));
    throw _err(r, 'Failed to load calendar tasks');
  }

  static Future<List<GanttTask>> getGanttTasks({required int projectId}) async {
    final uri = Uri.parse('$_baseUrl/tasks/gantt')
        .replace(queryParameters: {'project_id': projectId.toString()});
    final r = await http.get(uri, headers: await _headers());
    if (r.statusCode == 200) {
      return (json.decode(r.body) as List).map((t) => GanttTask.fromJson(t)).toList();
    }
    throw _err(r, 'Failed to load gantt tasks');
  }

  // ── Analytics ──────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getEstimationAnalytics() async {
    final r = await http.get(
        Uri.parse('$_baseUrl/tasks/analytics/estimation'), headers: await _headers());
    if (r.statusCode == 200) return json.decode(r.body) as Map<String, dynamic>;
    throw _err(r, 'Failed to load estimation analytics');
  }

  static Future<Map<String, dynamic>> getPunctualityAnalytics() async {
    final r = await http.get(
        Uri.parse('$_baseUrl/tasks/analytics/punctuality'), headers: await _headers());
    if (r.statusCode == 200) return json.decode(r.body) as Map<String, dynamic>;
    throw _err(r, 'Failed to load punctuality analytics');
  }

  // ── Completion history ───────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getCompletions({required int projectId}) async {
    final uri = Uri.parse('$_baseUrl/tasks/completions')
        .replace(queryParameters: {'project_id': projectId.toString()});
    final r = await http.get(uri, headers: await _headers());
    if (r.statusCode == 200) return List<Map<String, dynamic>>.from(json.decode(r.body));
    throw _err(r, 'Failed to load completion history');
  }

  /// Returns the raw CSV text of the project's completion record.
  static Future<String> exportCompletionsCsv({required int projectId}) async {
    final uri = Uri.parse('$_baseUrl/tasks/completions/export')
        .replace(queryParameters: {'project_id': projectId.toString()});
    final r = await http.get(uri, headers: await _authHeaders());
    if (r.statusCode == 200) return r.body;
    throw _err(r, 'Failed to export completion history');
  }
}

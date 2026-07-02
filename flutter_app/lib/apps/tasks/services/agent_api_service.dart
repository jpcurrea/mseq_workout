import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../../shared/services/auth_service.dart';

class AgentChatResponse {
  final String reply;
  final List<Map<String, dynamic>> actions;
  final bool pendingApproval;
  final List<Map<String, dynamic>> proposedToolCalls;
  final List<String> attachmentNotes;

  const AgentChatResponse({
    required this.reply,
    required this.actions,
    required this.pendingApproval,
    required this.proposedToolCalls,
    this.attachmentNotes = const [],
  });

  factory AgentChatResponse.fromJson(Map<String, dynamic> json) {
    final rawActions = (json['actions'] as List?) ?? const [];
    final rawProposed = (json['proposed_tool_calls'] as List?) ?? const [];
    final rawNotes = (json['attachment_notes'] as List?) ?? const [];
    return AgentChatResponse(
      reply: (json['reply'] ?? '').toString(),
      actions: rawActions.map((a) => Map<String, dynamic>.from(a as Map)).toList(),
      pendingApproval: json['pending_approval'] == true,
      proposedToolCalls: rawProposed.map((a) => Map<String, dynamic>.from(a as Map)).toList(),
      attachmentNotes: rawNotes.map((n) => n.toString()).toList(),
    );
  }
}

class AgentApiService {
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

  static Exception _err(http.Response r, String fallback) {
    try {
      final body = json.decode(r.body);
      if (body is Map && body['detail'] != null) return Exception(body['detail']);
    } catch (_) {}
    return Exception('$fallback: ${r.statusCode}');
  }

  static Future<AgentChatResponse> planningChat({
    required int projectId,
    required int planId,
    required List<Map<String, String>> messages,
    bool requireApproval = false,
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/agent/chat'),
      headers: await _headers(),
      body: json.encode({
        'mode': 'planning',
        'project_id': projectId,
        'plan_id': planId,
        'messages': messages,
        'require_approval': requireApproval,
        if (attachments.isNotEmpty) 'attachments': attachments,
      }),
    );

    if (r.statusCode == 200) {
      return AgentChatResponse.fromJson(json.decode(r.body) as Map<String, dynamic>);
    }
    throw _err(r, 'Failed to chat with planning agent');
  }

  static Future<AgentChatResponse> todoChat({
    required int projectId,
    required List<Map<String, String>> messages,
  }) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/agent/chat'),
      headers: await _headers(),
      body: json.encode({
        'mode': 'todo',
        'project_id': projectId,
        'messages': messages,
        'require_approval': false,
      }),
    );

    if (r.statusCode == 200) {
      return AgentChatResponse.fromJson(json.decode(r.body) as Map<String, dynamic>);
    }
    throw _err(r, 'Failed to chat with todo agent');
  }

  static Future<void> clearConversation({
    required String mode,
    required int projectId,
    int? planId,
  }) async {
    final params = <String, String>{
      'mode': mode,
      'project_id': '$projectId',
      if (planId != null) 'plan_id': '$planId',
    };
    final uri = Uri.parse('$_baseUrl/agent/conversation').replace(queryParameters: params);
    await http.delete(uri, headers: await _headers());
  }

  static Future<Map<String, dynamic>> getConversation({
    required String mode,
    required int projectId,
    int? planId,
  }) async {
    final params = <String, String>{
      'mode': mode,
      'project_id': '$projectId',
      if (planId != null) 'plan_id': '$planId',
    };
    final uri = Uri.parse('$_baseUrl/agent/conversation').replace(queryParameters: params);
    final r = await http.get(uri, headers: await _headers());
    if (r.statusCode == 200) {
      final body = json.decode(r.body) as Map<String, dynamic>;
      final rawMessages = (body['messages'] as List?) ?? const [];
      return {
        'messages': rawMessages.map((m) => Map<String, dynamic>.from(m as Map)).toList(),
        'summary': body['summary'],
        'has_memory': body['has_memory'] == true,
      };
    }
    throw _err(r, 'Failed to load saved conversation');
  }

  static Future<List<Map<String, dynamic>>> applyPlanningActions({
    required int projectId,
    required int planId,
    required List<Map<String, dynamic>> toolCalls,
  }) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/agent/planning/apply-actions'),
      headers: await _headers(),
      body: json.encode({
        'project_id': projectId,
        'plan_id': planId,
        'tool_calls': toolCalls,
      }),
    );

    if (r.statusCode == 200) {
      final body = json.decode(r.body) as Map<String, dynamic>;
      final raw = (body['actions'] as List?) ?? const [];
      return raw.map((a) => Map<String, dynamic>.from(a as Map)).toList();
    }
    throw _err(r, 'Failed to apply planning actions');
  }

  static Future<Map<String, dynamic>> getSettings() async {
    final r = await http.get(
      Uri.parse('$_baseUrl/agent/settings'),
      headers: await _headers(),
    );
    if (r.statusCode == 200) {
      return json.decode(r.body) as Map<String, dynamic>;
    }
    throw _err(r, 'Failed to load AI settings');
  }

  static Future<void> updateSettings({
    String? apiKey,
    String? baseUrl,
    String? model,
  }) async {
    final r = await http.put(
      Uri.parse('$_baseUrl/agent/settings'),
      headers: await _headers(),
      body: json.encode({
        if (apiKey != null) 'api_key': apiKey,
        if (baseUrl != null) 'base_url': baseUrl,
        if (model != null) 'model': model,
      }),
    );
    if (r.statusCode != 200) {
      throw _err(r, 'Failed to save AI settings');
    }
  }

  static Future<void> clearSettings() async {
    final r = await http.delete(
      Uri.parse('$_baseUrl/agent/settings'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw _err(r, 'Failed to clear AI settings');
    }
  }

  // ── Agent routines ─────────────────────────────────────────────────────────

  /// List the user's routines. If [projectId] is given, project-scoped
  /// routines for that project are included alongside global ones.
  static Future<List<AgentRoutine>> listRoutines({int? projectId}) async {
    final uri = Uri.parse('$_baseUrl/agent/routines').replace(
      queryParameters: {if (projectId != null) 'project_id': '$projectId'},
    );
    final r = await http.get(uri, headers: await _headers());
    if (r.statusCode == 200) {
      final raw = (json.decode(r.body) as List?) ?? const [];
      return raw
          .map((e) => AgentRoutine.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    }
    throw _err(r, 'Failed to load routines');
  }

  static Future<AgentRoutine> createRoutine({
    required String name,
    required String steps,
    String? description,
    String? whenToUse,
    int? projectId,
  }) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/agent/routines'),
      headers: await _headers(),
      body: json.encode({
        'name': name,
        'steps': steps,
        if (description != null) 'description': description,
        if (whenToUse != null) 'when_to_use': whenToUse,
        if (projectId != null) 'project_id': projectId,
      }),
    );
    if (r.statusCode == 200) {
      return AgentRoutine.fromJson(json.decode(r.body) as Map<String, dynamic>);
    }
    throw _err(r, 'Failed to create routine');
  }

  static Future<AgentRoutine> updateRoutine(
    int routineId, {
    String? name,
    String? steps,
    String? description,
    String? whenToUse,
    String? scope,
    int? projectId,
  }) async {
    final r = await http.put(
      Uri.parse('$_baseUrl/agent/routines/$routineId'),
      headers: await _headers(),
      body: json.encode({
        if (name != null) 'name': name,
        if (steps != null) 'steps': steps,
        if (description != null) 'description': description,
        if (whenToUse != null) 'when_to_use': whenToUse,
        if (scope != null) 'scope': scope,
        if (projectId != null) 'project_id': projectId,
      }),
    );
    if (r.statusCode == 200) {
      return AgentRoutine.fromJson(json.decode(r.body) as Map<String, dynamic>);
    }
    throw _err(r, 'Failed to update routine');
  }

  static Future<void> deleteRoutine(int routineId) async {
    final r = await http.delete(
      Uri.parse('$_baseUrl/agent/routines/$routineId'),
      headers: await _headers(),
    );
    if (r.statusCode != 200) {
      throw _err(r, 'Failed to delete routine');
    }
  }
}

/// A saved agent routine: a reusable, named set of steps the agent can follow.
class AgentRoutine {
  final int id;
  final String name;
  final String? description;
  final String? whenToUse;
  final String scope; // "global" | "project"
  final int? projectId;
  final bool isSystem;
  final String createdBy; // "user" | "agent" | "system"
  final String steps;

  const AgentRoutine({
    required this.id,
    required this.name,
    this.description,
    this.whenToUse,
    required this.scope,
    this.projectId,
    required this.isSystem,
    required this.createdBy,
    this.steps = '',
  });

  factory AgentRoutine.fromJson(Map<String, dynamic> json) {
    return AgentRoutine(
      id: json['id'] as int,
      name: (json['name'] ?? '').toString(),
      description: json['description'] as String?,
      whenToUse: json['when_to_use'] as String?,
      scope: (json['scope'] ?? 'global').toString(),
      projectId: json['project_id'] as int?,
      isSystem: json['is_system'] == true,
      createdBy: (json['created_by'] ?? 'user').toString(),
      steps: (json['steps'] ?? '').toString(),
    );
  }
}

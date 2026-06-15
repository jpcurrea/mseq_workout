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
}

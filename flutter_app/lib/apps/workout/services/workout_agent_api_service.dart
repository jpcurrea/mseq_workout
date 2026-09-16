import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../../shared/services/auth_service.dart';

/// Reply from the workout coach agent.
class CoachChatResponse {
  final String reply;

  /// Tool results that were actually executed this turn.
  final List<Map<String, dynamic>> actions;

  /// True when [proposedToolCalls] are waiting for the user to approve them.
  final bool pendingApproval;
  final List<Map<String, dynamic>> proposedToolCalls;

  const CoachChatResponse({
    required this.reply,
    required this.actions,
    required this.pendingApproval,
    required this.proposedToolCalls,
  });

  /// True when the agent changed workouts or the schedule, so the UI should reload.
  bool get mutatedData => actions.any((a) =>
      a['ok'] == true &&
      a['dry_run'] != true &&
      const {
        'create_workout',
        'update_workout',
        'delete_workout',
        'log_score',
        'generate_routine',
      }.contains(a['action']));

  factory CoachChatResponse.fromJson(Map<String, dynamic> json) {
    final rawActions = (json['actions'] as List?) ?? const [];
    final rawProposed = (json['proposed_tool_calls'] as List?) ?? const [];
    return CoachChatResponse(
      reply: (json['reply'] ?? '').toString(),
      actions: rawActions.map((a) => Map<String, dynamic>.from(a as Map)).toList(),
      pendingApproval: json['pending_approval'] == true,
      proposedToolCalls:
          rawProposed.map((a) => Map<String, dynamic>.from(a as Map)).toList(),
    );
  }
}

/// Client for the `/workout-agent` endpoints.
class WorkoutAgentApiService {
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

  static Future<CoachChatResponse> chat({
    required List<Map<String, String>> messages,
    bool requireApproval = false,
  }) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/workout-agent/chat'),
      headers: await _headers(),
      body: json.encode({
        'messages': messages,
        'require_approval': requireApproval,
      }),
    );
    if (r.statusCode == 200) {
      return CoachChatResponse.fromJson(json.decode(r.body) as Map<String, dynamic>);
    }
    throw _err(r, 'Failed to chat with your coach');
  }

  /// Commits tool calls that a `requireApproval: true` turn queued up.
  static Future<List<Map<String, dynamic>>> applyActions(
    List<Map<String, dynamic>> toolCalls,
  ) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/workout-agent/apply-actions'),
      headers: await _headers(),
      body: json.encode({'tool_calls': toolCalls}),
    );
    if (r.statusCode == 200) {
      final body = json.decode(r.body) as Map<String, dynamic>;
      final raw = (body['results'] as List?) ?? const [];
      return raw.map((a) => Map<String, dynamic>.from(a as Map)).toList();
    }
    throw _err(r, 'Failed to apply coach actions');
  }

  static Future<Map<String, dynamic>> getConversation() async {
    final r = await http.get(
      Uri.parse('$_baseUrl/workout-agent/conversation'),
      headers: await _headers(),
    );
    if (r.statusCode == 200) {
      final body = json.decode(r.body) as Map<String, dynamic>;
      final rawMessages = (body['messages'] as List?) ?? const [];
      return {
        'messages':
            rawMessages.map((m) => Map<String, dynamic>.from(m as Map)).toList(),
        'summary': body['summary'],
        'has_memory': body['has_memory'] == true,
      };
    }
    throw _err(r, 'Failed to load saved conversation');
  }

  static Future<void> clearConversation() async {
    await http.delete(
      Uri.parse('$_baseUrl/workout-agent/conversation'),
      headers: await _headers(),
    );
  }
}

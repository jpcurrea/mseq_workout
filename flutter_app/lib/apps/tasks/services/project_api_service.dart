import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/project.dart';
import '../../../shared/services/auth_service.dart';

class ProjectApiService {
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

  // ── Projects ───────────────────────────────────────────────────────────────

  static Future<List<Project>> getProjects() async {
    final r = await http.get(Uri.parse('$_baseUrl/projects'), headers: await _headers());
    if (r.statusCode == 200) {
      return (json.decode(r.body) as List).map((p) => Project.fromJson(p)).toList();
    }
    throw _err(r, 'Failed to load projects');
  }

  static Future<Project> getActiveProject() async {
    final r = await http.get(
        Uri.parse('$_baseUrl/projects/me/active'), headers: await _headers());
    if (r.statusCode == 200) return Project.fromJson(json.decode(r.body));
    throw _err(r, 'Failed to load active project');
  }

  static Future<Project> createProject(String name, {String? description}) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/projects'),
      headers: await _headers(),
      body: json.encode({'name': name, if (description != null) 'description': description}),
    );
    if (r.statusCode == 200) return Project.fromJson(json.decode(r.body));
    throw _err(r, 'Failed to create project');
  }

  static Future<Project> updateProject(int id, {String? name, String? description}) async {
    final r = await http.put(
      Uri.parse('$_baseUrl/projects/$id'),
      headers: await _headers(),
      body: json.encode({
        if (name != null) 'name': name,
        if (description != null) 'description': description,
      }),
    );
    if (r.statusCode == 200) return Project.fromJson(json.decode(r.body));
    throw _err(r, 'Failed to update project');
  }

  static Future<void> deleteProject(int id) async {
    final r = await http.delete(
        Uri.parse('$_baseUrl/projects/$id'), headers: await _headers());
    if (r.statusCode != 200) throw _err(r, 'Failed to delete project');
  }

  static Future<void> setActiveProject(int projectId) async {
    final r = await http.post(
        Uri.parse('$_baseUrl/projects/$projectId/activate'), headers: await _headers());
    if (r.statusCode != 200) throw _err(r, 'Failed to set active project');
  }

  // ── Members ────────────────────────────────────────────────────────────────

  static Future<List<ProjectMember>> getMembers(int projectId) async {
    final r = await http.get(
        Uri.parse('$_baseUrl/projects/$projectId/members'), headers: await _headers());
    if (r.statusCode == 200) {
      return (json.decode(r.body) as List).map((m) => ProjectMember.fromJson(m)).toList();
    }
    throw _err(r, 'Failed to load members');
  }

  static Future<void> removeMember(int projectId, int targetUserId) async {
    final r = await http.delete(
        Uri.parse('$_baseUrl/projects/$projectId/members/$targetUserId'),
        headers: await _headers());
    if (r.statusCode != 200) throw _err(r, 'Failed to remove member');
  }

  // ── Invites ────────────────────────────────────────────────────────────────

  static Future<ProjectInvite> createInvite(
    int projectId, {
    String roleToGrant = 'editor',
    int? maxUses,
    int? expiresHours,
  }) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/projects/$projectId/invites'),
      headers: await _headers(),
      body: json.encode({
        'role_to_grant': roleToGrant,
        if (maxUses != null) 'max_uses': maxUses,
        if (expiresHours != null) 'expires_hours': expiresHours,
      }),
    );
    if (r.statusCode == 200) return ProjectInvite.fromJson(json.decode(r.body));
    throw _err(r, 'Failed to create invite');
  }

  static Future<List<ProjectInvite>> getInvites(int projectId) async {
    final r = await http.get(
        Uri.parse('$_baseUrl/projects/$projectId/invites'), headers: await _headers());
    if (r.statusCode == 200) {
      return (json.decode(r.body) as List).map((i) => ProjectInvite.fromJson(i)).toList();
    }
    throw _err(r, 'Failed to load invites');
  }

  static Future<void> revokeInvite(int projectId, int inviteId) async {
    final r = await http.delete(
        Uri.parse('$_baseUrl/projects/$projectId/invites/$inviteId'),
        headers: await _headers());
    if (r.statusCode != 200) throw _err(r, 'Failed to revoke invite');
  }

  static Future<Map<String, dynamic>> redeemInvite(String token) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/projects/join'),
      headers: await _headers(),
      body: json.encode({'token': token}),
    );
    if (r.statusCode == 200) return json.decode(r.body) as Map<String, dynamic>;
    throw _err(r, 'Failed to join project');
  }
}

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../../shared/services/auth_service.dart';

class BudgetApiService {
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

  static Future<Map<String, dynamic>> getSummary() async {
    final r = await http.get(Uri.parse('$_baseUrl/budget/summary'), headers: await _headers());
    if (r.statusCode == 200) return json.decode(r.body) as Map<String, dynamic>;
    throw _err(r, 'Failed to load budget summary');
  }

  static Future<List<Map<String, dynamic>>> getAccounts() async {
    final r = await http.get(Uri.parse('$_baseUrl/budget/accounts'), headers: await _headers());
    if (r.statusCode == 200) return List<Map<String, dynamic>>.from(json.decode(r.body));
    throw _err(r, 'Failed to load accounts');
  }

  static Future<void> createAccount(String name, double balance) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/budget/accounts'),
      headers: await _headers(),
      body: json.encode({'name': name, 'balance': balance}),
    );
    if (r.statusCode != 200) throw _err(r, 'Failed to create account');
  }

  static Future<void> updateAccount(int id, {String? name, double? balance}) async {
    final r = await http.put(
      Uri.parse('$_baseUrl/budget/accounts/$id'),
      headers: await _headers(),
      body: json.encode({if (name != null) 'name': name, if (balance != null) 'balance': balance}),
    );
    if (r.statusCode != 200) throw _err(r, 'Failed to update account');
  }

  static Future<void> deleteAccount(int id) async {
    final r = await http.delete(Uri.parse('$_baseUrl/budget/accounts/$id'), headers: await _headers());
    if (r.statusCode != 200) throw _err(r, 'Failed to delete account');
  }

  static Future<List<Map<String, dynamic>>> getGoals() async {
    final r = await http.get(Uri.parse('$_baseUrl/budget/goals'), headers: await _headers());
    if (r.statusCode == 200) return List<Map<String, dynamic>>.from(json.decode(r.body));
    throw _err(r, 'Failed to load goals');
  }

  static Future<void> createGoal(String name, double targetAmount, {String? targetDate, double currentSaved = 0.0}) async {
    final r = await http.post(
      Uri.parse('$_baseUrl/budget/goals'),
      headers: await _headers(),
      body: json.encode({
        'name': name,
        'target_amount': targetAmount,
        if (targetDate != null) 'target_date': targetDate,
        'current_saved': currentSaved,
      }),
    );
    if (r.statusCode != 200) throw _err(r, 'Failed to create goal');
  }

  static Future<void> updateGoal(int id, {String? name, double? targetAmount, double? currentSaved, String? targetDate}) async {
    final r = await http.put(
      Uri.parse('$_baseUrl/budget/goals/$id'),
      headers: await _headers(),
      body: json.encode({
        if (name != null) 'name': name,
        if (targetAmount != null) 'target_amount': targetAmount,
        if (currentSaved != null) 'current_saved': currentSaved,
        if (targetDate != null) 'target_date': targetDate,
      }),
    );
    if (r.statusCode != 200) throw _err(r, 'Failed to update goal');
  }

  static Future<void> deleteGoal(int id) async {
    final r = await http.delete(Uri.parse('$_baseUrl/budget/goals/$id'), headers: await _headers());
    if (r.statusCode != 200) throw _err(r, 'Failed to delete goal');
  }
}

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/workout.dart';
import 'auth_service.dart';

class ApiService {
  // static const String baseUrl = 'https://workout-backend-h6pd.onrender.com';
  static const String baseUrl = 'https://workout-backend-h6pd.onrender.com';

  static Future<Map<String, String>> _headers() async {
    final token = await AuthService.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static Exception _httpException(http.Response response, String fallbackMessage) {
    String message = '$fallbackMessage: ${response.statusCode}';
    try {
      final error = json.decode(response.body);
      if (error is Map<String, dynamic> && error['detail'] != null) {
        message = error['detail'].toString();
      }
    } catch (_) {}
    return Exception(message);
  }

  static Exception _networkException(Object e) {
    final msg = e.toString();
    if (msg.startsWith('Exception: ')) {
      return Exception(msg.replaceFirst('Exception: ', ''));
    }
    return Exception('Network error: $e');
  }

  static Future<List<Workout>> getWorkouts() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/workouts'),
        headers: await _headers(),
      );

      if (response.statusCode == 200) {
        final List<dynamic> jsonList = json.decode(response.body);
        return jsonList.map((json) => Workout.fromJson(json)).toList();
      } else {
        throw Exception('Failed to load workouts: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Network error: $e');
    }
  }

  static Future<List<WorkoutScheduleItem>> getTodayWorkouts() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/today'),
        headers: await _headers(),
      );

      if (response.statusCode == 200) {
        final List<dynamic> jsonList = json.decode(response.body);
        return jsonList.map((json) => WorkoutScheduleItem.fromJson(json)).toList();
      } else {
        throw Exception('Failed to load today\'s workouts: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Network error: $e');
    }
  }

  static Future<List<WorkoutScheduleItem>> getWorkoutsForDate(String date) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/schedule/$date'),
        headers: await _headers(),
      );

      if (response.statusCode == 200) {
        final List<dynamic> jsonList = json.decode(response.body);
        return jsonList.map((json) => WorkoutScheduleItem.fromJson(json)).toList();
      } else {
        throw Exception('Failed to load workouts for date: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Network error: $e');
    }
  }

  static Future<void> updateWorkoutScore(String workout, String date, double score) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/update-score'),
        headers: await _headers(),
        body: json.encode({
          'workout': workout,
          'date': date,
          'score': score,
        }),
      );

      if (response.statusCode != 200) {
        throw _httpException(response, 'Failed to update score');
      }
    } catch (e) {
      throw _networkException(e);
    }
  }

  static Future<Map<String, dynamic>> generateNewRoutine({
    String? startDate,
    int? sequencePower,
    int? minimumIntervalDays,
    int? mseqBase,
    int? activeSymbols,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/generate-routine'),
        headers: await _headers(),
        body: json.encode({
          if (startDate != null) 'start_date': startDate,
          if (sequencePower != null) 'sequence_power': sequencePower,
          if (minimumIntervalDays != null) 'minimum_interval_days': minimumIntervalDays,
          if (mseqBase != null) 'mseq_base': mseqBase,
          if (activeSymbols != null) 'active_symbols': activeSymbols,
        }),
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw _httpException(response, 'Failed to generate routine');
      }
    } catch (e) {
      throw _networkException(e);
    }
  }

  static Future<Map<String, dynamic>> getScheduleStats({
    required int sequencePower,
    required int minimumIntervalDays,
    required int mseqBase,
    required int activeSymbols,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/mseq/stats').replace(
        queryParameters: {
          'sequence_power': '$sequencePower',
          'minimum_interval_days': '$minimumIntervalDays',
          'mseq_base': '$mseqBase',
          'active_symbols': '$activeSymbols',
        },
      );
      final response = await http.get(uri, headers: await _headers());
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw _httpException(response, 'Failed to load schedule stats');
    } catch (e) {
      throw _networkException(e);
    }
  }

  static Future<void> createWorkout(Workout workout) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/workouts'),
        headers: await _headers(),
        body: json.encode({
          'name': workout.name,
          'goal': workout.goal,
          'units': workout.units,
          'at_park': workout.atPark,
          if (workout.exerciseId != null) 'exercise_id': workout.exerciseId,
        }),
      );

      if (response.statusCode != 200) {
        throw _httpException(response, 'Failed to create workout');
      }
    } catch (e) {
      throw _networkException(e);
    }
  }

  static Future<void> updateWorkout(
    String workoutName,
    double goal,
    String units,
    bool atPark, {
    String? exerciseId,
    bool exerciseIdProvided = false,
    String? newName,
  }) async {
    final body = <String, dynamic>{
      'goal': goal,
      'units': units,
      'at_park': atPark,
      if (exerciseIdProvided) 'exercise_id': exerciseId,
      if (newName != null && newName.isNotEmpty) 'new_name': newName,
    };
    final response = await http.put(
      Uri.parse('$baseUrl/workouts/$workoutName'),
      headers: await _headers(),
      body: json.encode(body),
    );

    if (response.statusCode != 200) {
      throw _httpException(response, 'Failed to update workout');
    }
  }

  static Future<void> deleteWorkout(String workoutName) async {
    try {
      final response = await http.delete(
        Uri.parse('$baseUrl/workouts/$workoutName'),
        headers: await _headers(),
      );

      if (response.statusCode != 200) {
        throw _httpException(response, 'Failed to delete workout');
      }
    } catch (e) {
      throw _networkException(e);
    }
  }

  static Future<List<String>> getWorkoutNames() async {
    final workouts = await getWorkouts();
    return workouts.map((w) => w.name).toList();
  }

  static Future<List<Map<String, dynamic>>> searchExercises(String query) async {
    try {
      final uri = Uri.parse('$baseUrl/exercises/search')
          .replace(queryParameters: {'q': query, 'limit': '10'});
      final response = await http.get(uri, headers: await _headers());
      if (response.statusCode == 200) {
        final List<dynamic> list = json.decode(response.body);
        return list.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> getWorkoutHistory(
    String workoutName, {
    int limit = 20,
    String? since,
  }) async {
    try {
      final encodedName = Uri.encodeComponent(workoutName);
      final params = <String, String>{'limit': limit.toString()};
      if (since != null) params['since'] = since;
      final uri = Uri.parse('$baseUrl/workouts/$encodedName/history')
          .replace(queryParameters: params);
      final response = await http.get(uri, headers: await _headers());
      if (response.statusCode == 200) {
        final List<dynamic> list = json.decode(response.body);
        return list.cast<Map<String, dynamic>>();
      } else {
        throw _httpException(response, 'Failed to load history');
      }
    } catch (e) {
      throw _networkException(e);
    }
  }

  static Future<Map<String, dynamic>> getWorkoutIntervalDistribution(
    String workoutName, {
    int maxDays = 60,
  }) async {
    try {
      final encodedName = Uri.encodeComponent(workoutName);
      final uri = Uri.parse('$baseUrl/workouts/$encodedName/interval-distribution')
          .replace(queryParameters: {'max_days': '$maxDays'});
      final response = await http.get(uri, headers: await _headers());
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      throw _httpException(response, 'Failed to load interval distribution');
    } catch (e) {
      throw _networkException(e);
    }
  }
}

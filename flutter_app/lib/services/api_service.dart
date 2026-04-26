import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/workout.dart';
import 'auth_service.dart';

class ApiService {
  // static const String baseUrl = 'http://localhost:8000';
  static const String baseUrl = 'https://workout-backend-h6pd.onrender.com';

  static Future<Map<String, String>> _headers() async {
    final token = await AuthService.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
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
        throw Exception('Failed to update score: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Network error: $e');
    }
  }

  static Future<Map<String, dynamic>> generateNewRoutine({
    String? startDate,
    int? sequencePower,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/generate-routine'),
        headers: await _headers(),
        body: json.encode({
          if (startDate != null) 'start_date': startDate,
          if (sequencePower != null) 'sequence_power': sequencePower,
        }),
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to generate routine: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Network error: $e');
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
        final error = json.decode(response.body);
        throw Exception(error['detail'] ?? 'Failed to create workout');
      }
    } catch (e) {
      throw Exception('Network error: $e');
    }
  }

  static Future<void> updateWorkout(String workoutName, double goal, String units, bool atPark) async {
    try {
      final response = await http.put(
        Uri.parse('$baseUrl/workouts/$workoutName'),
        headers: await _headers(),
        body: json.encode({
          'goal': goal,
          'units': units,
          'at_park': atPark,
        }),
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to update workout: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Network error: $e');
    }
  }

  static Future<void> deleteWorkout(String workoutName) async {
    try {
      final response = await http.delete(
        Uri.parse('$baseUrl/workouts/$workoutName'),
        headers: await _headers(),
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to delete workout: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Network error: $e');
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
        throw Exception('Failed to load history: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Network error: $e');
    }
  }
}

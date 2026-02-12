import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/workout.dart';
import '../services/api_service.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  DateTime selectedDate = DateTime.now();
  List<WorkoutScheduleItem> workouts = [];
  bool isLoading = false;

  @override
  void initState() {
    super.initState();
    loadWorkoutsForDate();
  }

  Future<void> loadWorkoutsForDate() async {
    setState(() {
      isLoading = true;
    });

    try {
      final dateString = DateFormat('yyyy-MM-dd').format(selectedDate);
      final workoutList = await ApiService.getWorkoutsForDate(dateString);
      setState(() {
        workouts = workoutList;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading workouts: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Workout History'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    DateFormat('EEEE, MMMM d, y').format(selectedDate),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                ElevatedButton(
                  onPressed: _selectDate,
                  child: const Text('Change Date'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _buildWorkoutList(),
          ),
        ],
      ),
    );
  }

  Widget _buildWorkoutList() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (workouts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.event_busy,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No workouts scheduled',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'for ${DateFormat('MMMM d, y').format(selectedDate)}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: workouts.length,
      itemBuilder: (context, index) {
        final workout = workouts[index];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: workout.atPark ? Colors.green : Colors.blue,
              child: Icon(
                workout.atPark ? Icons.park : Icons.home,
                color: Colors.white,
              ),
            ),
            title: Text(
              workout.workout,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Goal: ${workout.goal} ${workout.units}'),
                if (workout.score != null)
                  Text(
                    'Completed: ${workout.score} ${workout.units} (${workout.progressPercentage.toStringAsFixed(1)}%)',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  )
                else
                  Text(
                    'Not completed',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
              ],
            ),
            trailing: workout.isCompleted
                ? Icon(
                    Icons.check_circle,
                    color: workout.progressPercentage >= 100
                        ? Colors.green
                        : Colors.orange,
                  )
                : const Icon(Icons.radio_button_unchecked),
          ),
        );
      },
    );
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );

    if (picked != null && picked != selectedDate) {
      setState(() {
        selectedDate = picked;
      });
      loadWorkoutsForDate();
    }
  }
}
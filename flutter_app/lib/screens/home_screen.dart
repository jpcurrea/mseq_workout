import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/workout.dart';
import '../services/api_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<WorkoutScheduleItem> todayWorkouts = [];
  bool isLoading = true;
  String? errorMessage;
  Map<int, TextEditingController> scoreControllers = {};
  bool isUpdatingScores = false;

  @override
  void initState() {
    super.initState();
    loadTodayWorkouts();
  }

  @override
  void dispose() {
    for (var controller in scoreControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> loadTodayWorkouts() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final workouts = await ApiService.getTodayWorkouts();
      // Initialize controllers for score inputs
      scoreControllers.clear();
      for (int i = 0; i < workouts.length; i++) {
        scoreControllers[i] = TextEditingController(
          text: workouts[i].score?.toString() ?? '',
        );
      }
      setState(() {
        todayWorkouts = workouts;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        errorMessage = e.toString();
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final dateFormat = DateFormat('EEEE, MMMM d, y');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Today\'s Workout'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        leading: PopupMenuButton<String>(
          icon: const Icon(Icons.menu),
          onSelected: (String value) {
            switch (value) {
              case 'generate_routine':
                _showGenerateRoutineDialog();
                break;
              case 'manage_workouts':
                Navigator.pushNamed(context, '/manage-workouts');
                break;
              case 'refresh':
                loadTodayWorkouts();
                break;
            }
          },
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            const PopupMenuItem<String>(
              value: 'generate_routine',
              child: ListTile(
                leading: Icon(Icons.auto_fix_high),
                title: Text('Generate New Routine'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem<String>(
              value: 'manage_workouts',
              child: ListTile(
                leading: Icon(Icons.edit),
                title: Text('Manage Workouts'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem<String>(
              value: 'refresh',
              child: ListTile(
                leading: Icon(Icons.refresh),
                title: Text('Refresh Workouts'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.pushNamed(context, '/history'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: Text(
              dateFormat.format(today),
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: _buildWorkoutList(),
          ),
          if (todayWorkouts.isNotEmpty) _buildSubmitSection(),
        ],
      ),
    );
  }

  Widget _buildWorkoutList() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              'Error loading workouts',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              errorMessage!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: loadTodayWorkouts,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (todayWorkouts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.fitness_center,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'No workouts scheduled for today!',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Take a rest day or generate a new routine.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: loadTodayWorkouts,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        itemCount: todayWorkouts.length,
        itemBuilder: (context, index) {
          final workout = todayWorkouts[index];
          final controller = scoreControllers[index]!;
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: workout.atPark ? Colors.green : Colors.blue,
                    child: Icon(
                      workout.atPark ? Icons.park : Icons.home,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                workout.workout,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 60,
                              height: 32,
                              child: TextField(
                                controller: controller,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: InputDecoration(
                                  hintText: '',
                                  suffixText: workout.units,
                                  border: const OutlineInputBorder(),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                  isDense: true,
                                ),
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                        Text(
                          'Goal: ${workout.goal} ${workout.units}',
                          style: const TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                        if (workout.score != null)
                          Row(
                            children: [
                              Text(
                                'Current: ${workout.score} (${workout.progressPercentage.toStringAsFixed(0)}%)',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 12,
                                ),
                              ),
                              if (workout.isCompleted)
                                const Padding(
                                  padding: EdgeInsets.only(left: 4),
                                  child: Icon(Icons.check_circle, color: Colors.green, size: 16),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showGenerateRoutineDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Generate New Routine'),
          content: const Text(
            'This will generate a new workout routine. Your current progress will be preserved, but the schedule will be updated.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await _generateNewRoutine();
              },
              child: const Text('Generate'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _generateNewRoutine() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Generating new routine...'),
            ],
          ),
        );
      },
    );

    try {
      await ApiService.generateNewRoutine();
      Navigator.of(context).pop(); // Close progress dialog
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('New routine generated successfully!')),
      );
      loadTodayWorkouts(); // Refresh the workout list
    } catch (e) {
      Navigator.of(context).pop(); // Close progress dialog
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error generating routine: $e')),
      );
    }
  }

  Widget _buildSubmitSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor,
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: isUpdatingScores ? null : _submitAllScores,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: isUpdatingScores
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text(
                    'Submit All Scores',
                    style: TextStyle(fontSize: 16),
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _submitAllScores() async {
    setState(() {
      isUpdatingScores = true;
    });

    try {
      int updatedCount = 0;
      List<String> errors = [];

      for (int i = 0; i < todayWorkouts.length; i++) {
        final workout = todayWorkouts[i];
        final scoreText = scoreControllers[i]?.text.trim() ?? '';
        
        if (scoreText.isNotEmpty) {
          final score = double.tryParse(scoreText);
          if (score != null) {
            try {
              await ApiService.updateWorkoutScore(
                workout.workout,
                workout.date,
                score,
              );
              updatedCount++;
            } catch (e) {
              errors.add('${workout.workout}: $e');
            }
          } else {
            errors.add('${workout.workout}: Invalid score format');
          }
        }
      }

      if (errors.isEmpty && updatedCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully updated $updatedCount workout scores!'),
            backgroundColor: Colors.green,
          ),
        );
        loadTodayWorkouts(); // Refresh the data
      } else if (updatedCount > 0 && errors.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Updated $updatedCount scores. ${errors.length} errors occurred.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
        loadTodayWorkouts(); // Refresh the data
      } else if (errors.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Errors: ${errors.join("; ")}'),
            backgroundColor: Colors.red,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No scores to update. Enter scores in the fields above.'),
          ),
        );
      }
    } finally {
      setState(() {
        isUpdatingScores = false;
      });
    }
  }
}
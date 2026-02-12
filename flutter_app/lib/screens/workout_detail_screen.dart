import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/workout.dart';
import '../services/api_service.dart';

class WorkoutDetailScreen extends StatefulWidget {
  final WorkoutScheduleItem workout;

  const WorkoutDetailScreen({
    super.key,
    required this.workout,
  });

  @override
  State<WorkoutDetailScreen> createState() => _WorkoutDetailScreenState();
}

class _WorkoutDetailScreenState extends State<WorkoutDetailScreen> {
  final TextEditingController _scoreController = TextEditingController();
  bool isUpdating = false;

  @override
  void initState() {
    super.initState();
    if (widget.workout.score != null) {
      _scoreController.text = widget.workout.score.toString();
    }
  }

  @override
  void dispose() {
    _scoreController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.workout.workout),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          widget.workout.atPark ? Icons.park : Icons.home,
                          color: widget.workout.atPark ? Colors.green : Colors.blue,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          widget.workout.atPark ? 'At Park' : 'At Home',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Goal: ${widget.workout.goal} ${widget.workout.units}',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Date: ${widget.workout.date}',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    if (widget.workout.score != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Current Score: ${widget.workout.score} ${widget.workout.units}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: widget.workout.progressPercentage / 100,
                        backgroundColor: Colors.grey[300],
                        valueColor: AlwaysStoppedAnimation<Color>(
                          widget.workout.progressPercentage >= 100
                              ? Colors.green
                              : Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${widget.workout.progressPercentage.toStringAsFixed(1)}% of goal',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Update Your Score',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _scoreController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
              ],
              decoration: InputDecoration(
                labelText: 'Score (${widget.workout.units})',
                hintText: 'Enter your achieved score',
                border: const OutlineInputBorder(),
                suffixText: widget.workout.units,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: isUpdating ? null : _updateScore,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: isUpdating
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text(
                        'Update Score',
                        style: TextStyle(fontSize: 16),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            if (widget.workout.score != null)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: isUpdating ? null : _clearScore,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text(
                    'Clear Score',
                    style: TextStyle(fontSize: 16),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _updateScore() async {
    final scoreText = _scoreController.text.trim();
    if (scoreText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a score')),
      );
      return;
    }

    final score = double.tryParse(scoreText);
    if (score == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid number')),
      );
      return;
    }

    setState(() {
      isUpdating = true;
    });

    try {
      await ApiService.updateWorkoutScore(
        widget.workout.workout,
        widget.workout.date,
        score,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Score updated successfully!')),
      );

      // Return true to indicate the workout was updated
      Navigator.of(context).pop(true);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error updating score: $e')),
      );
    } finally {
      setState(() {
        isUpdating = false;
      });
    }
  }

  Future<void> _clearScore() async {
    setState(() {
      isUpdating = true;
    });

    try {
      await ApiService.updateWorkoutScore(
        widget.workout.workout,
        widget.workout.date,
        0, // Setting score to 0 to clear it
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Score cleared successfully!')),
      );

      // Return true to indicate the workout was updated
      Navigator.of(context).pop(true);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error clearing score: $e')),
      );
    } finally {
      setState(() {
        isUpdating = false;
      });
    }
  }
}
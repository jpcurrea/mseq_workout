import 'dart:async';
import 'package:flutter/material.dart';
import '../models/workout.dart';
import '../services/api_service.dart';

class WorkoutManagementScreen extends StatefulWidget {
  const WorkoutManagementScreen({super.key});

  @override
  State<WorkoutManagementScreen> createState() => _WorkoutManagementScreenState();
}

class _WorkoutManagementScreenState extends State<WorkoutManagementScreen> {
  List<Workout> workouts = [];
  bool isLoading = true;
  String? errorMessage;
  Map<int, WorkoutEditControllers> editControllers = {};
  bool isSaving = false;

  @override
  void initState() {
    super.initState();
    loadWorkouts();
  }

  @override
  void dispose() {
    for (var controllers in editControllers.values) {
      controllers.dispose();
    }
    super.dispose();
  }

  Future<void> loadWorkouts() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final loadedWorkouts = await ApiService.getWorkouts();
      
      // Initialize controllers for each workout
      editControllers.clear();
      for (int i = 0; i < loadedWorkouts.length; i++) {
        editControllers[i] = WorkoutEditControllers(
          nameController: TextEditingController(text: loadedWorkouts[i].name),
          goalController: TextEditingController(text: loadedWorkouts[i].goal.toString()),
          unitsController: TextEditingController(text: loadedWorkouts[i].units),
          atPark: loadedWorkouts[i].atPark,
        );
      }
      
      setState(() {
        workouts = loadedWorkouts;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        errorMessage = e.toString();
        isLoading = false;
      });
    }
  }

  Future<void> _addNewWorkout() async {
    final result = await showDialog<Workout>(
      context: context,
      builder: (BuildContext context) => const AddWorkoutDialog(),
    );

    if (result != null) {
      setState(() => isSaving = true);
      try {
        await ApiService.createWorkout(result);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Workout added successfully!'), backgroundColor: Colors.green),
        );
        await loadWorkouts();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding workout: $e'), backgroundColor: Colors.red),
        );
      } finally {
        setState(() => isSaving = false);
      }
    }
  }

  Future<void> _saveWorkout(int index) async {
    final controllers = editControllers[index]!;
    final originalName = workouts[index].name;
    
    final goal = double.tryParse(controllers.goalController.text);
    final units = controllers.unitsController.text.trim();
    
    if (goal == null || goal <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid goal')),
      );
      return;
    }
    
    if (units.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter units')),
      );
      return;
    }

    setState(() => isSaving = true);
    try {
      await ApiService.updateWorkout(originalName, goal, units, controllers.atPark);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Workout updated successfully!'), backgroundColor: Colors.green),
      );
      await loadWorkouts();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error updating workout: $e'), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => isSaving = false);
    }
  }

  Future<void> _deleteWorkout(int index) async {
    final workout = workouts[index];
    
    final confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete Workout'),
          content: Text('Are you sure you want to delete "${workout.name}"?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      setState(() => isSaving = true);
      try {
        await ApiService.deleteWorkout(workout.name);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Workout deleted successfully!'), backgroundColor: Colors.green),
        );
        await loadWorkouts();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting workout: $e'), backgroundColor: Colors.red),
        );
      } finally {
        setState(() => isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Workouts'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle),
            onPressed: isSaving ? null : _addNewWorkout,
            tooltip: 'Add Workout',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
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
              onPressed: loadWorkouts,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (workouts.isEmpty) {
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
              'No workouts found',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Add your first workout to get started.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: workouts.length,
      itemBuilder: (context, index) => _buildWorkoutCard(index),
    );
  }

  Widget _buildWorkoutCard(int index) {
    final controllers = editControllers[index]!;
    final originalWorkout = workouts[index];

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    originalWorkout.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: isSaving ? null : () => _deleteWorkout(index),
                  tooltip: 'Delete',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: controllers.goalController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Goal',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: controllers.unitsController,
                    decoration: const InputDecoration(
                      labelText: 'Units',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<bool>(
                    initialValue: controllers.atPark,
                    decoration: const InputDecoration(
                      labelText: 'Location',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: false, child: Text('Home')),
                      DropdownMenuItem(value: true, child: Text('Park')),
                    ],
                    onChanged: (value) {
                      setState(() {
                        controllers.atPark = value ?? false;
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: isSaving ? null : () => _saveWorkout(index),
                icon: const Icon(Icons.save, size: 18),
                label: const Text('Save Changes'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WorkoutEditControllers {
  final TextEditingController nameController;
  final TextEditingController goalController;
  final TextEditingController unitsController;
  bool atPark;

  WorkoutEditControllers({
    required this.nameController,
    required this.goalController,
    required this.unitsController,
    required this.atPark,
  });

  void dispose() {
    nameController.dispose();
    goalController.dispose();
    unitsController.dispose();
  }
}

class AddWorkoutDialog extends StatefulWidget {
  const AddWorkoutDialog({super.key});

  @override
  State<AddWorkoutDialog> createState() => _AddWorkoutDialogState();
}

class _AddWorkoutDialogState extends State<AddWorkoutDialog> {
  final _nameController = TextEditingController();
  final _goalController = TextEditingController();
  final _unitsController = TextEditingController();
  bool _atPark = false;

  // Exercise autocomplete state
  String? _exerciseId;
  List<Map<String, dynamic>> _suggestions = [];
  bool _loadingSuggestions = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _nameController.dispose();
    _goalController.dispose();
    _unitsController.dispose();
    super.dispose();
  }

  void _onNameChanged(String value) {
    // Clear any previously linked exercise when the user edits the name
    _exerciseId = null;
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    if (value.trim().length < 2) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      setState(() => _loadingSuggestions = true);
      final results = await ApiService.searchExercises(value.trim());
      if (mounted) {
        setState(() {
          _suggestions = results;
          _loadingSuggestions = false;
        });
      }
    });
  }

  void _selectSuggestion(Map<String, dynamic> s) {
    _nameController.text = s['name'] as String;
    _exerciseId = s['id'] as String;
    // Auto-fill units hint from primary muscles if units is still blank
    setState(() => _suggestions = []);
  }

  void _submit() {
    final name = _nameController.text.trim();
    final goalText = _goalController.text.trim();
    final units = _unitsController.text.trim();

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a workout name')),
      );
      return;
    }

    final goal = double.tryParse(goalText);
    if (goal == null || goal <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid goal')),
      );
      return;
    }

    if (units.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter units')),
      );
      return;
    }

    Navigator.of(context).pop(Workout(
      name: name,
      goal: goal,
      units: units,
      atPark: _atPark,
      exerciseId: _exerciseId,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add New Workout'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Workout Name',
                border: const OutlineInputBorder(),
                suffixIcon: _exerciseId != null
                    ? const Icon(Icons.link, color: Colors.green, size: 18)
                    : null,
              ),
              autofocus: true,
              onChanged: _onNameChanged,
            ),
            // Suggestion dropdown
            if (_loadingSuggestions)
              const LinearProgressIndicator(minHeight: 2),
            if (_suggestions.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(4)),
                  color: Theme.of(context).colorScheme.surface,
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black12,
                        blurRadius: 4,
                        offset: const Offset(0, 2))
                  ],
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: _suggestions.length,
                  itemBuilder: (_, i) {
                    final s = _suggestions[i];
                    final muscles =
                        (s['primaryMuscles'] as List?)?.join(', ') ?? '';
                    return InkWell(
                      onTap: () => _selectSuggestion(s),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s['name'] as String,
                                style: const TextStyle(fontSize: 13)),
                            if (muscles.isNotEmpty)
                              Text(muscles,
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _goalController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Goal',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _unitsController,
              decoration: const InputDecoration(
                labelText: 'Units (e.g., reps, minutes, miles)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<bool>(
              initialValue: _atPark,
              decoration: const InputDecoration(
                labelText: 'Location',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: false, child: Text('Home')),
                DropdownMenuItem(value: true, child: Text('Park')),
              ],
              onChanged: (value) {
                setState(() {
                  _atPark = value ?? false;
                });
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

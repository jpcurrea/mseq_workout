import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/workout.dart';
import '../../../shared/services/api_service.dart';
import '../../../shared/widgets/workout_history_panel.dart';

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
  int _mseqBase = 5;
  int _sequencePower = 4;
  int _activeSymbols = 1;
  int _minimumIntervalDays = 2;
  bool _loadingScheduleStats = true;
  String? _scheduleStatsError;
  Map<String, dynamic>? _scheduleStats;

  static const Map<int, List<int>> _supportedPowersByBase = {
    2: [2, 3, 4, 5, 6],
    3: [2, 3, 4, 5, 6],
    5: [2, 3, 4],
    9: [2],
  };

  List<int> _powerOptionsForCurrentBase() {
    return _supportedPowersByBase[_mseqBase] ?? const [2, 3, 4, 5, 6];
  }

  @override
  void initState() {
    super.initState();
    loadWorkouts();
    _loadScheduleStats();
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
      _loadScheduleStats();
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
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Workout added successfully!'), backgroundColor: Colors.green),
        );
        await loadWorkouts();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding workout: $e'), backgroundColor: Colors.red),
        );
      } finally {
        if (mounted) setState(() => isSaving = false);
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
      await ApiService.updateWorkout(
        originalName, goal, units, controllers.atPark,
        exerciseId: workouts[index].exerciseId,
        exerciseIdProvided: true,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Workout updated successfully!'), backgroundColor: Colors.green),
      );
      await loadWorkouts();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error updating workout: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  Future<void> _editMeta(int index) async {
    final workout = workouts[index];
    final result = await showDialog<({String name, String? exerciseId, bool exerciseIdProvided})>(
      context: context,
      builder: (_) => EditWorkoutMetaDialog(
        currentName: workout.name,
        currentExerciseId: workout.exerciseId,
      ),
    );
    if (result == null) return;
    setState(() => isSaving = true);
    try {
      await ApiService.updateWorkout(
        workout.name,
        workout.goal,
        workout.units,
        workout.atPark,
        newName: result.name != workout.name ? result.name : null,
        exerciseId: result.exerciseId,
        exerciseIdProvided: result.exerciseIdProvided,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Workout updated!'), backgroundColor: Colors.green),
      );
      await loadWorkouts();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => isSaving = false);
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
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Workout deleted successfully!'), backgroundColor: Colors.green),
        );
        await loadWorkouts();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting workout: $e'), backgroundColor: Colors.red),
        );
      } finally {
        if (mounted) setState(() => isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Workouts'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
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

    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        Card(
          child: ExpansionTile(
            initiallyExpanded: true,
            leading: const Icon(Icons.list_alt),
            title: const Text(
              '1. Choose your workouts:',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text('Add, edit, delete, and fine-tune each workout.'),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  onPressed: isSaving ? null : _addNewWorkout,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Workout'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 460,
                child: workouts.isEmpty
                    ? Center(
                        child: Text(
                          'No workouts yet. Tap Add Workout to create your first one.',
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        itemCount: workouts.length,
                        itemBuilder: (context, index) => _buildWorkoutCard(index),
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: ExpansionTile(
            initiallyExpanded: true,
            leading: const Icon(Icons.auto_fix_high),
            title: const Text(
              '2. Customize your chaos:',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text('Set m-sequence power, symbol density, and minimum interval.'),
            childrenPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            children: [
              SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<int>(
                      value: _sequencePower,
                      decoration: const InputDecoration(
                        labelText: 'Sequence power',
                        border: OutlineInputBorder(),
                      ),
                      items: _powerOptionsForCurrentBase()
                          .map(
                            (p) => DropdownMenuItem(
                              value: p,
                              child: Text('$p (${math.pow(_mseqBase, p).toInt() - 1} frames)'),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _sequencePower = value);
                        _loadScheduleStats();
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      value: _activeSymbols,
                      decoration: const InputDecoration(
                        labelText: 'Workout density (active symbols)',
                        border: OutlineInputBorder(),
                      ),
                      items: List.generate(_mseqBase - 1, (i) => i + 1)
                          .map(
                            (s) => DropdownMenuItem(
                              value: s,
                              child: Text('$s of $_mseqBase symbols active (~${(100 * s / _mseqBase).toStringAsFixed(0)}% frequency)'),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _activeSymbols = value);
                        _loadScheduleStats();
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Higher density means each workout appears more often across the sequence.',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 12),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 12),
                      title: const Text(
                        'Advanced m-sequence settings',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      subtitle: const Text('Base changes symbol space and density behavior.'),
                      children: [
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int>(
                          value: _mseqBase,
                          decoration: const InputDecoration(
                            labelText: 'm-sequence base',
                            border: OutlineInputBorder(),
                          ),
                          items: const [2, 3, 5, 9]
                              .map(
                                (b) => DropdownMenuItem(
                                  value: b,
                                  child: Text('Base $b (${b - 1} non-zero symbol${b == 2 ? '' : 's'})'),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() {
                              _mseqBase = value;
                              final powerOptions = _powerOptionsForCurrentBase();
                              if (!powerOptions.contains(_sequencePower)) {
                                _sequencePower = powerOptions.last;
                              }
                              if (_activeSymbols > _mseqBase - 1) {
                                _activeSymbols = _mseqBase - 1;
                              }
                            });
                            _loadScheduleStats();
                          },
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Base 5 or 9 give fine density control. Base 3 gives a short, dense cycle. Base 2 is binary (on/off, 50% density).',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      value: _minimumIntervalDays,
                      decoration: const InputDecoration(
                        labelText: 'Minimum interval (days)',
                        border: OutlineInputBorder(),
                      ),
                      items: const [1, 2, 3, 4, 5, 7, 10, 14]
                          .map(
                            (d) => DropdownMenuItem(
                              value: d,
                              child: Text('$d day${d == 1 ? '' : 's'}'),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _minimumIntervalDays = value);
                        _loadScheduleStats();
                      },
                    ),
                    const SizedBox(height: 12),
                    _buildScheduleStatsCard(context),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: workouts.isEmpty || isSaving ? null : () => _generateNewRoutine(
                        mseqBase: _mseqBase,
                        sequencePower: _sequencePower,
                        activeSymbols: _activeSymbols,
                        minimumIntervalDays: _minimumIntervalDays,
                      ),
                      icon: const Icon(Icons.bolt),
                      label: const Text('Generate New Routine'),
                    ),
                  ],
                ),
              ),
              if (workouts.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Add at least one workout before generating a schedule.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildWorkoutCard(int index) {
    final controllers = editControllers[index]!;
    final originalWorkout = workouts[index];

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 0),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: originalWorkout.atPark ? Colors.green : Colors.blue,
          child: Icon(
            originalWorkout.atPark ? Icons.park : Icons.home,
            color: Colors.white,
            size: 16,
          ),
        ),
        title: Text(
          originalWorkout.name,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        subtitle: Text(
          'Goal: ${originalWorkout.goal} ${originalWorkout.units}',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit, color: Colors.blueGrey),
              onPressed: isSaving ? null : () => _editMeta(index),
              tooltip: 'Rename / link exercise',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: isSaving ? null : () => _deleteWorkout(index),
              tooltip: 'Delete',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const Icon(Icons.expand_more),
          ],
        ),
        children: [
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
                    setState(() => controllers.atPark = value ?? false);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: isSaving ? null : () => _saveWorkout(index),
              icon: const Icon(Icons.save, size: 18),
              label: const Text('Save Changes'),
            ),
          ),
          const Divider(height: 24),
          _ManageHistoryLoader(workoutName: originalWorkout.name, workout: originalWorkout),
        ],
      ),
    );
  }

  Future<void> _loadScheduleStats() async {
    setState(() {
      _loadingScheduleStats = true;
      _scheduleStatsError = null;
    });
    try {
      final stats = await ApiService.getScheduleStats(
        sequencePower: _sequencePower,
        minimumIntervalDays: _minimumIntervalDays,
        mseqBase: _mseqBase,
        activeSymbols: _activeSymbols,
      );
      if (!mounted) return;
      setState(() {
        _scheduleStats = stats;
        _loadingScheduleStats = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingScheduleStats = false;
        _scheduleStatsError = '$e';
      });
    }
  }


  String _fmtRate(double value) {
    if (value <= 0) return '0/day';
    final everyDays = 1 / value;
    return '${value.toStringAsFixed(4)}/day (1 every ${everyDays.toStringAsFixed(1)} days)';
  }

  String _fmtRangeRate(Map<String, dynamic>? range) {
    if (range == null) return 'n/a';
    final min = (range['min'] as num?)?.toDouble();
    final max = (range['max'] as num?)?.toDouble();
    if (min == null || max == null) return 'n/a';
    return '${_fmtRate(min)} to ${_fmtRate(max)}';
  }

  Widget _buildScheduleStatsCard(BuildContext context) {
    if (_loadingScheduleStats) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_scheduleStatsError != null) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.red.shade200),
          borderRadius: BorderRadius.circular(8),
          color: Colors.red.shade50,
        ),
        child: Text(
          'Could not load live stats: $_scheduleStatsError',
          style: TextStyle(color: Colors.red.shade700, fontSize: 12),
        ),
      );
    }

    final stats = _scheduleStats;
    if (stats == null) return const SizedBox.shrink();
    final base = (stats['mseq_base'] as num?)?.toInt() ?? 5;
    final activeSymbols = (stats['active_symbols'] as num?)?.toInt() ?? _activeSymbols;
    final overallMean = (stats['overall_mean_workouts_per_day'] as num?)?.toDouble() ?? 0;
    final perWorkoutMean = (stats['per_workout_mean_workouts_per_day'] as num?)?.toDouble() ?? 0;
    final activeFraction = base > 0 ? (activeSymbols / base) : 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Density: $activeSymbols/$base symbols active (~${(activeFraction * 100).toStringAsFixed(0)}% of slots before min interval)',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text('Mean workout rate (overall): ${_fmtRate(overallMean)}'),
          Text(
            'Range (overall): ${_fmtRangeRate(stats['overall_workouts_per_day_range'] as Map<String, dynamic>?)}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text('Mean workout rate per workout: ${_fmtRate(perWorkoutMean)}'),
          Text(
            'Range (per workout): ${_fmtRangeRate(stats['per_workout_workouts_per_day_range'] as Map<String, dynamic>?)}',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
  Future<void> _generateNewRoutine({
    required int mseqBase,
    required int sequencePower,
    required int activeSymbols,
    required int minimumIntervalDays,
  }) async {
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
      await ApiService.generateNewRoutine(
        mseqBase: mseqBase,
        sequencePower: sequencePower,
        activeSymbols: activeSymbols,
        minimumIntervalDays: minimumIntervalDays,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Routine generated (base $mseqBase, power $sequencePower, density $activeSymbols/$mseqBase, min interval ${minimumIntervalDays}d).',
          ),
        ),
      );
      await loadWorkouts();
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/');
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error generating routine: $e')),
      );
    }
  }
}

class _ManageIntervalDistributionChart extends StatefulWidget {
  final String workoutName;

  const _ManageIntervalDistributionChart({required this.workoutName});

  @override
  State<_ManageIntervalDistributionChart> createState() => _ManageIntervalDistributionChartState();
}

class _ManageIntervalDistributionChartState extends State<_ManageIntervalDistributionChart> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _bins = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ApiService.getWorkoutIntervalDistribution(widget.workoutName);
      final bins = (data['bins'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _bins = bins;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_error != null) {
      return Text(
        'Could not load interval chart: $_error',
        style: TextStyle(fontSize: 12, color: Colors.red.shade700),
      );
    }

    if (_bins.isEmpty) {
      return const Text(
        'Interval distribution: not enough scheduled sessions yet.',
        style: TextStyle(fontSize: 12, color: Colors.black54),
      );
    }

    final maxY = _bins
        .map((b) => (b['count'] as num).toDouble())
        .reduce((a, b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Interval distribution (days between sessions)',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 160,
          child: BarChart(
            BarChartData(
              maxY: maxY + 1,
              gridData: const FlGridData(show: false),
              borderData: FlBorderData(show: false),
              barTouchData: BarTouchData(
                enabled: true,
                touchTooltipData: BarTouchTooltipData(
                  tooltipBorderRadius: BorderRadius.circular(6),
                  getTooltipItem: (group, groupIndex, rod, rodIndex) {
                    final bin = _bins[group.x.toInt()];
                    return BarTooltipItem(
                      '${bin['days']}d\n${(bin['count'] as num).toInt()}',
                      const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    );
                  },
                ),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: true, reservedSize: 28),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 26,
                    getTitlesWidget: (value, meta) {
                      final idx = value.toInt();
                      if (idx < 0 || idx >= _bins.length) return const SizedBox.shrink();
                      return Text('${_bins[idx]['days']}', style: const TextStyle(fontSize: 10));
                    },
                  ),
                ),
              ),
              barGroups: List.generate(_bins.length, (i) {
                final count = (_bins[i]['count'] as num).toDouble();
                return BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: count,
                      width: 12,
                      borderRadius: BorderRadius.circular(3),
                      color: Theme.of(context).colorScheme.primary,
                    )
                  ],
                );
              }),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Lazy history loader for manage screen ────────────────────────────────────

class _ManageHistoryLoader extends StatefulWidget {
  final String workoutName;
  final Workout workout;

  const _ManageHistoryLoader({required this.workoutName, required this.workout});

  @override
  State<_ManageHistoryLoader> createState() => _ManageHistoryLoaderState();
}

class _ManageHistoryLoaderState extends State<_ManageHistoryLoader> {
  List<Map<String, dynamic>>? _history;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ApiService.getWorkoutHistory(widget.workoutName, limit: 20);
      if (mounted) setState(() { _history = data; });
    } catch (_) {
      if (mounted) setState(() { _history = []; });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    // Always render the panel (it shows image + chart); if history is empty
    // the panel shows just the image and a "no entries" message.
    return WorkoutHistoryPanel(
      history: _history ?? [],
      units: widget.workout.units,
      goal: widget.workout.goal,
      exerciseId: widget.workout.exerciseId,
      sidePanel: _ManageIntervalDistributionChart(workoutName: widget.workoutName),
    );
  }
}

// ─── Edit controllers ─────────────────────────────────────────────────────────

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

// ─── Edit name + exercise link dialog ─────────────────────────────────────────

class EditWorkoutMetaDialog extends StatefulWidget {
  final String currentName;
  final String? currentExerciseId;

  const EditWorkoutMetaDialog({
    super.key,
    required this.currentName,
    required this.currentExerciseId,
  });

  @override
  State<EditWorkoutMetaDialog> createState() => _EditWorkoutMetaDialogState();
}

class _EditWorkoutMetaDialogState extends State<EditWorkoutMetaDialog> {
  late final TextEditingController _nameController;
  String? _exerciseId;
  String? _exerciseDisplayName;
  bool _exerciseIdProvided = false;

  List<Map<String, dynamic>> _suggestions = [];
  bool _loadingSuggestions = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentName);
    _exerciseId = widget.currentExerciseId;
    // Show current ID as display name until user searches
    _exerciseDisplayName = widget.currentExerciseId?.replaceAll('_', ' ');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _nameController.dispose();
    super.dispose();
  }

  void _onNameChanged(String value) {
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
    setState(() {
      _exerciseId = s['id'] as String;
      _exerciseDisplayName = s['name'] as String;
      _exerciseIdProvided = true;
      _suggestions = [];
    });
  }

  void _clearLink() {
    setState(() {
      _exerciseId = null;
      _exerciseDisplayName = null;
      _exerciseIdProvided = true;
    });
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name cannot be empty')),
      );
      return;
    }
    Navigator.of(context).pop((
      name: name,
      exerciseId: _exerciseId,
      exerciseIdProvided: _exerciseIdProvided,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Workout'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Workout Name',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              onChanged: _onNameChanged,
            ),
            if (_loadingSuggestions) const LinearProgressIndicator(minHeight: 2),
            if (_suggestions.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(4)),
                  color: Theme.of(context).colorScheme.surface,
                  boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))],
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(_suggestions.length, (i) {
                      final s = _suggestions[i];
                      final muscles = (s['primaryMuscles'] as List?)?.join(', ') ?? '';
                      return InkWell(
                        onTap: () => _selectSuggestion(s),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s['name'] as String, style: const TextStyle(fontSize: 13)),
                              if (muscles.isNotEmpty)
                                Text(muscles, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                            ],
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            // Exercise link status
            if (_exerciseId != null)
              Row(
                children: [
                  const Icon(Icons.link, color: Colors.green, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _exerciseDisplayName ?? _exerciseId!,
                      style: const TextStyle(fontSize: 13, color: Colors.green),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.link_off, size: 18, color: Colors.red),
                    tooltip: 'Remove exercise link',
                    onPressed: _clearLink,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              )
            else
              Text(
                'No exercise linked — search by name above to link one',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
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
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(_suggestions.length, (i) {
                      final s = _suggestions[i];
                      final name = (s['name'] as String?) ?? '';
                      final muscles =
                          (s['primaryMuscles'] as List?)?.join(', ') ?? '';
                      if (name.isEmpty) return const SizedBox.shrink();
                      return InkWell(
                        onTap: () => _selectSuggestion(s),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name,
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
                    }),
                  ),
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

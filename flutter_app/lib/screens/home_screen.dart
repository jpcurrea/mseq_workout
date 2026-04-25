import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/workout.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import 'login_screen.dart';

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
  DateTime? _selectedDate;

  @override
  void initState() {
    super.initState();
    loadWorkouts();
  }

  @override
  void dispose() {
    for (var controller in scoreControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> loadWorkouts() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      List<WorkoutScheduleItem> workouts = [];
      DateTime dateToUse = _selectedDate ?? DateTime.now();
      int lookback = 0;
      const int maxLookback = 30;
      while (lookback < maxLookback) {
        final dateStr = DateFormat('yyyy-MM-dd').format(dateToUse);
        workouts = await ApiService.getWorkoutsForDate(dateStr);
        if (workouts.isNotEmpty) {
          break;
        }
        dateToUse = dateToUse.subtract(const Duration(days: 1));
        lookback++;
      }
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
    final dateFormat = DateFormat('EEEE, MMMM d, y');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Today\'s Workout'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        leading: PopupMenuButton<String>(
          icon: const Icon(Icons.menu),
          onSelected: (String value) async {
            switch (value) {
              case 'generate_routine':
                _showGenerateRoutineDialog();
                break;
              case 'manage_workouts':
                Navigator.pushNamed(context, '/manage-workouts');
                break;
              case 'progress':
                Navigator.pushNamed(context, '/progress');
                break;
              case 'refresh':
                loadWorkouts();
                break;
              case 'logout':
                await AuthService.logout();
                if (context.mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                    (route) => false,
                  );
                }
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
              value: 'progress',
              child: ListTile(
                leading: Icon(Icons.show_chart),
                title: Text('Progress Charts'),
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
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'logout',
              child: ListTile(
                leading: Icon(Icons.logout),
                title: Text('Sign Out'),
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
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: Row(
              children: [
                if (_selectedDate != null)
                  TextButton(
                    onPressed: () {
                      setState(() { _selectedDate = null; });
                      loadWorkouts();
                    },
                    child: const Text('Today'),
                  )
                else
                  const SizedBox(width: 80),
                Expanded(
                  child: Text(
                    dateFormat.format(_selectedDate ?? DateTime.now()),
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.calendar_today),
                  onPressed: _pickDate,
                  tooltip: 'Change date',
                ),
              ],
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
              onPressed: loadWorkouts,
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
              _selectedDate == null ? 'No workouts scheduled for today!' : 'No workouts scheduled for this date.',
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
      onRefresh: loadWorkouts,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        itemCount: todayWorkouts.length,
        itemBuilder: (context, index) {
          final workout = todayWorkouts[index];
          final controller = scoreControllers[index]!;
          return _WorkoutCard(
            workout: workout,
            scoreController: controller,
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
      loadWorkouts(); // Refresh the workout list
    } catch (e) {
      Navigator.of(context).pop(); // Close progress dialog
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error generating routine: $e')),
      );
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() { _selectedDate = picked; });
      loadWorkouts();
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
        loadWorkouts(); // Refresh the data
      } else if (updatedCount > 0 && errors.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Updated $updatedCount scores. ${errors.length} errors occurred.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
        loadWorkouts(); // Refresh the data
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

// ─── Expandable workout card ────────────────────────────────────────────────

class _WorkoutCard extends StatefulWidget {
  final WorkoutScheduleItem workout;
  final TextEditingController scoreController;

  const _WorkoutCard({required this.workout, required this.scoreController});

  @override
  State<_WorkoutCard> createState() => _WorkoutCardState();
}

class _WorkoutCardState extends State<_WorkoutCard> {
  List<Map<String, dynamic>>? _history;
  bool _loading = false;

  Future<void> _loadHistory() async {
    if (_history != null) return; // already loaded
    setState(() => _loading = true);
    try {
      final data = await ApiService.getWorkoutHistory(widget.workout.workout);
      setState(() { _history = data; });
    } catch (_) {
      setState(() { _history = []; });
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final workout = widget.workout;
    final color = workout.atPark ? Colors.green : Colors.blue;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
      child: ExpansionTile(
        onExpansionChanged: (expanded) { if (expanded) _loadHistory(); },
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: color,
          child: Icon(
            workout.atPark ? Icons.park : Icons.home,
            color: Colors.white,
            size: 18,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                workout.workout,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 72,
              height: 32,
              child: TextField(
                controller: widget.scoreController,
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
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: [
              Text('Goal: ${workout.goal} ${workout.units}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
              if (workout.score != null) ...[
                const SizedBox(width: 8),
                Text(
                  '${workout.score} (${workout.progressPercentage.toStringAsFixed(0)}%)',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (workout.isCompleted)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(Icons.check_circle, color: Colors.green, size: 14),
                  ),
              ],
            ],
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : _history == null || _history!.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text('No scored entries yet.',
                            style: TextStyle(color: Colors.black45, fontSize: 13)),
                      )
                    : _HistoryPanel(history: _history!, units: workout.units, goal: workout.goal),
          ),
        ],
      ),
    );
  }
}

// ─── History panel: chart + table ───────────────────────────────────────────

class _HistoryPanel extends StatelessWidget {
  final List<Map<String, dynamic>> history;
  final String units;
  final double goal;

  const _HistoryPanel({required this.history, required this.units, required this.goal});

  @override
  Widget build(BuildContext context) {
    // Chart uses chronological order; table shows most-recent-first (history is desc from API)
    final chrono = history.reversed.toList();
    final recent = history.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        SizedBox(height: 150, child: _MiniLineChart(entries: chrono, goal: goal)),
        const SizedBox(height: 12),
        _RecentTable(entries: recent, units: units),
      ],
    );
  }
}

class _MiniLineChart extends StatelessWidget {
  final List<Map<String, dynamic>> entries;
  final double goal;

  const _MiniLineChart({required this.entries, required this.goal});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final axisColor = Colors.grey.shade400;
    final labelStyle = TextStyle(fontSize: 9, color: Colors.grey.shade600);

    final dated = entries.map((e) {
      final d = DateTime.parse(e['date'] as String);
      return (date: DateTime(d.year, d.month, d.day), score: (e['score'] as num).toDouble());
    }).toList();

    if (dated.isEmpty) return const SizedBox.shrink();

    final firstDate = dated.first.date;
    final todayDate = DateTime.now();
    final today = DateTime(todayDate.year, todayDate.month, todayDate.day);

    // X axis: day offset from firstDate; extends to today
    final maxX = today.difference(firstDate).inDays.toDouble().clamp(1.0, double.infinity);
    final spots = dated.map((e) =>
      FlSpot(e.date.difference(firstDate).inDays.toDouble(), e.score)
    ).toList();

    // ~4 intervals on each axis (5 ticks including 0 and max)
    final xInterval = (maxX / 4).ceilToDouble().clamp(1.0, double.infinity);
    final yInterval = (goal / 4).ceilToDouble().clamp(1.0, double.infinity);

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX,
        minY: 0,
        maxY: goal,
        clipData: const FlClipData.all(),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(
          show: true,
          border: Border(
            bottom: BorderSide(color: axisColor, width: 1),
            right: BorderSide(color: axisColor, width: 1),
            left: BorderSide.none,
            top: BorderSide.none,
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              interval: yInterval,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  value == value.truncateToDouble()
                      ? value.toInt().toString()
                      : value.toStringAsFixed(1),
                  style: labelStyle,
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 18,
              interval: xInterval,
              getTitlesWidget: (value, meta) {
                final d = firstDate.add(Duration(days: value.toInt()));
                return Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text('${d.month}/${d.day}', style: labelStyle),
                );
              },
            ),
          ),
        ),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            HorizontalLine(
              y: goal,
              color: Colors.orange.withOpacity(0.6),
              strokeWidth: 1,
              dashArray: [4, 4],
            ),
          ],
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: false,
            color: color,
            barWidth: 1.5,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                radius: 3,
                color: color,
                strokeWidth: 0,
              ),
            ),
            belowBarData: BarAreaData(
              show: true,
              color: color.withOpacity(0.08),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentTable extends StatelessWidget {
  final List<Map<String, dynamic>> entries;
  final String units;

  const _RecentTable({required this.entries, required this.units});

  @override
  Widget build(BuildContext context) {
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2),
        1: FlexColumnWidth(1),
      },
      children: [
        TableRow(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
          ),
          children: const [
            Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('Date', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
            Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('Score', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ],
        ),
        ...entries.map((e) => TableRow(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(e['date'] as String, style: const TextStyle(fontSize: 12)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text('${e['score']} $units', style: const TextStyle(fontSize: 12)),
            ),
          ],
        )),
      ],
    );
  }
}
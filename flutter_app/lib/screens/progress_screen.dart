import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';

// ─── Date range options ──────────────────────────────────────────────────────

enum _Range { week7, days30, all }

extension _RangeExt on _Range {
  String get label {
    switch (this) {
      case _Range.week7:
        return '7d';
      case _Range.days30:
        return '30d';
      case _Range.all:
        return 'All';
    }
  }

  String? get since {
    final now = DateTime.now();
    switch (this) {
      case _Range.week7:
        return DateFormat('yyyy-MM-dd').format(now.subtract(const Duration(days: 7)));
      case _Range.days30:
        return DateFormat('yyyy-MM-dd').format(now.subtract(const Duration(days: 30)));
      case _Range.all:
        return null;
    }
  }

  int get historyLimit {
    switch (this) {
      case _Range.week7:
        return 50;
      case _Range.days30:
        return 200;
      case _Range.all:
        return 2000;
    }
  }
}

// ─── Screen ──────────────────────────────────────────────────────────────────

class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key});

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  List<String> _workoutNames = [];
  String? _selectedWorkout;
  _Range _range = _Range.days30;

  // loaded data
  List<Map<String, dynamic>> _history = [];
  double _goal = 0;
  String _units = '';

  bool _loadingNames = true;
  bool _loadingHistory = false;
  String? _error;

  // For interactive tooltip
  int? _touchedIndex;

  @override
  void initState() {
    super.initState();
    _loadWorkoutNames();
  }

  Future<void> _loadWorkoutNames() async {
    try {
      final names = await ApiService.getWorkoutNames();
      setState(() {
        _workoutNames = names;
        _loadingNames = false;
        if (names.isNotEmpty) {
          _selectedWorkout = names.first;
        }
      });
      if (_selectedWorkout != null) _loadHistory();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loadingNames = false;
      });
    }
  }

  Future<void> _loadHistory() async {
    if (_selectedWorkout == null) return;
    setState(() {
      _loadingHistory = true;
      _error = null;
      _touchedIndex = null;
    });
    try {
      final data = await ApiService.getWorkoutHistory(
        _selectedWorkout!,
        limit: _range.historyLimit,
        since: _range.since,
      );
      // Also fetch workout metadata for goal/units
      final workouts = await ApiService.getWorkouts();
      final meta = workouts.firstWhere(
        (w) => w.name == _selectedWorkout,
        orElse: () => workouts.first,
      );
      setState(() {
        _history = data;
        _goal = meta.goal;
        _units = meta.units;
        _loadingHistory = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loadingHistory = false;
      });
    }
  }

  void _onRangeChanged(_Range r) {
    setState(() => _range = r);
    _loadHistory();
  }

  void _onWorkoutChanged(String? name) {
    if (name == null) return;
    setState(() => _selectedWorkout = name);
    _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Progress'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildControls(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.4),
      child: Row(
        children: [
          Expanded(
            child: _loadingNames
                ? const SizedBox(
                    height: 36,
                    child: Center(
                        child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))),
                  )
                : DropdownButtonFormField<String>(
                    value: _selectedWorkout,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    ),
                    items: _workoutNames
                        .map((n) => DropdownMenuItem(value: n, child: Text(n, overflow: TextOverflow.ellipsis)))
                        .toList(),
                    onChanged: _onWorkoutChanged,
                  ),
          ),
          const SizedBox(width: 8),
          _RangeSelector(selected: _range, onChanged: _onRangeChanged),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loadingNames || (_loadingHistory && _history.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),
              ElevatedButton(
                  onPressed: _loadHistory, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_history.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.show_chart,
                size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('No scored entries for this range.',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text('Submit some scores on the home screen first.',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
    }

    // history is newest-first from API; chart needs oldest-first
    final chrono = _history.reversed.toList();
    return Column(
      children: [
        if (_loadingHistory)
          const LinearProgressIndicator(minHeight: 2)
        else
          const SizedBox(height: 2),
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
            child: _ProgressChart(
              entries: chrono,
              goal: _goal,
              units: _units,
              touchedIndex: _touchedIndex,
              onTouch: (i) => setState(() => _touchedIndex = i),
            ),
          ),
        ),
        _buildSummaryRow(chrono),
        const Divider(height: 1),
        Expanded(
          flex: 2,
          child: _HistoryTable(
              entries: _history, // newest-first for table
              units: _units,
              goal: _goal),
        ),
      ],
    );
  }

  Widget _buildSummaryRow(List<Map<String, dynamic>> chrono) {
    if (chrono.isEmpty) return const SizedBox.shrink();
    final scores = chrono.map((e) => (e['score'] as num).toDouble()).toList();
    final best = scores.reduce((a, b) => a > b ? a : b);
    final avg = scores.reduce((a, b) => a + b) / scores.length;
    final latest = scores.last;
    final pct = _goal > 0 ? (latest / _goal * 100).toStringAsFixed(0) : '—';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _StatChip(label: 'Latest', value: '${_fmt(latest)} $_units'),
          _StatChip(label: 'Best', value: '${_fmt(best)} $_units'),
          _StatChip(label: 'Average', value: '${_fmt(avg)} $_units'),
          _StatChip(label: 'vs Goal', value: '$pct%'),
          _StatChip(label: 'Entries', value: '${chrono.length}'),
        ],
      ),
    );
  }

  String _fmt(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

// ─── Range selector ──────────────────────────────────────────────────────────

class _RangeSelector extends StatelessWidget {
  final _Range selected;
  final ValueChanged<_Range> onChanged;

  const _RangeSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_Range>(
      segments: _Range.values
          .map((r) => ButtonSegment(value: r, label: Text(r.label)))
          .toList(),
      selected: {selected},
      onSelectionChanged: (s) => onChanged(s.first),
      style: ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

// ─── Chart ───────────────────────────────────────────────────────────────────

class _ProgressChart extends StatelessWidget {
  final List<Map<String, dynamic>> entries; // oldest-first
  final double goal;
  final String units;
  final int? touchedIndex;
  final ValueChanged<int?> onTouch;

  const _ProgressChart({
    required this.entries,
    required this.goal,
    required this.units,
    required this.touchedIndex,
    required this.onTouch,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();

    final color = Theme.of(context).colorScheme.primary;
    final axisStyle =
        TextStyle(fontSize: 10, color: Colors.grey.shade600);

    final dated = entries.map((e) {
      final d = DateTime.parse(e['date'] as String);
      return (
        date: DateTime(d.year, d.month, d.day),
        score: (e['score'] as num).toDouble()
      );
    }).toList();

    final firstDate = dated.first.date;
    final today = () {
      final n = DateTime.now();
      return DateTime(n.year, n.month, n.day);
    }();
    final maxX =
        today.difference(firstDate).inDays.toDouble().clamp(1.0, double.infinity);

    final maxScore =
        dated.map((e) => e.score).reduce((a, b) => a > b ? a : b);
    final maxY = (maxScore > goal ? maxScore * 1.1 : goal).ceilToDouble();

    final spots = [
      for (int i = 0; i < dated.length; i++)
        FlSpot(
          dated[i].date.difference(firstDate).inDays.toDouble(),
          dated[i].score,
        )
    ];

    final xInterval = (maxX / 4).ceilToDouble().clamp(1.0, double.infinity);
    final yInterval = (maxY / 4).ceilToDouble().clamp(1.0, double.infinity);

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX,
        minY: 0,
        maxY: maxY,
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: Colors.grey.shade200, strokeWidth: 1),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border(
            bottom: BorderSide(color: Colors.grey.shade400, width: 1),
            left: BorderSide(color: Colors.grey.shade400, width: 1),
            right: BorderSide.none,
            top: BorderSide.none,
          ),
        ),
        titlesData: FlTitlesData(
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: yInterval,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  value == value.truncateToDouble()
                      ? value.toInt().toString()
                      : value.toStringAsFixed(1),
                  style: axisStyle,
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: xInterval,
              getTitlesWidget: (value, meta) {
                final d = firstDate.add(Duration(days: value.toInt()));
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${d.month}/${d.day}',
                    style: axisStyle,
                  ),
                );
              },
            ),
          ),
        ),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            HorizontalLine(
              y: goal,
              color: Colors.orange.withOpacity(0.7),
              strokeWidth: 1.5,
              dashArray: [5, 4],
              label: HorizontalLineLabel(
                show: true,
                alignment: Alignment.topRight,
                padding: const EdgeInsets.only(right: 4, bottom: 2),
                style: TextStyle(
                    fontSize: 10,
                    color: Colors.orange.shade700,
                    fontWeight: FontWeight.w600),
                labelResolver: (line) => 'Goal $goal $units',
              ),
            ),
          ],
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => spots.map((s) {
              final d = firstDate.add(Duration(days: s.x.toInt()));
              final dateStr = DateFormat('MMM d').format(d);
              final scoreStr = s.y == s.y.truncateToDouble()
                  ? s.y.toInt().toString()
                  : s.y.toStringAsFixed(1);
              return LineTooltipItem(
                '$dateStr\n$scoreStr $units',
                TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              );
            }).toList(),
          ),
          touchCallback: (event, response) {
            if (!event.isInterestedForInteractions ||
                response?.lineBarSpots == null) {
              onTouch(null);
            } else {
              onTouch(response!.lineBarSpots!.first.spotIndex);
            }
          },
          handleBuiltInTouches: true,
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.25,
            color: color,
            barWidth: 2,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) {
                final isActive = index == touchedIndex;
                return FlDotCirclePainter(
                  radius: isActive ? 6 : 4,
                  color: isActive ? Colors.white : color,
                  strokeColor: color,
                  strokeWidth: isActive ? 2.5 : 0,
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              color: color.withOpacity(0.10),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Summary chip ────────────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  final String label;
  final String value;

  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 10,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold)),
      ],
    );
  }
}

// ─── History table ───────────────────────────────────────────────────────────

class _HistoryTable extends StatelessWidget {
  final List<Map<String, dynamic>> entries; // newest-first
  final String units;
  final double goal;

  const _HistoryTable(
      {required this.entries, required this.units, required this.goal});

  @override
  Widget build(BuildContext context) {
    final pctStyle =
        TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.primary);
    final rowStyle = const TextStyle(fontSize: 12);
    final headerStyle =
        const TextStyle(fontWeight: FontWeight.bold, fontSize: 12);

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: entries.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .primaryContainer
                  .withOpacity(0.4),
              border: Border(
                  bottom: BorderSide(color: Colors.grey.shade300, width: 1)),
            ),
            child: Row(
              children: [
                Expanded(child: Text('Date', style: headerStyle)),
                SizedBox(
                    width: 80,
                    child: Text('Score', style: headerStyle, textAlign: TextAlign.right)),
                SizedBox(
                    width: 60,
                    child: Text('% Goal', style: headerStyle, textAlign: TextAlign.right)),
              ],
            ),
          );
        }
        final e = entries[i - 1];
        final score = (e['score'] as num).toDouble();
        final pct = goal > 0
            ? '${(score / goal * 100).toStringAsFixed(0)}%'
            : '—';
        final scoreStr = score == score.truncateToDouble()
            ? '${score.toInt()} $units'
            : '${score.toStringAsFixed(1)} $units';
        final isGoalMet = goal > 0 && score >= goal;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(color: Colors.grey.shade100, width: 1)),
          ),
          child: Row(
            children: [
              Expanded(
                  child: Text(e['date'] as String, style: rowStyle)),
              SizedBox(
                  width: 80,
                  child: Text(scoreStr,
                      style: rowStyle, textAlign: TextAlign.right)),
              SizedBox(
                  width: 60,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(pct, style: pctStyle),
                      if (isGoalMet) ...[
                        const SizedBox(width: 3),
                        const Icon(Icons.check_circle,
                            size: 12, color: Colors.green),
                      ],
                    ],
                  )),
            ],
          ),
        );
      },
    );
  }
}

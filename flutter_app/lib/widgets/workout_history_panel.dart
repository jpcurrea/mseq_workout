import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

// ─── History panel: exercise image + mini chart + recent scores ──────────────

class WorkoutHistoryPanel extends StatelessWidget {
  final List<Map<String, dynamic>> history; // newest-first from API
  final String units;
  final double goal;
  final String? exerciseId;

  const WorkoutHistoryPanel({
    super.key,
    required this.history,
    required this.units,
    required this.goal,
    this.exerciseId,
  });

  @override
  Widget build(BuildContext context) {
    final chrono = history.reversed.toList();
    final recent = history.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (exerciseId != null)
          WorkoutExerciseImage(exerciseId: exerciseId!)
        else
          const Text('(no exercise linked)', style: TextStyle(fontSize: 10, color: Colors.grey)),
        const SizedBox(height: 8),
        if (history.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4, bottom: 8),
            child: Text('No scored entries yet.',
                style: TextStyle(color: Colors.black45, fontSize: 13)),
          )
        else ...[
          SizedBox(height: 150, child: WorkoutMiniLineChart(entries: chrono, goal: goal)),
          const SizedBox(height: 12),
          WorkoutRecentTable(entries: recent, units: units),
        ],
      ],
    );
  }
}

// ─── Exercise reference image (animated: alternates between frame 0 and 1) ────

class WorkoutExerciseImage extends StatefulWidget {
  final String exerciseId;

  const WorkoutExerciseImage({super.key, required this.exerciseId});

  @override
  State<WorkoutExerciseImage> createState() => _WorkoutExerciseImageState();
}

class _WorkoutExerciseImageState extends State<WorkoutExerciseImage> {
  static const _base =
      'https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises';
  static const _height = 180.0;

  int _frame = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (mounted) setState(() => _frame = _frame == 0 ? 1 : 0);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _frame0Image() => Image.network(
        '$_base/${widget.exerciseId}/0.jpg',
        height: _height,
        width: double.infinity,
        fit: BoxFit.contain,
        loadingBuilder: (_, child, progress) => progress == null
            ? child
            : SizedBox(
                height: _height,
                child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
        errorBuilder: (_, __, ___) => Container(
          height: _height,
          color: Colors.grey.shade200,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.broken_image, color: Colors.grey),
              Text('No image: ${widget.exerciseId}',
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ]),
          ),
        ),
      );

  Widget _frame1Image() => Image.network(
        '$_base/${widget.exerciseId}/1.jpg',
        height: _height,
        width: double.infinity,
        fit: BoxFit.contain,
        // frame 1 missing is fine — frame 0 will stay visible underneath
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: _height,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Frame 0 — fades out when _frame == 1
            AnimatedOpacity(
              opacity: _frame == 0 ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: _frame0Image(),
            ),
            // Frame 1 — fades in when _frame == 1
            AnimatedOpacity(
              opacity: _frame == 1 ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: _frame1Image(),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Mini sparkline chart ─────────────────────────────────────────────────────

class WorkoutMiniLineChart extends StatelessWidget {
  final List<Map<String, dynamic>> entries; // oldest-first
  final double goal;

  const WorkoutMiniLineChart({super.key, required this.entries, required this.goal});

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
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final maxX = today.difference(firstDate).inDays.toDouble().clamp(1.0, double.infinity);
    final spots = dated
        .map((e) => FlSpot(e.date.difference(firstDate).inDays.toDouble(), e.score))
        .toList();

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
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touchSpots) => touchSpots.map((s) {
              final d = firstDate.add(Duration(days: s.x.toInt()));
              final dateStr = DateFormat('MMM d').format(d);
              final scoreStr = s.y == s.y.truncateToDouble()
                  ? s.y.toInt().toString()
                  : s.y.toStringAsFixed(1);
              return LineTooltipItem(
                '$dateStr\n$scoreStr',
                const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              );
            }).toList(),
          ),
          handleBuiltInTouches: true,
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: false,
            color: color,
            barWidth: 1.5,
            dotData: FlDotData(
              show: true,
              getDotPainter: (_, __, ___, ____) => FlDotCirclePainter(
                radius: 3,
                color: color,
                strokeWidth: 0,
              ),
            ),
            belowBarData: BarAreaData(show: true, color: color.withOpacity(0.08)),
          ),
        ],
      ),
    );
  }
}

// ─── Recent scores table ──────────────────────────────────────────────────────

class WorkoutRecentTable extends StatelessWidget {
  final List<Map<String, dynamic>> entries;
  final String units;

  const WorkoutRecentTable({super.key, required this.entries, required this.units});

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
              child: Text('Date',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
            Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('Score',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ],
        ),
        ...entries.map((e) => TableRow(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(e['date'] as String,
                      style: const TextStyle(fontSize: 12)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text('${e['score']} $units',
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            )),
      ],
    );
  }
}

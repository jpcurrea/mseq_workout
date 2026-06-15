import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/project.dart';
import '../services/project_api_service.dart';
import '../services/task_api_service.dart';
import '../services/csv_download.dart';

/// Shows the chronological record of every task completion in the active
/// project, with an option to export the record as a CSV file.
class TaskCompletionsScreen extends StatefulWidget {
  const TaskCompletionsScreen({super.key});

  @override
  State<TaskCompletionsScreen> createState() => _TaskCompletionsScreenState();
}

class _TaskCompletionsScreenState extends State<TaskCompletionsScreen> {
  Project? _project;
  List<Map<String, dynamic>> _rows = [];
  bool _isLoading = true;
  bool _isExporting = false;
  String? _error;

  final _dateFmt = DateFormat('MMM d, y · h:mm a');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final project = await ProjectApiService.getActiveProject();
      final rows = await TaskApiService.getCompletions(projectId: project.id);
      setState(() {
        _project = project;
        _rows = rows;
        _isLoading = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  Future<void> _export() async {
    if (_project == null || _isExporting) return;
    setState(() => _isExporting = true);
    try {
      final csv = await TaskApiService.exportCompletionsCsv(projectId: _project!.id);
      final filename = 'task_completions_${_project!.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.csv';
      final downloaded = await downloadCsv(filename, csv);
      if (!mounted) return;
      if (downloaded) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported $filename')),
        );
      } else {
        await Clipboard.setData(ClipboardData(text: csv));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('CSV copied to clipboard (download unsupported here)')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  String _fmtDate(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso);
    return dt == null ? iso : _dateFmt.format(dt.toLocal());
  }

  String _fmtMinutes(num? minutes) {
    if (minutes == null) return '—';
    final m = minutes.round();
    if (m < 60) return '${m}m';
    final h = m ~/ 60;
    final rem = m % 60;
    return rem == 0 ? '${h}h' : '${h}h ${rem}m';
  }

  Widget _latenessChip(num? lateness) {
    if (lateness == null) return const SizedBox.shrink();
    final late = lateness > 0;
    final mins = lateness.abs().round();
    final label = late ? 'Late ${_fmtMinutes(mins)}' : 'On time';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: late ? Colors.red[50] : Colors.green[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: late ? Colors.red[200]! : Colors.green[300]!),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: late ? Colors.red[700] : Colors.green[700],
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Completion History'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          IconButton(
            icon: _isExporting
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined),
            tooltip: 'Export CSV',
            onPressed: _rows.isEmpty ? null : _export,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_rows.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('No completed tasks recorded yet', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _rows.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final r = _rows[i];
          final tags = (r['tags'] as String?)?.trim();
          final skipped = (r['status']?.toString() ?? 'completed') == 'skipped';
          return ListTile(
            leading: Icon(
              skipped ? Icons.skip_next : Icons.check_circle,
              color: skipped ? Colors.orange : Colors.green,
            ),
            title: Row(
              children: [
                Flexible(child: Text(r['title']?.toString() ?? 'Untitled')),
                if (skipped)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.orange[50],
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.orange[200]!),
                      ),
                      child: Text(
                        'Skipped',
                        style: TextStyle(fontSize: 10, color: Colors.orange[800], fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_fmtDate(r['completed_at'] as String?)),
                const SizedBox(height: 2),
                Text(
                  'Est ${_fmtMinutes(r['estimated_minutes'] as num?)} · '
                  'Actual ${_fmtMinutes(r['actual_minutes'] as num?)}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                if (tags != null && tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(tags, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                  ),
              ],
            ),
            trailing: skipped ? null : _latenessChip(r['lateness_minutes'] as num?),
            isThreeLine: true,
          );
        },
      ),
    );
  }
}

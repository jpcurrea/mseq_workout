import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/task.dart';
import '../services/task_api_service.dart';

/// Full-screen form for creating or editing a task.
/// Returns `true` via Navigator.pop if the task was saved.
class TaskFormScreen extends StatefulWidget {
  final Task? editTask;
  final int? projectId;

  const TaskFormScreen({super.key, this.editTask, this.projectId});

  @override
  State<TaskFormScreen> createState() => _TaskFormScreenState();
}

class _TaskFormScreenState extends State<TaskFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _durationCtrl;

  DateTime? _dueDate;
  bool _isRecurring = false;
  String? _recurrenceRule;
  List<Tag> _allTags = [];
  Set<int> _selectedTagIds = {};
  List<Task> _allTasks = [];
  int? _parentTaskId;
  bool _isSaving = false;

  bool get _isEditing => widget.editTask != null;

  @override
  void initState() {
    super.initState();
    final t = widget.editTask;
    _titleCtrl = TextEditingController(text: t?.title ?? '');
    _descCtrl = TextEditingController(text: t?.description ?? '');
    _durationCtrl = TextEditingController(
        text: t?.durationMinutes != null ? t!.durationMinutes.toString() : '');
    _dueDate = t?.dueDate;
    _isRecurring = t?.isRecurring ?? false;
    _recurrenceRule = t?.recurrenceRule;
    _selectedTagIds = Set.from(t?.tags.map((tag) => tag.id) ?? []);
    _parentTaskId = t?.parentTaskId;
    _loadData();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _durationCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final projectId = widget.projectId ?? widget.editTask?.projectId;
    try {
      final results = await Future.wait([
        projectId != null
            ? TaskApiService.getTags(projectId: projectId)
            : Future.value(<Tag>[]),
        projectId != null
            ? TaskApiService.getTasks(projectId: projectId)
            : Future.value(<Task>[]),
      ]);
      setState(() {
        _allTags = results[0] as List<Tag>;
        _allTasks = (results[1] as List<Task>)
            .where((t) => t.id != widget.editTask?.id)
            .toList();
      });
    } catch (_) {}
  }

  Future<void> _pickDueDate() async {
    final picked = await showDateTimePicker(context, initial: _dueDate ?? DateTime.now());
    if (picked != null) setState(() => _dueDate = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    final durationMin = int.tryParse(_durationCtrl.text.trim());
    final dueDateStr = _dueDate?.toIso8601String();

    try {
      if (_isEditing) {
        await TaskApiService.updateTask(
          widget.editTask!.id,
          title: _titleCtrl.text.trim(),
          description: _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
          dueDate: dueDateStr,
          durationMinutes: durationMin,
          parentTaskId: _parentTaskId,
          isRecurring: _isRecurring,
          recurrenceRule: _isRecurring ? _recurrenceRule : null,
          tagIds: _selectedTagIds.toList(),
        );
      } else {
        final projectId = widget.projectId ?? widget.editTask?.projectId;
        if (projectId == null) throw Exception('No project selected');
        await TaskApiService.createTask(
          projectId: projectId,
          title: _titleCtrl.text.trim(),
          description: _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
          dueDate: dueDateStr,
          durationMinutes: durationMin,
          parentTaskId: _parentTaskId,
          isRecurring: _isRecurring,
          recurrenceRule: _isRecurring ? _recurrenceRule : null,
          tagIds: _selectedTagIds.toList(),
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _createNewTag() async {
    final nameCtrl = TextEditingController();
    Color selectedColor = const Color(0xFF6366f1);

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Tag'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Tag name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create')),
        ],
      ),
    );
    if (ok != true || nameCtrl.text.trim().isEmpty) return;

    try {
      final tag = await TaskApiService.createTag(
        nameCtrl.text.trim(),
        color: '#${selectedColor.value.toRadixString(16).substring(2)}',
      );
      setState(() {
        _allTags.add(tag);
        _selectedTagIds.add(tag.id);
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Task' : 'New Task'),
        actions: [
          _isSaving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : TextButton(
                  onPressed: _save,
                  child: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Title
            TextFormField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Title *',
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Title is required' : null,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),

            // Description
            TextFormField(
              controller: _descCtrl,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),

            // Due date + duration row
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.event),
                    label: Text(_dueDate != null
                        ? DateFormat('MMM d, y HH:mm').format(_dueDate!)
                        : 'Set due date'),
                    onPressed: _pickDueDate,
                  ),
                ),
                const SizedBox(width: 8),
                if (_dueDate != null)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () => setState(() => _dueDate = null),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            TextFormField(
              controller: _durationCtrl,
              decoration: const InputDecoration(
                labelText: 'Estimated duration (minutes)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.timer_outlined),
              ),
              keyboardType: TextInputType.number,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null;
                if (int.tryParse(v.trim()) == null) return 'Enter a number';
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Tags
            Text('Tags', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ..._allTags.map((tag) => FilterChip(
                  label: Text(tag.name),
                  selected: _selectedTagIds.contains(tag.id),
                  selectedColor: tag.flutterColor.withOpacity(0.25),
                  onSelected: (sel) => setState(() {
                    if (sel) _selectedTagIds.add(tag.id);
                    else _selectedTagIds.remove(tag.id);
                  }),
                )),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: const Text('New tag'),
                  onPressed: _createNewTag,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Parent task
            if (_allTasks.isNotEmpty) ...[
              Text('Parent task (optional)', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              DropdownButtonFormField<int?>(
                value: _parentTaskId,
                decoration: const InputDecoration(border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem(value: null, child: Text('None (top-level)')),
                  ..._allTasks.map((t) => DropdownMenuItem(value: t.id, child: Text(t.title))),
                ],
                onChanged: (v) => setState(() => _parentTaskId = v),
              ),
              const SizedBox(height: 16),
            ],

            // Recurring
            SwitchListTile(
              title: const Text('Recurring task'),
              value: _isRecurring,
              onChanged: (v) => setState(() => _isRecurring = v),
            ),
            if (_isRecurring) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _recurrenceRule,
                decoration: const InputDecoration(
                  labelText: 'Repeat',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'DAILY', child: Text('Daily')),
                  DropdownMenuItem(value: 'WEEKLY', child: Text('Weekly')),
                  DropdownMenuItem(value: 'MONTHLY', child: Text('Monthly')),
                ],
                onChanged: (v) => setState(() => _recurrenceRule = v),
                validator: (v) => (_isRecurring && v == null) ? 'Select a frequency' : null,
              ),
            ],
            const SizedBox(height: 80), // FAB clearance
          ],
        ),
      ),
    );
  }
}

// ── Helper: date+time picker ──────────────────────────────────────────────────

Future<DateTime?> showDateTimePicker(BuildContext context, {DateTime? initial}) async {
  final date = await showDatePicker(
    context: context,
    initialDate: initial ?? DateTime.now(),
    firstDate: DateTime(2020),
    lastDate: DateTime(2040),
  );
  if (date == null) return null;
  if (!context.mounted) return date;

  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial ?? DateTime.now()),
  );
  if (time == null) return date;

  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

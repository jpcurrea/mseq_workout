import 'package:flutter/material.dart';
import '../services/agent_api_service.dart';

/// Manages the user's agent routines — reusable, named sets of steps the AI
/// agent can follow. Built-in routines are shown read-only; the user can add,
/// edit and delete their own (and see any the agent has saved).
class AgentRoutinesScreen extends StatefulWidget {
  /// When provided, project-scoped routines for this project are shown
  /// alongside global ones, and new routines can be scoped to it.
  final int? projectId;
  final String? projectName;

  const AgentRoutinesScreen({super.key, this.projectId, this.projectName});

  @override
  State<AgentRoutinesScreen> createState() => _AgentRoutinesScreenState();
}

class _AgentRoutinesScreenState extends State<AgentRoutinesScreen> {
  List<AgentRoutine> _routines = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final routines = await AgentApiService.listRoutines(projectId: widget.projectId);
      if (!mounted) return;
      setState(() {
        _routines = routines;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _edit({AgentRoutine? existing}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _RoutineEditor(
          existing: existing,
          projectId: widget.projectId,
          projectName: widget.projectName,
        ),
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _delete(AgentRoutine routine) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Delete routine?'),
        content: Text('Delete "${routine.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AgentApiService.deleteRoutine(routine.id);
      _load();
    } catch (e) {
      if (mounted) _showError(e.toString());
    }
  }

  void _showError(String message) {
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Error'),
        content: SelectableText(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent Routines'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
              : _routines.isEmpty
                  ? const Center(
                      child: Text('No routines yet — tap + to create one',
                          style: TextStyle(color: Colors.grey)),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: _routines.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (_, i) => _routineCard(_routines[i]),
                    ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(),
        tooltip: 'New routine',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _routineCard(AgentRoutine r) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ExpansionTile(
        leading: Icon(
          r.isSystem
              ? Icons.auto_awesome
              : (r.createdBy == 'agent' ? Icons.smart_toy_outlined : Icons.playlist_add_check),
          color: scheme.primary,
        ),
        title: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Row(
          children: [
            _chip(r.scope == 'project' ? 'Project' : 'Global',
                scheme.secondaryContainer, scheme.onSecondaryContainer),
            const SizedBox(width: 6),
            if (r.isSystem)
              _chip('Built-in', scheme.tertiaryContainer, scheme.onTertiaryContainer)
            else if (r.createdBy == 'agent')
              _chip('By agent', scheme.primaryContainer, scheme.onPrimaryContainer),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (r.whenToUse != null && r.whenToUse!.trim().isNotEmpty) ...[
            const Text('When to use', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 2),
            Text(r.whenToUse!, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 10),
          ],
          if (r.description != null && r.description!.trim().isNotEmpty) ...[
            Text(r.description!, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 10),
          ],
          const Text('Steps', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 2),
          SelectableText(r.steps, style: const TextStyle(fontSize: 13, height: 1.35)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (r.isSystem)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('Read-only', style: TextStyle(color: Colors.grey, fontSize: 12)),
                )
              else ...[
                TextButton.icon(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit'),
                  onPressed: () => _edit(existing: r),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                  label: const Text('Delete', style: TextStyle(color: Colors.red)),
                  onPressed: () => _delete(r),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w500)),
    );
  }
}

class _RoutineEditor extends StatefulWidget {
  final AgentRoutine? existing;
  final int? projectId;
  final String? projectName;

  const _RoutineEditor({this.existing, this.projectId, this.projectName});

  @override
  State<_RoutineEditor> createState() => _RoutineEditorState();
}

class _RoutineEditorState extends State<_RoutineEditor> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _whenCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _stepsCtrl;
  late bool _projectScoped;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _whenCtrl = TextEditingController(text: e?.whenToUse ?? '');
    _descCtrl = TextEditingController(text: e?.description ?? '');
    _stepsCtrl = TextEditingController(text: e?.steps ?? '');
    _projectScoped = e != null ? e.scope == 'project' : false;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _whenCtrl.dispose();
    _descCtrl.dispose();
    _stepsCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final steps = _stepsCtrl.text.trim();
    if (name.isEmpty || steps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and steps are required')),
      );
      return;
    }
    setState(() => _saving = true);
    final desc = _descCtrl.text.trim();
    final when = _whenCtrl.text.trim();
    final scope = _projectScoped && widget.projectId != null ? 'project' : 'global';
    try {
      if (widget.existing == null) {
        await AgentApiService.createRoutine(
          name: name,
          steps: steps,
          description: desc.isEmpty ? null : desc,
          whenToUse: when.isEmpty ? null : when,
          projectId: scope == 'project' ? widget.projectId : null,
        );
      } else {
        await AgentApiService.updateRoutine(
          widget.existing!.id,
          name: name,
          steps: steps,
          description: desc,
          whenToUse: when,
          scope: scope,
          projectId: scope == 'project' ? widget.projectId : null,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isEditing ? 'Edit routine' : 'New routine',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameCtrl,
            maxLength: 100,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. Weekly cleanup',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _whenCtrl,
            maxLength: 2000,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'When to use (optional)',
              hintText: 'Describe when the agent should pick this routine',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _descCtrl,
            maxLength: 2000,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _stepsCtrl,
            maxLength: 8000,
            maxLines: 8,
            minLines: 4,
            decoration: const InputDecoration(
              labelText: 'Steps',
              hintText: '1. Do this\n2. Then that',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 4),
          if (widget.projectId != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _projectScoped,
              onChanged: (v) => setState(() => _projectScoped = v),
              title: const Text('Limit to this project'),
              subtitle: Text(
                _projectScoped
                    ? 'Only available in ${widget.projectName ?? 'this project'}'
                    : 'Available across all your projects',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _saving ? null : () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

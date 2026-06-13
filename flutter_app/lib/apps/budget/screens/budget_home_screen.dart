import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/budget_api_service.dart';

class BudgetHomeScreen extends StatefulWidget {
  const BudgetHomeScreen({super.key});

  @override
  State<BudgetHomeScreen> createState() => _BudgetHomeScreenState();
}

class _BudgetHomeScreenState extends State<BudgetHomeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _goals = [];
  bool _isLoading = true;
  String? _error;
  final _currency = NumberFormat.currency(symbol: '\$');

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final results = await Future.wait([
        BudgetApiService.getSummary(),
        BudgetApiService.getAccounts(),
        BudgetApiService.getGoals(),
      ]);
      setState(() {
        _summary = results[0] as Map<String, dynamic>;
        _accounts = results[1] as List<Map<String, dynamic>>;
        _goals = results[2] as List<Map<String, dynamic>>;
        _isLoading = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Budget'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pushReplacementNamed('/hub'),
        ),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(icon: Icon(Icons.account_balance), text: 'Accounts'),
            Tab(icon: Icon(Icons.flag_outlined), text: 'Goals'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                    ElevatedButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ))
              : Column(
                  children: [
                    _SpendableNowCard(summary: _summary!, currency: _currency),
                    Expanded(
                      child: TabBarView(
                        controller: _tabCtrl,
                        children: [
                          _AccountsTab(
                            accounts: _accounts,
                            currency: _currency,
                            onRefresh: _load,
                            showError: _showError,
                          ),
                          _GoalsTab(
                            goals: _goals,
                            currency: _currency,
                            onRefresh: _load,
                            showError: _showError,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}

// ── Spendable Now card ────────────────────────────────────────────────────────

class _SpendableNowCard extends StatelessWidget {
  final Map<String, dynamic> summary;
  final NumberFormat currency;

  const _SpendableNowCard({required this.summary, required this.currency});

  @override
  Widget build(BuildContext context) {
    final spendable = (summary['spendable_now'] as num?)?.toDouble() ?? 0;
    final balance = (summary['total_balance'] as num?)?.toDouble() ?? 0;
    final needed = (summary['total_needed_by_goals'] as num?)?.toDouble() ?? 0;
    final isPositive = spendable >= 0;

    return Card(
      margin: const EdgeInsets.all(16),
      color: isPositive ? const Color(0xFF2E7D6B) : Colors.red[700],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              'Spendable Now',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(
              currency.format(spendable),
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _SummaryPill(label: 'Balance', value: currency.format(balance)),
                _SummaryPill(label: 'Reserved', value: currency.format(needed)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryPill extends StatelessWidget {
  final String label;
  final String value;
  const _SummaryPill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12)),
        Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ── Accounts tab ──────────────────────────────────────────────────────────────

class _AccountsTab extends StatelessWidget {
  final List<Map<String, dynamic>> accounts;
  final NumberFormat currency;
  final VoidCallback onRefresh;
  final void Function(String) showError;

  const _AccountsTab({
    required this.accounts,
    required this.currency,
    required this.onRefresh,
    required this.showError,
  });

  Future<void> _addAccount(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final balCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add Account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Account name')),
            const SizedBox(height: 8),
            TextField(
              controller: balCtrl,
              decoration: const InputDecoration(labelText: 'Current balance', prefixText: '\$'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true) return;
    final balance = double.tryParse(balCtrl.text.trim()) ?? 0.0;
    try {
      await BudgetApiService.createAccount(nameCtrl.text.trim(), balance);
      onRefresh();
    } catch (e) {
      showError(e.toString());
    }
  }

  Future<void> _editBalance(BuildContext context, Map<String, dynamic> account) async {
    final ctrl = TextEditingController(text: account['balance'].toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Update ${account['name']}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'New balance', prefixText: '\$'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final balance = double.tryParse(ctrl.text.trim());
    if (balance == null) return;
    try {
      await BudgetApiService.updateAccount(account['id'], balance: balance);
      onRefresh();
    } catch (e) {
      showError(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: accounts.isEmpty
          ? const Center(child: Text('No accounts yet', style: TextStyle(color: Colors.grey)))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: accounts.length,
              itemBuilder: (_, i) {
                final a = accounts[i];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.account_balance_outlined),
                    title: Text(a['name'] as String),
                    subtitle: Text(
                      currency.format(a['balance']),
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _editBalance(context, a),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                          onPressed: () async {
                            try {
                              await BudgetApiService.deleteAccount(a['id']);
                              onRefresh();
                            } catch (e) {
                              showError(e.toString());
                            }
                          },
                        ),
                      ],
                    ),
                    onTap: () => _editBalance(context, a),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addAccount(context),
        tooltip: 'Add account',
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ── Goals tab ─────────────────────────────────────────────────────────────────

class _GoalsTab extends StatelessWidget {
  final List<Map<String, dynamic>> goals;
  final NumberFormat currency;
  final VoidCallback onRefresh;
  final void Function(String) showError;

  const _GoalsTab({
    required this.goals,
    required this.currency,
    required this.onRefresh,
    required this.showError,
  });

  Future<void> _addGoal(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final targetCtrl = TextEditingController();
    final savedCtrl = TextEditingController(text: '0');
    DateTime? targetDate;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, setState) => AlertDialog(
          title: const Text('Add Goal'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Goal name')),
              const SizedBox(height: 8),
              TextField(
                controller: targetCtrl,
                decoration: const InputDecoration(labelText: 'Target amount', prefixText: '\$'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: savedCtrl,
                decoration: const InputDecoration(labelText: 'Already saved', prefixText: '\$'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.event),
                label: Text(targetDate != null
                    ? DateFormat('MMM d, y').format(targetDate!)
                    : 'Set target date (optional)'),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: DateTime.now().add(const Duration(days: 30)),
                    firstDate: DateTime.now(),
                    lastDate: DateTime(2040),
                  );
                  if (picked != null) setState(() => targetDate = picked);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await BudgetApiService.createGoal(
        nameCtrl.text.trim(),
        double.tryParse(targetCtrl.text.trim()) ?? 0.0,
        targetDate: targetDate != null ? DateFormat('yyyy-MM-dd').format(targetDate!) : null,
        currentSaved: double.tryParse(savedCtrl.text.trim()) ?? 0.0,
      );
      onRefresh();
    } catch (e) {
      showError(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: goals.isEmpty
          ? const Center(child: Text('No goals yet', style: TextStyle(color: Colors.grey)))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: goals.length,
              itemBuilder: (_, i) {
                final g = goals[i];
                final target = (g['target_amount'] as num).toDouble();
                final saved = (g['current_saved'] as num).toDouble();
                final still = (g['still_needed'] as num).toDouble();
                final progress = target > 0 ? (saved / target).clamp(0.0, 1.0) : 0.0;
                final dateStr = g['target_date'] as String?;

                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                g['name'] as String,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                              onPressed: () async {
                                try {
                                  await BudgetApiService.deleteGoal(g['id']);
                                  onRefresh();
                                } catch (e) {
                                  showError(e.toString());
                                }
                              },
                            ),
                          ],
                        ),
                        if (dateStr != null)
                          Text(
                            'By ${DateFormat('MMM d, y').format(DateTime.parse(dateStr))}',
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 8,
                            backgroundColor: Colors.grey[200],
                            color: progress >= 1.0 ? Colors.green : const Color(0xFF7C5CBF),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('${currency.format(saved)} saved', style: const TextStyle(fontSize: 12)),
                            Text('${currency.format(still)} to go',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: still > 0 ? Colors.orange[700] : Colors.green,
                                  fontWeight: FontWeight.w600,
                                )),
                            Text('Goal: ${currency.format(target)}', style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addGoal(context),
        tooltip: 'Add goal',
        child: const Icon(Icons.add),
      ),
    );
  }
}

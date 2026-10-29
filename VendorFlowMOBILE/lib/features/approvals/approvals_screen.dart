import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';

/// Approval inbox for one tab: pending | approved | rejected.
final approvalsProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, tab) async =>
    Map<String, dynamic>.from(await ref.watch(apiProvider).get('/approvals', query: {'tab': tab, 'pageSize': 50}) as Map));

class ApprovalsScreen extends ConsumerStatefulWidget {
  const ApprovalsScreen({super.key});

  @override
  ConsumerState<ApprovalsScreen> createState() => _ApprovalsScreenState();
}

class _ApprovalsScreenState extends ConsumerState<ApprovalsScreen> {
  String _tab = 'pending';
  String? _busyId;

  // Approves straight from the list. The row version stops a double tap from approving twice.
  Future<void> _approve(Map<String, dynamic> item) async {
    setState(() => _busyId = item['id'] as String);
    try {
      await ref.read(apiProvider).post('/approvals/${item['id']}/approve', body: {'expectedVersion': item['rowVersion']});
      if (mounted) showMessage(context, 'Approved');
    } catch (e) {
      if (mounted) showMessage(context, apiMessage(e));
    }
    if (mounted) setState(() => _busyId = null);
    ref.invalidate(approvalsProvider);
  }

  Future<void> _reject(Map<String, dynamic> item) async {
    final comment = await askComment(context, 'Reject request');
    if (comment == null) return;
    try {
      await ref.read(apiProvider).post('/approvals/${item['id']}/reject', body: {'comment': comment, 'expectedVersion': item['rowVersion']});
      if (mounted) showMessage(context, 'Rejected');
    } catch (e) {
      if (mounted) showMessage(context, apiMessage(e));
    }
    ref.invalidate(approvalsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(approvalsProvider(_tab));
    final counts = data.value?['counts'] as Map? ?? {};
    return Scaffold(
      backgroundColor: Brand.background,
      appBar: ScreenHeader('Approvals', subtitle: '${counts['pending'] ?? 0} waiting for you'),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Row(children: [
            for (final t in const ['pending', 'approved', 'rejected'])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(label: Text('${t[0].toUpperCase()}${t.substring(1)} ${counts[t] ?? ''}'.trim()), selected: _tab == t, onSelected: (_) => setState(() => _tab = t)),
              ),
          ]),
        ),
        Expanded(
          child: data.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(apiMessage(e), onRetry: () => ref.invalidate(approvalsProvider)),
            data: (page) {
              final items = List<Map<String, dynamic>>.from((page['items'] as List).map((e) => Map<String, dynamic>.from(e as Map)));
              if (items.isEmpty) return const EmptyView('Nothing here.', icon: Icons.task_alt);
              return RefreshIndicator(
                onRefresh: () async => ref.invalidate(approvalsProvider),
                child: ListView.builder(
                  padding: const EdgeInsets.all(14),
                  itemCount: items.length,
                  itemBuilder: (_, i) => _ApprovalCard(
                    item: items[i], showActions: _tab == 'pending' && (ref.read(authProvider).value?.has('approvals.decide') ?? false),
                    busy: _busyId == items[i]['id'], onApprove: () => _approve(items[i]), onReject: () => _reject(items[i]),
                  ),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.item, required this.showActions, required this.busy, required this.onApprove, required this.onReject});

  final Map<String, dynamic> item;
  final bool showActions;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) => AppCard(
        onTap: () => context.push('/approvals/${item['id']}', extra: item),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(item['title'] as String, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            Text(money(item['amount'] as num), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 2),
          Text('${item['requestedByName']} · ${item['departmentName'] ?? statusText(item['entityType'] as String?)} · ${item['waitingDays']}d', style: const TextStyle(color: Brand.muted)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            StatusChip(item['priority'] as String?),
            StatusChip('Open', label: 'Step ${item['currentStep']} of ${item['totalSteps']}'),
          ]),
          if (showActions) ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: FilledButton(style: FilledButton.styleFrom(backgroundColor: const Color(0xFF12A05C)), onPressed: busy ? null : onApprove, child: const Text('Approve'))),
              const SizedBox(width: 10),
              Expanded(child: OutlinedButton(style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFDC2D4A)), onPressed: onReject, child: const Text('Reject'))),
            ]),
          ],
        ]),
      );
}

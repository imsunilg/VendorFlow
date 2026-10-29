import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';

/// Counts for the home screen cards (pending approvals, open POs, overdue invoices, expiring documents).
final summaryProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async =>
    Map<String, dynamic>.from(await ref.watch(apiProvider).get('/dashboard/summary') as Map));

/// The first approvals waiting for the user.
final topApprovalsProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async {
  final user = ref.watch(authProvider).value;
  if (user == null || !user.has('approvals.view')) return [];
  final page = await ref.watch(apiProvider).get('/approvals', query: {'tab': 'pending', 'pageSize': 3}) as Map;
  return List<dynamic>.from(page['items'] as List);
});

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).value!;
    final labels = ref.watch(labelsProvider);
    final summary = ref.watch(summaryProvider);
    final approvals = ref.watch(topApprovalsProvider);

    return Scaffold(
      backgroundColor: Brand.background,
      appBar: ScreenHeader('Good morning, ${user.firstName}', subtitle: labels.organization),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(summaryProvider);
          ref.invalidate(topApprovalsProvider);
        },
        child: ListView(padding: const EdgeInsets.all(14), children: [
          summary.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(apiMessage(e), onRetry: () => ref.invalidate(summaryProvider)),
            data: (s) => GridView.count(
              crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), childAspectRatio: 1.75, mainAxisSpacing: 10, crossAxisSpacing: 10,
              children: [
                _Kpi('Pending approvals', '${s['pendingApprovals'] ?? 0}', const Color(0xFFD98A06), onTap: () => context.go('/approvals')),
                if (s['openPoAmount'] != null) _Kpi('Open POs', shortMoney(s['openPoAmount'] as num), Brand.navy, onTap: () => context.push('/purchase-orders')),
                if (s['overdueInvoices'] != null) _Kpi('Overdue invoices', '${s['overdueInvoices']}', const Color(0xFFDC2D4A), onTap: () => context.push('/finance')),
                if (s['expiringDocuments'] != null) _Kpi('Docs expiring', '${s['expiringDocuments']}', const Color(0xFFD98A06), onTap: () => context.push('/vendors')),
              ],
            ),
          ),
          const SizedBox(height: 14),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Needs your action', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              approvals.when(
                loading: () => const LoadingView(),
                error: (e, _) => Text(apiMessage(e)),
                data: (items) => items.isEmpty
                    ? const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('You are all caught up.', style: TextStyle(color: Brand.muted)))
                    : Column(children: [
                        for (final a in items)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(a['title'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text('${a['number']} · ${money(a['amount'] as num)}'),
                            trailing: const StatusChip('Pending', label: 'Approve'),
                            onTap: () => context.push('/approvals/${a['id']}', extra: a),
                          ),
                      ]),
              ),
            ]),
          ),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Quick actions', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (user.has('requisitions.create')) ActionChip(avatar: const Icon(Icons.add, size: 18), label: const Text('Requisition'), onPressed: () => context.push('/requisitions/new')),
                if (user.has('grn.record')) ActionChip(label: const Text('Receive goods'), onPressed: () => context.push('/purchase-orders', extra: 'receive')),
                if (user.has('vendors.view')) ActionChip(label: Text(labels.vendors), onPressed: () => context.push('/vendors')),
                if (user.has('invoices.view')) ActionChip(label: const Text('Invoices'), onPressed: () => context.push('/finance')),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, this.color, {this.onTap});

  final String label;
  final String value;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => AppCard(
        margin: EdgeInsets.zero,
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(label, style: const TextStyle(color: Brand.muted)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: color)),
        ]),
      );
}

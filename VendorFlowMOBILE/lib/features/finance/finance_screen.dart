import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';

final invoicesProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async {
  final page = await ref.watch(apiProvider).get('/invoices', query: {'pageSize': 50, 'sortBy': 'due_date', 'sortDir': 'asc'}) as Map;
  return List<dynamic>.from(page['items'] as List);
});

final paymentsProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async {
  final page = await ref.watch(apiProvider).get('/payments', query: {'pageSize': 50}) as Map;
  return List<dynamic>.from(page['items'] as List);
});

/// Read-only status of invoices and payments (payments are recorded on the web app).
class FinanceScreen extends ConsumerWidget {
  const FinanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).value!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: Brand.background,
        appBar: AppBar(
          backgroundColor: Brand.navy,
          foregroundColor: Colors.white,
          title: const Text('Invoices & payments', style: TextStyle(fontWeight: FontWeight.w700)),
          bottom: const TabBar(labelColor: Colors.white, unselectedLabelColor: Color(0xFFA8B4F5), indicatorColor: Colors.white, tabs: [Tab(text: 'Invoices'), Tab(text: 'Payments')]),
        ),
        body: TabBarView(children: [
          user.has('invoices.view') ? const _InvoiceList() : const EmptyView('You do not have access to invoices.'),
          user.has('payments.view') ? const _PaymentList() : const EmptyView('You do not have access to payments.'),
        ]),
      ),
    );
  }
}

class _InvoiceList extends ConsumerWidget {
  const _InvoiceList();

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref.watch(invoicesProvider).when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(apiMessage(e), onRetry: () => ref.invalidate(invoicesProvider)),
        data: (items) => items.isEmpty
            ? const EmptyView('No invoices yet.', icon: Icons.receipt_long_outlined)
            : ListView.builder(
                padding: const EdgeInsets.all(14),
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final inv = items[i] as Map;
                  return AppCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(inv['invoiceNumber'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                        Text(money(inv['total'] as num), style: const TextStyle(fontWeight: FontWeight.w800)),
                      ]),
                      Text('${inv['vendorName']} · due ${dateText(inv['dueDate'] as String?)}', style: const TextStyle(color: Brand.muted)),
                      const SizedBox(height: 8),
                      Row(children: [
                        StatusChip(inv['status'] as String?),
                        if (inv['isOverdue'] == true) ...[const SizedBox(width: 8), StatusChip('Overdue', label: '${inv['daysOverdue']} days overdue')],
                        const Spacer(),
                        Text('Balance ${money(inv['balance'] as num)}', style: const TextStyle(color: Brand.muted)),
                      ]),
                    ]),
                  );
                },
              ),
      );
}

class _PaymentList extends ConsumerWidget {
  const _PaymentList();

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref.watch(paymentsProvider).when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(apiMessage(e), onRetry: () => ref.invalidate(paymentsProvider)),
        data: (items) => items.isEmpty
            ? const EmptyView('No payments recorded yet.', icon: Icons.payments_outlined)
            : ListView.builder(
                padding: const EdgeInsets.all(14),
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final p = items[i] as Map;
                  return AppCard(
                    child: Row(children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${p['number']} · ${p['invoiceNumber']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('${p['vendorName']} · ${p['method']} · ${dateText(p['paidOn'] as String?)}', style: const TextStyle(color: Brand.muted)),
                      ])),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text(money(p['amount'] as num), style: const TextStyle(fontWeight: FontWeight.w800)),
                        StatusChip(p['status'] as String?),
                      ]),
                    ]),
                  );
                },
              ),
      );
}

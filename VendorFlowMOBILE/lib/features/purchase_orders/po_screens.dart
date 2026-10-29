import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';

final posProvider = FutureProvider.autoDispose.family<List<dynamic>, bool>((ref, onlyReceivable) async {
  final page = await ref.watch(apiProvider).get('/purchase-orders', query: {'pageSize': 50, 'sortBy': 'created_at', 'sortDir': 'desc'}) as Map;
  final items = List<dynamic>.from(page['items'] as List);
  return onlyReceivable ? items.where((p) => p['status'] == 'Issued' || p['status'] == 'PartiallyReceived').toList() : items;
});

final poProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async =>
    Map<String, dynamic>.from(await ref.watch(apiProvider).get('/purchase-orders/$id') as Map));

/// List of purchase orders. With receiveMode only POs that can receive goods are shown and tapping opens the receipt form.
class PurchaseOrdersScreen extends ConsumerWidget {
  const PurchaseOrdersScreen({super.key, this.receiveMode = false});

  final bool receiveMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(posProvider(receiveMode));
    return Scaffold(
      backgroundColor: Brand.background,
      appBar: ScreenHeader(receiveMode ? 'Receive goods' : 'Purchase orders', subtitle: receiveMode ? 'Choose the purchase order' : null),
      body: list.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(apiMessage(e), onRetry: () => ref.invalidate(posProvider)),
        data: (items) => items.isEmpty
            ? EmptyView(receiveMode ? 'No purchase order is waiting for goods.' : 'No purchase orders yet.', icon: Icons.shopping_cart_outlined)
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(posProvider),
                child: ListView.builder(
                  padding: const EdgeInsets.all(14),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final p = items[i] as Map;
                    return AppCard(
                      onTap: () => context.push(receiveMode ? '/receive/${p['id']}' : '/purchase-orders/${p['id']}'),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text(p['number'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                          Text(money(p['total'] as num), style: const TextStyle(fontWeight: FontWeight.w800)),
                        ]),
                        Text('${p['vendorName']} · ${dateText(p['expectedDelivery'] as String?)}', style: const TextStyle(color: Brand.muted)),
                        const SizedBox(height: 8),
                        Row(children: [
                          StatusChip(p['status'] as String?),
                          const SizedBox(width: 12),
                          Expanded(child: LinearProgressIndicator(value: ((p['receiptPct'] ?? 0) as num) / 100, minHeight: 6, borderRadius: BorderRadius.circular(4))),
                          const SizedBox(width: 8),
                          Text('${p['receiptPct']}%'),
                        ]),
                      ]),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

class PoDetailScreen extends ConsumerWidget {
  const PoDetailScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final po = ref.watch(poProvider(id));
    final user = ref.watch(authProvider).value!;
    return Scaffold(
      backgroundColor: Brand.background,
      appBar: const ScreenHeader('Purchase order'),
      body: po.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(apiMessage(e), onRetry: () => ref.invalidate(poProvider)),
        data: (p) => ListView(padding: const EdgeInsets.all(14), children: [
          AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(p['number'] as String, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))), StatusChip(p['status'] as String?)]),
            Text('${p['vendorName']} · Revision ${p['revision']}', style: const TextStyle(color: Brand.muted)),
            const SizedBox(height: 8),
            InfoRow('Order date', dateText(p['orderDate'] as String?)),
            InfoRow('Expected', dateText(p['expectedDelivery'] as String?)),
            InfoRow('Total', money(p['total'] as num, decimals: 2)),
            InfoRow('Receipt', '${p['receiptPct']}%'),
          ])),
          AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Items', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            for (final i in List<dynamic>.from(p['items'] as List))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(i['description'] as String),
                subtitle: Text('Received ${i['receivedQty']} of ${i['quantity']}'),
                trailing: Text(money(i['lineTotal'] as num)),
              ),
          ])),
          if (user.has('grn.record') && (p['status'] == 'Issued' || p['status'] == 'PartiallyReceived'))
            FilledButton.icon(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)), onPressed: () => context.push('/receive/$id'), icon: const Icon(Icons.inventory_2_outlined), label: const Text('Receive goods')),
        ]),
      ),
    );
  }
}

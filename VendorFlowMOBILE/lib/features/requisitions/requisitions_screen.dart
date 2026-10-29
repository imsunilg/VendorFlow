import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';

/// Requisitions of the user ("mine") or everyone's.
final requisitionsProvider = FutureProvider.autoDispose.family<List<dynamic>, String>((ref, scope) async {
  final page = await ref.watch(apiProvider).get('/requisitions', query: {'scope': scope, 'pageSize': 50, 'sortBy': 'created_at', 'sortDir': 'desc'}) as Map;
  return List<dynamic>.from(page['items'] as List);
});

class RequisitionsScreen extends ConsumerStatefulWidget {
  const RequisitionsScreen({super.key});

  @override
  ConsumerState<RequisitionsScreen> createState() => _RequisitionsScreenState();
}

class _RequisitionsScreenState extends ConsumerState<RequisitionsScreen> {
  String _scope = 'mine';

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).value!;
    final list = ref.watch(requisitionsProvider(_scope));
    return Scaffold(
      backgroundColor: Brand.background,
      appBar: const ScreenHeader('Requests', subtitle: 'Requisitions and their approval status'),
      floatingActionButton: user.has('requisitions.create') ? FloatingActionButton.extended(onPressed: () => context.push('/requisitions/new'), icon: const Icon(Icons.add), label: const Text('New')) : null,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'mine', label: Text('My requests')), ButtonSegment(value: 'all', label: Text('All'))],
            selected: {_scope},
            onSelectionChanged: (s) => setState(() => _scope = s.first),
          ),
        ),
        Expanded(
          child: list.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(apiMessage(e), onRetry: () => ref.invalidate(requisitionsProvider)),
            data: (items) => items.isEmpty
                ? const EmptyView('No requisitions yet.', icon: Icons.description_outlined)
                : RefreshIndicator(
                    onRefresh: () async => ref.invalidate(requisitionsProvider),
                    child: ListView.builder(
                      padding: const EdgeInsets.all(14),
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final r = items[i] as Map;
                        return AppCard(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(child: Text(r['title'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                              Text(money(r['totalAmount'] as num), style: const TextStyle(fontWeight: FontWeight.w800)),
                            ]),
                            const SizedBox(height: 2),
                            Text('${r['number']} · ${r['departmentName'] ?? '—'} · by ${dateText(r['requiredDate'] as String?)}', style: const TextStyle(color: Brand.muted)),
                            const SizedBox(height: 8),
                            StatusChip(r['status'] as String?),
                          ]),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ]),
    );
  }
}

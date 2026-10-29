import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';
import 'approvals_screen.dart';

/// Line items of the document behind the approval (requisition or purchase order).
final approvalItemsProvider = FutureProvider.autoDispose.family<List<dynamic>, Map<String, dynamic>>((ref, item) async {
  final path = item['entityType'] == 'requisition' ? '/requisitions/${item['entityId']}' : '/purchase-orders/${item['entityId']}';
  final doc = await ref.watch(apiProvider).get(path) as Map;
  return List<dynamic>.from(doc['items'] as List);
});

class ApprovalDetailScreen extends ConsumerStatefulWidget {
  const ApprovalDetailScreen({super.key, required this.item});

  /// The inbox row (already loaded by the list screen).
  final Map<String, dynamic> item;

  @override
  ConsumerState<ApprovalDetailScreen> createState() => _ApprovalDetailScreenState();
}

class _ApprovalDetailScreenState extends ConsumerState<ApprovalDetailScreen> {
  final _comment = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  // decision: approve | reject | request-changes. Reject and request-changes need a comment.
  Future<void> _decide(String decision) async {
    if (decision != 'approve' && _comment.text.trim().isEmpty) {
      showMessage(context, 'Add a comment first.');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).post('/approvals/${widget.item['id']}/$decision',
          body: {'comment': _comment.text.trim(), 'expectedVersion': widget.item['rowVersion']});
      ref.invalidate(approvalsProvider);
      if (mounted) {
        showMessage(context, decision == 'approve' ? 'Approved' : 'Done');
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showMessage(context, apiMessage(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final items = ref.watch(approvalItemsProvider(item));
    final steps = List<Map<String, dynamic>>.from((item['steps'] as List).map((e) => Map<String, dynamic>.from(e as Map)));
    final canDecide = item['status'] == 'Pending' && (ref.watch(authProvider).value?.has('approvals.decide') ?? false);

    return Scaffold(
      backgroundColor: Brand.background,
      appBar: ScreenHeader(item['number'] as String? ?? 'Approval'),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(money(item['amount'] as num), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          Text(item['title'] as String, style: const TextStyle(color: Brand.muted)),
          const SizedBox(height: 6),
          Text('${item['requestedByName']} · ${item['departmentName'] ?? ''}', style: const TextStyle(color: Brand.muted)),
        ])),
        AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Approval route', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final s in steps)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: s['status'] == 'Approved' ? const Color(0xFF12A05C) : s['status'] == 'Pending' ? const Color(0xFFFFB36B) : const Color(0xFFE6E9F2),
                child: s['status'] == 'Approved' ? const Icon(Icons.check, size: 18, color: Colors.white) : Text('${s['stepNo']}'),
              ),
              title: Text(s['name'] as String),
              subtitle: Text(s['decidedByName'] != null ? '${s['decidedByName']} · ${statusText(s['status'] as String?).toLowerCase()}' : (s['status'] == 'Pending' ? 'Waiting' : 'Not started')),
            ),
        ])),
        AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Items', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          items.when(
            loading: () => const LoadingView(),
            error: (e, _) => Text(apiMessage(e)),
            data: (list) => Column(children: [
              for (final i in list)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Expanded(child: Text('${i['description']} × ${i['quantity']}')),
                    Text(money((i['lineTotal'] ?? 0) as num)),
                  ]),
                ),
            ]),
          ),
        ])),
        if (canDecide) ...[
          AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Comment (required to reject)', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            TextField(controller: _comment, maxLines: 3, decoration: const InputDecoration(hintText: 'Add a comment…', border: OutlineInputBorder())),
          ])),
          Row(children: [
            Expanded(child: FilledButton(style: FilledButton.styleFrom(backgroundColor: const Color(0xFF12A05C), minimumSize: const Size.fromHeight(50)), onPressed: _busy ? null : () => _decide('approve'), child: const Text('Approve'))),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton(style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFDC2D4A), minimumSize: const Size.fromHeight(50)), onPressed: _busy ? null : () => _decide('reject'), child: const Text('Reject'))),
          ]),
          TextButton(onPressed: _busy ? null : () => _decide('request-changes'), child: const Text('Request changes')),
        ],
      ]),
    );
  }
}

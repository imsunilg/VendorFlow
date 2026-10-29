import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';

final notificationsProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async =>
    Map<String, dynamic>.from(await ref.watch(apiProvider).get('/notifications', query: {'pageSize': 50}) as Map));

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  // Colour and icon by notification type.
  Color _color(String type) {
    if (type.contains('overdue') || type.contains('expired')) return const Color(0xFFDC2D4A);
    if (type.contains('needed') || type.contains('expiring') || type.contains('due') || type.contains('reminder')) return const Color(0xFFD98A06);
    if (type.contains('issued')) return Brand.primary;
    return const Color(0xFF12A05C);
  }

  // Opens the document behind a notification when the app has a screen for it.
  void _open(BuildContext context, Map n) {
    final id = n['entityId'] as String?;
    switch (n['entityType']) {
      case 'purchase_order': if (id != null) context.push('/purchase-orders/$id');
      case 'vendor': if (id != null) context.push('/vendors/$id');
      case 'invoice': context.push('/finance');
      default: context.go('/approvals');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(notificationsProvider);
    return Scaffold(
      backgroundColor: Brand.background,
      appBar: ScreenHeader('Notifications', subtitle: '${data.value?['unreadCount'] ?? 0} new'),
      body: data.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(apiMessage(e), onRetry: () => ref.invalidate(notificationsProvider)),
        data: (page) {
          final items = List<dynamic>.from(page['items'] as List);
          if (items.isEmpty) return const EmptyView('No notifications.', icon: Icons.notifications_none);
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(notificationsProvider),
            child: ListView.builder(
              padding: const EdgeInsets.all(14),
              itemCount: items.length,
              itemBuilder: (_, i) {
                final n = items[i] as Map;
                final color = _color(n['type'] as String);
                return AppCard(
                  onTap: () async {
                    await ref.read(apiProvider).post('/notifications/${n['id']}/read');
                    ref.invalidate(notificationsProvider);
                    if (context.mounted) _open(context, n);
                  },
                  child: Row(children: [
                    Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                      child: Icon(Icons.notifications_none, color: color),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(n['title'] as String, style: TextStyle(fontWeight: n['read'] == true ? FontWeight.w500 : FontWeight.w800)),
                      Text((n['body'] ?? '') as String, style: const TextStyle(color: Brand.muted)),
                    ])),
                  ]),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

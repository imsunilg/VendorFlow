import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';

final vendorsProvider = FutureProvider.autoDispose.family<List<dynamic>, String>((ref, search) async {
  final page = await ref.watch(apiProvider).get('/vendors', query: {'search': search, 'pageSize': 50, 'sortBy': 'name'}) as Map;
  return List<dynamic>.from(page['items'] as List);
});

final vendorProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async =>
    Map<String, dynamic>.from(await ref.watch(apiProvider).get('/vendors/$id') as Map));

final vendorPerformanceProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async =>
    Map<String, dynamic>.from(await ref.watch(apiProvider).get('/vendors/$id/performance') as Map));

class VendorsScreen extends ConsumerStatefulWidget {
  const VendorsScreen({super.key});

  @override
  ConsumerState<VendorsScreen> createState() => _VendorsScreenState();
}

class _VendorsScreenState extends ConsumerState<VendorsScreen> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final labels = ref.watch(labelsProvider);
    final list = ref.watch(vendorsProvider(_search));
    return Scaffold(
      backgroundColor: Brand.background,
      appBar: ScreenHeader(labels.vendors),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: TextField(
            decoration: InputDecoration(hintText: labels.t('Search vendors…'), prefixIcon: const Icon(Icons.search), filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
            onSubmitted: (v) => setState(() => _search = v.trim()),
          ),
        ),
        Expanded(
          child: list.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(apiMessage(e), onRetry: () => ref.invalidate(vendorsProvider)),
            data: (items) => items.isEmpty
                ? EmptyView(labels.t('No vendors found.'))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final v = items[i] as Map;
                      return AppCard(
                        onTap: () => context.push('/vendors/${v['id']}'),
                        child: Row(children: [
                          CircleAvatar(backgroundColor: Brand.primary, child: Text((v['name'] as String).substring(0, 2).toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
                          const SizedBox(width: 12),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(v['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                            Text('${v['category'] ?? ''} · ${v['city'] ?? ''}', style: const TextStyle(color: Brand.muted)),
                          ])),
                          StatusChip(v['status'] as String?),
                        ]),
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}

class VendorDetailScreen extends ConsumerWidget {
  const VendorDetailScreen({super.key, required this.id});

  final String id;

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri) && context.mounted) showMessage(context, 'Cannot open $url');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = ref.watch(labelsProvider);
    final vendor = ref.watch(vendorProvider(id));
    final performance = ref.watch(vendorPerformanceProvider(id));
    return Scaffold(
      backgroundColor: Brand.background,
      appBar: ScreenHeader('${labels.vendor} details'),
      body: vendor.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(apiMessage(e), onRetry: () => ref.invalidate(vendorProvider)),
        data: (v) {
          final contacts = List<dynamic>.from(v['contacts'] as List);
          final phone = (contacts.isNotEmpty ? contacts.first['phone'] : v['phone']) as String?;
          final email = (contacts.isNotEmpty ? contacts.first['email'] : v['email']) as String?;
          return ListView(padding: const EdgeInsets.all(14), children: [
            AppCard(child: Column(children: [
              CircleAvatar(radius: 34, backgroundColor: Brand.primary, child: Text((v['name'] as String).substring(0, 2).toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700))),
              const SizedBox(height: 10),
              Text(v['name'] as String, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800), textAlign: TextAlign.center),
              Text('${v['category'] ?? ''} · ${v['city'] ?? ''}', style: const TextStyle(color: Brand.muted)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [StatusChip(v['status'] as String?), StatusChip(v['risk'] as String?, label: '${v['risk']} risk')]),
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (phone != null && phone.isNotEmpty) OutlinedButton.icon(onPressed: () => _open(context, 'tel:$phone'), icon: const Icon(Icons.call), label: const Text('Call')),
                const SizedBox(width: 10),
                if (email != null && email.isNotEmpty) OutlinedButton.icon(onPressed: () => _open(context, 'mailto:$email'), icon: const Icon(Icons.mail_outline), label: const Text('Email')),
              ]),
            ])),
            performance.when(
              loading: () => const SizedBox.shrink(),
              error: (e, _) => const SizedBox.shrink(),
              data: (p) => Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF3B4FE0), Color(0xFF6C7CF5)]), borderRadius: BorderRadius.circular(16)),
                child: Column(children: [
                  const Text('Performance score', style: TextStyle(color: Colors.white70)),
                  Text(p['score'] == null ? 'No data yet' : '${p['score']}%', style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w800)),
                ]),
              ),
            ),
            AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Documents', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (final d in List<dynamic>.from(v['documents'] as List))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(d['docType'] as String),
                  subtitle: d['expiryDate'] == null ? null : Text('Expires ${dateText(d['expiryDate'] as String?)}'),
                  trailing: StatusChip(d['status'] as String?, label: d['status'] == 'Expiring' ? '${d['daysLeft']} days' : null),
                ),
              if ((v['documents'] as List).isEmpty) const Text('No documents yet.', style: TextStyle(color: Brand.muted)),
            ])),
          ]);
        },
      ),
    );
  }
}

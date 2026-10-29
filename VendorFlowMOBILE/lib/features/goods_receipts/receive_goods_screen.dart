import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/api_client.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';
import '../purchase_orders/po_screens.dart';

/// Record received goods against a purchase order (received = accepted + rejected) and optionally attach photos.
class ReceiveGoodsScreen extends ConsumerStatefulWidget {
  const ReceiveGoodsScreen({super.key, required this.poId});

  final String poId;

  @override
  ConsumerState<ReceiveGoodsScreen> createState() => _ReceiveGoodsScreenState();
}

class _ReceiveGoodsScreenState extends ConsumerState<ReceiveGoodsScreen> {
  // One set of three text boxes per PO item: received, accepted, rejected.
  final Map<String, List<TextEditingController>> _fields = {};
  final List<XFile> _photos = [];
  final _challan = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    for (final list in _fields.values) {
      for (final c in list) { c.dispose(); }
    }
    _challan.dispose();
    super.dispose();
  }

  List<TextEditingController> _controllersFor(String itemId) =>
      _fields.putIfAbsent(itemId, () => [TextEditingController(text: '0'), TextEditingController(text: '0'), TextEditingController(text: '0')]);

  double _num(TextEditingController c) => double.tryParse(c.text) ?? 0;

  Future<void> _addPhoto() async {
    final photo = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 80);
    if (photo != null) setState(() => _photos.add(photo));
  }

  Future<void> _post(Map<String, dynamic> po) async {
    final lines = <Map<String, dynamic>>[];
    for (final item in List<dynamic>.from(po['items'] as List)) {
      final c = _controllersFor(item['id'] as String);
      final received = _num(c[0]), accepted = _num(c[1]), rejected = _num(c[2]);
      if (received == 0 && accepted == 0 && rejected == 0) continue;
      if (accepted + rejected != received) { showMessage(context, '${item['description']}: accepted + rejected must equal received.'); return; }
      if (received > (item['pendingQty'] as num)) { showMessage(context, '${item['description']}: only ${item['pendingQty']} pending.'); return; }
      lines.add({'poItemId': item['id'], 'receivedQty': received, 'acceptedQty': accepted, 'rejectedQty': rejected});
    }
    if (lines.isEmpty) { showMessage(context, 'Enter a received quantity.'); return; }

    setState(() => _busy = true);
    final api = ref.read(apiProvider);
    try {
      final grn = await api.post('/purchase-orders/${widget.poId}/receipts', body: {
        'deliveryChallan': _challan.text.trim().isEmpty ? null : _challan.text.trim(),
        'receivedBy': ref.read(authProvider).value?.fullName, 'items': lines,
      }) as Map;
      for (final photo in _photos) {
        await api.upload('/attachments/goods_receipt/${grn['id']}', FormData.fromMap({'file': await MultipartFile.fromFile(photo.path, filename: photo.name)}));
      }
      ref.invalidate(posProvider);
      ref.invalidate(poProvider);
      if (mounted) { showMessage(context, 'Receipt ${grn['number']} posted'); context.pop(); }
    } catch (e) {
      if (mounted) { setState(() => _busy = false); showMessage(context, apiMessage(e)); }
    }
  }

  @override
  Widget build(BuildContext context) {
    final po = ref.watch(poProvider(widget.poId));
    return Scaffold(
      backgroundColor: Brand.background,
      appBar: const ScreenHeader('Receive goods'),
      body: po.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(apiMessage(e)),
        data: (p) => ListView(padding: const EdgeInsets.all(14), children: [
          AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p['number'] as String, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Text(p['vendorName'] as String, style: const TextStyle(color: Brand.muted)),
            const SizedBox(height: 10),
            TextField(controller: _challan, decoration: const InputDecoration(labelText: 'Delivery challan no.', border: OutlineInputBorder())),
          ])),
          for (final item in List<dynamic>.from(p['items'] as List))
            if ((item['pendingQty'] as num) > 0)
              AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item['description'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                Text('Ordered ${item['quantity']} · pending ${item['pendingQty']}', style: const TextStyle(color: Brand.muted)),
                const SizedBox(height: 8),
                Row(children: [
                  for (final (index, label) in const ['Received', 'Accepted', 'Rejected'].indexed)
                    Expanded(child: Padding(
                      padding: EdgeInsets.only(right: index == 2 ? 0 : 8),
                      child: TextField(controller: _controllersFor(item['id'] as String)[index], keyboardType: TextInputType.number, decoration: InputDecoration(labelText: label, border: const OutlineInputBorder())),
                    )),
                ]),
              ])),
          AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Photos', style: TextStyle(fontWeight: FontWeight.w700))),
              TextButton.icon(onPressed: _addPhoto, icon: const Icon(Icons.photo_camera_outlined), label: const Text('Add photos')),
            ]),
            Text(_photos.isEmpty ? 'No photos added.' : '${_photos.length} photo(s) will be attached.', style: const TextStyle(color: Brand.muted)),
          ])),
          FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)), onPressed: _busy ? null : () => _post(p), child: Text(_busy ? 'Posting…' : 'Post receipt')),
        ]),
      ),
    );
  }
}

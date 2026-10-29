import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';
import 'requisitions_screen.dart';

final _departmentsProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async => List<dynamic>.from(await ref.watch(apiProvider).get('/lookups/departments') as List));
final _costCentresProvider = FutureProvider.autoDispose<List<dynamic>>((ref) async => List<dynamic>.from(await ref.watch(apiProvider).get('/lookups/cost-centres') as List));

class _Line {
  _Line(this.description, this.quantity, this.price);
  final String description;
  final double quantity;
  final double price;
  double get total => (quantity * double.parse(price.toStringAsFixed(2)) * 100).round() / 100;
}

class RequisitionFormScreen extends ConsumerStatefulWidget {
  const RequisitionFormScreen({super.key});

  @override
  ConsumerState<RequisitionFormScreen> createState() => _RequisitionFormScreenState();
}

class _RequisitionFormScreenState extends ConsumerState<RequisitionFormScreen> {
  final _title = TextEditingController();
  String? _departmentId;
  String? _costCentreId;
  DateTime? _requiredBy;
  final List<_Line> _lines = [];
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  double get _total => _lines.fold(0, (sum, l) => sum + l.total);

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(context: context, initialDate: now.add(const Duration(days: 14)), firstDate: now, lastDate: now.add(const Duration(days: 730)));
    if (date != null) setState(() => _requiredBy = date);
  }

  // Asks for one item (description, quantity, price) and adds it to the list.
  Future<void> _addLine() async {
    final description = TextEditingController();
    final quantity = TextEditingController(text: '1');
    final price = TextEditingController();
    final line = await showDialog<_Line>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add item'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: description, decoration: const InputDecoration(labelText: 'Description')),
          TextField(controller: quantity, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantity')),
          TextField(controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Estimated unit price')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final q = double.tryParse(quantity.text);
              final p = double.tryParse(price.text);
              if (description.text.trim().isEmpty || q == null || q <= 0 || p == null || p < 0) return;
              Navigator.pop(ctx, _Line(description.text.trim(), q, p));
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (line != null) setState(() => _lines.add(line));
  }

  // Saves the requisition; with submit = true it is also sent for approval.
  Future<void> _save({required bool submit}) async {
    if (_title.text.trim().isEmpty || _departmentId == null || _costCentreId == null || _requiredBy == null || _lines.isEmpty) {
      showMessage(context, 'Fill in title, department, cost centre, date and at least one item.');
      return;
    }
    setState(() => _busy = true);
    final api = ref.read(apiProvider);
    try {
      final created = await api.post('/requisitions', body: {
        'title': _title.text.trim(), 'departmentId': _departmentId, 'costCentreId': _costCentreId,
        'requiredDate': _requiredBy!.toIso8601String().substring(0, 10),
        'items': [for (final l in _lines) {'description': l.description, 'quantity': l.quantity, 'estUnitPrice': l.price}],
      }) as Map;
      if (submit) await api.post('/requisitions/${created['id']}/submit');
      ref.invalidate(requisitionsProvider);
      if (mounted) {
        showMessage(context, submit ? 'Submitted for approval' : 'Draft saved');
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
    final departments = ref.watch(_departmentsProvider).value ?? [];
    final costCentres = (ref.watch(_costCentresProvider).value ?? []).where((c) => c['departmentId'] == _departmentId || _departmentId == null).toList();
    return Scaffold(
      backgroundColor: Brand.background,
      appBar: const ScreenHeader('New requisition'),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        AppCard(child: Column(children: [
          TextField(controller: _title, decoration: const InputDecoration(labelText: 'Title *', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _departmentId,
            decoration: const InputDecoration(labelText: 'Department *', border: OutlineInputBorder()),
            items: [for (final d in departments) DropdownMenuItem(value: d['id'] as String, child: Text(d['name'] as String))],
            onChanged: (v) => setState(() { _departmentId = v; _costCentreId = null; }),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey(_departmentId),
            initialValue: _costCentreId,
            decoration: const InputDecoration(labelText: 'Cost centre *', border: OutlineInputBorder()),
            items: [for (final c in costCentres) DropdownMenuItem(value: c['id'] as String, child: Text('${c['code']} · ${c['name']}'))],
            onChanged: (v) => setState(() => _costCentreId = v),
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: _pickDate,
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Required by *', border: OutlineInputBorder()),
              child: Text(_requiredBy == null ? 'Choose a date' : dateText(_requiredBy!.toIso8601String())),
            ),
          ),
        ])),
        AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Items', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
            TextButton.icon(onPressed: _addLine, icon: const Icon(Icons.add), label: const Text('Add')),
          ]),
          for (var i = 0; i < _lines.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_lines[i].description),
              subtitle: Text('${_lines[i].quantity} × ${money(_lines[i].price)}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(money(_lines[i].total), style: const TextStyle(fontWeight: FontWeight.w700)),
                IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _lines.removeAt(i))),
              ]),
            ),
          const Divider(),
          Row(children: [const Expanded(child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700))), Text(money(_total), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))]),
        ])),
        FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)), onPressed: _busy ? null : () => _save(submit: true), child: const Text('Submit for approval')),
        TextButton(onPressed: _busy ? null : () => _save(submit: false), child: const Text('Save as draft')),
      ]),
    );
  }
}

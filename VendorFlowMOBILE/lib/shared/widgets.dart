import 'package:flutter/material.dart';
import '../core/format.dart';

/// Brand colours used across the app (same as the web app).
class Brand {
  static const navy = Color(0xFF0E1A42);
  static const primary = Color(0xFF3B4FE0);
  static const background = Color(0xFFF4F6FB);
  static const border = Color(0xFFE6E9F2);
  static const muted = Color(0xFF6B7394);
}

/// Small coloured pill with a status text.
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.label});

  final String? status;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, size: 7, color: color),
        const SizedBox(width: 5),
        Text(label ?? statusText(status), style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
      ]),
    );
  }
}

/// White rounded card used for every block of content.
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.onTap, this.padding = const EdgeInsets.all(14), this.margin = const EdgeInsets.only(bottom: 10)});

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) => Container(
        margin: margin,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: Brand.border)),
        child: Material(
          color: Colors.transparent,
          child: InkWell(borderRadius: BorderRadius.circular(16), onTap: onTap, child: Padding(padding: padding, child: child)),
        ),
      );
}

/// Dark blue header used on every screen (title + optional subtitle).
class ScreenHeader extends StatelessWidget implements PreferredSizeWidget {
  const ScreenHeader(this.title, {super.key, this.subtitle, this.actions});

  final String title;
  final String? subtitle;
  final List<Widget>? actions;

  @override
  Size get preferredSize => Size.fromHeight(subtitle == null ? 60 : 82);

  @override
  Widget build(BuildContext context) => AppBar(
        backgroundColor: Brand.navy,
        foregroundColor: Colors.white,
        toolbarHeight: preferredSize.height,
        actions: actions,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          if (subtitle != null) Text(subtitle!, style: const TextStyle(fontSize: 13, color: Color(0xFFA8B4F5))),
        ]),
      );
}

/// Shown while data loads.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) => const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()));
}

/// Shown when a call failed, with a retry button.
class ErrorView extends StatelessWidget {
  const ErrorView(this.message, {super.key, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 40, color: Brand.muted),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Try again')),
          ]),
        ),
      );
}

/// Shown when a list is empty.
class EmptyView extends StatelessWidget {
  const EmptyView(this.message, {super.key, this.icon = Icons.inbox_outlined});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: Brand.muted),
            const SizedBox(height: 8),
            Text(message, style: const TextStyle(color: Brand.muted), textAlign: TextAlign.center),
          ]),
        ),
      );
}

/// A label/value pair for detail screens.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 120, child: Text(label, style: const TextStyle(color: Brand.muted))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );
}

void showMessage(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

/// Asks for a comment (reject / request changes). Returns the text, or null when cancelled.
Future<String?> askComment(BuildContext context, String title, {bool required = true}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, maxLines: 3, autofocus: true, onChanged: (_) => setState(() {}),
            decoration: InputDecoration(hintText: required ? 'Comment (required)' : 'Comment (optional)', border: const OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: required && controller.text.trim().isEmpty ? null : () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Confirm'),
          ),
        ],
      ),
    ),
  );
}

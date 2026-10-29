import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).value!;
    final labels = ref.watch(labelsProvider);
    return Scaffold(
      backgroundColor: Brand.background,
      appBar: const ScreenHeader('Profile'),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        AppCard(child: Column(children: [
          CircleAvatar(radius: 34, backgroundColor: Brand.primary, child: Text(user.initials, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700))),
          const SizedBox(height: 10),
          Text(user.fullName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          Text(user.email, style: const TextStyle(color: Brand.muted)),
        ])),
        AppCard(child: Column(children: [
          InfoRow('Organization', labels.organization),
          InfoRow('Application', labels.appName),
          InfoRow('Roles', user.roleText),
          const InfoRow('Server', apiBase),
        ])),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50), foregroundColor: const Color(0xFFDC2D4A)),
          onPressed: () => ref.read(authProvider.notifier).logout(),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ]),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers.dart';
import 'router.dart';
import 'shared/widgets.dart';

void main() => runApp(const ProviderScope(child: VendorFlowApp()));

class VendorFlowApp extends ConsumerWidget {
  const VendorFlowApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = ref.watch(labelsProvider);
    return MaterialApp.router(
      title: labels.appName,
      debugShowCheckedModeBanner: false,
      routerConfig: ref.watch(routerProvider),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Brand.primary, primary: Brand.primary),
        scaffoldBackgroundColor: Brand.background,
        navigationBarTheme: const NavigationBarThemeData(backgroundColor: Colors.white, indicatorColor: Color(0xFFE8EBFF)),
      ),
    );
  }
}

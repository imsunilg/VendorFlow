import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'core/providers.dart';
import 'features/approvals/approval_detail_screen.dart';
import 'features/approvals/approvals_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/finance/finance_screen.dart';
import 'features/goods_receipts/receive_goods_screen.dart';
import 'features/home/home_screen.dart';
import 'features/notifications/notifications_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/purchase_orders/po_screens.dart';
import 'features/requisitions/requisition_form_screen.dart';
import 'features/requisitions/requisitions_screen.dart';
import 'features/vendors/vendors_screen.dart';

/// All screens and the sign-in redirect. Signed-out users always land on /login.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      if (auth.isLoading && !auth.hasValue) return null;        // still reading the stored session
      final signedIn = auth.value != null;
      final onLogin = state.matchedLocation == '/login';
      if (!signedIn) return onLogin ? null : '/login';
      return onLogin ? '/' : null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      // The five tabs of the bottom bar.
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => _Shell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/', builder: (_, _) => const HomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/approvals', builder: (_, _) => const ApprovalsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/requisitions', builder: (_, _) => const RequisitionsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/alerts', builder: (_, _) => const NotificationsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/profile', builder: (_, _) => const ProfileScreen())]),
        ],
      ),
      // Detail screens open above the tabs.
      GoRoute(path: '/approvals/:id', builder: (_, state) => ApprovalDetailScreen(item: Map<String, dynamic>.from(state.extra as Map))),
      GoRoute(path: '/requisitions/new', builder: (_, _) => const RequisitionFormScreen()),
      GoRoute(path: '/vendors', builder: (_, _) => const VendorsScreen()),
      GoRoute(path: '/vendors/:id', builder: (_, state) => VendorDetailScreen(id: state.pathParameters['id']!)),
      GoRoute(path: '/purchase-orders', builder: (_, state) => PurchaseOrdersScreen(receiveMode: state.extra == 'receive')),
      GoRoute(path: '/purchase-orders/:id', builder: (_, state) => PoDetailScreen(id: state.pathParameters['id']!)),
      GoRoute(path: '/receive/:poId', builder: (_, state) => ReceiveGoodsScreen(poId: state.pathParameters['poId']!)),
      GoRoute(path: '/finance', builder: (_, _) => const FinanceScreen()),
    ],
  );
});

/// Bottom navigation: Home, Approvals, Requests, Alerts, Profile.
class _Shell extends StatelessWidget {
  const _Shell({required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: shell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: shell.currentIndex,
          onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.check), label: 'Approvals'),
            NavigationDestination(icon: Icon(Icons.description_outlined), selectedIcon: Icon(Icons.description), label: 'Requests'),
            NavigationDestination(icon: Icon(Icons.notifications_none), selectedIcon: Icon(Icons.notifications), label: 'Alerts'),
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
          ],
        ),
      );
}

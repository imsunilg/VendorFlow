import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api_client.dart';
import '../../core/providers.dart';
import '../../shared/widgets.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  // Validates the form, signs in and shows the API's message if it fails. The router moves on when the user is set.
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _busy = true; _error = null; });
    await ref.read(authProvider.notifier).login(_email.text.trim(), _password.text);
    if (!mounted) return;
    final state = ref.read(authProvider);
    setState(() {
      _busy = false;
      _error = state.hasError ? apiMessage(state.error!) : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final labels = ref.watch(labelsProvider);
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(color: Brand.primary, borderRadius: BorderRadius.circular(18)),
                    child: const Icon(Icons.shopping_cart_outlined, color: Colors.white, size: 32),
                  ),
                  const SizedBox(height: 18),
                  Text(labels.appName, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: Brand.navy)),
                  const Text('Sign in to your workspace', style: TextStyle(color: Brand.muted, fontSize: 16)),
                  const SizedBox(height: 28),
                  if (_error != null)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: const Color(0xFFFDE4E8), borderRadius: BorderRadius.circular(10)),
                      child: Text(_error!, style: const TextStyle(color: Color(0xFFDC2D4A))),
                    ),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.username],
                    decoration: const InputDecoration(labelText: 'Work email', border: OutlineInputBorder()),
                    validator: (v) => v == null || !v.contains('@') ? 'Enter a valid email address.' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                    validator: (v) => v == null || v.isEmpty ? 'Password is required.' : null,
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity, height: 50,
                    child: FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'Signing in…' : 'Sign in')),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

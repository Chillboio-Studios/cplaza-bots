import 'package:flutter/material.dart';
import '../api.dart';
import '../models.dart';

class LoginScreen extends StatefulWidget {
  final ApiClient api;
  final void Function(BotUser) onLogin;
  const LoginScreen({super.key, required this.api, required this.onLogin});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _isRegister = false;
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = _isRegister
          ? await widget.api.register(_username.text.trim(), _password.text)
          : await widget.api.login(_username.text.trim(), _password.text);
      widget.onLogin(BotUser.fromJson(res['user']));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.smart_toy,
                    size: 72, color: Color(0xFF5865F2)),
                const SizedBox(height: 12),
                Text('CreatorPlaza Bots',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('Build Discord bots without code',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey[400])),
                const SizedBox(height: 32),
                TextField(
                  controller: _username,
                  decoration: const InputDecoration(
                      labelText: 'Username', prefixIcon: Icon(Icons.person)),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Password',
                      prefixIcon: Icon(Icons.lock)),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)),
                ],
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_isRegister ? 'Create Account' : 'Log In'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () =>
                      setState(() => _isRegister = !_isRegister),
                  child: Text(_isRegister
                      ? 'Already have an account? Log in'
                      : "Don't have an account? Sign up"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

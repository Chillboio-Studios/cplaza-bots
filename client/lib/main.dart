import 'package:flutter/material.dart';
import 'api.dart';
import 'models.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';

void main() {
  runApp(const CreatorPlazaApp());
}

class CreatorPlazaApp extends StatelessWidget {
  const CreatorPlazaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CreatorPlaza Bots',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5865F2),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF1E1F22),
        cardColor: const Color(0xFF2B2D31),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF2B2D31),
          foregroundColor: Colors.white,
          centerTitle: false,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF383A40),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF5865F2),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final ApiClient api = ApiClient();
  bool _loading = true;
  BotUser? _user;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await api.loadToken();
    try {
      final res = await api.me();
      _user = res?['user'] != null
          ? BotUser.fromJson(res!['user'])
          : null;
    } catch (_) {
      _user = null;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _onLogin(BotUser user) {
    setState(() => _user = user);
  }

  Future<void> _onLogout() async {
    await api.logout();
    setState(() => _user = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_user == null) {
      return LoginScreen(api: api, onLogin: _onLogin);
    }
    return DashboardScreen(api: api, user: _user!, onLogout: _onLogout);
  }
}

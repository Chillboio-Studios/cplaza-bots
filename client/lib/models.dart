import 'dart:convert';

class BotUser {
  final int id;
  final String username;
  final String plan;
  final String role;
  BotUser(
      {required this.id,
      required this.username,
      this.plan = 'free',
      this.role = 'user'});
  factory BotUser.fromJson(Map<String, dynamic> j) => BotUser(
      id: j['id'],
      username: j['username'],
      plan: j['plan'] ?? 'free',
      role: j['role'] ?? 'user');
}

Map<String, dynamic> decodeConfig(dynamic raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is String && raw.isNotEmpty) {
    try {
      final d = jsonDecode(raw);
      if (d is Map<String, dynamic>) return d;
    } catch (_) {}
  }
  return {};
}

class Bot {
  final int id;
  String name;
  String token; // masked by API after creation
  Map<String, dynamic> config;
  String status;
  String createdAt;

  Bot({
    required this.id,
    required this.name,
    required this.token,
    required this.config,
    required this.status,
    required this.createdAt,
  });

  factory Bot.fromJson(Map<String, dynamic> j) => Bot(
        id: j['id'],
        name: j['name'] ?? 'Untitled Bot',
        token: j['token'] ?? '',
        config: decodeConfig(j['config']),
        status: j['status'] ?? 'offline',
        createdAt: j['created_at'] ?? '',
      );

  List<dynamic> get modules =>
      (config['modules'] as List?) ?? [];

  Map<String, dynamic> get settings =>
      Map<String, dynamic>.from(config['settings'] ?? {});
}

class CustomBot {
  final int id;
  String name;
  String repoUrl;
  String branch;
  String language;
  String startupScript;
  int port;
  String? hostname;
  List<String> envKeys;
  String status;
  String? statusMessage;
  String createdAt;

  CustomBot({
    required this.id,
    required this.name,
    required this.repoUrl,
    required this.branch,
    required this.language,
    required this.startupScript,
    required this.port,
    this.hostname,
    required this.envKeys,
    required this.status,
    this.statusMessage,
    required this.createdAt,
  });

  factory CustomBot.fromJson(Map<String, dynamic> j) => CustomBot(
        id: j['id'],
        name: j['name'] ?? 'Custom Bot',
        repoUrl: j['repo_url'] ?? '',
        branch: j['branch'] ?? 'main',
        language: j['language'] ?? 'python',
        startupScript: j['startup_script'] ?? '',
        port: j['port'] ?? 8000,
        hostname: j['hostname'],
        envKeys: List<String>.from(j['env_keys'] ?? const []),
        status: j['status'] ?? 'deploying',
        statusMessage: j['status_message'],
        createdAt: j['created_at'] ?? '',
      );
}

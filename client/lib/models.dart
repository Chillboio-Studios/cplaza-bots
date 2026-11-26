import 'dart:convert';

class BotUser {
  final int id;
  final String username;
  final String plan;
  BotUser({required this.id, required this.username, this.plan = 'free'});
  factory BotUser.fromJson(Map<String, dynamic> j) =>
      BotUser(id: j['id'], username: j['username'], plan: j['plan'] ?? 'free');
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

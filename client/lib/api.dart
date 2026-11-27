import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final String message;
  final int statusCode;
  ApiException(this.message, this.statusCode);
  @override
  String toString() => message;
}

class ApiClient {
  // Production API. For local dev use http://localhost:3000 (Windows/web),
  // http://10.0.2.2:3000 (Android emulator), or your LAN IP (physical device).
  static const String baseUrl = 'https://botapi.creatorplaza.nl';

  String? _token;
  static const String _tokenFile = '.creatorplaza_token';

  Future<void> loadToken() async {
    if (kIsWeb) return;
    try {
      final f = File(_tokenFile);
      if (await f.exists()) {
        _token = (await f.readAsString()).trim();
        if (_token!.isEmpty) _token = null;
      }
    } catch (_) {}
  }

  Future<void> _saveToken(String token) async {
    _token = token;
    if (kIsWeb) return;
    try {
      await File(_tokenFile).writeAsString(token);
    } catch (_) {}
  }

  Future<void> clearToken() async {
    _token = null;
    if (kIsWeb) return;
    try {
      final f = File(_tokenFile);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  Future<dynamic> _request(String method, String path,
      {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('$baseUrl$path');
    http.Response res;
    final encoded = body == null ? null : jsonEncode(body);
    switch (method) {
      case 'GET':
        res = await http.get(uri, headers: _headers);
        break;
      case 'POST':
        res = await http.post(uri, headers: _headers, body: encoded);
        break;
      case 'PUT':
        res = await http.put(uri, headers: _headers, body: encoded);
        break;
      case 'DELETE':
        res = await http.delete(uri, headers: _headers);
        break;
      default:
        throw ApiException('Unsupported method', 0);
    }
    dynamic data;
    try {
      data = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {
      data = null;
    }
    if (res.statusCode >= 400) {
      throw ApiException(data?['error'] ?? 'Request failed (${res.statusCode})',
          res.statusCode);
    }
    return data;
  }

  Future<Map<String, dynamic>> register(String username, String password) async {
    final data = await _request('POST', '/api/auth/register',
        body: {'username': username, 'password': password});
    await _saveToken(data['token']);
    return {'user': data['user']};
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final data = await _request('POST', '/api/auth/login',
        body: {'username': username, 'password': password});
    await _saveToken(data['token']);
    return {'user': data['user']};
  }

  Future<void> logout() async {
    try {
      await _request('POST', '/api/auth/logout');
    } catch (_) {}
    await clearToken();
  }

  Future<Map<String, dynamic>?> me() async {
    try {
      final data = await _request('GET', '/api/me');
      return {'user': data['user']};
    } on ApiException catch (e) {
      if (e.statusCode == 401 ||
          (e.statusCode == 403 && e.message == 'Account suspended')) {
        await clearToken();
        return null;
      }
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> listBots() async {
    final data = await _request('GET', '/api/bots');
    return List<Map<String, dynamic>>.from(data['bots']);
  }

  Future<Map<String, dynamic>> getBot(int id) async {
    final data = await _request('GET', '/api/bots/$id');
    return data['bot'];
  }

  Future<Map<String, dynamic>> createBot(
      String name, String token, Map<String, dynamic> config) async {
    final data = await _request('POST', '/api/bots',
        body: {'name': name, 'token': token, 'config': config});
    return data['bot'];
  }

  Future<Map<String, dynamic>> updateBot(int id,
      {String? name, String? token, Map<String, dynamic>? config}) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (token != null) body['token'] = token;
    if (config != null) body['config'] = config;
    final data = await _request('PUT', '/api/bots/$id', body: body);
    return data['bot'];
  }

  Future<void> deleteBot(int id) async {
    await _request('DELETE', '/api/bots/$id');
  }

  Future<String> deployBot(int id, {String action = 'start'}) async {
    final data =
        await _request('POST', '/api/bots/$id/deploy', body: {'action': action});
    return data['status'] ?? 'online';
  }

  // ---------- sharing ----------

  Future<Map<String, dynamic>> shareBot(int id) async {
    final data = await _request('POST', '/api/bots/$id/share');
    return {'code': data['code'], 'url': data['url']};
  }

  Future<List<Map<String, dynamic>>> listShares(int id) async {
    final data = await _request('GET', '/api/bots/$id/shares');
    return List<Map<String, dynamic>>.from(data['shares']);
  }

  Future<void> deleteShare(String code) async {
    await _request('DELETE', '/api/shares/$code');
  }

  /// Accepts a full share URL or a raw code; returns {name, config}.
  Future<Map<String, dynamic>> fetchSharedConfig(String input) async {
    var code = input.trim();
    final m = RegExp(r'/share/([A-Za-z0-9_-]+)').firstMatch(code);
    if (m != null) code = m.group(1)!;
    final data = await _request('GET', '/api/share/$code');
    return {'name': data['name'], 'config': decodeConfigForShare(data['config'])};
  }

  // ---------- custom bots (premium) ----------

  Future<List<Map<String, dynamic>>> listCustomBots() async {
    final data = await _request('GET', '/api/custom-bots');
    return List<Map<String, dynamic>>.from(data['bots']);
  }

  Future<Map<String, dynamic>> getCustomBot(int id) async {
    final data = await _request('GET', '/api/custom-bots/$id');
    return data['bot'];
  }

  /// fields: name, repo_url, branch, language, startup_script, port,
  /// domain or subdomain, env {KEY: VALUE}
  Future<Map<String, dynamic>> createCustomBot(
      Map<String, dynamic> fields) async {
    final data = await _request('POST', '/api/custom-bots', body: fields);
    return data['bot'];
  }

  Future<Map<String, dynamic>> updateCustomBot(
      int id, Map<String, dynamic> fields) async {
    final data = await _request('PUT', '/api/custom-bots/$id', body: fields);
    return data['bot'];
  }

  Future<void> deleteCustomBot(int id) async {
    await _request('DELETE', '/api/custom-bots/$id');
  }

  Future<void> restartCustomBot(int id) async {
    await _request('POST', '/api/custom-bots/$id/restart');
  }

  Future<Map<String, dynamic>> customBotLogs(int id,
      {int tail = 200}) async {
    return await _request('GET', '/api/custom-bots/$id/logs?tail=$tail');
  }

  Future<Map<String, dynamic>> customBotStatus(int id) async {
    return await _request('GET', '/api/custom-bots/$id/status');
  }
}

Map<String, dynamic> decodeConfigForShare(dynamic raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is String && raw.isNotEmpty) {
    try {
      final d = jsonDecode(raw);
      if (d is Map<String, dynamic>) return d;
    } catch (_) {}
  }
  return {};
}

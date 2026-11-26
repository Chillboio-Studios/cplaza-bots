import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Self-updater for Windows/Linux desktop builds.
/// Checks GitHub releases on Chillboio-Studios/creatorplaza-bots, downloads
/// the platform asset, then hands off to a helper script that swaps files
/// and relaunches after we exit.
class AppUpdater {
  static const repo = 'Chillboio-Studios/creatorplaza-bots';
  static const appVersion = '1.0.0'; // keep in sync with pubspec.yaml

  static bool get supported => Platform.isWindows || Platform.isLinux;

  static String get _assetName => Platform.isWindows
      ? 'creatorplaza-bots-windows.zip'
      : 'creatorplaza-bots-linux.tar.gz';

  static String get _exeName => Platform.isWindows
      ? 'creatorplaza_bots.exe'
      : 'creatorplaza_bots';

  static Directory? _staged;

  /// Returns the latest release tag if it's newer than the running build.
  static Future<String?> checkForUpdate() async {
    try {
      final res = await http
          .get(Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
              headers: {'User-Agent': 'creatorplaza-bots/$appVersion'})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String? ?? '').replaceFirst(RegExp('^v'), '');
      final assets = (data['assets'] as List? ?? [])
          .map((a) => a['name'] as String? ?? '')
          .toList();
      if (!_isNewer(tag, appVersion) || !assets.contains(_assetName)) return null;
      return tag;
    } catch (_) {
      return null;
    }
  }

  /// Downloads and extracts the release asset into a temp dir.
  /// [onProgress] gets 0.0–1.0.
  static Future<void> downloadUpdate(String tag,
      {void Function(double)? onProgress}) async {
    final meta = await http
        .get(Uri.parse('https://api.github.com/repos/$repo/releases/tags/v$tag'),
            headers: {'User-Agent': 'creatorplaza-bots/$appVersion'})
        .timeout(const Duration(seconds: 15));
    if (meta.statusCode != 200) throw Exception('Release lookup failed');
    final data = jsonDecode(meta.body) as Map<String, dynamic>;
    String? url;
    for (final a in data['assets'] as List? ?? []) {
      if (a['name'] == _assetName) url = a['browser_download_url'] as String?;
    }
    if (url == null) throw Exception('No $_assetName in release v$tag');

    final client = http.Client();
    final res = await client.send(http.Request('GET', Uri.parse(url))
      ..headers['User-Agent'] = 'creatorplaza-bots/$appVersion');
    if (res.statusCode != 200) {
      client.close();
      throw Exception('Download failed (${res.statusCode})');
    }

    final total = res.contentLength ?? 0;
    final tmp = await Directory.systemTemp.createTemp('cp_update');
    final archive = File('${tmp.path}${Platform.isWindows ? '.zip' : '.tar.gz'}');
    final sink = archive.openWrite();
    var received = 0;
    await for (final chunk in res.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
    }
    await sink.close();
    client.close();

    final extractDir = Directory('${tmp.path}/staged');
    await extractDir.create();
    final tarRes = await Process.run('tar',
        ['-xf', archive.path, '-C', extractDir.path]);
    if (tarRes.exitCode != 0) {
      throw Exception('Extract failed: ${tarRes.stderr}');
    }
    _staged = extractDir;
  }

  /// Writes a helper script next to the executable, launches it detached,
  /// then exits — the script waits for us to die, swaps files, relaunches.
  static Future<void> applyAndRestart() async {
    final staged = _staged;
    if (staged == null) return;
    final exePath = Platform.resolvedExecutable;
    final installDir = File(exePath).parent.path;
    final helperDir = File(exePath).parent.parent.path;
    final sep = Platform.pathSeparator;

    if (Platform.isWindows) {
      final bat = File('$helperDir${sep}apply_update.bat');
      await bat.writeAsString('''@echo off
setlocal
timeout /t 3 /nobreak >nul
robocopy "${staged.path}" "$installDir" /MIR /NFL /NDL /NJH /NJS >nul
start "" "$installDir\\$_exeName"
del "%~f0"
''');
      await Process.start('cmd', ['/c', 'start', '', bat.path],
          mode: ProcessStartMode.detached, runInShell: true);
    } else {
      final sh = File('$helperDir${sep}apply_update.sh');
      await sh.writeAsString('''#!/bin/sh
sleep 3
cp -rf "${staged.path}/." "$installDir/"
chmod +x "$installDir/$_exeName"
cd "$installDir" && nohup ./$_exeName >/dev/null 2>&1 &
rm -f "\$0"
''');
      await Process.run('chmod', ['+x', sh.path]);
      await Process.start('sh', [sh.path],
          mode: ProcessStartMode.detached, runInShell: true);
    }
    exit(0);
  }

  static bool _isNewer(String latest, String current) {
    List<int> parse(String v) => v
        .split(RegExp('[^0-9]+'))
        .where((s) => s.isNotEmpty)
        .map(int.parse)
        .toList();
    final a = parse(latest), b = parse(current);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}

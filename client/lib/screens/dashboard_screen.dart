import 'package:flutter/material.dart';
import '../api.dart';
import '../models.dart';
import '../updater.dart';
import 'editor_screen.dart';
import 'custom_bots_screen.dart';

class DashboardScreen extends StatefulWidget {
  final ApiClient api;
  final BotUser user;
  final VoidCallback onLogout;
  const DashboardScreen(
      {super.key,
      required this.api,
      required this.user,
      required this.onLogout});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Bot> _bots = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _checkForUpdate();
  }

  Future<void> _checkForUpdate() async {
    if (!AppUpdater.supported) return;
    final latest = await AppUpdater.checkForUpdate();
    if (latest == null || !mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Update available'),
        content: Text('CreatorPlaza Bots v$latest is ready to install.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Later')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Update')),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    var progress = 0.0;
    var finished = false;
    String? error;
    var started = false;
    var open = true;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          if (!started) {
            started = true;
            AppUpdater.downloadUpdate(latest, onProgress: (p) {
              progress = p;
              if (open) setDlg(() {});
            }).then((_) {
              finished = true;
              if (open) setDlg(() {});
            }).catchError((e) {
              error = e.toString();
              finished = true;
              if (open) setDlg(() {});
            });
          }
          return AlertDialog(
            title: const Text('Downloading update'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!finished)
                  Column(
                    children: [
                      LinearProgressIndicator(
                          value: progress > 0 ? progress : null),
                      const SizedBox(height: 8),
                      Text('${(progress * 100).toStringAsFixed(0)}%'),
                    ],
                  )
                else if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red))
                else
                  const Text('Ready — restart to finish updating.'),
              ],
            ),
            actions: [
              if (finished && error == null)
                ElevatedButton(
                  onPressed: AppUpdater.applyAndRestart,
                  child: const Text('Restart now'),
                )
              else if (finished)
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'))
              else
                const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          );
        },
      ),
    ).whenComplete(() => open = false);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await widget.api.listBots();
      setState(() => _bots = raw.map(Bot.fromJson).toList());
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'online':
        return Colors.green;
      case 'error':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  Future<void> _createBot() async {
    final nameCtrl = TextEditingController();
    final tokenCtrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Bot'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Bot Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: tokenCtrl,
              decoration: const InputDecoration(
                  labelText: 'Discord Bot Token',
                  hintText: 'Paste token from Discord Developer Portal'),
            ),
            const SizedBox(height: 12),
            const Text(
              'You can add commands and actions after creating.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create')),
        ],
      ),
    );
    if (result != true || !mounted) return;
    if (nameCtrl.text.trim().isEmpty || tokenCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Name and token are required')));
      return;
    }
    try {
      final config = {
        'modules': <dynamic>[],
        'settings': {
          'presence': {'status': 'online', 'type': 'playing', 'activity': ''}
        }
      };
      final bot = await widget.api
          .createBot(nameCtrl.text.trim(), tokenCtrl.text.trim(), config);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                EditorScreen(api: widget.api, bot: Bot.fromJson(bot))),
      );
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _importBot() async {
    final linkCtrl = TextEditingController();
    final fetched = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Shared Bot'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Paste a CreatorPlaza share link:'),
            const SizedBox(height: 12),
            TextField(
              controller: linkCtrl,
              decoration: const InputDecoration(
                  labelText: 'Share link',
                  hintText: 'http://.../share/abc123'),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              try {
                final data =
                    await widget.api.fetchSharedConfig(linkCtrl.text);
                if (ctx.mounted) Navigator.pop(ctx, data);
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text(e.toString())));
                }
              }
            },
            child: const Text('Fetch'),
          ),
        ],
      ),
    );
    if (fetched == null || !mounted) return;

    final nameCtrl =
        TextEditingController(text: fetched['name']?.toString() ?? 'Imported Bot');
    final tokenCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name your bot'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Bot name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: tokenCtrl,
              decoration: const InputDecoration(
                  labelText: 'Discord Bot Token (optional)',
                  hintText: 'Add later in the editor'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Import')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final bot = await widget.api.createBot(
        nameCtrl.text.trim().isEmpty ? 'Imported Bot' : nameCtrl.text.trim(),
        tokenCtrl.text.trim(),
        Map<String, dynamic>.from(fetched['config'] as Map),
      );
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                EditorScreen(api: widget.api, bot: Bot.fromJson(bot))),
      );
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _openEditor(Bot bot) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => EditorScreen(api: widget.api, bot: bot)),
    );
    _load();
  }

  Future<void> _botAction(Bot bot, String action) async {
    try {
      if (action == 'delete') {
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete ${bot.name}?'),
            content: const Text('This cannot be undone.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Delete')),
            ],
          ),
        );
        if (confirm != true) return;
        await widget.api.deleteBot(bot.id);
      } else {
        await widget.api.deployBot(bot.id, action: action);
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CreatorPlaza Bots'),
        actions: [
          IconButton(
            tooltip: 'Custom bots (premium)',
            icon: const Icon(Icons.hub_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    CustomBotsScreen(api: widget.api, user: widget.user),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Import shared bot',
            icon: const Icon(Icons.upload_outlined),
            onPressed: _importBot,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('@${widget.user.username}'),
                  if (widget.user.plan == 'premium') ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFAA81A),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text('PREMIUM',
                          style: TextStyle(
                              color: Colors.black,
                              fontSize: 10,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ],
              ),
            ),
          ),
          IconButton(icon: const Icon(Icons.logout), onPressed: widget.onLogout),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createBot,
        icon: const Icon(Icons.add),
        label: const Text('New Bot'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 8),
                      ElevatedButton(
                          onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                )
              : _bots.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.smart_toy_outlined,
                              size: 80, color: Colors.grey[600]),
                          const SizedBox(height: 12),
                          Text('No bots yet',
                              style: TextStyle(color: Colors.grey[400])),
                          const SizedBox(height: 4),
                          Text('Tap "New Bot" to build your first bot',
                              style:
                                  TextStyle(color: Colors.grey[500], fontSize: 12)),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _bots.length,
                        itemBuilder: (context, i) {
                          final bot = _bots[i];
                          return Card(
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: _statusColor(bot.status)
                                    .withOpacity(0.2),
                                child: Icon(Icons.smart_toy,
                                    color: _statusColor(bot.status)),
                              ),
                              title: Text(bot.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                '${(bot.modules.length)} module(s) • ${bot.status}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: PopupMenuButton<String>(
                                onSelected: (a) => _botAction(bot, a),
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                      value: 'start', child: Text('Deploy')),
                                  const PopupMenuItem(
                                      value: 'stop', child: Text('Stop')),
                                  const PopupMenuItem(
                                      value: 'restart',
                                      child: Text('Restart')),
                                  const PopupMenuItem(
                                      value: 'delete', child: Text('Delete')),
                                ],
                              ),
                              onTap: () => _openEditor(bot),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

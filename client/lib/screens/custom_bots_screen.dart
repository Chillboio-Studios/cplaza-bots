import 'package:flutter/material.dart';
import '../api.dart';
import '../models.dart';
import 'custom_bot_form.dart';

/// Premium custom bots: user-supplied GitHub repos deployed as pods.
class CustomBotsScreen extends StatefulWidget {
  final ApiClient api;
  final BotUser user;
  const CustomBotsScreen({super.key, required this.api, required this.user});

  @override
  State<CustomBotsScreen> createState() => _CustomBotsScreenState();
}

class _CustomBotsScreenState extends State<CustomBotsScreen> {
  List<CustomBot> _bots = [];
  bool _loading = true;
  String? _error;

  bool get _allowed =>
      widget.user.plan == 'premium' || widget.user.role == 'admin';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await widget.api.listCustomBots();
      setState(() => _bots = raw.map(CustomBot.fromJson).toList());
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
      case 'deploying':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  Future<void> _openForm([CustomBot? bot]) async {
    CustomBot? editing = bot;
    if (bot != null) {
      // fetch full record (startup_script isn't in list responses)
      try {
        editing = CustomBot.fromJson(await widget.api.getCustomBot(bot.id));
      } catch (_) {}
    }
    if (!mounted) return;
    final result = await Navigator.push<CustomBot>(
      context,
      MaterialPageRoute(
        builder: (_) => CustomBotFormScreen(api: widget.api, bot: editing),
      ),
    );
    if (result != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result.status == 'error'
                ? 'Deployed with errors — check logs'
                : 'Bot deployed (status: ${result.status})')));
      }
      _load();
    }
  }

  Future<void> _botAction(CustomBot bot, String action) async {
    try {
      switch (action) {
        case 'logs':
          await showDialog(
            context: context,
            builder: (_) => _LogsDialog(api: widget.api, bot: bot),
          );
          return;
        case 'restart':
          await widget.api.restartCustomBot(bot.id);
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Restarting…')));
          }
          break;
        case 'edit':
          await _openForm(bot);
          return;
        case 'delete':
          final confirm = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('Delete ${bot.name}?'),
              content: const Text(
                  'The pod, service, domain and SSL certificate will be removed. This cannot be undone.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Delete')),
              ],
            ),
          );
          if (confirm != true) return;
          await widget.api.deleteCustomBot(bot.id);
          break;
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
      appBar: AppBar(title: const Text('Custom Bots')),
      floatingActionButton: _allowed
          ? FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.add),
              label: const Text('New Custom Bot'),
            )
          : null,
      body: !_allowed
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, size: 64, color: Colors.grey[600]),
                  const SizedBox(height: 12),
                  Text('Premium feature',
                      style: TextStyle(color: Colors.grey[400], fontSize: 18)),
                  const SizedBox(height: 4),
                  Text('Deploy bots from your own GitHub repositories',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                ],
              ),
            )
          : _loading
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
                              Icon(Icons.hub_outlined,
                                  size: 80, color: Colors.grey[600]),
                              const SizedBox(height: 12),
                              Text('No custom bots yet',
                                  style: TextStyle(color: Colors.grey[400])),
                              const SizedBox(height: 4),
                              Text('Deploy a bot from a public GitHub repo',
                                  style: TextStyle(
                                      color: Colors.grey[500], fontSize: 12)),
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
                                    child: Icon(Icons.hub,
                                        color: _statusColor(bot.status)),
                                  ),
                                  title: Text(bot.name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  subtitle: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${bot.language} • port ${bot.port}'
                                        '${bot.hostname != null ? ' • ${bot.hostname}' : ''}',
                                        style: const TextStyle(fontSize: 12),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (bot.statusMessage != null)
                                        Text(bot.statusMessage!,
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.red)),
                                    ],
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: _statusColor(bot.status)
                                              .withOpacity(0.15),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Text(bot.status,
                                            style: TextStyle(
                                                color:
                                                    _statusColor(bot.status),
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold)),
                                      ),
                                      PopupMenuButton<String>(
                                        onSelected: (a) =>
                                            _botAction(bot, a),
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                              value: 'logs',
                                              child: Text('Logs')),
                                          PopupMenuItem(
                                              value: 'restart',
                                              child: Text('Restart')),
                                          PopupMenuItem(
                                              value: 'edit',
                                              child: Text('Edit')),
                                          PopupMenuItem(
                                              value: 'delete',
                                              child: Text('Delete')),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
    );
  }
}

class _LogsDialog extends StatefulWidget {
  final ApiClient api;
  final CustomBot bot;
  const _LogsDialog({required this.api, required this.bot});

  @override
  State<_LogsDialog> createState() => _LogsDialogState();
}

class _LogsDialogState extends State<_LogsDialog> {
  String _logs = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.customBotLogs(widget.bot.id);
      setState(() => _logs = data['logs']?.toString() ?? '');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Logs — ${widget.bot.name}'),
      content: SizedBox(
        width: 560,
        height: 360,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!))
                : SingleChildScrollView(
                    child: SelectableText(
                      _logs.isEmpty ? '(no logs yet)' : _logs,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
      ),
      actions: [
        TextButton(onPressed: _fetch, child: const Text('Refresh')),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ],
    );
  }
}

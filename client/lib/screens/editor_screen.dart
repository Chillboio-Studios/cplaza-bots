import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../api.dart';
import '../models.dart';

const _uuid = Uuid();

const _triggerTypes = {
  'command': 'Slash Command',
  'message': 'Message Contains',
  'join': 'Member Join',
  'reaction': 'Reaction Added',
};

const _actionTypes = {
  'send': 'Send Message',
  'embed': 'Send Embed',
  'react': 'Add Reaction',
  'dm': 'Direct Message',
  'addrole': 'Add Role',
  'removerole': 'Remove Role',
  'kick': 'Kick Member',
  'ban': 'Ban Member',
  'timeout': 'Timeout Member',
};

const _argTypes = {
  'string': 'Text',
  'integer': 'Whole number',
  'number': 'Decimal number',
  'boolean': 'True/False',
  'user': 'User',
  'channel': 'Channel',
  'role': 'Role',
};

const _conditionTypes = {
  'role': 'Has Role',
  'channel': 'In Channel',
  'permission': 'Has Permission',
};

const _variableHint =
    'Variables: {{user}} {{username}} {{server}} {{channel}} {{message}} {{args}} {{memberCount}} — slash command options are usable as {{option_name}}';

class EditorScreen extends StatefulWidget {
  final ApiClient api;
  final Bot bot;
  const EditorScreen({super.key, required this.api, required this.bot});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late Map<String, dynamic> _config;
  late TextEditingController _nameCtrl;
  late TextEditingController _tokenCtrl;
  bool _saving = false;
  bool _deploying = false;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _config = Map<String, dynamic>.from(widget.bot.config);
    _config.putIfAbsent('modules', () => <dynamic>[]);
    _config.putIfAbsent('settings', () => <String, dynamic>{});
    _nameCtrl = TextEditingController(text: widget.bot.name);
    _tokenCtrl = TextEditingController(text: widget.bot.token);
  }

  List<dynamic> get _modules => _config['modules'] as List;

  Future<void> _save({bool pop = false}) async {
    setState(() => _saving = true);
    try {
      final token = _tokenCtrl.text.trim();
      final updated = await widget.api.updateBot(
        widget.bot.id,
        name: _nameCtrl.text.trim(),
        token: token.isEmpty || token.contains('•') ? null : token,
        config: _config,
      );
      widget.bot.name = updated['name'];
      widget.bot.config = decodeConfig(updated['config']);
      widget.bot.status = updated['status'] ?? widget.bot.status;
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved')));
      if (pop) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deploy(String action) async {
    setState(() => _deploying = true);
    try {
      await _save();
      final status = await widget.api.deployBot(widget.bot.id, action: action);
      widget.bot.status = status;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(action == 'stop' ? 'Bot stopped' : 'Bot deployed')));
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _deploying = false);
    }
  }

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      final res = await widget.api.shareBot(widget.bot.id);
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Share Bot Config'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Anyone with this link can import a copy of this bot\'s setup. The bot token is NOT included.'),
              const SizedBox(height: 12),
              SelectableText(res['url'] as String,
                  style: const TextStyle(fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy Link'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: res['url'] as String));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Link copied')));
              },
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: SizedBox(
          width: 220,
          child: TextFormField(
            controller: _nameCtrl,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(
                isDense: true, border: InputBorder.none, hintText: 'Bot name'),
          ),
        ),
        actions: [
          if (widget.bot.status == 'online')
            TextButton.icon(
              onPressed: _deploying ? null : () => _deploy('stop'),
              icon: const Icon(Icons.stop_circle_outlined, color: Colors.red),
              label: const Text('Stop'),
            ),
          TextButton.icon(
            onPressed: _deploying ? null : () => _deploy('restart'),
            icon: const Icon(Icons.play_circle_outline, color: Colors.green),
            label: Text(widget.bot.status == 'online' ? 'Restart' : 'Deploy'),
          ),
          IconButton(
            tooltip: 'Share config link',
            onPressed: _sharing ? null : _share,
            icon: _sharing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.share_outlined),
          ),
          IconButton(
            tooltip: 'Save',
            onPressed: _saving ? null : () => _save(pop: true),
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _buildSettings(),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('Modules',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('${_modules.length}',
                  style: TextStyle(color: Colors.grey[500])),
            ],
          ),
          const SizedBox(height: 8),
          ..._modules.asMap().entries.map((e) => _buildModuleCard(e.key, e.value)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _addModule,
            icon: const Icon(Icons.add),
            label: const Text('Add Module'),
          ),
          const SizedBox(height: 24),
          Text(_variableHint,
              style: TextStyle(fontSize: 11, color: Colors.grey[500])),
        ],
      ),
    );
  }

  // ---------- settings ----------

  Widget _buildSettings() {
    final settings = Map<String, dynamic>.from(_config['settings'] ?? {});
    final presence = Map<String, dynamic>.from(settings['presence'] ?? {});
    void updatePresence(String key, dynamic value) {
      presence[key] = value;
      settings['presence'] = presence;
      _config['settings'] = settings;
      setState(() {});
    }

    return Card(
      child: ExpansionTile(
        initiallyExpanded: true,
        leading: const Icon(Icons.settings),
        title: const Text('Bot Settings'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Presence',
                    style: TextStyle(color: Colors.grey[400], fontSize: 13)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: presence['status'] ?? 'online',
                        decoration: const InputDecoration(labelText: 'Status'),
                        items: const [
                          DropdownMenuItem(value: 'online', child: Text('Online')),
                          DropdownMenuItem(value: 'idle', child: Text('Idle')),
                          DropdownMenuItem(value: 'dnd', child: Text('Do Not Disturb')),
                          DropdownMenuItem(value: 'invisible', child: Text('Invisible')),
                        ],
                        onChanged: (v) => updatePresence('status', v),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: presence['type'] ?? 'playing',
                        decoration: const InputDecoration(labelText: 'Activity'),
                        items: const [
                          DropdownMenuItem(value: 'playing', child: Text('Playing')),
                          DropdownMenuItem(value: 'listening', child: Text('Listening to')),
                          DropdownMenuItem(value: 'watching', child: Text('Watching')),
                          DropdownMenuItem(value: 'competing', child: Text('Competing in')),
                        ],
                        onChanged: (v) => updatePresence('type', v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: presence['activity'] ?? '',
                  decoration: const InputDecoration(
                      labelText: 'Activity text (optional)'),
                  onChanged: (v) => updatePresence('activity', v),
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 8),
                Text('Bot Token',
                    style: TextStyle(color: Colors.grey[400], fontSize: 13)),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _tokenCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Discord Bot Token',
                    hintText: 'Leave masked value to keep current token',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- modules ----------

  void _addModule() {
    setState(() {
      _modules.add({
        'id': _uuid.v4(),
        'enabled': true,
        'trigger': {'type': 'command', 'command': '', 'description': ''},
        'conditions': <dynamic>[],
        'actions': <dynamic>[],
      });
    });
  }

  void _removeModule(int index) {
    setState(() => _modules.removeAt(index));
  }

  Widget _buildModuleCard(int index, dynamic module) {
    final m = Map<String, dynamic>.from(module as Map);
    _modules[index] = m;
    final trigger = Map<String, dynamic>.from(m['trigger'] ?? {});
    m['trigger'] = trigger;
    final conditions = (m['conditions'] as List?) ?? [];
    m['conditions'] = conditions;
    final actions = (m['actions'] as List?) ?? [];
    m['actions'] = actions;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _triggerLabel(trigger),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Switch(
                  value: m['enabled'] != false,
                  onChanged: (v) {
                    setState(() => m['enabled'] = v);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => _removeModule(index),
                ),
              ],
            ),
            const Divider(height: 16),
            _buildTriggerEditor(trigger),
            const SizedBox(height: 8),
            _sectionHeader(Icons.filter_alt, 'Conditions (optional)'),
            ..._buildConditions(conditions),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () {
                setState(() => conditions.add({'type': 'role', 'value': ''}));
              },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add condition'),
            ),
            const SizedBox(height: 8),
            _sectionHeader(Icons.bolt, 'Actions'),
            ...actions.asMap().entries.map((e) => _buildActionCard(e.key, e.value, actions, trigger)),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: () => _pickAction(actions),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add block'),
            ),
          ],
        ),
      ),
    );
  }

  String _triggerLabel(Map<String, dynamic> trigger) {
    final type = _triggerTypes[trigger['type']] ?? 'Trigger';
    final extra = trigger['type'] == 'command'
        ? (trigger['command']?.toString().isNotEmpty == true
            ? ' /${trigger['command']}'
            : '')
        : trigger['type'] == 'message' &&
                trigger['keyword']?.toString().isNotEmpty == true
            ? ' "${trigger['keyword']}"'
            : trigger['type'] == 'reaction' &&
                    trigger['emoji']?.toString().isNotEmpty == true
                ? ' ${trigger['emoji']}'
                : '';
    return '$type$extra';
  }

  Widget _buildArgsEditor(Map<String, dynamic> trigger) {
    final args = (trigger['args'] as List?) ?? [];
    trigger['args'] = args;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.tune, size: 16, color: Colors.grey[400]),
          const SizedBox(width: 6),
          Text('Arguments',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[300])),
          const Spacer(),
          Text('${args.length}/25',
              style: TextStyle(fontSize: 11, color: Colors.grey[500])),
        ]),
        const SizedBox(height: 6),
        ...args.asMap().entries.map((e) {
          final i = e.key;
          final a = Map<String, dynamic>.from(e.value as Map);
          args[i] = a;
          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF383A40).withOpacity(0.4),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              children: [
                Row(children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      initialValue: a['name'] ?? '',
                      decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Name',
                          hintText: 'e.g. user, reason'),
                      onChanged: (v) => a['name'] = v,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      initialValue: _argTypes.containsKey(a['type'])
                          ? a['type']
                          : 'string',
                      isDense: true,
                      decoration: const InputDecoration(labelText: 'Type'),
                      items: _argTypes.entries
                          .map((en) => DropdownMenuItem(
                              value: en.key, child: Text(en.value)))
                          .toList(),
                      onChanged: (v) {
                        a['type'] = v;
                        setState(() {});
                      },
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => args.removeAt(i)),
                  ),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: a['description'] ?? '',
                      decoration: const InputDecoration(
                          isDense: true, labelText: 'Description (optional)'),
                      onChanged: (v) => a['description'] = v,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('Required', style: TextStyle(fontSize: 12)),
                    selected: a['required'] == true,
                    onSelected: (v) => setState(() => a['required'] = v),
                  ),
                ]),
              ],
            ),
          );
        }),
        TextButton.icon(
          onPressed: args.length >= 25
              ? null
              : () => setState(() => args.add(
                  {'name': '', 'type': 'string', 'description': '', 'required': false})),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add argument'),
        ),
      ],
    );
  }

  Widget _buildTriggerEditor(Map<String, dynamic> trigger) {
    final type = trigger['type'] ?? 'command';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _triggerTypes.containsKey(type) ? type : 'command',
          decoration: const InputDecoration(labelText: 'When this happens'),
          items: _triggerTypes.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: (v) {
            trigger['type'] = v;
            // reset trigger-specific fields
            trigger.remove('command');
            trigger.remove('description');
            trigger.remove('keyword');
            trigger.remove('emoji');
            if (v == 'command') {
              trigger['command'] = '';
              trigger['description'] = '';
            }
            setState(() {});
          },
        ),
        const SizedBox(height: 8),
        if (type == 'command') ...[
          TextFormField(
            initialValue: trigger['command'] ?? '',
            decoration: const InputDecoration(
                labelText: 'Command name', hintText: 'e.g. hello'),
            onChanged: (v) => trigger['command'] = v,
          ),
          const SizedBox(height: 8),
          TextFormField(
            initialValue: trigger['description'] ?? '',
            decoration: const InputDecoration(
                labelText: 'Command description (shown in Discord)'),
            onChanged: (v) => trigger['description'] = v,
          ),
          const SizedBox(height: 12),
          _buildArgsEditor(trigger),
        ],
        if (type == 'message')
          TextFormField(
            initialValue: trigger['keyword'] ?? '',
            decoration: const InputDecoration(
                labelText: 'Keyword', hintText: 'Message must contain this'),
            onChanged: (v) => trigger['keyword'] = v,
          ),
        if (type == 'reaction')
          TextFormField(
            initialValue: trigger['emoji'] ?? '',
            decoration: const InputDecoration(
                labelText: 'Emoji (optional)',
                hintText: 'e.g. 👍 — leave empty for any'),
            onChanged: (v) => trigger['emoji'] = v,
          ),
        if (type == 'join')
          Text('Triggers when a member joins the server.',
              style: TextStyle(fontSize: 12, color: Colors.grey[500])),
      ],
    );
  }

  // ---------- conditions ----------

  Widget _sectionHeader(IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(children: [
        Icon(icon, size: 16, color: Colors.grey[400]),
        const SizedBox(width: 6),
        Text(title,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey[300])),
      ]),
    );
  }

  List<Widget> _buildConditions(List conditions) {
    return conditions.asMap().entries.map((e) {
      final i = e.key;
      final c = Map<String, dynamic>.from(e.value as Map);
      conditions[i] = c;
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                initialValue:
                    _conditionTypes.containsKey(c['type']) ? c['type'] : 'role',
                isDense: true,
                decoration: const InputDecoration(labelText: 'If'),
                items: _conditionTypes.entries
                    .map((en) =>
                        DropdownMenuItem(value: en.key, child: Text(en.value)))
                    .toList(),
                onChanged: (v) {
                  c['type'] = v;
                  setState(() {});
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: TextFormField(
                initialValue: c['value'] ?? '',
                decoration: InputDecoration(
                    isDense: true,
                    labelText: switch (c['type']) {
                      'channel' => 'Channel name or #',
                      'permission' => 'e.g. Administrator',
                      _ => 'Role name or ID',
                    }),
                onChanged: (v) => c['value'] = v,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() => conditions.removeAt(i)),
            ),
          ],
        ),
      );
    }).toList();
  }

  // ---------- actions ----------

  Future<void> _pickAction(List actions) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _actionTypes.entries
              .map((e) => ListTile(
                    leading: const Icon(Icons.add_box_outlined),
                    title: Text(e.value),
                    onTap: () => Navigator.pop(ctx, e.key),
                  ))
              .toList(),
        ),
      ),
    );
    if (picked != null) {
      setState(() => actions.add({'type': picked}));
    }
  }

  Widget _buildActionCard(int index, dynamic action, List actions,
      [Map<String, dynamic>? trigger]) {
    final a = Map<String, dynamic>.from(action as Map);
    actions[index] = a;
    final type = a['type'] ?? 'send';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF383A40).withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_actionIcon(type), size: 16, color: Color(0xFF5865F2)),
              const SizedBox(width: 6),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _actionTypes.containsKey(type) ? type : 'send',
                    isDense: true,
                    isExpanded: true,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600),
                    items: _actionTypes.entries
                        .map((e) => DropdownMenuItem(
                            value: e.key, child: Text(e.value)))
                        .toList(),
                    onChanged: (v) {
                      a.clear();
                      a['type'] = v;
                      setState(() {});
                    },
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(() => actions.removeAt(index)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ..._buildActionFields(a, trigger),
        ],
      ),
    );
  }

  IconData _actionIcon(String type) {
    switch (type) {
      case 'send':
        return Icons.chat_bubble_outline;
      case 'embed':
        return Icons.view_agenda_outlined;
      case 'react':
        return Icons.emoji_emotions_outlined;
      case 'dm':
        return Icons.mail_outline;
      case 'addrole':
        return Icons.person_add_alt;
      case 'removerole':
        return Icons.person_remove_alt_1;
      case 'kick':
        return Icons.exit_to_app;
      case 'ban':
        return Icons.gavel_outlined;
      case 'timeout':
        return Icons.timer_off_outlined;
      default:
        return Icons.bolt;
    }
  }

  List<Widget> _buildActionFields(Map<String, dynamic> a,
      [Map<String, dynamic>? trigger]) {
    // user-type argument names defined on this module's command trigger
    final userArgs = <String>[
      for (final arg in (trigger?['args'] as List? ?? const []))
        if (arg is Map && arg['type'] == 'user' &&
            (arg['name']?.toString().isNotEmpty ?? false))
          arg['name'].toString(),
    ];

    Widget targetPicker() {
      if (userArgs.isEmpty) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Add a "User" argument to the command trigger to pick a target here.',
            style: TextStyle(fontSize: 11, color: Colors.orange[300]),
          ),
        );
      }
      final current = userArgs.contains(a['targetArg']) ? a['targetArg'] : '';
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: DropdownButtonFormField<String>(
          initialValue: current.isEmpty ? '' : current,
          isDense: true,
          decoration: const InputDecoration(
              labelText: 'Target (who to moderate)'),
          items: [
            const DropdownMenuItem(
                value: '', child: Text('Command user (default)')),
            ...userArgs.map((n) =>
                DropdownMenuItem(value: n, child: Text('@$n'))),
          ],
          onChanged: (v) => a['targetArg'] = v ?? '',
        ),
      );
    }

    Widget tf(String key, String label,
            {String? hint, int maxLines = 1}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextFormField(
            initialValue: a[key]?.toString() ?? '',
            maxLines: maxLines,
            decoration: InputDecoration(
                isDense: true, labelText: label, hintText: hint),
            onChanged: (v) => a[key] = v,
          ),
        );

    switch (a['type']) {
      case 'send':
        return [
          tf('content', 'Message',
              hint: 'e.g. Hello {{user}}!', maxLines: 3),
          tf('channel', 'Channel (optional)', hint: 'name or # — default: current'),
        ];
      case 'embed':
        return [
          tf('title', 'Title'),
          tf('description', 'Description', maxLines: 3),
          Row(children: [
            Expanded(child: tf('color', 'Color', hint: '#5865F2')),
            const SizedBox(width: 8),
            Expanded(child: tf('footer', 'Footer')),
          ]),
          tf('channel', 'Channel (optional)', hint: 'name or # — default: current'),
        ];
      case 'react':
        return [tf('emoji', 'Emoji', hint: 'e.g. 👍')];
      case 'dm':
        return [
          tf('content', 'DM message', hint: 'e.g. Thanks for joining!', maxLines: 3)
        ];
      case 'addrole':
        return [tf('role', 'Role name or ID')];
      case 'removerole':
        return [tf('role', 'Role name or ID')];
      case 'kick':
        return [
          targetPicker(),
          tf('reason', 'Reason (optional)'),
        ];
      case 'ban':
        return [
          targetPicker(),
          tf('reason', 'Reason (optional)'),
        ];
      case 'timeout':
        return [
          targetPicker(),
          tf('minutes', 'Minutes', hint: '10'),
          tf('reason', 'Reason (optional)'),
        ];
      default:
        return [];
    }
  }
}

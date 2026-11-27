import 'package:flutter/material.dart';
import '../api.dart';
import '../models.dart';

/// Create or edit a premium custom bot: public GitHub repo -> own k8s pod.
class CustomBotFormScreen extends StatefulWidget {
  final ApiClient api;
  final CustomBot? bot; // null = create
  const CustomBotFormScreen({super.key, required this.api, this.bot});

  @override
  State<CustomBotFormScreen> createState() => _CustomBotFormScreenState();
}

class _CustomBotFormScreenState extends State<CustomBotFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _repo;
  late final TextEditingController _branch;
  late final TextEditingController _port;
  late final TextEditingController _subdomain;
  late final TextEditingController _domain;
  late final TextEditingController _script;
  late final TextEditingController _env;
  String _language = 'python';
  String _domainType = 'none'; // none | subdomain | custom
  bool _saving = false;

  static const _languages = ['python', 'nodejs', 'java', 'cpp'];

  @override
  void initState() {
    super.initState();
    final b = widget.bot;
    _name = TextEditingController(text: b?.name ?? '');
    _repo = TextEditingController(text: b?.repoUrl ?? '');
    _branch = TextEditingController(text: b?.branch ?? 'main');
    _port = TextEditingController(text: '${b?.port ?? 8000}');
    _subdomain = TextEditingController();
    _domain = TextEditingController();
    _script = TextEditingController(text: b?.startupScript ?? '');
    _env = TextEditingController();
    if (b != null) {
      _language = _languages.contains(b.language) ? b.language : 'python';
      if (b.hostname != null && b.hostname!.endsWith('.creatorplaza.nl')) {
        _domainType = 'subdomain';
        _subdomain.text =
            b.hostname!.split('.').first;
      } else if (b.hostname != null) {
        _domainType = 'custom';
        _domain.text = b.hostname!;
      }
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name, _repo, _branch, _port, _subdomain, _domain, _script, _env
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> _parseEnv() {
    final env = <String, String>{};
    for (final line in _env.text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      final i = t.indexOf('=');
      if (i <= 0) {
        throw const FormatException('Env lines must be KEY=VALUE');
      }
      env[t.substring(0, i).trim()] = t.substring(i + 1).trim();
    }
    return env;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final fields = <String, dynamic>{
        'name': _name.text.trim(),
        'repo_url': _repo.text.trim(),
        'branch': _branch.text.trim().isEmpty ? 'main' : _branch.text.trim(),
        'language': _language,
        'startup_script': _script.text.trim(),
        'port': int.tryParse(_port.text.trim()) ?? 8000,
        'domain': _domainType == 'custom' ? _domain.text.trim() : '',
        'subdomain':
            _domainType == 'subdomain' ? _subdomain.text.trim() : '',
      };
      final envText = _env.text.trim();
      if (envText.isNotEmpty || widget.bot == null) {
        fields['env'] = _parseEnv();
      }
      // editing: empty env box keeps existing vars (env key omitted)
      final bot = widget.bot == null
          ? await widget.api.createCustomBot(fields)
          : await widget.api.updateCustomBot(widget.bot!.id, fields);
      if (mounted) Navigator.pop(context, CustomBot.fromJson(bot));
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.bot != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Edit Custom Bot' : 'New Custom Bot')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (v) =>
                  (v == null || v.trim().length < 3) ? 'Required (min 3 chars)' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _repo,
              decoration: const InputDecoration(
                labelText: 'GitHub repository',
                hintText: 'https://github.com/owner/repo',
              ),
              validator: (v) => (v == null ||
                      !v.trim().startsWith('https://github.com/'))
                  ? 'Must be a github.com URL'
                  : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _branch,
                    decoration: const InputDecoration(labelText: 'Branch'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _language,
                    decoration: const InputDecoration(labelText: 'Language'),
                    items: _languages
                        .map((l) => DropdownMenuItem(value: l, child: Text(l)))
                        .toList(),
                    onChanged: (v) => setState(() => _language = v ?? 'python'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Port', hintText: '8000'),
              validator: (v) {
                final p = int.tryParse(v ?? '');
                return (p == null || p < 1024 || p > 65535)
                    ? '1024-65535'
                    : null;
              },
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              initialValue: _domainType,
              decoration: const InputDecoration(labelText: 'Domain'),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('None')),
                DropdownMenuItem(
                    value: 'subdomain',
                    child: Text('Subdomain (*.creatorplaza.nl)')),
                DropdownMenuItem(
                    value: 'custom', child: Text('Custom domain')),
              ],
              onChanged: (v) => setState(() => _domainType = v ?? 'none'),
            ),
            if (_domainType == 'subdomain') ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _subdomain,
                decoration: const InputDecoration(
                    labelText: 'Subdomain', hintText: 'mybot'),
                validator: (v) => (v == null ||
                        !RegExp(r'^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$')
                            .hasMatch(v.trim()))
                    ? 'Letters, numbers, dashes'
                    : null,
              ),
            ],
            if (_domainType == 'custom') ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _domain,
                decoration: const InputDecoration(
                    labelText: 'Domain',
                    hintText: 'bot.example.com',
                    helperText:
                        'Point its DNS at the cluster ingress for automatic SSL'),
                validator: (v) => (v == null ||
                        !RegExp(r'^([a-z0-9-]+\.)+[a-z]{2,}$')
                            .hasMatch(v.trim().toLowerCase()))
                    ? 'Invalid domain'
                    : null,
              ),
            ],
            const SizedBox(height: 20),
            TextFormField(
              controller: _script,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Startup script',
                hintText: 'e.g. pip install -r requirements.txt && python bot.py',
                alignLabelWithHint: true,
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _env,
              minLines: 2,
              maxLines: 6,
              decoration: InputDecoration(
                labelText: 'Environment variables',
                hintText: 'DISCORD_TOKEN=...\nAPI_KEY=...',
                alignLabelWithHint: true,
                helperText: widget.bot == null
                    ? 'One KEY=VALUE per line'
                    : 'One KEY=VALUE per line — leave empty to keep existing vars',
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.rocket_launch_outlined),
              label: Text(editing ? 'Save & Redeploy' : 'Deploy Bot'),
            ),
          ],
        ),
      ),
    );
  }
}

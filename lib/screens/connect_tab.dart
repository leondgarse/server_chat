import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../models/app_state.dart';
import '../widgets/theme_switch_button.dart';

class ConnectTab extends StatefulWidget {
  const ConnectTab({super.key});

  @override
  State<ConnectTab> createState() => _ConnectTabState();
}

class _ConnectTabState extends State<ConnectTab> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '22');
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  final _keyController  = TextEditingController();
  final List<_TunnelRow> _tunnelRows = [];

  // Saved named profiles  { name: {host,port,user,pass,key} }
  Map<String, Map<String, String>> _profiles = {};

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _userController.dispose();
    _passController.dispose();
    _keyController.dispose();
    for (final r in _tunnelRows) r.dispose();
    super.dispose();
  }

  // ─── Persistence ───────────────────────────────────────────────────────────

  Future<File> _getConfigFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/ssh_config.json');
  }

  Future<void> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();

    // Load last-used connection
    try {
      final file = await _getConfigFile();
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (mounted) {
          setState(() {
            _hostController.text = j['host'] ?? '';
            _portController.text = j['port'] ?? '22';
            _userController.text = j['user'] ?? '';
            _passController.text = j['pass'] ?? '';
            _keyController.text  = j['key']  ?? '';
            _loadTunnelRows(j['tunnels'] as String? ?? '');
          });
        }
      }
    } catch (_) {
      try {
        if (mounted) setState(() {
          _hostController.text = prefs.getString('host') ?? '';
          _portController.text = prefs.getString('port') ?? '22';
          _userController.text = prefs.getString('user') ?? '';
          _passController.text = prefs.getString('pass') ?? '';
          _keyController.text  = prefs.getString('key')  ?? '';
          _loadTunnelRows(prefs.getString('tunnels') ?? '');
        });
      } catch (_) {}
    }

    // Load named profiles
    try {
      final raw = prefs.getString('ssh_profiles');
      if (raw != null) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        if (mounted) {
          setState(() {
            _profiles = decoded.map((k, v) =>
              MapEntry(k, Map<String, String>.from(v as Map)));
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveLastUsed() async {
    final config = {
      'host':    _hostController.text,
      'port':    _portController.text,
      'user':    _userController.text,
      'pass':    _passController.text,
      'key':     _keyController.text,
      'tunnels': _tunnelsString,
    };
    try {
      final file = await _getConfigFile();
      await file.writeAsString(jsonEncode(config));
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      config.forEach((k, v) => prefs.setString(k, v));
    } catch (_) {}
  }

  Future<void> _saveProfilesToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ssh_profiles', jsonEncode(_profiles));
    } catch (_) {}
  }

  void _loadProfile(String name) {
    final p = _profiles[name];
    if (p == null) return;
    setState(() {
      _hostController.text = p['host'] ?? '';
      _portController.text = p['port'] ?? '22';
      _userController.text = p['user'] ?? '';
      _passController.text = p['pass'] ?? '';
      _keyController.text  = p['key']  ?? '';
      _loadTunnelRows(p['tunnels'] ?? '');
    });
  }

  Future<void> _saveProfileDialog() async {
    final nameCtrl = TextEditingController();
    // Suggest a name from host+user
    if (_hostController.text.isNotEmpty) {
      nameCtrl.text = '${_userController.text}@${_hostController.text}';
    }
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Connection'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Profile name'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() {
      _profiles[name] = {
        'host':    _hostController.text,
        'port':    _portController.text,
        'user':    _userController.text,
        'pass':    _passController.text,
        'key':     _keyController.text,
        'tunnels': _tunnelsString,
      };
    });
    await _saveProfilesToPrefs();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved "$name"')));
    }
  }

  Future<void> _deleteProfile(String name) async {
    setState(() => _profiles.remove(name));
    await _saveProfilesToPrefs();
  }

  // ─── Connect ───────────────────────────────────────────────────────────────

  Future<void> _connect(BuildContext context) async {
    final state = Provider.of<AppState>(context, listen: false);
    if (_hostController.text.isEmpty || _userController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Hostname and Username are required')));
      return;
    }
    await _saveLastUsed();
    await state.connect(
      _hostController.text,
      int.tryParse(_portController.text) ?? 22,
      _userController.text,
      _passController.text.isNotEmpty ? _passController.text : null,
      _keyController.text.isNotEmpty  ? _keyController.text  : null,
      tunnels: _tunnelsString.isNotEmpty ? _tunnelsString : null,
    );
    if (!context.mounted) return;
    if (state.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connected!')));
      _showBatteryReminderOnce(context);
    }
  }

  Future<void> _showBatteryReminderOnce(BuildContext context) async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('battery_reminder_shown') == true) return;
    await prefs.setBool('battery_reminder_shown', true);
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Allow Background Activity'),
        content: const Text(
          'To prevent SSH sessions from being killed in the background:\n\n'
          '1. Open Settings → Apps → TermiConnect → Battery\n'
          '2. Set to "Unrestricted" or "Allow all background activity"\n\n'
          'Some devices have a separate Battery Management screen — find TermiConnect there and allow all background activity.\n\n'
          'This is required for stable long-running sessions.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  // ─── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);

    if (state.lastError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || state.lastError == null) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: ${state.lastError}')));
        state.clearError();
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.terminal, color: Color(0xFF0D33F2)),
          SizedBox(width: 8),
          Text('TermiConnect'),
        ]),
        actions: const [ThemeSwitchButton()],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ── Connected banner ──────────────────────────────────────────
            if (state.isConnected) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                ),
                child: Row(children: [
                  const Icon(Icons.check_circle, color: Colors.green),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Connected to ${_hostController.text}')),
                  TextButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('Disconnect?'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                            TextButton(onPressed: () => Navigator.pop(c, true),
                                child: const Text('Disconnect', style: TextStyle(color: Colors.red))),
                          ],
                        ),
                      );
                      if (ok == true && mounted) state.disconnect();
                    },
                    child: const Text('DISCONNECT', style: TextStyle(color: Colors.red)),
                  ),
                ]),
              ),
              const SizedBox(height: 24),
            ],

            // ── Saved profiles ────────────────────────────────────────────
            if (_profiles.isNotEmpty) ...[
              const Text('SAVED CONNECTIONS',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
              const SizedBox(height: 8),
              ..._profiles.keys.map((name) => ListTile(
                dense: true,
                leading: const Icon(Icons.history, size: 18),
                title: Text(name),
                subtitle: Text(
                  '${_profiles[name]!['user']}@${_profiles[name]!['host']}:${_profiles[name]!['port']}',
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () => _loadProfile(name),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                  onPressed: () => _deleteProfile(name),
                ),
              )),
              const Divider(),
              const SizedBox(height: 8),
            ],

            // ── Form ──────────────────────────────────────────────────────
            const Text('SSH CONNECTION',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _hostController,
                  decoration: const InputDecoration(
                      labelText: 'Hostname / IP', prefixIcon: Icon(Icons.dns)),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 1,
                child: TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Port'),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _userController,
                  decoration: const InputDecoration(
                      labelText: 'Username', prefixIcon: Icon(Icons.person)),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _passController,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Password', prefixIcon: Icon(Icons.lock)),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            TextField(
              controller: _keyController,
              maxLines: 4,
              decoration: const InputDecoration(
                  labelText: 'SSH Private Key (optional)',
                  alignLabelWithHint: true),
            ),
            const SizedBox(height: 24),

            // ── Local port tunnels ─────────────────────────────────────────
            Row(children: [
              const Expanded(
                child: Text('LOCAL TUNNELS',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _tunnelRows.add(_TunnelRow())),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add'),
              ),
            ]),
            if (_tunnelRows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'No tunnels configured',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ),
            ..._tunnelRows.asMap().entries.map((e) {
              final i = e.key;
              final row = e.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: row.local,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Local port',
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.arrow_forward, size: 16, color: Colors.grey),
                  ),
                  Expanded(
                    child: TextField(
                      controller: row.remote,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Remote port',
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline, color: Colors.red, size: 20),
                    onPressed: () => setState(() {
                      _tunnelRows[i].dispose();
                      _tunnelRows.removeAt(i);
                    }),
                    visualDensity: VisualDensity.compact,
                  ),
                ]),
              );
            }),

            const SizedBox(height: 24),

            // ── Buttons ───────────────────────────────────────────────────
            Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: state.isConnecting || state.isConnected
                      ? null
                      : () => _connect(context),
                  icon: state.isConnecting
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.bolt),
                  label: Text(state.isConnecting ? 'CONNECTING…' : 'CONNECT'),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _saveProfileDialog,
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: const Text('Save'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  // ── Tunnel helpers ──────────────────────────────────────────────────────────

  /// Serialises tunnel rows as "localPort:localhost:remotePort\n…"
  String get _tunnelsString => _tunnelRows
      .where((r) => r.local.text.trim().isNotEmpty && r.remote.text.trim().isNotEmpty)
      .map((r) => '${r.local.text.trim()}:localhost:${r.remote.text.trim()}')
      .join('\n');

  /// Populates [_tunnelRows] from the stored string format.
  void _loadTunnelRows(String raw) {
    for (final r in _tunnelRows) r.dispose();
    _tunnelRows.clear();
    for (final line in raw.split('\n')) {
      final s = line.trim();
      if (s.isEmpty) continue;
      final parts = s.split(':');
      if (parts.length < 3) continue;
      _tunnelRows.add(_TunnelRow(
        local: parts[0],
        remote: parts.last,
      ));
    }
  }
}

// ── Tunnel row model ──────────────────────────────────────────────────────────

class _TunnelRow {
  final TextEditingController local;
  final TextEditingController remote;

  _TunnelRow({String local = '', String remote = ''})
      : local  = TextEditingController(text: local),
        remote = TextEditingController(text: remote);

  void dispose() {
    local.dispose();
    remote.dispose();
  }
}

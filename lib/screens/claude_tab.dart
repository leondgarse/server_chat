import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import '../utils/text_truncator.dart';
import '../utils/theme.dart';
import '../widgets/remote_path_picker.dart';
import '../widgets/connection_button.dart';
import '../widgets/theme_switch_button.dart';
import 'tmux_tab.dart';

/// Prefix of the tmux sessions that host Remote Control Claude processes.
const String _rcPrefix = 'crc-';

/// One Claude Code conversation stored under `~/.claude/projects/<dir>/`.
class ClaudeHistorySession {
  final String id;
  final DateTime modified;
  final int sizeBytes;
  final int userTurns;
  final String title;
  final String? lastPrompt;

  ClaudeHistorySession({
    required this.id,
    required this.modified,
    required this.sizeBytes,
    required this.userTurns,
    required this.title,
    this.lastPrompt,
  });

  String get shortId => id.length > 8 ? id.substring(0, 8) : id;
  String get tmuxName => '$_rcPrefix$shortId';
}

/// A tmux session currently hosting `claude --remote-control`.
class _RcProcess {
  final String tmuxName;
  final String path;
  final bool exited;
  _RcProcess(this.tmuxName, this.path, this.exited);
}

class ClaudeTab extends StatefulWidget {
  const ClaudeTab({super.key});

  @override
  State<ClaudeTab> createState() => _ClaudeTabState();
}

class _ClaudeTabState extends State<ClaudeTab> with AutomaticKeepAliveClientMixin {
  final TextEditingController _pathController = TextEditingController();
  final FocusNode _pathFocus = FocusNode();
  bool _pathFocused = false;
  String _lastKnownPath = '';

  List<ClaudeHistorySession> _sessions = [];
  Map<String, _RcProcess> _rcProcs = {};
  bool _loading = false;
  bool _reloadPending = false;
  String? _error;
  String _loadedPath = '';
  bool _wasConnected = false;

  /// The CLI command used to invoke Claude (default: 'claude').
  /// Can be a full path, shell alias, or wrapper function defined in .bashrc.
  String _claudeCmd = 'claude';
  bool _skipPermissions = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _pathFocus.addListener(() => setState(() => _pathFocused = _pathFocus.hasFocus));
    _pathController.addListener(() => setState(() {}));
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      final saved = prefs.getString('claude_cmd');
      setState(() {
        if (saved != null && saved.trim().isNotEmpty) _claudeCmd = saved.trim();
        _skipPermissions = prefs.getBool('claude_rc_skip_perms') ?? false;
      });
    });
  }

  @override
  void dispose() {
    _pathController.dispose();
    _pathFocus.dispose();
    super.dispose();
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  static String _sq(String s) => "'${s.replaceAll("'", "'\\''")}'";

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _copyText(String text, [String label = 'Copied']) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(label), duration: const Duration(seconds: 1)),
    );
  }

  String _resolvedPath(AppState state) {
    var path = _pathController.text.trim();
    if (path.isEmpty) path = state.sshService.homeDir;
    path = state.sshService.resolvePath(path);
    if (path.length > 1 && path.endsWith('/')) path = path.substring(0, path.length - 1);
    return path;
  }

  void _syncCurrentPath(AppState state) {
    if (!state.isConnected) {
      _wasConnected = false;
      return;
    }
    final justConnected = !_wasConnected;
    _wasConnected = true;
    if (state.currentPath != _lastKnownPath) {
      _lastKnownPath = state.currentPath;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _pathController.text = state.currentPath;
        _loadSessions();
      });
    } else if (justConnected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadSessions();
      });
    }
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 30) return '${d.inDays}d ago';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  static String _size(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// Decode a `"key":"value"` fragment grabbed by `grep -o` into its value.
  /// The fragment may be cut short by `cut`, so fall back to a lenient decode.
  static String? _jsonField(String fragment) {
    final idx = fragment.indexOf('":"');
    if (idx < 0) return null;
    var raw = fragment.substring(idx + 3);
    if (raw.endsWith('"')) raw = raw.substring(0, raw.length - 1);
    // Drop a dangling backslash left by truncation.
    while (raw.endsWith('\\')) {
      raw = raw.substring(0, raw.length - 1);
    }
    try {
      return jsonDecode('"$raw"') as String;
    } catch (_) {
      return raw
          .replaceAll(r'\n', ' ')
          .replaceAll(r'\t', ' ')
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', r'\');
    }
  }

  static String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  // ─── Remote queries ────────────────────────────────────────────────────────

  /// Lists `~/.claude/projects/<encoded path>/*.jsonl` (newest first) and
  /// extracts a title for each one with grep, so no python/jq is needed.
  String _listScript(String path) => '''
P=${_sq(path)}
R=\$(cd "\$P" 2>/dev/null && pwd -P) || R="\$P"
found=0
for X in "\$R" "\$P"; do
  E=\$(printf '%s' "\$X" | sed 's/[^a-zA-Z0-9]/-/g')
  D="\$HOME/.claude/projects/\$E"
  if [ -d "\$D" ]; then found=1; break; fi
done
[ \$found = 1 ] || { echo "@@NODIR"; exit 0; }
cd "\$D" || exit 0
ls -t -- *.jsonl 2>/dev/null | head -n 60 | while IFS= read -r f; do
  m=\$(stat -c %Y "\$f" 2>/dev/null || stat -f %m "\$f")
  s=\$(stat -c %s "\$f" 2>/dev/null || stat -f %z "\$f")
  printf '@@S\\t%s\\t%s\\t%s\\t%s\\n' "\${f%.jsonl}" "\$m" "\$s" "\$(grep -c '"type":"user"' "\$f")"
  grep -oE '"customTitle":"([^"\\\\]|\\\\.)*"' "\$f" | tail -n1 | cut -c1-300 | sed 's/^/@@T\\t/'
  grep -oE '"aiTitle":"([^"\\\\]|\\\\.)*"' "\$f" | tail -n1 | cut -c1-300 | sed 's/^/@@A\\t/'
  grep '"type":"summary"' "\$f" | grep -oE '"summary":"([^"\\\\]|\\\\.)*"' | tail -n1 | cut -c1-300 | sed 's/^/@@Y\\t/'
  grep -oE '"lastPrompt":"([^"\\\\]|\\\\.)*"' "\$f" | tail -n1 | cut -c1-300 | sed 's/^/@@L\\t/'
  grep -m8 '"type":"user"' "\$f" | grep -v '"tool_result"' | grep -v '"isMeta":true' \\
    | grep -oE '"(content|text)":"([^"\\\\]|\\\\.)*"' | head -n4 | cut -c1-300 | sed 's/^/@@U\\t/'
done
''';

  Future<void> _loadSessions() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) return;
    if (_loading) {
      _reloadPending = true;
      return;
    }
    final path = _resolvedPath(state);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final out = await state.sshService.executeCommandFast(_listScript(path));
      final procs = await _loadRcProcesses(state);
      if (!mounted) return;
      setState(() {
        _sessions = _parseSessions(out);
        _rcProcs = procs;
        _loadedPath = path;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
      if (_reloadPending && mounted) {
        _reloadPending = false;
        _loadSessions();
      }
    }
  }

  List<ClaudeHistorySession> _parseSessions(String out) {
    final result = <ClaudeHistorySession>[];
    String? id;
    DateTime modified = DateTime.now();
    int size = 0, turns = 0;
    String? custom, ai, summary, last, firstUser;

    void flush() {
      if (id == null) return;
      final title = custom ?? ai ?? summary ?? firstUser ?? last ?? '(no prompt)';
      result.add(ClaudeHistorySession(
        id: id,
        modified: modified,
        sizeBytes: size,
        userTurns: turns,
        title: _oneLine(title),
        lastPrompt: last == null ? null : _oneLine(last),
      ));
    }

    for (final line in const LineSplitter().convert(out)) {
      final tab = line.indexOf('\t');
      if (tab < 0) continue;
      final tag = line.substring(0, tab);
      final rest = line.substring(tab + 1);
      switch (tag) {
        case '@@S':
          flush();
          final p = rest.split('\t');
          id = p.length >= 4 ? p[0] : null;
          modified = DateTime.fromMillisecondsSinceEpoch(
              (int.tryParse(p.length > 1 ? p[1] : '') ?? 0) * 1000);
          size = int.tryParse(p.length > 2 ? p[2] : '') ?? 0;
          turns = int.tryParse(p.length > 3 ? p[3].trim() : '') ?? 0;
          custom = ai = summary = last = firstUser = null;
          break;
        case '@@T':
          custom = _jsonField(rest);
          break;
        case '@@A':
          ai = _jsonField(rest);
          break;
        case '@@Y':
          summary = _jsonField(rest);
          break;
        case '@@L':
          last = _jsonField(rest);
          break;
        case '@@U':
          final v = _jsonField(rest);
          // Skip slash-command / system wrappers like <command-name>…
          if (firstUser == null && v != null && v.trim().isNotEmpty &&
              !v.trimLeft().startsWith('<')) {
            firstUser = v;
          }
          break;
      }
    }
    flush();
    // Sessions with no real user turn (e.g. aborted starts) are just noise.
    return result.where((s) => s.userTurns > 0 || s.title != '(no prompt)').toList();
  }

  Future<Map<String, _RcProcess>> _loadRcProcesses(AppState state) async {
    final map = <String, _RcProcess>{};
    try {
      final out = await state.sshService.executeCommandFast(
          'tmux list-panes -a -F "#{session_name}|||#{pane_current_path}|||#{pane_dead}|||#{pane_current_command}" 2>/dev/null');
      for (final line in const LineSplitter().convert(out)) {
        final p = line.split('|||');
        if (p.length < 4 || !p[0].startsWith(_rcPrefix)) continue;
        // After claude exits the pane sits in the wrapper shell's `read`,
        // so a bare shell in the foreground means claude is no longer running.
        final fg = p[3].trim();
        final exited = p[2].trim() == '1' || const {'bash', 'sh', 'zsh'}.contains(fg);
        map.putIfAbsent(p[0], () => _RcProcess(p[0], p[1], exited));
      }
    } catch (_) {}
    return map;
  }

  /// Build the shell command that runs claude with Remote Control on.
  String _claudeRcCommand({String? resumeId, String? name}) {
    final cmd = _claudeCmd.isEmpty ? 'claude' : _claudeCmd;
    final b = StringBuffer(cmd);
    if (resumeId != null) b.write(' --resume $resumeId');
    if (_skipPermissions) b.write(' --dangerously-skip-permissions');
    b.write(' --remote-control');
    if (name != null && name.trim().isNotEmpty) b.write(' ${_sq(name.trim())}');
    return b.toString();
  }

  /// Start claude inside a detached tmux session so it keeps running (and
  /// stays reachable from the Claude app) after this SSH connection drops.
  Future<void> _startRc({
    required String tmuxName,
    required String path,
    String? resumeId,
    String? name,
  }) async {
    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) {
      _snack('Not connected');
      return;
    }
    final claude = _claudeRcCommand(resumeId: resumeId, name: name);
    // bash -l -i so aliases/functions from .bashrc (custom claude command) work.
    // After claude exits, keep the pane open so errors stay readable.
    final inner = '$claude; echo; echo "[claude exited — press Enter to close]"; read _';
    final shell = 'bash -l -i -c ${_sq(inner)}';
    final command =
        'tmux has-session -t ${_sq(tmuxName)} 2>/dev/null && { echo "@@EXISTS"; exit 0; }; '
        'tmux new-session -d -s ${_sq(tmuxName)} -x 200 -y 50 -c ${_sq(path)} ${_sq(shell)} '
        '&& echo "@@OK"';
    try {
      final out = await state.sshService.executeCommandFast(command);
      if (out.contains('@@EXISTS')) {
        _snack('Already running in tmux "$tmuxName"');
      } else if (out.contains('@@OK')) {
        _snack('Remote Control starting in tmux "$tmuxName"');
      } else {
        _snack('Failed to start tmux session${out.trim().isEmpty ? "" : ": ${out.trim()}"}');
        return;
      }
    } catch (e) {
      _snack('Error: $e');
      return;
    }
    await _loadSessions();
    if (!mounted) return;
    // Give claude a moment to connect, then show its screen (URL / prompts).
    await Future.delayed(const Duration(seconds: 3));
    if (mounted) _showPeek(tmuxName);
  }

  Future<void> _stopRc(String tmuxName) async {
    final state = Provider.of<AppState>(context, listen: false);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop Remote Control?'),
        content: Text('Kills tmux session "$tmuxName" and the claude process in it. '
            'The conversation history is kept and can be started again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      // Ctrl-C twice lets claude exit cleanly before the session is killed.
      await state.sshService.executeCommandFast(
          'tmux send-keys -t ${_sq(tmuxName)} C-c 2>/dev/null; sleep 0.3; '
          'tmux send-keys -t ${_sq(tmuxName)} C-c 2>/dev/null; sleep 0.5; '
          'tmux kill-session -t ${_sq(tmuxName)} 2>/dev/null; true');
    } catch (e) {
      _snack('Error: $e');
    }
    await _loadSessions();
  }

  Future<String> _capture(String tmuxName) async {
    final state = Provider.of<AppState>(context, listen: false);
    return state.sshService.executeCommandFast(
        'tmux capture-pane -p -J -t ${_sq(tmuxName)} -S -300 2>&1');
  }

  static String? _extractUrl(String text) {
    final matches = RegExp(r'https://claude\.ai/code/[A-Za-z0-9_\-/?=&.%]+').allMatches(text);
    return matches.isEmpty ? null : matches.last.group(0);
  }

  void _attach(String tmuxName) {
    final state = Provider.of<AppState>(context, listen: false);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TmuxSessionPage(sessionName: tmuxName, state: state),
    )).then((_) {
      if (mounted) _loadSessions();
    });
  }

  // ─── Dialogs ───────────────────────────────────────────────────────────────

  Future<void> _showPeek(String tmuxName) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _PeekDialog(
        tmuxName: tmuxName,
        capture: () => _capture(tmuxName),
        extractUrl: _extractUrl,
        onCopy: (t) => _copyText(t, 'URL copied'),
        onAttach: () {
          Navigator.pop(ctx);
          _attach(tmuxName);
        },
      ),
    );
  }

  Future<void> _showSessionSheet(ClaudeHistorySession s) async {
    final proc = _rcProcs[s.tmuxName];
    final running = proc != null;
    final resumeCmd = 'cd ${_sq(_loadedPath)} && ${_claudeCmd.isEmpty ? "claude" : _claudeCmd} --resume ${s.id}';
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('${s.id}\n${_ago(s.modified)} · ${s.userTurns} msgs · ${_size(s.sizeBytes)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey, fontFamily: 'monospace')),
              if (s.lastPrompt != null && s.lastPrompt != s.title) ...[
                const SizedBox(height: 8),
                Text('Last: ${s.lastPrompt}',
                    maxLines: 3, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              ],
              const SizedBox(height: 8),
              const Divider(),
              if (!running)
                ListTile(
                  leading: const Icon(Icons.cast_connected, color: AppTheme.primaryBlue),
                  title: const Text('Start in Remote Control'),
                  subtitle: Text('claude --resume ${s.shortId}… --remote-control  (tmux: ${s.tmuxName})'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _startRc(tmuxName: s.tmuxName, path: _loadedPath, resumeId: s.id);
                  },
                )
              else ...[
                ListTile(
                  leading: const Icon(Icons.qr_code_2),
                  title: const Text('Show status / session URL'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showPeek(s.tmuxName);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.terminal),
                  title: const Text('Attach terminal'),
                  subtitle: const Text('Answer prompts or type locally'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _attach(s.tmuxName);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.stop_circle_outlined, color: Colors.red),
                  title: const Text('Stop Remote Control'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _stopRc(s.tmuxName);
                  },
                ),
              ],
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copy resume command'),
                onTap: () {
                  Navigator.pop(ctx);
                  _copyText(resumeCmd);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showNewRcDialog() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) {
      _snack('Not connected');
      return;
    }
    final path = _resolvedPath(state);
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Remote Control session'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(path, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Session name (optional)',
                helperText: 'Shown in the Claude app session list',
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text),
            child: const Text('Start'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    if (name == null || !mounted) return;
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    await _startRc(tmuxName: '${_rcPrefix}new-$stamp', path: path, name: name);
  }

  Future<void> _showSettingsDialog() async {
    final ctrl = TextEditingController(text: _claudeCmd);
    bool skip = _skipPermissions;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Claude Command'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                onChanged: (_) => setDialogState(() {}),
                decoration: const InputDecoration(
                  hintText: 'claude',
                  labelText: 'Base command / alias / path',
                  helperText: 'Alias or function from .bashrc is supported',
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: skip,
                onChanged: (v) => setDialogState(() => skip = v ?? false),
                title: const Text('--dangerously-skip-permissions'),
                subtitle: const Text('Otherwise approve tool use from the Claude app'),
              ),
              const SizedBox(height: 4),
              const Text('Resume command:', style: TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  () {
                    final cmd = ctrl.text.trim().isEmpty ? 'claude' : ctrl.text.trim();
                    return '$cmd --resume <id>${skip ? " --dangerously-skip-permissions" : ""} --remote-control';
                  }(),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    final cmd = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || !mounted) return;
    setState(() {
      if (cmd.isNotEmpty) _claudeCmd = cmd;
      _skipPermissions = skip;
    });
    final prefs = await SharedPreferences.getInstance();
    if (cmd.isNotEmpty) await prefs.setString('claude_cmd', cmd);
    await prefs.setBool('claude_rc_skip_perms', skip);
  }

  // ─── UI ────────────────────────────────────────────────────────────────────

  Widget _buildPathBar(AppState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final style = Theme.of(context).textTheme.bodyMedium!.copyWith(fontSize: 14);
              // prefixIcon=48, internal content padding≈12 each side
              const textStart = 60.0;
              const textEnd = 12.0;
              final availableWidth = constraints.maxWidth - textStart - textEnd;
              final truncated = !_pathFocused
                  ? truncateLeft(_pathController.text, availableWidth, style)
                  : _pathController.text;
              return Stack(
                children: [
                  TextField(
                    controller: _pathController,
                    focusNode: _pathFocus,
                    textAlignVertical: TextAlignVertical.top,
                    maxLines: 1,
                    style: _pathFocused ? style : style.copyWith(color: Colors.transparent),
                    onSubmitted: (v) {
                      state.setCurrentPath(state.sshService.resolvePath(v.trim()));
                      _loadSessions();
                    },
                    decoration: InputDecoration(
                      hintText: _pathController.text.isEmpty ? 'Project path' : null,
                      prefixIcon: IconButton(
                        icon: const Icon(Icons.folder_open),
                        onPressed: () async {
                          final path = await showDialog<String>(
                            context: context,
                            builder: (c) => RemotePathPickerDialog(
                              initialPath: _pathController.text,
                              foldersOnly: true,
                            ),
                          );
                          if (path != null) {
                            _pathController.text = path;
                            state.setCurrentPath(path);
                            _loadSessions();
                          }
                        },
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    ),
                  ),
                  if (!_pathFocused && _pathController.text.isNotEmpty)
                    Positioned(
                      left: textStart,
                      top: 0,
                      bottom: 0,
                      right: textEnd,
                      child: IgnorePointer(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(truncated,
                              maxLines: 1, overflow: TextOverflow.clip, style: style),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          onPressed: state.isConnected ? _showNewRcDialog : null,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New'),
        ),
      ]),
    );
  }

  Widget _rcBadge(_RcProcess p) {
    final color = p.exited ? Colors.orange : Colors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(p.exited ? Icons.error_outline : Icons.cast_connected, size: 12, color: color),
        const SizedBox(width: 4),
        Text(p.exited ? 'exited' : 'RC', style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  Widget _buildSessionCard(ClaudeHistorySession s) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final proc = _rcProcs[s.tmuxName];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      elevation: 0,
      color: isDark ? AppTheme.surfaceDark : AppTheme.surfaceLight,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: proc != null
              ? AppTheme.primaryBlue
              : (isDark ? AppTheme.borderDark : AppTheme.borderLight),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showSessionSheet(s),
        onLongPress: proc == null
            ? () => _startRc(tmuxName: s.tmuxName, path: _loadedPath, resumeId: s.id)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Text(s.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: isDark ? AppTheme.textPrimaryDark : AppTheme.textPrimaryLight,
                    )),
              ),
              if (proc != null) ...[const SizedBox(width: 8), _rcBadge(proc)],
            ]),
            const SizedBox(height: 6),
            Text('${s.shortId} · ${_ago(s.modified)} · ${s.userTurns} msgs · ${_size(s.sizeBytes)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace')),
          ]),
        ),
      ),
    );
  }

  Widget _buildBody(AppState state) {
    if (!state.isConnected) {
      return const Center(child: Text('Not connected', style: TextStyle(color: Colors.grey)));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _loadSessions, child: const Text('Retry')),
          ]),
        ),
      );
    }
    // RC tmux sessions not tied to a listed history entry (new sessions, or
    // started from another directory).
    final listed = _sessions.map((s) => s.tmuxName).toSet();
    final others = _rcProcs.values.where((p) => !listed.contains(p.tmuxName)).toList();

    final children = <Widget>[];
    if (others.isNotEmpty) {
      children.add(_sectionHeader('Active Remote Control'));
      for (final p in others) {
        children.add(ListTile(
          dense: true,
          leading: _rcBadge(p),
          title: Text(p.tmuxName, style: const TextStyle(fontFamily: 'monospace')),
          subtitle: Text(p.path, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _showPeek(p.tmuxName),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              icon: const Icon(Icons.terminal, size: 20),
              tooltip: 'Attach',
              onPressed: () => _attach(p.tmuxName),
            ),
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined, size: 20, color: Colors.red),
              tooltip: 'Stop',
              onPressed: () => _stopRc(p.tmuxName),
            ),
          ]),
        ));
      }
    }
    children.add(_sectionHeader(
        'History${_sessions.isEmpty ? "" : " (${_sessions.length})"}'));
    if (_sessions.isEmpty && !_loading) {
      children.add(Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No Claude sessions found for\n${_loadedPath.isEmpty ? _pathController.text : _loadedPath}\n\n'
          'Tap "New" to start one with Remote Control.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      ));
    }
    children.addAll(_sessions.map(_buildSessionCard));
    children.add(const SizedBox(height: 24));

    return RefreshIndicator(
      onRefresh: _loadSessions,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: children,
      ),
    );
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1, color: Colors.grey)),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = Provider.of<AppState>(context);
    _syncCurrentPath(state);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Claude Sessions'),
        actions: [
          IconButton(
            icon: _loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, size: 20),
            onPressed: _loading ? null : _loadSessions,
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.settings, size: 20),
            onPressed: _showSettingsDialog,
            tooltip: 'Claude command ($_claudeCmd)',
          ),
          const ThemeSwitchButton(),
          const ConnectionButton(),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: _buildPathBar(state),
        ),
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: _buildBody(state),
      ),
    );
  }
}

/// Shows the tail of the tmux pane running claude, plus the session URL if
/// claude printed one. Auto-refreshes every 2 seconds.
class _PeekDialog extends StatefulWidget {
  final String tmuxName;
  final Future<String> Function() capture;
  final String? Function(String) extractUrl;
  final void Function(String) onCopy;
  final VoidCallback onAttach;

  const _PeekDialog({
    required this.tmuxName,
    required this.capture,
    required this.extractUrl,
    required this.onCopy,
    required this.onAttach,
  });

  @override
  State<_PeekDialog> createState() => _PeekDialogState();
}

class _PeekDialogState extends State<_PeekDialog> {
  String _text = '';
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      final t = await widget.capture();
      if (mounted) setState(() => _text = t.trimRight());
    } catch (e) {
      if (mounted) setState(() => _text = 'Error: $e');
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.extractUrl(_text);
    final lines = _text.split('\n');
    final tail = lines.length > 40 ? lines.sublist(lines.length - 40).join('\n') : _text;
    return AlertDialog(
      title: Text(widget.tmuxName, style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (url != null)
            InkWell(
              onTap: () => widget.onCopy(url),
              child: Row(children: [
                const Icon(Icons.link, size: 18, color: AppTheme.primaryBlue),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(url,
                      style: const TextStyle(color: AppTheme.primaryBlue, fontSize: 12),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                const Icon(Icons.copy, size: 16),
              ]),
            )
          else
            const Text(
              'Open the Claude app → Code to find this session. '
              'If claude is waiting on a prompt (trust / enable Remote Control), attach to answer it.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          const SizedBox(height: 8),
          Flexible(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                reverse: true,
                scrollDirection: Axis.vertical,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    tail.isEmpty ? '…' : tail,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 10, color: Colors.white70, height: 1.2),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: widget.onAttach, child: const Text('Attach')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}

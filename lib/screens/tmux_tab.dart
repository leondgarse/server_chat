import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';
import '../models/app_state.dart';
import '../utils/theme.dart';
import '../widgets/connection_button.dart';

// ---------------------------------------------------------------------------
// Data models for session tree

class _PaneData {
  final int index;
  final String id;
  final bool active;
  final int width;
  final int height;
  _PaneData({
    required this.index,
    required this.id,
    required this.active,
    required this.width,
    required this.height,
  });
}

class _WindowData {
  final int index;
  final String name;
  final bool active;
  final List<_PaneData> panes;
  _WindowData({
    required this.index,
    required this.name,
    required this.active,
    required this.panes,
  });
}

class _SessionData {
  final String name;
  final bool attached;
  final List<_WindowData> windows;
  _SessionData({
    required this.name,
    required this.attached,
    required this.windows,
  });
}

// ---------------------------------------------------------------------------

class TmuxTab extends StatefulWidget {
  const TmuxTab({super.key});

  @override
  State<TmuxTab> createState() => _TmuxTabState();
}

class _TmuxTabState extends State<TmuxTab> with AutomaticKeepAliveClientMixin {
  List<_SessionData> _sessions = [];
  bool _loading = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSessions());
  }

  Future<void> _loadSessions() async {
    final state = context.read<AppState>();
    if (!state.isConnected) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // One-shot query: all sessions + windows + panes
      final output = await state.sshService.executeCommand(
        'tmux list-panes -a -F '
        '"#{session_name}|||#{session_attached}|||#{window_index}|||#{window_name}|||#{window_active}|||#{pane_index}|||#{pane_id}|||#{pane_active}|||#{pane_width}|||#{pane_height}"'
        ' 2>/dev/null || echo "NO_SESSIONS"',
      );

      final sessions = _parseSessionTree(output);
      setState(() {
        _sessions = sessions;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<_SessionData> _parseSessionTree(String output) {
    final lines = output
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && l != 'NO_SESSIONS')
        .toList();

    // session name → _SessionData (mutable during build)
    final Map<String, _SessionData> sessionMap = {};
    // session+window key → list of panes
    final Map<String, List<_PaneData>> panesMap = {};
    // session+window key → window metadata
    final Map<String, Map<String, dynamic>> windowMeta = {};

    for (final line in lines) {
      final parts = line.split('|||');
      if (parts.length < 10) continue;

      final sessionName = parts[0];
      final sessionAttached = parts[1] == '1';
      final windowIndex = int.tryParse(parts[2]) ?? 0;
      final windowName = parts[3];
      final windowActive = parts[4] == '1';
      final paneIndex = int.tryParse(parts[5]) ?? 0;
      final paneId = parts[6];
      final paneActive = parts[7] == '1';
      final paneWidth = int.tryParse(parts[8]) ?? 80;
      final paneHeight = int.tryParse(parts[9]) ?? 24;

      final winKey = '$sessionName|||$windowIndex';

      windowMeta[winKey] = {
        'index': windowIndex,
        'name': windowName,
        'active': windowActive,
        'session': sessionName,
      };

      panesMap.putIfAbsent(winKey, () => []).add(_PaneData(
        index: paneIndex,
        id: paneId,
        active: paneActive,
        width: paneWidth,
        height: paneHeight,
      ));

      if (!sessionMap.containsKey(sessionName)) {
        // Placeholder – windows added below
        sessionMap[sessionName] = _SessionData(
          name: sessionName,
          attached: sessionAttached,
          windows: [],
        );
      }
    }

    // Build final session list
    final result = <_SessionData>[];
    for (final entry in sessionMap.entries) {
      final sessionName = entry.key;
      final attached = entry.value.attached;

      final windows = <_WindowData>[];
      for (final winEntry in windowMeta.entries) {
        if (winEntry.value['session'] != sessionName) continue;
        final winKey = winEntry.key;
        final panes = panesMap[winKey] ?? [];
        panes.sort((a, b) => a.index.compareTo(b.index));
        windows.add(_WindowData(
          index: winEntry.value['index'] as int,
          name: winEntry.value['name'] as String,
          active: winEntry.value['active'] as bool,
          panes: panes,
        ));
      }
      windows.sort((a, b) => a.index.compareTo(b.index));
      result.add(_SessionData(name: sessionName, attached: attached, windows: windows));
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  Future<void> _createSession(AppState state) async {
    try {
      await state.sshService.executeCommand(
        r'tmux new-session -d -s mobile$(date +%s)',
      );
      await _loadSessions();
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  void _openSession(AppState state, _SessionData session,
      {int? windowIndex, String? paneId}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider.value(
          value: state,
          child: TmuxSessionPage(
            sessionName: session.name,
            state: state,
            initialWindowIndex: windowIndex,
            initialPaneId: paneId,
          ),
        ),
        fullscreenDialog: true,
      ),
    ).then((_) => _loadSessions()); // refresh on return
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = context.watch<AppState>();

    if (!state.isConnected) {
      return const Center(
        child: Text(
          'Not connected',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 16),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Tmux Sessions',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                color: AppTheme.primaryBlue,
                onPressed: _loading ? null : _loadSessions,
              ),
              ElevatedButton.icon(
                onPressed: _loading ? null : () => _createSession(state),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New Session'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _sessions.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'No tmux sessions. Create one?',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: () => _createSession(state),
                            icon: const Icon(Icons.add),
                            label: const Text('New Session'),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      itemCount: _sessions.length,
                      itemBuilder: (context, index) {
                        return _SessionTreeTile(
                          session: _sessions[index],
                          onSessionTap: () => _openSession(state, _sessions[index]),
                          onWindowTap: (winIndex) =>
                              _openSession(state, _sessions[index], windowIndex: winIndex),
                          onPaneTap: (winIndex, paneId) =>
                              _openSession(state, _sessions[index],
                                  windowIndex: winIndex, paneId: paneId),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Session tree tile: Session → expandable Windows → expandable Panes

class _SessionTreeTile extends StatefulWidget {
  final _SessionData session;
  final VoidCallback onSessionTap;
  final void Function(int windowIndex) onWindowTap;
  final void Function(int windowIndex, String paneId) onPaneTap;

  const _SessionTreeTile({
    required this.session,
    required this.onSessionTap,
    required this.onWindowTap,
    required this.onPaneTap,
  });

  @override
  State<_SessionTreeTile> createState() => _SessionTreeTileState();
}

class _SessionTreeTileState extends State<_SessionTreeTile> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.session.attached;
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Column(
        children: [
          // Session row
          InkWell(
            onTap: widget.onSessionTap,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.terminal,
                    color: session.attached ? AppTheme.primaryBlue : AppTheme.textSecondary,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              session.name,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (session.attached) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'attached',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: AppTheme.primaryBlue,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        Text(
                          '${session.windows.length} window${session.windows.length != 1 ? 's' : ''}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Expand/collapse for windows
                  IconButton(
                    icon: Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: AppTheme.textSecondary,
                    ),
                    onPressed: () => setState(() => _expanded = !_expanded),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                  ),
                  const Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary),
                ],
              ),
            ),
          ),
          // Windows list (when expanded)
          if (_expanded)
            Column(
              children: session.windows.map((window) {
                return _WindowTile(
                  window: window,
                  onWindowTap: () => widget.onWindowTap(window.index),
                  onPaneTap: (paneId) => widget.onPaneTap(window.index, paneId),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}

class _WindowTile extends StatefulWidget {
  final _WindowData window;
  final VoidCallback onWindowTap;
  final void Function(String paneId) onPaneTap;

  const _WindowTile({
    required this.window,
    required this.onWindowTap,
    required this.onPaneTap,
  });

  @override
  State<_WindowTile> createState() => _WindowTileState();
}

class _WindowTileState extends State<_WindowTile> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.window.active && widget.window.panes.length > 1;
  }

  @override
  Widget build(BuildContext context) {
    final window = widget.window;
    return Column(
      children: [
        InkWell(
          onTap: widget.onWindowTap,
          child: Padding(
            padding: const EdgeInsets.only(left: 36, right: 12, top: 8, bottom: 8),
            child: Row(
              children: [
                Icon(
                  Icons.tab,
                  size: 16,
                  color: window.active ? AppTheme.primaryBlue : AppTheme.textSecondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${window.index}: ${window.name}',
                    style: TextStyle(
                      fontSize: 13,
                      color: window.active ? AppTheme.primaryBlue : null,
                      fontWeight: window.active ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                Text(
                  '${window.panes.length} pane${window.panes.length != 1 ? 's' : ''}',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                ),
                if (window.panes.length > 1)
                  IconButton(
                    icon: Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: AppTheme.textSecondary,
                    ),
                    onPressed: () => setState(() => _expanded = !_expanded),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
          ),
        ),
        if (_expanded)
          ...window.panes.map((pane) => InkWell(
                onTap: () => widget.onPaneTap(pane.id),
                child: Padding(
                  padding: const EdgeInsets.only(left: 60, right: 12, top: 6, bottom: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.crop_square,
                        size: 14,
                        color: pane.active ? Colors.green : AppTheme.textSecondary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Pane ${pane.index}  ${pane.width}×${pane.height}',
                        style: TextStyle(
                          fontSize: 12,
                          color: pane.active ? Colors.green : AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              )),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class TmuxSessionPage extends StatefulWidget {
  final String sessionName;
  final AppState state;
  final int? initialWindowIndex;
  final String? initialPaneId;

  const TmuxSessionPage({
    super.key,
    required this.sessionName,
    required this.state,
    this.initialWindowIndex,
    this.initialPaneId,
  });

  @override
  State<TmuxSessionPage> createState() => _TmuxSessionPageState();
}

class _TmuxSessionPageState extends State<TmuxSessionPage> {
  late final Terminal _terminal;
  late final TerminalController _terminalController;
  SSHSession? _session;
  bool _exited = false;
  double _fontSize = 13.0;
  int _lastCols = 80;
  int _lastRows = 25;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    _terminal.onOutput = (data) => _session?.stdin.add(utf8.encode(data));
    _terminal.onResize = (w, h, pw, ph) {
      _lastCols = w;
      _lastRows = h;
      _session?.resizeTerminal(w, h);
    };
    _startSession();
  }

  Future<void> _startSession() async {
    try {
      final session = await widget.state.sshService.startInteractiveShell(
        width: _lastCols,
        height: _lastRows,
      );
      _session = session;
      session.resizeTerminal(_lastCols, _lastRows);

      session.stdout.listen((data) {
        _terminal.write(utf8.decode(data, allowMalformed: true));
      });
      session.stderr.listen((data) {
        _terminal.write(utf8.decode(data, allowMalformed: true));
      });
      session.done.then((_) {
        if (mounted) setState(() => _exited = true);
      });

      // Build attach command, optionally jumping to a window/pane
      final attachCmd = StringBuffer(
        'tmux set -g mouse on 2>/dev/null; tmux attach -t ${widget.sessionName}',
      );
      if (widget.initialWindowIndex != null) {
        attachCmd.write(' \\; select-window -t ${widget.sessionName}:${widget.initialWindowIndex}');
      }
      attachCmd.write('\n');
      session.stdin.add(utf8.encode(attachCmd.toString()));

      // If a specific pane was requested, select it after a short delay
      if (widget.initialPaneId != null) {
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted && _session != null) {
            _sendRaw(utf8.encode(
              'tmux select-pane -t ${widget.initialPaneId}\n',
            ));
          }
        });
      }
    } catch (e) {
      if (mounted) {
        _terminal.write('\r\nError: $e\r\n');
        setState(() => _exited = true);
      }
    }
  }

  void _sendRaw(List<int> bytes) {
    _session?.stdin.add(bytes);
  }

  void _sendKey(String key) {
    switch (key) {
      case 'Escape':
        _sendRaw([0x1b]);
      case 'Tab':
        _sendRaw([0x09]);
      case 'Enter':
        _sendRaw([0x0d]);
      case 'Up':
        _sendRaw([0x1b, 0x5b, 0x41]);
      case 'Down':
        _sendRaw([0x1b, 0x5b, 0x42]);
      case 'Right':
        _sendRaw([0x1b, 0x5b, 0x43]);
      case 'Left':
        _sendRaw([0x1b, 0x5b, 0x44]);
      case 'C-c':
        _sendRaw([0x03]);
      case 'C-d':
        _sendRaw([0x04]);
      case 'C-z':
        _sendRaw([0x1a]);
      case 'C-l':
        _sendRaw([0x0c]);
      case 'C-u':
        _sendRaw([0x15]);
      case 'C-a':
        _sendRaw([0x01]);
      default:
        // C-<letter> combos
        if (key.startsWith('C-') && key.length == 3) {
          final c = key[2].toLowerCase().codeUnitAt(0);
          if (c >= 97 && c <= 122) _sendRaw([c - 96]);
        }
    }
  }

  @override
  void dispose() {
    _session?.close();
    _terminalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.sessionName),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.remove),
            tooltip: 'Zoom out',
            onPressed: () => setState(() => _fontSize = (_fontSize - 1).clamp(7, 28)),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Zoom in',
            onPressed: () => setState(() => _fontSize = (_fontSize + 1).clamp(7, 28)),
          ),
          const ConnectionButton(),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Container(
                  color: Colors.black,
                  child: TerminalView(
                    _terminal,
                    controller: _terminalController,
                    padding: EdgeInsets.zero,
                    textStyle: TerminalStyle(fontSize: _fontSize),
                  ),
                ),
                if (_exited)
                  Container(
                    color: Colors.black54,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Session ended',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          _SpecialKeysBar(onKey: _sendKey),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Special keys bar

class _SpecialKeysBar extends StatefulWidget {
  final void Function(String key) onKey;

  const _SpecialKeysBar({required this.onKey});

  @override
  State<_SpecialKeysBar> createState() => _SpecialKeysBarState();
}

class _SpecialKeysBarState extends State<_SpecialKeysBar> {
  bool _ctrlOn = false;

  void _tap(String key) {
    HapticFeedback.lightImpact();
    if (_ctrlOn) {
      setState(() => _ctrlOn = false);
      widget.onKey('C-$key');
    } else {
      widget.onKey(key);
    }
  }

  void _tapDirect(String key) {
    HapticFeedback.lightImpact();
    widget.onKey(key);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        border: const Border(top: BorderSide(color: Colors.black, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Row 1: modifiers + special keys
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
              child: Row(
                children: [
                  _KeyBtn(label: 'ESC', onTap: () => _tapDirect('Escape')),
                  _KeyBtn(label: 'TAB', onTap: () => _tapDirect('Tab')),
                  _ModBtn(
                    label: 'CTRL',
                    active: _ctrlOn,
                    onTap: () => setState(() => _ctrlOn = !_ctrlOn),
                  ),
                  _KeyBtn(label: 'C-c', onTap: () => _tapDirect('C-c'), accent: Colors.red),
                  _KeyBtn(label: 'C-d', onTap: () => _tapDirect('C-d')),
                  _KeyBtn(label: 'C-z', onTap: () => _tapDirect('C-z')),
                  _KeyBtn(label: 'C-l', onTap: () => _tapDirect('C-l')),
                  _KeyBtn(label: 'C-u', onTap: () => _tapDirect('C-u')),
                ],
              ),
            ),
            // Row 2: arrows + enter
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
              child: Row(
                children: [
                  _ArrowBtn(icon: Icons.arrow_left, onTap: () => _tap('Left')),
                  _ArrowBtn(icon: Icons.arrow_drop_up, onTap: () => _tap('Up')),
                  _ArrowBtn(icon: Icons.arrow_drop_down, onTap: () => _tap('Down')),
                  _ArrowBtn(icon: Icons.arrow_right, onTap: () => _tap('Right')),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _KeyBtn(
                      label: 'RET',
                      icon: Icons.keyboard_return,
                      onTap: () => _tapDirect('Enter'),
                      accent: AppTheme.primaryBlue,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyBtn extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final Color? accent;

  const _KeyBtn({
    required this.label,
    required this.onTap,
    this.icon,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final color = accent ?? Colors.white70;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 34,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: accent != null
                ? accent!.withValues(alpha: 0.18)
                : Colors.grey.shade800,
            borderRadius: BorderRadius.circular(5),
            border: Border(
              bottom: BorderSide(
                color: accent != null ? accent!.withValues(alpha: 0.4) : Colors.black,
                width: 2,
              ),
            ),
          ),
          child: Center(
            child: icon != null
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 12, color: color),
                      const SizedBox(width: 2),
                      Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color)),
                    ],
                  )
                : Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color)),
          ),
        ),
      ),
    );
  }
}

class _ModBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ModBtn({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 34,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: active ? AppTheme.primaryBlue : Colors.grey.shade800,
            borderRadius: BorderRadius.circular(5),
            border: Border(
              bottom: BorderSide(
                color: active ? AppTheme.primaryBlue.withValues(alpha: 0.6) : Colors.black,
                width: 2,
              ),
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: active ? Colors.white : AppTheme.primaryBlue,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ArrowBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ArrowBtn({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 34,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: Colors.grey.shade800,
          borderRadius: BorderRadius.circular(5),
          border: const Border(bottom: BorderSide(color: Colors.black, width: 2)),
        ),
        child: Icon(icon, size: 18, color: Colors.white70),
      ),
    );
  }
}

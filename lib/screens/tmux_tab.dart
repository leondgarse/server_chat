import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';
import '../models/app_state.dart';
import '../utils/theme.dart';
import '../widgets/connection_button.dart';
import '../widgets/special_keys_bar.dart';
import '../widgets/theme_switch_button.dart';
import 'connect_tab.dart';

// ---------------------------------------------------------------------------
// Data models for session tree

class _PaneData {
  final int index;
  final String id;
  final bool active;
  final int width;
  final int height;
  final int left;
  final int top;
  _PaneData({
    required this.index,
    required this.id,
    required this.active,
    required this.width,
    required this.height,
    required this.left,
    required this.top,
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
        '"#{session_name}|||#{session_attached}|||#{window_index}|||#{window_name}|||#{window_active}|||#{pane_index}|||#{pane_id}|||#{pane_active}|||#{pane_width}|||#{pane_height}|||#{pane_left}|||#{pane_top}"'
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
      if (parts.length < 12) continue;

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
      final paneLeft = int.tryParse(parts[10]) ?? 0;
      final paneTop = int.tryParse(parts[11]) ?? 0;

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
        left: paneLeft,
        top: paneTop,
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

  void _openConnectPage(BuildContext context, AppState state) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider.value(
          value: state,
          child: const Scaffold(body: ConnectTab()),
        ),
        fullscreenDialog: true,
      ),
    ).then((_) { if (mounted) _loadSessions(); });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = context.watch<AppState>();

    // Auto-load sessions whenever we become connected and have nothing loaded.
    if (state.isConnected && _sessions.isEmpty && !_loading && _error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadSessions();
      });
    }

    if (!state.isConnected) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Tmux'),
          actions: [const ThemeSwitchButton(), const ConnectionButton()],
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off, size: 48, color: AppTheme.textSecondary),
              const SizedBox(height: 16),
              const Text(
                'Not connected',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 16),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => _openConnectPage(context, state),
                icon: const Icon(Icons.link),
                label: const Text('Connect'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tmux'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            color: AppTheme.primaryBlue,
            onPressed: _loading ? null : _loadSessions,
          ),
          const ThemeSwitchButton(),
          const ConnectionButton(),
        ],
      ),
      body: Column(
        children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Sessions',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
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
      ),
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
        if (_expanded) ...[
          _PaneLayoutOverview(
            panes: window.panes,
            onPaneTap: widget.onPaneTap,
          ),
          ...window.panes.map((pane) => InkWell(
                onTap: () => widget.onPaneTap(pane.id),
                child: Padding(
                  padding: const EdgeInsets.only(left: 60, right: 12, top: 4, bottom: 4),
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
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Pane layout overview: scaled diagram showing spatial positions of panes.

class _PaneLayoutOverview extends StatelessWidget {
  final List<_PaneData> panes;
  final void Function(String paneId) onPaneTap;

  const _PaneLayoutOverview({required this.panes, required this.onPaneTap});

  @override
  Widget build(BuildContext context) {
    if (panes.length <= 1) return const SizedBox.shrink();

    int maxRight = 0;
    int maxBottom = 0;
    for (final p in panes) {
      final r = p.left + p.width;
      final b = p.top + p.height;
      if (r > maxRight) maxRight = r;
      if (b > maxBottom) maxBottom = b;
    }
    if (maxRight == 0 || maxBottom == 0) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(left: 48, right: 12, top: 4, bottom: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableW = constraints.maxWidth;
          final ratio = maxBottom / maxRight;
          // Ensure each pane is at least 22px tall so numbers are legible.
          final minPaneTermRows =
              panes.map((p) => p.height).reduce(math.min);
          final minRequired = minPaneTermRows > 0
              ? (maxBottom * 22.0 / minPaneTermRows)
              : 56.0;
          final diagramH = math
              .max((availableW * ratio).clamp(56.0, 120.0), minRequired)
              .clamp(0.0, 240.0);
          final scaleX = availableW / maxRight;
          final scaleY = diagramH / maxBottom;

          return SizedBox(
            height: diagramH,
            child: Stack(
              children: [
                // Background border
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                // Each pane rectangle
                ...panes.map((pane) => Positioned(
                      left: pane.left * scaleX,
                      top: pane.top * scaleY,
                      width: pane.width * scaleX,
                      height: pane.height * scaleY,
                      child: GestureDetector(
                        onTap: () => onPaneTap(pane.id),
                        child: Container(
                          margin: const EdgeInsets.all(1.5),
                          decoration: BoxDecoration(
                            color: pane.active
                                ? Colors.green.withValues(alpha: 0.25)
                                : (isDark
                                    ? Colors.blueGrey.withValues(alpha: 0.2)
                                    : Colors.blueGrey.withValues(alpha: 0.12)),
                            border: Border.all(
                              color: pane.active ? Colors.green : Colors.blueGrey,
                              width: pane.active ? 1.5 : 1.0,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${pane.index}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: pane.active ? Colors.green : Colors.blueGrey,
                            ),
                          ),
                        ),
                      ),
                    )),
              ],
            ),
          );
        },
      ),
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
  // Pinch-to-zoom raw pointer tracking (bypasses gesture arena)
  final Map<int, Offset> _pointers = {};
  double _initialPinchDistance = 0;
  double _fontSizeAtPinchStart = 13.0;
  int _lastCols = 80;
  int _lastRows = 25;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    _terminal.onOutput = (data) => _session?.stdin.add(Uint8List.fromList(utf8.encode(data)));
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

      Future.delayed(const Duration(milliseconds: 800), () async {
        if (!mounted) return;
        try {
          if (widget.initialPaneId != null) {
            // Zoom the requested pane via separate SSH exec (not PTY stdin).
            await widget.state.sshService.executeCommand(
              'tmux select-pane -t ${widget.initialPaneId} && '
              'tmux resize-pane -Z -t ${widget.initialPaneId}',
            );
          } else {
            // Connecting to a session/window: unzoom any currently zoomed pane
            // so the full window layout is visible.
            final target = widget.initialWindowIndex != null
                ? '${widget.sessionName}:${widget.initialWindowIndex}'
                : widget.sessionName;
            await widget.state.sshService.executeCommand(
              '[ "\$(tmux display-message -p \'#{window_zoomed_flag}\' -t $target 2>/dev/null)" = "1" ] && '
              'tmux resize-pane -Z -t $target || true',
            );
          }
        } catch (_) {}
      });
    } catch (e) {
      if (mounted) {
        _terminal.write('\r\nError: $e\r\n');
        setState(() => _exited = true);
      }
    }
  }

  void _sendRaw(List<int> bytes) {
    _session?.stdin.add(Uint8List.fromList(bytes));
  }

  void _sendKey(String key) {
    final dashIdx = key.indexOf('-');
    if (dashIdx > 0) {
      // Key has modifier prefix, e.g. "C-v", "CS-Up", "CSA-b"
      final mods = key.substring(0, dashIdx);
      final base = key.substring(dashIdx + 1);
      _sendModified(base,
          ctrl: mods.contains('C'),
          shift: mods.contains('S'),
          alt: mods.contains('A'));
      return;
    }
    switch (key) {
      case 'Escape': _sendRaw([0x1b]);
      case 'Tab':    _sendRaw([0x09]);
      case 'Enter':  _sendRaw([0x0d]);
      case 'Home':   _sendRaw([0x1b, 0x5b, 0x48]);
      case 'End':    _sendRaw([0x1b, 0x5b, 0x46]);
      case 'Delete': _sendRaw([0x1b, 0x5b, 0x33, 0x7e]);
      case 'Up':     _sendRaw([0x1b, 0x5b, 0x41]);
      case 'Down':   _sendRaw([0x1b, 0x5b, 0x42]);
      case 'Right':  _sendRaw([0x1b, 0x5b, 0x43]);
      case 'Left':   _sendRaw([0x1b, 0x5b, 0x44]);
    }
  }

  // xterm modifier encoding: code = 1 + Shift(1) + Alt(2) + Ctrl(4)
  void _sendModified(String base, {bool ctrl = false, bool shift = false, bool alt = false}) {
    final code = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
    switch (base) {
      case 'Up':    _sendRaw([0x1b, 0x5b, 0x31, 0x3b, 0x30 + code, 0x41]); return;
      case 'Down':  _sendRaw([0x1b, 0x5b, 0x31, 0x3b, 0x30 + code, 0x42]); return;
      case 'Right': _sendRaw([0x1b, 0x5b, 0x31, 0x3b, 0x30 + code, 0x43]); return;
      case 'Left':  _sendRaw([0x1b, 0x5b, 0x31, 0x3b, 0x30 + code, 0x44]); return;
    }
    if (base.length != 1) return;
    final ch = base.toLowerCase().codeUnitAt(0);
    final bytes = <int>[];
    if (alt) bytes.add(0x1b);                          // Alt → ESC prefix
    if (ctrl && ch >= 97 && ch <= 122) {
      bytes.add(ch - 96);                              // Ctrl+letter → 0x01–0x1a
    } else if (shift) {
      bytes.add(base.toUpperCase().codeUnitAt(0));     // Shift+letter → uppercase
    } else {
      bytes.add(ch);
    }
    if (bytes.isNotEmpty) _sendRaw(bytes);
  }

  @override
  void dispose() {
    // If we zoomed a pane, unzoom it when navigating away (X button / back).
    // Fire-and-forget — we don't await since dispose() is synchronous.
    if (widget.initialPaneId != null && widget.state.sshService.isConnected) {
      widget.state.sshService.executeCommand(
        'tmux resize-pane -Z -t ${widget.initialPaneId} 2>/dev/null || true',
      ).catchError((_) => '');
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _session?.close();
    _terminalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    if (isLandscape) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }

    // Use raw Listener for pinch-to-zoom to bypass the gesture arena
    // (TerminalView's own gesture recognizers would win otherwise).
    final terminalWidget = Listener(
      onPointerDown: (e) {
        _pointers[e.pointer] = e.localPosition;
        if (_pointers.length == 2) {
          final pts = _pointers.values.toList();
          _initialPinchDistance = (pts[0] - pts[1]).distance;
          _fontSizeAtPinchStart = _fontSize;
        }
      },
      onPointerMove: (e) {
        _pointers[e.pointer] = e.localPosition;
        if (_pointers.length == 2 && _initialPinchDistance > 0) {
          final pts = _pointers.values.toList();
          final dist = (pts[0] - pts[1]).distance;
          setState(() {
            _fontSize = (_fontSizeAtPinchStart * dist / _initialPinchDistance).clamp(7.0, 28.0);
          });
        }
      },
      onPointerUp: (e) => _pointers.remove(e.pointer),
      onPointerCancel: (e) => _pointers.remove(e.pointer),
      child: Container(
        color: Colors.black,
        child: TerminalView(
          _terminal,
          controller: _terminalController,
          padding: EdgeInsets.zero,
          textStyle: TerminalStyle(fontSize: _fontSize),
        ),
      ),
    );

    return Scaffold(
      appBar: isLandscape
          ? null
          : AppBar(
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
                terminalWidget,
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
          SpecialKeysBar(onKey: _sendKey),
        ],
      ),
    );
  }
}


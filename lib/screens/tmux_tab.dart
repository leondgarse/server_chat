import 'dart:convert';
import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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

const _lightTerminalTheme = TerminalTheme(
  cursor: Color(0xFF0d33f2),
  selection: Color(0x440d33f2),
  foreground: Color(0xFF101322),
  background: Color(0xFFf5f6f8),
  black: Color(0xFF101322),
  red: Color(0xFFCD3131),
  green: Color(0xFF0A8754),
  yellow: Color(0xFF866B00),
  blue: Color(0xFF0d33f2),
  magenta: Color(0xFFBC3FBC),
  cyan: Color(0xFF008B8B),
  white: Color(0xFF6E7681),
  brightBlack: Color(0xFF555F6E),
  brightRed: Color(0xFFCD3131),
  brightGreen: Color(0xFF0A8754),
  brightYellow: Color(0xFFB8860B),
  brightBlue: Color(0xFF2472C8),
  brightMagenta: Color(0xFFD670D6),
  brightCyan: Color(0xFF11A8CD),
  brightWhite: Color(0xFF101322),
  searchHitBackground: Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: Color(0xFF31FF26),
  searchHitForeground: Color(0xFF000000),
);

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
  final String? currentCommand;
  _PaneData({
    required this.index,
    required this.id,
    required this.active,
    required this.width,
    required this.height,
    required this.left,
    required this.top,
    this.currentCommand,
  });
}

class _WindowData {
  final int index;
  final String name;
  final bool active;
  final bool zoomed;
  final List<_PaneData> panes;
  _WindowData({
    required this.index,
    required this.name,
    required this.active,
    required this.zoomed,
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
        '"#{session_name}|||#{session_attached}|||#{window_index}|||#{window_name}|||#{window_active}|||#{pane_index}|||#{pane_id}|||#{pane_active}|||#{pane_width}|||#{pane_height}|||#{pane_left}|||#{pane_top}|||#{pane_current_command}|||#{window_zoomed_flag}"'
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
      final paneCurrentCommand = parts.length > 12 ? parts[12] : null;
      final windowZoomed = parts.length > 13 ? parts[13] == '1' : false;

      final winKey = '$sessionName|||$windowIndex';

      windowMeta[winKey] = {
        'index': windowIndex,
        'name': windowName,
        'active': windowActive,
        'zoomed': windowZoomed,
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
        currentCommand: paneCurrentCommand,
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
          zoomed: winEntry.value['zoomed'] as bool,
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
                      Expanded(
                        child: Text(
                          pane.currentCommand != null && pane.currentCommand!.isNotEmpty
                              ? 'Pane ${pane.index}  ${pane.currentCommand}  ${pane.width}×${pane.height}'
                              : 'Pane ${pane.index}  ${pane.width}×${pane.height}',
                          style: TextStyle(
                            fontSize: 12,
                            color: pane.active ? Colors.green : AppTheme.textSecondary,
                          ),
                          overflow: TextOverflow.ellipsis,
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
  // Window/pane nav bar data
  List<_WindowData> _windows = [];
  int _activeWindowIndex = 0;
  String? _activePaneId;
  // Tmux prefix key (e.g. 'C-b' or 'C-s'), loaded from SharedPreferences.
  String _tmuxPrefix = 'C-b';
  // Tmux copy-mode scroll state
  bool _inCopyMode = false;
  double _dragAccum = 0; // accumulated vertical drag pixels
  bool _dragActive = false; // true once drag threshold crossed (survives rebuilds)
  String? _scrollTargetPaneId; // pane under the finger when drag started
  final GlobalKey _terminalKey = GlobalKey(); // for hit-testing pane at touch pos

  @override
  void initState() {
    super.initState();
    _activeWindowIndex = widget.initialWindowIndex ?? 0;
    _activePaneId = widget.initialPaneId;
    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    _terminal.onOutput = (data) => _session?.stdin.add(Uint8List.fromList(utf8.encode(data)));
    _terminal.onResize = (w, h, pw, ph) {
      _lastCols = w;
      _lastRows = h;
      _session?.resizeTerminal(w, h);
    };
    _startSession();
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('tmux_prefix');
      if (saved != null && saved.isNotEmpty && mounted) {
        setState(() => _tmuxPrefix = saved);
      }
    });
  }

  Future<void> _saveTmuxPrefix(String prefix) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tmux_prefix', prefix);
    if (mounted) setState(() => _tmuxPrefix = prefix);
  }

  Future<void> _loadWindowPaneData() async {
    try {
      final out = await widget.state.sshService.executeCommand(
        'tmux list-panes -t ${widget.sessionName} -a -F '
        '"#{window_index}|||#{window_name}|||#{window_active}|||#{pane_index}|||#{pane_id}|||#{pane_active}|||#{pane_width}|||#{pane_height}|||#{pane_left}|||#{pane_top}|||#{pane_current_command}|||#{window_zoomed_flag}"'
        ' 2>/dev/null',
      );
      final Map<int, Map<String, dynamic>> winMeta = {};
      final Map<int, List<_PaneData>> winPanes = {};
      for (final line in out.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty)) {
        final p = line.split('|||');
        if (p.length < 11) continue;
        final wi = int.tryParse(p[0]) ?? 0;
        winMeta.putIfAbsent(wi, () => {'name': p[1], 'active': p[2] == '1', 'zoomed': p.length > 11 ? p[11] == '1' : false});
        winPanes.putIfAbsent(wi, () => []).add(_PaneData(
          index: int.tryParse(p[3]) ?? 0,
          id: p[4],
          active: p[5] == '1',
          width: int.tryParse(p[6]) ?? 80,
          height: int.tryParse(p[7]) ?? 24,
          left: int.tryParse(p[8]) ?? 0,
          top: int.tryParse(p[9]) ?? 0,
          currentCommand: p.length > 10 ? p[10] : null,
        ));
      }
      final windows = winMeta.entries.map((e) => _WindowData(
        index: e.key,
        name: e.value['name'] as String,
        active: e.value['active'] as bool,
        zoomed: e.value['zoomed'] as bool,
        panes: winPanes[e.key] ?? [],
      )).toList()..sort((a, b) => a.index.compareTo(b.index));

      if (!mounted) return;
      setState(() {
        _windows = windows;
        final activeWin = windows.firstWhere((w) => w.active, orElse: () => windows.isNotEmpty ? windows.first : _WindowData(index: 0, name: '', active: false, zoomed: false, panes: []));
        _activeWindowIndex = activeWin.index;
        final activePaneInWin = activeWin.panes.firstWhere((p) => p.active, orElse: () => activeWin.panes.isNotEmpty ? activeWin.panes.first : _PaneData(index: 0, id: '', active: false, width: 80, height: 24, left: 0, top: 0));
        _activePaneId ??= activePaneInWin.id.isNotEmpty ? activePaneInWin.id : null;
      });

      // If we're NOT in pane-zoom mode and there's a zoomed window, unzoom it
      if (widget.initialPaneId == null) {
        final zoomedWindows = windows.where((w) => w.zoomed).toList();
        if (zoomedWindows.isNotEmpty) {
          for (final w in zoomedWindows) {
            widget.state.sshService.executeCommand(
              'tmux resize-pane -Z -t ${widget.sessionName}:${w.index} 2>/dev/null || true',
            ).catchError((_) => '');
          }
        }
      }
    } catch (_) {}
  }

  // ---- Tmux copy-mode scroll -----------------------------------------------

  String get _currentTarget {
    if (_scrollTargetPaneId != null) return _scrollTargetPaneId!;
    if (_activePaneId != null) return _activePaneId!;
    // Try to derive active pane id from loaded window data before falling back.
    final win = _windows.isEmpty ? null
        : _windows.firstWhere((w) => w.index == _activeWindowIndex,
            orElse: () => _windows.first);
    final pane = win?.panes.firstWhere((p) => p.active,
        orElse: () => win.panes.isNotEmpty ? win.panes.first : _PaneData(index: 0, id: '', active: false, width: 80, height: 24, left: 0, top: 0));
    if (pane != null && pane.id.isNotEmpty) return pane.id;
    return '${widget.sessionName}:$_activeWindowIndex';
  }

  /// Find which pane (from [_windows]) the pixel position [pos] falls in,
  /// given the terminal widget's pixel [size]. Returns pane id or null.
  String? _paneIdAtPixel(Offset pos, Size size) {
    final win = _windows.isEmpty ? null
        : _windows.firstWhere((w) => w.index == _activeWindowIndex,
            orElse: () => _windows.first);
    if (win == null || win.panes.isEmpty) return null;
    if (win.panes.length == 1) return win.panes.first.id;
    // Derive total terminal grid from the union of pane extents, not _lastCols/Rows,
    // so cell size is accurate even before the first resize event fires.
    int totalCols = 0, totalRows = 0;
    for (final p in win.panes) {
      final r = p.left + p.width;
      final b = p.top + p.height;
      if (r > totalCols) totalCols = r;
      if (b > totalRows) totalRows = b;
    }
    // Fall back to _lastCols/_lastRows if pane data is missing.
    if (totalCols <= 0) totalCols = _lastCols;
    if (totalRows <= 0) totalRows = _lastRows;
    if (totalCols <= 0 || totalRows <= 0) return null;
    final cellW = size.width / totalCols;
    final cellH = size.height / totalRows;
    final col = pos.dx / cellW;
    final row = pos.dy / cellH;
    // Find closest pane — use centre-distance to handle separator columns
    // gracefully rather than strict boundary membership.
    _PaneData? best;
    double bestDist = double.infinity;
    for (final pane in win.panes) {
      final cx = pane.left + pane.width / 2.0;
      final cy = pane.top  + pane.height / 2.0;
      final dx = col - cx;
      final dy = row - cy;
      // Weight horizontal distance more to handle left/right splits better.
      final dist = dx * dx * 1.5 + dy * dy;
      if (dist < bestDist) {
        bestDist = dist;
        best = pane;
      }
    }
    return best?.id;
  }

  /// Scroll up/down N lines in tmux copy-mode via SSH exec.
  /// lines > 0 = scroll-up (finger dragged down), lines < 0 = scroll-down.
  /// When scrolling down and the offset reaches 0 (bottom), exits copy-mode automatically.
  void _tmuxScroll(int lines) {
    if (!widget.state.sshService.isConnected) return;
    if (!_inCopyMode) setState(() => _inCopyMode = true);
    final target = _currentTarget;
    final dir = lines > 0 ? 'scroll-up' : 'scroll-down';
    final count = lines.abs();
    final scrollKeys = List.filled(count, "tmux send-keys -X -t '$target' $dir").join('; ');

    if (lines < 0) {
      // Scroll-down: after scrolling, check if we've hit the bottom (offset=0).
      // If so, exit copy-mode automatically.
      widget.state.sshService.executeCommandFast(
        "tmux copy-mode -t '$target'; $scrollKeys; "
        "tmux display-message -p -t '$target' '#{scroll_position}'",
      ).then((out) {
        final offset = int.tryParse(out.trim()) ?? -1;
        if (offset == 0 && mounted) _exitCopyMode();
      }).catchError((e) { debugPrint('[tmux-scroll] error: $e'); });
    } else {
      widget.state.sshService.executeCommandFast(
        "tmux copy-mode -t '$target'; $scrollKeys",
      ).catchError((e) { debugPrint('[tmux-scroll] error: $e'); return ''; });
    }
  }

  void _exitCopyMode() {
    if (!_inCopyMode) return;
    setState(() => _inCopyMode = false);
    // Send cancel via the attached PTY stdin — tmux receives it directly.
    _session?.stdin.add(utf8.encode('q'));
  }

  void _switchToWindow(int windowIndex) {
    widget.state.sshService.executeCommandFast(
      'tmux select-window -t ${widget.sessionName}:$windowIndex',
    ).catchError((_) => '');
    setState(() {
      _activeWindowIndex = windowIndex;
      _activePaneId = null;
    });
    Future.delayed(const Duration(milliseconds: 300), _loadWindowPaneData);
  }

  void _switchToPane(String paneId) {
    widget.state.sshService.executeCommandFast(
      'tmux select-pane -t $paneId && tmux resize-pane -Z -t $paneId',
    ).catchError((_) => '');
    setState(() => _activePaneId = paneId);
    Future.delayed(const Duration(milliseconds: 400), _loadWindowPaneData);
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
            // Zoom the requested pane. Select it first, then zoom.
            // Use executeCommandFast — no login shell overhead.
            await widget.state.sshService.executeCommandFast(
              'tmux select-pane -t ${widget.initialPaneId} && '
              'tmux resize-pane -Z -t ${widget.initialPaneId}',
            );
          } else {
            // Connecting to a session/window: unzoom any currently zoomed pane.
            final target = widget.initialWindowIndex != null
                ? '${widget.sessionName}:${widget.initialWindowIndex}'
                : widget.sessionName;
            await widget.state.sshService.executeCommandFast(
              '[ "\$(tmux display-message -p \'#{window_zoomed_flag}\' -t $target 2>/dev/null)" = "1" ] && '
              'tmux resize-pane -Z -t $target || true',
            );
          }
        } catch (_) {}
        // Load pane data AFTER zoom/unzoom so _windows reflects the correct state.
        if (mounted) _loadWindowPaneData();
      });
    } catch (e) {
      if (mounted) {
        _terminal.write('\r\nError: $e\r\n');
        setState(() => _exited = true);
      }
    }
  }

  /// Wraps _sendKey: routes keys appropriately based on mode.
  void _sendKeyWithCopyMode(String key) {
    if (_inCopyMode) {
      // In copy-mode: Up/Down scroll further; anything else exits first.
      if (key == 'Up') { _tmuxScroll(3); return; }
      if (key == 'Down') { _tmuxScroll(-3); return; }
      _exitCopyMode();
      if (key == 'Escape') return;
    }
    _sendKey(key);
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
    // If we zoomed a pane, unzoom it unconditionally on leave.
    // Use 'resize-pane -Z' only if currently zoomed (check flag first) to avoid
    // toggling back to zoomed state on a race with re-entry.
    if (widget.initialPaneId != null && widget.state.sshService.isConnected) {
      final svc = widget.state.sshService;
      final sessionName = widget.sessionName;
      svc.executeCommandFast(
        '[ "\$(tmux display-message -p \'#{window_zoomed_flag}\' -t $sessionName 2>/dev/null)" = "1" ] && '
        'tmux resize-pane -Z -t $sessionName || true',
      ).catchError((_) => '');
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _session?.close();
    _terminalController.dispose();
    super.dispose();
  }

  // ---- Breadcrumb helpers -------------------------------------------------

  Widget _breadcrumbItem(String label, {IconData? icon, bool isSelected = false, VoidCallback? onTap}) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: isSelected
            ? BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(4),
              )
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: cs.onSurface.withValues(alpha: 0.6)),
              const SizedBox(width: 4),
            ],
            Text(
              label.isEmpty ? '…' : label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                color: cs.onSurface.withValues(alpha: isSelected ? 0.9 : 0.55),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 2),
              Icon(Icons.arrow_drop_down, size: 14, color: cs.onSurface.withValues(alpha: 0.4)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _breadcrumbSeparator() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text('/', style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.2))),
    );
  }

  void _showWindowSelector() {
    if (_windows.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Icon(Icons.tab, color: cs.primary),
                    const SizedBox(width: 8),
                    Text('Select Window', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: cs.onSurface)),
                  ]),
                ),
                Divider(height: 1, color: cs.outline),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _windows.length,
                    itemBuilder: (_, i) {
                      final win = _windows[i];
                      final isActive = win.index == _activeWindowIndex;
                      return ListTile(
                        leading: Icon(Icons.tab, color: isActive ? cs.primary : cs.onSurface.withValues(alpha: 0.6)),
                        title: Text('${win.index}: ${win.name}',
                            style: TextStyle(color: isActive ? cs.primary : cs.onSurface, fontWeight: isActive ? FontWeight.bold : FontWeight.normal)),
                        subtitle: Text('${win.panes.length} pane${win.panes.length != 1 ? 's' : ''}',
                            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.38))),
                        trailing: isActive ? Icon(Icons.check, color: cs.primary) : null,
                        onTap: () { Navigator.pop(ctx); _switchToWindow(win.index); },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showPaneSelector() {
    final win = _windows.firstWhere((w) => w.index == _activeWindowIndex, orElse: () => _windows.isNotEmpty ? _windows.first : _WindowData(index: 0, name: '', active: false, zoomed: false, panes: []));
    if (win.panes.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Icon(Icons.terminal, color: cs.primary),
                    const SizedBox(width: 8),
                    Text('Select Pane', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: cs.onSurface)),
                  ]),
                ),
                Divider(height: 1, color: cs.outline),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: win.panes.length,
                    itemBuilder: (_, i) {
                      final pane = win.panes[i];
                      final isActive = pane.id == _activePaneId || (_activePaneId == null && pane.active);
                      final cmd = pane.currentCommand ?? '';
                      return ListTile(
                        leading: Icon(Icons.crop_square, size: 18, color: isActive ? Colors.green : cs.onSurface.withValues(alpha: 0.6)),
                        title: Text(
                          cmd.isNotEmpty ? '${pane.index}: $cmd' : 'Pane ${pane.index}',
                          style: TextStyle(color: isActive ? Colors.green : cs.onSurface, fontWeight: isActive ? FontWeight.bold : FontWeight.normal),
                        ),
                        subtitle: Text('${pane.width}×${pane.height}', style: TextStyle(color: cs.onSurface.withValues(alpha: 0.38))),
                        trailing: isActive ? const Icon(Icons.check, color: Colors.green) : null,
                        onTap: () { Navigator.pop(ctx); _switchToPane(pane.id); },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    if (isLandscape) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }

    final activeWin = _windows.isNotEmpty
        ? _windows.firstWhere((w) => w.index == _activeWindowIndex, orElse: () => _windows.first)
        : null;
    _PaneData? activePane;
    if (activeWin != null) {
      final panes = activeWin.panes;
      activePane = panes.firstWhere(
        (p) => p.id == _activePaneId || (_activePaneId == null && p.active),
        orElse: () => panes.isNotEmpty ? panes.first : _PaneData(index: 0, id: '', active: false, width: 80, height: 24, left: 0, top: 0),
      );
    }

    // Pixels of drag per tmux scroll line. Smaller = faster scrolling.
    const double pixelsPerLine = 18.0;
    // Minimum drag before scroll starts, to avoid accidental scrolls on taps.
    const double dragThreshold = 6.0;
    // Single Listener handles pinch-to-zoom, mouse-wheel scroll, AND
    // single-finger drag scroll. Using Listener (not GestureDetector) means
    // we never enter the gesture arena, so TerminalView cannot steal touches.
    // In pane-zoom mode: drag/wheel → xterm native scroll (instant, no SSH).
    // In session/multi-pane mode: drag/wheel → tmux copy-mode (SSH round-trip).
    final terminalWidget = Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          // scrollDelta.dy > 0 = wheel down = scroll toward older content (up)
          final lines = (e.scrollDelta.dy / pixelsPerLine).round();
          if (lines != 0) _tmuxScroll(lines);
        }
      },
      onPointerDown: (e) {
        _pointers[e.pointer] = e.localPosition;
        _dragActive = false;
        if (_pointers.length == 1) {
          if (widget.initialPaneId == null) {
            final rb = _terminalKey.currentContext?.findRenderObject() as RenderBox?;
            if (rb != null) {
              _scrollTargetPaneId = _paneIdAtPixel(e.localPosition, rb.size);
            }
          }
          _dragAccum = 0;
        } else if (_pointers.length == 2) {
          _dragAccum = 0;
          _dragActive = false;
          final pts = _pointers.values.toList();
          _initialPinchDistance = (pts[0] - pts[1]).distance;
          _fontSizeAtPinchStart = _fontSize;
        }
      },
      onPointerMove: (e) {
        final prev = _pointers[e.pointer];
        _pointers[e.pointer] = e.localPosition;
        if (_pointers.length == 2 && _initialPinchDistance > 0) {
          final pts = _pointers.values.toList();
          final dist = (pts[0] - pts[1]).distance;
          setState(() {
            _fontSize = (_fontSizeAtPinchStart * dist / _initialPinchDistance).clamp(7.0, 28.0);
          });
        } else if (_pointers.length == 1 && prev != null) {
          final dy = e.localPosition.dy - prev.dy;
          _dragAccum += dy;
          if (!_dragActive && _dragAccum.abs() < dragThreshold) return;
          _dragActive = true;
          final lines = (_dragAccum / pixelsPerLine).truncate();
          if (lines != 0) {
            _dragAccum -= lines * pixelsPerLine;
            // dy>0 = finger dragged down = scroll toward older content (up in buffer)
            _tmuxScroll(lines);
          }
        }
      },
      onPointerUp: (e) {
        _pointers.remove(e.pointer);
        if (_pointers.isEmpty) {
          _dragAccum = 0;
          _dragActive = false;
          _scrollTargetPaneId = null;
        }
      },
      onPointerCancel: (e) {
        _pointers.remove(e.pointer);
        if (_pointers.isEmpty) {
          _dragAccum = 0;
          _dragActive = false;
          _scrollTargetPaneId = null;
        }
      },
        child: Container(
          key: _terminalKey,
          color: isDark ? Colors.black : const Color(0xFFf5f6f8),
          child: TerminalView(
            _terminal,
            controller: _terminalController,

            theme: isDark ? TerminalThemes.defaultTheme : _lightTerminalTheme,
            padding: EdgeInsets.zero,
            textStyle: TerminalStyle(fontSize: _fontSize),
          ),
        ),
    );

    return Scaffold(
      appBar: isLandscape
          ? null
          : AppBar(
              title: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.sessionName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    if (widget.initialPaneId != null && activeWin != null) ...[
                      _breadcrumbSeparator(),
                      _breadcrumbItem(
                        '${activeWin.index}: ${activeWin.name}',
                        icon: Icons.tab_outlined,
                        isSelected: false,
                        onTap: _windows.length > 1 ? _showWindowSelector : null,
                      ),
                      if (activePane != null && activeWin.panes.length > 1) ...[
                        _breadcrumbSeparator(),
                        _breadcrumbItem(
                          activePane.currentCommand?.isNotEmpty == true
                              ? '${activePane.index}: ${activePane.currentCommand}'
                              : 'Pane ${activePane.index}',
                          icon: Icons.terminal,
                          isSelected: false,
                          onTap: _showPaneSelector,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
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
                // Copy-mode badge (window/multi-pane mode only) — tap to exit
                if (_inCopyMode && widget.initialPaneId == null)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: GestureDetector(
                      onTap: _exitCopyMode,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.unfold_more, size: 12, color: Colors.white),
                            SizedBox(width: 4),
                            Text('SCROLL  ✕', style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
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
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
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
          SpecialKeysBar(
            onKey: _sendKeyWithCopyMode,
            prefix: _tmuxPrefix,
            onPrefixChanged: _saveTmuxPrefix,
          ),
        ],
      ),
    );
  }
}


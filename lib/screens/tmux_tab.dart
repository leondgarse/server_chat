import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';
import '../models/app_state.dart';
import '../utils/theme.dart';
import '../widgets/connection_button.dart';

class TmuxTab extends StatefulWidget {
  const TmuxTab({super.key});

  @override
  State<TmuxTab> createState() => _TmuxTabState();
}

class _TmuxTabState extends State<TmuxTab> with AutomaticKeepAliveClientMixin {
  List<String> _sessions = [];
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
      final output = await state.sshService.executeCommand(
        'tmux list-sessions -F "#{session_name} #{session_windows}w #{session_attached}" 2>/dev/null || echo "NO_SESSIONS"',
      );

      final lines = output
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      if (lines.length == 1 && lines.first == 'NO_SESSIONS') {
        setState(() {
          _sessions = [];
          _loading = false;
        });
      } else {
        setState(() {
          _sessions = lines.where((l) => l != 'NO_SESSIONS').toList();
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
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

  void _openSession(AppState state, String sessionLine) {
    final name = sessionLine.split(' ').first;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChangeNotifierProvider.value(
          value: state,
          child: TmuxSessionPage(sessionName: name, state: state),
        ),
        fullscreenDialog: true,
      ),
    );
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
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: _sessions.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final line = _sessions[index];
                        final parts = line.split(' ');
                        final name = parts.first;
                        final meta = parts.length > 1
                            ? parts.sublist(1).join(' ')
                            : '';
                        return ListTile(
                          leading: const Icon(
                            Icons.terminal,
                            color: AppTheme.primaryBlue,
                          ),
                          title: Text(name),
                          subtitle: meta.isNotEmpty ? Text(meta) : null,
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openSession(state, line),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class TmuxSessionPage extends StatefulWidget {
  final String sessionName;
  final AppState state;

  const TmuxSessionPage({
    super.key,
    required this.sessionName,
    required this.state,
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
  // Stores the last known terminal dimensions from TerminalView layout.
  int _lastCols = 80;
  int _lastRows = 25;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    // Forward terminal responses (device queries, mouse reports) to the PTY.
    _terminal.onOutput = (data) => _session?.stdin.add(utf8.encode(data));
    // Keep PTY size in sync with the xterm widget.
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

      // Sync PTY to the dimensions TerminalView may have already reported
      // while the SSH handshake was in progress.
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

      // Now that the PTY has the correct size, attach tmux so it renders
      // the status-bar and windows at the right rows/columns.
      session.stdin.add(utf8.encode(
        'tmux set -g mouse on 2>/dev/null; tmux attach -t ${widget.sessionName}\n',
      ));
    } catch (e) {
      if (mounted) {
        _terminal.write('\r\nError: $e\r\n');
        setState(() => _exited = true);
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
      body: Stack(
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
    );
  }
}

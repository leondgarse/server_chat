import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';
import '../models/app_state.dart';
import '../utils/theme.dart';
import '../widgets/connection_button.dart';
import '../widgets/theme_switch_button.dart';
import '../widgets/special_keys_bar.dart';

// Light terminal theme matching the app's light background colours.
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

class PtyTab extends StatefulWidget {
  const PtyTab({super.key});

  @override
  State<PtyTab> createState() => _PtyTabState();
}

class _PtyTabState extends State<PtyTab> with AutomaticKeepAliveClientMixin {
  late Terminal _terminal;
  late TerminalController _terminalController;
  SSHSession? _session;
  bool _isRunning = false;
  bool _starting = false;
  bool _exited = false;
  int _lastCols = 80;
  int _lastRows = 24;

  // Command suggestion state
  final StringBuffer _inputBuffer = StringBuffer();
  List<String> _suggestions = [];
  Timer? _suggestionDebounce;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _initTerminal();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startSession());
  }

  void _initTerminal() {
    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    _terminal.onOutput = (data) {
      _session?.stdin.add(Uint8List.fromList(utf8.encode(data)));
      _trackInput(data);
    };
    _terminal.onResize = (w, h, pw, ph) {
      _lastCols = w;
      _lastRows = h;
      _session?.resizeTerminal(w, h);
    };
  }

  void _trackInput(String data) {
    for (final ch in data.runes) {
      if (ch == 0x0d || ch == 0x0a) {
        // Enter — clear buffer and suggestions
        _inputBuffer.clear();
        _cancelSuggestions();
      } else if (ch == 0x7f || ch == 0x08) {
        // Backspace
        final s = _inputBuffer.toString();
        if (s.isNotEmpty) {
          _inputBuffer.clear();
          _inputBuffer.write(s.substring(0, s.length - 1));
        }
        _scheduleSuggestions();
      } else if (ch == 0x03 || ch == 0x04 || ch == 0x1b) {
        // Ctrl-C / Ctrl-D / Escape — clear
        _inputBuffer.clear();
        _cancelSuggestions();
      } else if (ch >= 0x20) {
        _inputBuffer.write(String.fromCharCode(ch));
        _scheduleSuggestions();
      }
    }
  }

  void _scheduleSuggestions() {
    _suggestionDebounce?.cancel();
    final prefix = _inputBuffer.toString().trim();
    if (prefix.isEmpty) {
      _cancelSuggestions();
      return;
    }
    _suggestionDebounce = Timer(const Duration(milliseconds: 300), () {
      _fetchSuggestions(prefix);
    });
  }

  void _cancelSuggestions() {
    _suggestionDebounce?.cancel();
    if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
  }

  Future<void> _fetchSuggestions(String prefix) async {
    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) return;
    try {
      // Escape single quotes in prefix for shell safety
      final escaped = prefix.replaceAll("'", "'\\''");
      final raw = await state.sshService.executeCommandFast(
        "grep -F '$escaped' ~/.bash_history 2>/dev/null | grep -v '^\\s*\$' | tail -40 | sort -u | tail -20",
      );
      if (!mounted) return;
      final current = _inputBuffer.toString().trim();
      if (!current.startsWith(prefix.substring(0, prefix.length > current.length ? current.length : prefix.length))) return;
      final lines = raw
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && l != prefix)
          .toList()
          .reversed
          .toList();
      setState(() => _suggestions = lines);
    } catch (_) {
      // Silently ignore fetch errors
    }
  }

  void _applySuggestion(String suggestion) {
    final current = _inputBuffer.toString();
    // Send backspaces to clear current input
    if (current.isNotEmpty) {
      _session?.stdin.add(Uint8List.fromList(List.filled(current.length, 0x7f)));
    }
    // Send the suggestion
    _session?.stdin.add(utf8.encode(suggestion));
    _inputBuffer.clear();
    _inputBuffer.write(suggestion);
    _cancelSuggestions();
  }

  @override
  void dispose() {
    _suggestionDebounce?.cancel();
    _session?.close();
    super.dispose();
  }

  Future<void> _startSession() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) return;
    if (_isRunning || _starting) return;
    _starting = true;

    setState(() { _exited = false; });

    try {
      final session = await state.sshService.startInteractiveShell(
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
        if (mounted) setState(() { _isRunning = false; _exited = true; });
      });

      final path = state.currentPath;
      if (path.isNotEmpty) {
        session.stdin.add(utf8.encode('cd "$path"\n'));
      }

      if (mounted) setState(() => _isRunning = true);
    } catch (e) {
      _terminal.write('\r\nError starting PTY: $e\r\n');
    } finally {
      _starting = false;
    }
  }

  void _reconnect() {
    _session?.close();
    _session = null;
    _inputBuffer.clear();
    _cancelSuggestions();
    _initTerminal();
    setState(() { _isRunning = false; _starting = false; _exited = false; });
    _startSession();
  }

  /// Send a command to the running PTY session (called from TerminalTab).
  void runCommand(String cmd) {
    if (_session == null || !_isRunning) return;
    _session!.stdin.add(utf8.encode('$cmd\r'));
  }

  void _sendRaw(List<int> bytes) {
    _session?.stdin.add(Uint8List.fromList(bytes));
  }

  // xterm modifier encoding: code = 1 + Shift(1) + Alt(2) + Ctrl(4)
  void _sendKey(String key) {
    final dashIdx = key.indexOf('-');
    if (dashIdx > 0) {
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

  void _sendModified(String base,
      {bool ctrl = false, bool shift = false, bool alt = false}) {
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
    if (alt) bytes.add(0x1b);
    if (ctrl && ch >= 97 && ch <= 122) {
      bytes.add(ch - 96);
    } else if (shift) {
      bytes.add(base.toUpperCase().codeUnitAt(0));
    } else {
      bytes.add(ch);
    }
    if (bytes.isNotEmpty) _sendRaw(bytes);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = Provider.of<AppState>(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Auto-start when connection becomes available
    if (state.isConnected && !_isRunning && !_exited) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startSession());
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('PTY Shell'),
        actions: [
          if (_exited)
            IconButton(
              icon: const Icon(Icons.refresh, size: 20, color: Colors.orange),
              onPressed: state.isConnected ? _reconnect : null,
              tooltip: 'Reconnect PTY',
            ),
          const ThemeSwitchButton(),
          const ConnectionButton(),
        ],
      ),
      body: !state.isConnected
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.terminal, size: 48, color: AppTheme.textSecondary),
                  const SizedBox(height: 12),
                  const Text('Not connected', style: TextStyle(color: AppTheme.textSecondary)),
                  const SizedBox(height: 16),
                  const ConnectionButton(),
                ],
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: TerminalView(
                    _terminal,
                    controller: _terminalController,
                    theme: isDark ? TerminalThemes.defaultTheme : _lightTerminalTheme,
                    textStyle: const TerminalStyle(fontSize: 13),
                    padding: const EdgeInsets.all(4),
                  ),
                ),
                if (_suggestions.isNotEmpty)
                  _SuggestionBar(
                    suggestions: _suggestions,
                    onSelected: _applySuggestion,
                    isDark: isDark,
                  ),
                SpecialKeysBar(onKey: _sendKey),
              ],
            ),
    );
  }
}

class _SuggestionBar extends StatelessWidget {
  const _SuggestionBar({
    required this.suggestions,
    required this.onSelected,
    required this.isDark,
  });

  final List<String> suggestions;
  final ValueChanged<String> onSelected;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xFF1e2235) : const Color(0xFFe8eaf0);
    final chipBg = isDark ? const Color(0xFF2a3050) : Colors.white;
    final chipBorder = isDark ? const Color(0xFF3d4870) : const Color(0xFFc5c8d8);
    final textColor = isDark ? const Color(0xFFd0d4e8) : const Color(0xFF2a2f4a);

    return Container(
      height: 36,
      color: bg,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        itemCount: suggestions.length,
        separatorBuilder: (context, i) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final cmd = suggestions[i];
          return GestureDetector(
            onTap: () => onSelected(cmd),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                color: chipBg,
                border: Border.all(color: chipBorder),
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: Text(
                cmd,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: textColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
        },
      ),
    );
  }
}

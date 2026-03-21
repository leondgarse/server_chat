import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';
import '../models/app_state.dart';
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

/// A full-screen interactive shell page for commands like python, bash, etc.
/// Uses a real xterm Terminal so TUI apps (claude, vim, htop, ipython) render correctly.
class InteractiveShellPage extends StatefulWidget {
  final String command;
  final String workingDir;

  const InteractiveShellPage({super.key, required this.command, required this.workingDir});

  @override
  State<InteractiveShellPage> createState() => _InteractiveShellPageState();
}

class _InteractiveShellPageState extends State<InteractiveShellPage> {
  late final Terminal _terminal;
  late final TerminalController _terminalController;
  SSHSession? _session;
  bool _exited = false;
  int _lastCols = 80;
  int _lastRows = 24;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    _terminal.onOutput = (data) {
      _session?.stdin.add(Uint8List.fromList(utf8.encode(data)));
    };
    _terminal.onResize = (w, h, pw, ph) {
      _lastCols = w;
      _lastRows = h;
      _session?.resizeTerminal(w, h);
    };
    _startSession();
  }

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }

  Future<void> _startSession() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) return;

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
        if (mounted) setState(() => _exited = true);
      });

      // cd to working dir and run the command
      session.stdin.add(utf8.encode('cd "${widget.workingDir}" && ${widget.command}\n'));
    } catch (e) {
      _terminal.write('\r\nError: $e\r\n');
    }
  }

  void _sendRaw(List<int> bytes) {
    _session?.stdin.add(Uint8List.fromList(bytes));
  }

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: Text(_exited ? '${widget.command}  [exited]' : widget.command),
      ),
      body: Column(
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
          SpecialKeysBar(onKey: _sendKey),
        ],
      ),
    );
  }
}

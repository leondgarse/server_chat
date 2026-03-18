import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dartssh2/dartssh2.dart';
import '../models/app_state.dart';
import '../models/chat_message.dart';
import '../utils/theme.dart';
import '../widgets/special_keys_bar.dart';

/// A full-screen interactive shell page for commands like python, bash, etc.
class InteractiveShellPage extends StatefulWidget {
  final String command;
  final String workingDir;

  const InteractiveShellPage({super.key, required this.command, required this.workingDir});

  @override
  State<InteractiveShellPage> createState() => _InteractiveShellPageState();
}

class _InteractiveShellPageState extends State<InteractiveShellPage> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  SSHSession? _session;
  bool _isRunning = false;
  String _outputBuffer = '';

  @override
  void initState() {
    super.initState();
    _startSession();
  }

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _startSession() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) return;

    try {
      _session = await state.sshService.startInteractiveShell();
      setState(() => _isRunning = true);

      // cd to working dir and run the command
      _session!.write(utf8.encode('cd "${widget.workingDir}" && ${widget.command}\n'));

      _session!.stdout.listen((data) {
        if (!mounted) return;
        String text = utf8.decode(data);
        // Strip ANSI
        text = text.replaceAll(RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|].*?\x07)'), '');
        text = text.replaceAll('\r', '');
        _handleOutput(text);
      }, onDone: () {
        if (!mounted) return;
        setState(() {
          _flushBuffer();
          _isRunning = false;
          _messages.add(ChatMessage(text: '--- Session ended ---', isUser: false));
        });
      });

      _session!.stderr.listen((data) {
        if (!mounted) return;
        String text = utf8.decode(data);
        text = text.replaceAll(RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|].*?\x07)'), '');
        text = text.replaceAll('\r', '');
        _handleOutput(text);
      });
    } catch (e) {
      setState(() {
        _messages.add(ChatMessage(text: 'Error: $e', isUser: false));
      });
    }
  }

  void _handleOutput(String chunk) {
    setState(() {
      _outputBuffer += chunk;
      // Flush on newline
      if (_outputBuffer.contains('\n')) {
        _flushBuffer();
      }
    });
  }

  void _flushBuffer() {
    if (_outputBuffer.trim().isNotEmpty) {
      _messages.add(ChatMessage(text: _outputBuffer.trim(), isUser: false));
      _scrollToBottom();
    }
    _outputBuffer = '';
  }

  void _sendInput(String text) {
    if (text.isEmpty || _session == null) return;
    setState(() {
      _messages.add(ChatMessage(text: text, isUser: true));
    });
    _session!.write(utf8.encode('$text\n'));
    _inputController.clear();
    _scrollToBottom();
  }

  void _sendRaw(List<int> bytes) {
    _session?.write(Uint8List.fromList(bytes));
  }

  // Translates key names from SpecialKeysBar into raw byte sequences.
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

  Widget _buildBubble(ChatMessage msg) {
    if (msg.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.primaryBlue,
            borderRadius: BorderRadius.circular(12).copyWith(topRight: Radius.zero),
          ),
          child: Text(msg.text, style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 13)),
        ),
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.surfaceDark : AppTheme.surfaceLight,
          borderRadius: BorderRadius.circular(12).copyWith(topLeft: Radius.zero),
          border: Border.all(color: isDark ? AppTheme.borderDark : AppTheme.borderLight),
        ),
        child: SelectableText(
          msg.text,
          style: TextStyle(
            color: isDark ? AppTheme.textPrimaryDark : AppTheme.textPrimaryLight,
            fontFamily: 'monospace',
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.command),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (c, i) => _buildBubble(_messages[i]),
            ),
          ),
          if (_outputBuffer.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  _outputBuffer.length > 80 ? '...${_outputBuffer.substring(_outputBuffer.length - 80)}' : _outputBuffer,
                  style: const TextStyle(color: Colors.grey, fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          SpecialKeysBar(onKey: _sendKey),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    onSubmitted: (_) => _sendInput(_inputController.text),
                    enabled: _isRunning,
                    decoration: InputDecoration(
                      hintText: _isRunning ? 'Enter input...' : 'Session ended',
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: _isRunning ? AppTheme.primaryBlue : Colors.grey,
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white),
                    onPressed: _isRunning ? () => _sendInput(_inputController.text) : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dartssh2/dartssh2.dart';
import '../models/app_state.dart';
import '../models/chat_message.dart';
import '../utils/theme.dart';

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

  void _sendCtrlC() {
    _session?.write(Uint8List.fromList([3]));
  }

  void _sendCtrlD() {
    _session?.write(Uint8List.fromList([4]));
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
        actions: [
          IconButton(icon: const Text('Ctrl+C', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)), onPressed: _sendCtrlC),
          IconButton(icon: const Text('Ctrl+D', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)), onPressed: _sendCtrlD),
        ],
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

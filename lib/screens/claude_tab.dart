import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import '../models/chat_message.dart';
import '../utils/text_truncator.dart';
import '../utils/theme.dart';
import '../widgets/remote_path_picker.dart';
import '../widgets/connection_button.dart';
import '../widgets/theme_switch_button.dart';

class ClaudeTab extends StatefulWidget {
  const ClaudeTab({super.key});

  @override
  State<ClaudeTab> createState() => _ClaudeTabState();
}

class _ClaudeTabState extends State<ClaudeTab> with AutomaticKeepAliveClientMixin {
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _pathFocus = FocusNode();
  bool _pathFocused = false;

  final List<ChatMessage> _messages = [];
  final List<String> _promptHistory = [];
  int _historyIndex = -1;

  String? _sessionId;
  bool _started   = false;
  bool _isSending = false;
  String _lastKnownPath = '';

  String _pendingText = '';
  String _lineBuffer  = '';
  SSHSession? _currentSession;

  /// The CLI command used to invoke Claude (default: 'claude').
  /// Can be a full path, shell alias, or wrapper function defined in .bashrc.
  String _claudeCmd = 'claude';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _pathFocus.addListener(() => setState(() => _pathFocused = _pathFocus.hasFocus));
    _pathController.addListener(() => setState(() {}));
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('claude_cmd');
      if (saved != null && saved.trim().isNotEmpty && mounted) {
        setState(() => _claudeCmd = saved.trim());
      }
    });
  }

  Future<void> _saveClaudeCmd(String cmd) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('claude_cmd', cmd);
  }

  Future<void> _showCmdDialog() async {
    final ctrl = TextEditingController(text: _claudeCmd);
    final result = await showDialog<String>(
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
              const SizedBox(height: 12),
              const Text('Full command that will run:',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
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
                    return '$cmd -p "\$CLAUDE_PROMPT" --output-format stream-json --verbose --dangerously-skip-permissions';
                  }(),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result != null && result.isNotEmpty) {
      setState(() => _claudeCmd = result);
      _saveClaudeCmd(result);
    }
  }

  @override
  void dispose() {
    _currentSession?.close();
    _promptController.dispose();
    _pathController.dispose();
    _pathFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _syncCurrentPath(AppState state) {
    if (!state.isConnected) return;
    if (state.currentPath == _lastKnownPath) return;
    _lastKnownPath = state.currentPath;
    // Don't auto-update if a session is active — user may have set a specific path.
    if (!_started && !_isSending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pathController.text = state.currentPath;
      });
    }
  }

  void _historyUp() {
    if (_promptHistory.isEmpty) return;
    if (_historyIndex < _promptHistory.length - 1) {
      _historyIndex++;
      _promptController.text = _promptHistory[_promptHistory.length - 1 - _historyIndex];
    }
  }

  void _historyDown() {
    if (_historyIndex > 0) {
      _historyIndex--;
      _promptController.text = _promptHistory[_promptHistory.length - 1 - _historyIndex];
    } else {
      _historyIndex = -1;
      _promptController.clear();
    }
  }

  void _copyText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ─── Start dialog ──────────────────────────────────────────────────────────

  Future<void> _showStartDialog() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not connected')));
      return;
    }

    String path = _pathController.text.trim();
    if (path.isEmpty) path = state.sshService.homeDir;
    path = state.sshService.resolvePath(path);
    _pathController.text = path;
    state.setCurrentPath(path);

    if (!mounted) return;
    final mode = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Claude Session'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.add_circle, color: Colors.green),
            title: const Text('New Session'),
            onTap: () => Navigator.pop(ctx, 'new'),
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Resume Last Session'),
            subtitle: Text(_sessionId != null
                ? 'ID: ${_sessionId!.substring(0, 8)}…'
                : 'No previous session'),
            onTap: () => Navigator.pop(ctx, 'resume'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ],
      ),
    );

    if (mode == null || !mounted) return;

    setState(() {
      _messages.clear();
      _pendingText = '';
      _lineBuffer  = '';
      _started     = true;
      if (mode == 'new') _sessionId = null;
      _messages.add(ChatMessage(
        text: 'Claude ready in $path  •  ${mode == "resume" && _sessionId != null ? "resuming ${_sessionId!.substring(0, 8)}…" : "new session"}',
        isUser: false,
      ));
    });
  }

  // ─── Send prompt ───────────────────────────────────────────────────────────

  Future<void> _sendPrompt(String promptText) async {
    final trimmed = promptText.trim();
    if (trimmed.isEmpty || _isSending || !_started) return;

    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) return;

    _promptHistory.add(trimmed);
    _historyIndex = -1;

    setState(() {
      _messages.add(ChatMessage(text: trimmed, isUser: true));
      _isSending   = true;
      _pendingText = '';
      _lineBuffer  = '';
    });
    _promptController.clear();
    _scrollToBottom();

    final path        = _pathController.text.trim();
    final escapedPath = path.replaceAll('"', '\\"');
    final resumeFlag  = _sessionId != null ? ' --resume $_sessionId' : '';
    final b64         = base64Encode(utf8.encode(trimmed));

    // Decode prompt from base64 into a variable, then pass via -p.
    // Using a variable avoids shell-quoting issues with special characters.
    // --output-format stream-json --verbose  →  includes tool_result events
    // --dangerously-skip-permissions  →  no interactive prompts in print mode
    final cmd = _claudeCmd.isEmpty ? 'claude' : _claudeCmd;
    final command =
        'cd "$escapedPath" && '
        "CLAUDE_PROMPT=\$(printf '%s' '$b64' | base64 -d) && "
        'NO_COLOR=1 $cmd -p "\$CLAUDE_PROMPT" '
        '--output-format stream-json --verbose '
        '--dangerously-skip-permissions$resumeFlag';

    bool errorHandled = false;
    try {
      _currentSession = await state.sshService.startRawSession(command);

      final done = Completer<void>();
      _currentSession!.stdout.listen(
        (d) { if (mounted) _handleChunk(utf8.decode(d, allowMalformed: true)); },
        onDone: ()  { if (!done.isCompleted) done.complete(); },
        onError: (e){ if (!done.isCompleted) done.completeError(e); },
      );
      _currentSession!.stderr.listen((d) {
        final text = utf8.decode(d, allowMalformed: true);
        if (mounted &&
            !text.contains('cannot set terminal process group') &&
            !text.contains('no job control in this shell')) {
          _handleChunk(text);
        }
      });
      await done.future;
    } catch (e) {
      errorHandled = true;
      if (mounted) {
        setState(() {
          // Save partial output BEFORE the error so message order is correct.
          if (_pendingText.trim().isNotEmpty) {
            _messages.add(ChatMessage(text: _pendingText.trim(), isUser: false));
            _pendingText = '';
          }
          _messages.add(ChatMessage(text: _disconnectMessage(e), isUser: false));
        });
      }
    } finally {
      _currentSession = null;
      if (_lineBuffer.trim().isNotEmpty) _parseLine(_lineBuffer.trim());
      if (mounted) {
        final connState = Provider.of<AppState>(context, listen: false);
        setState(() {
          if (_pendingText.trim().isNotEmpty) {
            _messages.add(ChatMessage(text: _pendingText.trim(), isUser: false));
          }
          // If the stream closed cleanly (onDone, no exception) but the SSH
          // connection is gone, the remote process was killed by the disconnect.
          if (!errorHandled && !connState.isConnected) {
            _messages.add(ChatMessage(
              text: '⚡ Connection lost — response may be incomplete.\n'
                    'Session ID preserved. Tap Resume once reconnected.',
              isUser: false,
            ));
          }
          _isSending   = false;
          _pendingText = '';
          _lineBuffer  = '';
        });
        _scrollToBottom();
      }
    }
  }

  /// Human-readable message for SSH/socket errors during a Claude session.
  static String _disconnectMessage(dynamic e) {
    final s = e.toString().toLowerCase();
    if (s.contains('socket') || s.contains('closed') ||
        s.contains('connection') || s.contains('pipe') || s.contains('eof')) {
      return '⚡ Connection lost — response may be incomplete.\n'
             'Session ID preserved. Tap Resume once reconnected.';
    }
    return 'Error: $e';
  }

  void _stopSession() {
    _currentSession?.close();
    _currentSession = null;
    if (!mounted) return;
    setState(() {
      if (_pendingText.trim().isNotEmpty) {
        _messages.add(ChatMessage(text: _pendingText.trim(), isUser: false));
      }
      _isSending   = false;
      _pendingText = '';
      _messages.add(ChatMessage(text: '(stopped)', isUser: false));
    });
  }

  // ─── Stream-JSON parsing ───────────────────────────────────────────────────

  void _handleChunk(String chunk) {
    _lineBuffer += chunk;
    while (_lineBuffer.contains('\n')) {
      final idx  = _lineBuffer.indexOf('\n');
      final line = _lineBuffer.substring(0, idx).trim();
      _lineBuffer = _lineBuffer.substring(idx + 1);
      if (line.isNotEmpty) _parseLine(line);
    }
  }

  /// Returns true for lines that are bash interactive-shell noise injected by
  /// `bash -i`: PS1 prompts, echoed stdin commands, and the logout message.
  static bool _isShellNoise(String line) {
    if (line == 'logout') return true;
    // PS1 prompt or prompt+logout on the same line (e.g. "user@host:~$ logout")
    if (line.contains(r'$ ') || line.contains(r'# ') ||
        line.endsWith(r'$') || line.endsWith(r'#')) { return true; }
    // Echoed fragments of the pathFix / command we wrote to stdin
    if (line.contains('export PATH') || line.contains('unset _P') ||
        line.contains('expand_aliases') || line.contains('shopt') ||
        line.contains('base64 -d') || line.contains('CLAUDE_PROMPT') ||
        line.contains('stream-json') || line.contains('dangerously-skip-permissions') ||
        line.contains('output-format') || line.contains('NO_COLOR=')) { return true; }
    return false;
  }

  void _parseLine(String line) {
    if (!line.startsWith('{')) {
      // Raw output (bash errors, PATH issues) — show directly, but suppress
      // interactive-shell noise (PS1 prompts, echoed stdin, logout).
      if (!_isShellNoise(line)) {
        if (mounted) setState(() => _pendingText += '$line\n');
      }
      return;
    }
    try {
      final j    = jsonDecode(line) as Map<String, dynamic>;
      final type = j['type'] as String?;

      if (type == 'system' && j['subtype'] == 'init') {
        final id = j['session_id'] as String?;
        if (id != null && id.isNotEmpty) _sessionId = id;

      } else if (type == 'assistant') {
        for (final block in (j['message']?['content'] as List? ?? [])) {
          final bt = block['type'] as String?;
          if (bt == 'text') {
            final t = block['text'] as String? ?? '';
            if (t.isNotEmpty && mounted) setState(() => _pendingText += t);
          } else if (bt == 'tool_use') {
            final name = block['name'] as String? ?? 'tool';
            final input = block['input'];
            // Show the command being run, e.g. "[Bash] ls -la"
            String hint = '';
            if (input is Map) hint = (input['command'] ?? input['path'] ?? '').toString();
            if (mounted) setState(() => _pendingText += '\n▶ $name${hint.isNotEmpty ? ": $hint" : ""}\n');
          }
        }

      } else if (type == 'user') {
        // tool_result events — contain the ACTUAL output of Bash/Read/etc.
        for (final block in (j['message']?['content'] as List? ?? [])) {
          if (block['type'] == 'tool_result') {
            final raw = block['content'];
            String out = '';
            if (raw is String) {
              out = raw;
            } else if (raw is List) {
              for (final c in raw) {
                if (c['type'] == 'text') out += (c['text'] as String? ?? '');
              }
            }
            if (out.trim().isNotEmpty && mounted) {
              setState(() => _pendingText += '${out.trimRight()}\n');
            }
          }
        }
        _scrollToBottom();
      }
      // 'result' event — stream completion handled by onDone
    } catch (_) {}
  }

  // ─── UI ────────────────────────────────────────────────────────────────────

  Widget _buildBubble(ChatMessage msg, {bool pending = false}) {
    if (msg.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
          padding: const EdgeInsets.all(12),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
          decoration: BoxDecoration(
            color: AppTheme.primaryBlue,
            borderRadius: BorderRadius.circular(12).copyWith(topRight: Radius.zero),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SelectableText(msg.text,
                    style: const TextStyle(color: Colors.white, fontFamily: 'Space Grotesk')),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: () => _copyText(msg.text),
                child: const Icon(Icons.copy, size: 14, color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.92),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.surfaceDark : AppTheme.surfaceLight,
          borderRadius: BorderRadius.circular(12).copyWith(topLeft: Radius.zero),
          border: Border.all(color: isDark ? AppTheme.borderDark : AppTheme.borderLight),
        ),
        child: Stack(
          children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText(msg.text,
                  style: TextStyle(
                    color: isDark ? AppTheme.textPrimaryDark : AppTheme.textPrimaryLight,
                    fontFamily: 'monospace',
                    fontSize: 13,
                  )),
              if (pending) ...[
                const SizedBox(height: 6),
                SizedBox(
                  width: 12, height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryBlue),
                ),
              ],
            ]),
            Positioned(
              top: 0,
              right: 0,
              child: InkWell(
                onTap: () => _copyText(msg.text),
                child: Icon(Icons.copy, size: 14,
                    color: isDark ? Colors.white38 : Colors.black26),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = Provider.of<AppState>(context);
    _syncCurrentPath(state);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Claude Chat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 20),
            onPressed: _historyUp,
            tooltip: 'Previous prompt',
          ),
          IconButton(
            icon: const Icon(Icons.arrow_downward, size: 20),
            onPressed: _historyDown,
            tooltip: 'Next prompt',
          ),
          IconButton(
            icon: const Icon(Icons.terminal, size: 20),
            onPressed: _showCmdDialog,
            tooltip: 'Claude command ($_claudeCmd)',
          ),
          const ThemeSwitchButton(),
          const ConnectionButton(),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
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
                            textAlign: TextAlign.left,
                            textAlignVertical: TextAlignVertical.top,
                            maxLines: 1,
                            style: _pathFocused ? style : style.copyWith(color: Colors.transparent),
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
                                  child: Text(
                                    truncated,
                                    maxLines: 1,
                                    overflow: TextOverflow.clip,
                                    style: style,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
              ),
              const SizedBox(width: 8),
              if (!_started)
                ElevatedButton(onPressed: _showStartDialog, child: const Text('Start'))
              else if (_isSending)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.withValues(alpha: 0.1),
                    foregroundColor: Colors.red, elevation: 0,
                  ),
                  onPressed: _stopSession,
                  icon: const Icon(Icons.stop, size: 18),
                  label: const Text('Stop'),
                )
              else
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange.withValues(alpha: 0.1),
                    foregroundColor: Colors.orange, elevation: 0,
                  ),
                  onPressed: _showStartDialog,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('New'),
                ),
            ]),
          ),
        ),
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: Column(children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 16),
            itemCount: _messages.length + (_isSending ? 1 : 0),
            itemBuilder: (_, i) {
              if (i == _messages.length && _isSending) {
                return _buildBubble(
                  ChatMessage(text: _pendingText.isEmpty ? '…' : _pendingText, isUser: false),
                  pending: true,
                );
              }
              return _buildBubble(_messages[i]);
            },
          ),
        ),
        if (_isSending)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [
              SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryBlue)),
              const SizedBox(width: 8),
              const Text('Claude is thinking…', style: TextStyle(color: Colors.grey, fontSize: 12)),
              const Spacer(),
              if (_sessionId != null)
                Text('Session: ${_sessionId!.substring(0, 8)}…',
                    style: const TextStyle(color: Colors.grey, fontSize: 11)),
            ]),
          ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
          ),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _promptController,
                onSubmitted: (_) => _sendPrompt(_promptController.text),
                enabled: _started && !_isSending,
                maxLines: null,
                decoration: InputDecoration(
                  hintText: !_started ? 'Press Start…' : _isSending ? 'Waiting…' : 'Prompt Claude…',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            CircleAvatar(
              backgroundColor: (_started && !_isSending) ? AppTheme.primaryBlue : Colors.grey,
              child: IconButton(
                icon: const Icon(Icons.send, color: Colors.white),
                onPressed: (_started && !_isSending)
                    ? () => _sendPrompt(_promptController.text)
                    : null,
              ),
            ),
          ]),
        ),
      ]),
      ),
    );
  }
}

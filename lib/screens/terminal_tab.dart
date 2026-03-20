import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../models/chat_message.dart';
import '../utils/text_truncator.dart';
import '../utils/theme.dart';
import '../widgets/connection_button.dart';
import '../widgets/theme_switch_button.dart';
import 'interactive_shell_page.dart';

class TerminalTab extends StatefulWidget {
  const TerminalTab({super.key});

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> with AutomaticKeepAliveClientMixin {
  final TextEditingController _cmdController = TextEditingController();
  final List<ChatMessage> _messages = [];
  final ScrollController _scrollController = ScrollController();
  final List<String> _cmdHistory = [];
  int _historyIndex = -1;
  bool _isExecuting = false;

  @override
  bool get wantKeepAlive => true; // Keep state when switching tabs

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

  static const _interactiveCommands = {'python', 'python3', 'ipython', 'node', 'bash', 'zsh', 'sh', 'irb', 'sqlite3', 'mysql', 'psql', 'top', 'htop', 'vim', 'nano', 'less', 'more', 'claude'};

  bool _isInteractiveCommand(String cmd) {
    final firstWord = cmd.split(' ').first.split('/').last;
    return _interactiveCommands.contains(firstWord);
  }

  void _historyUp() {
    if (_cmdHistory.isEmpty) return;
    if (_historyIndex < _cmdHistory.length - 1) {
      _historyIndex++;
      _cmdController.text = _cmdHistory[_cmdHistory.length - 1 - _historyIndex];
    }
  }

  void _historyDown() {
    if (_historyIndex > 0) {
      _historyIndex--;
      _cmdController.text = _cmdHistory[_cmdHistory.length - 1 - _historyIndex];
    } else {
      _historyIndex = -1;
      _cmdController.clear();
    }
  }

  Future<void> _executeCommand() async {
    final cmd = _cmdController.text.trim();
    if (cmd.isEmpty) return;

    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not connected to SSH.')));
       return;
    }

    // Save to history
    _cmdHistory.add(cmd);
    _historyIndex = -1;

    // If interactive command, open in a new page
    if (_isInteractiveCommand(cmd)) {
      _cmdController.clear();
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChangeNotifierProvider.value(
            value: state,
            child: InteractiveShellPage(command: cmd, workingDir: state.currentPath),
          ),
        ),
      );
      return;
    }

    setState(() {
      _messages.add(ChatMessage(text: cmd, isUser: true));
      _isExecuting = true;
    });
    _cmdController.clear();
    _scrollToBottom();

    try {
      final dir = state.currentPath;
      bool isCd = cmd.startsWith('cd ') || cmd == 'cd';

      final String actualCmd;
      if (isCd) {
        actualCmd = 'cd "$dir" && $cmd && pwd';
      } else {
        actualCmd = 'cd "$dir" && $cmd';
      }

      final output = await state.sshService.executeCommand(actualCmd);
      final cleanOutput = output.trim();

      if (isCd) {
        if (!cleanOutput.contains('No such file') && !cleanOutput.contains('Not a directory')) {
          final newDir = cleanOutput.split('\n').last.trim();
          if (newDir.isNotEmpty) state.setCurrentPath(newDir);
        }
        setState(() {
          _messages.add(ChatMessage(text: cleanOutput.isEmpty ? '(changed dir)' : cleanOutput, isUser: false));
        });
      } else {
        setState(() {
          _messages.add(ChatMessage(text: cleanOutput, isUser: false));
        });
      }
    } catch (e) {
      setState(() {
        _messages.add(ChatMessage(text: "Error: $e", isUser: false));
      });
    } finally {
      setState(() {
        _isExecuting = false;
      });
      _scrollToBottom();
    }
  }

  void _copyText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    if (message.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: GestureDetector(
          onLongPress: () => _copyText(message.text),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.primaryBlue,
              borderRadius: BorderRadius.circular(12).copyWith(topRight: Radius.zero),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: SelectableText(
                    message.text,
                    style: const TextStyle(color: Colors.white, fontFamily: 'Space Grotesk'),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => _copyText(message.text),
                  child: const Icon(Icons.copy, size: 14, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      );
    } else {
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
          child: Stack(
            children: [
              SelectableText(
                message.text.isEmpty ? "(No output)" : message.text,
                style: TextStyle(
                  color: isDark ? AppTheme.textPrimaryDark : AppTheme.textPrimaryLight,
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: InkWell(
                  onTap: () => _copyText(message.text),
                  child: Icon(Icons.copy, size: 14, color: isDark ? Colors.white38 : Colors.black26),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    final state = Provider.of<AppState>(context);
    final displayDir = state.isConnected ? state.currentPath : '~';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal Shell'),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 20),
            onPressed: _historyUp,
            tooltip: 'Previous command',
          ),
          IconButton(
            icon: const Icon(Icons.arrow_downward, size: 20),
            onPressed: _historyDown,
            tooltip: 'Next command',
          ),
          const ThemeSwitchButton(),
          IconButton(
            icon: const Icon(Icons.open_in_full, size: 20),
            tooltip: 'Full terminal (PTY)',
            onPressed: () {
              if (!state.isConnected) return;
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ChangeNotifierProvider.value(
                  value: state,
                  child: InteractiveShellPage(
                    command: 'bash',
                    workingDir: state.currentPath,
                  ),
                ),
              ));
            },
          ),
          const ConnectionButton(),
        ],
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                return _buildMessageBubble(_messages[index]);
              },
            ),
          ),
          if (_isExecuting)
             const Padding(
               padding: EdgeInsets.all(8.0),
               child: CircularProgressIndicator(),
             ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final style = Theme.of(context).textTheme.bodyMedium!.copyWith(fontSize: 14);
                      final hint = truncateLeft(
                        '$displayDir \$',
                        constraints.maxWidth - 32,
                        style,
                      );
                      return TextField(
                        controller: _cmdController,
                        textAlign: TextAlign.left,
                        textAlignVertical: TextAlignVertical.top,
                        onSubmitted: (_) => _executeCommand(),
                        style: style,
                        decoration: InputDecoration(
                          hint: Text(
                            hint,
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            style: style.copyWith(color: Theme.of(context).hintColor),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                if (_isExecuting)
                  CircleAvatar(
                    backgroundColor: Colors.red,
                    child: IconButton(
                      icon: const Icon(Icons.stop, color: Colors.white),
                      onPressed: () {
                        final state = Provider.of<AppState>(context, listen: false);
                        state.sshService.cancelCommand();
                      },
                    ),
                  ),
                if (!_isExecuting)
                  CircleAvatar(
                    backgroundColor: AppTheme.primaryBlue,
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.white),
                      onPressed: _executeCommand,
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

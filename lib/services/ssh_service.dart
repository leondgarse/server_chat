import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

class SSHService {
  SSHClient? _client;
  String? _homeDir;
  Timer? _keepAliveTimer;

  bool get isConnected => _client != null && !_client!.isClosed;
  String get homeDir => _homeDir ?? '/';

  Future<void> connect({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKey,
  }) async {
    try {
      final socket = await SSHSocket.connect(host, port);
      
      _client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: password != null ? () => password : null,
        identities: privateKey != null 
          ? [
              ...SSHKeyPair.fromPem(privateKey)
            ]
          : null,
      );
      
      // Wait for authentication to complete
      await _client?.authenticated;

      // Start keepalive timer - sends a no-op packet every 15 seconds
      // This prevents the SSH connection from dropping when the screen is off
      _keepAliveTimer?.cancel();
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
        try {
          if (isConnected) {
            await _client!.run('true');
          } else {
            _keepAliveTimer?.cancel();
          }
        } catch (_) {
          _keepAliveTimer?.cancel();
        }
      });

      // Resolve and cache the home directory
      if (isConnected) {
        final result = await _client!.run('echo \$HOME');
        _homeDir = utf8.decode(result).trim();
        if (_homeDir == null || _homeDir!.isEmpty) {
          _homeDir = '/home/$username';
        }
      }
    } catch (e) {
      debugPrint('SSH Connection Error: $e');
      _client?.close();
      _client = null;
      rethrow;
    }
  }

  void disconnect() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _client?.close();
    _client = null;
    _homeDir = null;
  }

  /// Resolve ~ to actual home directory
  String resolvePath(String path) {
    if (path == '~' || path == '~/') return homeDir;
    if (path.startsWith('~/')) return '$homeDir/${path.substring(2)}';
    return path;
  }

  /// Execute a command using a login shell so user PATH and profile are loaded.
  Future<String> executeCommand(String command) async {
    if (!isConnected) {
      throw Exception('Not connected to SSH server');
    }
    try {
      // Use bash -l (login shell) so .bashrc/.profile are sourced
      // This ensures conda, python, etc. are on PATH
      final result = await _client!.run('bash -l -c ${_shellEscape(command)}');
      return utf8.decode(result);
    } catch (e) {
      debugPrint('Execute Command Error: $e');
      rethrow;
    }
  }

  /// Shell-escape a command string for use with bash -c
  String _shellEscape(String cmd) {
    final escaped = cmd.replaceAll("'", "'\\''");
    return "'$escaped'";
  }

  Future<SSHSession?> startSession() async {
     if (!isConnected) {
      throw Exception('Not connected to SSH server');
    }
    return await _client!.execute('bash');
  }

  /// Start a non-PTY login bash session for claude --output-format stream-json.
  /// No terminal echo, clean stdout, stdin piped in directly.
  Future<SSHSession> startCommandSession() async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    return await _client!.execute('bash -l');
  }

  /// Execute [command] via a login bash and stream stdout+stderr to [onData].
  /// Returns when the command exits.
  Future<void> executeCommandStreaming(
    String command,
    void Function(String chunk) onData,
  ) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    final session = await _client!.execute('bash -l -c ${_shellEscape(command)}');

    final done = Completer<void>();
    session.stdout.listen(
      (d) => onData(utf8.decode(d, allowMalformed: true)),
      onDone: () { if (!done.isCompleted) done.complete(); },
      onError: (e) { if (!done.isCompleted) done.completeError(e); },
    );
    session.stderr.listen(
      (d) => onData(utf8.decode(d, allowMalformed: true)),
    );
    await done.future;
  }

  /// Start a login bash session, pipe [command] to its stdin, then return the
  /// session so the caller can listen to stdout/stderr and optionally cancel
  /// by calling session.close().  Avoids all shell-quoting issues because the
  /// command bytes are written directly over SSH without a wrapping shell.
  Future<SSHSession> startRawSession(String command) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    final session = await _client!.execute('bash -l -s');
    session.stdin.add(utf8.encode('$command\n'));
    await session.stdin.close(); // EOF → bash exits after command finishes
    return session;
  }

  /// Interactive shell. Use termType='dumb' to suppress TUI/colour output
  /// (e.g. for claude sessions where we parse plain text).
  Future<SSHSession> startInteractiveShell({
    String termType = 'xterm-256color',
    int width = 80,
    int height = 25,
  }) async {
    if (!isConnected) {
      throw Exception('Not connected to SSH server');
    }
    return await _client!.shell(
      pty: SSHPtyConfig(type: termType, width: width, height: height),
    );
  }

  Future<String> readFile(String path) async {
    final resolved = resolvePath(path);
    return await executeCommand('cat "$resolved"');
  }

  Future<void> writeFile(String path, String content) async {
    final resolved = resolvePath(path);
    final b64 = base64Encode(utf8.encode(content));
    await executeCommand('echo "$b64" | base64 --decode > "$resolved"');
  }
}

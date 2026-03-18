import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

class SSHService {
  SSHClient? _client;
  String? _homeDir;
  Timer? _keepAliveTimer;

  /// Called when the connection drops unexpectedly (not from a deliberate disconnect()).
  void Function()? onDisconnected;

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
        identities: privateKey != null ? [...SSHKeyPair.fromPem(privateKey)] : null,
        // Protocol-level keepalive: sends SSH_MSG_GLOBAL_REQUEST every 20s.
        // After 3 unanswered probes (60s) dartssh2 closes the socket.
        keepAliveInterval: const Duration(seconds: 20),
        keepAliveMaxCount: 3,
      );

      await _client!.authenticated;

      // Detect unexpected drops (network loss, server restart, keepalive timeout).
      _client!.done.then((_) => _handleUnexpectedDisconnect())
                   .catchError((_) => _handleUnexpectedDisconnect());

      // Secondary timer: ensures we notice a dead socket even if the protocol
      // keepalive reply is swallowed by a NAT/firewall without closing the TCP stream.
      _keepAliveTimer?.cancel();
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
        if (!isConnected) {
          _handleUnexpectedDisconnect();
          return;
        }
        try {
          await _client!.run('true');
        } catch (_) {
          _handleUnexpectedDisconnect();
        }
      });

      // Cache home directory.
      final result = await _client!.run('echo \$HOME');
      _homeDir = utf8.decode(result).trim();
      if (_homeDir == null || _homeDir!.isEmpty) {
        _homeDir = '/home/$username';
      }
    } catch (e) {
      debugPrint('SSH Connection Error: $e');
      _client?.close();
      _client = null;
      rethrow;
    }
  }

  /// Called whenever the connection closes without an explicit disconnect() call.
  void _handleUnexpectedDisconnect() {
    if (_client == null) return; // already handled
    debugPrint('SSHService: unexpected disconnect');
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _client = null;
    onDisconnected?.call();
  }

  void disconnect() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    final c = _client;
    _client = null; // clear first so _handleUnexpectedDisconnect is a no-op
    _homeDir = null;
    c?.close();
  }

  /// Resolve ~ to actual home directory
  String resolvePath(String path) {
    if (path == '~' || path == '~/') return homeDir;
    if (path.startsWith('~/')) return '$homeDir/${path.substring(2)}';
    return path;
  }

  /// Execute a command using an interactive login shell so both
  /// .bash_profile and .bashrc (virtualenvs, conda, etc.) are sourced.
  Future<String> executeCommand(String command) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    try {
      final result = await _client!.run('bash -l -i -c ${_shellEscape(command)}');
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
    if (!isConnected) throw Exception('Not connected to SSH server');
    return await _client!.execute('bash');
  }

  /// Start a non-PTY login bash session for claude --output-format stream-json.
  Future<SSHSession> startCommandSession() async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    return await _client!.execute('bash -l -i');
  }

  /// Execute [command] and stream stdout+stderr to [onData].
  Future<void> executeCommandStreaming(
    String command,
    void Function(String chunk) onData,
  ) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    final session = await _client!.execute('bash -l -i -c ${_shellEscape(command)}');

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

  /// Start a login bash session, pipe [command] to stdin, then return the
  /// session so the caller can listen to stdout/stderr.
  Future<SSHSession> startRawSession(String command) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    final session = await _client!.execute('bash -l -i -s');
    session.stdin.add(utf8.encode('$command\n'));
    await session.stdin.close();
    return session;
  }

  /// Interactive PTY shell.
  Future<SSHSession> startInteractiveShell({
    String termType = 'xterm-256color',
    int width = 80,
    int height = 25,
  }) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    return await _client!.shell(
      pty: SSHPtyConfig(type: termType, width: width, height: height),
    );
  }

  Future<String> readFile(String path) async {
    final resolved = resolvePath(path);
    return await executeCommand('cat "$resolved"');
  }

  Future<void> writeFile(String path, String content) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    final resolved = resolvePath(path);
    // Stream content directly via SSH stdin — no shell escaping, no size limit.
    final session = await _client!.execute('cat > "$resolved"');
    session.stdin.add(utf8.encode(content));
    await session.stdin.close();
    await session.done;
  }
}

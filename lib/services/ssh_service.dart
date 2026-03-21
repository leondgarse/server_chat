import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

class SSHService {
  SSHClient? _client;
  String? _homeDir;
  Timer? _keepAliveTimer;
  SSHSession? _activeCommand;
  final List<ServerSocket> _localForwardServers = [];

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
    String? tunnels,
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
      );

      await _client!.authenticated;

      // Detect unexpected drops (network loss, server restart, keepalive timeout).
      _client!.done.then((_) => _handleUnexpectedDisconnect())
                   .catchError((_) => _handleUnexpectedDisconnect());

      // Secondary timer: detects dead connections by checking isConnected.
      // We do NOT open a new SSH channel here — the protocol-level keepAliveInterval
      // (20s) is sufficient to detect broken connections without consuming session slots.
      _keepAliveTimer?.cancel();
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (!isConnected) {
          _handleUnexpectedDisconnect();
        }
      });

      // Set up local port forwards, if any.
      if (tunnels != null && tunnels.trim().isNotEmpty) {
        await _setupLocalForwards(tunnels);
      }

      // Cache home directory using executeCommandFast (avoids run() channel leak).
      _homeDir = (await executeCommandFast('echo \$HOME')).trim();
      if (_homeDir!.isEmpty) _homeDir = '/home/$username';
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
    _closeLocalForwards();
    onDisconnected?.call();
  }

  /// Parses "localPort:remoteHost:remotePort" lines and starts a local
  /// ServerSocket for each, tunneling accepted connections over SSH.
  Future<void> _setupLocalForwards(String tunnels) async {
    for (final line in tunnels.split('\n')) {
      final spec = line.trim();
      if (spec.isEmpty || spec.startsWith('#')) continue;
      final parts = spec.split(':');
      if (parts.length < 3) continue;
      final localPort  = int.tryParse(parts[0]);
      final remotePort = int.tryParse(parts.last);
      final remoteHost = parts.sublist(1, parts.length - 1).join(':');
      if (localPort == null || remotePort == null || remoteHost.isEmpty) continue;
      try {
        final server = await ServerSocket.bind('127.0.0.1', localPort);
        _localForwardServers.add(server);
        debugPrint('SSH tunnel: 127.0.0.1:$localPort → $remoteHost:$remotePort');
        server.listen((socket) async {
          try {
            final channel = await _client!.forwardLocal(remoteHost, remotePort);
            socket.listen(
              (data) => channel.sink.add(data),
              onDone: () => channel.sink.close(),
              onError: (_) => channel.sink.close(),
              cancelOnError: true,
            );
            channel.stream.listen(
              (data) => socket.add(data),
              onDone: () => socket.destroy(),
              onError: (_) => socket.destroy(),
              cancelOnError: true,
            );
          } catch (_) {
            socket.destroy();
          }
        });
      } catch (e) {
        debugPrint('Failed to bind tunnel 127.0.0.1:$localPort: $e');
      }
    }
  }

  void _closeLocalForwards() {
    for (final s in _localForwardServers) {
      s.close();
    }
    _localForwardServers.clear();
  }

  /// Cancel the currently running executeCommand session, if any.
  void cancelCommand() {
    _activeCommand?.close();
    _activeCommand = null;
  }

  void disconnect() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    final c = _client;
    _client = null; // clear first so _handleUnexpectedDisconnect is a no-op
    _homeDir = null;
    _closeLocalForwards();
    c?.close();
  }

  /// Resolve ~ to actual home directory
  String resolvePath(String path) {
    if (path == '~' || path == '~/') return homeDir;
    if (path.startsWith('~/')) return '$homeDir/${path.substring(2)}';
    return path;
  }

  /// bash startup warnings produced by -i without a real TTY.
  static bool _isBashStartupWarning(String text) =>
      text.contains('cannot set terminal process group') ||
      text.contains('no job control in this shell');

  /// Execute a command using an interactive login shell so both
  /// .bash_profile and .bashrc (virtualenvs, conda, etc.) are sourced.
  /// Uses -i so .bashrc's interactive guard (case $- in *i*) passes.
  /// stdout/stderr are captured separately; bash startup warnings are filtered.
  Future<String> executeCommand(String command) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    try {
      final session = await _client!.execute('bash -l -i -c ${_shellEscape(command)}');
      _activeCommand = session;
      final out = StringBuffer();
      final err = StringBuffer();
      final done = Completer<void>();
      session.stdout.listen(
        (d) => out.write(utf8.decode(d, allowMalformed: true)),
        onDone: () { if (!done.isCompleted) done.complete(); },
        onError: (e) { if (!done.isCompleted) done.completeError(e); },
      );
      session.stderr.listen((d) {
        final text = utf8.decode(d, allowMalformed: true);
        if (!_isBashStartupWarning(text)) err.write(text);
      });
      await done.future;
      final errStr = err.toString().trim();
      return errStr.isEmpty ? out.toString() : '$out$errStr\n';
    } catch (e) {
      debugPrint('Execute Command Error: $e');
      rethrow;
    } finally {
      _activeCommand = null;
    }
  }

  /// Like [executeCommand] but uses plain `bash -c` (no login/interactive flags).
  /// Much faster — suitable for simple commands like tmux control that don't
  /// need the user's PATH or shell startup files.
  Future<String> executeCommandFast(String command) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    final session = await _client!.execute('bash -c ${_shellEscape(command)}');
    final out = StringBuffer();
    final done = Completer<void>();
    session.stdout.listen(
      (d) => out.write(utf8.decode(d, allowMalformed: true)),
      onDone: () { if (!done.isCompleted) done.complete(); },
      onError: (e) { if (!done.isCompleted) done.completeError(e); },
    );
    session.stderr.listen((_) {});
    await done.future;
    return out.toString();
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
    return await _client!.execute('bash -l');
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
    session.stderr.listen((d) {
      final text = utf8.decode(d, allowMalformed: true);
      if (!_isBashStartupWarning(text)) onData(text);
    });
    await done.future;
  }

  /// Start a login bash session, pipe [command] to stdin, then return the
  /// session so the caller can listen to stdout/stderr.
  Future<SSHSession> startRawSession(String command) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    // Use bash -l (login, no -i) so .bash_profile is sourced for PATH without
    // the interactive mode that prints PS1 prompts and echoes commands to stdout.
    // Use bash -i (interactive) so .bashrc is sourced automatically including
    // alias/function definitions. Without -i, bash skips .bashrc because of the
    // "case $- in *i*)" guard present in most distributions.
    // The "no job control" / "cannot set terminal" messages that -i emits on a
    // non-TTY are already filtered in the caller's stderr listener.
    final session = await _client!.execute('bash -i -l -s');
    // Export the resolved PATH so subprocesses (e.g. claude → python3) find
    // conda/virtualenv binaries even though this session has no TTY.
    const pathFix =
        r'shopt -s expand_aliases; '
        r'_P="$(bash -l -i -c "echo \$PATH" 2>/dev/null)"; [ -n "$_P" ] && export PATH="$_P"; unset _P';
    session.stdin.add(utf8.encode('$pathFix\n$command\n'));
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

  /// Upload a local file to a remote path via SFTP with optional progress.
  Future<void> uploadFile(
    String localPath,
    String remotePath, {
    void Function(int sent, int total)? onProgress,
  }) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    final sftp = await _client!.sftp();
    final localFile = File(localPath);
    final total = await localFile.length();
    final remote = await sftp.open(
      remotePath,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
    int sent = 0;
    await remote.write(
      localFile.openRead().map((chunk) {
        final bytes = Uint8List.fromList(chunk);
        sent += bytes.length;
        onProgress?.call(sent, total);
        return bytes;
      }),
    );
    await remote.close();
  }

  /// Download a remote file to a local path via SFTP with optional progress.
  Future<void> downloadFile(
    String remotePath,
    String localPath, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    final sftp = await _client!.sftp();
    final remote = await sftp.open(remotePath, mode: SftpFileOpenMode.read);
    final stat = await remote.stat();
    final total = stat.size ?? 0;
    final localFile = File(localPath);
    await localFile.parent.create(recursive: true);
    final sink = localFile.openWrite();
    int received = 0;
    await for (final chunk in remote.read()) {
      received += chunk.length;
      onProgress?.call(received, total);
      sink.add(chunk);
    }
    await sink.flush();
    await sink.close();
    await remote.close();
  }

  /// Check whether a remote path is a directory (via SFTP stat).
  Future<bool> isRemoteDirectory(String remotePath) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    final sftp = await _client!.sftp();
    try {
      final stat = await sftp.stat(remotePath);
      return stat.isDirectory;
    } catch (_) {
      return false;
    }
  }

  /// Check whether a remote path exists as a file (via SFTP stat).
  Future<bool> isRemoteFile(String remotePath) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    final sftp = await _client!.sftp();
    try {
      final stat = await sftp.stat(remotePath);
      return !stat.isDirectory;
    } catch (_) {
      return false;
    }
  }

  /// List a remote directory via SFTP.
  Future<List<SftpName>> sftpListDir(String remotePath) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    final sftp = await _client!.sftp();
    final items = <SftpName>[];
    await for (final batch in sftp.readdir(remotePath)) {
      items.addAll(batch);
    }
    return items;
  }

  /// Upload a local directory recursively to [remoteBasePath] via SFTP.
  Future<void> uploadDirectory(
    String localDirPath,
    String remoteBasePath, {
    void Function(String file, double progress)? onProgress,
  }) async {
    if (!isConnected) throw Exception('Not connected to SSH server');
    final sftp = await _client!.sftp();

    Future<void> doUpload(String localPath, String remotePath) async {
      try { await sftp.mkdir(remotePath); } catch (_) {}
      final dir = Directory(localPath);
      for (final entity in dir.listSync()) {
        final name = entity.path.split('/').last;
        final childRemote = '$remotePath/$name';
        if (entity is Directory) {
          await doUpload(entity.path, childRemote);
        } else if (entity is File) {
          onProgress?.call(entity.path, 0);
          await uploadFile(entity.path, childRemote, onProgress: (received, total) {
            if (total > 0) {
              onProgress?.call(entity.path, received / total);
            }
          });
        }
      }
    }

    final dirName = localDirPath.split('/').last;
    await doUpload(localDirPath, '$remoteBasePath/$dirName');
  }

  /// Download a remote directory recursively to [localBasePath] via SFTP.
  Future<void> downloadDirectory(
    String remoteDirPath,
    String localBasePath, {
    void Function(String file)? onProgress,
  }) async {
    if (!isConnected) throw Exception('Not connected to SSH server');

    Future<void> doDownload(String remotePath, String localPath) async {
      await Directory(localPath).create(recursive: true);
      final items = await sftpListDir(remotePath);
      for (final item in items) {
        if (item.filename == '.' || item.filename == '..') continue;
        final childRemote = '$remotePath/${item.filename}';
        final childLocal = '$localPath/${item.filename}';
        final isDir = item.attr.isDirectory;
        if (isDir) {
          await doDownload(childRemote, childLocal);
        } else {
          onProgress?.call(childRemote);
          await downloadFile(childRemote, childLocal);
        }
      }
    }

    final dirName = remoteDirPath.split('/').last;
    await doDownload(remoteDirPath, '$localBasePath/$dirName');
  }
}

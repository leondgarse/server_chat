import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/ssh_service.dart';

class AppState extends ChangeNotifier {
  final SSHService sshService = SSHService();

  static const _batteryChannel = MethodChannel('com.mobilecoder.server_chat/battery');

  AppState() {
    sshService.onDisconnected = _onUnexpectedDisconnect;
    _loadThemeMode();
  }

  // ── Theme ──────────────────────────────────────────────────────────────────

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  Future<void> _loadThemeMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final val = prefs.getString('theme_mode') ?? 'system';
      _themeMode = val == 'light'
          ? ThemeMode.light
          : val == 'dark'
              ? ThemeMode.dark
              : ThemeMode.system;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      final val = mode == ThemeMode.light
          ? 'light'
          : mode == ThemeMode.dark
              ? 'dark'
              : 'system';
      await prefs.setString('theme_mode', val);
    } catch (_) {}
  }

  // ── Connection state ───────────────────────────────────────────────────────

  bool _isConnecting = false;
  bool get isConnecting => _isConnecting;

  bool get isConnected => sshService.isConnected;

  String? _lastError;
  String? get lastError => _lastError;

  // Path context for Claude
  String _currentPath = '/';
  String get currentPath => _currentPath;

  // ── Auto-reconnect ─────────────────────────────────────────────────────────

  /// Whether to auto-reconnect when the connection is lost unexpectedly.
  bool autoReconnect = true;

  /// True while waiting to retry (between attempts).
  bool get isReconnecting => _reconnectTimer != null && !isConnected && !isConnecting;

  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 8;
  Timer? _reconnectTimer;

  void _onUnexpectedDisconnect() {
    _currentPath = '/';
    try { WakelockPlus.disable(); } catch (_) {}
    notifyListeners();
    if (autoReconnect) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _reconnectAttempts = 0;
      return;
    }
    _reconnectTimer?.cancel();
    // Exponential backoff: 2s, 4s, 8s, 16s, 30s, 30s, 30s, 30s
    final delaySec = _reconnectAttempts < 4
        ? (2 << _reconnectAttempts)   // 2, 4, 8, 16
        : 30;
    _reconnectAttempts++;
    _reconnectTimer = Timer(Duration(seconds: delaySec), _doAutoReconnect);
  }

  Future<void> _doAutoReconnect() async {
    if (isConnected || isConnecting) {
      _reconnectAttempts = 0;
      return;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/ssh_config.json');
      if (!await file.exists()) return;
      final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (!await connectFromConfig(j)) return;
      if (isConnected) {
        _reconnectAttempts = 0;
      } else {
        _scheduleReconnect();
      }
    } catch (_) {
      _scheduleReconnect();
    }
  }

  // ── Battery optimization ───────────────────────────────────────────────────

  /// Prompt Android to exempt this app from battery optimization.
  /// No-op on non-Android platforms.
  Future<void> requestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return;
    try {
      final exempt = await _batteryChannel
          .invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
      if (!exempt) {
        await _batteryChannel.invokeMethod('requestIgnoreBatteryOptimizations');
      }
    } catch (_) {}
  }

  // ── Connect / Disconnect ───────────────────────────────────────────────────

  /// Connect using a saved config map (the `ssh_config.json` / profile format).
  /// Returns false if the config lacks a host or user.
  Future<bool> connectFromConfig(Map<String, dynamic> j) async {
    String str(String k) => (j[k] as String? ?? '').trim();
    String? opt(String k) => (j[k] as String? ?? '').isNotEmpty ? j[k] as String : null;
    final host = str('host');
    final user = str('user');
    if (host.isEmpty || user.isEmpty) return false;
    final tunnels = str('tunnels');
    SSHJumpHost? jump;
    if (str('jump') == '1' && str('jumpHost').isNotEmpty) {
      final jumpPass = opt('jumpPass');
      final jumpKey  = opt('jumpKey');
      final reuse = jumpPass == null && jumpKey == null;
      jump = SSHJumpHost(
        host: str('jumpHost'),
        port: int.tryParse(str('jumpPort')) ?? 22,
        username: str('jumpUser').isNotEmpty ? str('jumpUser') : user,
        // No jump credentials given → reuse the target's password/key.
        password: reuse ? opt('pass') : jumpPass,
        privateKey: reuse ? opt('key') : jumpKey,
      );
    }
    await connect(
      host,
      int.tryParse(str('port')) ?? 22,
      user,
      opt('pass'),
      opt('key'),
      tunnels: tunnels.isNotEmpty ? tunnels : null,
      jump: jump,
    );
    return true;
  }

  /// "via user@bastion" label for the current connection, or null if direct.
  String? get jumpLabel => _jumpLabel;
  String? _jumpLabel;

  Future<void> connect(String host, int port, String username, String? password, String? privateKey, {String? tunnels, SSHJumpHost? jump}) async {
    _reconnectTimer?.cancel();
    _isConnecting = true;
    _lastError = null;
    notifyListeners();

    try {
      await sshService.connect(
        host: host,
        port: port,
        username: username,
        password: password,
        privateKey: privateKey,
        tunnels: tunnels,
        jump: jump,
      );

      if (sshService.isConnected) {
        _jumpLabel = jump == null ? null : '${jump.username}@${jump.host}';
        _currentPath = sshService.homeDir;
        _reconnectAttempts = 0;
        try { await WakelockPlus.enable(); } catch (_) {}
        // Ask Android to stop killing this process when backgrounded.
        requestBatteryOptimizationExemption();
      }
    } catch (e) {
      _lastError = e.toString();
    } finally {
      _isConnecting = false;
      notifyListeners();
    }
  }

  void disconnect() {
    // Cancel any pending reconnect — this is intentional.
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;
    // SSHService.disconnect() sets _client=null before closing, so
    // _handleUnexpectedDisconnect() becomes a no-op and onDisconnected is never called.
    sshService.disconnect();
    try { WakelockPlus.disable(); } catch (_) {}
    notifyListeners();
  }

  /// Set cwd directly with an already-resolved absolute path (no SSH round-trip).
  void setCurrentPath(String path) {
    _currentPath = path;
    notifyListeners();
  }

  /// Validate and update cwd via SSH (for user-typed paths from the UI).
  Future<void> updatePath(String path) async {
    if (!isConnected) return;
    try {
      final result = await sshService.executeCommand('cd "$path" && pwd');
      if (result.trim().isNotEmpty && !result.toLowerCase().contains('no such file')) {
        _currentPath = result.trim();
        notifyListeners();
      } else {
        _lastError = "Invalid path: $path";
        notifyListeners();
      }
    } catch (e) {
      _lastError = "Error updating path: $e";
      notifyListeners();
    }
  }

  void clearError() {
    _lastError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    super.dispose();
  }
}

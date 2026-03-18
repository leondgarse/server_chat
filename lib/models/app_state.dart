import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/ssh_service.dart';

class AppState extends ChangeNotifier {
  final SSHService sshService = SSHService();

  AppState() {
    sshService.onDisconnected = () {
      _currentPath = '/';
      notifyListeners();
    };
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

  bool _isConnecting = false;
  bool get isConnecting => _isConnecting;

  bool get isConnected => sshService.isConnected;

  String? _lastError;
  String? get lastError => _lastError;

  // Path context for Claude
  String _currentPath = '/';
  String get currentPath => _currentPath;

  Future<void> connect(String host, int port, String username, String? password, String? privateKey, {String? tunnels}) async {
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
       );
       
       if (sshService.isConnected) {
         _currentPath = sshService.homeDir;
         try { await WakelockPlus.enable(); } catch (_) {}
       }
    } catch (e) {
      _lastError = e.toString();
    } finally {
      _isConnecting = false;
      notifyListeners();
    }
  }

  void disconnect() {
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
}

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/ssh_service.dart';

class AppState extends ChangeNotifier {
  final SSHService sshService = SSHService();

  bool _isConnecting = false;
  bool get isConnecting => _isConnecting;

  bool get isConnected => sshService.isConnected;

  String? _lastError;
  String? get lastError => _lastError;

  // Path context for Claude
  String _currentPath = '/';
  String get currentPath => _currentPath;

  Future<void> connect(String host, int port, String username, String? password, String? privateKey) async {
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

  Future<void> updatePath(String path) async {
    if (!isConnected) return;
    try {
       // Validate path exists and is a directory
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

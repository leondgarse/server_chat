import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import 'terminal_tab.dart';
import 'file_edit_tab.dart';
import 'claude_tab.dart';
import 'tmux_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  final List<Widget> _tabs = [
    const TerminalTab(),
    const FileEditTab(),
    const ClaudeTab(),
    const TmuxTab(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryAutoConnect());
  }

  Future<void> _tryAutoConnect() async {
    final state = context.read<AppState>();
    if (state.isConnected || state.isConnecting) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/ssh_config.json');
      if (!await file.exists()) return;
      final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final host = (j['host'] as String? ?? '').trim();
      final user = (j['user'] as String? ?? '').trim();
      if (host.isEmpty || user.isEmpty) return;
      if (!mounted) return;
      final tunnels = (j['tunnels'] as String? ?? '').trim();
      await state.connect(
        host,
        int.tryParse(j['port'] as String? ?? '22') ?? 22,
        user,
        (j['pass'] as String? ?? '').isNotEmpty ? j['pass'] as String : null,
        (j['key']  as String? ?? '').isNotEmpty ? j['key']  as String : null,
        tunnels: tunnels.isNotEmpty ? tunnels : null,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _tabs),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.code),       label: 'SHELL'),
          BottomNavigationBarItem(icon: Icon(Icons.folder),     label: 'FILES'),
          BottomNavigationBarItem(icon: Icon(Icons.smart_toy),  label: 'CLAUDE'),
          BottomNavigationBarItem(icon: Icon(Icons.view_agenda),label: 'TMUX'),
        ],
      ),
    );
  }
}

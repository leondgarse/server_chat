import 'package:flutter/material.dart';
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

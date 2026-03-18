import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';

/// Cycles Light → Dark → System and shows the current mode as an icon.
class ThemeSwitchButton extends StatelessWidget {
  const ThemeSwitchButton({super.key});

  static IconData _icon(ThemeMode m) => switch (m) {
        ThemeMode.light  => Icons.light_mode_outlined,
        ThemeMode.dark   => Icons.dark_mode_outlined,
        ThemeMode.system => Icons.brightness_auto_outlined,
      };

  static String _label(ThemeMode m) => switch (m) {
        ThemeMode.light  => 'Light theme',
        ThemeMode.dark   => 'Dark theme',
        ThemeMode.system => 'System theme',
      };

  static ThemeMode _next(ThemeMode m) => switch (m) {
        ThemeMode.light  => ThemeMode.dark,
        ThemeMode.dark   => ThemeMode.system,
        ThemeMode.system => ThemeMode.light,
      };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final mode  = state.themeMode;
    return IconButton(
      icon: Icon(_icon(mode)),
      tooltip: _label(mode),
      onPressed: () => state.setThemeMode(_next(mode)),
    );
  }
}

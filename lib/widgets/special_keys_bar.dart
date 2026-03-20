import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/theme.dart';

/// Shared special-keys bar used by TmuxSessionPage and InteractiveShellPage.
/// Calls [onKey] with a key name string:
///   - bare names: 'Escape', 'Tab', 'Enter', 'Up', 'Down', 'Left', 'Right',
///                 'Home', 'End', 'Delete'
///   - modifier-prefixed: e.g. 'C-a', 'S-Up', 'CA-b'  (C=Ctrl, S=Shift, A=Alt)
///
/// When a modifier is active, a hidden TextField captures the next system-
/// keyboard character and sends it with the modifier applied — no separate
/// letter row needed.
class SpecialKeysBar extends StatefulWidget {
  final void Function(String key) onKey;

  const SpecialKeysBar({super.key, required this.onKey});

  @override
  State<SpecialKeysBar> createState() => _SpecialKeysBarState();
}

class _SpecialKeysBarState extends State<SpecialKeysBar> {
  bool _ctrlOn  = false;
  bool _shiftOn = false;
  bool _altOn   = false;

  // Used to capture the next character typed on the soft keyboard
  final FocusNode _captureFocus = FocusNode();
  final TextEditingController _captureCtrl = TextEditingController();

  @override
  void dispose() {
    _captureFocus.dispose();
    _captureCtrl.dispose();
    super.dispose();
  }

  String get _activeModifier {
    final buf = StringBuffer();
    if (_ctrlOn)  buf.write('C');
    if (_shiftOn) buf.write('S');
    if (_altOn)   buf.write('A');
    return buf.toString();
  }

  void _clearModifiers() =>
      setState(() { _ctrlOn = false; _shiftOn = false; _altOn = false; });

  void _tapDirect(String key) {
    HapticFeedback.lightImpact();
    widget.onKey(key);
  }

  void _tapArrow(String dir) {
    HapticFeedback.lightImpact();
    final mod = _activeModifier;
    if (mod.isNotEmpty) {
      _clearModifiers();
      widget.onKey('$mod-$dir');
    } else {
      widget.onKey(dir);
    }
  }

  /// Called when the hidden capture field receives text from the soft keyboard.
  void _onCaptureChanged(String value) {
    if (value.isEmpty) return;
    // Take the last character typed (TextField may accumulate)
    final ch = value.characters.last.toLowerCase();
    _captureCtrl.clear();
    final mod = _activeModifier;
    _clearModifiers();
    HapticFeedback.lightImpact();
    widget.onKey(mod.isNotEmpty ? '$mod-$ch' : ch);
  }

  /// Toggle a modifier. When any modifier becomes active, focus the hidden
  /// capture field so the soft keyboard delivers input there.
  void _toggleModifier(void Function() toggle) {
    setState(toggle);
    final anyMod = _ctrlOn || _shiftOn || _altOn;
    if (anyMod) {
      _captureCtrl.clear();
      _captureFocus.requestFocus();
    } else {
      _captureFocus.unfocus();
    }
  }

  Widget _modBtn(String label, bool active, VoidCallback onTap) =>
      _ModBtn(label: label, active: active, onTap: onTap);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    final barBg     = isDark ? Colors.grey.shade900 : Colors.grey.shade200;
    final topBorder = isDark ? Colors.black : Colors.grey.shade400;

    final modifiers = [
      _modBtn('CTRL',  _ctrlOn,  () => _toggleModifier(() => _ctrlOn  = !_ctrlOn)),
      _modBtn('SHIFT', _shiftOn, () => _toggleModifier(() => _shiftOn = !_shiftOn)),
      _modBtn('ALT',   _altOn,   () => _toggleModifier(() => _altOn   = !_altOn)),
    ];
    final specials = [
      _KeyBtn(label: 'ESC',  onTap: () => _tapDirect('Escape')),
      _KeyBtn(label: 'TAB',  onTap: () => _tapDirect('Tab')),
      _KeyBtn(label: 'HOME', onTap: () => _tapDirect('Home')),
      _KeyBtn(label: 'END',  onTap: () => _tapDirect('End')),
      _KeyBtn(label: 'DEL',  onTap: () => _tapDirect('Delete')),
    ];
    final arrows = [
      _ArrowBtn(icon: Icons.arrow_left,      onTap: () => _tapArrow('Left')),
      _ArrowBtn(icon: Icons.arrow_drop_up,   onTap: () => _tapArrow('Up')),
      _ArrowBtn(icon: Icons.arrow_drop_down, onTap: () => _tapArrow('Down')),
      _ArrowBtn(icon: Icons.arrow_right,     onTap: () => _tapArrow('Right')),
    ];
    final retBtn = Expanded(
      child: _KeyBtn(
        label: 'RET',
        icon: Icons.keyboard_return,
        onTap: () => _tapDirect('Enter'),
        accent: AppTheme.primaryBlue,
      ),
    );

    // Invisible 1px TextField that captures the next soft-keyboard character
    // when a modifier is active. Must have non-zero size to receive focus on
    // Android. keyboardType.visiblePassword suppresses autocorrect/suggestions
    // while keeping the normal (non-secure) keyboard layout.
    final captureField = SizedBox(
      height: 1,
      width: double.infinity,
      child: Opacity(
        opacity: 0,
        child: TextField(
          focusNode: _captureFocus,
          controller: _captureCtrl,
          onChanged: _onCaptureChanged,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          style: const TextStyle(fontSize: 1),
          decoration: const InputDecoration(
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: barBg,
        border: Border(top: BorderSide(color: topBorder, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            captureField,
            if (isLandscape) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: Row(
                  children: [
                    ...modifiers,
                    ...specials,
                    ...arrows,
                    const SizedBox(width: 4),
                    retBtn,
                  ],
                ),
              ),
            ] else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
                child: Row(children: [...modifiers, ...specials]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
                child: Row(children: [...arrows, const SizedBox(width: 8), retBtn]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _KeyBtn extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final Color? accent;

  const _KeyBtn({
    required this.label,
    required this.onTap,
    this.icon,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg     = isDark ? Colors.grey.shade800 : Colors.grey.shade300;
    final fg     = isDark ? Colors.white70 : Colors.black87;
    final border = isDark ? Colors.black : Colors.grey.shade400;
    final color  = accent ?? fg;

    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 34,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: accent != null ? accent!.withValues(alpha: 0.18) : bg,
            borderRadius: BorderRadius.circular(5),
            border: Border(
              bottom: BorderSide(
                color: accent != null ? accent!.withValues(alpha: 0.4) : border,
                width: 2,
              ),
            ),
          ),
          child: Center(
            child: icon != null
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 12, color: color),
                      const SizedBox(width: 2),
                      Text(label,
                          style: TextStyle(
                              fontSize: 9, fontWeight: FontWeight.w700, color: color)),
                    ],
                  )
                : Text(label,
                    style: TextStyle(
                        fontSize: 9, fontWeight: FontWeight.w700, color: color)),
          ),
        ),
      ),
    );
  }
}

class _ModBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ModBtn({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark  = Theme.of(context).brightness == Brightness.dark;
    final inactiveBg     = isDark ? Colors.grey.shade800 : Colors.grey.shade300;
    final inactiveBorder = isDark ? Colors.black : Colors.grey.shade400;

    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 34,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: active ? AppTheme.primaryBlue : inactiveBg,
            borderRadius: BorderRadius.circular(5),
            border: Border(
              bottom: BorderSide(
                color: active
                    ? AppTheme.primaryBlue.withValues(alpha: 0.6)
                    : inactiveBorder,
                width: 2,
              ),
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: active ? Colors.white : AppTheme.primaryBlue,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ArrowBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ArrowBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg     = isDark ? Colors.grey.shade800 : Colors.grey.shade300;
    final fg     = isDark ? Colors.white70 : Colors.black87;
    final border = isDark ? Colors.black : Colors.grey.shade400;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 34,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(5),
          border: Border(bottom: BorderSide(color: border, width: 2)),
        ),
        child: Icon(icon, size: 18, color: fg),
      ),
    );
  }
}

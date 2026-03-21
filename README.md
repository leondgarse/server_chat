# TermiConnect

A Flutter SSH client for Android/Linux with a chat-style UX for Claude Code sessions, terminal commands, tmux, and remote file editing.

## Features

### Shell Tab
- Chat-style terminal: type a command, get the output as a reply bubble
- Command history (↑/↓ in AppBar)
- Stop button cancels a running command mid-execution
- Interactive commands (`vim`, `python`, `ipython`, `claude`, etc.) push a full-screen PTY page (isolated per command)
- `cd` tracks working directory; shared live with Files and Claude tabs

### PTY Tab
- Persistent full-screen `bash` shell using xterm terminal emulator
- Survives tab switches (keeps state via `AutomaticKeepAliveClientMixin`)
- Auto-starts on connect, auto-cd to the current working directory
- **Command suggestions**: as you type, matching commands from `~/.bash_history` appear as tappable chips above the key bar — tap to complete
- Special-keys bar for modifier combos and arrow keys
- Reconnect button when the shell session exits

### Files Tab
- Load a remote file over SSH → edit in a text field → save back
- Path picker browses the remote filesystem via SFTP
- Path field automatically follows the current working directory from Shell

### Claude Tab
- Chat interface to [Claude Code](https://github.com/anthropics/claude-code) running on the server
- Uses `claude -p --output-format stream-json --verbose --dangerously-skip-permissions`
- Streams assistant text, tool calls (`▶ Bash: ls -la`), and actual tool output in real time
- Session resume: re-uses the last `session_id` with `--resume`
- Folder picker for working directory; automatically follows Shell/Files current path
- Prompt history (↑/↓ in AppBar)

### Tmux Tab
- Lists all tmux sessions, windows, and panes in a tree view
- Pane layout overview: a scaled diagram showing exact pane positions — tap any pane to jump directly to it (zooms in on that pane)
- Attach to any session/window/pane in a full-screen xterm terminal
- Mouse support (`tmux set -g mouse on` is sent on attach)
- Pinch-to-zoom and ±1pt font buttons (7–28pt range)
- Landscape mode: fullscreen immersive, single-row key bar
- Special-keys bar with CTRL/SHIFT/ALT modifier stacking, arrows, ESC, TAB, HOME, END, DEL, RET
- Configurable PREFIX key button: tap sends the prefix immediately; long-press to edit (e.g. `C-b` or `C-s`) — persisted in SharedPreferences
- Drag or mouse-wheel to scroll: enters tmux copy-mode via SSH; exits automatically at the bottom or on any non-arrow key
- Arrow keys Up/Down while in copy-mode continue scrolling; any other key exits copy-mode first
- Long-press arrow keys for continuous repeat (80ms interval)

### Connect Tab
- SSH connection form: host, port, username, password, private key (paste)
- **Local port tunnels**: add `localPort → remotePort` pairs (forwarded to remote `localhost`) — set up before connecting, auto-restored at startup
- Save / load / delete named connection profiles (stored in SharedPreferences)
- Auto-connects to the last-used connection on startup
- Connection status shown as a button in the AppBar of every tab

### Theme
- Light, Dark, and System (auto) themes
- Toggle with the sun/moon icon in the AppBar of any tab — change takes effect instantly and is persisted
- xterm terminal views (PTY, Tmux, Shell PTY) use a matching light theme when in light mode

## Shared Current Directory

All editing/execution tabs share a single working-directory state (`AppState.currentPath`):
- **Shell** — updated on every `cd` command
- **Files** — path field follows Shell's directory automatically (unless a file is already open)
- **Claude** — uses the current path as the project directory for every prompt (auto-updates when idle)

## Special Keys Bar

Available in the **PTY** tab, **Tmux** full-screen terminal, and **Shell PTY** page:

| Row (portrait) | Keys |
|---|---|
| Row 1 | PREFIX (tmux only) · CTRL · SHIFT · ALT · ESC · TAB · HOME · END · DEL |
| Row 2 | ← ↑ ↓ → · RET |

- Modifier keys (CTRL/SHIFT/ALT) stack independently; tapping a letter or arrow while a modifier is active sends the correct xterm escape sequence and clears the modifier
- Long-press any arrow key for continuous repeat
- Landscape: all keys on a single row
- PREFIX button (Tmux only): one-shot — tap to send the configured prefix key immediately; long-press to change it

## Project Layout

```
lib/
├── main.dart
├── models/
│   ├── app_state.dart               # ChangeNotifier: SSH, theme, current path, auto-reconnect
│   └── chat_message.dart
├── screens/
│   ├── home_screen.dart             # Bottom nav (Shell/Files/PTY/Claude/Tmux) + auto-connect
│   ├── connect_tab.dart             # SSH form, profiles, local tunnels
│   ├── terminal_tab.dart            # Chat-style shell
│   ├── pty_tab.dart                 # Persistent PTY shell tab
│   ├── tmux_tab.dart                # Tmux tree view + full xterm session
│   ├── claude_tab.dart              # Claude Code chat
│   ├── file_edit_tab.dart           # Remote file editor
│   └── interactive_shell_page.dart  # Full-screen PTY pushed for interactive shell commands
├── services/
│   └── ssh_service.dart             # dartssh2 wrapper (exec, shell, SFTP, keepalive, tunnels)
├── utils/
│   └── theme.dart                   # Light/dark TermiConnect theme
└── widgets/
    ├── connection_button.dart        # AppBar SSH status icon
    ├── theme_switch_button.dart      # AppBar light/dark/auto toggle
    ├── special_keys_bar.dart         # Shared PTY key bar (PTY, Tmux, Shell PTY)
    └── remote_path_picker.dart       # SFTP file/folder browser dialog
```

## Key Dependencies

| Package | Purpose |
|---|---|
| `dartssh2` | SSH client — exec, interactive shell, SFTP, local port forwarding |
| `xterm` (Termius fork) | Terminal emulator widget (PTY rendering, alt-buffer, light/dark themes) |
| `provider` | State management |
| `shared_preferences` | Persist SSH profiles, theme, tmux prefix key |
| `path_provider` | Local file paths |
| `google_fonts` | Space Grotesk font |
| `wakelock_plus` | Keep screen on during sessions |

## Build & Run

```bash
cd server_chat
flutter pub get

# Linux desktop (for quick testing)
flutter run -d linux

# Android device
flutter run

# Release APK
flutter build apk --release
```

## Design System

Defined in `DESIGN.md`. Summary:
- Font: **Space Grotesk**
- Primary: `#0d33f2`
- Background Light: `#f5f6f8` / Dark: `#101322`
- Chat bubble radius: 12px | Input radius: 8px

## Known Limitations

- Claude tab uses `--dangerously-skip-permissions` (required for non-interactive mode)
- Tmux terminal sizing requires the SSH handshake to complete after the first layout frame; initial render may briefly show default 80×25 before correct resize
- Large file edits load the entire file into memory
- No SSH host key verification (trusts all hosts)
- Local port tunnel `remoteHost` is always `localhost` on the remote side (sufficient for most use cases)
- Tmux pane copy-mode scroll: at the bottom (`[0/...]`), press `q` via the soft keyboard or ESC key to exit copy-mode manually

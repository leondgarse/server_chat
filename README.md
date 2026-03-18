# TermiConnect

A Flutter SSH client for Android/Linux with a chat-style UX for Claude Code sessions, terminal commands, tmux, and remote file editing.

## Features

### Shell Tab
- Chat-style terminal: type a command, get the output as a reply bubble
- Command history (↑/↓ in AppBar)
- Stop button cancels a running command mid-execution
- Interactive commands (`vim`, `python`, `claude`, etc.) open in a full-screen PTY page
- PTY button opens a full `bash` PTY with special-keys bar
- `cd` tracks working directory; shared live with Files and Claude tabs

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
- Pane layout overview: a scaled diagram showing exact pane positions — tap any pane to jump directly to it
- Attach to any session/window/pane in a full-screen xterm terminal
- Mouse support (`tmux set -g mouse on` is sent on attach)
- Pinch-to-zoom and ±1pt font buttons (7–28pt range)
- Landscape mode: fullscreen immersive, single-row key bar
- Special-keys bar with CTRL/SHIFT/ALT modifier stacking, a–z letter row, arrows, ESC, TAB, HOME, END, DEL, RET

### Connect Tab
- SSH connection form: host, port, username, password, private key (paste)
- **Local port tunnels**: add `localPort → remotePort` pairs (forwarded to remote `localhost`) — set up before connecting, auto-restored at startup
- Save / load / delete named connection profiles (stored in SharedPreferences)
- Auto-connects to the last-used connection on startup
- Connection status shown as a button in the AppBar of every tab

### Theme
- Light, Dark, and System (auto) themes
- Toggle with the sun/moon icon in the AppBar of any tab — change takes effect instantly and is persisted

## Shared Current Directory

All three editing/execution tabs share a single working-directory state (`AppState.currentPath`):
- **Shell** — updated on every `cd` command
- **Files** — path field follows Shell's directory automatically (unless a file is already open)
- **Claude** — uses the current path as the project directory for every prompt (auto-updates when idle)

## Special Keys Bar

Available in both the **Tmux** full-screen terminal and the **Shell PTY** page:

| Row | Keys |
|-----|------|
| Row 1 | CTRL · SHIFT · ALT · ESC · TAB · HOME · END · DEL |
| Row 2 | ← ↑ ↓ → · RET |
| (modifier active) | Scrollable a–z letter row for modifier+key combos |

Modifier keys stack independently; tapping a letter or arrow while a modifier is active sends the correct xterm escape sequence and clears the modifier.

## Project Layout

```
lib/
├── main.dart
├── models/
│   ├── app_state.dart               # ChangeNotifier: SSH, theme, current path
│   └── chat_message.dart
├── screens/
│   ├── home_screen.dart             # Bottom nav + auto-connect on startup
│   ├── connect_tab.dart             # SSH form, profiles, local tunnels
│   ├── terminal_tab.dart            # Chat-style shell
│   ├── tmux_tab.dart                # Tmux tree view + full xterm session
│   ├── claude_tab.dart              # Claude Code chat
│   ├── file_edit_tab.dart           # Remote file editor
│   └── interactive_shell_page.dart  # Full-screen PTY for interactive commands
├── services/
│   └── ssh_service.dart             # dartssh2 wrapper (exec, shell, SFTP, keepalive, tunnels)
├── utils/
│   └── theme.dart                   # Light/dark TermiConnect theme
└── widgets/
    ├── connection_button.dart        # AppBar SSH status icon
    ├── theme_switch_button.dart      # AppBar light/dark/auto toggle
    ├── special_keys_bar.dart         # Shared PTY key bar (tmux + shell PTY)
    └── remote_path_picker.dart       # SFTP file/folder browser dialog
```

## Key Dependencies

| Package | Purpose |
|---|---|
| `dartssh2` | SSH client — exec, interactive shell, SFTP, local port forwarding |
| `xterm` (Termius fork) | Terminal emulator widget (PTY rendering) |
| `provider` | State management |
| `shared_preferences` | Persist SSH profiles and theme preference |
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

# TermiConnect

A Flutter SSH client for Android/Linux with a chat-style UX for Claude Code sessions, terminal commands, tmux, and remote file editing.

## Features

### Shell Tab
- Chat-style terminal: type a command, get the output as a reply bubble
- Command history (↑/↓ in AppBar)
- Interactive commands (`vim`, `python`, `node`, etc.) open in a full-screen PTY page
- `cd` tracks working directory across commands

### Tmux Tab
- Lists running tmux sessions on the remote server
- Create new session (`mobile<timestamp>`)
- Attach to any session in a full-screen xterm terminal
- Mouse support (`tmux set -g mouse on` is sent on attach)
- Zoom in/out font size (7–28pt range)
- PTY size synced with terminal widget layout for correct status-bar rendering

### Claude Tab
- Chat interface to [Claude Code](https://github.com/anthropics/claude-code) running on the server
- Uses `claude -p --output-format stream-json --verbose --dangerously-skip-permissions`
- Streams assistant text, tool calls (`▶ Bash: ls -la`), and actual tool output in real time
- Session resume: re-uses the last `session_id` with `--resume`
- Folder picker for working directory

### File Edit Tab
- Load a remote file over SSH → edit in a text field → save back
- Path picker browses the remote filesystem via SFTP

### Connect Tab
- SSH connection form: host, port, username, password, private key (paste)
- Save / load / delete named connection profiles (stored in SharedPreferences)
- Connection status shown as a button in the AppBar of every tab

## Project Layout

```
lib/
├── main.dart
├── models/
│   ├── app_state.dart          # ChangeNotifier: SSH state, connect/disconnect
│   └── chat_message.dart       # Simple message model (text, isUser)
├── screens/
│   ├── home_screen.dart         # Bottom nav: Shell / Files / Claude / Tmux
│   ├── connect_tab.dart         # SSH connection form + saved profiles
│   ├── terminal_tab.dart        # Chat-style shell
│   ├── tmux_tab.dart            # Tmux session list + full xterm attach
│   ├── claude_tab.dart          # Claude Code chat interface
│   ├── file_edit_tab.dart       # Remote file editor
│   └── interactive_shell_page.dart  # Full-screen PTY for interactive commands
├── services/
│   └── ssh_service.dart         # dartssh2 wrapper (exec, shell, SFTP, keepalive)
├── utils/
│   └── theme.dart               # TermiConnect light/dark theme
└── widgets/
    ├── connection_button.dart   # AppBar icon → ConnectTab overlay
    └── remote_path_picker.dart  # SFTP file/folder browser dialog
```

## Key Dependencies

| Package | Purpose |
|---|---|
| `dartssh2` | SSH client — exec, interactive shell, SFTP |
| `xterm` (Termius fork) | Terminal emulator widget (PTY rendering) |
| `provider` | State management |
| `shared_preferences` | Persist SSH profiles |
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

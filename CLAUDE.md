# TermiConnect — Android SSH Chat App

Flutter (Dart) app for SSH-based server interaction. Chat-style UX for Claude Code sessions, terminal commands, tmux, and file editing. Tested on Android and Linux desktop (`flutter run -d linux`).

## Project Layout

```
server_chat/              # Flutter app root (main codebase)
├── lib/
│   ├── main.dart
│   ├── models/
│   │   ├── app_state.dart          # ChangeNotifier: SSH state
│   │   └── chat_message.dart
│   ├── screens/
│   │   ├── home_screen.dart         # Bottom nav: Shell / Files / Claude / Tmux
│   │   ├── connect_tab.dart         # SSH form + saved named profiles
│   │   ├── terminal_tab.dart        # Chat-style shell commands
│   │   ├── tmux_tab.dart            # Tmux session list + xterm attach
│   │   ├── claude_tab.dart          # Claude Code chat (--print stream-json)
│   │   ├── file_edit_tab.dart       # Remote file editor
│   │   └── interactive_shell_page.dart  # Full-screen PTY page
│   ├── services/
│   │   └── ssh_service.dart         # dartssh2 wrapper, keepalive, SFTP
│   ├── utils/
│   │   └── theme.dart               # Light/dark TermiConnect theme
│   └── widgets/
│       ├── connection_button.dart   # AppBar status icon → ConnectTab
│       └── remote_path_picker.dart  # SFTP file browser dialog
├── pubspec.yaml
├── stitch.json                    # Stitch project ID
├── next-prompt.md                 # Stitch loop baton (current page task)
├── queue/                         # Stitch generated HTML/PNG staging
├── README.md                      # User-facing docs
└── DESIGN.md                      # Design system (Space Grotesk, #0d33f2, etc.)
```

## Key Dependencies

| Package | Purpose |
|---|---|
| `dartssh2` | SSH client (connect, exec, shell, SFTP) |
| `xterm` (Termius fork) | Terminal emulator — `github.com/termius/xterm.dart` |
| `provider` | State management |
| `shared_preferences` | Persist SSH connection profiles |
| `google_fonts` | Space Grotesk font |
| `path_provider` | Local file paths |
| `wakelock_plus` | Keep screen on during SSH sessions |

## Design System

- **Font:** Space Grotesk  |  **Primary:** `#0d33f2`
- **Background Light:** `#f5f6f8`  /  **Dark:** `#101322`
- **Border radius:** 12px chat bubbles, 8px inputs
- Full spec in `DESIGN.md` (Section 6 = Stitch prompt block)

## Architecture Notes

### Bottom nav tabs (home_screen.dart)
- Index 0: Shell (TerminalTab)
- Index 1: Files (FileEditTab)
- Index 2: Claude (ClaudeTab)
- Index 3: Tmux (TmuxTab)
- ConnectTab is NOT in the nav — accessed via ConnectionButton in every AppBar

### Claude Tab
- Non-interactive `claude -p` mode with `--output-format stream-json --verbose --dangerously-skip-permissions [--resume <id>]`
- Prompt is base64-encoded to avoid shell quoting: `CLAUDE_PROMPT=$(printf '%s' 'B64' | base64 -d)`
- `startRawSession(command)` in SSHService: runs `bash -l -s`, writes command, closes stdin (EOF)
- Parses stream-json events: `system/init` → session_id, `assistant` → text + tool_use hints, `user` → tool_result (actual command output)

### Tmux Tab
- Lists sessions: `tmux list-sessions -F "#{session_name} #{session_windows}w #{session_attached}"`
- `TmuxSessionPage` uses `xterm` Terminal + TerminalView for full PTY
- `terminal.onOutput` → forwards terminal responses back to PTY stdin
- `terminal.onResize` → stores cols/rows, calls `session.resizeTerminal()`
- SSH shell opened with `width: _lastCols, height: _lastRows` (populated by first onResize before handshake completes)
- `tmux attach` sent AFTER session is ready with correct dimensions

### SSH Service (`ssh_service.dart`)
- Keepalive: `true` command every 15s
- `resolvePath()` expands `~` to actual home dir (cached after connect via `echo $HOME`)
- `startInteractiveShell({termType, width, height})` — PTY shell
- `startRawSession(command)` — `bash -l -s` + stdin write + EOF (for Claude)
- `executeCommand(cmd)` — single exec channel, returns stdout+stderr

### Connect Tab
- Profiles stored in SharedPreferences key `ssh_profiles` as JSON map
- Last-used connection stored in `getApplicationDocumentsDirectory()/ssh_config.json`

## Build & Run

```bash
flutter pub get
flutter run -d linux              # Linux desktop testing
flutter run                       # Android device
flutter build apk --release       # Release APK
```

## Stitch Workflow

Skills: `stitch-loop`, `design-md`, `enhance-prompt` in `~/.claude/skills/`

1. Edit `next-prompt.md` (YAML frontmatter: `page: <name>`)
2. Include design block from `DESIGN.md` Section 6
3. Run `/stitch-loop`

## MCP Servers

- **dart-mcp-server**: configured in `/home/leondgarse/workspace/mobile_coder/.mcp.json`
- **StitchMCP**: `~/.gemini/antigravity/mcp_config.json`

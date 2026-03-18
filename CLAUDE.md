# TermiConnect — Android SSH Chat App

Flutter (Dart) app for SSH-based server interaction. Chat-style UX for Claude Code sessions, terminal commands, tmux, and file editing. Tested on Android and Linux desktop (`flutter run -d linux`).

## Project Layout

```
server_chat/              # Flutter app root (main codebase)
├── lib/
│   ├── main.dart
│   ├── models/
│   │   ├── app_state.dart          # ChangeNotifier: SSH state, theme mode, currentPath
│   │   └── chat_message.dart
│   ├── screens/
│   │   ├── home_screen.dart         # Bottom nav: Shell / Files / Claude / Tmux + auto-connect
│   │   ├── connect_tab.dart         # SSH form + saved profiles + local port tunnels
│   │   ├── terminal_tab.dart        # Chat-style shell commands
│   │   ├── tmux_tab.dart            # Tmux session tree + pane overview + xterm attach
│   │   ├── claude_tab.dart          # Claude Code chat (--print stream-json)
│   │   ├── file_edit_tab.dart       # Remote file editor
│   │   └── interactive_shell_page.dart  # Full-screen PTY page (chat-bubble display)
│   ├── services/
│   │   └── ssh_service.dart         # dartssh2 wrapper: exec, shell, SFTP, keepalive, port-forward
│   ├── utils/
│   │   └── theme.dart               # Light/dark TermiConnect theme (Space Grotesk, #0d33f2)
│   └── widgets/
│       ├── connection_button.dart   # AppBar SSH status icon → ConnectTab
│       ├── theme_switch_button.dart # AppBar light/dark/system toggle (cycles, persisted)
│       ├── special_keys_bar.dart    # Shared PTY key bar for Tmux + Shell PTY pages
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
| `dartssh2` | SSH client (connect, exec, shell, SFTP, forwardLocal) |
| `xterm` (Termius fork) | Terminal emulator — `github.com/termius/xterm.dart` |
| `provider` | State management |
| `shared_preferences` | Persist SSH profiles, theme preference |
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
- `_tryAutoConnect()` in `initState` reads `ssh_config.json` and connects automatically, including restoring local port tunnels

### Shared Current Directory
All three content tabs share `AppState.currentPath`:
- **Shell**: updated after every `cd` command via `state.setCurrentPath(newDir)`
- **Files**: `_syncCurrentPath()` in `build()` updates `_pathController.text` when `state.currentPath` changes, only if `_contentController.text.isEmpty` (no file open)
- **Claude**: same `_syncCurrentPath()` pattern — only auto-updates when `!_started && !_isSending`

### Theme
- `AppState._themeMode` (default `ThemeMode.system`), loaded from SharedPreferences key `theme_mode` at startup
- `AppState.setThemeMode(mode)` notifies listeners + persists
- `ServerChatApp` uses `context.watch<AppState>().themeMode` so `MaterialApp.themeMode` rebuilds instantly
- `ThemeSwitchButton` widget in every AppBar cycles: Light → Dark → System → Light

### Claude Tab
- Non-interactive `claude -p` mode with `--output-format stream-json --verbose --dangerously-skip-permissions [--resume <id>]`
- Prompt is base64-encoded: `CLAUDE_PROMPT=$(printf '%s' 'B64' | base64 -d)`
- `startRawSession(command)` in SSHService: runs `bash -l -s`, writes PATH-fix line then command, closes stdin (EOF)
- Parses stream-json events: `system/init` → session_id, `assistant` → text + tool_use hints, `user` → tool_result output

### Tmux Tab
- One-shot query: `tmux list-panes -a -F "...#{pane_left}|||#{pane_top}"` — 12 fields per line
- `_PaneData` has `left`, `top`, `width`, `height` for spatial layout
- `_PaneLayoutOverview` widget: scaled `Stack` of tappable rectangles showing exact pane positions
  - Minimum rendered pane height: `max(proportional, maxBottom*22/minPaneRows)` so numbers always fit
- `TmuxSessionPage._startSession()`: pane zoom via `executeCommand('tmux select-pane -t X && tmux resize-pane -Z -t X')`
- `dispose()`: fire-and-forget unzoom when `initialPaneId != null`
- Landscape fullscreen: `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)`, AppBar hidden
- Pinch-to-zoom: raw `Listener` with `_pointers` map (bypasses gesture arena)
- `_sendKey` / `_sendModified`: xterm modifier table — code = 1 + Shift(1) + Alt(2) + Ctrl(4)
- Auto-load trigger in `build()`: fires `_loadSessions()` when `state.isConnected && _sessions.isEmpty && !_loading && _error == null`

### Special Keys Bar (shared widget)
`lib/widgets/special_keys_bar.dart` — used by both `TmuxSessionPage` and `InteractiveShellPage`.
- `onKey` callback receives bare key names or modifier-prefixed strings (`'C-a'`, `'CS-Up'`)
- **Portrait**: Row 1 = CTRL · SHIFT · ALT · ESC · TAB · HOME · END · DEL; Row 2 = ← ↑ ↓ → · RET
- **Landscape**: single row with all buttons
- Modifier-active: scrollable a–z letter row appended below
- Fully theme-adaptive: `isDark` check in each button widget; dark = `grey.shade800/900`, light = `grey.shade200/300`

### Local Port Tunnels
- Stored as `tunnels: "localPort:localhost:remotePort\n..."` in `ssh_config.json` and profiles
- `SSHService._setupLocalForwards(tunnels)`: binds `ServerSocket` on `127.0.0.1:localPort` per entry
- Each accepted TCP connection → `_client.forwardLocal(remoteHost, remotePort)` → bidirectional pipe
- `_closeLocalForwards()` called on both `disconnect()` and `_handleUnexpectedDisconnect()`
- ConnectTab UI: dynamic list of `localPort → remotePort` rows with + Add / × remove; remote host always `localhost`

### SSH Service (`ssh_service.dart`)
- Keepalive: protocol-level (`keepAliveInterval: 20s`) + secondary `Timer.periodic(30s)` running `true`
- `resolvePath()` expands `~` to actual home dir (cached after connect via `echo $HOME`)
- `startInteractiveShell({termType, width, height})` — PTY shell for Tmux and Shell PTY page
- `startRawSession(command)` — `bash -l -s` + PATH-fix subshell + stdin write + EOF (for Claude)
- `executeCommand(cmd)` — `bash -l -i -c` with stdout/stderr separation; filters bash startup warnings
- `cancelCommand()` — closes `_activeCommand` session (Shell stop button)

### Connect Tab
- Profiles stored in SharedPreferences key `ssh_profiles` as JSON map
- Last-used connection stored in `getApplicationDocumentsDirectory()/ssh_config.json`
- Tunnel rows: `List<_TunnelRow>` (each has `local`/`remote` TextEditingController); serialised by `_tunnelsString` getter

### Interactive Shell Page
- Full PTY via `startInteractiveShell()` but chat-bubble display (ANSI stripped)
- `_sendKey(String)` + `_sendModified(...)` translate `SpecialKeysBar` key names to raw byte sequences
- Ctrl+C / Ctrl+D now handled via CTRL modifier in key bar (no dedicated AppBar buttons)

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

# currentDate
Today's date is 2026-03-18.

# TermiConnect — Android SSH Chat App

Flutter (Dart) app for SSH-based server interaction. Chat-style UX for Claude Code sessions, terminal commands, tmux, and file editing. Tested on Android and Linux desktop (`flutter run -d linux`).

## Project Layout

```
server_chat/              # Flutter app root (main codebase)
├── lib/
│   ├── main.dart
│   ├── models/
│   │   ├── app_state.dart          # ChangeNotifier: SSH state, theme mode, currentPath, auto-reconnect
│   │   └── chat_message.dart
│   ├── screens/
│   │   ├── home_screen.dart         # Bottom nav: Shell / Files / PTY / Claude / Tmux + auto-connect
│   │   ├── connect_tab.dart         # SSH form + saved profiles + local port tunnels
│   │   ├── terminal_tab.dart        # Chat-style shell commands
│   │   ├── pty_tab.dart             # Persistent PTY shell tab (xterm, AutomaticKeepAlive)
│   │   ├── tmux_tab.dart            # Tmux session tree + pane overview + xterm attach
│   │   ├── claude_tab.dart          # Claude Code chat (--print stream-json)
│   │   ├── file_edit_tab.dart       # Remote file editor
│   │   └── interactive_shell_page.dart  # Full-screen xterm PTY pushed for interactive commands
│   ├── services/
│   │   └── ssh_service.dart         # dartssh2 wrapper: exec, shell, SFTP, keepalive, port-forward
│   ├── utils/
│   │   └── theme.dart               # Light/dark TermiConnect theme (Space Grotesk, #0d33f2)
│   └── widgets/
│       ├── connection_button.dart   # AppBar SSH status icon → ConnectTab
│       ├── theme_switch_button.dart # AppBar light/dark/system toggle (cycles, persisted)
│       ├── special_keys_bar.dart    # Shared PTY key bar for PTY, Tmux, Shell PTY pages
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
| `shared_preferences` | Persist SSH profiles, theme preference, tmux prefix key |
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
- Index 2: PTY (PtyTab) — persistent xterm shell, starts on connect via `addPostFrameCallback`
- Index 3: Claude (ClaudeTab)
- Index 4: Tmux (TmuxTab)
- ConnectTab is NOT in the nav — accessed via ConnectionButton in every AppBar
- `_tryAutoConnect()` in `initState` reads `ssh_config.json` and connects automatically, including restoring local port tunnels
- **CRITICAL**: PtyTab uses a `_starting` bool (set synchronously before `await`) in addition to `_isRunning` to prevent multiple concurrent `startInteractiveShell()` calls during the connect/rebuild cycle. Without this, multiple shell channels open simultaneously, exhausting the server's SSH channel limit and causing `SSHChannelOpenError(2)` in Shell/Files tabs.

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
- One-shot query: `tmux list-panes -a -F "...#{pane_left}|||#{pane_top}"` — 14 fields per line including `#{window_zoomed_flag}`
- `_PaneData` has `left`, `top`, `width`, `height` for spatial layout
- `_PaneLayoutOverview` widget: scaled `Stack` of tappable rectangles showing exact pane positions
  - Minimum rendered pane height: `max(proportional, maxBottom*22/minPaneRows)` so numbers always fit
- `TmuxSessionPage._startSession()`: pane zoom via `executeCommandFast('tmux select-pane -t X && tmux resize-pane -Z -t X')` after 800ms delay
- `dispose()`: fire-and-forget unzoom — checks `#{window_zoomed_flag}` first to avoid toggle-back race
- Landscape fullscreen: `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)`, AppBar hidden
- Pinch-to-zoom: raw `Listener` with `_pointers` map (bypasses gesture arena)
- `_sendKey` / `_sendModified`: xterm modifier table — code = 1 + Shift(1) + Alt(2) + Ctrl(4)
- Auto-load trigger in `build()`: fires `_loadSessions()` when `state.isConnected && _sessions.isEmpty && !_loading && _error == null`
- **Scroll**: ALL scroll (both pane mode and window mode) goes through `_tmuxScroll()` via SSH copy-mode commands. xterm `ScrollController.jumpTo()` does NOT work for tmux because tmux always uses the alt-screen buffer — xterm replaces the normal Scrollable with `InfiniteScrollView` in alt-buffer mode, making pixel-based scroll a no-op.
- `_tmuxScroll(lines)`: `lines > 0` = scroll-up (see older content). Enters copy-mode if not already in it. On scroll-down, checks `#{scroll_position}` and auto-exits copy-mode at 0. Sends `tmux send-keys -X scroll-up/down` via `executeCommandFast`.
- `_exitCopyMode()`: sends `q` via `_session.stdin` (the attached PTY client) — tmux receives it directly, NOT via `executeCommandFast`.
- `_sendKeyWithCopyMode`: in copy-mode, Up/Down continue scrolling; any other key exits copy-mode first; Escape exits without forwarding.
- Pane selector (`_showPaneSelector`) and window selector (`_showWindowSelector`): use `executeCommandFast` for `tmux select-pane/window` — stdin goes to the shell inside the pane, not tmux control.
- **Breadcrumb** in AppBar title shows pane nav only when `widget.initialPaneId != null` (authoritative pane-mode flag), NOT based on `_windows.any(w.zoomed)`.
- PREFIX key in `SpecialKeysBar`: one-shot (tap sends immediately), NOT a sticky modifier. Long-press opens editor dialog. Stored in SharedPreferences key `tmux_prefix`.

### Special Keys Bar (shared widget)
`lib/widgets/special_keys_bar.dart` — used by `PtyTab`, `TmuxSessionPage`, and `InteractiveShellPage`.
- `onKey` callback receives bare key names or modifier-prefixed strings (`'C-a'`, `'CS-Up'`)
- **Portrait**: Row 1 = PREFIX (optional) · CTRL · SHIFT · ALT · ESC · TAB · HOME · END · DEL; Row 2 = ← ↑ ↓ → · RET
- **Landscape**: single row with all buttons
- Modifier keys (CTRL/SHIFT/ALT): sticky toggles — when active, hidden capture TextField takes focus so next soft-keyboard character is sent with the modifier applied
- PREFIX button: one-shot (sends `onKey(prefix)` immediately on tap); long-press opens edit dialog. No `_prefixArmed` state — it is NOT a combining modifier.
- Arrow buttons (`_ArrowBtn`): `StatefulWidget` with `Timer.periodic(80ms)` on long-press for continuous repeat
- Fully theme-adaptive: `isDark` check in each button widget; dark = `grey.shade800/900`, light = `grey.shade200/300`

### Local Port Tunnels
- Stored as `tunnels: "localPort:localhost:remotePort\n..."` in `ssh_config.json` and profiles
- `SSHService._setupLocalForwards(tunnels)`: binds `ServerSocket` on `127.0.0.1:localPort` per entry
- Each accepted TCP connection → `_client.forwardLocal(remoteHost, remotePort)` → bidirectional pipe
- `_closeLocalForwards()` called on both `disconnect()` and `_handleUnexpectedDisconnect()`
- ConnectTab UI: dynamic list of `localPort → remotePort` rows with + Add / × remove; remote host always `localhost`

### SSH Service (`ssh_service.dart`)
- Keepalive: protocol-level (`keepAliveInterval: 20s`) only. Secondary `Timer.periodic(30s)` checks `isConnected` locally — does NOT open SSH channels (avoids channel slot exhaustion).
- Home dir cached at connect via `executeCommandFast('echo $HOME')` — NOT `_client!.run()`. `run()` has a dartssh2 bug where it does not close the SSH channel after completion, leaving a slot permanently occupied. `executeCommandFast` properly awaits channel close via stream `onDone`.
- `resolvePath()` expands `~` to actual home dir (cached after connect)
- `startInteractiveShell({termType, width, height})` — PTY shell for PTY tab, Tmux, and InteractiveShellPage
- `startRawSession(command)` — `bash -l -s` + PATH-fix subshell + stdin write + EOF (for Claude)
- `executeCommand(cmd)` — `bash -l -i -c` with stdout/stderr separation; filters bash startup warnings
- `executeCommandFast(cmd)` — `bash -c` (no login/interactive); faster, for tmux control and home dir detection
- `cancelCommand()` — closes `_activeCommand` session (Shell stop button)

### Connect Tab
- Profiles stored in SharedPreferences key `ssh_profiles` as JSON map
- Last-used connection stored in `getApplicationDocumentsDirectory()/ssh_config.json`
- Tunnel rows: `List<_TunnelRow>` (each has `local`/`remote` TextEditingController); serialised by `_tunnelsString` getter

### PTY Tab (`pty_tab.dart`)
- Persistent full-screen xterm shell in the bottom nav; survives tab switches via `AutomaticKeepAliveClientMixin`
- `_startSession()` uses both `_isRunning` AND `_starting` (set synchronously before the first `await`) to prevent concurrent calls during the multi-rebuild connect cycle
- Auto-starts when `state.isConnected && !_isRunning && !_exited` in `build()` via `addPostFrameCallback`
- `runCommand(String cmd)` — public method (called via GlobalKey or directly) to send a command to the running session
- **Command suggestions**: `_trackInput(data)` intercepts `_terminal.onOutput` to maintain `_inputBuffer` (handles printable chars, backspace, Enter/Ctrl-C/Escape). After 300ms debounce, `_fetchSuggestions(prefix)` runs `grep -F '<prefix>' ~/.bash_history` via `executeCommandFast` (separate SSH channel, not the PTY). Results shown in `_SuggestionBar` — a 36px horizontal chip row between the terminal and `SpecialKeysBar`. Tapping a chip calls `_applySuggestion`: sends backspaces to clear the current input, then types the full command.

### Interactive Shell Page (`interactive_shell_page.dart`)
- Full-screen xterm PTY pushed onto the navigator stack from Shell tab when an interactive command is detected
- Each invocation creates its own SSH shell session — completely isolated from the persistent PTY tab
- No input box or history controls — interaction is entirely via the xterm terminal + `SpecialKeysBar`
- Title shows `command [exited]` when the session ends
- `_sendKey(String)` + `_sendModified(...)` translate `SpecialKeysBar` key names to raw byte sequences

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
Today's date is 2026-03-21.

# xcode-hackatime

WakaTime time tracking for Xcode - with accurate `lineno`, `cursorpos`, file
path, and write detection in every heartbeat.

Works with wakatime.com, [Hackatime](https://hackatime.hackclub.com), or any
WakaTime-compatible backend (whatever `~/.wakatime.cfg` points at).

## How it works

Xcode has no plugin API suitable for time tracking: XcodeKit Source Editor
Extensions only run when the user explicitly invokes a menu command, and
runtime injection into Xcode is blocked by the Hardened Runtime
(`library-validation`) without disabling SIP or re-signing Xcode.

So this is a small background agent that observes Xcode from the outside
through the **macOS Accessibility API** - public, stable, SIP-friendly, and
requiring only a one-time Accessibility permission grant:

```
                Xcode
                  │  AX notifications
                  ▼
         xcode-hackatime agent
         ├─ AXFocusedUIElementChanged → which editor is active
         ├─ window AXDocument         → full file path
         ├─ AXSelectedTextRange       → cursor offset
         ├─ AXStringForRange prefix   → physical line number
         └─ file mtime on disk        → is_write (real saves)
                  │  snapshot on heartbeat policy
                  ▼
         ~/.wakatime/wakatime-cli → dashboard
```

AX events are the *sensor*, not the scheduler: caret movement updates
in-memory state, and a heartbeat is sent only when the file changes, a write
lands on disk, or 2 minutes have passed for the same file - the same
deduplication rule official WakaTime plugins use.

### Accuracy notes

- **`lineno`** counts physical newlines in the text before the caret
  (fetched via the parameterized `AXStringForRange` attribute, so the cost is
  proportional to the caret position, never the file size). `AXLineForIndex`
  is deliberately *not* used because it counts soft-wrapped display lines.
- **`cursorpos`** is the 1-based absolute character offset of the insertion
  point.
- **`is_write`** is ground truth: the file's modification time on disk
  advanced since the last check (catches ⌘S and Xcode autosave).
- **file path** comes from the focused window's `AXDocument` attribute - the
  actual open document, not the Project navigator selection (which can point
  at a different file than the focused editor).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/hackclub/xcode-hackatime/main/install.sh | bash
```

`install` downloads `wakatime-cli` automatically if missing and warns if
`~/.wakatime.cfg` has no `api_key` (Hackatime's setup at
https://hackatime.hackclub.com writes it for you).

Building from source instead:

```sh
swift build -c release
.build/release/xcode-hackatime install
```

Then grant permission once: **System Settings → Privacy & Security →
Accessibility → enable `xcode-hackatime`**. Tracking starts immediately; the
agent auto-starts at login and reattaches whenever Xcode launches or quits.

## Commands

| Command | Description |
|---|---|
| `install` | Copy binary to `~/.wakatime`, register launchd agent, start |
| `uninstall` | Stop and remove the agent |
| `status` | launchd state + recent log lines |
| `probe` | Dump Xcode's Accessibility state (diagnostics) |
| `run` | Run in the foreground (what launchd invokes) |

Logs: `~/.wakatime/xcode-hackatime.log`

**Signing (important)**: sign the binary with a real identity before
installing, so the Accessibility grant survives updates:

```sh
codesign -f -s "Apple Development" \
  --identifier com.hackclub.hackatime.xcode-hackatime \
  .build/release/xcode-hackatime
```

For distributable releases use `scripts/release.sh`, which builds a universal
binary, signs it with the Developer ID Application certificate (hardened
runtime + timestamp), and notarizes it via `notarytool`.

An ad-hoc (unsigned) binary works, but its TCC identity is its build hash -
every rebuild silently invalidates the Accessibility grant, and worse, the
System Settings entry goes *stale*: the toggle shows enabled while trust is
actually gone. If that happens, remove the entry with the `−` button and
re-add it (the agent re-prompts within ~30 s). With a certificate-signed
binary, the grant is keyed to your signing identity and survives rebuilds.

## Why not…

- **XcodeKit extension** - command-invocation only; no callbacks for cursor
  movement, edits, or file switches. Kept out of the critical path entirely.
- **dylib injection / private APIs in-process** - Xcode 26 ships with
  `library-validation` and no `get-task-allow`, so injection requires
  disabling SIP or re-signing Xcode. Both rejected as install requirements.
- **task_for_pid memory reading** - blocked by SIP for protected processes.

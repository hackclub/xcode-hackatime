# xcode-hackatime

WakaTime time tracking for Xcode - with accurate `lineno`, `cursorpos`, file
path, and write detection in every heartbeat.

Works with wakatime.com, [Hackatime](https://hackatime.hackclub.com), or any
WakaTime-compatible backend (whatever `~/.wakatime.cfg` points at).

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

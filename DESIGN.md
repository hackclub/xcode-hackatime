# Design

xcode-hackatime is a launchd agent that watches Xcode through the macOS
Accessibility (AX) API and reports coding activity to Hackatime/WakaTime by
shelling out to wakatime-cli. Zero dependencies: the platform provides the
sensor (AX), the scheduler (launchd), the logger (unified logging), and the
config parser (wakatime-cli itself).

## Architecture

| Unit | Role |
|---|---|
| `XcodeObserver` | **Sensor.** Attaches an AXObserver to the running Xcode, tracks the focused source editor, and reports coalesced activity snapshots. Never decides when to send. |
| `WriteClassifier` | **Pure policy.** Is a disk mtime change the user's save or an external change? The full truth table is its doc comment. |
| `HeartbeatEngine` | **Policy + effect.** Decides when activity becomes a heartbeat (file change / write / 30s staleness), computes line deltas, forks wakatime-cli. `process()` reads as five numbered phases: classify -> decide -> pace -> measure -> send-and-commit. |
| `Installer` | launchd registration, wakatime-cli download, config check, log and permission hygiene. |
| `Notifier` | The notification helper: delivery, Notification Center approval, on-device icon rendering. |
| `Onboarding` | A separate process showing the Accessibility walkthrough window (separate so it survives the agent's exit/relaunch cycle without flicker). |
| `OnboardingUI` / `KeySetup` | Shared window kit for the onboarding-style windows plus the API-key setup window. |
| `Doctor` | `doctor` checks every link in the tracking chain (agent, trust, CLI, API auth, Xcode, heartbeats, tracker conflicts) and prints a fix per failure. Reads the agent's trust from its unified-log trail, because a terminal-spawned check-trust is TCC-attributed to the terminal. |
| `Probe` | Diagnostic dump of Xcode's AX tree, for bug reports. |

Everything runs on the main run loop. The only off-main work is the
fresh-process trust check while trusted (notification-triggered, spawned
from a utility queue so a slow child cannot stall AX event delivery) and
the CLI termination handler; both hop back to main before touching
anything. Main-thread confinement is by convention; Swift 6 strict
concurrency annotation is deferred as a broad pass for another day.

## Sensing

The AX API has no save event and no "user did this" bit, so everything is
inferred.

**The file path** comes from the window's `AXDocument`, which follows the
*focused* editor pane. Live-verified across three split panes and across
multiple windows: the document and heartbeat attribution flip with focus in
every direction, and a loose-file window past the prefix cap sends writes
without line/column instead of stalling Xcode.

**Line and column** come from fetching the text before the caret
(`AXStringForRange`) and counting newlines. `AXLineForIndex` would be one
cheap call, but it counts soft-wrapped display lines, so it reports wrong
physical lines under Xcode's default wrap setting. The fetch is lazy,
resolved only when a heartbeat actually sends; cheap AX reads run
per-event.

**Writes** come from mtime advances over a per-file committed baseline.
**Attribution** comes from timing bands (`WriteClassifier`): a save rides
the user's editing in that file, or is fresh on a live event; everything
else is external and swallowed.

**User presence** is the attached Xcode frontmost AND a HID input event
within the last 10s (`CGEventSource`); editor events failing that test are
demoted to the quiet-tick path (Xcode reloading a buffer is not the user).

**Code review (comparison) mode fails safe.** On entry, keyboard focus
moves to a non-editor element (`Xcode.WorkspaceWindow`), so the sensor goes
quiet instead of misattributing; `AXDocument` stays correct throughout.
Tracking resumes when focus returns to a source editor. The worst case is
undercounting seconds spent in a diff-reading mode, never overcounting.

**Accepted limit:** an external write landing while the user is actively
editing that same file inside the attribution windows is credited to them.
That is inherent to mtime sensing; every narrower rule we tried lost real
saves.

**One Xcode instance is tracked.** Xcode and Xcode-beta share a bundle ID;
with both running, whichever is found first wins until it exits.

## Heartbeat policy

A heartbeat sends when the file changed, a write landed, or 30s passed
since the last heartbeat for the same file. Official plugins use 120s;
denser position samples add zero tracked time between the same endpoints
(the server bridges consecutive heartbeats into one duration), so the
divergence costs nothing.

**Success = wakatime-cli launched, not exited 0.** The CLI owns offline
queuing and retries; re-sending from the plugin on a nonzero exit would
double-count whenever the CLI queued before failing. Nonzero exits are
logged.

**Transactional commits.** Baselines advance only when a heartbeat actually
launches, so failed sends retry themselves with no separate retry state. An
unsent user write is pinned (`FileBaseline.unsentWrite`) so retries after
launch failures cannot drift it out of the attribution band into
"external" while the user keeps editing.

**Pacing.** Never more than one wakatime-cli fork per second; rejected
sends coalesce into `pendingSendFiles` and drain one per event/tick. A
save-all batch spreading over a few 20s ticks is accepted pacing.

**Line deltas.** Each heartbeat carries the human line delta since the last
committed baseline. A jump past 50 lines in either direction in one save is
a paste, generation, or bulk delete, not typing: the delta is dropped, the
write still counts. (Symmetric, unlike vscode-wakatime's positive-only
guard; a live -99 external cleanup proved the need.)

**Clocks.** Wall-clock `Date` everywhere, with explicit
backward-correction repair (`repairedNow`), instead of a monotonic clock:
it keeps the injectable test clock and the mtime comparisons in one time
domain.

## Timing dials

| Dial | Value | Lives in | Why |
|---|---|---|---|
| CLI fork cap | 1s | HeartbeatEngine.minSpacing | Never more than one wakatime-cli per second. |
| Same-file heartbeat | 30s | HeartbeatEngine.heartbeatInterval | See heartbeat policy above. |
| Sweep window | 2 x saveSlack | HeartbeatEngine.sweepWindow | Quiet ticks re-check files the user touched recently, catching autosaves that land after focus moved away. |
| Baseline cap | 512 files | HeartbeatEngine.maxTrackedFiles | Session-lifetime maps reset rather than grow unbounded. |
| Line-count cap | 10 MB | HeartbeatEngine.maxLineCountBytes | Synchronous read on the main run loop; the delta is optional metadata. |
| Save slack | 60s | WriteClassifier.saveSlack | cmd-S/autosave lands within this of the user's editing in the file. |
| Write recency | 10s | WriteClassifier.recentWriteWindow | Return-from-break cmd-S: fresh mtime on a live event. |
| State refresh throttle | 1s | XcodeObserver.expensiveRefreshInterval | AX reads block Xcode's main thread, and Xcode fires several notifications per keystroke; the throttle runs before any read. |
| Re-sync / quiet tick | 20s | XcodeObserver timer | Attach recovery, stale-pid reconcile, state refresh, disk-write poll. |
| HID recency | 10s | XcodeObserver.inputRecencyWindow | Real typing produces an AX event within milliseconds of a keystroke. |
| Prefix cap | 256K UTF-16 units | XcodeObserver.maxPrefixLength | The AX prefix fetch stalls Xcode's main thread in proportion to caret offset (~30ms measured at 2.4M units); the cap keeps the worst stall under one 60Hz frame. Line/column is optional metadata. |
| Paste guard | delta > 50 lines, either sign | HeartbeatEngine (phase 4) | See heartbeat policy above. |
| Trust probe fallback | 10s waiting / 300s trusted | main.swift timers | Trust checks are event-driven (see Permissions); the timers only cover missed notifications. |

A transient AX path failure consumes the 1s refresh throttle: deliberate
backpressure on a struggling AX server.

## Permissions (TCC)

Accessibility trust is cached per-process by the AX framework, so a
long-lived agent can never observe its own grant or revocation. Hence:

- Fresh-process `check-trust` children are the ground-truth read.
- Checks are triggered by the `com.apple.accessibility.api` distributed
  notification (undocumented, payload-free; it only ever *triggers* the
  supported check, so a bogus or missed notification degrades to the
  fallback timers, never to a wrong answer).
- Any change exits the agent so launchd relaunches it with fresh state.
- The system prompt shows once per install (`.ax-prompted`). Install clears
  the marker because replacing an ad-hoc binary invalidates the grant.
- The onboarding window lives in its own process so it survives the
  relaunch cycle.

Reading the TCC SQLite database directly was considered and rejected: the
Accessibility rows live in the SIP-protected system `TCC.db`, reading it
requires Full Disk Access (a far heavier grant than the one being
detected), and the schema is private and shifts across macOS releases.

## Onboarding

Windows are invitations, never gates. Every window (Accessibility
walkthrough, API-key setup) is closable, closing one is respected without
respawn nagging, and tracking proceeds independently of any window's fate.

Completions get a visible win-state (a short success flip in the window
plus a one-time banner on the waiting-to-trusted transition) because
silence reads as "did it work?". Install validates the whole auth path with
`wakatime-cli --today` while the user is still at the terminal, spawns the
walkthrough even with Xcode closed (install is an explicit action, a window
is expected), and marks reinstalls so the walkthrough shows off-then-on
toggle steps for the stale Accessibility row.

## Notifications

Banners go only through the `Hackatime.app` helper bundle that install
assembles around our own binary (Info.plist, on-device-rendered icon,
ad-hoc bundle signature). A missing helper means no banner, never a
fallback under another app's identity.

Delivery uses the deprecated `NSUserNotification` deliberately:
`UNUserNotificationCenter` silently auto-denies authorization outside a
full app lifecycle (verified live against ad-hoc signing, a real developer
certificate, a pumped run loop, and a LaunchServices launch), while the
deprecated API has delivered from bundled CLI helpers for a decade.

macOS registers an NSUserNotification source suppressed-pending, and no
approval prompt ever comes, so install approves delivery itself: clear the
pending bit and set auth in `com.apple.ncprefs`, bounce usernoted,
re-deliver the install banner. Only install does this; a user's later off
toggle in System Settings is never overridden.

The helper also gives users the sanctioned Focus path: a real "Hackatime"
entry they can style as Alerts and allow through Focus modes. True Focus
bypass (critical alerts) is Apple-gated and wrong for a time tracker
anyway.

## Coexistence with WakaTime.app

WakaTime.app (macos-wakatime) tracks Xcode through the same AX API, and
both trackers share `~/.wakatime.cfg` and the CLI, so dual Xcode tracking
is never a deliberate setup, always double-counting. Its Xcode tracking is
auto-disabled, persistently: remove `com.apple.dt.Xcode` from
`wakatime_monitored_apps` in the `macos-wakatime.WakaTime` defaults domain
and bounce the app in the background.

Install does it, agent startup does it, and a preferences file watcher owns
it from then on: it re-checks the moment the plist changes AND on every
(re)attach, which covers cfprefsd's atomic replaces and the reattach gap
without any polling fallback. Each disable is logged, and the agent posts a
banner rate-limited to one per 10 minutes per message, so the preference
rewrite is never silent.

## Logging

The unified log is the only record of normal output (os.Logger, subsystem =
the launchd label): rotation, retention, and access control handled by the
OS; `status` prints its tail. The file at logPath only captures **stderr**
(crash traces, which the unified log cannot see); launchd has no
StandardOutPath. Log-then-exit sites use `logAndExit`, which gives logd a
300ms grace so an instant exit does not lose the final entry. The file is
0600 and trimmed past 1 MB at agent start, which also bounds crash loops
(every relaunch trims).

## Supply chain

The downloaded wakatime-cli must pass code-signature verification
(`codesign --verify --strict` plus a pinned WakaTime TeamIdentifier,
`538RQNWSWT`) before it is made executable: the release URL is mutable
(`releases/latest`), so a compromised asset fails closed. The team pin
survives releases; a digest pin would not. install.sh applies the same
anchored check to our own release asset before executing it.

## Testing

Test injection points exist for the engine only (clock, CLI launch);
throttling,
staleness, and write recency are untestable against the wall clock.
launchctl, AX, installer, and notification paths are integration-verified
by exercising the binary against a live Xcode.

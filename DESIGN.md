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
| `HeartbeatEngine` | **Policy + effect.** Decides when activity becomes a heartbeat (file change / write / 2-minute staleness), computes line deltas, forks wakatime-cli. `process()` reads as five numbered phases: classify → decide → pace → measure → send-and-commit. |
| `Installer` | launchd registration, wakatime-cli download, config check, log and permission hygiene. |
| `Onboarding` | A separate process showing the Accessibility walkthrough window (separate so it survives the agent's exit/relaunch cycle without flicker). |
| `Probe` | Diagnostic dump of Xcode's AX tree, for bug reports. |

Everything runs on the main run loop. The only off-main work is the 30s
trust probe (notification-triggered, with a 60s fallback while trusted) and
the CLI termination handler, both of which hop back to main
before touching anything.

## The sensing model and its limits

The AX API has no save event and no "user did this" bit, so everything is
inferred:

- **Writes** come from mtime advances over a per-file committed baseline.
- **Attribution** comes from timing bands (`WriteClassifier`): a save rides
  the user's editing in that file, or is fresh on a live event; everything
  else is external and swallowed.
- **User presence** = the attached Xcode is frontmost AND a HID input event
  occurred within the last 10s (`CGEventSource`); editor events failing that
  test are demoted to the quiet-tick path (Xcode reloading a buffer is not
  the user).
- **Transactional commits**: baselines only advance when a heartbeat
  actually launches, so failed sends retry themselves with no separate
  retry state.

**Accepted limit:** an external write landing while the user is actively
editing that same file inside the attribution windows is credited to them.
That is inherent to mtime sensing; every narrower rule we tried lost real
saves.

## Timing dials

| Dial | Value | Lives in | Why |
|---|---|---|---|
| CLI fork cap | 1s | HeartbeatEngine.minSpacing | Never more than one wakatime-cli per second; rejected sends coalesce into `pendingSendFiles`, draining one per event/tick. |
| Same-file heartbeat | 120s | HeartbeatEngine.heartbeatInterval | The standard WakaTime plugin rule. |
| Sweep window | 2 × saveSlack | HeartbeatEngine.sweepWindow | Quiet ticks re-check files the user touched recently, catching autosaves that land after focus moved away. |
| Baseline cap | 512 files | HeartbeatEngine.maxTrackedFiles | Session-lifetime maps reset rather than grow unbounded. |
| Line-count cap | 10 MB | HeartbeatEngine.maxLineCountBytes | Synchronous read on the main run loop; the delta is optional metadata. |
| Save slack | 60s | WriteClassifier.saveSlack | ⌘S/autosave lands within this of the user's editing in the file. |
| Write recency | 10s | WriteClassifier.recentWriteWindow | Return-from-break ⌘S: fresh mtime on a live event. |
| State refresh throttle | 1s | XcodeObserver.expensiveRefreshInterval | AX reads block Xcode's main thread; heartbeats are throttled harder anyway. |
| Re-sync / quiet tick | 20s | XcodeObserver timer | Attach recovery, stale-pid reconcile, state refresh, disk-write poll. |
| HID recency | 10s | XcodeObserver.inputRecencyWindow | Real typing produces an AX event within milliseconds of a keystroke. |
| Prefix cap | 1M UTF-16 units | XcodeObserver.maxPrefixLength | Line/column is optional metadata; a multi-megabyte AX prefix fetch stalls Xcode's main thread. |
| Paste guard | \|delta\| > 50 lines | HeartbeatEngine (phase 4) | a >50-line jump in either direction in one save is a paste, generation or bulk delete, not typing - the delta is dropped, the write still counts. (Symmetric, unlike vscode-wakatime's positive-only guard; a live -99 external cleanup proved the need.) |
| Trust probe fallback | 10s waiting / 60s trusted | main.swift timers | Fresh-process TCC reads are primarily *event-driven* (the `com.apple.accessibility.api` distributed notification fires on any Accessibility-list change); the timers only cover missed notifications. |

## Accepted decisions

1. **Heartbeat "success" = wakatime-cli launched, not exited 0.** The CLI
   owns offline queuing and retries; re-sending from the plugin on a nonzero
   exit would double-count whenever the CLI queued before failing. Nonzero
   exits are logged.
2. **One Xcode instance is tracked.** Xcode and Xcode-beta share a bundle
   ID; with both running, whichever is found first wins until it exits.
3. **Swift 6 strict concurrency is deferred.** Main-thread confinement is by
   convention; annotating is a broad pass for another day.
4. **Test seams exist for the engine only** (clock, CLI launch). launchctl,
   AX, and installer paths are integration-verified by exercising the binary.
5. **Cheap AX reads run per-event; the document-prefix line fetch is lazy**,
   resolved only when a heartbeat actually sends.
6. The mtime-attribution limit described above.
7. The user-presence rule described above.
8. **A transient AX path failure consumes the 1s refresh throttle** —
   deliberate backpressure on a struggling AX server.
9. **Wall-clock `Date` everywhere, with explicit backward-correction
   repair** (`repairedNow`), instead of a monotonic clock — it keeps the
   test clock seam and the mtime comparisons in one time domain.
10. **Logging is dual on purpose.** The unified log (os.Logger, subsystem =
    the launchd label) is the system of record — rotation, retention, and
    access control handled by the OS. The launchd-captured file stays
    because logd buffers can lose entries written immediately before
    `exit(0)` (which this agent does by design), and the plain file is what
    users attach to bug reports. It is 0600, trimmed at 1 MB.
11. **Deferred sends drain one per event/tick** under the fork cap; a
    save-all batch spreading over a few 20s ticks is accepted pacing.
12. **The downloaded wakatime-cli must pass code-signature verification**
    (`codesign --verify --strict` plus a pinned WakaTime TeamIdentifier,
    `538RQNWSWT`) before it is made executable — the release URL is mutable
    (`releases/latest`), so a compromised asset fails closed. The team pin
    survives releases; a digest pin would not.
13. **An unsent user write is pinned** (`FileBaseline.unsentWrite`) so that
    retries after launch failures can't drift it out of the attribution
    band into "external" while the user keeps editing.
14. **Install auto-disables WakaTime.app's Xcode tracking** (removes
    `com.apple.dt.Xcode` from `wakatime_monitored_apps` in the
    `macos-wakatime.WakaTime` defaults domain and bounces the app in the
    background) because running both double-counts every heartbeat. The
    agent itself only *warns* at startup if it is re-enabled: install-time
    disable is a sensible default, runtime force-disable would fight a
    deliberate user choice.

## The TCC dance

Accessibility trust is cached per-process by the AX framework, so a
long-lived agent can never observe its own grant or revocation. Hence:
fresh-process `check-trust` children as the ground-truth read, triggered by
the `com.apple.accessibility.api` distributed notification (undocumented,
payload-free — it only ever *triggers* the supported check, so a bogus or
missed notification degrades to the fallback timers, never to a wrong
answer), exit-to-relaunch on any change, the system prompt shown once per
install (`.ax-prompted`, cleared by install because replacing an ad-hoc
binary invalidates the grant), and the onboarding window living in its own
process so it survives the relaunch cycle.

Reading the TCC SQLite database directly was considered and rejected: the
Accessibility rows live in the SIP-protected system `TCC.db`, reading it
requires Full Disk Access (a far heavier grant than the one being detected),
and the schema is private and shifts across macOS releases.

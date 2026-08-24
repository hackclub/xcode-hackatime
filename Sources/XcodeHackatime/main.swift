import AppKit
import ApplicationServices
import os

/// system of record for diagnostics: the unified log (the OS handles
/// rotation, retention and access control; stream it in Console.app or with
/// `log show --predicate 'subsystem == "com.hackclub.hackatime..."'`).
/// paths are the diagnostic payload, so entries log as .public. the store
/// is only readable on this Mac, unlike a world-readable file.
private let osLogger = Logger(subsystem: Installer.label, category: "agent")

func logLine(_ message: String) {
    osLogger.notice("\(message, privacy: .public)")
    // also print: launchd captures this to the log file (kept because logd
    // buffers; an exit(0) right after a notice can lose the unified-log
    // entry, and the plain file is what users attach to bug reports), and
    // foreground `run` shows it live.
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

/// TCC state read by a brand-new process, immune to the per-process cache.
/// nil means the check itself could not run (e.g. our binary briefly missing
/// during a reinstall, transient fork pressure). callers must not confuse
/// that with a definitive "not trusted".
func freshTrustCheck() -> Bool? {
    guard let process = Installer.spawnSelf(["check-trust"], discardOutput: true) else { return nil }
    process.waitUntilExit()
    // only a normal exit with the defined statuses is an answer. a crash or
    // a signal is a failed check, not evidence of revocation.
    guard process.terminationReason == .exit else { return nil }
    switch process.terminationStatus {
    case 0: return true
    case 1: return false
    default: return nil
    }
}

/// macOS posts this whenever the Accessibility list changes. it carries no
/// payload and is not API contract, so it only ever *triggers* the supported
/// fresh-process check. fallback timers cover missed notifications.
let axChangedNotification = Notification.Name("com.apple.accessibility.api")

func runAgent() -> Never {
    // launchd recreates the log with default umask; it records every file
    // path the user works on, so keep it private to this account.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Installer.logPath)
    Installer.trimLogIfNeeded()
    if !AXIsProcessTrusted() {
        // show the system permission prompt only once per install: it is the
        // only way to get registered in the Accessibility list at all, but we
        // exit/relaunch continuously while waiting (to read fresh TCC state),
        // and a re-prompt on every relaunch nags the user with popups. after
        // the first prompt the row exists in System Settings, and the
        // onboarding window carries the instructions.
        let promptMarker = Installer.axPromptedMarker
        if !FileManager.default.fileExists(atPath: promptMarker) {
            Installer.touchMarker(promptMarker)
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        logLine("waiting for Accessibility permission…")
        // a TCC grant does not propagate to an already-running process (the
        // AX framework caches the denial), but a *fresh* process always
        // reads fresh TCC state. so the checks below spawn ourselves as a
        // short-lived `check-trust` child, and the moment one reports
        // trusted we exit so launchd relaunches us trusted (no respawn
        // throttle once we have been alive >10s). the checks are
        // event-driven: macOS posts axChangedNotification whenever the
        // Accessibility list changes, so we notice the grant
        // near-instantly; a slow timer covers missed notifications. while
        // waiting, if Xcode is open, show the onboarding window (a separate
        // process, so it survives our relaunch cycle without flicker).
        let checkTrustAndMaybeRelaunch = {
            if freshTrustCheck() == true {
                logLine("permission granted; relaunching to pick it up")
                exit(0)
            }
        }
        let tick = {
            checkTrustAndMaybeRelaunch()
            if XcodeObserver.runningXcode() != nil { Onboarding.spawnIfNeeded() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: axChangedNotification, object: nil, queue: .main
        ) { _ in checkTrustAndMaybeRelaunch() }
        XcodeObserver.onXcodeNotification(NSWorkspace.didLaunchApplicationNotification) { _ in
            Onboarding.spawnIfNeeded()
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in tick() }
        tick()
        // exit periodically regardless, so launchd relaunches us with a
        // clean slate.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
            logLine("still not trusted; exiting so launchd can relaunch with fresh TCC state")
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }
    logLine("Accessibility permission OK")
    // tells any onboarding window that tracking has started, so it dismisses.
    Installer.touchMarker(Onboarding.trustedMarker)
    // a past "user closed the onboarding window" no longer applies once
    // trusted; clear it so onboarding returns if permission is ever revoked.
    try? FileManager.default.removeItem(atPath: Onboarding.dismissedMarker)

    // detection only at runtime: install auto-disables, but if the user
    // re-enabled it deliberately, warn instead of fighting them.
    if Installer.competingXcodeTrackerEnabled() {
        logLine(
            "warning: WakaTime.app is also tracking Xcode - every heartbeat double-counts. run 'xcode-hackatime install' to disable it, or turn Xcode off in WakaTime.app's monitored apps"
        )
    }

    let engine = HeartbeatEngine(log: logLine)
    if !engine.cliExists {
        logLine(
            "warning: ~/.wakatime/wakatime-cli not found - heartbeats will fail. Install any WakaTime plugin once, or download wakatime-cli from https://github.com/wakatime/wakatime-cli/releases"
        )
    }

    let observer = XcodeObserver(log: logLine)
    observer.onActivity = { state, resolvePosition in
        engine.consider(state, resolvePosition: resolvePosition)
    }
    observer.onWritePoll = { state, resolvePosition in
        engine.pollDiskWrites(state, resolvePosition: resolvePosition)
    }
    // full metadata resolution chain lives here, not in the engine: the
    // attached instance, then any running Xcode, then Launch Services'
    // default (covers Xcode-beta.app and relocated installs).
    engine.attachedXcodeBundleURL = {
        observer.attachedXcodeBundleURL
            ?? XcodeObserver.runningXcode()?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: XcodeObserver.xcodeBundleID)
    }
    observer.startWatchingWorkspace()

    // notice revocation: our own AX state is cached, so ask a fresh process.
    // event-driven via axChangedNotification with a slow fallback timer.
    // this runs off the main queue; waitUntilExit would otherwise stall AX
    // event delivery for the child's whole lifetime on every check. only a
    // definitive "not trusted" restarts; we retry a failed check (nil).
    let revocationCheck = {
        DispatchQueue.global(qos: .utility).async {
            guard freshTrustCheck() == false else { return }
            DispatchQueue.main.async {
                logLine("Accessibility permission revoked; restarting into onboarding")
                exit(0)
            }
        }
    }
    DistributedNotificationCenter.default().addObserver(
        forName: axChangedNotification, object: nil, queue: .main
    ) { _ in revocationCheck() }
    Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
        // a trusted agent lives for the whole login session; startup-only
        // trimming would let the log grow without bound.
        Installer.trimLogIfNeeded()
        revocationCheck()
    }

    logLine("xcode-hackatime \(appVersion) running")
    // nothing else holds engine/observer strongly (the AX callback refcon is
    // deliberately unretained, timers capture weak), and ARC frees locals at
    // last use, not scope end. without this, an optimized build may dealloc
    // both right here and leave the AX callback with a dangling refcon.
    withExtendedLifetime((engine, observer)) {
        RunLoop.main.run()
    }
    exit(0)
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "help"
switch command {
case "run":
    runAgent()
case "check-trust":
    exit(AXIsProcessTrusted() ? 0 : 1)
case "onboard":
    exit(Onboarding.run())
case "probe":
    exit(Probe.run())
case "install":
    exit(Installer.install())
case "uninstall":
    exit(Installer.uninstall())
case "status":
    exit(Installer.status())
case "version", "--version":
    print(appVersion)
    exit(0)
default:
    print(
        """
        xcode-hackatime \(appVersion) - WakaTime for Xcode, via the Accessibility API

        usage: xcode-hackatime <command>

          install     copy to ~/.wakatime, register launchd agent, start tracking
          uninstall   stop and remove the launchd agent
          status      show agent state and recent log lines
          run         run the tracker in the foreground (used by launchd)
          probe       dump Xcode's Accessibility tree state (diagnostics)
          version     print the version
        """)
    exit(command == "help" ? 0 : 64)
}

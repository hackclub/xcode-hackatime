import AppKit
import ApplicationServices
import os

// unified log entries are .public: paths are the diagnostic payload, and the
// store is only readable on this Mac, unlike a world-readable file
private let osLogger = Logger(subsystem: Installer.label, category: "agent")

private let stampFormatter = ISO8601DateFormatter()

func logLine(_ message: String) {
    // "warning:" prefixed messages go to the error level so log-show
    // predicates can filter them from routine chatter
    if message.hasPrefix("warning:") {
        osLogger.error("\(message, privacy: .public)")
    } else {
        osLogger.notice("\(message, privacy: .public)")
    }
    // launchd discards stdout; this print only serves foreground runs
    print("[\(stampFormatter.string(from: Date()))] \(message)")
    fflush(stdout)
}

// logd buffers asynchronously; an instant exit can lose the final entry
func logAndExit(_ message: String) -> Never {
    logLine(message)
    Thread.sleep(forTimeInterval: 0.3)
    exit(0)
}

/// TCC state read by a brand-new process, immune to the per-process cache;
/// nil means the check itself could not run, not "not trusted"
func freshTrustCheck() -> Bool? {
    guard let process = Installer.spawnSelf(["check-trust"], discardOutput: true) else { return nil }
    process.waitUntilExit()
    // a crash or a signal is a failed check, not evidence of revocation
    guard process.terminationReason == .exit else { return nil }
    switch process.terminationStatus {
    case 0: return true
    case 1: return false
    default: return nil
    }
}

/// posted by macOS on any Accessibility list change. undocumented and
/// payload-free, so it only ever triggers the supported fresh-process check;
/// fallback timers cover missed notifications
let axChangedNotification = Notification.Name("com.apple.accessibility.api")

func runAgent() -> Never {
    // launchd recreates the log with default umask; it records every file
    // path the user works on
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Installer.logPath)
    Installer.trimLogIfNeeded()
    if !AXIsProcessTrusted() {
        // prompt once per install: the untrusted agent exits and relaunches
        // continuously to read fresh TCC state, and re-prompting every
        // relaunch nags with popups. after the first prompt the row exists
        // in System Settings and the onboarding window carries instructions
        let promptMarker = Installer.axPromptedMarker
        if !FileManager.default.fileExists(atPath: promptMarker) {
            Installer.touchMarker(promptMarker)
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        logLine("waiting for Accessibility permission...")
        // a trusted start that finds this marker posts the one-time
        // "tracking started" banner
        Installer.touchMarker(Onboarding.grantPendingMarker)
        // a TCC grant never propagates to a running process (the AX
        // framework caches the denial), but a fresh process reads fresh
        // state; exit on the first trusted report so launchd relaunches us
        // trusted
        let checkTrustAndMaybeRelaunch = {
            if freshTrustCheck() == true {
                logAndExit("permission granted; relaunching to pick it up")
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
        Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
            logAndExit("still not trusted; exiting so launchd can relaunch with fresh TCC state")
        }
        RunLoop.main.run()
        exit(0)
    }
    logLine("Accessibility permission OK")
    if Installer.consumeMarker(Onboarding.grantPendingMarker) {
        Installer.postBanner("You're all set - Xcode time counts from now.")
    }
    Installer.consumeMarker(Onboarding.regrantMarker)
    // tells any onboarding window that tracking has started, so it dismisses
    Installer.touchMarker(Onboarding.trustedMarker)
    // a past window dismissal no longer applies once trusted; clear it so
    // onboarding returns if permission is ever revoked
    try? FileManager.default.removeItem(atPath: Onboarding.dismissedMarker)

    // no eager disable call: the watcher fires once at attach
    Installer.startCompetingTrackerWatcher(report: logLine)

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
    // attached instance, then any running Xcode, then Launch Services'
    // default (covers Xcode-beta.app and relocated installs)
    engine.attachedXcodeBundleURL = {
        observer.attachedXcodeBundleURL
            ?? XcodeObserver.runningXcode()?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: XcodeObserver.xcodeBundleID)
    }
    observer.startWatchingWorkspace()

    // revocation is invisible to our own cached AX state, so ask a fresh
    // process. off the main queue: waitUntilExit would stall AX event
    // delivery for the child's whole lifetime. only a definitive "not
    // trusted" restarts; a failed check (nil) is retried
    let revocationCheck = {
        DispatchQueue.global(qos: .utility).async {
            guard freshTrustCheck() == false else { return }
            DispatchQueue.main.async {
                logAndExit("Accessibility permission revoked; restarting into onboarding")
            }
        }
    }
    DistributedNotificationCenter.default().addObserver(
        forName: axChangedNotification, object: nil, queue: .main
    ) { _ in revocationCheck() }
    // fallback for a missed axChangedNotification; five-minute worst-case
    // detection is acceptable
    Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
        revocationCheck()
    }

    logLine("xcode-hackatime \(appVersion) running")
    // nothing else holds engine/observer strongly (the AX callback refcon is
    // deliberately unretained, timers capture weak) and ARC frees locals at
    // last use, so an optimized build may dealloc both right here and leave
    // the AX callback with a dangling refcon
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
case "notify":
    Notifier.run(message: CommandLine.arguments.dropFirst(2).joined(separator: " "))
case "doctor":
    exit(Doctor.run())
case "setup-key":
    exit(KeySetup.run())
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
          doctor      check every link in the tracking chain, with fixes
          probe       dump Xcode's Accessibility tree state (diagnostics)
          version     print the version
        """)
    exit(command == "help" ? 0 : 64)
}

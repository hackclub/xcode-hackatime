import ApplicationServices
import AppKit

func logLine(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

/// TCC state read by a brand-new process — immune to the per-process cache.
func freshTrustCheck() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["check-trust"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

func runAgent() -> Never {
    if !AXIsProcessTrusted() {
        // Show the system permission prompt only once per install: it's the
        // only way to get registered in the Accessibility list at all, but we
        // exit/relaunch continuously while waiting (to read fresh TCC state),
        // and re-prompting on every relaunch nags the user with popups. After
        // the first prompt the row exists in System Settings, and the
        // onboarding window carries the instructions.
        let promptMarker = Installer.installDir + "/.ax-prompted"
        if !FileManager.default.fileExists(atPath: promptMarker) {
            try? FileManager.default.createDirectory(atPath: Installer.installDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: promptMarker, contents: Data())
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        logLine("waiting for Accessibility permission…")
        // A TCC grant does not propagate to an already-running process (the
        // AX framework caches the denial), but a *fresh* process always reads
        // fresh TCC state. So poll by spawning ourselves as a short-lived
        // `check-trust` child every second; the moment it reports trusted,
        // exit so launchd relaunches us trusted (no respawn throttle once
        // we've been alive >10s). While waiting, if Xcode is open, show the
        // onboarding window (a separate process, so it survives our relaunch
        // cycle without flicker).
        for _ in 0..<60 {
            Thread.sleep(forTimeInterval: 1)
            if freshTrustCheck() {
                logLine("permission granted; relaunching to pick it up")
                exit(0)
            }
            let xcodeRunning = NSWorkspace.shared.runningApplications
                .contains { $0.bundleIdentifier == XcodeObserver.xcodeBundleID }
            if xcodeRunning { Onboarding.spawnIfNeeded() }
        }
        logLine("still not trusted; exiting so launchd can relaunch with fresh TCC state")
        exit(0)
    }
    logLine("Accessibility permission OK")
    // Tells any onboarding window that tracking has started, so it dismisses.
    // (Ensure the directory exists — when running from a build directory the
    // install step may never have created it.)
    try? FileManager.default.createDirectory(atPath: Installer.installDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: Onboarding.trustedMarker, contents: Data())
    // A past "user closed the onboarding window" no longer applies once
    // trusted; clear it so onboarding returns if permission is ever revoked.
    try? FileManager.default.removeItem(atPath: Onboarding.dismissedMarker)

    let engine = HeartbeatEngine(log: logLine)
    if !engine.cliExists {
        logLine("warning: ~/.wakatime/wakatime-cli not found - heartbeats will fail. Install any WakaTime plugin once, or download wakatime-cli from https://github.com/wakatime/wakatime-cli/releases")
    }

    let observer = XcodeObserver(log: logLine)
    observer.onActivity = { state in
        engine.consider(state)
    }
    observer.startWatchingWorkspace()

    // Notice revocation: our own AX state is cached, so ask a fresh process.
    Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
        if !freshTrustCheck() {
            logLine("Accessibility permission revoked; restarting into onboarding")
            exit(0)
        }
    }

    logLine("xcode-hackatime \(appVersion) running")
    RunLoop.main.run()
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
    print("""
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

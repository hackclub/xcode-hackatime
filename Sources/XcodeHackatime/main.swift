import ApplicationServices
import AppKit

func logLine(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

func runAgent() -> Never {
    // Ask for Accessibility permission (shows the system prompt on first run).
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(options) {
        logLine("waiting for Accessibility permission…")
        // A TCC grant does not reliably propagate to an already-running
        // process, so poll briefly and then exit - launchd's KeepAlive
        // relaunches us and the fresh process sees the grant. While waiting,
        // if Xcode is open, show the onboarding window (a separate process,
        // so it survives our relaunch cycle without flicker).
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 2)
            if AXIsProcessTrusted() { break }
            let xcodeRunning = NSWorkspace.shared.runningApplications
                .contains { $0.bundleIdentifier == XcodeObserver.xcodeBundleID }
            if xcodeRunning { Onboarding.spawnIfNeeded() }
        }
        if !AXIsProcessTrusted() {
            logLine("still not trusted; exiting so launchd can relaunch with fresh TCC state")
            exit(0)
        }
    }
    logLine("Accessibility permission OK")
    // Tells any onboarding window that tracking has started, so it dismisses.
    FileManager.default.createFile(atPath: Onboarding.trustedMarker, contents: Data())

    let engine = HeartbeatEngine(log: logLine)
    if !engine.cliExists {
        logLine("warning: ~/.wakatime/wakatime-cli not found - heartbeats will fail. Install any WakaTime plugin once, or download wakatime-cli from https://github.com/wakatime/wakatime-cli/releases")
    }

    let observer = XcodeObserver(log: logLine)
    observer.onActivity = { state in
        engine.consider(state)
    }
    observer.startWatchingWorkspace()

    logLine("xcode-hackatime \(appVersion) running")
    RunLoop.main.run()
    exit(0)
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "help"
switch command {
case "run":
    runAgent()
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
    """)
    exit(command == "help" ? 0 : 64)
}

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
        // relaunches us and the fresh process sees the grant.
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 5)
            if AXIsProcessTrusted() { break }
        }
        if !AXIsProcessTrusted() {
            logLine("still not trusted; exiting so launchd can relaunch with fresh TCC state")
            exit(0)
        }
    }
    logLine("Accessibility permission OK")

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

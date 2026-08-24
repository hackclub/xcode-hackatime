import AppKit
import Foundation

/// `xcode-hackatime doctor` checks every link in the tracking chain and
/// prints a fix for each broken one. assembled from checks that already
/// exist elsewhere; made to be the first thing pasted into a support
/// thread.
enum Doctor {
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ label: String, _ detail: String, fix: String? = nil) {
            print("\(ok ? "✓" : "✗") \(label): \(detail)")
            if !ok {
                failures += 1
                if let fix { print("    fix: \(fix)") }
            }
        }

        // agent registered and running
        let (loadStatus, loadOut) = Installer.shell(
            "/bin/launchctl", ["print", "gui/\(getuid())/\(Installer.label)"])
        let agentPID = loadOut.split(separator: "\n")
            .first { $0.contains("pid = ") }?.trimmingCharacters(in: .whitespaces)
        check(
            loadStatus == 0, "agent",
            loadStatus == 0 ? "loaded (\(agentPID ?? "pid unknown"))" : "not loaded",
            fix: "run 'xcode-hackatime install'")

        // agent trust, read from its own recent unified-log lines. a
        // terminal-spawned check-trust is attributed to the terminal by TCC
        // and proves nothing about the agent.
        let (_, logOut) = Installer.shell(
            "/usr/bin/log",
            [
                "show", "--last", "2h", "--style", "compact",
                "--predicate", "subsystem == \"\(Installer.label)\"",
            ])
        let logLines = logOut.split(separator: "\n")
        let lastWaiting = logLines.lastIndex { $0.contains("waiting for Accessibility") }
        let lastGranted = logLines.lastIndex { $0.contains("Accessibility permission OK") }
        let trusted: Bool
        let trustDetail: String
        switch (lastWaiting, lastGranted) {
        case let (waiting?, granted?):
            trusted = granted > waiting
            trustDetail = trusted ? "granted" : "the agent is waiting for the toggle"
        case (nil, .some):
            trusted = true
            trustDetail = "granted"
        case (.some, nil):
            trusted = false
            trustDetail = "the agent is waiting for the toggle"
        case (nil, nil):
            trusted = false
            trustDetail = "no agent log activity in the last 2h"
        }
        check(
            trusted, "accessibility", trustDetail,
            fix: "System Settings → Privacy & Security → Accessibility → toggle xcode-hackatime off, then on")

        // wakatime-cli present
        let cliOK = FileManager.default.isExecutableFile(atPath: Installer.wakatimeCLIPath)
        check(
            cliOK, "wakatime-cli", cliOK ? Installer.wakatimeCLIPath : "missing",
            fix: "re-run 'xcode-hackatime install' to download and verify it")

        // api key and network, proven end to end by the CLI itself
        if cliOK {
            let (todayStatus, todayOut) = Installer.shell(Installer.wakatimeCLIPath, ["--today"])
            let today = todayOut.trimmingCharacters(in: .whitespacesAndNewlines)
            check(
                todayStatus == 0, "api",
                todayStatus == 0
                    ? "connected (\(today) tracked today)"
                    : "wakatime-cli --today failed (exit \(todayStatus))",
                fix:
                    "check api_key in ~/.wakatime.cfg - https://hackatime.hackclub.com/my/wakatime_setup writes it for you"
            )
        }

        // xcode
        let xcode = XcodeObserver.runningXcode()
        check(
            xcode != nil, "Xcode",
            xcode.map { "running (pid \($0.processIdentifier))" } ?? "not running",
            fix: "open Xcode; the agent attaches automatically")

        // recent heartbeats (only expected while Xcode is running)
        let lastBeat = logLines.last { $0.contains("heartbeat:") }
        let beatDetail = lastBeat.flatMap { line -> String? in
            guard let start = line.range(of: "heartbeat:")?.upperBound else { return nil }
            return "last:" + line[start...]
        }
        check(
            lastBeat != nil || xcode == nil, "heartbeats",
            beatDetail ?? "none in the last 2h",
            fix: "type in an Xcode source editor, then re-run doctor")

        // competing tracker
        let competing = Installer.competingXcodeTrackerEnabled()
        check(
            !competing, "WakaTime.app",
            competing ? "also tracking Xcode (every heartbeat double-counts)" : "no conflict",
            fix: "run 'xcode-hackatime install' to auto-disable it")

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) problem\(failures == 1 ? "" : "s") found")
        return failures == 0 ? 0 : 1
    }
}

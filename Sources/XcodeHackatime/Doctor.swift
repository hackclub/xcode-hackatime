import AppKit
import Foundation

/// `xcode-hackatime doctor` checks every link in the tracking chain and
/// prints a fix for each broken one; made to be pasted into a support thread
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

        let job = Installer.launchdJob()
        check(
            job.loaded, "agent",
            job.loaded ? "loaded (\(job.field("pid = ") ?? "pid unknown"))" : "not loaded",
            fix: "run 'xcode-hackatime install'")

        // trust is read from the agent's own log lines: a terminal-spawned
        // check-trust is TCC-attributed to the terminal and proves nothing
        // about the agent
        let logLines = Installer.unifiedLogLines(last: "2h")
        let lastWaiting = logLines.lastIndex { $0.contains("waiting for Accessibility") }
        let lastGranted = logLines.lastIndex { $0.contains("Accessibility permission OK") }
        let trusted: Bool
        let trustDetail: String
        if lastGranted != nil || lastWaiting != nil {
            trusted = (lastGranted ?? -1) > (lastWaiting ?? -1)
            trustDetail = trusted ? "granted" : "the agent is waiting for the toggle"
        } else {
            // a healthy agent can be silent for hours; fall back to the
            // grant-cycle markers (grant-pending is touched while waiting
            // and consumed on every trusted start)
            let waitingNow = FileManager.default.fileExists(atPath: Onboarding.grantPendingMarker)
            let everTrusted = FileManager.default.fileExists(atPath: Onboarding.trustedMarker)
            trusted = !waitingNow && everTrusted
            trustDetail =
                waitingNow
                ? "the agent is waiting for the toggle"
                : (everTrusted ? "granted (agent quiet; inferred from state markers)" : "never granted")
        }
        check(
            trusted, "accessibility", trustDetail,
            fix: "System Settings -> Privacy & Security -> Accessibility -> toggle xcode-hackatime off, then on")

        let cliOK = FileManager.default.isExecutableFile(atPath: Installer.wakatimeCLIPath)
        check(
            cliOK, "wakatime-cli", cliOK ? Installer.wakatimeCLIPath : "missing",
            fix: "re-run 'xcode-hackatime install' to download and verify it")

        if cliOK {
            let today = Installer.todayCheck()
            check(
                today.ok, "api", today.detail,
                fix: "check api_key in ~/.wakatime.cfg - \(Installer.setupURL) writes it for you")
        }

        let xcode = XcodeObserver.runningXcode()
        check(
            xcode != nil, "Xcode",
            xcode.map { "running (pid \($0.processIdentifier))" } ?? "not running",
            fix: "open Xcode; the agent attaches automatically")

        // informational, never a failure: idle gating means silence while
        // the user is away is designed behavior, even with Xcode open
        let lastBeat = logLines.last { $0.contains("heartbeat:") }
        let beatDetail = lastBeat.flatMap { line -> String? in
            guard let start = line.range(of: "heartbeat:")?.upperBound else { return nil }
            return "last:" + line[start...]
        }
        check(true, "heartbeats", beatDetail ?? "none in the last 2h (normal while idle)")

        let competing = Installer.competingXcodeTrackerEnabled()
        check(
            !competing, "WakaTime.app",
            competing ? "also tracking Xcode (every heartbeat double-counts)" : "no conflict",
            fix: "run 'xcode-hackatime install' to auto-disable it")

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) problem\(failures == 1 ? "" : "s") found")
        return failures == 0 ? 0 : 1
    }
}

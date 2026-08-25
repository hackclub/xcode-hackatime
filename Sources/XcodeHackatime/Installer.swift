import AppKit
import Foundation

/// installs/removes the launchd agent so tracking starts at login and stays
/// alive. the installed binary itself is what needs the Accessibility grant.
enum Installer {
    static let label = "com.hackclub.hackatime.xcode-hackatime"
    static var installDir: String { NSHomeDirectory() + "/.wakatime" }
    static var installedBinary: String { installDir + "/xcode-hackatime" }
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    static var logPath: String { installDir + "/xcode-hackatime.log" }
    /// the standard CLI location every WakaTime plugin shares.
    static var wakatimeCLIPath: String { installDir + "/wakatime-cli" }
    /// created after the one-time Accessibility prompt. every install clears
    /// it: a reinstall invalidates the TCC grant for ad-hoc builds, and
    /// leaving the marker would suppress the re-prompt forever.
    static var axPromptedMarker: String { installDir + "/.ax-prompted" }
    /// where anyone signs up / fetches a key; the one copy of this URL.
    static let setupURL = "https://hackatime.hackclub.com/my/wakatime_setup"

    /// every marker and pid file, for uninstall's sweep. new state files
    /// must be added here or they leak across uninstall/reinstall.
    static var allStateFiles: [String] {
        [
            axPromptedMarker, Onboarding.trustedMarker, Onboarding.dismissedMarker,
            Onboarding.regrantMarker, Onboarding.grantPendingMarker,
            Onboarding.pidFile, KeySetup.pidFile,
        ]
    }

    /// absolute path to this executable. argv[0] is whatever the user typed
    /// at the shell (a bare name when found via $PATH), so never use it as
    /// a filesystem path.
    static let selfExecutablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]

    /// launch our own binary with a subcommand. returns nil if the spawn
    /// failed (e.g. the binary is briefly missing during a reinstall).
    @discardableResult
    static func spawnSelf(_ args: [String], discardOutput: Bool) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: selfExecutablePath)
        process.arguments = args
        if discardOutput {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        return (try? process.run()) != nil ? process : nil
    }

    /// best-effort creation of ~/.wakatime for callers outside install()
    /// (which keeps its throwing, permission-setting variant).
    static func ensureInstallDir() {
        try? FileManager.default.createDirectory(atPath: installDir, withIntermediateDirectories: true)
    }

    /// create-or-touch a marker file, ensuring its directory first. marker
    /// mtimes are load-bearing (the onboarding window compares them), so
    /// every marker goes through this one chokepoint.
    static func touchMarker(_ path: String) {
        ensureInstallDir()
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    /// remove a marker if present; true when it existed. markers are
    /// one-shot signals, so read-and-clear is the normal consumption.
    @discardableResult
    static func consumeMarker(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        try? FileManager.default.removeItem(atPath: path)
        return true
    }

    /// take the single-instance flock for a window process. the fd stays
    /// open for the process lifetime; the kernel drops the lock at exit, so
    /// stale files and recycled pids cannot fool it.
    static func acquireSingletonLock(_ path: String) -> Bool {
        ensureInstallDir()
        let fd = open(path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        ftruncate(fd, 0)
        "\(ProcessInfo.processInfo.processIdentifier)\n".withCString { _ = write(fd, $0, strlen($0)) }
        return true
    }

    /// user-visible macOS banner via osascript (an unbundled binary cannot
    /// use UNUserNotificationCenter). escapes the body, posts off the
    /// calling thread and rate-limits each distinct message to one banner
    /// per 10 minutes (per-message, so a grant banner cannot swallow the
    /// tracker banner that follows it).
    private static var lastBannerAt: [String: Date] = [:]
    static func postBanner(_ body: String) {
        guard Date().timeIntervalSince(lastBannerAt[body] ?? .distantPast) > 600 else { return }
        lastBannerAt[body] = Date()
        let escaped = body.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global(qos: .utility).async {
            shell("/usr/bin/osascript", ["-e", "display notification \"\(escaped)\" with title \"Hackatime\""])
        }
    }

    /// prove the whole auth path (key, network, backend) via the CLI.
    static func todayCheck() -> (ok: Bool, detail: String) {
        let (status, out) = shell(wakatimeCLIPath, ["--today"])
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0
            ? (true, "connected (\(trimmed) tracked today)")
            : (false, "wakatime-cli --today failed (exit \(status))")
    }

    /// launchctl print for our job; `field` plucks one "key = ..." line.
    static func launchdJob() -> (loaded: Bool, field: (String) -> String?) {
        let (status, out) = shell("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
        let lines = out.split(separator: "\n")
        return (
            status == 0,
            { key in lines.first { $0.contains(key) }?.trimmingCharacters(in: .whitespaces) }
        )
    }

    /// unified-log lines for our subsystem, header row dropped.
    static func unifiedLogLines(last: String) -> [String] {
        let (status, out) = shell(
            "/usr/bin/log",
            [
                "show", "--last", last, "--style", "compact",
                "--predicate", "subsystem == \"\(label)\"",
            ])
        guard status == 0 else { return [] }
        return out.split(separator: "\n").dropFirst().map(String.init)
    }

    /// the file only holds stderr (crash traces) and launchd never rotates
    /// it; a crash LOOP would grow it without bound, so every agent start
    /// trims past ~1MB. startup-only is enough: a crash loop relaunches
    /// constantly, so trims happen constantly too. the write is non-atomic
    /// on purpose. it truncates the inode launchd already has open
    /// (O_APPEND), so future relaunches keep appending correctly.
    static func trimLogIfNeeded() {
        guard let size = FileManager.default.fileSize(atPath: logPath), size > 1_000_000 else { return }
        try? "".write(toFile: logPath, atomically: false, encoding: .utf8)
        logLine("log trimmed (was \(size) bytes)")
    }

    static func install() -> Int32 {
        let fm = FileManager.default
        let selfPath = URL(fileURLWithPath: selfExecutablePath).resolvingSymlinksInPath().path

        do {
            try fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
            // the log records every file path the user works on; keep the
            // directory and log unreadable to other local accounts.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installDir)
            if !fm.fileExists(atPath: logPath) {
                fm.createFile(atPath: logPath, contents: Data(), attributes: [.posixPermissions: 0o600])
            } else {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPath)
            }
            try? fm.removeItem(atPath: axPromptedMarker)
            // copy the binary to a stable path. a launchd agent that points
            // at a build directory would break on the next `swift build`
            // (and the Accessibility grant is tied to the binary's
            // location). stage next to the destination, then rename(2) into
            // place: every step up to and including the swap leaves a
            // previously working install fully intact on failure (a running
            // old agent keeps its vnode across the rename; only the
            // bootout/bootstrap below replaces it).
            if selfPath != installedBinary {
                if fm.fileExists(atPath: installedBinary) { touchMarker(Onboarding.regrantMarker) }
                let staged = installedBinary + ".new"
                try? fm.removeItem(atPath: staged)
                try fm.copyItem(atPath: selfPath, toPath: staged)
                guard rename(staged, installedBinary) == 0 else {
                    try? fm.removeItem(atPath: staged)
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }

            // no StandardOutPath: the unified log is the record for normal
            // output (the OS rotates and protects it). the file only
            // captures stderr, which the unified log cannot: crash traces.
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [installedBinary, "run"],
                "RunAtLoad": true,
                "KeepAlive": true,
                "StandardErrorPath": logPath,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try fm.createDirectory(
                atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)

            _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            let (status, out) = shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath])
            guard status == 0 else {
                print("launchctl bootstrap failed: \(out)")
                return 1
            }
        } catch {
            print("install failed: \(error)")
            return 1
        }

        disableCompetingXcodeTracker()
        let cliInstalled = ensureWakatimeCLI()

        guard cliInstalled else {
            print("")
            print("⚠️  Install INCOMPLETE: wakatime-cli is missing, so heartbeats cannot")
            print("   be sent. The agent is registered and will start working once")
            print("   ~/.wakatime/wakatime-cli exists. Re-run install to retry.")
            return 1
        }
        // prove the whole auth path now, while the user is still looking at
        // the terminal, instead of days later when stats are missing. a
        // passing --today already proves a key exists, so the key probe
        // only runs to split "bad key" from "no key".
        let today = todayCheck()
        if today.ok {
            print("✓ \(today.detail)")
        } else if apiKeyConfigured() {
            print("⚠️  \(today.detail): the api_key in ~/.wakatime.cfg may be wrong.")
            print("   \(setupURL) writes a fresh one. run 'xcode-hackatime doctor' to re-check.")
        } else {
            print("")
            print("⚠️  No api_key found in ~/.wakatime.cfg.")
            print("   \(setupURL) writes it for you.")
            // an invitation, never a gate: the window is closable and
            // tracking starts on its own the moment a key exists.
            spawnSelf(["setup-key"], discardOutput: false)
        }
        print("Installed and started.")
        print("  agent:  \(installedBinary)")
        print("  plist:  \(plistPath)")
        print("  log:    \(logPath)")
        print("")
        print("If Accessibility permission hasn't been granted yet, macOS will now")
        print("show a prompt (or add 'xcode-hackatime' to System Settings → Privacy")
        print("& Security → Accessibility - enable it there). Tracking begins the")
        print("moment the permission is on; no restart needed.")
        // show the walkthrough window even with Xcode closed: install is an
        // explicit user action, so a window is expected. it self-suppresses
        // when the agent is already tracking.
        Onboarding.spawnIfNeeded(afterInstall: true)
        return 0
    }

    /// macos-wakatime (WakaTime.app) tracks Xcode through the same AX API;
    /// running both double-counts every heartbeat. its monitored-app list is
    /// a plain array in its defaults domain, so install removes Xcode from
    /// it (other apps untouched) and bounces the app in the background - no
    /// settings window appears.
    private static let wakaTimeAppBundleID = "macos-wakatime.WakaTime"
    private static let wakaTimeMonitoredKey = "wakatime_monitored_apps"

    /// process-lifetime file watchers. dispatch sources die when released,
    /// so every active watcher stays referenced here.
    private static var watchers: [DispatchSourceFileSystemObject] = []

    /// watch a file for changes, surviving atomic replaces. cfprefsd writes
    /// preferences via temp-and-rename, which kills a naive per-fd watch:
    /// on delete or rename this watcher reports the change, then reopens
    /// the path and keeps watching the replacement.
    static func watchFile(_ path: String, onChange: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // the file does not exist yet (domain never written); retry.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { watchFile(path, onChange: onChange) }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        // weak captures: a dispatch source retains its handler blocks, so a
        // strong `source` here would be a retain cycle that leaks one source
        // per atomic replace for the life of the agent.
        source.setEventHandler { [weak source] in
            guard let source else { return }
            let events = source.data
            onChange()
            if events.contains(.delete) || events.contains(.rename) {
                source.cancel()
            }
        }
        source.setCancelHandler { [weak source] in
            close(fd)
            if let source { watchers.removeAll { $0 === source } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { watchFile(path, onChange: onChange) }
        }
        watchers.append(source)
        source.resume()
        // fire once per attach: a change can land inside the reattach gap
        // after an atomic replace, and the watcher is the sole owner of its
        // state (no polling fallback), so every attach re-checks.
        onChange()
    }

    /// event-driven guard for decision 15: watch WakaTime.app's preferences
    /// and re-disable its Xcode tracking the moment it reappears. there is
    /// no polling fallback; the watcher's attach-time fire carries the
    /// ownership across replaces. our own rewrite also fires the watcher
    /// once; the re-check is then a no-op.
    static func startCompetingTrackerWatcher(report: @escaping (String) -> Void) {
        let plist = NSHomeDirectory() + "/Library/Preferences/\(wakaTimeAppBundleID).plist"
        watchFile(plist) {
            disableCompetingXcodeTracker(report: report, notifyUser: true)
        }
    }

    static func competingXcodeTrackerEnabled() -> Bool {
        let domain = UserDefaults.standard.persistentDomain(forName: wakaTimeAppBundleID)
        let monitored = domain?[wakaTimeMonitoredKey] as? [String] ?? []
        return monitored.contains(XcodeObserver.xcodeBundleID)
    }

    /// both trackers share ~/.wakatime.cfg and the CLI, so dual Xcode
    /// tracking is never a deliberate setup - it is always double-counting.
    /// callers therefore re-run this whenever the list can have reappeared
    /// (WakaTime.app reinstalls preserve preferences, but wipes and fresh
    /// first-runs do not). it does nothing when Xcode is not in the list.
    static func disableCompetingXcodeTracker(report: (String) -> Void = { print($0) }, notifyUser: Bool = false) {
        guard var domain = UserDefaults.standard.persistentDomain(forName: wakaTimeAppBundleID),
            var monitored = domain[wakaTimeMonitoredKey] as? [String],
            monitored.contains(XcodeObserver.xcodeBundleID)
        else { return }
        monitored.removeAll { $0 == XcodeObserver.xcodeBundleID }
        domain[wakaTimeMonitoredKey] = monitored
        UserDefaults.standard.setPersistentDomain(domain, forName: wakaTimeAppBundleID)
        report("Disabled WakaTime.app's Xcode tracking (it would double-count every heartbeat).")
        report("Its other monitored apps are untouched.")
        if notifyUser {
            postBanner("WakaTime.app tried to track Xcode again - disabled it to prevent double-counting.")
        }
        // a running WakaTime.app may cache the list; bounce it invisibly
        // (open -g launches in the background, no windows). the wait blocks,
        // so the agent (notifyUser) does it off the main run loop; the
        // one-shot install CLI needs it synchronous or the process exits
        // before the relaunch.
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: wakaTimeAppBundleID).first
        else { return }
        let bounce = {
            app.terminate()
            for _ in 0..<15 where !app.isTerminated { Thread.sleep(forTimeInterval: 0.2) }
            shell("/usr/bin/open", ["-g", "-b", wakaTimeAppBundleID])
        }
        if notifyUser {
            DispatchQueue.global(qos: .utility).async(execute: bounce)
        } else {
            bounce()
        }
    }

    /// WakaTime, Inc.'s Apple Developer team, pinned so a compromised
    /// release asset fails closed instead of executing as the user. (the
    /// team ID is stable across releases, unlike a per-release digest.)
    private static let wakatimeTeamID = "538RQNWSWT"

    /// download wakatime-cli from GitHub releases if it is not present.
    /// (the location is standard and every other WakaTime plugin shares it.)
    /// returns whether a working CLI is in place.
    private static func ensureWakatimeCLI() -> Bool {
        let fm = FileManager.default
        let cli = wakatimeCLIPath
        if fm.isExecutableFile(atPath: cli) { return true }

        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        let asset = "wakatime-cli-darwin-\(arch)"
        let url = "https://github.com/wakatime/wakatime-cli/releases/latest/download/\(asset).zip"

        // stage the download in a private directory: nothing from the
        // archive may touch live paths before it passes verification. a
        // hostile zip could otherwise overwrite the agent binary itself,
        // even when the CLI entry later fails its check.
        let stagingDir = installDir + "/.cli-staging"
        try? fm.removeItem(atPath: stagingDir)
        do {
            try fm.createDirectory(
                atPath: stagingDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            print("warning: could not create staging directory: \(error.localizedDescription)")
            return false
        }
        defer { try? fm.removeItem(atPath: stagingDir) }
        let zipPath = stagingDir + "/\(asset).zip"

        print("Downloading wakatime-cli…")
        let (dl, dlOut) = shell("/usr/bin/curl", ["-fsSL", "-o", zipPath, url])
        guard dl == 0 else {
            print("warning: could not download wakatime-cli (\(dlOut.trimmingCharacters(in: .whitespacesAndNewlines)))")
            print("Install it manually from https://github.com/wakatime/wakatime-cli/releases")
            return false
        }
        let (uz, uzOut) = shell("/usr/bin/unzip", ["-o", "-q", zipPath, "-d", stagingDir])
        let staged = stagingDir + "/\(asset)"
        guard uz == 0, fm.fileExists(atPath: staged) else {
            print("warning: could not unpack wakatime-cli (\(uzOut.trimmingCharacters(in: .whitespacesAndNewlines)))")
            return false
        }
        // the archive comes from a mutable "latest" URL and we will execute
        // it. anchor the check to Apple's Developer ID chain AND WakaTime's
        // team via a codesign requirement: a self-signed certificate can
        // claim any TeamIdentifier in -dv text, so text matching proves
        // nothing.
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(wakatimeTeamID)\""
        guard shell("/usr/bin/codesign", ["--verify", "--strict", "-R=\(requirement)", staged]).0 == 0 else {
            print("warning: downloaded wakatime-cli failed code-signature verification; discarded it.")
            print("Install it manually from https://github.com/wakatime/wakatime-cli/releases")
            return false
        }
        _ = shell("/bin/chmod", ["+x", staged])
        // only the verified binary leaves staging.
        let assetPath = installDir + "/\(asset)"
        try? fm.removeItem(atPath: assetPath)
        guard rename(staged, assetPath) == 0 else {
            print("warning: could not move verified wakatime-cli into place")
            return false
        }
        // fileExists follows symlinks, so a dangling link reads as absent
        // and would wedge every reinstall on "file exists". check for the
        // link itself too.
        if fm.fileExists(atPath: cli) || (try? fm.destinationOfSymbolicLink(atPath: cli)) != nil {
            do { try fm.removeItem(atPath: cli) } catch {
                print("warning: could not replace existing \(cli): \(error.localizedDescription)")
                return false
            }
        }
        do { try fm.createSymbolicLink(atPath: cli, withDestinationPath: assetPath) } catch {
            print("warning: could not link wakatime-cli: \(error.localizedDescription)")
            return false
        }
        guard fm.isExecutableFile(atPath: cli) else {
            print("warning: \(cli) is not executable after install; heartbeats will fail")
            return false
        }
        print("wakatime-cli installed (signature verified).")
        return true
    }

    /// ask wakatime-cli itself whether a key is configured. it owns the
    /// config format (INI sections, comments, WAKATIME_HOME relocation), so
    /// delegating makes it impossible for this check to drift from how the
    /// CLI actually reads the file. --config-read exits 0 only for a
    /// present, nonempty value.
    static func apiKeyConfigured() -> Bool {
        let cli = wakatimeCLIPath
        if FileManager.default.isExecutableFile(atPath: cli) {
            return ["api_key", "api_key_vault_cmd"].contains { key in
                shell(cli, ["--config-read", key]).0 == 0
            }
        }
        // no CLI to ask (its download just failed, which install already
        // warned about); a strict line scan still catches the common
        // "no key at all" case for the setup hint.
        let cfg = NSHomeDirectory() + "/.wakatime.cfg"
        let contents = (try? String(contentsOfFile: cfg, encoding: .utf8)) ?? ""
        return contents.split(separator: "\n").contains { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return false }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return (key == "api_key" || key == "api_key_vault_cmd") && !value.isEmpty
        }
    }

    static func uninstall() -> Int32 {
        // bootout of an agent that is not loaded fails; that is fine, since
        // the goal state (not running) is already true. but bootout can also
        // fail with the job still loaded, so verify the goal state itself
        // before deleting anything: removing the plist does not unload an
        // already-bootstrapped job, and a running agent keeps tracking.
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        if shell("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).0 == 0 {
            print(
                "Uninstall failed: the agent is still loaded (launchctl bootout did not take effect). Nothing was removed."
            )
            return 1
        }
        // the onboarding window is a separate process that survives agent
        // relaunches. it would survive uninstall too (then recreate its
        // dismissed marker on close). stop it explicitly.
        if Onboarding.isRunning(),
            let text = try? String(contentsOfFile: Onboarding.pidFile, encoding: .utf8),
            let onboardPid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            // guard against pid recycling: only signal a process that is
            // actually our binary. SIGTERM is destructive to strangers.
            NSRunningApplication(processIdentifier: onboardPid)?
                .executableURL?.lastPathComponent == "xcode-hackatime"
        {
            if kill(onboardPid, SIGTERM) != 0 {
                print("note: could not stop the onboarding window (pid \(onboardPid)); close it manually.")
            }
        }
        // our state files. wakatime-cli and ~/.wakatime.cfg stay; every
        // other WakaTime plugin shares them. a missing file is the goal
        // state. never report any other removal failure as success.
        let fm = FileManager.default
        var failures: [String] = []
        for path in [plistPath, installedBinary, logPath] + allStateFiles
        where fm.fileExists(atPath: path) {
            do { try fm.removeItem(atPath: path) } catch {
                failures.append("\(path): \(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else {
            print("Uninstall incomplete - could not remove:")
            failures.forEach { print("  \($0)") }
            return 1
        }
        print("Uninstalled. You can also remove the Accessibility entry in System Settings.")
        return 0
    }

    static func status() -> Int32 {
        let job = launchdJob()
        if job.loaded {
            print("launchd agent: loaded (\(job.field("state =") ?? "state unknown"))")
        } else {
            print("launchd agent: not loaded")
        }
        // prefer the unified log (the system of record); `log show` can fail
        // for non-admin accounts, so the crash-trace file below remains the
        // fallback.
        let entries = unifiedLogLines(last: "30m")
        if !entries.isEmpty {
            print("--- recent activity (unified log, last 30m) ---")
            entries.suffix(10).forEach { print($0) }
            return job.loaded ? 0 : 1
        }
        // tail without materializing the whole log. decode lossily (the
        // seek can land mid-scalar) and drop the first (possibly partial)
        // line when it does not start at offset 0.
        if let fh = FileHandle(forReadingAtPath: logPath) {
            let size = (try? fh.seekToEnd()) ?? 0
            let window: UInt64 = 16_384
            let start = size > window ? size - window : 0
            try? fh.seek(toOffset: start)
            var lines = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n")[...]
            if start > 0 { lines = lines.dropFirst() }
            if !lines.isEmpty {
                print("--- stderr log (crash traces) ---")
                lines.suffix(10).forEach { print($0) }
            }
            try? fh.close()
        }
        return job.loaded ? 0 : 1
    }

    @discardableResult
    static func shell(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (127, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

extension FileManager {
    /// modification date of the item at `path`, nil if unreadable.
    func modificationDate(atPath path: String) -> Date? {
        (try? attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// size in bytes of the item at `path`, nil if unreadable.
    func fileSize(atPath path: String) -> Int? {
        (try? attributesOfItem(atPath: path))?[.size] as? Int
    }
}

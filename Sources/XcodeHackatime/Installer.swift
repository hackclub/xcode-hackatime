import AppKit
import Foundation

/// installs and removes the launchd agent. the installed copy at a stable
/// path is the binary that holds the Accessibility grant
enum Installer {
    static let label = "com.hackclub.hackatime.xcode-hackatime"
    static var installDir: String { NSHomeDirectory() + "/.wakatime" }
    static var installedBinary: String { installDir + "/xcode-hackatime" }
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    static var logPath: String { installDir + "/xcode-hackatime.log" }
    /// standard CLI location shared by every WakaTime plugin
    static var wakatimeCLIPath: String { installDir + "/wakatime-cli" }
    /// created after the one-time Accessibility prompt. every install clears
    /// it: replacing an ad-hoc binary invalidates the TCC grant, and a
    /// leftover marker would suppress the re-prompt forever
    static var axPromptedMarker: String { installDir + "/.ax-prompted" }
    /// where users sign up and fetch a key
    static let setupURL = "https://hackatime.hackclub.com/my/wakatime_setup"

    /// new state files must be added here or they leak across uninstall
    static var allStateFiles: [String] {
        [
            axPromptedMarker, Onboarding.trustedMarker, Onboarding.dismissedMarker,
            Onboarding.regrantMarker, Onboarding.grantPendingMarker,
            Onboarding.pidFile, KeySetup.pidFile, notifierApp,
        ]
    }

    /// argv[0] is whatever the user typed at the shell (a bare name when
    /// found via $PATH), so it is never usable as a filesystem path
    static let selfExecutablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
    /// symlink-resolved, so copies land the real binary and not a link
    static let resolvedSelfPath = URL(fileURLWithPath: selfExecutablePath).resolvingSymlinksInPath().path

    /// returns nil if the spawn failed (e.g. the binary is briefly missing
    /// during a reinstall)
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

    static func ensureInstallDir() {
        try? FileManager.default.createDirectory(atPath: installDir, withIntermediateDirectories: true)
    }

    /// the onboarding window compares marker mtimes, so every marker write
    /// goes through here
    static func touchMarker(_ path: String) {
        ensureInstallDir()
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    /// remove a marker if present; true when it existed
    @discardableResult
    static func consumeMarker(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        try? FileManager.default.removeItem(atPath: path)
        return true
    }

    /// the fd stays open for the process lifetime and the kernel drops the
    /// flock at exit, so stale files and recycled pids cannot fool it
    static func acquireSingletonLock(_ path: String) -> Bool {
        ensureInstallDir()
        let fd = open(path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        ftruncate(fd, 0)
        "\(ProcessInfo.processInfo.processIdentifier)\n".withCString { _ = write(fd, $0, strlen($0)) }
        return true
    }

    /// helper bundle assembled by install; gives banners a real Hackatime
    /// identity (name, icon, Focus-manageable)
    static var notifierApp: String { installDir + "/Hackatime.app" }
    static var notifierBinary: String { notifierApp + "/Contents/MacOS/" + Notifier.executableName }

    /// best-effort banner: no helper means no banner, never a fallback under
    /// another app's identity. throttled per message so a grant banner
    /// cannot swallow the tracker banner that follows it
    private static var lastBannerAt: [String: Date] = [:]
    static func postBanner(_ body: String) {
        guard Date().timeIntervalSince(lastBannerAt[body] ?? .distantPast) > 600 else { return }
        if deliverBanner(body) { lastBannerAt[body] = Date() }
    }

    /// the single chokepoint for helper invocation. fire and forget: the
    /// helper delays its own exit 0.7s for the notification daemon, and no
    /// caller should block on that
    @discardableResult
    static func deliverBanner(_ message: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: notifierBinary) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: notifierBinary)
        process.arguments = ["notify", message]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }

    /// assemble ~/.wakatime/Hackatime.app around a copy of our binary. the
    /// icon renders on-device; no assets ship with the bare binary
    static func installNotifierApp() {
        let fm = FileManager.default
        let contents = notifierApp + "/Contents"
        let macos = contents + "/MacOS"
        let resources = contents + "/Resources"
        do {
            try fm.createDirectory(atPath: macos, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: resources, withIntermediateDirectories: true)
            try writePlist(
                [
                    "CFBundleIdentifier": Notifier.bundleID,
                    "CFBundleName": "Hackatime",
                    "CFBundleDisplayName": "Hackatime",
                    "CFBundleExecutable": Notifier.executableName,
                    "CFBundleIconFile": "Hackatime",
                    "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": appVersion,
                    "LSUIElement": true,
                ], to: contents + "/Info.plist")
            try? fm.removeItem(atPath: notifierBinary)
            try fm.copyItem(atPath: resolvedSelfPath, toPath: notifierBinary)
            let icon = resources + "/Hackatime.icns"
            if !fm.fileExists(atPath: icon) { Notifier.writeIcon(to: icon) }
            // ad-hoc signature suffices for notification delivery, verified live
            shell(
                "/usr/bin/codesign", ["-f", "-s", "-", "--identifier", Notifier.bundleID, notifierApp])
            // lsregister so LaunchServices resolves the bundle id and icon
            shell(
                "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                ["-f", notifierApp])
        } catch {
            print(
                "note: could not assemble the notification helper (\(error.localizedDescription)); banners are skipped."
            )
        }
    }

    static func writePlist(_ dict: [String: Any], to path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// proves the whole auth path (key, network, backend) via the CLI
    static func todayCheck() -> (ok: Bool, detail: String) {
        let (status, out) = shell(wakatimeCLIPath, ["--today"])
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0
            ? (true, "connected (\(trimmed) tracked today)")
            : (false, "wakatime-cli --today failed (exit \(status))")
    }

    /// launchctl print for our job; `field` plucks one "key = ..." line
    static func launchdJob() -> (loaded: Bool, field: (String) -> String?) {
        let (status, out) = shell("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
        let lines = out.split(separator: "\n")
        return (
            status == 0,
            { key in lines.first { $0.contains(key) }?.trimmingCharacters(in: .whitespaces) }
        )
    }

    /// unified-log lines for our subsystem, header row dropped
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

    /// launchd never rotates the stderr file and a crash loop would grow it
    /// without bound; startup-only trimming is enough because a crash loop
    /// relaunches constantly. the non-atomic write truncates the inode
    /// launchd holds open O_APPEND, so relaunches keep appending correctly
    static func trimLogIfNeeded() {
        guard let size = FileManager.default.fileSize(atPath: logPath), size > 1_000_000 else { return }
        try? "".write(toFile: logPath, atomically: false, encoding: .utf8)
        logLine("log trimmed (was \(size) bytes)")
    }

    static func install() -> Int32 {
        let fm = FileManager.default
        let selfPath = resolvedSelfPath

        do {
            try fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
            // the log records every file path the user works on; keep it
            // unreadable to other local accounts
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installDir)
            if !fm.fileExists(atPath: logPath) {
                fm.createFile(atPath: logPath, contents: Data(), attributes: [.posixPermissions: 0o600])
            } else {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPath)
            }
            try? fm.removeItem(atPath: axPromptedMarker)
            // the Accessibility grant is tied to the binary's location, and
            // a build-directory path would break on the next swift build.
            // stage then rename(2) so a failed install leaves the previous
            // working install intact (a running old agent keeps its vnode
            // across the rename)
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
            // output; the file exists for crash traces on stderr, which the
            // unified log cannot capture
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [installedBinary, "run"],
                "RunAtLoad": true,
                "KeepAlive": true,
                "StandardErrorPath": logPath,
            ]
            try fm.createDirectory(
                atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try writePlist(plist, to: plistPath)

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
        // prove the auth path while the user is still at the terminal, not
        // days later when stats are missing. the key probe only runs to
        // split "bad key" from "no key"
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
            // tracking starts on its own the moment a key exists
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
        // install is an explicit user action, so the walkthrough window is
        // expected even with Xcode closed
        Onboarding.spawnIfNeeded(afterInstall: true)
        // macOS never prompts for NSUserNotification sources; without the
        // prime-and-approve every banner is silent
        installNotifierApp()
        Notifier.primeDelivery(
            message: "Notifications are set up - Hackatime posts important tracking events here.",
            deliver: deliverBanner)
        return 0
    }

    /// WakaTime.app tracks Xcode through the same AX API; running both
    /// double-counts every heartbeat
    private static let wakaTimeAppBundleID = "macos-wakatime.WakaTime"
    private static let wakaTimeMonitoredKey = "wakatime_monitored_apps"

    /// dispatch sources die when released, so active watchers live here
    private static var watchers: [DispatchSourceFileSystemObject] = []

    /// cfprefsd writes preferences via temp-and-rename, which kills a naive
    /// per-fd watch; on delete or rename this reports the change, then
    /// reopens the path and watches the replacement
    static func watchFile(_ path: String, onChange: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // the file does not exist yet (domain never written); retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { watchFile(path, onChange: onChange) }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        // a dispatch source retains its handler blocks; a strong `source`
        // here is a retain cycle leaking one source per atomic replace
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
        // a change can land inside the reattach gap after an atomic replace,
        // and there is no polling fallback, so every attach re-checks
        onChange()
    }

    /// re-disable WakaTime.app's Xcode tracking the moment its preferences
    /// change; event-driven only, no polling fallback
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
    /// tracking is always double-counting, never a deliberate setup. no-op
    /// when Xcode is not in the list
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
        // a running WakaTime.app caches the list, so bounce it (open -g
        // relaunches in the background, no windows). the agent bounces off
        // the main run loop; the one-shot install CLI must stay synchronous
        // or the process exits before the relaunch
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
    /// release asset fails closed. the team ID is stable across releases,
    /// unlike a per-release digest
    private static let wakatimeTeamID = "538RQNWSWT"

    /// download wakatime-cli from GitHub releases if absent; returns whether
    /// a working CLI is in place
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

        // nothing from the archive may touch live paths before it passes
        // verification: a hostile zip could otherwise overwrite the agent
        // binary itself even when the CLI entry later fails its check
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
        // the archive comes from a mutable "latest" URL and will be
        // executed. the requirement anchors to Apple's chain AND the team:
        // a self-signed certificate can claim any TeamIdentifier in -dv
        // text, so text matching proves nothing
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(wakatimeTeamID)\""
        guard shell("/usr/bin/codesign", ["--verify", "--strict", "-R=\(requirement)", staged]).0 == 0 else {
            print("warning: downloaded wakatime-cli failed code-signature verification; discarded it.")
            print("Install it manually from https://github.com/wakatime/wakatime-cli/releases")
            return false
        }
        _ = shell("/bin/chmod", ["+x", staged])
        let assetPath = installDir + "/\(asset)"
        try? fm.removeItem(atPath: assetPath)
        guard rename(staged, assetPath) == 0 else {
            print("warning: could not move verified wakatime-cli into place")
            return false
        }
        // fileExists follows symlinks, so a dangling link reads as absent
        // and would wedge every reinstall on "file exists"
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

    /// wakatime-cli owns the config format (INI sections, comments,
    /// WAKATIME_HOME relocation), so delegating cannot drift from how it
    /// reads the file. --config-read exits 0 only for a nonempty value
    static func apiKeyConfigured() -> Bool {
        let cli = wakatimeCLIPath
        if FileManager.default.isExecutableFile(atPath: cli) {
            return ["api_key", "api_key_vault_cmd"].contains { key in
                shell(cli, ["--config-read", key]).0 == 0
            }
        }
        // no CLI to ask; a strict line scan still catches the common
        // "no key at all" case for the setup hint
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
        // bootout can fail with the job still loaded, and removing the plist
        // does not unload an already-bootstrapped job, so verify the goal
        // state itself before deleting anything
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        if shell("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).0 == 0 {
            print(
                "Uninstall failed: the agent is still loaded (launchctl bootout did not take effect). Nothing was removed."
            )
            return 1
        }
        // the onboarding window is a separate process; it would survive
        // uninstall and recreate its dismissed marker on close
        if Onboarding.isRunning(),
            let text = try? String(contentsOfFile: Onboarding.pidFile, encoding: .utf8),
            let onboardPid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            // pid recycling: only SIGTERM a process that is actually our binary
            NSRunningApplication(processIdentifier: onboardPid)?
                .executableURL?.lastPathComponent == "xcode-hackatime"
        {
            if kill(onboardPid, SIGTERM) != 0 {
                print("note: could not stop the onboarding window (pid \(onboardPid)); close it manually.")
            }
        }
        // wakatime-cli and ~/.wakatime.cfg stay; other WakaTime plugins
        // share them
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
        // `log show` can fail for non-admin accounts, so the crash-trace
        // file below remains the fallback
        let entries = unifiedLogLines(last: "30m")
        if !entries.isEmpty {
            print("--- recent activity (unified log, last 30m) ---")
            entries.suffix(10).forEach { print($0) }
            return job.loaded ? 0 : 1
        }
        // decode lossily (the seek can land mid-scalar) and drop the first,
        // possibly partial, line when it does not start at offset 0
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
    func modificationDate(atPath path: String) -> Date? {
        (try? attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func fileSize(atPath path: String) -> Int? {
        (try? attributesOfItem(atPath: path))?[.size] as? Int
    }
}

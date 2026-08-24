import Foundation

/// Installs/removes the launchd agent so tracking starts at login and stays
/// alive. The installed binary itself is what needs the Accessibility grant.
enum Installer {
    static let label = "com.hackclub.hackatime.xcode-hackatime"
    static var installDir: String { NSHomeDirectory() + "/.wakatime" }
    static var installedBinary: String { installDir + "/xcode-hackatime" }
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    static var logPath: String { installDir + "/xcode-hackatime.log" }
    /// Created after the one-time Accessibility prompt. Cleared on every
    /// install: a reinstall invalidates the TCC grant for ad-hoc builds, and
    /// leaving the marker would suppress the re-prompt forever.
    static var axPromptedMarker: String { installDir + "/.ax-prompted" }

    /// Absolute path to this executable. argv[0] is whatever was typed at
    /// the shell - a bare name when found via $PATH - so it must never be
    /// used as a filesystem path.
    static let selfExecutablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]

    /// Launch our own binary with a subcommand. Returns nil if the spawn
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

    /// launchd never rotates StandardOutPath, so bound it ourselves: start
    /// each agent run with a fresh file once it grows past ~1MB. Non-atomic
    /// write on purpose - it truncates the inode launchd already has open
    /// (O_APPEND), so both our stdout and future relaunches keep working.
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
            // The log records every file path the user works on; keep the
            // directory and log unreadable to other local accounts.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installDir)
            if !fm.fileExists(atPath: logPath) {
                fm.createFile(atPath: logPath, contents: Data(), attributes: [.posixPermissions: 0o600])
            } else {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPath)
            }
            try? fm.removeItem(atPath: axPromptedMarker)
            // Copy the binary to a stable path - a launchd agent pointing at a
            // build directory would break on the next `swift build` (and the
            // Accessibility grant is tied to the binary's location). Stage
            // next to the destination, then rename(2) into place: every step
            // up to and including the swap leaves a previously working
            // install fully intact on failure (a running old agent keeps its
            // vnode across the rename and is replaced only at the
            // bootout/bootstrap below).
            if selfPath != installedBinary {
                let staged = installedBinary + ".new"
                try? fm.removeItem(atPath: staged)
                try fm.copyItem(atPath: selfPath, toPath: staged)
                guard rename(staged, installedBinary) == 0 else {
                    try? fm.removeItem(atPath: staged)
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }

            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [installedBinary, "run"],
                "RunAtLoad": true,
                "KeepAlive": true,
                "StandardOutPath": logPath,
                "StandardErrorPath": logPath,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try fm.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
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

        ensureWakatimeCLI()
        checkAPIKey()

        print("Installed and started.")
        print("  agent:  \(installedBinary)")
        print("  plist:  \(plistPath)")
        print("  log:    \(logPath)")
        print("")
        print("If Accessibility permission hasn't been granted yet, macOS will now")
        print("show a prompt (or add 'xcode-hackatime' to System Settings → Privacy")
        print("& Security → Accessibility - enable it there). Tracking begins the")
        print("moment the permission is on; no restart needed.")
        return 0
    }

    /// Download wakatime-cli from GitHub releases if it isn't present.
    /// (Standard location shared with every other WakaTime plugin.)
    private static func ensureWakatimeCLI() {
        let fm = FileManager.default
        let cli = installDir + "/wakatime-cli"
        if fm.isExecutableFile(atPath: cli) { return }

        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        let asset = "wakatime-cli-darwin-\(arch)"
        let url = "https://github.com/wakatime/wakatime-cli/releases/latest/download/\(asset).zip"
        let zipPath = installDir + "/\(asset).zip"

        print("Downloading wakatime-cli…")
        let (dl, dlOut) = shell("/usr/bin/curl", ["-fsSL", "-o", zipPath, url])
        guard dl == 0 else {
            print("warning: could not download wakatime-cli (\(dlOut.trimmingCharacters(in: .whitespacesAndNewlines)))")
            print("Install it manually from https://github.com/wakatime/wakatime-cli/releases")
            return
        }
        let (uz, uzOut) = shell("/usr/bin/unzip", ["-o", "-q", zipPath, "-d", installDir])
        try? fm.removeItem(atPath: zipPath)
        guard uz == 0, fm.fileExists(atPath: installDir + "/\(asset)") else {
            print("warning: could not unpack wakatime-cli (\(uzOut.trimmingCharacters(in: .whitespacesAndNewlines)))")
            return
        }
        _ = shell("/bin/chmod", ["+x", installDir + "/\(asset)"])
        if fm.fileExists(atPath: cli) {
            do { try fm.removeItem(atPath: cli) } catch {
                print("warning: could not replace existing \(cli): \(error.localizedDescription)")
                return
            }
        }
        do { try fm.createSymbolicLink(atPath: cli, withDestinationPath: installDir + "/\(asset)") } catch {
            print("warning: could not link wakatime-cli: \(error.localizedDescription)")
            return
        }
        guard fm.isExecutableFile(atPath: cli) else {
            print("warning: \(cli) is not executable after install; heartbeats will fail")
            return
        }
        print("wakatime-cli installed.")
    }

    private static func checkAPIKey() {
        // Ask wakatime-cli itself whether a key is configured - it owns the
        // config format (INI sections, comments, WAKATIME_HOME relocation),
        // so delegating makes it impossible for this check to drift from
        // how the CLI actually reads the file. --config-read exits 0 only
        // for a present, nonempty value.
        let cli = installDir + "/wakatime-cli"
        let hasKey: Bool
        if FileManager.default.isExecutableFile(atPath: cli) {
            hasKey = ["api_key", "api_key_vault_cmd"].contains { key in
                shell(cli, ["--config-read", key]).0 == 0
            }
        } else {
            // No CLI to ask (its download just failed, which install already
            // warned about); a strict line scan still catches the common
            // "no key at all" case for the setup hint below.
            let cfg = NSHomeDirectory() + "/.wakatime.cfg"
            let contents = (try? String(contentsOfFile: cfg, encoding: .utf8)) ?? ""
            hasKey = contents.split(separator: "\n").contains { line in
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return false }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                return (key == "api_key" || key == "api_key_vault_cmd") && !value.isEmpty
            }
        }
        if !hasKey {
            print("")
            print("⚠️  No api_key found in ~/.wakatime.cfg.")
            print("   Hackatime: follow https://hackatime.hackclub.com - its setup script")
            print("   writes ~/.wakatime.cfg for you. WakaTime: put your key from")
            print("   https://wakatime.com/settings/api-key in ~/.wakatime.cfg:")
            print("     [settings]")
            print("     api_key = YOUR-KEY")
        }
    }

    static func uninstall() -> Int32 {
        // bootout of an agent that isn't loaded fails; that's fine - the
        // goal state (not running) is already true. But bootout can also
        // fail with the job still loaded, so verify the goal state itself
        // before deleting anything: removing the plist does not unload an
        // already-bootstrapped job, and a running agent keeps tracking.
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        if shell("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).0 == 0 {
            print("Uninstall failed: the agent is still loaded (launchctl bootout did not take effect). Nothing was removed.")
            return 1
        }
        // The onboarding window is a separate process that survives agent
        // relaunches - and would survive uninstall too (then recreate its
        // dismissed marker on close). Stop it explicitly.
        if Onboarding.isRunning(),
           let text = try? String(contentsOfFile: Onboarding.pidFile, encoding: .utf8),
           let onboardPid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(onboardPid, SIGTERM)
        }
        // Our state files. wakatime-cli and ~/.wakatime.cfg stay - they're
        // shared with every other WakaTime plugin. A missing file is the
        // goal state; any other removal failure must not be reported as
        // success.
        let fm = FileManager.default
        var failures: [String] = []
        for path in [plistPath, installedBinary, logPath,
                     Onboarding.trustedMarker, Onboarding.dismissedMarker,
                     Onboarding.pidFile, axPromptedMarker]
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
        let (status, out) = shell("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
        let loaded = status == 0
        if loaded {
            let state = out.split(separator: "\n").first { $0.contains("state =") }?.trimmingCharacters(in: .whitespaces) ?? "state unknown"
            print("launchd agent: loaded (\(state))")
        } else {
            print("launchd agent: not loaded")
        }
        // Prefer the unified log (the system of record); `log show` can fail
        // for non-admin accounts, so the launchd-captured file below remains
        // the fallback.
        let (logStatus, logOut) = shell("/usr/bin/log", ["show", "--last", "30m",
            "--predicate", "subsystem == \"\(label)\"", "--style", "compact"])
        let entries = logOut.split(separator: "\n").dropFirst()
        if logStatus == 0, !entries.isEmpty {
            print("--- recent activity (unified log, last 30m) ---")
            entries.suffix(10).forEach { print($0) }
            return loaded ? 0 : 1
        }
        // Tail without materializing the whole log. Decode lossily - the
        // seek can land mid-scalar - and drop the first (possibly partial)
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
                print("--- last log lines ---")
                lines.suffix(10).forEach { print($0) }
            }
            try? fh.close()
        }
        return loaded ? 0 : 1
    }

    @discardableResult
    private static func shell(_ path: String, _ args: [String]) -> (Int32, String) {
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
    /// Modification date of the item at `path`, nil if unreadable.
    func modificationDate(atPath path: String) -> Date? {
        (try? attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Size in bytes of the item at `path`, nil if unreadable.
    func fileSize(atPath path: String) -> Int? {
        (try? attributesOfItem(atPath: path))?[.size] as? Int
    }
}

import Foundation

/// Installs/removes the launchd agent so tracking starts at login and stays
/// alive. The installed binary itself is what needs the Accessibility grant.
enum Installer {
    static let label = "com.hackclub.hackatime.xcode-hackatime"
    static var installDir: String { NSHomeDirectory() + "/.wakatime" }
    static var installedBinary: String { installDir + "/xcode-hackatime" }
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    static var logPath: String { installDir + "/xcode-hackatime.log" }

    static func install() -> Int32 {
        let fm = FileManager.default
        let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path

        do {
            try fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
            // Copy the binary to a stable path - a launchd agent pointing at a
            // build directory would break on the next `swift build` (and the
            // Accessibility grant is tied to the binary's location).
            if selfPath != installedBinary {
                if fm.fileExists(atPath: installedBinary) {
                    _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
                    try fm.removeItem(atPath: installedBinary)
                }
                try fm.copyItem(atPath: selfPath, toPath: installedBinary)
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
            try data.write(to: URL(fileURLWithPath: plistPath))

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
        try? fm.removeItem(atPath: cli)
        try? fm.createSymbolicLink(atPath: cli, withDestinationPath: installDir + "/\(asset)")
        print("wakatime-cli installed.")
    }

    private static func checkAPIKey() {
        let cfg = NSHomeDirectory() + "/.wakatime.cfg"
        let contents = (try? String(contentsOfFile: cfg, encoding: .utf8)) ?? ""
        if !contents.contains("api_key") {
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
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
        try? FileManager.default.removeItem(atPath: installedBinary)
        print("Uninstalled. You can also remove the Accessibility entry in System Settings.")
        return 0
    }

    static func status() -> Int32 {
        let (status, out) = shell("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])
        if status == 0 {
            let state = out.split(separator: "\n").first { $0.contains("state =") }?.trimmingCharacters(in: .whitespaces) ?? "state unknown"
            print("launchd agent: loaded (\(state))")
        } else {
            print("launchd agent: not loaded")
        }
        if let log = try? String(contentsOfFile: logPath, encoding: .utf8) {
            let tail = log.split(separator: "\n").suffix(10)
            print("--- last log lines ---")
            tail.forEach { print($0) }
        }
        return 0
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

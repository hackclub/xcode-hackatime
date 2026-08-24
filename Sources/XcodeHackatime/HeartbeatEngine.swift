import Foundation
import AppKit

/// Decides when editor activity becomes a WakaTime heartbeat and shells out
/// to wakatime-cli. Follows the standard plugin rule: send when the file
/// changed, when a write happened, or when ≥2 minutes passed since the last
/// heartbeat for the same file.
final class HeartbeatEngine {
    static let heartbeatInterval: TimeInterval = 120
    /// Minimum spacing between consecutive CLI invocations, so a burst of AX
    /// events can never fork more than one process per second.
    private static let minSpacing: TimeInterval = 1

    private let cliPath: String
    private let pluginString: String
    private let log: (String) -> Void

    private var lastFile: String?
    private var lastSent: Date = .distantPast
    private var lastMTime: [String: Date] = [:]
    private var lastLineCount: [String: Int] = [:]
    private var lastAttempt: Date = .distantPast

    init(log: @escaping (String) -> Void) {
        self.log = log

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.cliPath = "\(home)/.wakatime/wakatime-cli"

        let xcodeVersion = Self.installedXcodeVersion() ?? "unknown"
        self.pluginString = "xcode/\(xcodeVersion) xcode-hackatime/\(appVersion)"
    }

    var cliExists: Bool { FileManager.default.isExecutableFile(atPath: cliPath) }

    /// Snapshot the sensor state and send a heartbeat if policy says so.
    func consider(_ state: EditorState) {
        guard let file = state.filePath else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAttempt) >= Self.minSpacing else { return }
        lastAttempt = now

        let isWrite = fileWasModified(file)
        let fileChanged = file != lastFile
        let stale = now.timeIntervalSince(lastSent) >= Self.heartbeatInterval
        guard fileChanged || isWrite || stale else { return }

        // Net line change since the last save we saw: a single newline scan
        // of the file (never a diff), and only when a write landed on disk or
        // to establish a file's baseline - zero cost on ordinary heartbeats.
        var lineChanges: Int?
        if isWrite || lastLineCount[file] == nil, let count = lineCount(of: file) {
            if isWrite, let previous = lastLineCount[file], count != previous {
                lineChanges = count - previous
            }
            lastLineCount[file] = count
        }

        send(file: file, line: state.line, cursorOffset: state.cursorOffset, isWrite: isWrite, lineChanges: lineChanges)
        lastFile = file
        lastSent = now
    }

    /// Ground-truth write detection: the file's mtime on disk advanced since
    /// we last looked. Catches ⌘S and Xcode's autosave without needing any
    /// editor save event.
    private func fileWasModified(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        defer { lastMTime[path] = mtime }
        guard let previous = lastMTime[path] else { return false }
        return mtime > previous
    }

    /// Lines in the file, via a linear newline scan of the mapped bytes.
    private func lineCount(of path: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        if data.isEmpty { return 0 }
        var newlines = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for byte in buf where byte == 0x0A { newlines += 1 }
        }
        return newlines + 1
    }

    private func send(file: String, line: Int?, cursorOffset: Int?, isWrite: Bool, lineChanges: Int?) {
        var args = [
            "--entity", file,
            "--plugin", pluginString,
            "--category", "coding",
        ]
        if let line { args += ["--lineno", String(line)] }
        if let cursorOffset { args += ["--cursorpos", String(cursorOffset + 1)] }
        if isWrite { args.append("--write") }
        if let lineChanges { args += ["--human-line-changes", String(lineChanges)] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            log("heartbeat: \(file) line=\(line.map(String.init) ?? "-") pos=\(cursorOffset.map { String($0 + 1) } ?? "-") write=\(isWrite)\(lineChanges.map { " lines\($0 >= 0 ? "+" : "")\($0)" } ?? "")")
        } catch {
            log("failed to launch wakatime-cli: \(error)")
        }
    }

    private static func installedXcodeVersion() -> String? {
        let plist = "/Applications/Xcode.app/Contents/Info.plist"
        guard let dict = NSDictionary(contentsOfFile: plist) else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }
}

let appVersion = "0.2.2"

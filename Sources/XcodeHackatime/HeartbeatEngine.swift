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
    /// Writes whose send failed to launch, keyed by file, holding the unsent
    /// line delta. The mtime/line-count baselines advance as soon as a write
    /// is *observed*, so on failure the write signal must be carried here or
    /// it would be lost for the full heartbeat interval.
    private var pendingWrite: [String: Int] = [:]
    /// When the last editor event of any kind reached us.
    private var lastEvent: Date = .distantPast
    /// A save the user makes always rides an active event stream (typing
    /// fires AX events continuously; autosave lands mid-stream). An mtime
    /// advance first observed after this much event silence is an external
    /// change instead — git pull, a formatter, a generator reloading the
    /// buffer — and must not be credited as a user write.
    private static let externalChangeGap: TimeInterval = 60

    init(log: @escaping (String) -> Void) {
        self.log = log

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.cliPath = "\(home)/.wakatime/wakatime-cli"

        let xcodeVersion = Self.installedXcodeVersion() ?? "unknown"
        self.pluginString = "xcode/\(xcodeVersion) xcode-hackatime/\(appVersion)"
    }

    var cliExists: Bool { FileManager.default.isExecutableFile(atPath: cliPath) }

    /// Per-file baselines live for the agent's whole login session; reset
    /// them on the rare traversal of this many distinct files rather than
    /// growing without bound (a reset just re-establishes baselines).
    private static let maxTrackedFiles = 512

    /// Snapshot the sensor state and send a heartbeat if policy says so.
    func consider(_ state: EditorState) {
        guard let file = state.filePath else { return }
        if lastMTime.count > Self.maxTrackedFiles { lastMTime.removeAll() }
        if lastLineCount.count > Self.maxTrackedFiles { lastLineCount.removeAll() }
        if pendingWrite.count > Self.maxTrackedFiles { pendingWrite.removeAll() }
        let now = Date()
        guard now.timeIntervalSince(lastAttempt) >= Self.minSpacing else { return }
        lastAttempt = now

        let sinceLastEvent = now.timeIntervalSince(lastEvent)
        lastEvent = now
        var isWrite = fileWasModified(file)
        if isWrite, sinceLastEvent > Self.externalChangeGap {
            // External change: re-baseline the line count so the foreign
            // diff is never sent as the user's line delta, and drop the
            // write flag. (Trade-off: an autosave that lands just after the
            // user stops typing, noticed only after a long break, is also
            // reclassified — a rare cosmetic loss versus crediting entire
            // git pulls as coding.)
            isWrite = false
            if let count = lineCount(of: file) { lastLineCount[file] = count }
        }
        if pendingWrite[file] != nil { isWrite = true }
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
        if let unsentDelta = pendingWrite[file] {
            let merged = (lineChanges ?? 0) + unsentDelta
            lineChanges = merged == 0 ? nil : merged
        }

        // Only record the heartbeat as sent if the CLI actually launched.
        // The write signal was consumed above (baselines advanced), so on
        // failure carry it in pendingWrite for the next event to retry.
        guard send(file: file, line: state.line, cursorOffset: state.cursorOffset, isWrite: isWrite, lineChanges: lineChanges) else {
            if isWrite { pendingWrite[file] = lineChanges ?? 0 }
            return
        }
        pendingWrite.removeValue(forKey: file)
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

    /// Lines in the file, via a linear newline scan. Deliberately a plain
    /// read, not a mapping: we scan right after a write landed, and a mapped
    /// file truncated concurrently by another tool is a SIGBUS, not an error.
    /// Source files are small; the copy is cheap.
    private func lineCount(of path: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        if data.isEmpty { return 0 }
        var newlines = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for byte in buf where byte == 0x0A { newlines += 1 }
        }
        return newlines + 1
    }

    /// Returns true if wakatime-cli was launched (not whether it succeeded —
    /// that's reported asynchronously by the termination handler).
    private func send(file: String, line: Int?, cursorOffset: Int?, isWrite: Bool, lineChanges: Int?) -> Bool {
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
        // A bad API key or network trouble would otherwise be invisible: the
        // CLI's output is discarded, so at least report nonzero exits.
        process.terminationHandler = { [log] p in
            guard p.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                log("wakatime-cli exited with status \(p.terminationStatus) — check ~/.wakatime/wakatime.log and the api_key in ~/.wakatime.cfg")
            }
        }
        do {
            try process.run()
            log("heartbeat: \(file) line=\(line.map(String.init) ?? "-") pos=\(cursorOffset.map { String($0 + 1) } ?? "-") write=\(isWrite)\(lineChanges.map { " lines\($0 >= 0 ? "+" : "")\($0)" } ?? "")")
            return true
        } catch {
            log("failed to launch wakatime-cli: \(error)")
            return false
        }
    }

    private static func installedXcodeVersion() -> String? {
        // Resolve via Launch Services rather than a hardcoded path, so
        // Xcode-beta.app and relocated installs report correctly.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: XcodeObserver.xcodeBundleID) else { return nil }
        return Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}

let appVersion = "0.2.2"

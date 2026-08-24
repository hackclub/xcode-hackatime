import Foundation
import AppKit

/// Decides when editor activity becomes a WakaTime heartbeat and shells out
/// to wakatime-cli. Follows the standard plugin rule: send when the file
/// changed, when a write happened, or when ≥2 minutes passed since the last
/// heartbeat for the same file.
final class HeartbeatEngine {
    // MARK: - Tuning
    // How these dials relate to each other, to the observer's timers, and to
    // WriteClassifier's attribution windows is laid out in DESIGN.md.

    /// Same-file heartbeats at most this often (the standard plugin rule).
    static let heartbeatInterval: TimeInterval = 120
    /// Consecutive CLI forks at least this far apart; rejected sends are
    /// coalesced into pendingSendFiles, never dropped.
    private static let minSpacing: TimeInterval = 1
    /// Per-file baselines live for the agent's whole login session; reset
    /// past this count instead of growing without bound (a reset just
    /// re-establishes baselines).
    private static let maxTrackedFiles = 512
    /// The quiet-tick sweep covers files the user touched this recently.
    private static let sweepWindow: TimeInterval = 2 * WriteClassifier.saveSlack
    /// lineCount skips files past this size - it's synchronous I/O on the
    /// main run loop, and the line delta is optional metadata.
    private static let maxLineCountBytes = 10_000_000

    private let cliPath: String
    private let pluginString: String
    private let log: (String) -> Void
    /// A bad API key or network trouble would otherwise be invisible (the
    /// CLI's output is discarded), so nonzero exits are at least logged.
    private let reportCLIFailure: (Process) -> Void

    /// On-disk state last committed for a file. Baselines only advance when
    /// a heartbeat actually goes out (or an external change is deliberately
    /// swallowed), so a failed send re-detects the same write from the
    /// untouched baseline on the next event - no separate retry state.
    private struct FileBaseline {
        var mtime: Date?
        var lineCount: Int?
        /// When the user last acted in THIS file. Per-file, so activity in
        /// one file can never validate an external change to another.
        var lastActivity: Date?
    }
    private var baselines: [String: FileBaseline] = [:]
    private var lastFile: String?
    private var lastSent: Date = .distantPast
    private var lastAttempt: Date = .distantPast
    /// Send-worthy events rejected by the spacing cap, kept so they can be
    /// retried instead of silently dropped (a file switch followed by
    /// stillness, or a multi-file autosave batch draining one send per
    /// tick, would otherwise lose heartbeats).
    private var pendingSendFiles: Set<String> = []

    /// Test seam for the clock; policy around throttling, staleness, and
    /// write recency is untestable against the wall clock.
    var now: () -> Date = { Date() }
    /// Test seam: when set, replaces launching wakatime-cli (receives the
    /// argument list, returns whether the "launch" succeeded).
    var invokeCLIOverride: (([String]) -> Bool)?

    init(log: @escaping (String) -> Void) {
        self.log = log
        self.reportCLIFailure = { p in
            guard p.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                log("wakatime-cli exited with status \(p.terminationStatus) - check ~/.wakatime/wakatime.log and the api_key in ~/.wakatime.cfg")
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.cliPath = "\(home)/.wakatime/wakatime-cli"

        let xcodeVersion = Self.installedXcodeVersion() ?? "unknown"
        self.pluginString = "xcode/\(xcodeVersion) xcode-hackatime/\(appVersion)"
    }

    var cliExists: Bool { FileManager.default.isExecutableFile(atPath: cliPath) }

    /// Snapshot the sensor state and send a heartbeat if policy says so.
    /// `resolveLine` is called only when a heartbeat actually goes out — the
    /// AX document-prefix fetch behind it is the most expensive read, and
    /// most events end without sending.
    func consider(_ state: EditorState, resolveLine: () -> Int? = { nil }) {
        process(state, userAction: true, resolveLine: resolveLine)
    }

    /// Timer-driven disk check so a save that lands *after* the last editor
    /// event (type, ⌘S, walk away) is still credited. Only ever sends write
    /// heartbeats — a quiet tick is not activity.
    func pollDiskWrites(_ state: EditorState, resolveLine: () -> Int? = { nil }) {
        process(state, userAction: false, resolveLine: resolveLine)
        // Autosave can land on a file after the user switched away from it;
        // sweep recently-active files so those saves aren't missed (their
        // line/cursor is unknown by then — the write still counts).
        let cutoff = now().addingTimeInterval(-Self.sweepWindow)
        let recent = baselines.filter { ($0.value.lastActivity ?? .distantPast) > cutoff }.keys
        // Deferred sends are swept regardless of recency, or a batch that
        // drains one send per tick would age out of the window unsent.
        for file in Set(recent).union(pendingSendFiles) where file != state.filePath {
            process(EditorState(filePath: file, cursorOffset: nil), userAction: false, resolveLine: { nil })
        }
    }

    private func process(_ state: EditorState, userAction: Bool, resolveLine: () -> Int?) {
        guard let file = state.filePath else { return }
        evictIfNeeded()
        let now = repairedNow()

        // 1. Classify what the disk says happened to this file (the truth
        //    table lives on WriteClassifier).
        var baseline = baselines[file] ?? FileBaseline()
        let diskMTime = FileManager.default.modificationDate(atPath: file)
        let verdict = WriteClassifier.classify(diskMTime: diskMTime, baselineMTime: baseline.mtime,
                                               lastActivity: baseline.lastActivity,
                                               now: now, userAction: userAction)
        let isWrite = verdict == .userWrite
        switch verdict {
        case .baseline:
            baseline.mtime = diskMTime
            baselines[file] = baseline
        case .external:
            // Never attribute the foreign diff: advance the mtime and drop
            // the line baseline (it re-establishes on the next send).
            baseline.mtime = diskMTime
            baseline.lineCount = nil
            baselines[file] = baseline
        case .unchanged, .userWrite:
            break // a user write commits only on send success - see FileBaseline
        }
        if userAction {
            // A sensor fact, not send bookkeeping - commit immediately.
            // (mtime/lineCount in `baseline` are still pristine here.)
            baseline.lastActivity = now
            baselines[file] = baseline
        }

        // 2. Decide whether this deserves a heartbeat.
        let fileChanged = userAction && file != lastFile
        let stale = userAction && now.timeIntervalSince(lastSent) >= Self.heartbeatInterval
        guard fileChanged || isWrite || stale || pendingSendFiles.contains(file) else { return }

        // 3. Respect the CLI fork cap - coalescing, never dropping: the next
        //    event or quiet tick for the file retries a rejected send.
        guard now.timeIntervalSince(lastAttempt) >= Self.minSpacing else {
            pendingSendFiles.insert(file)
            return
        }
        lastAttempt = now

        // 4. Net line change since the last save we saw: a single newline
        //    scan (never a diff), and only when a write landed or to
        //    establish a baseline - zero cost on ordinary heartbeats.
        var lineChanges: Int?
        if isWrite || baseline.lineCount == nil, let count = lineCount(of: file) {
            if isWrite, let previous = baseline.lineCount, count != previous {
                lineChanges = count - previous
            }
            baseline.lineCount = count
        }

        // 5. Send, then commit - only on a successful launch (FileBaseline).
        guard send(file: file, line: resolveLine(), cursorOffset: state.cursorOffset, isWrite: isWrite, lineChanges: lineChanges) else { return }
        pendingSendFiles.remove(file)
        if isWrite, let diskMTime { baseline.mtime = diskMTime }
        baselines[file] = baseline
        lastFile = file
        lastSent = now
    }

    private func evictIfNeeded() {
        guard baselines.count > Self.maxTrackedFiles else { return }
        baselines.removeAll()
        pendingSendFiles.removeAll()
    }

    /// The wall clock, with backward corrections repaired: a negative jump
    /// would make every spacing check fail and suspend sends until real time
    /// catches up; one early heartbeat is the better failure mode.
    private func repairedNow() -> Date {
        let now = now()
        if now < lastAttempt { lastAttempt = .distantPast; lastSent = .distantPast }
        return now
    }

    /// Lines in the file, via a linear newline scan. Deliberately a plain
    /// read, not a mapping: we scan right after a write landed, and a mapped
    /// file truncated concurrently by another tool is a SIGBUS, not an error.
    /// Source files are small; the copy is cheap.
    private func lineCount(of path: String) -> Int? {
        guard let size = FileManager.default.fileSize(atPath: path), size <= Self.maxLineCountBytes,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        if data.isEmpty { return 0 }
        var newlines = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var cursor = buf.baseAddress!
            let end = cursor + buf.count
            while cursor < end, let hit = memchr(cursor, 0x0A, end - cursor) {
                newlines += 1
                cursor = UnsafeRawPointer(hit) + 1
            }
        }
        return newlines + 1
    }

    /// Returns true if wakatime-cli was launched - deliberately not whether
    /// it exited 0. Delivery retries are the CLI's job: it queues heartbeats
    /// offline and resends them itself, so re-sending from here on a nonzero
    /// exit would double-count whenever the CLI queued the heartbeat before
    /// failing. Nonzero exits are still surfaced via the termination handler.
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

        let launched: Bool
        if let invokeCLIOverride {
            launched = invokeCLIOverride(args)
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = reportCLIFailure
            do {
                try process.run()
                launched = true
            } catch {
                log("failed to launch wakatime-cli: \(error)")
                launched = false
            }
        }
        if launched {
            log("heartbeat: \(file) line=\(line.map(String.init) ?? "-") pos=\(cursorOffset.map { String($0 + 1) } ?? "-") write=\(isWrite)\(lineChanges.map { " lines\($0 >= 0 ? "+" : "")\($0)" } ?? "")")
        }
        return launched
    }

    private static func installedXcodeVersion() -> String? {
        // Prefer the Xcode that's actually running (the one we track);
        // fall back to Launch Services' default rather than a hardcoded
        // path, so Xcode-beta.app and relocated installs report correctly.
        let url = XcodeObserver.runningXcode()?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: XcodeObserver.xcodeBundleID)
        return url.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
    }
}

let appVersion = "0.2.2"

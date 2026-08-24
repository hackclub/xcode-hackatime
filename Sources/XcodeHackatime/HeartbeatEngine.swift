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
    /// A send-worthy event rejected by the spacing cap, kept so it can be
    /// retried instead of silently dropped (a file switch followed by
    /// stillness would otherwise never get its heartbeat).
    private var pendingSendFile: String?
    /// Write attribution: a disk change is the user's save only if it
    /// happened within `saveSlack` of their editing in that file (autosave
    /// trails the last keystroke), or — on a live event — within
    /// `recentWriteWindow` before now (⌘S right after a long pause). Both
    /// are bands, not one-sided cutoffs: an mtime far in the past (a tool
    /// preserving timestamps) or in the future (clock skew) is external.
    private static let saveSlack: TimeInterval = 60
    private static let recentWriteWindow: TimeInterval = 10

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

    /// Per-file baselines live for the agent's whole login session; reset
    /// them on the rare traversal of this many distinct files rather than
    /// growing without bound (a reset just re-establishes baselines).
    private static let maxTrackedFiles = 512

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
        let cutoff = now().addingTimeInterval(-2 * Self.saveSlack)
        for (file, baseline) in baselines
        where file != state.filePath && (baseline.lastActivity ?? .distantPast) > cutoff {
            process(EditorState(filePath: file, cursorOffset: nil), userAction: false, resolveLine: { nil })
        }
    }

    private func process(_ state: EditorState, userAction: Bool, resolveLine: () -> Int?) {
        guard let file = state.filePath else { return }
        if baselines.count > Self.maxTrackedFiles { baselines.removeAll() }
        let now = now()
        // A backward wall-clock correction would otherwise make every
        // spacing check negative and suspend sends until the clock catches
        // up; one early heartbeat is the better failure mode.
        if now < lastAttempt { lastAttempt = .distantPast; lastSent = .distantPast }

        // Ground-truth write detection: the file's mtime on disk advanced
        // since the committed baseline. Catches ⌘S and Xcode's autosave
        // without needing any editor save event.
        var baseline = baselines[file] ?? FileBaseline()
        let diskMTime = FileManager.default.modificationDate(atPath: file)
        var isWrite = false
        if let diskMTime {
            if let previous = baseline.mtime {
                if diskMTime > previous {
                    // See the saveSlack/recentWriteWindow doc for the rules.
                    let duringActivity = baseline.lastActivity.map {
                        abs(diskMTime.timeIntervalSince($0)) <= Self.saveSlack
                    } ?? false
                    let freshNow = userAction
                        && (-1...Self.recentWriteWindow).contains(now.timeIntervalSince(diskMTime))
                    if duringActivity || freshNow {
                        isWrite = true
                    } else {
                        // External change. Swallow it: advance the mtime and
                        // drop the line-count baseline so the foreign diff is
                        // never sent as the user's line delta.
                        baseline.mtime = diskMTime
                        baseline.lineCount = nil
                        baselines[file] = baseline
                    }
                } else if diskMTime < previous {
                    // Replaced with older content (checkout, restore, a
                    // timestamp-preserving tool): external. Re-baseline, or
                    // the stale line count would be charged against the
                    // user's next save.
                    baseline.mtime = diskMTime
                    baseline.lineCount = nil
                    baselines[file] = baseline
                }
            } else {
                // First sighting: nothing to defer yet, baseline immediately.
                baseline.mtime = diskMTime
                baselines[file] = baseline
            }
        }
        if userAction {
            // A sensor fact, not send bookkeeping - commit immediately.
            // (mtime/lineCount in `baseline` are still pristine here; write
            // commits stay deferred to send success below.)
            baseline.lastActivity = now
            baselines[file] = baseline
        }

        let fileChanged = userAction && file != lastFile
        let stale = userAction && now.timeIntervalSince(lastSent) >= Self.heartbeatInterval
        guard fileChanged || isWrite || stale || pendingSendFile == file else { return }

        // The spacing cap applies to CLI invocations, not policy evaluation:
        // a no-op event must never consume the slot of a send-worthy one.
        // And a send-worthy event it does reject is coalesced, not dropped —
        // the next event or quiet tick for the file retries it.
        guard now.timeIntervalSince(lastAttempt) >= Self.minSpacing else {
            pendingSendFile = file
            return
        }
        lastAttempt = now

        // Net line change since the last save we saw: a single newline scan
        // of the file (never a diff), and only when a write landed on disk or
        // to establish a file's baseline - zero cost on ordinary heartbeats.
        var lineChanges: Int?
        if isWrite || baseline.lineCount == nil, let count = lineCount(of: file) {
            if isWrite, let previous = baseline.lineCount, count != previous {
                lineChanges = count - previous
            }
            baseline.lineCount = count
        }

        // Commit only on a successful launch - see FileBaseline.
        guard send(file: file, line: resolveLine(), cursorOffset: state.cursorOffset, isWrite: isWrite, lineChanges: lineChanges) else { return }
        if pendingSendFile == file { pendingSendFile = nil }
        if isWrite, let diskMTime { baseline.mtime = diskMTime }
        baselines[file] = baseline
        lastFile = file
        lastSent = now
    }

    /// Lines in the file, via a linear newline scan. Deliberately a plain
    /// read, not a mapping: we scan right after a write landed, and a mapped
    /// file truncated concurrently by another tool is a SIGBUS, not an error.
    /// Source files are small; the copy is cheap.
    /// Skip absurdly large files: this runs synchronously on the main run
    /// loop, and the line delta is optional metadata not worth a stall.
    private static let maxLineCountBytes = 10_000_000

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

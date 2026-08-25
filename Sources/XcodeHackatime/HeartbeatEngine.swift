import AppKit
import Foundation

/// turns editor activity into wakatime-cli heartbeats: send when the file
/// changed, when a write landed, or heartbeatInterval after the last
/// heartbeat for the same file
final class HeartbeatEngine {
    // MARK: - Tuning
    // DESIGN.md lays out how these dials relate to the observer's timers and
    // WriteClassifier's attribution windows

    /// official plugins use 120; we use 30
    static let heartbeatInterval: TimeInterval = 30
    /// cli forks stay at least this far apart; rejected sends coalesce into
    /// pendingSendFiles, never drop
    private static let minSpacing: TimeInterval = 1
    /// baselines live for the agent's whole login session; past this count
    /// they reset instead of growing without bound
    private static let maxTrackedFiles = 512
    private static let sweepWindow: TimeInterval = 2 * WriteClassifier.saveSlack
    /// the line count is synchronous I/O on the main run loop and the delta
    /// is optional metadata, so skip files past this size
    private static let maxLineCountBytes = 10_000_000

    private let cliPath: String
    private let log: (String) -> Void
    /// the engine discards cli output, so nonzero exits (bad api key,
    /// network trouble) would otherwise be invisible
    private let reportCLIFailure: (Process) -> Void

    /// last committed on-disk state. baselines advance only when a heartbeat
    /// actually launches, so a failed send re-detects the same write from
    /// the untouched baseline on the next event, with no separate retry state
    private struct FileBaseline {
        var mtime: Date?
        var lineCount: Int?
        /// per-file, so activity in one file can never validate an external
        /// change to another
        var lastActivity: Date?
        /// pins a write whose send did not launch, so continued editing
        /// cannot drift it out of the attribution band before a retry lands
        var unsentWrite = false
    }
    private var baselines: [String: FileBaseline] = [:]
    private var lastFile: String?
    private var lastSent: Date = .distantPast
    private var lastAttempt: Date = .distantPast
    /// send-worthy events the spacing cap rejected; dropping them would lose
    /// a file switch followed by stillness, or the tail of a multi-file
    /// autosave batch draining one send per tick
    private var pendingSendFiles: Set<String> = []

    /// test seam: throttling, staleness and write recency are untestable
    /// against the wall clock
    var now: () -> Date = { Date() }
    /// test seam replacing the cli launch
    var invokeCLIOverride: (([String]) -> Bool)?

    init(log: @escaping (String) -> Void) {
        self.log = log
        self.reportCLIFailure = { p in
            guard p.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                log(
                    "warning: wakatime-cli exited with status \(p.terminationStatus) - check ~/.wakatime/wakatime.log and the api_key in ~/.wakatime.cfg"
                )
            }
        }

        self.cliPath = Installer.wakatimeCLIPath
    }

    /// plugin metadata resolved against the Xcode running right now (the
    /// agent can start before Xcode, and the user can switch to Xcode-beta
    /// mid-session), cached per bundle url so ordinary sends do not re-read
    /// Info.plist
    private var cachedPlugin: (url: URL?, string: String)?
    /// main wires the resolution chain; the engine knows nothing about Xcode
    /// discovery
    var attachedXcodeBundleURL: () -> URL? = { nil }
    private func pluginString() -> String {
        let url = attachedXcodeBundleURL()
        if let cached = cachedPlugin, cached.url == url { return cached.string }
        let version =
            url.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "unknown"
        let string = "xcode/\(version) xcode-hackatime/\(appVersion)"
        cachedPlugin = (url, string)
        return string
    }

    var cliExists: Bool { FileManager.default.isExecutableFile(atPath: cliPath) }

    /// `resolvePosition` runs only when a heartbeat actually sends: the AX
    /// document-prefix fetch behind it is the most expensive read, and most
    /// events end without sending
    func consider(_ state: EditorState, resolvePosition: () -> (line: Int, column: Int)? = { nil }) {
        process(state, userAction: true, resolvePosition: resolvePosition)
    }

    /// timer-driven disk check, crediting a save that lands after the last
    /// editor event. only ever sends write heartbeats: a quiet tick is not
    /// activity
    func pollDiskWrites(_ state: EditorState, resolvePosition: () -> (line: Int, column: Int)? = { nil }) {
        process(state, userAction: false, resolvePosition: resolvePosition)
        // autosave can land after the user switched away, so sweep recently
        // active files (their line/cursor is unknown by then; the write
        // still counts). deferred sends sweep regardless of recency, or a
        // batch draining one send per tick would age out unsent
        let cutoff = now().addingTimeInterval(-Self.sweepWindow)
        let recent = baselines.filter { ($0.value.lastActivity ?? .distantPast) > cutoff }.keys
        for file in pendingSendFiles.union(recent) where file != state.filePath {
            process(EditorState(filePath: file, cursorOffset: nil), userAction: false, resolvePosition: { nil })
        }
    }

    private func process(_ state: EditorState, userAction: Bool, resolvePosition: () -> (line: Int, column: Int)?) {
        guard let file = state.filePath else { return }
        evictIfNeeded()
        let now = repairedNow()

        var baseline = baselines[file] ?? FileBaseline()
        let diskMTime = FileManager.default.modificationDate(atPath: file)
        let verdict = WriteClassifier.classify(
            diskMTime: diskMTime, baselineMTime: baseline.mtime,
            lastActivity: baseline.lastActivity,
            now: now, userAction: userAction)
        let isWrite = verdict == .userWrite || baseline.unsentWrite
        switch verdict {
        case .baseline:
            baseline.mtime = diskMTime
            baselines[file] = baseline
        case .external where baseline.unsentWrite:
            // the user's earlier write whose send failed, drifted out of the
            // band while retries continued; not actually external
            break
        case .external:
            // never attribute the foreign diff, but measure it now so the
            // user's next save deltas against the external content. clamp a
            // future stamp (a pre-correction save seen after the clock moved
            // back) to now, or the poisoned baseline would swallow the next
            // save too
            baseline.mtime = diskMTime.map { min($0, now) }
            baseline.lineCount = lineCount(of: file)
            baselines[file] = baseline
        case .unchanged, .userWrite:
            break  // a user write commits only on send success
        }
        if userAction {
            // a sensor fact, not send bookkeeping; commit immediately
            baseline.lastActivity = now
            baselines[file] = baseline
        }

        let fileChanged = userAction && file != lastFile
        let stale = userAction && now.timeIntervalSince(lastSent) >= Self.heartbeatInterval
        guard fileChanged || isWrite || stale || pendingSendFiles.contains(file) else { return }

        guard now.timeIntervalSince(lastAttempt) >= Self.minSpacing else {
            deferSend(file, isWrite: isWrite)
            return
        }
        lastAttempt = now

        // a single newline scan, never a diff, and only when a write landed
        // or no baseline exists; ordinary heartbeats pay nothing
        var lineChanges: Int?
        if isWrite || baseline.lineCount == nil, let count = lineCount(of: file) {
            if isWrite, let previous = baseline.lineCount, count != previous {
                lineChanges = count - previous
            }
            baseline.lineCount = count
        }
        // symmetric paste guard: a jump past 50 lines in one save (either
        // direction) is a paste, a generation or a bulk delete, not typing;
        // drop the delta, keep the write. a live external cleanup once
        // sailed through as -99 when only positive jumps were guarded
        if let changes = lineChanges, abs(changes) > 50 { lineChanges = nil }

        guard
            send(
                file: file, position: resolvePosition(), isWrite: isWrite,
                lineChanges: lineChanges, linesInFile: baseline.lineCount)
        else {
            deferSend(file, isWrite: isWrite)
            return
        }
        pendingSendFiles.remove(file)
        baseline.unsentWrite = false
        if isWrite, let diskMTime { baseline.mtime = diskMTime }
        baselines[file] = baseline
        lastFile = file
        lastSent = now
    }

    /// the one owner of the defer invariant (DESIGN.md decision 13): a
    /// rejected send joins pendingSendFiles and, when it carried a write,
    /// pins unsentWrite
    private func deferSend(_ file: String, isWrite: Bool) {
        pendingSendFiles.insert(file)
        if isWrite { baselines[file, default: FileBaseline()].unsentWrite = true }
    }

    private func evictIfNeeded() {
        guard baselines.count > Self.maxTrackedFiles else { return }
        baselines.removeAll()
        pendingSendFiles.removeAll()
    }

    /// newest clock reading ever observed. regression is detected against
    /// this, not lastAttempt: unsent activity advances per-file stamps
    /// without advancing lastAttempt, and a rollback into that gap must
    /// still trigger the repair
    private var lastObservedNow: Date = .distantPast

    /// wall clock with backward corrections repaired. a negative jump would
    /// make every spacing check fail and suspend sends until real time
    /// catches up; one early heartbeat is the better failure mode
    private func repairedNow() -> Date {
        let now = now()
        defer { lastObservedNow = now }
        if now < lastObservedNow {
            lastAttempt = .distantPast
            lastSent = .distantPast
            // per-file stamps carry the old (now future) time domain too: a
            // future mtime baseline misclassifies the next save as external,
            // and a future activity stamp breaks the attribution band
            for (file, var baseline) in baselines {
                if let mtime = baseline.mtime, mtime > now {
                    baseline.mtime = now.addingTimeInterval(-WriteClassifier.recentWriteWindow)
                }
                if let activity = baseline.lastActivity, activity > now {
                    baseline.lastActivity = now
                }
                baselines[file] = baseline
            }
        }
        return now
    }

    /// counts newlines with a plain read, deliberately not a mapping: a
    /// mapped file that another tool truncates concurrently is a SIGBUS,
    /// not an error
    private func lineCount(of path: String) -> Int? {
        guard let size = FileManager.default.fileSize(atPath: path), size <= Self.maxLineCountBytes,
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return nil }
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

    /// true means wakatime-cli launched, deliberately not that it exited 0:
    /// the cli queues heartbeats offline and retries itself, so a re-send
    /// from here on a nonzero exit would double-count. the termination
    /// handler still surfaces nonzero exits
    private func send(
        file: String, position: (line: Int, column: Int)?, isWrite: Bool,
        lineChanges: Int?, linesInFile: Int?
    ) -> Bool {
        var args = [
            "--entity", file,
            "--plugin", pluginString(),
            "--category", "coding",
        ]
        if let project = projectRoot(for: file) {
            // fallback name and workspace path for folders the cli cannot
            // detect itself (it detects vcs projects on its own)
            args += ["--alternate-project", project.name]
            args += ["--project-folder", project.folder]
        }
        if let position {
            args += ["--lineno", String(position.line)]
            // cursorpos is wakatime's 1-based column, not a document offset
            args += ["--cursorpos", String(position.column)]
        }
        if isWrite { args.append("--write") }
        if let lineChanges { args += ["--human-line-changes", String(lineChanges)] }
        // the delta already counted lines; passing the total spares the cli
        // its own read of the file
        if let linesInFile { args += ["--lines-in-file", String(linesInFile)] }

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
            log(
                "heartbeat: \(file)\(position.map { " \($0.line):\($0.column)" } ?? "") write=\(isWrite)\(lineChanges.map { " lines\($0 >= 0 ? "+" : "")\($0)" } ?? "")"
            )
        }
        return launched
    }

    /// nearest ancestor directory that looks like a project root, cached per
    /// file directory so ordinary sends do not touch the filesystem.
    /// --alternate-project is the cli's fallback for folders without version
    /// control (vscode-wakatime passes its workspace name the same way)
    private var projectRootCache: [String: (name: String, folder: String)?] = [:]
    private func projectRoot(for file: String) -> (name: String, folder: String)? {
        let dir = (file as NSString).deletingLastPathComponent
        if let cached = projectRootCache[dir] { return cached }
        if projectRootCache.count > Self.maxTrackedFiles { projectRootCache.removeAll() }
        let fm = FileManager.default
        var current = dir
        var root: (name: String, folder: String)?
        for _ in 0..<12 {
            if current == "/" || current == NSHomeDirectory() { break }
            let entries = (try? fm.contentsOfDirectory(atPath: current)) ?? []
            let looksLikeRoot = entries.contains { entry in
                entry == ".git" || entry == "Package.swift" || entry == ".wakatime-project"
                    || entry.hasSuffix(".xcodeproj") || entry.hasSuffix(".xcworkspace")
            }
            if looksLikeRoot {
                root = (name: (current as NSString).lastPathComponent, folder: current)
                break
            }
            current = (current as NSString).deletingLastPathComponent
        }
        projectRootCache[dir] = root
        return root
    }
}

let appVersion = "0.3.0"

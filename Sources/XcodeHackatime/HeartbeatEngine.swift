import AppKit
import Foundation

/// decides when editor activity becomes a WakaTime heartbeat and shells out
/// to wakatime-cli. it follows the standard plugin rule: send when the file
/// changed, when a write happened or when ≥2 minutes passed since the last
/// heartbeat for the same file.
final class HeartbeatEngine {
    // MARK: - Tuning
    // DESIGN.md lays out how these dials relate to each other, to the
    // observer's timers and to WriteClassifier's attribution windows.

    /// same-file heartbeats go out at most this often (the standard plugin rule).
    static let heartbeatInterval: TimeInterval = 120
    /// consecutive CLI forks stay at least this far apart. the engine
    /// coalesces rejected sends into pendingSendFiles, never drops them.
    private static let minSpacing: TimeInterval = 1
    /// per-file baselines live for the agent's whole login session. past
    /// this count the engine resets them instead of growing without bound
    /// (a reset just re-establishes baselines).
    private static let maxTrackedFiles = 512
    /// the quiet-tick sweep covers files the user touched this recently.
    private static let sweepWindow: TimeInterval = 2 * WriteClassifier.saveSlack
    /// lineCount skips files past this size. the read is synchronous I/O on
    /// the main run loop, and the line delta is optional metadata.
    private static let maxLineCountBytes = 10_000_000

    private let cliPath: String
    private let log: (String) -> Void
    /// a bad API key or network trouble would otherwise be invisible (the
    /// engine discards the CLI's output), so it at least logs nonzero exits.
    private let reportCLIFailure: (Process) -> Void

    /// the on-disk state last committed for a file. baselines advance only
    /// when a heartbeat actually goes out (or when the engine deliberately
    /// swallows an external change). a failed send therefore re-detects the
    /// same write from the untouched baseline on the next event, with no
    /// separate retry state.
    private struct FileBaseline {
        var mtime: Date?
        var lineCount: Int?
        /// when the user last acted in THIS file. it is per-file, so activity
        /// in one file can never validate an external change to another.
        var lastActivity: Date?
        /// a user write whose send did not launch. this pins classification
        /// so continued editing cannot drift the unsent write out of the
        /// attribution band and into "external" before a retry lands.
        var unsentWrite = false
    }
    private var baselines: [String: FileBaseline] = [:]
    private var lastFile: String?
    private var lastSent: Date = .distantPast
    private var lastAttempt: Date = .distantPast
    /// send-worthy events that the spacing cap rejected. the engine keeps
    /// them and retries them instead of silently dropping them. without
    /// this, a file switch followed by stillness, or a multi-file autosave
    /// batch that drains one send per tick, would lose heartbeats.
    private var pendingSendFiles: Set<String> = []

    /// test seam for the clock. policy around throttling, staleness and
    /// write recency is untestable against the wall clock.
    var now: () -> Date = { Date() }
    /// test seam: when set, it replaces launching wakatime-cli (it receives
    /// the argument list and returns whether the "launch" succeeded).
    var invokeCLIOverride: (([String]) -> Bool)?

    init(log: @escaping (String) -> Void) {
        self.log = log
        self.reportCLIFailure = { p in
            guard p.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                log(
                    "wakatime-cli exited with status \(p.terminationStatus) - check ~/.wakatime/wakatime.log and the api_key in ~/.wakatime.cfg"
                )
            }
        }

        self.cliPath = Installer.wakatimeCLIPath
    }

    /// the plugin metadata for heartbeats. resolved against the Xcode that
    /// runs right now (the agent can start before Xcode, and the user can
    /// switch to Xcode-beta mid-session), cached per bundle URL so ordinary
    /// sends do not re-read Info.plist.
    private var cachedPlugin: (url: URL?, string: String)?
    /// the bundle URL of the Xcode the heartbeats come from. main wires the
    /// full resolution chain (attached instance, then any running one, then
    /// Launch Services' default); the engine itself knows nothing about
    /// Xcode discovery.
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

    /// snapshot the sensor state and send a heartbeat if policy says so.
    /// the engine calls `resolvePosition` only when a heartbeat actually
    /// goes out. the AX document-prefix fetch behind it is the most
    /// expensive read, and most events end without sending.
    func consider(_ state: EditorState, resolvePosition: () -> (line: Int, column: Int)? = { nil }) {
        process(state, userAction: true, resolvePosition: resolvePosition)
    }

    /// timer-driven disk check. it credits a save that lands *after* the
    /// last editor event (type, ⌘S, walk away). it only ever sends write
    /// heartbeats, because a quiet tick is not activity.
    func pollDiskWrites(_ state: EditorState, resolvePosition: () -> (line: Int, column: Int)? = { nil }) {
        process(state, userAction: false, resolvePosition: resolvePosition)
        // autosave can land on a file after the user switched away from it.
        // the sweep covers recently-active files so those saves are not
        // missed (their line/cursor is unknown by then, but the write still
        // counts).
        let cutoff = now().addingTimeInterval(-Self.sweepWindow)
        let recent = baselines.filter { ($0.value.lastActivity ?? .distantPast) > cutoff }.keys
        // the sweep covers deferred sends regardless of recency. otherwise a
        // batch that drains one send per tick would age out of the window
        // unsent.
        for file in pendingSendFiles.union(recent) where file != state.filePath {
            process(EditorState(filePath: file, cursorOffset: nil), userAction: false, resolvePosition: { nil })
        }
    }

    private func process(_ state: EditorState, userAction: Bool, resolvePosition: () -> (line: Int, column: Int)?) {
        guard let file = state.filePath else { return }
        evictIfNeeded()
        let now = repairedNow()

        // 1. classify what the disk says happened to this file (the truth
        //    table lives on WriteClassifier).
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
            // not actually external: the user's earlier write whose send
            // failed. it drifted out of the band while retries continued.
            break
        case .external:
            // never attribute the foreign diff, but measure it now. the
            // user's next save then deltas against the external content
            // instead of losing its delta entirely. external changes are
            // rare; one read here is fine. clamp a future stamp (a
            // pre-correction save seen after the clock moved back) to now,
            // or the poisoned baseline would swallow the user's next save
            // too.
            baseline.mtime = diskMTime.map { min($0, now) }
            baseline.lineCount = lineCount(of: file)
            baselines[file] = baseline
        case .unchanged, .userWrite:
            break  // a user write commits only on send success; see FileBaseline
        }
        if userAction {
            // a sensor fact, not send bookkeeping: commit immediately.
            // (mtime/lineCount in `baseline` are still pristine here.)
            baseline.lastActivity = now
            baselines[file] = baseline
        }

        // 2. decide whether this deserves a heartbeat.
        let fileChanged = userAction && file != lastFile
        let stale = userAction && now.timeIntervalSince(lastSent) >= Self.heartbeatInterval
        guard fileChanged || isWrite || stale || pendingSendFiles.contains(file) else { return }

        // 3. respect the CLI fork cap. coalesce, never drop: the next
        //    event or quiet tick for the file retries a rejected send.
        guard now.timeIntervalSince(lastAttempt) >= Self.minSpacing else {
            deferSend(file, isWrite: isWrite)
            return
        }
        lastAttempt = now

        // 4. net line change since the last save we saw: a single newline
        //    scan (never a diff). it runs only when a write landed or to
        //    establish a baseline, so ordinary heartbeats pay zero cost.
        var lineChanges: Int?
        if isWrite || baseline.lineCount == nil, let count = lineCount(of: file) {
            if isWrite, let previous = baseline.lineCount, count != previous {
                lineChanges = count - previous
            }
            baseline.lineCount = count
        }
        // paste guard, symmetric: a jump of more than 50 lines in one save
        // (either direction) is a paste, a generation or a bulk delete, not
        // typing. drop the delta; the write heartbeat itself still counts.
        // (proven live: an external cleanup once sailed through as -99 when
        // only positive jumps were guarded.)
        if let changes = lineChanges, abs(changes) > 50 { lineChanges = nil }

        // 5. send, then commit, only on a successful launch (FileBaseline).
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
    /// rejected send joins pendingSendFiles AND, when it carried a write,
    /// pins unsentWrite so retries cannot drift it into the external band.
    private func deferSend(_ file: String, isWrite: Bool) {
        pendingSendFiles.insert(file)
        if isWrite { baselines[file, default: FileBaseline()].unsentWrite = true }
    }

    private func evictIfNeeded() {
        guard baselines.count > Self.maxTrackedFiles else { return }
        baselines.removeAll()
        pendingSendFiles.removeAll()
    }

    /// the wall clock, with backward corrections repaired. a negative jump
    /// would make every spacing check fail and suspend sends until real time
    /// catches up. one early heartbeat is the better failure mode.
    /// the newest clock reading ever observed. the regression detector
    /// compares against this, not lastAttempt: unsent activity advances
    /// per-file stamps without advancing lastAttempt, and a rollback into
    /// that gap must still trigger the repair.
    private var lastObservedNow: Date = .distantPast

    private func repairedNow() -> Date {
        let now = now()
        defer { lastObservedNow = now }
        if now < lastObservedNow {
            lastAttempt = .distantPast
            lastSent = .distantPast
            // per-file stamps carry the old (now future) time domain too: a
            // future mtime baseline would misclassify the next save as
            // external (new-domain mtimes sort below it), and a future
            // activity stamp breaks the attribution band. clamp both into
            // the present so post-correction saves keep their write credit.
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

    /// lines in the file, via a linear newline scan. this is deliberately a
    /// plain read, not a mapping: we scan right after a write landed, and a
    /// mapped file that another tool truncates concurrently is a SIGBUS, not
    /// an error. source files are small; the copy is cheap.
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

    /// returns true if wakatime-cli launched, deliberately not whether it
    /// exited 0. delivery retries are the CLI's job: it queues heartbeats
    /// offline and resends them itself. a re-send from here on a nonzero
    /// exit would double-count whenever the CLI queued the heartbeat before
    /// failing. the termination handler still surfaces nonzero exits.
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
            // the CLI detects VCS projects itself; these are the fallback
            // name and the workspace path for folders it cannot detect.
            args += ["--alternate-project", project.name]
            args += ["--project-folder", project.folder]
        }
        if let position {
            args += ["--lineno", String(position.line)]
            // cursorpos is WakaTime's 1-based column, not a document offset.
            args += ["--cursorpos", String(position.column)]
        }
        if isWrite { args.append("--write") }
        if let lineChanges { args += ["--human-line-changes", String(lineChanges)] }
        // we already counted lines for the delta; passing the total spares
        // the CLI its own read of the file.
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

    /// project-name fallback for wakatime-cli. the CLI detects git projects
    /// itself; --alternate-project covers folders without version control
    /// (vscode-wakatime passes its workspace name the same way). we use the
    /// name of the nearest ancestor directory that looks like a project
    /// root, cached per file directory so ordinary sends do not touch the
    /// filesystem.
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

import XCTest

@testable import xcode_hackatime

/// policy tests for HeartbeatEngine.consider: throttling, staleness, write
/// detection and classification, delta computation and commit-on-success.
/// the engine's test seams inject the clock and the CLI launch;
/// files are real temp files so mtime/line-count reads exercise real I/O.
final class HeartbeatEngineTests: XCTestCase {
    private var engine: HeartbeatEngine!
    private var sentArgs: [[String]] = []
    private var launchSucceeds = true
    private var clock: Date!
    private var dir: URL!

    override func setUp() {
        super.setUp()
        clock = Date(timeIntervalSince1970: 1_000_000)
        sentArgs = []
        launchSucceeds = true
        engine = HeartbeatEngine(log: { _ in })
        engine.now = { [unowned self] in clock }
        engine.invokeCLIOverride = { [unowned self] args in
            if launchSucceeds { sentArgs.append(args) }
            return launchSucceeds
        }
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hb-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeFile(_ name: String, lines: Int, mtime: Date) -> String {
        let path = dir.appendingPathComponent(name).path
        rewrite(path, lines: lines, mtime: mtime)
        return path
    }

    private func setMTime(_ path: String, _ date: Date) {
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    private func rewrite(_ path: String, lines: Int, mtime: Date) {
        let content = Array(repeating: "line", count: lines).joined(separator: "\n")
        try! Data(content.utf8).write(to: URL(fileURLWithPath: path))
        setMTime(path, mtime)
    }

    private func consider(_ path: String) {
        engine.consider(EditorState(filePath: path, cursorOffset: 0))
    }

    private func poll(_ path: String) {
        engine.pollDiskWrites(EditorState(filePath: path, cursorOffset: 0))
    }

    private func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    private var lastSend: [String]? { sentArgs.last }

    // MARK: - Send policy

    func testFirstConsiderOfFileSends() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)
        XCTAssertEqual(sentArgs.count, 1)
        XCTAssertFalse(lastSend!.contains("--write"), "first sighting is not a write")
    }

    func testSendsWithinMinSpacingAreDeferred() {
        let a = makeFile("a.swift", lines: 3, mtime: clock)
        let b = makeFile("b.swift", lines: 3, mtime: clock)
        consider(a)
        advance(0.5)
        consider(b)  // send-worthy (file change), but within the CLI fork cap
        XCTAssertEqual(sentArgs.count, 1)
    }

    func testNoopEventDoesNotConsumeTheSendSlot() {
        let a = makeFile("a.swift", lines: 3, mtime: clock)
        let b = makeFile("b.swift", lines: 3, mtime: clock)
        consider(a)  // sends
        advance(1.1)
        consider(a)  // no-op: nothing send-worthy
        advance(0.1)
        consider(b)  // file change, 1.2s after the last actual send
        XCTAssertEqual(sentArgs.count, 2, "a no-op event must not throttle the next real send")
        XCTAssertTrue(lastSend!.contains(b))
    }

    func testSameFileNotStaleDoesNotResend() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)
        advance(30)
        consider(file)
        XCTAssertEqual(sentArgs.count, 1)
    }

    func testStaleFileResends() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)
        advance(HeartbeatEngine.heartbeatInterval + 1)
        consider(file)
        XCTAssertEqual(sentArgs.count, 2)
    }

    func testFileChangeSends() {
        let a = makeFile("a.swift", lines: 3, mtime: clock)
        let b = makeFile("b.swift", lines: 3, mtime: clock)
        consider(a)
        advance(2)
        consider(b)
        XCTAssertEqual(sentArgs.count, 2)
        XCTAssertTrue(lastSend!.contains(b))
    }

    // MARK: - Write classification

    func testFreshMTimeAdvanceIsUserWriteWithLineDelta() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)  // establishes baselines (send: fileChanged)
        advance(30)
        rewrite(file, lines: 8, mtime: clock.addingTimeInterval(-1))  // saved a moment ago
        consider(file)
        XCTAssertEqual(sentArgs.count, 2)
        XCTAssertTrue(lastSend!.contains("--write"))
        XCTAssertEqual(value(of: "--human-line-changes", in: lastSend!), "5")
    }

    func testStaleMTimeAdvanceIsExternalChange() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)
        advance(300)
        // changed on disk minutes ago, first noticed now: git pull, not ⌘S.
        rewrite(file, lines: 100, mtime: clock.addingTimeInterval(-200))
        consider(file)
        // a stale heartbeat still goes out (>120s), but without write credit.
        XCTAssertEqual(sentArgs.count, 2)
        XCTAssertFalse(lastSend!.contains("--write"))
        XCTAssertNil(value(of: "--human-line-changes", in: lastSend!))
        // and the foreign diff never surfaces as a later delta either.
        advance(30)
        rewrite(file, lines: 101, mtime: clock.addingTimeInterval(-1))
        consider(file)
        XCTAssertEqual(
            value(of: "--human-line-changes", in: lastSend!), "1",
            "delta must be measured from the post-external baseline")
    }

    func testSaveAfterLongPauseStillCountsAsWrite() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)
        advance(600)  // user walks away
        rewrite(file, lines: 4, mtime: clock.addingTimeInterval(-2))  // ⌘S on return
        consider(file)
        XCTAssertTrue(lastSend!.contains("--write"))
    }

    func testLargePasteDeltaIsDropped() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)
        advance(30)
        rewrite(file, lines: 200, mtime: clock.addingTimeInterval(-1))  // paste, not typing
        consider(file)
        XCTAssertTrue(lastSend!.contains("--write"))
        XCTAssertNil(
            value(of: "--human-line-changes", in: lastSend!),
            "vscode-wakatime parity: >50-line jumps carry no human delta")
    }

    func testLargeDeletionDeltaIsDropped() {
        let file = makeFile("a.swift", lines: 200, mtime: clock)
        consider(file)
        advance(30)
        rewrite(file, lines: 3, mtime: clock.addingTimeInterval(-1))  // bulk delete, not typing
        consider(file)
        XCTAssertTrue(lastSend!.contains("--write"))
        XCTAssertNil(
            value(of: "--human-line-changes", in: lastSend!),
            "the paste guard is symmetric: -197 is no more typed than +197")
    }

    // MARK: - Commit-on-success

    func testFailedLaunchRetriesTheSameWrite() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)
        advance(30)
        rewrite(file, lines: 8, mtime: clock.addingTimeInterval(-1))
        launchSucceeds = false
        consider(file)  // launch fails; nothing may be committed
        XCTAssertEqual(sentArgs.count, 1)
        launchSucceeds = true
        advance(2)
        consider(file)
        XCTAssertEqual(sentArgs.count, 2)
        XCTAssertTrue(lastSend!.contains("--write"), "write signal must survive a failed launch")
        XCTAssertEqual(value(of: "--human-line-changes", in: lastSend!), "5")
    }

    func testClockRegressionAfterUnsentActivityStillRepairs() {
        let a = makeFile("a.swift", lines: 3, mtime: clock)
        consider(a)  // sends at t0
        advance(110)
        consider(a)  // no send, but records activity at t110
        clock = clock.addingTimeInterval(-109)  // corrected back to t1
        advance(5)
        rewrite(a, lines: 8, mtime: clock.addingTimeInterval(-1))  // quiet save at t6
        poll(a)
        XCTAssertTrue(
            lastSend!.contains("--write"),
            "the repair must trigger on any backward step, not only past lastAttempt")
        XCTAssertEqual(value(of: "--human-line-changes", in: lastSend!), "5")
    }

    func testPreservedHistoricalMTimeIsExternal() {
        let file = makeFile("a.swift", lines: 3, mtime: clock.addingTimeInterval(-1))
        consider(file)
        advance(200)
        consider(file)  // stale send keeps the user's per-file activity fresh
        advance(30)
        // a tool replaced the file and preserved an old timestamp: newer than
        // the baseline, but far from any user activity in either direction.
        rewrite(file, lines: 100, mtime: clock.addingTimeInterval(-180))
        consider(file)
        XCTAssertEqual(sentArgs.count, 2, "historical mtime must be swallowed as external")
    }

    func testFutureMTimeIsExternal() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)
        advance(30)
        rewrite(file, lines: 100, mtime: clock.addingTimeInterval(300))  // bogus future stamp
        consider(file)
        XCTAssertEqual(sentArgs.count, 1, "future mtime must be swallowed as external")
    }

    func testActivityInOneFileDoesNotValidateWritesInAnother() {
        let a = makeFile("a.swift", lines: 3, mtime: clock)
        let b = makeFile("b.swift", lines: 3, mtime: clock)
        consider(b)  // b's activity baseline is established here, then goes stale
        advance(2)
        consider(a)  // user works in a
        advance(120)
        // b changed on disk mid-way: during a's activity, but not b's.
        rewrite(b, lines: 100, mtime: clock.addingTimeInterval(-30))
        poll(b)
        XCTAssertEqual(sentArgs.count, 2, "activity in a must not credit b's external change")
    }

    func testDeferredSendIsCoalescedNotDropped() {
        let a = makeFile("a.swift", lines: 3, mtime: clock)
        let b = makeFile("b.swift", lines: 3, mtime: clock)
        consider(a)  // sends
        advance(0.5)
        consider(b)  // send-worthy, rejected by the fork cap; must be kept
        XCTAssertEqual(sentArgs.count, 1)
        advance(20)
        poll(b)  // the next quiet tick flushes the deferred send
        XCTAssertEqual(sentArgs.count, 2)
        XCTAssertTrue(lastSend!.contains(b))
    }

    func testBackwardMTimeResetsBaseline() {
        let file = makeFile("a.swift", lines: 3, mtime: clock.addingTimeInterval(-1))
        consider(file)
        advance(30)
        // checkout/restore: 100-line content stamped with an OLD mtime.
        rewrite(file, lines: 100, mtime: clock.addingTimeInterval(-500))
        consider(file)
        XCTAssertEqual(sentArgs.count, 1, "backward mtime is external, not a send trigger")
        advance(2)
        rewrite(file, lines: 103, mtime: clock.addingTimeInterval(-1))  // real user save: +3 lines
        consider(file)
        XCTAssertTrue(lastSend!.contains("--write"))
        XCTAssertEqual(
            value(of: "--human-line-changes", in: lastSend!), "3",
            "the user's +3 survives; the foreign 97-line diff does not")
    }

    func testClockRegressionDoesNotSuspendSends() {
        let a = makeFile("a.swift", lines: 3, mtime: clock)
        let b = makeFile("b.swift", lines: 3, mtime: clock)
        consider(a)
        clock = clock.addingTimeInterval(-3600)  // wall clock corrected backward
        consider(b)
        XCTAssertEqual(sentArgs.count, 2, "a clock correction must not suspend tracking")
    }

    func testSaveAfterClockRegressionKeepsWriteCredit() {
        let a = makeFile("a.swift", lines: 3, mtime: clock)
        let b = makeFile("b.swift", lines: 3, mtime: clock)
        consider(a)  // a's baselines stamped in the old (soon future) domain
        advance(2)
        clock = clock.addingTimeInterval(-3600)
        consider(b)  // triggers the repair; a's stamps are clamped
        advance(30)
        rewrite(a, lines: 8, mtime: clock.addingTimeInterval(-1))  // post-correction save
        consider(a)
        XCTAssertTrue(
            lastSend!.contains("--write"),
            "the first save after a clock correction must keep its write credit")
        XCTAssertEqual(value(of: "--human-line-changes", in: lastSend!), "5")
    }

    func testPollSweepsRecentlyActiveBackgroundFile() {
        let a = makeFile("a.swift", lines: 3, mtime: clock)
        let b = makeFile("b.swift", lines: 3, mtime: clock)
        consider(a)
        advance(2)
        consider(b)  // focus moves to b; a is now a background file
        advance(10)
        rewrite(a, lines: 8, mtime: clock.addingTimeInterval(-1))  // autosave lands on a
        poll(b)  // quiet tick sweeps recently-active files, not just the focused one
        XCTAssertEqual(sentArgs.count, 3)
        XCTAssertTrue(lastSend!.contains(a))
        XCTAssertTrue(lastSend!.contains("--write"))
        XCTAssertEqual(value(of: "--human-line-changes", in: lastSend!), "5")
    }

    func testBatchOfBackgroundWritesDrainsAcrossTicks() {
        let a = makeFile("a.swift", lines: 3, mtime: clock)
        let b = makeFile("b.swift", lines: 3, mtime: clock)
        let c = makeFile("c.swift", lines: 3, mtime: clock)
        consider(a)
        advance(2)
        consider(b)
        advance(2)
        consider(c)  // three sends; a and b are now background files
        advance(5)
        for f in [a, b] { rewrite(f, lines: 8, mtime: clock) }  // save-all lands at once
        advance(5)
        poll(c)  // tick 1: one background write sends, the other is deferred
        XCTAssertEqual(sentArgs.count, 4)
        advance(20)
        poll(c)  // tick 2: the deferred write drains instead of aging out
        XCTAssertEqual(sentArgs.count, 5)
        let writes = sentArgs.suffix(2)
        XCTAssertTrue(writes.allSatisfy { $0.contains("--write") })
        XCTAssertEqual(Set(writes.compactMap { value(of: "--entity", in: $0) }), Set([a, b]))
    }

    func testAlternateProjectDerivedFromProjectRoot() {
        let proj = dir.appendingPathComponent("SparrowMail")
        try! FileManager.default.createDirectory(
            at: proj.appendingPathComponent("Sources"),
            withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: proj.appendingPathComponent("Package.swift").path,
            contents: Data())
        let file = proj.appendingPathComponent("Sources/App.swift").path
        FileManager.default.createFile(atPath: file, contents: Data("hi".utf8))
        setMTime(file, clock)
        consider(file)
        XCTAssertEqual(value(of: "--alternate-project", in: lastSend!), "SparrowMail")
        XCTAssertEqual(value(of: "--project-folder", in: lastSend!), proj.path)
    }

    func testLinesInFileIsPassedWhenKnown() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)  // first send establishes the count
        XCTAssertEqual(value(of: "--lines-in-file", in: lastSend!), "3")
        advance(30)
        rewrite(file, lines: 8, mtime: clock.addingTimeInterval(-1))
        consider(file)
        XCTAssertEqual(value(of: "--lines-in-file", in: lastSend!), "8")
    }

    func testNoAlternateProjectWithoutProjectRoot() {
        let file = makeFile("loose.swift", lines: 3, mtime: clock)
        consider(file)
        XCTAssertNil(value(of: "--alternate-project", in: lastSend!))
    }

    // MARK: - Quiet-tick disk polling

    func testPollSendsSaveThatLandedAfterLastEvent() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)  // user activity establishes baselines
        advance(30)
        // ⌘S landed 25s ago, just after the user's last event. no AX event
        // followed it; only the timer poll notices.
        rewrite(file, lines: 8, mtime: clock.addingTimeInterval(-25))
        poll(file)
        XCTAssertEqual(sentArgs.count, 2)
        XCTAssertTrue(lastSend!.contains("--write"))
        XCTAssertEqual(value(of: "--human-line-changes", in: lastSend!), "5")
    }

    func testPollNeverSendsPlainHeartbeat() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)
        advance(HeartbeatEngine.heartbeatInterval + 60)  // stale, but no write
        poll(file)
        XCTAssertEqual(sentArgs.count, 1, "a quiet tick is not activity")
    }

    func testPollSwallowsIdleExternalChange() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)
        advance(300)
        // changed on disk 200s after the user's last activity: git pull.
        rewrite(file, lines: 100, mtime: clock.addingTimeInterval(-100))
        poll(file)
        XCTAssertEqual(sentArgs.count, 1, "external change on a quiet tick must not send")
    }

    func testWriteSurvivesProlongedLaunchFailureWhileEditing() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        consider(file)
        advance(30)
        rewrite(file, lines: 8, mtime: clock.addingTimeInterval(-1))
        launchSucceeds = false
        consider(file)  // write detected, launch fails
        // the user keeps editing; retries keep failing far past saveSlack,
        // which would drift the unsent write into the external band.
        for _ in 0..<10 {
            advance(10)
            consider(file)
        }
        launchSucceeds = true
        advance(10)
        consider(file)
        XCTAssertTrue(
            lastSend!.contains("--write"),
            "an unsent write must never drift into the external band")
        XCTAssertEqual(value(of: "--human-line-changes", in: lastSend!), "5")
    }

    // MARK: - Args

    func testLineAndColumnArePassedThrough() {
        let file = makeFile("a.swift", lines: 3, mtime: clock)
        engine.consider(
            EditorState(filePath: file, cursorOffset: 41),
            resolvePosition: { (line: 7, column: 12) })
        XCTAssertEqual(value(of: "--lineno", in: lastSend!), "7")
        XCTAssertEqual(
            value(of: "--cursorpos", in: lastSend!), "12",
            "cursorpos is the 1-based column, never the document offset")
        XCTAssertEqual(value(of: "--entity", in: lastSend!), file)
    }

    private func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

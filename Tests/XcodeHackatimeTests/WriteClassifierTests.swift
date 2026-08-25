import XCTest

@testable import xcode_hackatime

/// pins the classification itself; HeartbeatEngineTests covers what a
/// verdict does to baselines and sends
final class WriteClassifierTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func verdict(
        disk: TimeInterval?, baseline: TimeInterval?, activity: TimeInterval?,
        now: TimeInterval, userAction: Bool
    ) -> WriteClassifier.Verdict {
        WriteClassifier.classify(
            diskMTime: disk.map(at), baselineMTime: baseline.map(at),
            lastActivity: activity.map(at), now: at(now), userAction: userAction)
    }

    func testUnreadableFileIsUnchanged() {
        XCTAssertEqual(verdict(disk: nil, baseline: 0, activity: 0, now: 10, userAction: true), .unchanged)
    }

    func testFirstSightingEstablishesBaseline() {
        XCTAssertEqual(verdict(disk: 5, baseline: nil, activity: nil, now: 10, userAction: true), .baseline)
    }

    func testEqualMTimeIsUnchanged() {
        XCTAssertEqual(verdict(disk: 5, baseline: 5, activity: 5, now: 10, userAction: true), .unchanged)
    }

    func testOlderMTimeIsExternal() {
        // checkout/restore stamped older content over a newer baseline
        XCTAssertEqual(verdict(disk: 2, baseline: 5, activity: 6, now: 10, userAction: true), .external)
    }

    func testSaveDuringActivityIsUserWrite() {
        // autosave trails the last keystroke by a few seconds
        XCTAssertEqual(verdict(disk: 105, baseline: 5, activity: 100, now: 130, userAction: false), .userWrite)
    }

    func testFreshMTimeOnLiveEventIsUserWrite() {
        // cmd-S right after a long pause: no recent per-file activity, but
        // the mtime is seconds old and a user event is in flight
        XCTAssertEqual(verdict(disk: 998, baseline: 5, activity: 100, now: 1000, userAction: true), .userWrite)
    }

    func testFreshMTimeOnQuietTickIsExternal() {
        // same freshness with nobody driving: git pull while away
        XCTAssertEqual(verdict(disk: 998, baseline: 5, activity: 100, now: 1000, userAction: false), .external)
    }

    func testStaleMTimeFarFromActivityIsExternal() {
        // changed on disk minutes after the user stopped editing
        XCTAssertEqual(verdict(disk: 400, baseline: 5, activity: 100, now: 700, userAction: true), .external)
    }

    func testHistoricalMTimeDuringActivityIsExternal() {
        // newer than the baseline but far older than the user's activity:
        // a timestamp-preserving tool, not a save
        XCTAssertEqual(verdict(disk: 50, baseline: 5, activity: 400, now: 405, userAction: true), .external)
    }

    func testFutureMTimeIsExternal() {
        XCTAssertEqual(verdict(disk: 700, baseline: 5, activity: 100, now: 400, userAction: true), .external)
    }
}

import Foundation

/// classifies an observed on-disk mtime against a file's committed baseline
/// and the user's activity in that file. pure (no clock, no filesystem), so
/// the truth table is directly testable.
///
/// for disk mtime `m`, committed baseline `b`, per-file last user activity
/// `a`, current time `t` and whether the observation rides a user-driven
/// event:
///
/// | Condition                                        | Verdict     |
/// |--------------------------------------------------|-------------|
/// | `m` unreadable (deleted, permissions)            | .unchanged  |
/// | `b == nil`                                       | .baseline   |
/// | `m == b`                                         | .unchanged  |
/// | `m < b` (checkout/restore stamped older content) | .external   |
/// | `m > b`, `|m - a| <= saveSlack`                  | .userWrite  |
/// | `m > b`, user event, `-1s <= t - m <= recentWriteWindow` | .userWrite |
/// | `m > b`, otherwise                               | .external   |
///
/// the two user-write rows are how saves actually happen: cmd-S and autosave
/// land during or just after the user's editing in that file, and a cmd-S
/// right after a long pause shows up as a fresh mtime on a live event.
/// everything else is external (git pull, a formatter, a generator, a tool
/// that preserves historical timestamps, a future mtime from clock skew)
enum WriteClassifier {
    /// cmd-S/autosave lands within this long of the user's editing in the file
    static let saveSlack: TimeInterval = 60
    /// on a live user event, an mtime at most this old is the user's save
    /// even without recent per-file activity (return-from-break cmd-S); the
    /// -1s lower bound tolerates sub-second skew, nothing more
    static let recentWriteWindow: TimeInterval = 10

    enum Verdict {
        /// no committed baseline yet; establish one
        case baseline
        case unchanged
        /// the user's save: send --write with the line delta
        case userWrite
        /// changed on disk outside the user's editing: advance the baseline,
        /// never attribute the diff
        case external
    }

    static func classify(
        diskMTime: Date?, baselineMTime: Date?, lastActivity: Date?,
        now: Date, userAction: Bool
    ) -> Verdict {
        guard let diskMTime else { return .unchanged }
        guard let baselineMTime else { return .baseline }
        if diskMTime == baselineMTime { return .unchanged }
        if diskMTime < baselineMTime { return .external }
        let duringActivity =
            lastActivity.map {
                abs(diskMTime.timeIntervalSince($0)) <= saveSlack
            } ?? false
        let freshNow =
            userAction
            && (-1...recentWriteWindow).contains(now.timeIntervalSince(diskMTime))
        return duringActivity || freshNow ? .userWrite : .external
    }
}

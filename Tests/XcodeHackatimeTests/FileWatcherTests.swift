import XCTest

@testable import xcode_hackatime

/// the preferences watcher must survive cfprefsd-style atomic replaces
/// (write to a temp file, rename over the target): a naive per-fd watch
/// dies with the replaced inode. the assertion is precise: a write to the
/// REPLACEMENT file must be observed, which only a reattached watcher can
/// do (the attach-time courtesy fire cannot satisfy it).
final class FileWatcherTests: XCTestCase {
    func testWatcherSurvivesAtomicReplace() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("prefs.plist").path
        FileManager.default.createFile(atPath: target, contents: Data("a".utf8))

        var finalWriteHappened = false
        let observedAfterReplace = expectation(description: "write to the replacement file observed")
        observedAfterReplace.assertForOverFulfill = false
        Installer.watchFile(target) {
            if finalWriteHappened { observedAfterReplace.fulfill() }
        }

        // atomic replace, cfprefsd style.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let tmp = dir.appendingPathComponent("tmp").path
            FileManager.default.createFile(atPath: tmp, contents: Data("b".utf8))
            _ = rename(tmp, target)
        }
        // give the watcher past its 1s reattach delay, then write to the
        // replacement file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            finalWriteHappened = true
            let handle = FileHandle(forWritingAtPath: target)!
            handle.seekToEndOfFile()
            handle.write(Data("c".utf8))
            try? handle.close()
        }
        wait(for: [observedAfterReplace], timeout: 10)
    }
}

import XCTest

@testable import xcode_hackatime

/// the preferences watcher must survive cfprefsd-style atomic replaces
/// (write to a temp file, rename over the target): a naive per-fd watch
/// dies with the replaced inode.
final class FileWatcherTests: XCTestCase {
    func testWatcherSurvivesAtomicReplace() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("prefs.plist").path
        FileManager.default.createFile(atPath: target, contents: Data("a".utf8))

        let changed = expectation(description: "changes observed across a replace")
        changed.expectedFulfillmentCount = 2
        changed.assertForOverFulfill = false
        Installer.watchFile(target) { changed.fulfill() }

        // in-place append (plain write event)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let handle = FileHandle(forWritingAtPath: target)!
            handle.seekToEndOfFile()
            handle.write(Data("b".utf8))
            try? handle.close()
        }
        // atomic replace, then a write to the REPLACEMENT file: only a
        // reattached watcher can see it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let tmp = dir.appendingPathComponent("tmp").path
            FileManager.default.createFile(atPath: tmp, contents: Data("c".utf8))
            _ = rename(tmp, target)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            try? Data("d".utf8).write(to: URL(fileURLWithPath: target))
        }
        wait(for: [changed], timeout: 10)
    }
}

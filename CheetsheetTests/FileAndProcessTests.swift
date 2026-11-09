import Foundation
import Testing
@testable import Cheetsheet

/// Running programs, caching by file, and watching folders.
struct ProcessRunnerTests {
    @Test func returnsOutput() {
        #expect(ProcessRunner.run("/bin/echo", ["hello"]) == "hello\n")
    }

    @Test func failureIsNilUnlessAllowed() {
        #expect(ProcessRunner.run("/usr/bin/false", []) == nil)
        #expect(ProcessRunner.run("/usr/bin/false", [], requireSuccess: false) == "")
        #expect(ProcessRunner.run("/nonexistent/program", []) == nil)
    }

    @Test func stopsAfterTimeout() {
        let start = Date()
        #expect(ProcessRunner.run("/bin/sleep", ["10"], timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func stopsWhenABackgroundProcessKeepsTheOutputOpen() {
        // The shell exits at once, but the sleep it leaves behind still holds the pipe.
        let start = Date()
        #expect(ProcessRunner.run("/bin/sh", ["-c", "sleep 10 & echo started"], timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func returnsLargeOutput() {
        // More than a pipe holds, so it must be read while the program runs.
        let output = ProcessRunner.run("/bin/sh", ["-c", "yes cheetsheet | head -n 100000"])
        #expect(output?.count == 100_000 * 11)
    }

    @Test func passesEnvironment() {
        #expect(ProcessRunner.run("/bin/sh", ["-c", "printf %s \"$CHEETSHEET_TEST\""],
                                  environment: ["CHEETSHEET_TEST": "yes"]) == "yes")
    }
}

/// A fresh temporary folder per test, removed afterwards.
final class TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appending(path: "cheetsheet-tests-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

struct TildePathTests {
    @Test func shortensOnlyPathsInsideHome() {
        #expect(ConfigFolder.tildePath("/Users/bob/.vimrc", home: "/Users/bob") == "~/.vimrc")
        #expect(ConfigFolder.tildePath("/Users/bob", home: "/Users/bob/") == "~")
        #expect(ConfigFolder.tildePath("/Users/bobby/dotfiles/vimrc", home: "/Users/bob") == "/Users/bobby/dotfiles/vimrc")
    }
}

struct ConfigCacheTests {
    @Test func recomputesOnlyWhenTheFileChanges() throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "vimrc")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        let cache = ConfigCache<Int>()
        var runs = 0

        #expect(cache.value(for: [file]) { runs += 1; return runs } == 1)
        #expect(cache.value(for: [file]) { runs += 1; return runs } == 1)  // unchanged: cached

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
        #expect(cache.value(for: [file]) { runs += 1; return runs } == 2)  // edited: recomputed
    }

    @Test func failedRunsAreNotCached() throws {
        let cache = ConfigCache<Int>()
        let file = URL(fileURLWithPath: "/nonexistent")
        #expect(cache.value(for: [file]) { nil } == nil)
        #expect(cache.value(for: [file]) { 7 } == 7)
    }
}

@MainActor
struct FolderWatcherTests {
    /// Waits up to two seconds for `condition`, letting the main queue deliver file events.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func seesFilesSavedInTheFolder() async throws {
        let folder = try TemporaryFolder()
        var changes = 0
        let watcher = FolderWatcher(folder.url) { changes += 1 }
        try "{}".write(to: folder.url.appending(path: "sheet.json"), atomically: true, encoding: .utf8)
        #expect(await eventually { changes > 0 })
        withExtendedLifetime(watcher) {}
    }

    @Test func seesEditsBehindSymlinks() async throws {
        // Like GNU Stow: the watched folder holds a link into a dotfiles folder.
        let watched = try TemporaryFolder(), dotfiles = try TemporaryFolder()
        let real = dotfiles.url.appending(path: "config.json")
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: watched.url.appending(path: "config.json"), withDestinationURL: real)

        var changes = 0
        let watcher = FolderWatcher(watched.url) { changes += 1 }
        try #"{"holdDelay": 1}"#.write(to: real, atomically: true, encoding: .utf8)
        #expect(await eventually { changes > 0 })
        withExtendedLifetime(watcher) {}
    }

    @Test func seesFilesWrittenInPlace() async throws {
        // Writing into the existing file (not replacing it) doesn't change the folder.
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "config.json")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        var changes = 0
        let watcher = FolderWatcher(folder.url) { changes += 1 }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(#"{"holdDelay": 1}"#.utf8))
        try handle.close()
        #expect(await eventually { changes > 0 })
        withExtendedLifetime(watcher) {}
    }

    @Test func keepsWatchingAfterTheFolderIsReplaced() async throws {
        let parent = try TemporaryFolder()
        let folder = parent.url.appending(path: "cheetsheet")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var changes = 0
        let watcher = FolderWatcher(folder) { changes += 1 }

        // Re-stowing deletes and recreates the folder.
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(await eventually { changes > 0 })
        try? await Task.sleep(for: .seconds(2.5))  // let the watcher pick the new folder up
        let before = changes
        try "{}".write(to: folder.appending(path: "sheet.json"), atomically: true, encoding: .utf8)
        #expect(await eventually { changes > before })
        withExtendedLifetime(watcher) {}
    }
}

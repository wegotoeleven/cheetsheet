import Foundation
import Synchronization

/// Runs the command line programs Cheetsheet reads bindings from (tmux, vim, ghostty).
nonisolated enum ProcessRunner {
    /// GUI apps don't get the shell's PATH, so look for a program in the usual install locations.
    static func find(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/run/current-system/sw/bin",
                "\(home)/.nix-profile/bin", "\(home)/.local/bin", "/usr/bin"]
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a program and returns what it printed, or nil if it failed, couldn't start,
    /// or was still running after `timeout` seconds (it's stopped then, so a stuck tmux
    /// server or a vimrc waiting for input can't hold anything up).
    /// With `requireSuccess` false, output is returned even when the program exits with an
    /// error code (vim does that when a vimrc has a harmless error).
    static func run(_ path: String, _ arguments: [String], environment: [String: String] = [:],
                    timeout: TimeInterval = 5, requireSuccess: Bool = true) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        // Output is collected as it arrives, so a full pipe never blocks the program, and the
        // wait below has a deadline. A blocking read could wait forever: it only ends once
        // every process holding the pipe has gone, including anything the program started.
        let data = Mutex(Data())
        let readAll = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        let reader = output.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                readAll.signal()
            } else {
                data.withLock { $0.append(chunk) }
            }
        }
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            reader.readabilityHandler = nil
            return nil
        }

        let deadline = DispatchTime.now() + timeout
        guard exited.wait(timeout: deadline) == .success, readAll.wait(timeout: deadline) == .success else {
            // Too slow: stop listening, ask it to quit, and force it a second later.
            reader.readabilityHandler = nil
            try? reader.close()
            let pid = process.processIdentifier
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
            return nil
        }

        guard process.terminationReason == .exit, process.terminationStatus == 0 || !requireSuccess else { return nil }
        return String(decoding: data.withLock { $0 }, as: UTF8.self)
    }

    /// The modification dates of some files, for telling whether a config changed.
    /// Symlinks are followed, so an edit in a dotfiles repo counts.
    static func modificationDates(_ urls: [URL]) -> [String: Date] {
        var dates: [String: Date] = [:]
        for url in urls {
            let real = url.resolvingSymlinksInPath()
            dates[url.path] = (try? FileManager.default.attributesOfItem(atPath: real.path))?[.modificationDate] as? Date
                ?? .distantPast
        }
        return dates
    }
}

/// Keeps a value worked out from some config files until one of them changes (or `maxAge`
/// passes, for changes it can't see, like a file the config includes). Used so the
/// overlay doesn't re-run vim or ghostty every time it opens.
nonisolated final class ConfigCache<Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let key: [String: Date]
        let value: Value
        let time: Date
    }
    // A Mutex makes this safe to use from several background threads at once.
    private let entry = Mutex<Entry?>(nil)
    private let maxAge: TimeInterval

    init(maxAge: TimeInterval = 300) { self.maxAge = maxAge }

    /// The cached value if `files` are unchanged, otherwise `compute()`'s result (cached
    /// only when it isn't nil, so a failed run is retried next time).
    func value(for files: [URL], compute: () -> Value?) -> Value? {
        let key = ProcessRunner.modificationDates(files)
        if let cached = entry.withLock({ $0 }), cached.key == key, Date().timeIntervalSince(cached.time) < maxAge {
            return cached.value
        }
        guard let value = compute() else { return nil }
        entry.withLock { $0 = Entry(key: key, value: value, time: Date()) }
        return value
    }
}

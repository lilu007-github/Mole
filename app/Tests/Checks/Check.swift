import Foundation

/// A tiny check runner. Command Line Tools ship neither XCTest nor Swift
/// Testing, so app/scripts/run-checks.sh compiles Burrow's sources together
/// with these files into one executable and runs it.
@MainActor
enum Checks {
    struct Case {
        let suite: String
        let name: String
        let live: Bool
        let body: @MainActor () async throws -> Void
    }

    struct Skip: Error {
        let reason: String
    }

    private(set) static var cases: [Case] = []
    private static var failures: [String] = []

    /// - Parameter live: runs the real Mole CLI (dry runs only); skipped when BURROW_SKIP_LIVE=1.
    static func add(_ suite: String, _ name: String, live: Bool = false,
                    _ body: @escaping @MainActor () async throws -> Void) {
        cases.append(Case(suite: suite, name: name, live: live, body: body))
    }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                       file: StaticString = #fileID, line: UInt = #line) {
        if !condition { failures.append("\(file):\(line): \(message())") }
    }

    /// Runs every case whose "suite/name" contains `filter`; returns the exit status.
    static func run(filter: String?) async -> Int32 {
        let skipLive = ProcessInfo.processInfo.environment["BURROW_SKIP_LIVE"] == "1"
        var passed = 0, failed = 0, skipped = 0
        for check in cases {
            let label = "\(check.suite)/\(check.name)"
            if let filter, !label.localizedCaseInsensitiveContains(filter) { continue }
            if check.live && skipLive {
                print("SKIP \(label) (BURROW_SKIP_LIVE=1)")
                skipped += 1
                continue
            }
            failures = []
            let started = Date()
            do {
                try await check.body()
            } catch let skip as Skip {
                print("SKIP \(label) (\(skip.reason))")
                skipped += 1
                continue
            } catch {
                failures.append("threw \(error)")
            }
            let seconds = String(format: "%.1fs", Date().timeIntervalSince(started))
            if failures.isEmpty {
                print("PASS \(label) \(seconds)")
                passed += 1
            } else {
                print("FAIL \(label) \(seconds)")
                failures.forEach { print("     \($0)") }
                failed += 1
            }
        }
        print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
        return failed == 0 ? 0 : 1
    }
}

/// Shorthand used by the suites.
@MainActor
func expect(_ condition: Bool, _ message: @autoclosure () -> String,
            file: StaticString = #fileID, line: UInt = #line) {
    Checks.expect(condition, message(), file: file, line: line)
}

/// A fresh temporary folder, removed when the runner exits.
func makeFixtureDir(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("burrow-checks-\(ProcessInfo.processInfo.processIdentifier)")
        .appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func removeFixtures() {
    try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
        .appendingPathComponent("burrow-checks-\(ProcessInfo.processInfo.processIdentifier)"))
}

/// Feeds text through the terminal parser in small chunks, like a live pipe.
func parse(_ text: String, chunk: Int = 7) -> [String] {
    let bytes = Data(text.utf8)
    var parser = TerminalTextParser()
    var lines: [String] = []
    var current = ""
    var pending = Data()
    var index = 0
    while index < bytes.count {
        let end = min(index + chunk, bytes.count)
        pending.append(bytes[index..<end])
        index = end
        let cut = pending.count - TerminalTextParser.incompleteUTF8Suffix(pending)
        parser.feed(String(decoding: pending.prefix(cut), as: UTF8.self), lines: &lines, current: &current)
        pending = Data(pending.suffix(from: pending.startIndex + cut))
    }
    return current.isEmpty ? lines : lines + [current]
}

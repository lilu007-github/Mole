import AppKit
import Foundation

/// A launchd job from a LaunchAgents or LaunchDaemons folder. Read-only:
/// Burrow lists and explains; `mo optimize` repairs broken background items.
struct StartupItem: Identifiable, Hashable {
    enum Scope: String, CaseIterable {
        case user = "当前用户", allUsers = "所有用户", system = "系统级"
    }

    enum State: String {
        case running = "运行中", loaded = "已加载", notLoaded = "未加载", disabled = "已停用", broken = "程序缺失"
    }

    var label: String
    var plist: URL
    var scope: Scope
    /// The executable it launches (Program or ProgramArguments[0]).
    var program: String?
    var programExists: Bool
    var runAtLoad: Bool
    var keepAlive: Bool
    var state: State
    var pid: Int?
    /// The app it belongs to, when one can be found.
    var app: URL?
    var id: String { plist.path }

    var appName: String? { app.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } }
}

enum StartupItems {
    nonisolated(unsafe) static var folders: [(StartupItem.Scope, String)] = [
        (.user, NSHomeDirectory() + "/Library/LaunchAgents"),
        (.allUsers, "/Library/LaunchAgents"),
        (.system, "/Library/LaunchDaemons"),
    ]

    static func scan() -> [StartupItem] {
        let userJobs = userDomainJobs()
        var items: [StartupItem] = []
        for (scope, folder) in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasSuffix(".plist") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { continue }
                let label = dict["Label"] as? String ?? (name as NSString).deletingPathExtension
                let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
                let exists = program.map { FileManager.default.fileExists(atPath: $0) } ?? true
                let keepAlive = (dict["KeepAlive"] as? Bool) ?? (dict["KeepAlive"] is [String: Any])
                var state: StartupItem.State
                var pid: Int?
                if !exists {
                    state = .broken
                } else if dict["Disabled"] as? Bool == true {
                    state = .disabled
                } else if scope == .system {
                    state = systemJobLoaded(label) ? .loaded : .notLoaded
                } else if let job = userJobs[label] {
                    pid = job
                    state = job > 0 ? .running : .loaded
                } else {
                    state = .notLoaded
                }
                items.append(StartupItem(label: label, plist: url, scope: scope, program: program, programExists: exists,
                                         runAtLoad: dict["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
                                         state: state, pid: pid, app: owningApp(label: label, program: program)))
            }
        }
        return items.sorted { ($0.state == .broken ? 0 : 1, $0.label) < ($1.state == .broken ? 0 : 1, $1.label) }
    }

    /// `launchctl list` for the user's GUI domain: label → pid (0 when loaded but idle).
    static func userDomainJobs() -> [String: Int] {
        guard let output = run("/bin/launchctl", ["list"]) else { return [:] }
        var jobs: [String: Int] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: "\t")
            guard fields.count == 3 else { continue }
            jobs[String(fields[2])] = Int(fields[0]) ?? 0
        }
        return jobs
    }

    /// `launchctl print system/<label>` succeeds without admin rights for loaded daemons.
    static func systemJobLoaded(_ label: String) -> Bool {
        run("/bin/launchctl", ["print", "system/\(label)"]) != nil
    }

    /// The app inside the program path, or one whose bundle id prefixes the label.
    static func owningApp(label: String, program: String?) -> URL? {
        if let program, let range = program.range(of: ".app/") {
            return URL(fileURLWithPath: String(program[..<range.lowerBound]) + ".app")
        }
        var parts = label.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) {
                return app
            }
            parts.removeLast()
        }
        return nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

import Foundation

/// Locates the Mole CLI and runs its machine-readable commands.
///
/// Burrow never deletes anything itself: every destructive action goes through
/// `mo`, so the CLI's protection lists, dry-run parity and operation log apply.
enum MoleCLI {
    static let pathDefaultsKey = "molePath"
    static let terminalColumns = 110
    static let terminalRows = 40

    /// Resolution order: user setting, the repo checkout recorded at build time,
    /// then the usual install locations.
    static var executableURL: URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let custom = UserDefaults.standard.string(forKey: pathDefaultsKey), !custom.isEmpty {
            candidates.append((custom as NSString).expandingTildeInPath)
        }
        if let repo = Bundle.main.object(forInfoDictionaryKey: "MoleRepoPath") as? String {
            candidates.append(repo + "/mole")
        }
        candidates += [
            "/opt/homebrew/bin/mo",
            "/usr/local/bin/mo",
            NSHomeDirectory() + "/.local/bin/mo",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// GUI apps start with a minimal PATH; add the locations Mole's own
    /// dependencies (brew, go, etc.) are normally found in.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        env["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        env["TERM"] = "xterm-256color"
        // Same size as the PTY, so lists that truncate names render identically
        // with and without a terminal (tput honors these variables).
        env["COLUMNS"] = String(terminalColumns)
        env["LINES"] = String(terminalRows)
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env
    }

    enum CLIError: LocalizedError {
        case notFound
        case failed(code: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                "找不到 mo 命令，请在设置里指定路径。"
            case let .failed(code, stderr):
                "mo 退出码 \(code)：\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }

    /// Runs `mo <arguments>` with stdin closed and decodes its stdout as JSON.
    static func json<T: Decodable>(_ arguments: [String], as type: T.Type) async throws -> T {
        let data = try await run(arguments)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    static func run(_ arguments: [String]) async throws -> Data {
        guard let url = executableURL else { throw CLIError.notFound }
        return try await Task.detached(priority: .userInitiated) {
            try runBlocking(url, arguments)
        }.value
    }

    private static func runBlocking(_ url: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain stderr concurrently so a chatty command cannot fill the pipe and stall.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0 else {
            throw CLIError.failed(code: process.terminationStatus,
                                  stderr: String(decoding: errData, as: UTF8.self))
        }
        return outData
    }
}

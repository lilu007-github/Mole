import Foundation

/// Mole's whitelists (~/.config/mole/whitelist and whitelist_optimize).
///
/// Burrow never parses or writes these files itself. A saved file replaces
/// Mole's optional defaults, so getting the semantics wrong would silently drop
/// protections. The bridge below sources Mole's own lib/manage/whitelist.sh and
/// does exactly what `mo clean --whitelist` does: load_whitelist, is_whitelisted
/// for each inventory row, custom patterns kept on save, save_whitelist_patterns.
enum Whitelist {
    enum Mode: String, CaseIterable, Identifiable {
        case clean, optimize
        var id: String { rawValue }
        var title: String { self == .clean ? "清理白名单" : "优化白名单" }
    }

    struct Row: Identifiable, Hashable {
        var name: String
        /// Portable form with "~", as Mole saves it.
        var pattern: String
        var protected: Bool
        /// A built-in safety rule: Mole adds it back on every load, so it cannot be turned off.
        var alwaysProtected = false
        var id: String { pattern }
    }

    struct State {
        var rows: [Row]
        /// Lines in the file that are no inventory row; always kept on save.
        var custom: [String]
    }

    enum BridgeError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case let .failed(message) = self { return message }
            return nil
        }
    }

    static func load(_ mode: Mode) async throws -> State {
        let output = try await bridge(["list", mode.rawValue])
        var rows: [Row] = []
        var custom: [String] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields.first == "ROW", fields.count == 5 {
                rows.append(Row(name: fields[2], pattern: fields[3], protected: fields[1] == "1",
                                alwaysProtected: fields[4] == "1"))
            } else if fields.first == "CUSTOM", fields.count == 2 {
                custom.append(fields[1])
            }
        }
        return State(rows: rows, custom: custom)
    }

    /// Saves the ticked rows plus the custom patterns, through Mole's save function.
    static func save(_ mode: Mode, protectedRows: [Row], custom: [String]) async throws {
        _ = try await bridge(["save", mode.rawValue] + protectedRows.map(\.pattern) + custom)
    }

    /// Runs the bridge with the Mole CLI's root (the folder holding `mole` and lib/).
    private static func bridge(_ arguments: [String]) async throws -> String {
        guard let mole = MoleCLI.executableURL?.resolvingSymlinksInPath() else {
            throw BridgeError.failed("找不到 Mole CLI。")
        }
        let root = mole.deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: root + "/lib/manage/whitelist.sh") else {
            throw BridgeError.failed("这个 Mole 安装的布局不受支持，请改用 mo clean --whitelist。")
        }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script, "burrow-whitelist", root] + arguments
            process.environment = MoleCLI.environment
            process.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors, as: UTF8.self)
                    .replacingOccurrences(of: #"\u{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw BridgeError.failed(message.isEmpty ? "Mole 无法读取白名单（退出码 \(process.terminationStatus)），没有做任何改动。" : message)
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// Mirrors manage_whitelist_categories in lib/manage/whitelist.sh, minus the menu.
    /// $1 = Mole root, $2 = list|save, $3 = clean|optimize, $4… = patterns to save.
    static let script = #"""
    set -euo pipefail
    ROOT="$1"; ACTION="$2"; MODE="$3"; shift 3
    if [[ "$MODE" == "optimize" ]]; then
        source "$ROOT/lib/core/common.sh"
        source "$ROOT/lib/core/sudo.sh"
        source "$ROOT/lib/optimize/diagnostics.sh"
        source "$ROOT/lib/optimize/maintenance.sh"
        source "$ROOT/lib/optimize/catalog.sh"
        source "$ROOT/lib/optimize/tasks.sh"
        source "$ROOT/lib/check/health_json.sh"
    else
        source "$ROOT/lib/core/common.sh"
        source "$ROOT/lib/core/sudo.sh"
        for lib in brew caches apps dev app_caches hints system user; do
            source "$ROOT/lib/clean/$lib.sh"
        done
    fi
    source "$ROOT/lib/manage/whitelist.sh"

    # An unreadable file stops here, exactly like the menu: saving would replace it.
    load_whitelist "$MODE" || exit 3

    if [[ "$ACTION" == "save" ]]; then
        if [[ $# -gt 0 ]]; then save_whitelist_patterns "$MODE" "$@"; else save_whitelist_patterns "$MODE"; fi
        exit 0
    fi

    if [[ "$MODE" == "optimize" ]]; then items=$(get_optimize_whitelist_items); else items=$(get_all_cache_items); fi
    patterns=()
    while IFS='|' read -r name pattern _; do
        [[ -n "$name" ]] || continue
        pattern="${pattern/\$HOME/$HOME}"
        patterns+=("$pattern")
        flag=0
        is_whitelisted "$pattern" && flag=1
        safety=0
        for s in "${SAFETY_WHITELIST_PATTERNS[@]+"${SAFETY_WHITELIST_PATTERNS[@]}"}"; do
            patterns_equivalent "$pattern" "$s" && { safety=1; flag=1; break; }
        done
        printf 'ROW\t%s\t%s\t%s\t%s\n' "$flag" "$name" "${pattern/#$HOME/~}" "$safety"
    done <<< "$items"

    for current in "${CURRENT_WHITELIST_PATTERNS[@]+"${CURRENT_WHITELIST_PATTERNS[@]}"}"; do
        known=false
        for p in "${patterns[@]+"${patterns[@]}"}"; do
            patterns_equivalent "$current" "$p" && { known=true; break; }
        done
        if [[ "$known" == false ]]; then
            for p in "${SAFETY_WHITELIST_PATTERNS[@]+"${SAFETY_WHITELIST_PATTERNS[@]}"}"; do
                patterns_equivalent "$current" "$p" && { known=true; break; }
            done
        fi
        [[ "$known" == true ]] || printf 'CUSTOM\t%s\n' "$current"
    done
    """#
}

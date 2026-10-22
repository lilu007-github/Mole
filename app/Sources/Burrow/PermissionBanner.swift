import AppKit
import SwiftUI

/// A macOS privacy permission that Mole reported as missing.
///
/// Mole's messages say "your terminal" because it assumes a shell; under Burrow
/// the permission belongs to Burrow, since macOS attributes child processes to
/// the app that launched them.
struct PermissionHint: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let settingsURL: URL

    static let appManagement = PermissionHint(
        id: "app-management",
        title: "macOS 拦截了对应用的修改",
        detail: "Mole 没能把 App 移到废纸篓，已安全跳过。请在「系统设置 → 隐私与安全性 → App 管理」里打开 Burrow，然后重试。",
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
    )

    static let fullDiskAccess = PermissionHint(
        id: "full-disk-access",
        title: "部分项目需要「完全磁盘访问权限」",
        detail: "Mole 跳过了读不到的位置（例如废纸篓）。如需处理，请在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里打开 Burrow，然后重新运行。",
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    )

    /// Matches the messages Mole prints (lib/core/file_ops.sh, lib/clean/user.sh,
    /// lib/optimize/tasks.sh, bin/clean.sh).
    static func detect(in lines: [String]) -> [PermissionHint] {
        var hints: [PermissionHint] = []
        if lines.contains(where: { $0.contains("macOS denied Trash access") }) {
            hints.append(.appManagement)
        }
        if lines.contains(where: { $0.contains("Full Disk Access") }) {
            hints.append(.fullDiskAccess)
        }
        return hints
    }
}

struct PermissionBanner: View {
    let lines: [String]

    var body: some View {
        let hints = PermissionHint.detect(in: lines)
        if !hints.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(hints) { hint in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hint.title).bold()
                            Text(hint.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("打开系统设置") { NSWorkspace.shared.open(hint.settingsURL) }
                    }
                }
            }
            .padding(10)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

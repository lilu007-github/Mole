import AppKit
import ApplicationServices
import SwiftUI

/// First-launch guide: what Burrow is and which macOS permissions help it.
struct OnboardingView: View {
    static let shownKey = "onboardingShown"
    static let showNotification = Notification.Name("BurrowShowOnboarding")
    @Environment(\.dismiss) private var dismiss
    @State private var fullDisk = Doctor.hasFullDiskAccess()
    @State private var accessibility = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎使用 Burrow").font(.title.bold())
                    Text("开源 Mole CLI 的图形界面。清理、卸载、优化都交给 Mole 执行，先预览、你确认后才动手。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("这些权限可以让 Burrow 做得更完整，都可以稍后在「诊断」里再打开：").font(.headline)
            permission("完全磁盘访问权限", "清理废纸篓等受保护的位置；没有它，这些项目会被跳过。",
                       granted: fullDisk, url: PermissionHint.fullDiskAccess.settingsURL)
            permission("App 管理", "卸载「应用程序」文件夹里的 App。macOS 无法提前检测，被拦截时 Burrow 会提示。",
                       granted: nil, url: PermissionHint.appManagement.settingsURL)
            permission("辅助功能（可选）", "清洁屏幕时屏蔽亮度、音量等按键。",
                       granted: accessibility, url: CleanScreen.accessibilitySettings)
            Text("在系统设置里打开权限后，回到这里点「重新检查」。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("重新检查") {
                    fullDisk = Doctor.hasFullDiskAccess()
                    accessibility = AXIsProcessTrusted()
                }
                Spacer()
                Button("开始使用") {
                    UserDefaults.standard.set(true, forKey: Self.shownKey)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func permission(_ title: String, _ detail: String, granted: Bool?, url: URL) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted == true ? "checkmark.circle.fill" : granted == false ? "circle" : "questionmark.circle")
                .foregroundStyle(granted == true ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted != true {
                Button("打开设置") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

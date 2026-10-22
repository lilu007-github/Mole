/// The pages in the sidebar, also used by Doctor to link to a page.
enum SidebarItem: String, CaseIterable, Identifiable {
    case status, analyze, clean, ai, purge, optimize, installer, uninstall, updates, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: "系统状态"
        case .analyze: "磁盘分析"
        case .clean: "清理"
        case .ai: "AI 数据"
        case .purge: "构建产物"
        case .optimize: "优化"
        case .installer: "安装包"
        case .uninstall: "卸载应用"
        case .updates: "应用更新"
        case .history: "历史记录"
        }
    }

    var symbol: String {
        switch self {
        case .status: "gauge.with.dots.needle.67percent"
        case .analyze: "chart.pie"
        case .clean: "sparkles"
        case .ai: "brain"
        case .purge: "hammer"
        case .optimize: "wand.and.stars"
        case .installer: "shippingbox"
        case .uninstall: "trash"
        case .updates: "arrow.down.app"
        case .history: "clock.arrow.circlepath"
        }
    }
}

import SwiftUI
import AppKit
import WorktreeCleanerCore

/// 顶部菜单栏常驻下拉面板（同心圆角悬浮卡片 + 全量仓库可展开 + 确定高度可顺滑滚动）
struct MenuBarView: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var expandedRepos: Set<String> = []

    private var cautionItems: [WorktreeItem] {
        state.items.filter { $0.safetyLevel == .caution }
    }

    private var safeOnlyCount: Int {
        state.items.filter { $0.safetyLevel == .safe }.count
    }

    private var repoSummaries: [(repo: String, count: Int, bytes: Int64, items: [WorktreeItem])] {
        let grouped = Dictionary(grouping: state.items, by: \.mainRepoName)
        return grouped.map { repo, list in
            let totalBytes = list.compactMap(\.diskSizeBytes).reduce(0, +)
            let sortedList = list.sorted { lhs, rhs in
                if lhs.safetyLevel != rhs.safetyLevel { return lhs.safetyLevel < rhs.safetyLevel }
                return (lhs.diskSizeBytes ?? 0) > (rhs.diskSizeBytes ?? 0)
            }
            return (repo: repo, count: list.count, bytes: totalBytes, items: sortedList)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private var isCompact: Bool {
        repoSummaries.count <= 2 && expandedRepos.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: 固定顶栏：标题外链 + 圆形玻璃动作按钮
            HStack(spacing: 6) {
                Button {
                    openMainWindow()
                } label: {
                    HStack(spacing: 4) {
                        Text("Worktree Cleaner")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                AdaptiveGlassGroup(spacing: 6) {
                    HStack(spacing: 6) {
                        GlassCircleButton(
                            systemName: "macwindow",
                            size: 26,
                            iconSize: 11.5,
                            helpText: state.tr("打开主窗口", "Open Main Window")
                        ) {
                            openMainWindow()
                        }

                        GlassCircleButton(
                            systemName: "arrow.clockwise",
                            size: 26,
                            iconSize: 11.5,
                            helpText: state.tr("立即扫描", "Rescan"),
                            isSpinning: state.isScanning
                        ) {
                            Task { await state.refresh() }
                        }
                        .disabled(state.isScanning)

                        GlassCircleButton(
                            systemName: "power",
                            size: 26,
                            iconSize: 11.5,
                            helpText: state.tr("退出", "Quit")
                        ) {
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // MARK: 可滚动内容区（支持触控板上下顺滑滚动浏览全量仓库与展开子项）
            scrollBody
        }
        .frame(width: 336)
    }

    @ViewBuilder
    private var scrollBody: some View {
        let contentStack = VStack(spacing: 8) {
            // 卡片 1：全景空间与安全分布
            FloatingCard(cornerRadius: 12, padding: 13) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .lastTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ByteCountFormatter.string(fromByteCount: state.reclaimableBytes, countStyle: .file))
                                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.primary)
                            Text(state.tr("可安全释放", "Safe to Reclaim"))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(ByteCountFormatter.string(fromByteCount: state.totalBytes, countStyle: .file))
                                .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(state.tr("共 \(state.items.count) 项", "\(state.items.count) total"))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }

                    MultiSegmentBar(
                        segments: [
                            .init(value: Double(safeOnlyCount), color: .green.opacity(0.85)),
                            .init(value: Double(cautionItems.count), color: .orange.opacity(0.85)),
                            .init(value: Double(state.dangerItems.count), color: .red.opacity(0.82)),
                            .init(value: Double(state.missingItems.count), color: .secondary.opacity(0.45))
                        ],
                        height: 6
                    )

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 5) {
                        LegendItem(color: .green, label: state.tr("安全可删", "Safe"), value: "\(safeOnlyCount)")
                        LegendItem(color: .orange, label: state.tr("待确认", "Review"), value: "\(cautionItems.count)")
                        LegendItem(color: .red, label: state.tr("有改动", "Active"), value: "\(state.dangerItems.count)")
                        LegendItem(color: .secondary, label: state.tr("幽灵", "Ghost"), value: "\(state.missingItems.count)")
                    }
                }
            }

            // 卡片 2：全量仓库占用（无数量截断，点击任意仓库可展开子 Worktree）
            if !repoSummaries.isEmpty {
                FloatingCard(cornerRadius: 12, padding: 13) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(state.tr("全部仓库 · \(repoSummaries.count)", "Repositories · \(repoSummaries.count)"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        let maxBytes = max(repoSummaries.first?.bytes ?? 1, 1)

                        ForEach(Array(repoSummaries.enumerated()), id: \.element.repo) { idx, entry in
                            let isExpanded = expandedRepos.contains(entry.repo)

                            VStack(alignment: .leading, spacing: 6) {
                                Button {
                                    withAnimation(.snappy(duration: 0.18)) {
                                        if isExpanded {
                                            expandedRepos.remove(entry.repo)
                                        } else {
                                            expandedRepos.insert(entry.repo)
                                        }
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 6) {
                                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(.tertiary)
                                                .frame(width: 10)

                                            Text(entry.repo == "Orphaned" ? state.tr("孤儿残留", "Orphaned") : entry.repo)
                                                .font(.system(size: 12.5, weight: .medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)

                                            Text("\(entry.count)")
                                                .font(.system(size: 10.5).monospacedDigit())
                                                .foregroundStyle(.tertiary)

                                            Spacer()

                                            Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                                                .font(.system(size: 11.5).monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }

                                        SegmentedTickBar(
                                            ratio: Double(entry.bytes) / Double(maxBytes),
                                            color: Color.accentColor.opacity(0.85),
                                            segments: 46,
                                            height: 10
                                        )
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if isExpanded {
                                    VStack(spacing: 4) {
                                        ForEach(entry.items) { wt in
                                            Button {
                                                state.selectedItemID = wt.id
                                                openMainWindow()
                                            } label: {
                                                HStack(spacing: 7) {
                                                    Circle()
                                                        .fill(wt.safetyLevel.color.opacity(0.88))
                                                        .frame(width: 5.5, height: 5.5)
                                                    Text(wt.displayBranch(language: state.language))
                                                        .font(.system(size: 11.5))
                                                        .foregroundStyle(.primary.opacity(0.86))
                                                        .lineLimit(1)
                                                    Spacer()
                                                    Text(wt.formattedSize)
                                                        .font(.system(size: 10.5).monospacedDigit())
                                                        .foregroundStyle(.tertiary)
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.leading, 14)
                                    .padding(.top, 2)
                                }
                            }

                            if idx < repoSummaries.count - 1 {
                                Divider().opacity(0.3)
                            }
                        }
                    }
                }
            }

            // 卡片 3：底部快捷操作卡
            FloatingCard(cornerRadius: 12, padding: 12) {
                VStack(spacing: 10) {
                    HStack {
                        Text(state.tr("快捷操作", "Quick Actions"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.85))
                        Spacer()
                        Text(state.safeItems.isEmpty
                             ? state.tr("已清空", "Clean")
                             : state.tr("\(state.safeItems.count) 项可清", "\(state.safeItems.count) ready"))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Divider().opacity(0.3)

                    AdaptiveGlassGroup(spacing: 8) {
                        HStack(spacing: 8) {
                            if !state.missingItems.isEmpty {
                                GlassPillButton(title: state.tr("清幽灵 (\(state.missingItems.count))", "Prune (\(state.missingItems.count))")) {
                                    Task { await state.pruneMissingOnly() }
                                }
                                .disabled(state.isCleaning)
                            } else if state.totalCacheBytes >= 20 * 1024 * 1024 {
                                let cacheStr = ByteCountFormatter.string(fromByteCount: state.totalCacheBytes, countStyle: .file)
                                GlassPillButton(title: state.tr("清缓存 \(cacheStr)", "Slim \(cacheStr)")) {
                                    Task { await state.cleanAllBuildCaches() }
                                }
                                .disabled(state.isCleaning)
                            }
                            Spacer()
                            GlassPillButton(title: state.tr("管理全部", "Manage All"), isProminent: true) {
                                openMainWindow()
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)

        if isCompact {
            ScrollView(.vertical, showsIndicators: false) {
                contentStack
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                contentStack
            }
            .frame(height: 460)
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

private struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color.opacity(0.85))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.85))
        }
    }
}

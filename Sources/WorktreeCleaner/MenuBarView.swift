import SwiftUI
import AppKit

/// 顶部菜单栏常驻下拉面板（同心圆角悬浮卡片 + 90% 灰阶克制美学 + 固定高度防裁切）
struct MenuBarView: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow

    private var cautionItems: [WorktreeItem] {
        state.items.filter { $0.safetyLevel == .caution }
    }

    private var safeOnlyCount: Int {
        state.items.filter { $0.safetyLevel == .safe }.count
    }

    private var topRepoSummaries: [(repo: String, count: Int, bytes: Int64)] {
        let grouped = Dictionary(grouping: state.items, by: \.mainRepoName)
        return grouped.map { repo, list in
            let totalBytes = list.compactMap(\.diskSizeBytes).reduce(0, +)
            return (repo: repo, count: list.count, bytes: totalBytes)
        }
        .sorted { $0.bytes > $1.bytes }
        .prefix(4)
        .map { $0 }
    }

    var body: some View {
        VStack(spacing: 8) {
            // MARK: 顶栏：极简标题外链 + 3 个 26pt 圆形 Liquid Glass 按钮
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
            .padding(.horizontal, 4)

            // MARK: 卡片 1：可释放空间 + 状态分布
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

            // MARK: 卡片 2：仓库空间占用 Top 4
            if !topRepoSummaries.isEmpty {
                FloatingCard(cornerRadius: 12, padding: 13) {
                    VStack(alignment: .leading, spacing: 10) {
                        let maxBytes = max(topRepoSummaries.first?.bytes ?? 1, 1)

                        ForEach(Array(topRepoSummaries.enumerated()), id: \.element.repo) { idx, entry in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Text(entry.repo == "Orphaned" ? state.tr("孤儿残留", "Orphaned") : entry.repo)
                                        .font(.system(size: 12.5, weight: .medium))
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
                                    segments: 34,
                                    height: 8
                                )
                            }

                            if idx < topRepoSummaries.count - 1 {
                                Divider().opacity(0.3)
                            }
                        }
                    }
                }
            }

            // MARK: 卡片 3：底部快捷操作卡（固定展开，绝不裁切）
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
        .padding(10)
        .frame(width: 326)
        .fixedSize(horizontal: false, vertical: true)
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

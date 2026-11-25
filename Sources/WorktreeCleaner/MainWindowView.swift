import SwiftUI
import AppKit

/// 主窗口：严格遵循 macOS HIG + Tahoe Liquid Glass 范式
/// - 通顶毛玻璃侧边栏 + 44pt 统一标题栏
/// - 90% 灰阶克制色彩 + 单视图唯一主强调色焦点
/// - Codex + Claude 意图唤醒、Squash/PR 合并识别、进程锁、敏感忽略文件保护、只清缓存、废纸篓后悔药
struct MainWindowView: View {
    @Bindable var state: AppState
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSearchFocused: Bool

    @State private var showDiffSheet = false
    @State private var showRootsPopover = false
    @State private var showSettingsPopover = false
    @State private var hoveredID: String?
    @State private var showAllBranchCommits = false
    @State private var showTouchedFiles = false

    private var isWindowActive: Bool { activeState != .inactive }

    private var orderedVisibleItems: [WorktreeItem] {
        groupedItems.flatMap(\.items)
    }

    private var groupedItems: [(repo: String, items: [WorktreeItem])] {
        let dict = Dictionary(grouping: state.filteredItems, by: \.mainRepoName)
        return dict.keys.sorted { lhs, rhs in
            if lhs == "Orphaned" && rhs != "Orphaned" { return false }
            if rhs == "Orphaned" && lhs != "Orphaned" { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        .map { key in (repo: key, items: dict[key] ?? []) }
    }

    var body: some View {
        HStack(spacing: 0) {
            leftSidebar
                .frame(minWidth: 304, idealWidth: 336, maxWidth: 396)
                .background(.ultraThinMaterial)

            Divider().opacity(colorScheme == .dark ? 0.35 : 0.45)

            detailCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colorScheme == .dark ? Color(white: 0.12) : Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea(.all, edges: .top)
        .onChange(of: state.selectedItemID) { _, _ in
            showAllBranchCommits = false
            showTouchedFiles = false
        }
        .onKeyPress(.upArrow) {
            moveSelection(delta: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(delta: 1)
            return .handled
        }
        .background {
            Button("") { isSearchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .sheet(isPresented: $state.showDeleteConfirmation) {
            DeleteConfirmationSheet(state: state)
        }
        .sheet(item: $state.pushTarget) { target in
            PushWorktreeSheet(state: state, item: target)
        }
        .sheet(isPresented: $showDiffSheet) {
            DiffPreviewSheet(state: state)
        }
        .overlay(alignment: .bottom) {
            if let message = state.bannerMessage {
                ToastBanner(message: message, isError: state.bannerIsError) {
                    state.bannerMessage = nil
                }
                .padding(.bottom, 64)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: state.bannerMessage)
    }

    private func moveSelection(delta: Int) {
        let list = orderedVisibleItems
        guard !list.isEmpty else { return }
        guard let currentID = state.selectedItem?.id,
              let idx = list.firstIndex(where: { $0.id == currentID }) else {
            state.selectedItemID = list.first?.id
            return
        }
        let next = min(max(idx + delta, 0), list.count - 1)
        state.selectedItemID = list[next].id
    }

    // MARK: - 左侧通顶毛玻璃侧边栏

    private var leftSidebar: some View {
        VStack(spacing: 0) {
            // 1. 44pt 统一标题栏
            HStack(spacing: 6) {
                Spacer().frame(width: 72)

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: state.reclaimableBytes, countStyle: .file))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)

                AdaptiveGlassGroup(spacing: 6) {
                    HStack(spacing: 6) {
                        GlassCircleButton(
                            systemName: "folder.badge.gearshape",
                            size: 26,
                            iconSize: 11.5,
                            helpText: state.tr("扫描目录", "Scan Folders")
                        ) {
                            showRootsPopover.toggle()
                        }
                        .popover(isPresented: $showRootsPopover, arrowEdge: .bottom) {
                            ScanRootsPopover(state: state)
                        }

                        GlassCircleButton(
                            systemName: "slider.horizontal.3",
                            size: 26,
                            iconSize: 11.5,
                            helpText: state.tr("偏好设置", "Preferences")
                        ) {
                            showSettingsPopover.toggle()
                        }
                        .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                            SettingsPopover(state: state)
                        }

                        GlassCircleButton(
                            systemName: "arrow.clockwise",
                            size: 26,
                            iconSize: 11.5,
                            helpText: state.tr("重新扫描 (⌘R)", "Rescan (⌘R)"),
                            isSpinning: state.isScanning
                        ) {
                            Task { await state.refresh() }
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(state.isScanning)
                    }
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 12)

            // 2. 紧凑桌面搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                TextField(state.tr("搜索分支、仓库或功能…", "Search branch, repo or task…"), text: $state.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($isSearchFocused)
                if !state.searchText.isEmpty {
                    Button {
                        state.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("⌘K")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05),
                        lineWidth: 0.5
                    )
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // 3. 灰阶筛选胶囊
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(WorktreeFilter.allCases) { filter in
                        FilterPill(
                            title: filter.title(language: state.language),
                            count: state.count(for: filter),
                            dotColor: filterDotColor(filter),
                            isSelected: state.activeFilter == filter
                        ) {
                            withAnimation(.easeOut(duration: 0.14)) {
                                state.activeFilter = filter
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 8)

            Divider().opacity(0.35)

            // 4. 分组列表
            if state.isScanning && state.items.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(state.tr("正在扫描…", "Scanning…"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.filteredItems.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(state.items.isEmpty
                         ? state.tr("没有冗余 Worktree", "No Redundant Worktrees")
                         : state.tr("无匹配项", "No Matches"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groupedItems, id: \.repo) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(group.repo == "Orphaned" ? state.tr("孤儿残留", "Orphaned") : group.repo)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text("\(group.items.count)")
                                        .font(.system(size: 10.5).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.bottom, 2)

                                ForEach(group.items) { item in
                                    SidebarWorktreeRow(
                                        item: item,
                                        language: state.language,
                                        freshnessHours: state.freshnessHours,
                                        isSelected: state.selectedItem?.id == item.id,
                                        isChecked: state.checkedIDs.contains(item.id),
                                        isHovered: hoveredID == item.id,
                                        isWindowActive: isWindowActive,
                                        onSelect: { state.selectedItemID = item.id },
                                        onToggleCheck: { state.toggleCheck(item) }
                                    )
                                    .onHover { inside in
                                        hoveredID = inside ? item.id : (hoveredID == item.id ? nil : hoveredID)
                                    }
                                    .contextMenu {
                                        if item.directoryExists {
                                            Button { state.revealInFinder(item.path) } label: {
                                                Label(state.tr("在 Finder 中显示", "Reveal in Finder"), systemImage: "folder")
                                            }
                                            if let editor = state.preferredEditor {
                                                Button { ExternalToolDetector.open(directory: item.path, with: editor) } label: {
                                                    Label(state.tr("用 \(editor.name) 打开", "Open in \(editor.name)"), systemImage: "macwindow")
                                                }
                                            }
                                            Button { state.openInTerminal(item.path) } label: {
                                                Label(state.tr("在终端中打开", "Open in Terminal"), systemImage: "terminal")
                                            }
                                            Button {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(item.path, forType: .string)
                                                state.showToast(state.tr("已复制路径", "Copied path"), isError: false)
                                            } label: {
                                                Label(state.tr("复制路径", "Copy Path"), systemImage: "doc.on.doc")
                                            }
                                            if item.reclaimableCacheBytes >= 5 * 1024 * 1024 {
                                                Divider()
                                                Button {
                                                    Task { await state.cleanCaches(for: item) }
                                                } label: {
                                                    Label(
                                                        state.tr("仅清构建缓存 (\(item.formattedCacheSize))", "Slim Caches (\(item.formattedCacheSize))"),
                                                        systemImage: "sparkles"
                                                    )
                                                }
                                            }
                                            if item.canPush {
                                                Divider()
                                                Button { state.requestPush(item) } label: {
                                                    Label(
                                                        item.isDirty
                                                            ? state.tr("提交并推送…", "Commit & Push…")
                                                            : state.tr("推送到远端…", "Push to Remote…"),
                                                        systemImage: "arrow.up.circle"
                                                    )
                                                }
                                            }
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            state.requestDelete([item])
                                        } label: {
                                            Label(state.tr("移除 Worktree…", "Remove Worktree…"), systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }

            Divider().opacity(0.35)

            // 5. 侧边栏底部批量操作条
            HStack(spacing: 8) {
                Button {
                    if state.checkedIDs.isEmpty {
                        state.selectAllSafe()
                    } else {
                        state.clearSelection()
                    }
                } label: {
                    Text(state.checkedIDs.isEmpty
                         ? state.tr("全选安全项", "Select Safe")
                         : state.tr("取消 (\(state.checkedIDs.count))", "Clear (\(state.checkedIDs.count))"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(state.checkedIDs.isEmpty && state.autoSelectableSafeItems.isEmpty)

                if !state.missingItems.isEmpty && state.checkedIDs.isEmpty {
                    Text("·").foregroundStyle(.quaternary)
                    Button {
                        Task { await state.pruneMissingOnly() }
                    } label: {
                        Text(state.tr("清幽灵 \(state.missingItems.count)", "Prune \(state.missingItems.count)"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isCleaning)
                }

                Spacer()

                if !state.checkedItems.isEmpty {
                    GlassPillButton(
                        title: state.tr(
                            "清理 · \(ByteCountFormatter.string(fromByteCount: state.checkedBytes, countStyle: .file))",
                            "Clean · \(ByteCountFormatter.string(fromByteCount: state.checkedBytes, countStyle: .file))"
                        ),
                        isProminent: true,
                        tint: state.checkedItems.contains(where: { $0.safetyLevel == .danger }) ? .red : .accentColor
                    ) {
                        state.requestDelete(state.checkedItems)
                    }
                    .disabled(state.isCleaning)
                }
            }
            .frame(height: 42)
            .padding(.horizontal, 12)
        }
    }

    // MARK: - 右侧纯净详情画布

    @ViewBuilder
    private var detailCanvas: some View {
        if let item = state.selectedItem {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Spacer().frame(height: 22)

                        // 1. 头部：仓库 · 来源 · PR 状态 + 分支标题 + 大小
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(item.isOrphan ? state.tr("孤儿目录", "Orphaned") : item.mainRepoName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text("·").foregroundStyle(.quaternary)
                                    Text(item.source.rawValue)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.tertiary)

                                    if let pr = item.prInfo {
                                        Text("·").foregroundStyle(.quaternary)
                                        Button {
                                            state.openURL(pr.url)
                                        } label: {
                                            HStack(spacing: 3) {
                                                Circle()
                                                    .fill(pr.badgeColor)
                                                    .frame(width: 5.5, height: 5.5)
                                                Text(pr.badgeText(language: state.language))
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .help(pr.url)
                                    }

                                    if item.isLocked {
                                        Text("·").foregroundStyle(.quaternary)
                                        Label("Locked", systemImage: "lock")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Text(item.displayBranch(language: state.language))
                                    .font(.system(size: 18, weight: .semibold))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(item.formattedSize)
                                    .font(.system(size: 16, weight: .medium, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.primary.opacity(0.9))
                                if let mod = item.lastModified {
                                    Text(mod.formatted(.relative(presentation: .named)))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }

                        // 2. 体检结论（中性微面 + 语义点）
                        InsetGroupCard(cornerRadius: 10, padding: 11) {
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(item.safetyLevel.color.opacity(0.9))
                                    .frame(width: 7, height: 7)
                                Text(item.safetyLevel.label(language: state.language))
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(item.safetySummary(language: state.language, freshnessHours: state.freshnessHours))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                Spacer()
                            }
                        }

                        // 3. 敏感忽略孤本文件预警（如 .env.local、secrets.json 等）
                        if !item.preciousIgnoredFiles.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(state.tr("本地忽略孤本文件", "Precious Ignored Files"))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if !item.mainRepoPath.isEmpty {
                                        Button {
                                            Task { await state.copyPreciousFiles(for: item) }
                                        } label: {
                                            Label(state.tr("拷回主仓库", "Copy to Main Repo"), systemImage: "doc.on.doc")
                                                .font(.system(size: 11.5, weight: .medium))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                InsetGroupCard(cornerRadius: 10) {
                                    VStack(spacing: 0) {
                                        ForEach(item.preciousIgnoredFiles, id: \.self) { relPath in
                                            HStack(spacing: 8) {
                                                Circle()
                                                    .fill(Color.orange.opacity(0.85))
                                                    .frame(width: 5.5, height: 5.5)
                                                Text(relPath)
                                                    .font(.system(size: 12, design: .monospaced))
                                                    .foregroundStyle(.primary.opacity(0.88))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Spacer()
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)

                                            if relPath != item.preciousIgnoredFiles.last {
                                                Divider().opacity(0.28).padding(.leading, 26)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // 4. 做了什么（Codex + Claude 意图 & Git 演进）
                        if let summary = item.featureSummary {
                            featureSummarySection(summary: summary, item: item)
                        }

                        // 5. 未提交改动
                        if !item.changedFiles.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(state.tr("未提交改动", "Uncommitted Changes"))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text("\(item.modifiedCount + item.untrackedCount)")
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Button {
                                        showDiffSheet = true
                                        Task { await state.loadDiff(for: item) }
                                    } label: {
                                        Text(state.tr("查看 Diff", "View Diff"))
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }

                                InsetGroupCard(cornerRadius: 10) {
                                    VStack(spacing: 0) {
                                        ForEach(item.changedFiles) { file in
                                            HStack(spacing: 8) {
                                                Text(file.badgeText)
                                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 20, alignment: .leading)

                                                Text(file.path)
                                                    .font(.system(size: 12, design: .monospaced))
                                                    .foregroundStyle(.primary.opacity(0.88))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Spacer()
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)

                                            if file.id != item.changedFiles.last?.id {
                                                Divider().opacity(0.3).padding(.leading, 40)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // 6. 未推送提交
                        if !item.unpushedCommits.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(state.tr("未推送提交", "Unpushed Commits"))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text("\(item.aheadCount)")
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }

                                InsetGroupCard(cornerRadius: 10) {
                                    VStack(spacing: 0) {
                                        ForEach(item.unpushedCommits) { commit in
                                            HStack(spacing: 10) {
                                                Text(commit.id)
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(.tertiary)
                                                    .frame(width: 52, alignment: .leading)
                                                Text(commit.message)
                                                    .font(.system(size: 12.5))
                                                    .lineLimit(1)
                                                Spacer()
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6.5)

                                            if commit.id != item.unpushedCommits.last?.id {
                                                Divider().opacity(0.3).padding(.leading, 12)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // 7. 路径分组信息
                        InsetGroupCard(cornerRadius: 10) {
                            VStack(spacing: 0) {
                                if !item.mainRepoPath.isEmpty {
                                    HStack {
                                        Text(state.tr("主仓库", "Main Repo"))
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                        Spacer(minLength: 16)
                                        Text(item.mainRepoPath)
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .textSelection(.enabled)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)

                                    Divider().opacity(0.3).padding(.leading, 12)
                                }

                                HStack(spacing: 8) {
                                    Text(state.tr("路径", "Path"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 16)
                                    Text(item.path)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(item.path, forType: .string)
                                        state.showToast(state.tr("已复制路径", "Copied path"), isError: false)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .help(state.tr("复制路径", "Copy Path"))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                        }

                        Spacer().frame(height: 60)
                    }
                    .padding(.horizontal, 26)
                }

                // MARK: 悬浮 Liquid Glass 动作栏
                AdaptiveGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        if item.directoryExists {
                            GlassCircleButton(
                                systemName: "folder",
                                size: 28,
                                iconSize: 12,
                                helpText: state.tr("在 Finder 中显示", "Reveal in Finder")
                            ) {
                                state.revealInFinder(item.path)
                            }

                            GlassMenuPill(systemName: "ellipsis", helpText: state.tr("打开与更多操作", "Open & More")) {
                                let editors = state.installedApps.filter { !$0.isTerminal }
                                let terminals = state.installedApps.filter { $0.isTerminal }

                                if !editors.isEmpty {
                                    ForEach(editors) { app in
                                        Button {
                                            ExternalToolDetector.open(directory: item.path, with: app)
                                        } label: {
                                            Label(state.tr("用 \(app.name) 打开", "Open in \(app.name)"), systemImage: "macwindow")
                                        }
                                    }
                                    Divider()
                                }

                                if !terminals.isEmpty {
                                    ForEach(terminals) { term in
                                        Button {
                                            ExternalToolDetector.open(directory: item.path, with: term)
                                        } label: {
                                            Label(state.tr("在 \(term.name) 中打开", "Open in \(term.name)"), systemImage: "terminal")
                                        }
                                    }
                                } else {
                                    Button { state.openInTerminal(item.path) } label: {
                                        Label(state.tr("在终端中打开", "Open in Terminal"), systemImage: "terminal")
                                    }
                                }

                                Divider()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.path, forType: .string)
                                    state.showToast(state.tr("已复制路径", "Copied path"), isError: false)
                                } label: {
                                    Label(state.tr("复制路径", "Copy Path"), systemImage: "doc.on.doc")
                                }

                                if item.isDirty {
                                    Button {
                                        showDiffSheet = true
                                        Task { await state.loadDiff(for: item) }
                                    } label: {
                                        Label(state.tr("查看 Diff", "View Diff"), systemImage: "text.magnifyingglass")
                                    }
                                }
                            }
                        }

                        Spacer()

                        // 可清构建缓存>=10MB 时提供瘦身按钮（保留所有源码与未提交改动）
                        if item.reclaimableCacheBytes >= 10 * 1024 * 1024 {
                            GlassPillButton(
                                title: state.tr("清缓存 \(item.formattedCacheSize)", "Slim \(item.formattedCacheSize)"),
                                systemName: "sparkles",
                                isProminent: false
                            ) {
                                Task { await state.cleanCaches(for: item) }
                            }
                            .disabled(state.isCleaning || state.isPushing)
                        }

                        if item.canPush {
                            GlassPillButton(
                                title: item.isDirty ? state.tr("提交并推送", "Commit & Push") : state.tr("推送", "Push"),
                                systemName: "arrow.up",
                                isProminent: false
                            ) {
                                state.requestPush(item)
                            }
                            .disabled(state.isCleaning || state.isPushing)
                        }

                        // 全屏唯一主强调色焦点按钮
                        GlassPillButton(
                            title: item.isMissing
                                ? state.tr("清理幽灵", "Prune")
                                : state.tr("移除", "Remove"),
                            systemName: "trash",
                            isProminent: true,
                            tint: item.safetyLevel == .danger ? .red : .accentColor
                        ) {
                            state.requestDelete([item])
                        }
                        .disabled(state.isCleaning || state.isPushing)
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 16)
                    .padding(.top, 12)
                    .background(
                        LinearGradient(
                            colors: [
                                (colorScheme == .dark ? Color(white: 0.12) : Color(nsColor: .windowBackgroundColor)).opacity(0),
                                (colorScheme == .dark ? Color(white: 0.12) : Color(nsColor: .windowBackgroundColor)).opacity(0.95)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 26, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                Text(state.tr("选择 Worktree 查看详情", "Select a Worktree to Inspect"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 「做了什么」功能摘要

    @ViewBuilder
    private func featureSummarySection(summary: FeatureSummary, item: WorktreeItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.tr("做了什么", "What Changed"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let base = summary.baseBranch {
                    Text(state.tr("相对 \(base)", "vs \(base)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if summary.hasBranchWork {
                    HStack(spacing: 7) {
                        if summary.totalCommitCount > 0 {
                            Text(state.tr("\(summary.totalCommitCount) 提交", "\(summary.totalCommitCount) commits"))
                        }
                        if summary.filesChangedCount > 0 {
                            Text(state.tr("\(summary.filesChangedCount) 文件", "\(summary.filesChangedCount) files"))
                        }
                        if summary.insertions > 0 || summary.deletions > 0 {
                            Text("+\(summary.insertions) / -\(summary.deletions)")
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                }
            }

            InsetGroupCard(cornerRadius: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    if !summary.agentTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(summary.agentTasks, id: \.self) { task in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 2)
                                    Text(task)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(.primary.opacity(0.92))
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)

                        if !summary.branchCommits.isEmpty || !summary.touchedAreas.isEmpty {
                            Divider().opacity(0.3).padding(.leading, 12)
                        }
                    }

                    if !summary.touchedAreas.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(summary.touchedAreas, id: \.self) { area in
                                    Text(area)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2.5)
                                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }

                        if !summary.branchCommits.isEmpty {
                            Divider().opacity(0.3).padding(.leading, 12)
                        }
                    }

                    if !summary.branchCommits.isEmpty {
                        let visible = showAllBranchCommits ? summary.branchCommits : Array(summary.branchCommits.prefix(5))
                        ForEach(visible) { commit in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(commit.id)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 52, alignment: .leading)

                                Text(commit.subject)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.primary.opacity(0.9))
                                    .lineLimit(2)

                                Spacer(minLength: 8)

                                Text(commit.relativeDate)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6.5)

                            if commit.id != visible.last?.id {
                                Divider().opacity(0.28).padding(.leading, 12)
                            }
                        }

                        if summary.branchCommits.count > 5 {
                            Divider().opacity(0.28)
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    showAllBranchCommits.toggle()
                                }
                            } label: {
                                Text(showAllBranchCommits
                                     ? state.tr("收起", "Collapse")
                                     : state.tr("展开其余 \(summary.branchCommits.count - 5) 条提交", "Show \(summary.branchCommits.count - 5) more commits"))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6.5)
                            }
                            .buttonStyle(.plain)
                        }
                    } else if summary.agentTasks.isEmpty {
                        Text(
                            summary.baseBranch != nil
                                ? state.tr("相对 \(summary.baseBranch!) 无新增提交", "No commits ahead of \(summary.baseBranch!)")
                                : (item.headSubject.isEmpty ? state.tr("无新增提交", "No commits") : item.headSubject)
                        )
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                }
            }

            if !summary.topFiles.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showTouchedFiles.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showTouchedFiles ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(state.tr("主要改动文件 (\(summary.topFiles.count))", "Top Changed Files (\(summary.topFiles.count))"))
                            .font(.system(size: 11.5))
                    }
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)

                if showTouchedFiles {
                    InsetGroupCard(cornerRadius: 10) {
                        VStack(spacing: 0) {
                            ForEach(summary.topFiles) { stat in
                                HStack(spacing: 8) {
                                    Text(stat.path)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.primary.opacity(0.85))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text("+\(stat.insertions) -\(stat.deletions)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5.5)

                                if stat.id != summary.topFiles.last?.id {
                                    Divider().opacity(0.28).padding(.leading, 12)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func filterDotColor(_ filter: WorktreeFilter) -> Color? {
        switch filter {
        case .all: return nil
        case .safe: return .green
        case .caution: return .orange
        case .danger: return .red
        case .missing: return .secondary
        }
    }
}

// MARK: - 侧边栏列表项

private struct SidebarWorktreeRow: View {
    let item: WorktreeItem
    let language: AppLanguage
    let freshnessHours: Int
    let isSelected: Bool
    let isChecked: Bool
    let isHovered: Bool
    let isWindowActive: Bool
    let onSelect: () -> Void
    let onToggleCheck: () -> Void

    private var subtitleText: String {
        if !item.activeProcesses.isEmpty {
            return L10n.tr("运行中：\(item.activeProcesses.first ?? "")", "Running: \(item.activeProcesses.first ?? "")", language: language)
        }
        if let task = item.featureSummary?.agentTasks.first, !task.isEmpty {
            return task
        }
        var parts: [String] = [item.source.rawValue]
        if let pr = item.prInfo {
            parts.append("#\(pr.number)")
        } else if let c = item.featureSummary?.totalCommitCount, c > 0 {
            parts.append(L10n.tr("\(c) 提交", "\(c) commits", language: language))
        }
        if item.modifiedCount + item.untrackedCount > 0 {
            parts.append(L10n.tr("\(item.modifiedCount + item.untrackedCount) 改动", "\(item.modifiedCount + item.untrackedCount) dirty", language: language))
        } else if item.aheadCount > 0 {
            parts.append(L10n.tr("\(item.aheadCount) 未推", "\(item.aheadCount) unpushed", language: language))
        } else if !item.preciousIgnoredFiles.isEmpty {
            parts.append(item.preciousIgnoredFiles.first ?? ".env")
        } else if item.isMissing {
            parts.append(L10n.tr("目录已失", "missing", language: language))
        } else if item.isOrphan {
            parts.append(L10n.tr("孤儿", "orphan", language: language))
        } else if item.isWithinFreshnessWindow(hours: freshnessHours) {
            parts.append(L10n.tr("近期", "recent", language: language))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleCheck) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isChecked ? (isWindowActive ? Color.accentColor : Color.secondary) : Color.primary.opacity(0.2),
                            lineWidth: 1.25
                        )
                        .frame(width: 14, height: 14)
                    if isChecked {
                        Circle()
                            .fill(isWindowActive ? Color.accentColor : Color.secondary)
                            .frame(width: 14, height: 14)
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)

            Circle()
                .fill(item.safetyLevel.color.opacity(isWindowActive ? 0.85 : 0.45))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayBranch(language: language))
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isWindowActive ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.formattedSize)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6.5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? Color.primary.opacity(isWindowActive ? 0.09 : 0.05)
                        : (isHovered ? Color.primary.opacity(0.04) : .clear)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: onSelect)
    }
}

private struct FilterPill: View {
    let title: String
    let count: Int
    let dotColor: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let dotColor {
                    Circle()
                        .fill(dotColor.opacity(0.8))
                        .frame(width: 5.5, height: 5.5)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .medium : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                Capsule()
                    .fill(isSelected ? Color.primary.opacity(0.10) : .clear)
            )
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct ToastBanner: View {
    let message: String
    let isError: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isError ? Color.red : Color.green)
                .frame(width: 6.5, height: 6.5)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .modifier(ToastGlassSurface())
    }
}

private struct ToastGlassSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
    }
}

// MARK: - 快速推送到远端 Sheet

private struct PushWorktreeSheet: View {
    @Bindable var state: AppState
    let item: WorktreeItem
    @Environment(\.colorScheme) private var colorScheme

    @State private var branchName: String
    @State private var commitMessage: String
    @State private var deleteAfterPush: Bool = false

    init(state: AppState, item: WorktreeItem) {
        self.state = state
        self.item = item
        _branchName = State(initialValue: item.suggestedPushBranchName)
        _commitMessage = State(initialValue: item.suggestedCommitMessage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.isDirty
                     ? state.tr("提交并推送", "Commit & Push")
                     : state.tr("推送到远端", "Push to Remote"))
                    .font(.system(size: 14, weight: .semibold))
                Text("\(item.mainRepoName) → \(item.remoteName ?? "origin")/\(branchName)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.isDetached
                         ? state.tr("新建分支名", "New Branch Name")
                         : state.tr("目标分支", "Target Branch"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    TextField(state.tr("分支名", "Branch name"), text: $branchName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 0.5)
                        )
                }

                if item.isDirty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(state.tr("Commit 说明", "Commit Message"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(state.tr("\(item.modifiedCount + item.untrackedCount) 个文件", "\(item.modifiedCount + item.untrackedCount) files"))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        TextField(state.tr("提交说明…", "Commit message…"), text: $commitMessage)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 0.5)
                            )
                    }
                }

                Toggle(isOn: $deleteAfterPush) {
                    Text(state.tr("推送成功后自动移除此 Worktree（移入废纸篓）", "Remove worktree after push (Move to Trash)"))
                        .font(.system(size: 12.5))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if let errorMsg = state.pushErrorMessage {
                Text(errorMsg)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(5)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            AdaptiveGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Spacer()
                    GlassPillButton(title: state.tr("取消", "Cancel")) {
                        state.pushTarget = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(state.isPushing)

                    GlassPillButton(
                        title: state.isPushing
                            ? state.tr("推送中…", "Pushing…")
                            : (deleteAfterPush ? state.tr("推送并移除", "Push & Remove") : state.tr("推送", "Push")),
                        systemName: "arrow.up",
                        isProminent: true,
                        isLoading: state.isPushing
                    ) {
                        Task {
                            await state.executePush(
                                item: item,
                                branchName: branchName,
                                commitMessage: item.isDirty ? commitMessage : nil,
                                deleteAfterPush: deleteAfterPush,
                                moveToTrash: true
                            )
                        }
                    }
                    .disabled(state.isPushing || branchName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - 安全移除确认 Sheet

private struct DeleteConfirmationSheet: View {
    @Bindable var state: AppState
    @State private var backupDirtyBeforeDelete = true
    @State private var moveToTrash = true
    @State private var deleteLocalBranch = false

    private var targets: [WorktreeItem] { state.pendingDeleteTargets }
    private var dirtyTargets: [WorktreeItem] { targets.filter(\.isDirty) }
    private var hasPhysicalFolders: Bool { targets.contains { !$0.isMissing } }
    private var hasDeletableBranches: Bool { targets.contains(where: \.canDeleteLocalBranch) }
    private var totalSize: Int64 { targets.compactMap(\.diskSizeBytes).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 3) {
                let sizeText = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
                Text(state.tr("确认移除 \(targets.count) 个 Worktree", "Remove \(targets.count) Worktree(s)"))
                    .font(.system(size: 14, weight: .semibold))
                Text(state.tr("预计释放 \(sizeText)，主仓库不受影响", "Reclaims ~\(sizeText). Main repository stays untouched."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            InsetGroupCard(cornerRadius: 10) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(targets) { item in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(item.safetyLevel.color.opacity(0.85))
                                    .frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(item.isOrphan ? state.tr("孤儿", "Orphan") : item.mainRepoName) · \(item.displayBranch(language: state.language))")
                                        .font(.system(size: 12.5, weight: .medium))
                                    Text(item.safetySummary(language: state.language, freshnessHours: state.freshnessHours))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.formattedSize)
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)

                            if item.id != targets.last?.id {
                                Divider().opacity(0.3).padding(.leading, 12)
                            }
                        }
                    }
                }
                .frame(minHeight: 80, maxHeight: 190)
            }

            VStack(alignment: .leading, spacing: 9) {
                if hasPhysicalFolders {
                    Toggle(isOn: $moveToTrash) {
                        Text(state.tr("移入废纸篓（可随时从废纸篓还原）", "Move to Trash (recoverable anytime)"))
                            .font(.system(size: 12.5))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if !dirtyTargets.isEmpty {
                    Toggle(isOn: $backupDirtyBeforeDelete) {
                        Text(state.tr("移除前自动 Commit 备份 \(dirtyTargets.count) 个有改动的 Worktree", "Auto-commit backup for \(dirtyTargets.count) dirty worktree(s)"))
                            .font(.system(size: 12.5))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if hasDeletableBranches {
                    Toggle(isOn: $deleteLocalBranch) {
                        Text(state.tr("同时删除对应的本地分支（保留主分支）", "Also delete matching local branch"))
                            .font(.system(size: 12.5))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }

            AdaptiveGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Spacer()
                    GlassPillButton(title: state.tr("取消", "Cancel")) {
                        state.showDeleteConfirmation = false
                    }
                    .keyboardShortcut(.cancelAction)

                    GlassPillButton(
                        title: confirmTitle,
                        systemName: "trash",
                        isProminent: true,
                        tint: confirmTint
                    ) {
                        Task {
                            await state.executeDelete(
                                targets: targets,
                                backupDirtyFirst: backupDirtyBeforeDelete,
                                moveToTrash: moveToTrash,
                                deleteLocalBranch: deleteLocalBranch,
                                force: true
                            )
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 470)
    }

    private var confirmTitle: String {
        if !dirtyTargets.isEmpty {
            return backupDirtyBeforeDelete
                ? state.tr("备份并移除", "Backup & Remove")
                : state.tr("强制移除", "Force Remove")
        }
        return moveToTrash
            ? state.tr("移入废纸篓", "Move to Trash")
            : state.tr("确认移除", "Remove")
    }

    private var confirmTint: Color {
        if !dirtyTargets.isEmpty {
            return backupDirtyBeforeDelete ? .orange : .red
        }
        return moveToTrash ? .accentColor : .red
    }
}

// MARK: - Diff 预览 Sheet

private struct DiffPreviewSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(state.tr("未提交改动 Diff", "Uncommitted Diff"))
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                GlassCircleButton(systemName: "xmark", size: 26, iconSize: 11) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().opacity(0.35)

            if state.isLoadingDiff {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(state.diffPreviewText ?? "")
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
        .frame(width: 720, height: 500)
    }
}

// MARK: - 扫描目录配置 Popover

private struct ScanRootsPopover: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(state.tr("扫描目录", "Scan Folders"))
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                GlassCircleButton(systemName: "plus", size: 24, iconSize: 11, helpText: state.tr("添加目录", "Add Folder")) {
                    state.addSearchRootViaPanel()
                }
            }

            VStack(spacing: 5) {
                ForEach(state.searchRoots, id: \.self) { root in
                    HStack {
                        Text(root.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            state.searchRoots.removeAll { $0 == root }
                            Task { await state.refresh() }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().opacity(0.3)

            Text(state.tr("已自动包含 ~/.codex、~/.claude、~/.cursor、~/.trae-cn", "Auto-scans ~/.codex, ~/.claude, ~/.cursor, ~/.trae-cn"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 310)
    }
}

// MARK: - 偏好设置 Popover（语言 / 冷却保护 / 开机自启）

private struct SettingsPopover: View {
    @Bindable var state: AppState

    private let freshnessOptions: [Int] = [0, 6, 24, 72, 168]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.tr("偏好设置", "Preferences"))
                .font(.system(size: 12.5, weight: .semibold))

            HStack {
                Text(state.tr("语言", "Language"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $state.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.optionTitle(in: state.language)).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(width: 115)
            }

            HStack {
                Text(state.tr("冷却保护", "Freshness Guard"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $state.freshnessHours) {
                    ForEach(freshnessOptions, id: \.self) { hours in
                        Text(freshnessTitle(hours)).tag(hours)
                    }
                }
                .labelsHidden()
                .frame(width: 115)
            }

            Divider().opacity(0.3)

            Toggle(isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            )) {
                Text(state.tr("登录时自动启动", "Launch at Login"))
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 260)
    }

    private func freshnessTitle(_ hours: Int) -> String {
        switch hours {
        case 0: return state.tr("关闭", "Off")
        case 6: return state.tr("6 小时", "6 Hours")
        case 24: return state.tr("24 小时", "24 Hours")
        case 72: return state.tr("3 天", "3 Days")
        default: return state.tr("7 天", "7 Days")
        }
    }
}

import Foundation
import SwiftUI
import AppKit
import WorktreeCleanerCore

/// 全局状态管理与动作调度中心
@MainActor
@Observable
final class AppState {
    private static let rootsStorageKey = "WorktreeCleaner.searchRoots"
    private static let languageStorageKey = "WorktreeCleaner.language"
    private static let freshnessStorageKey = "WorktreeCleaner.freshnessHours"

    var items: [WorktreeItem] = []
    var installedApps: [ExternalApp] = []
    var isScanning: Bool = false
    var isCleaning: Bool = false
    var isPushing: Bool = false
    var lastScanDate: Date?

    var searchText: String = ""
    var activeFilter: WorktreeFilter = .all
    var selectedItemID: String?
    var checkedIDs: Set<String> = []

    // 偏好设置
    var searchRoots: [String] {
        didSet {
            UserDefaults.standard.set(searchRoots, forKey: Self.rootsStorageKey)
        }
    }

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageStorageKey)
        }
    }

    var freshnessHours: Int {
        didSet {
            UserDefaults.standard.set(freshnessHours, forKey: Self.freshnessStorageKey)
        }
    }

    var launchAtLogin: Bool = false

    // Diff 预览
    var diffPreviewText: String?
    var isLoadingDiff: Bool = false

    // 快速推送弹窗
    var pushTarget: WorktreeItem?
    var pushErrorMessage: String?

    // 清理确认弹窗 & 结果提示
    var pendingDeleteTargets: [WorktreeItem] = []
    var showDeleteConfirmation: Bool = false
    var lastCleanupReport: CleanupReport?
    var bannerMessage: String?
    var bannerIsError: Bool = false

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.rootsStorageKey), !saved.isEmpty {
            self.searchRoots = saved
        } else {
            self.searchRoots = WorktreeScanner.defaultSearchRoots
        }

        if let rawLang = UserDefaults.standard.string(forKey: Self.languageStorageKey),
           let parsed = AppLanguage(rawValue: rawLang) {
            self.language = parsed
        } else {
            self.language = .system
        }

        if UserDefaults.standard.object(forKey: Self.freshnessStorageKey) != nil {
            self.freshnessHours = UserDefaults.standard.integer(forKey: Self.freshnessStorageKey)
        } else {
            self.freshnessHours = 24
        }

        self.launchAtLogin = LaunchAtLoginManager.isEnabled
        self.installedApps = ExternalToolDetector.detectInstalledApps()
    }

    func tr(_ zh: String, _ en: String) -> String {
        L10n.tr(zh, en, language: language)
    }

    // MARK: - 计算属性

    var preferredEditor: ExternalApp? {
        installedApps.first { !$0.isTerminal }
    }

    var preferredTerminal: ExternalApp? {
        installedApps.first { $0.isTerminal }
    }

    var filteredItems: [WorktreeItem] {
        items.filter { item in
            guard activeFilter.matches(item) else { return false }
            if searchText.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            let q = searchText.lowercased()
            if item.folderName.lowercased().contains(q)
                || item.mainRepoName.lowercased().contains(q)
                || item.displayBranch(language: language).lowercased().contains(q)
                || item.path.lowercased().contains(q)
                || item.source.rawValue.lowercased().contains(q)
                || item.headSubject.lowercased().contains(q) {
                return true
            }
            if let summary = item.featureSummary {
                if summary.agentTasks.contains(where: { $0.lowercased().contains(q) }) { return true }
                if summary.branchCommits.contains(where: { $0.subject.lowercased().contains(q) }) { return true }
            }
            return false
        }
    }

    var selectedItem: WorktreeItem? {
        guard let id = selectedItemID else { return filteredItems.first }
        return items.first(where: { $0.id == id })
    }

    var safeItems: [WorktreeItem] {
        items.filter { $0.safetyLevel == .safe || $0.safetyLevel == .missing }
    }

    var autoSelectableSafeItems: [WorktreeItem] {
        items.filter { $0.isAutoSelectableSafe(freshnessHours: freshnessHours) }
    }

    var dangerItems: [WorktreeItem] {
        items.filter { $0.safetyLevel == .danger }
    }

    var missingItems: [WorktreeItem] {
        items.filter { $0.safetyLevel == .missing }
    }

    var reclaimableBytes: Int64 {
        safeItems.compactMap(\.diskSizeBytes).reduce(0, +)
    }

    var totalBytes: Int64 {
        items.compactMap(\.diskSizeBytes).reduce(0, +)
    }

    var totalCacheBytes: Int64 {
        items.reduce(0) { $0 + $1.reclaimableCacheBytes }
    }

    var itemsWithCaches: [WorktreeItem] {
        items.filter { $0.reclaimableCacheBytes >= 5 * 1024 * 1024 }
    }

    var checkedItems: [WorktreeItem] {
        items.filter { checkedIDs.contains($0.id) }
    }

    var checkedBytes: Int64 {
        checkedItems.compactMap(\.diskSizeBytes).reduce(0, +)
    }

    func count(for filter: WorktreeFilter) -> Int {
        items.filter { filter.matches($0) }.count
    }

    // MARK: - 扫描

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true

        let scanned = await WorktreeScanner.scanAll(searchRoots: searchRoots)
        self.items = scanned
        self.lastScanDate = Date()
        self.isScanning = false

        let validIDs = Set(scanned.map(\.id))
        checkedIDs = checkedIDs.intersection(validIDs)
        if let sel = selectedItemID, !validIDs.contains(sel) {
            selectedItemID = scanned.first?.id
        } else if selectedItemID == nil {
            selectedItemID = scanned.first?.id
        }

        await populateDiskAndCacheSizes(for: scanned)
    }

    private func populateDiskAndCacheSizes(for targets: [WorktreeItem]) async {
        await withTaskGroup(of: (String, Int64, [CacheDirItem], Int64).self) { group in
            for item in targets where item.directoryExists {
                group.addTask {
                    let stats = await WorktreeScanner.populateDiskAndCacheStats(for: item)
                    return (item.id, stats.diskBytes, stats.cacheDirs, stats.cacheBytes)
                }
            }
            for await (id, diskBytes, cacheDirs, cacheBytes) in group {
                if let idx = items.firstIndex(where: { $0.id == id }) {
                    items[idx].diskSizeBytes = diskBytes
                    items[idx].cacheDirs = cacheDirs
                    items[idx].reclaimableCacheBytes = cacheBytes
                }
            }
        }
    }

    // MARK: - 勾选控制（受新鲜度冷却保护）

    func toggleCheck(_ item: WorktreeItem) {
        if checkedIDs.contains(item.id) {
            checkedIDs.remove(item.id)
        } else {
            checkedIDs.insert(item.id)
        }
    }

    func selectAllSafe() {
        let autoTargets = autoSelectableSafeItems
        for item in autoTargets {
            checkedIDs.insert(item.id)
        }
        let skippedRecent = safeItems.count - autoTargets.count
        if skippedRecent > 0 {
            showToast(
                tr(
                    "已勾选 \(autoTargets.count) 项，自动跳过 \(skippedRecent) 个近期活跃项",
                    "Selected \(autoTargets.count) items; skipped \(skippedRecent) recently active"
                ),
                isError: false
            )
        }
    }

    func clearSelection() {
        checkedIDs.removeAll()
    }

    // MARK: - 只清构建缓存（保留代码）

    func cleanCaches(for item: WorktreeItem) async {
        guard !item.cacheDirs.isEmpty, !isCleaning else { return }
        isCleaning = true
        let result = await WorktreeScanner.cleanBuildCaches(for: item)
        switch result {
        case .success(let freed):
            let stats = await WorktreeScanner.populateDiskAndCacheStats(for: item)
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].diskSizeBytes = stats.diskBytes
                items[idx].cacheDirs = stats.cacheDirs
                items[idx].reclaimableCacheBytes = stats.cacheBytes
            }
            let sizeStr = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
            showToast(
                tr("已清理缓存（移入废纸篓），释放 \(sizeStr)，代码零改动", "Moved caches to Trash, freed \(sizeStr)"),
                isError: false
            )
        case .failure(let err):
            showToast(err.localizedDescription, isError: true)
        }
        isCleaning = false
    }

    func cleanAllBuildCaches() async {
        let targets = itemsWithCaches
        guard !targets.isEmpty, !isCleaning else { return }
        isCleaning = true
        var totalFreed: Int64 = 0
        for item in targets {
            if case .success(let freed) = await WorktreeScanner.cleanBuildCaches(for: item) {
                totalFreed += freed
            }
        }
        isCleaning = false
        let sizeStr = ByteCountFormatter.string(fromByteCount: totalFreed, countStyle: .file)
        showToast(
            tr("已清理所有构建缓存，释放 \(sizeStr)", "Cleaned build caches, freed \(sizeStr)"),
            isError: false
        )
        await populateDiskAndCacheSizes(for: targets)
    }

    // MARK: - 拷回敏感忽略文件至主仓库

    func copyPreciousFiles(for item: WorktreeItem) async {
        let result = await WorktreeScanner.copyPreciousFilesToMainRepo(for: item)
        switch result {
        case .success(let info):
            if info.copied.isEmpty && !info.skipped.isEmpty {
                showToast(
                    tr("主仓库已存在同名文件，已安全跳过 (\(info.skipped.count))", "Skipped \(info.skipped.count) existing files in main repo"),
                    isError: false
                )
            } else {
                showToast(
                    tr("已拷回 \(info.copied.count) 个本地文件至主仓库", "Copied \(info.copied.count) local files to main repo"),
                    isError: false
                )
            }
        case .failure(let err):
            showToast(err.localizedDescription, isError: true)
        }
    }

    // MARK: - 快速推送到远端

    func requestPush(_ item: WorktreeItem) {
        pushErrorMessage = nil
        pushTarget = item
    }

    func executePush(
        item: WorktreeItem,
        branchName: String,
        commitMessage: String?,
        deleteAfterPush: Bool,
        moveToTrash: Bool = true
    ) async {
        guard !isPushing else { return }
        isPushing = true
        pushErrorMessage = nil

        let result = await WorktreeScanner.pushWorktree(
            item,
            branchName: branchName,
            commitMessage: commitMessage,
            deleteAfterPush: deleteAfterPush,
            moveToTrash: moveToTrash
        )

        isPushing = false

        switch result {
        case .success(let info):
            pushTarget = nil
            if info.removedAfterPush {
                showToast(
                    tr("已推送至 \(info.remote)/\(info.branch) 并移除 Worktree", "Pushed to \(info.remote)/\(info.branch) and removed worktree"),
                    isError: false
                )
            } else if info.committedChanges {
                showToast(
                    tr("已提交并推送至 \(info.remote)/\(info.branch)", "Committed and pushed to \(info.remote)/\(info.branch)"),
                    isError: false
                )
            } else {
                showToast(
                    tr("已推送至 \(info.remote)/\(info.branch)", "Pushed to \(info.remote)/\(info.branch)"),
                    isError: false
                )
            }
            await refresh()
        case .failure(let err):
            pushErrorMessage = err.localizedDescription
        }
    }

    // MARK: - 清理执行

    func requestDelete(_ targets: [WorktreeItem]) {
        guard !targets.isEmpty else { return }
        pendingDeleteTargets = targets
        showDeleteConfirmation = true
    }

    func executeDelete(
        targets: [WorktreeItem],
        backupDirtyFirst: Bool,
        moveToTrash: Bool,
        deleteLocalBranch: Bool,
        deleteOriginBranches: Bool = false,
        force: Bool
    ) async {
        guard !targets.isEmpty, !isCleaning else { return }
        isCleaning = true
        showDeleteConfirmation = false

        var succeeded = 0
        var failed: [(String, String)] = []
        var freed: Int64 = 0

        for item in targets {
            let originTarget = deleteOriginBranches ? item.originDeletionTarget : nil
            let result = await WorktreeScanner.removeWorktree(
                item,
                backupCommitFirst: backupDirtyFirst,
                moveToTrash: moveToTrash,
                deleteLocalBranch: deleteLocalBranch,
                originDeletionTarget: originTarget,
                force: force || item.safetyLevel == .danger
            )
            switch result {
            case .success:
                succeeded += 1
                freed += item.diskSizeBytes ?? 0
            case .failure(let err):
                let branch = originTarget.map { "origin/\($0.branch)" } ?? item.displayBranch(language: language)
                failed.append((item.path, "\(item.mainRepoName) · \(branch) — \(err.localizedDescription)"))
            }
        }

        isCleaning = false
        pendingDeleteTargets = []
        lastCleanupReport = CleanupReport(
            succeededCount: succeeded,
            failedItems: failed,
            freedBytes: freed,
            movedToTrash: moveToTrash
        )

        if failed.isEmpty {
            let sizeStr = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
            var message = moveToTrash
                ? tr("已移入废纸篓并清理 \(succeeded) 个 Worktree（约 \(sizeStr)）", "Moved \(succeeded) worktrees to Trash (~\(sizeStr))")
                : tr("已永久移除 \(succeeded) 个 Worktree（约 \(sizeStr)）", "Removed \(succeeded) worktrees (~\(sizeStr))")
            if deleteOriginBranches && targets.contains(where: { $0.originDeletionTarget != nil }) {
                message += tr("，所选 origin 分支均已不存在", ". The selected branches are absent from origin.")
            }
            showToast(message, isError: false)
        } else {
            let details = failed.map { $0.1 }.joined(separator: "\n")
            showToast(
                tr("已完成 \(succeeded) 项，\(failed.count) 项未完成。", "Completed \(succeeded). Incomplete: \(failed.count).")
                    + "\n" + details,
                isError: true
            )
        }

        await refresh()
    }

    func pruneMissingOnly() async {
        guard !missingItems.isEmpty, !isCleaning else { return }
        isCleaning = true
        let count = await WorktreeScanner.pruneAllMissing(items: items)
        isCleaning = false
        showToast(
            tr("已清理 \(count) 个主仓库的幽灵元数据", "Pruned stale metadata in \(count) repositories"),
            isError: false
        )
        await refresh()
    }

    // MARK: - 系统设置与外部交互

    func setLaunchAtLogin(_ enabled: Bool) {
        let res = LaunchAtLoginManager.setEnabled(enabled)
        switch res {
        case .success:
            launchAtLogin = enabled
        case .failure(let err):
            launchAtLogin = LaunchAtLoginManager.isEnabled
            showToast(
                tr("开机自启需要已签名应用移入 /Applications：\(err.localizedDescription)", "Launch at Login requires signed app in /Applications: \(err.localizedDescription)"),
                isError: true
            )
        }
    }

    func loadDiff(for item: WorktreeItem) async {
        isLoadingDiff = true
        diffPreviewText = nil
        diffPreviewText = await WorktreeScanner.fetchDiff(for: item)
        isLoadingDiff = false
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openInTerminal(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if let term = preferredTerminal {
            ExternalToolDetector.open(directory: path, with: term)
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", path]
            try? process.run()
        }
    }

    func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func addSearchRootViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = tr("添加扫描目录", "Add Folder")
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            if !searchRoots.contains(path) {
                searchRoots.append(path)
                Task { await refresh() }
            }
        }
    }

    func showToast(_ message: String, isError: Bool) {
        bannerIsError = isError
        bannerMessage = message
    }
}

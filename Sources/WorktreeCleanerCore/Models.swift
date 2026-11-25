import Foundation
import SwiftUI

/// Worktree 来源分类
public enum WorktreeSource: String, Codable, CaseIterable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
    case cursor = "Cursor"
    case trae = "Trae"
    case local = "Local"

    public var color: Color {
        switch self {
        case .codex: return .blue
        case .claude: return .orange
        case .cursor: return .purple
        case .trae: return .teal
        case .local: return .secondary
        }
    }

    public var icon: String {
        switch self {
        case .codex: return "terminal"
        case .claude: return "sparkles"
        case .cursor: return "cursorarrow.rays"
        case .trae: return "bolt.horizontal"
        case .local: return "arrow.triangle.branch"
        }
    }
}

/// Worktree 物理与 Git 形态分类
public enum WorktreeKind: String, Sendable {
    case linkedWorktree
    case prunableMetadata
    case brokenGitOrphan
    case directoryOrphan
}

/// Worktree 安全清理等级
public enum SafetyLevel: Int, Comparable, CaseIterable, Sendable {
    case missing = 0
    case safe = 1
    case caution = 2
    case danger = 3

    public static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var key: String {
        switch self {
        case .missing: return "missing"
        case .safe: return "safe"
        case .caution: return "caution"
        case .danger: return "danger"
        }
    }

    public func label(language: AppLanguage) -> String {
        switch self {
        case .missing: return L10n.tr("幽灵记录", "Ghost", language: language)
        case .safe: return L10n.tr("安全可删", "Safe", language: language)
        case .caution: return L10n.tr("待确认", "Review", language: language)
        case .danger: return L10n.tr("有改动", "Active / Dirty", language: language)
        }
    }

    public var color: Color {
        switch self {
        case .missing: return .secondary
        case .safe: return .green
        case .caution: return .orange
        case .danger: return .red
        }
    }

    public var sfSymbol: String {
        switch self {
        case .missing: return "questionmark.folder"
        case .safe: return "checkmark.shield.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .danger: return "hand.raised.fill"
        }
    }
}

/// 单个文件变更项
public struct ChangedFileItem: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let statusCode: String
    public let path: String

    public init(statusCode: String, path: String) {
        self.statusCode = statusCode
        self.path = path
    }

    public var badgeText: String {
        let trimmed = statusCode.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "M" : trimmed
    }

    public var badgeColor: Color {
        if statusCode.contains("?") { return .orange }
        if statusCode.contains("D") { return .red }
        if statusCode.contains("A") { return .green }
        return .blue
    }
}

/// 未推送提交项
public struct UnpushedCommit: Identifiable, Hashable, Sendable {
    public let id: String
    public let message: String

    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}

/// 相对主分支新增的提交记录
public struct BranchCommit: Identifiable, Hashable, Sendable {
    public let id: String
    public let relativeDate: String
    public let subject: String

    public init(id: String, relativeDate: String, subject: String) {
        self.id = id
        self.relativeDate = relativeDate
        self.subject = subject
    }
}

/// 相对主分支改动的文件行数统计
public struct DiffFileStat: Identifiable, Hashable, Sendable {
    public let id: String
    public let path: String
    public let insertions: Int
    public let deletions: Int

    public init(id: String, path: String, insertions: Int, deletions: Int) {
        self.id = id
        self.path = path
        self.insertions = insertions
        self.deletions = deletions
    }

    public var totalDelta: Int { insertions + deletions }
}

/// GitHub PR 关联状态
public struct PullRequestInfo: Hashable, Sendable {
    public let number: Int
    public let state: String
    public let url: String

    public init(number: Int, state: String, url: String) {
        self.number = number
        self.state = state
        self.url = url
    }

    public var isMerged: Bool {
        state.uppercased() == "MERGED"
    }

    public func badgeText(language: AppLanguage) -> String {
        switch state.uppercased() {
        case "MERGED": return L10n.tr("PR #\(number) 已合并", "PR #\(number) Merged", language: language)
        case "CLOSED": return L10n.tr("PR #\(number) 已关闭", "PR #\(number) Closed", language: language)
        default: return L10n.tr("PR #\(number) 进行中", "PR #\(number) Open", language: language)
        }
    }

    public var badgeColor: Color {
        switch state.uppercased() {
        case "MERGED": return .purple
        case "CLOSED": return .secondary
        default: return .green
        }
    }
}

/// 可再生构建与依赖缓存目录项
public struct CacheDirItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let relativePath: String
    public let sizeBytes: Int64

    public init(id: String, relativePath: String, sizeBytes: Int64) {
        self.id = id
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
    }
}

/// Worktree 做了什么功能的完整摘要
public struct FeatureSummary: Hashable, Sendable {
    public let baseBranch: String?
    public let totalCommitCount: Int
    public let branchCommits: [BranchCommit]
    public let filesChangedCount: Int
    public let insertions: Int
    public let deletions: Int
    public let touchedAreas: [String]
    public let topFiles: [DiffFileStat]
    public let agentTasks: [String]

    public init(
        baseBranch: String?,
        totalCommitCount: Int,
        branchCommits: [BranchCommit],
        filesChangedCount: Int,
        insertions: Int,
        deletions: Int,
        touchedAreas: [String],
        topFiles: [DiffFileStat],
        agentTasks: [String]
    ) {
        self.baseBranch = baseBranch
        self.totalCommitCount = totalCommitCount
        self.branchCommits = branchCommits
        self.filesChangedCount = filesChangedCount
        self.insertions = insertions
        self.deletions = deletions
        self.touchedAreas = touchedAreas
        self.topFiles = topFiles
        self.agentTasks = agentTasks
    }

    public var hasBranchWork: Bool {
        totalCommitCount > 0 || filesChangedCount > 0
    }
}

/// 单个 Git Worktree 的完整体检信息
public struct WorktreeItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let path: String
    public let kind: WorktreeKind
    public let mainRepoPath: String
    public let mainRepoName: String
    public let branch: String
    public let headCommit: String
    public let headSubject: String
    public let lastModified: Date?
    public let isDetached: Bool
    public let isLocked: Bool
    public let directoryExists: Bool
    public let source: WorktreeSource
    public let remoteName: String?

    public let modifiedCount: Int
    public let untrackedCount: Int
    public let aheadCount: Int
    public let hasUpstream: Bool
    public let isMergedToDefault: Bool
    public let isSquashMerged: Bool
    public let prInfo: PullRequestInfo?
    public let changedFiles: [ChangedFileItem]
    public let unpushedCommits: [UnpushedCommit]

    public let activeProcesses: [String]
    public let preciousIgnoredFiles: [String]
    public let orphanFileCount: Int

    public let featureSummary: FeatureSummary?

    public var diskSizeBytes: Int64?
    public var cacheDirs: [CacheDirItem] = []
    public var reclaimableCacheBytes: Int64 = 0

    public init(
        id: String,
        path: String,
        kind: WorktreeKind,
        mainRepoPath: String,
        mainRepoName: String,
        branch: String,
        headCommit: String,
        headSubject: String,
        lastModified: Date?,
        isDetached: Bool,
        isLocked: Bool,
        directoryExists: Bool,
        source: WorktreeSource,
        remoteName: String?,
        modifiedCount: Int,
        untrackedCount: Int,
        aheadCount: Int,
        hasUpstream: Bool,
        isMergedToDefault: Bool,
        isSquashMerged: Bool,
        prInfo: PullRequestInfo?,
        changedFiles: [ChangedFileItem],
        unpushedCommits: [UnpushedCommit],
        activeProcesses: [String],
        preciousIgnoredFiles: [String],
        orphanFileCount: Int,
        featureSummary: FeatureSummary?,
        diskSizeBytes: Int64?,
        cacheDirs: [CacheDirItem] = [],
        reclaimableCacheBytes: Int64 = 0
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.mainRepoPath = mainRepoPath
        self.mainRepoName = mainRepoName
        self.branch = branch
        self.headCommit = headCommit
        self.headSubject = headSubject
        self.lastModified = lastModified
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.directoryExists = directoryExists
        self.source = source
        self.remoteName = remoteName
        self.modifiedCount = modifiedCount
        self.untrackedCount = untrackedCount
        self.aheadCount = aheadCount
        self.hasUpstream = hasUpstream
        self.isMergedToDefault = isMergedToDefault
        self.isSquashMerged = isSquashMerged
        self.prInfo = prInfo
        self.changedFiles = changedFiles
        self.unpushedCommits = unpushedCommits
        self.activeProcesses = activeProcesses
        self.preciousIgnoredFiles = preciousIgnoredFiles
        self.orphanFileCount = orphanFileCount
        self.featureSummary = featureSummary
        self.diskSizeBytes = diskSizeBytes
        self.cacheDirs = cacheDirs
        self.reclaimableCacheBytes = reclaimableCacheBytes
    }

    public var folderName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    public var isOrphan: Bool {
        kind == .brokenGitOrphan || kind == .directoryOrphan
    }

    public var isMissing: Bool {
        kind == .prunableMetadata
    }

    public var isEffectivelyMerged: Bool {
        isMergedToDefault || isSquashMerged || (prInfo?.isMerged == true)
    }

    public func displayBranch(language: AppLanguage) -> String {
        if kind == .brokenGitOrphan || kind == .directoryOrphan {
            return folderName
        }
        if !branch.isEmpty { return branch }
        if isDetached { return "detached @ \(headCommit.prefix(7))" }
        return L10n.tr("未知分支", "Unknown Branch", language: language)
    }

    public var isDirty: Bool {
        modifiedCount > 0 || untrackedCount > 0
    }

    public func isWithinFreshnessWindow(hours: Int, now: Date = Date()) -> Bool {
        guard hours > 0, directoryExists, !isOrphan, !isMissing, let lastModified else {
            return false
        }
        return now.timeIntervalSince(lastModified) < TimeInterval(hours) * 3600
    }

    public func isAutoSelectableSafe(freshnessHours: Int, now: Date = Date()) -> Bool {
        guard safetyLevel == .safe || safetyLevel == .missing else { return false }
        return !isWithinFreshnessWindow(hours: freshnessHours, now: now)
    }

    public var safetyLevel: SafetyLevel {
        if kind == .prunableMetadata { return .missing }
        if !activeProcesses.isEmpty || isDirty || isLocked { return .danger }
        if isOrphan { return .caution }
        if !preciousIgnoredFiles.isEmpty { return .caution }
        if aheadCount > 0 { return .caution }
        if !hasUpstream && !isEffectivelyMerged { return .caution }
        return .safe
    }

    public var formattedSize: String {
        guard let bytes = diskSizeBytes else { return "…" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: reclaimableCacheBytes, countStyle: .file)
    }

    public var canPush: Bool {
        directoryExists && !isMissing && !isOrphan && remoteName != nil
    }

    public var needsPush: Bool {
        guard canPush else { return false }
        return isDirty || aheadCount > 0 || (!hasUpstream && !isEffectivelyMerged)
    }

    public var canDeleteLocalBranch: Bool {
        guard !isOrphan, !isMissing, !isDetached, !branch.isEmpty else { return false }
        let protected: Set<String> = ["main", "master", "develop", "dev", "prd", "production", "staging"]
        return !protected.contains(branch.lowercased())
    }

    public var suggestedCommitMessage: String {
        if let firstTask = featureSummary?.agentTasks.first, !firstTask.isEmpty {
            let cleaned = firstTask
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "wip: \(String(cleaned.prefix(60)))"
        }
        if !branch.isEmpty {
            return "wip(\(branch)): save worktree changes"
        }
        return "wip: save worktree changes"
    }

    public var suggestedPushBranchName: String {
        if !branch.isEmpty && !isDetached {
            return branch
        }
        let cleaned = folderName
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = cleaned.isEmpty ? "worktree" : cleaned
        return "wt/\(base)"
    }

    public func safetySummary(language: AppLanguage, freshnessHours: Int = 24) -> String {
        if kind == .prunableMetadata {
            return L10n.tr(
                "磁盘目录已不存在，清理仅移除 Git 残留元数据，零风险。",
                "Directory is missing on disk. Cleanup only prunes stale Git metadata.",
                language: language
            )
        }
        if kind == .brokenGitOrphan {
            return L10n.tr(
                "关联的主仓库已从磁盘移除，这是一个断根孤儿目录（含 \(orphanFileCount) 个顶层项）。",
                "Main repository no longer exists on disk. Orphaned worktree directory (\(orphanFileCount) entries).",
                language: language
            )
        }
        if kind == .directoryOrphan {
            return L10n.tr(
                "Agent 目录下的无 .git 残骸目录（含 \(orphanFileCount) 个顶层项），Git 无法自动感知。",
                "Leftover directory without .git inside agent root (\(orphanFileCount) entries), invisible to git worktree list.",
                language: language
            )
        }

        var reasons: [String] = []
        if !activeProcesses.isEmpty {
            let procText = activeProcesses.joined(separator: ", ")
            reasons.append(L10n.tr("进程占用中：\(procText)", "Active process running: \(procText)", language: language))
        }
        if isLocked {
            reasons.append(L10n.tr("已被 git worktree lock 锁定", "Locked via git worktree lock", language: language))
        }
        if modifiedCount > 0 {
            reasons.append(L10n.tr("\(modifiedCount) 个已修改文件未提交", "\(modifiedCount) uncommitted modified files", language: language))
        }
        if untrackedCount > 0 {
            reasons.append(L10n.tr("\(untrackedCount) 个未跟踪新文件", "\(untrackedCount) untracked files", language: language))
        }
        if !preciousIgnoredFiles.isEmpty {
            let preview = preciousIgnoredFiles.prefix(2).joined(separator: ", ")
            let suffix = preciousIgnoredFiles.count > 2 ? " (+\(preciousIgnoredFiles.count - 2))" : ""
            reasons.append(L10n.tr("含本地忽略文件：\(preview)\(suffix)", "Contains precious ignored files: \(preview)\(suffix)", language: language))
        }
        if aheadCount > 0 {
            reasons.append(L10n.tr("\(aheadCount) 个本地提交未推送", "\(aheadCount) unpushed local commits", language: language))
        }
        if !hasUpstream && !isEffectivelyMerged && reasons.isEmpty {
            reasons.append(L10n.tr("本地独立分支尚未推送远端或合入主分支", "Local branch has no upstream and is not merged", language: language))
        }

        if reasons.isEmpty {
            if isWithinFreshnessWindow(hours: freshnessHours) {
                return L10n.tr(
                    "工作区干净，但近期活跃过（冷却保护中，全选安全项将自动跳过）。",
                    "Clean, but recently active (protected from bulk selection by freshness guard).",
                    language: language
                )
            }
            if isSquashMerged {
                return L10n.tr(
                    "工作区干净，且改动已通过 Squash/Rebase 等价合入主分支，可放心清理。",
                    "Clean and squash-merged into default branch. Safe to remove.",
                    language: language
                )
            }
            if prInfo?.isMerged == true {
                return L10n.tr(
                    "工作区干净，关联 PR #\(prInfo!.number) 已合并，可放心清理。",
                    "Clean and PR #\(prInfo!.number) is merged. Safe to remove.",
                    language: language
                )
            }
            if isMergedToDefault {
                return L10n.tr(
                    "工作区干净，且分支改动已合入主分支，可放心清理。",
                    "Clean and merged into default branch. Safe to remove.",
                    language: language
                )
            }
            return L10n.tr(
                "工作区完全干净，且所有提交已同步至远端，可放心清理。",
                "Clean working tree with all commits synced to remote. Safe to remove.",
                language: language
            )
        }
        return reasons.joined(separator: language.isChinese ? "；" : "; ")
    }
}

/// 筛选标签
public enum WorktreeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case safe
    case caution
    case danger
    case missing

    public var id: String { rawValue }

    public func title(language: AppLanguage) -> String {
        switch self {
        case .all: return L10n.tr("全部", "All", language: language)
        case .safe: return L10n.tr("安全", "Safe", language: language)
        case .caution: return L10n.tr("待确认", "Review", language: language)
        case .danger: return L10n.tr("有改动", "Active", language: language)
        case .missing: return L10n.tr("幽灵", "Ghost", language: language)
        }
    }

    public func matches(_ item: WorktreeItem) -> Bool {
        switch self {
        case .all: return true
        case .safe: return item.safetyLevel == .safe
        case .caution: return item.safetyLevel == .caution
        case .danger: return item.safetyLevel == .danger
        case .missing: return item.safetyLevel == .missing
        }
    }
}

/// 清理结果
public struct CleanupReport: Identifiable, Sendable {
    public let id = UUID()
    public let succeededCount: Int
    public let failedItems: [(path: String, error: String)]
    public let freedBytes: Int64
    public let movedToTrash: Bool

    public init(succeededCount: Int, failedItems: [(path: String, error: String)], freedBytes: Int64, movedToTrash: Bool) {
        self.succeededCount = succeededCount
        self.failedItems = failedItems
        self.freedBytes = freedBytes
        self.movedToTrash = movedToTrash
    }
}

/// 推送结果
public struct PushResultInfo: Sendable {
    public let remote: String
    public let branch: String
    public let committedChanges: Bool
    public let removedAfterPush: Bool

    public init(remote: String, branch: String, committedChanges: Bool, removedAfterPush: Bool) {
        self.remote = remote
        self.branch = branch
        self.committedChanges = committedChanges
        self.removedAfterPush = removedAfterPush
    }
}

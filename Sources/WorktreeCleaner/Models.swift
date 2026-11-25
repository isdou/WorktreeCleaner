import Foundation
import SwiftUI

/// Worktree 来源分类
enum WorktreeSource: String, Codable, CaseIterable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
    case cursor = "Cursor"
    case trae = "Trae"
    case local = "Local"

    var color: Color {
        switch self {
        case .codex: return .blue
        case .claude: return .orange
        case .cursor: return .purple
        case .trae: return .teal
        case .local: return .secondary
        }
    }

    var icon: String {
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
enum WorktreeKind: String, Sendable {
    case linkedWorktree      // 正常关联到主仓库的子 Worktree
    case prunableMetadata    // 磁盘目录已丢失，仅剩 Git 幽灵元数据
    case brokenGitOrphan     // 存在 .git 文件但指向的主仓库/gitdir 已删除
    case directoryOrphan     // Agent worktree 目录下无 .git 的残骸目录
}

/// Worktree 安全清理等级
enum SafetyLevel: Int, Comparable, CaseIterable, Sendable {
    case missing = 0   // 幽灵元数据
    case safe = 1      // 干净且已同步/合并，安全可删
    case caution = 2   // 待确认（未推送、含敏感忽略文件、或孤儿残骸）
    case danger = 3    // 有未提交改动、被锁定、或有进程运行中

    static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    func label(language: AppLanguage) -> String {
        switch self {
        case .missing: return L10n.tr("幽灵记录", "Ghost", language: language)
        case .safe: return L10n.tr("安全可删", "Safe", language: language)
        case .caution: return L10n.tr("待确认", "Review", language: language)
        case .danger: return L10n.tr("有改动", "Active / Dirty", language: language)
        }
    }

    var color: Color {
        switch self {
        case .missing: return .secondary
        case .safe: return .green
        case .caution: return .orange
        case .danger: return .red
        }
    }

    var sfSymbol: String {
        switch self {
        case .missing: return "questionmark.folder"
        case .safe: return "checkmark.shield.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .danger: return "hand.raised.fill"
        }
    }
}

/// 单个文件变更项（来自 git status --porcelain）
struct ChangedFileItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let statusCode: String
    let path: String

    var badgeText: String {
        let trimmed = statusCode.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "M" : trimmed
    }

    var badgeColor: Color {
        if statusCode.contains("?") { return .orange }
        if statusCode.contains("D") { return .red }
        if statusCode.contains("A") { return .green }
        return .blue
    }
}

/// 未推送提交项
struct UnpushedCommit: Identifiable, Hashable, Sendable {
    let id: String // short hash
    let message: String
}

/// 相对主分支新增的提交记录
struct BranchCommit: Identifiable, Hashable, Sendable {
    let id: String // short hash
    let relativeDate: String
    let subject: String
}

/// 相对主分支改动的文件行数统计
struct DiffFileStat: Identifiable, Hashable, Sendable {
    let id: String // path
    let path: String
    let insertions: Int
    let deletions: Int

    var totalDelta: Int { insertions + deletions }
}

/// GitHub PR 关联状态（通过 gh CLI 可选获取）
struct PullRequestInfo: Hashable, Sendable {
    let number: Int
    let state: String // OPEN, MERGED, CLOSED
    let url: String

    var isMerged: Bool {
        state.uppercased() == "MERGED"
    }

    func badgeText(language: AppLanguage) -> String {
        switch state.uppercased() {
        case "MERGED": return L10n.tr("PR #\(number) 已合并", "PR #\(number) Merged", language: language)
        case "CLOSED": return L10n.tr("PR #\(number) 已关闭", "PR #\(number) Closed", language: language)
        default: return L10n.tr("PR #\(number) 进行中", "PR #\(number) Open", language: language)
        }
    }

    var badgeColor: Color {
        switch state.uppercased() {
        case "MERGED": return .purple
        case "CLOSED": return .secondary
        default: return .green
        }
    }
}

/// 可再生构建与依赖缓存目录项
struct CacheDirItem: Identifiable, Hashable, Sendable {
    let id: String // full path
    let relativePath: String
    let sizeBytes: Int64
}

/// Worktree 做了什么功能的完整摘要
struct FeatureSummary: Hashable, Sendable {
    let baseBranch: String?
    let totalCommitCount: Int
    let branchCommits: [BranchCommit]
    let filesChangedCount: Int
    let insertions: Int
    let deletions: Int
    let touchedAreas: [String]
    let topFiles: [DiffFileStat]
    let agentTasks: [String]

    var hasBranchWork: Bool {
        totalCommitCount > 0 || filesChangedCount > 0
    }
}

/// 单个 Git Worktree 的完整体检信息
struct WorktreeItem: Identifiable, Hashable, Sendable {
    let id: String // canonical path
    let path: String
    let kind: WorktreeKind
    let mainRepoPath: String
    let mainRepoName: String
    let branch: String
    let headCommit: String
    let headSubject: String
    let lastModified: Date?
    let isDetached: Bool
    let isLocked: Bool
    let directoryExists: Bool
    let source: WorktreeSource
    let remoteName: String?

    // Git 体检指标
    let modifiedCount: Int
    let untrackedCount: Int
    let aheadCount: Int
    let hasUpstream: Bool
    let isMergedToDefault: Bool
    let isSquashMerged: Bool
    let prInfo: PullRequestInfo?
    let changedFiles: [ChangedFileItem]
    let unpushedCommits: [UnpushedCommit]

    // 高级防误删护栏指标
    let activeProcesses: [String]
    let preciousIgnoredFiles: [String]
    let orphanFileCount: Int

    // 功能演进摘要
    let featureSummary: FeatureSummary?

    // 磁盘占用与可清理缓存（异步填充）
    var diskSizeBytes: Int64?
    var cacheDirs: [CacheDirItem] = []
    var reclaimableCacheBytes: Int64 = 0

    var folderName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var isOrphan: Bool {
        kind == .brokenGitOrphan || kind == .directoryOrphan
    }

    var isMissing: Bool {
        kind == .prunableMetadata
    }

    var isEffectivelyMerged: Bool {
        isMergedToDefault || isSquashMerged || (prInfo?.isMerged == true)
    }

    func displayBranch(language: AppLanguage) -> String {
        if kind == .brokenGitOrphan {
            return folderName
        }
        if kind == .directoryOrphan {
            return folderName
        }
        if !branch.isEmpty { return branch }
        if isDetached { return "detached @ \(headCommit.prefix(7))" }
        return L10n.tr("未知分支", "Unknown Branch", language: language)
    }

    var isDirty: Bool {
        modifiedCount > 0 || untrackedCount > 0
    }

    /// 是否处于新鲜度冷却保护窗口内（刚新建/刚改动过的干净目录不纳入一键全选）
    func isWithinFreshnessWindow(hours: Int, now: Date = Date()) -> Bool {
        guard hours > 0, directoryExists, !isOrphan, !isMissing, let lastModified else {
            return false
        }
        return now.timeIntervalSince(lastModified) < TimeInterval(hours) * 3600
    }

    /// 是否允许通过“全选安全项”自动勾选
    func isAutoSelectableSafe(freshnessHours: Int, now: Date = Date()) -> Bool {
        guard safetyLevel == .safe || safetyLevel == .missing else { return false }
        return !isWithinFreshnessWindow(hours: freshnessHours, now: now)
    }

    /// 综合安全等级判定
    var safetyLevel: SafetyLevel {
        if kind == .prunableMetadata {
            return .missing
        }
        if !activeProcesses.isEmpty || isDirty || isLocked {
            return .danger
        }
        if isOrphan {
            return .caution
        }
        if !preciousIgnoredFiles.isEmpty {
            return .caution
        }
        if aheadCount > 0 {
            return .caution
        }
        if !hasUpstream && !isEffectivelyMerged {
            return .caution
        }
        return .safe
    }

    var formattedSize: String {
        guard let bytes = diskSizeBytes else { return "…" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: reclaimableCacheBytes, countStyle: .file)
    }

    /// 是否可以推送到远端
    var canPush: Bool {
        directoryExists && !isMissing && !isOrphan && remoteName != nil
    }

    var needsPush: Bool {
        guard canPush else { return false }
        return isDirty || aheadCount > 0 || (!hasUpstream && !isEffectivelyMerged)
    }

    /// 是否适合顺手删除对应的本地分支
    var canDeleteLocalBranch: Bool {
        guard !isOrphan, !isMissing, !isDetached, !branch.isEmpty else { return false }
        let protected: Set<String> = ["main", "master", "develop", "dev", "prd", "production", "staging"]
        return !protected.contains(branch.lowercased())
    }

    var suggestedCommitMessage: String {
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

    var suggestedPushBranchName: String {
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

    func safetySummary(language: AppLanguage, freshnessHours: Int = 24) -> String {
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
enum WorktreeFilter: String, CaseIterable, Identifiable {
    case all
    case safe
    case caution
    case danger
    case missing

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .all: return L10n.tr("全部", "All", language: language)
        case .safe: return L10n.tr("安全", "Safe", language: language)
        case .caution: return L10n.tr("待确认", "Review", language: language)
        case .danger: return L10n.tr("有改动", "Active", language: language)
        case .missing: return L10n.tr("幽灵", "Ghost", language: language)
        }
    }

    func matches(_ item: WorktreeItem) -> Bool {
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
struct CleanupReport: Identifiable, Sendable {
    let id = UUID()
    let succeededCount: Int
    let failedItems: [(path: String, error: String)]
    let freedBytes: Int64
    let movedToTrash: Bool
}

/// 推送结果
struct PushResultInfo: Sendable {
    let remote: String
    let branch: String
    let committedChanges: Bool
    let removedAfterPush: Bool
}

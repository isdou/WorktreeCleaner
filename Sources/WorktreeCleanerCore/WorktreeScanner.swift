import Foundation

/// Git Worktree 全盘扫描、功能剖析、四重防误删护栏与安全清理引擎
public enum WorktreeScanner {

    /// 默认扫描的通用开发项目目录（不含任何个人硬编码路径）
    public static var defaultSearchRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Projects",
            "\(home)/Developer",
            "\(home)/Code",
            "\(home)/Workspace",
            "\(home)/src",
            "\(home)/Desktop",
            "\(home)/Downloads"
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// 常见 AI Agent 工具存放 Worktree 的独立目录
    public static var agentWorktreeRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.codex/worktrees",
            "\(home)/.claude/worktrees",
            "\(home)/.cursor/worktrees",
            "\(home)/.trae-cn/worktrees"
        ]
    }

    /// 受 macOS TCC 隐私保护的常见用户目录
    public static var protectedTCCRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            canonicalPath("\(home)/Desktop"),
            canonicalPath("\(home)/Downloads"),
            canonicalPath("\(home)/Documents")
        ]
    }

    private static let skipDiscoveryNames: Set<String> = [
        "node_modules", "Pods", "Carthage", "DerivedData", "build", "dist",
        "target", ".build", ".swiftpm", ".venv", "venv", "__pycache__",
        "Library", "Applications", "Pictures", "Movies", "Music"
    ]

    private static let cacheDirectoryNames: Set<String> = [
        "node_modules", ".next", ".nuxt", "dist", "build", ".build", ".swiftpm",
        "DerivedData", ".codex-derived-data", "target", ".venv", "venv",
        "__pycache__", ".pytest_cache", ".turbo", ".parcel-cache", ".cache", "coverage"
    ]

    // MARK: - 1. 全量扫描入口

    public static func scanAll(searchRoots: [String]) async -> [WorktreeItem] {
        // 先串行预检受 TCC 保护的目录，避免后续并发 git/du 子进程同时撞门引发多次弹窗
        let deniedRoots = preflightProtectedRoots(neededFor: searchRoots)
        let discovery = discoverRepositoriesAndOrphans(searchRoots: searchRoots, deniedRoots: deniedRoots)

        // 1. 并发拉取所有有效主仓库下的关联 worktree 列表，以及进程占用快照 & Codex 会话意图
        async let lsofOut = ShellRunner.run("/usr/sbin/lsof", arguments: ["-a", "-d", "cwd", "-Fpcn"], timeout: 5)
        let codexTasksByPath = AgentSessionStore.loadCodexThreadTitles()

        var rawEntries: [(mainRepo: String, entry: PorcelainEntry)] = []
        await withTaskGroup(of: [(String, PorcelainEntry)].self) { group in
            for repo in discovery.mainRepos {
                group.addTask {
                    let entries = await listPorcelainWorktrees(in: repo)
                    return entries.map { (repo, $0) }
                }
            }
            for await batch in group {
                rawEntries.append(contentsOf: batch)
            }
        }

        // 去重并过滤主仓库自身及被用户拒绝的受保护目录
        var seenPaths = Set<String>()
        var childTargets: [(mainRepo: String, entry: PorcelainEntry)] = []
        for item in rawEntries {
            let normMain = canonicalPath(item.mainRepo)
            let normPath = canonicalPath(item.entry.path)
            if normPath == normMain { continue }
            if isPath(normMain, underAnyOf: deniedRoots) || isPath(normPath, underAnyOf: deniedRoots) {
                continue
            }
            if seenPaths.insert(normPath).inserted {
                childTargets.append((normMain, item.entry))
            }
        }

        // 2. 加载 Claude Code 会话意图（批量针对本次发现的子 worktree + 孤儿目录）
        let allCandidatePaths = childTargets.map(\.entry.path) + discovery.brokenOrphans + discovery.directoryOrphans
        let claudeTasksByPath = AgentSessionStore.loadClaudeSessionTitles(for: allCandidatePaths)

        // 3. 解析活跃进程 cwd 映射
        let lsofResult = await lsofOut
        let processEntries = parseLsofCwdOutput(lsofResult.stdout, excludingPID: ProcessInfo.processInfo.processIdentifier)

        // 4. 按主仓库并发批量查询 GitHub PR 状态（如本机安装了 gh 且为 GitHub 仓库）
        let prsByRepo = await loadGitHubPullRequests(for: discovery.mainRepos)

        // 5. 并发体检每个正常/幽灵 Worktree + 孤儿目录
        var inspected: [WorktreeItem] = []
        await withTaskGroup(of: WorktreeItem.self) { group in
            for target in childTargets {
                let normPath = canonicalPath(target.entry.path)
                let mergedTasks = mergeTasks(codex: codexTasksByPath, claude: claudeTasksByPath, path: normPath)
                let activeProcs = matchingProcesses(for: normPath, entries: processEntries)
                let repoPRs = prsByRepo[target.mainRepo] ?? [:]

                group.addTask {
                    await inspectLinkedWorktree(
                        mainRepo: target.mainRepo,
                        entry: target.entry,
                        agentTasks: mergedTasks,
                        activeProcesses: activeProcs,
                        repoPRs: repoPRs
                    )
                }
            }

            for orphanPath in discovery.brokenOrphans {
                let normPath = canonicalPath(orphanPath)
                if seenPaths.contains(normPath) { continue }
                let mergedTasks = mergeTasks(codex: codexTasksByPath, claude: claudeTasksByPath, path: normPath)
                let activeProcs = matchingProcesses(for: normPath, entries: processEntries)
                group.addTask {
                    inspectOrphanDirectory(
                        path: orphanPath,
                        kind: .brokenGitOrphan,
                        agentTasks: mergedTasks,
                        activeProcesses: activeProcs
                    )
                }
            }

            for orphanPath in discovery.directoryOrphans {
                let normPath = canonicalPath(orphanPath)
                if seenPaths.contains(normPath) { continue }
                let mergedTasks = mergeTasks(codex: codexTasksByPath, claude: claudeTasksByPath, path: normPath)
                let activeProcs = matchingProcesses(for: normPath, entries: processEntries)
                group.addTask {
                    inspectOrphanDirectory(
                        path: orphanPath,
                        kind: .directoryOrphan,
                        agentTasks: mergedTasks,
                        activeProcesses: activeProcs
                    )
                }
            }

            for await item in group {
                inspected.append(item)
            }
        }

        return inspected.sorted { lhs, rhs in
            if lhs.safetyLevel != rhs.safetyLevel {
                return lhs.safetyLevel < rhs.safetyLevel
            }
            if lhs.isOrphan != rhs.isOrphan {
                return !lhs.isOrphan && rhs.isOrphan
            }
            if lhs.mainRepoName != rhs.mainRepoName {
                return lhs.mainRepoName.localizedCaseInsensitiveCompare(rhs.mainRepoName) == .orderedAscending
            }
            return lhs.folderName.localizedCaseInsensitiveCompare(rhs.folderName) == .orderedAscending
        }
    }

    // MARK: - 1.5 TCC 受保护目录串行预检门禁

    public static func isPath(_ path: String, underAnyOf roots: Set<String>) -> Bool {
        let norm = canonicalPath(path)
        for root in roots {
            let normRoot = canonicalPath(root)
            if norm == normRoot || norm.hasPrefix(normRoot + "/") {
                return true
            }
        }
        return false
    }

    public static func matchingProtectedRoots(
        for paths: [String],
        protectedRoots: [String] = protectedTCCRoots
    ) -> [String] {
        var matched: [String] = []
        for tccRoot in protectedRoots {
            let normRoot = canonicalPath(tccRoot)
            let needsRoot = paths.contains { path in
                let normPath = canonicalPath(path)
                return normPath == normRoot || normPath.hasPrefix(normRoot + "/")
            }
            if needsRoot {
                matched.append(normRoot)
            }
        }
        return matched
    }

    /// 仅从非受保护的 ~/.codex/worktrees 等目录读取 .git 文件内容，反推可能涉及的主仓库路径
    private static func collectAgentLinkedMainRepoPaths() -> [String] {
        let fm = FileManager.default
        var linkedMains: [String] = []

        func extractMainRepo(at dirPath: String) -> String? {
            let gitPath = (dirPath as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: gitPath, isDirectory: &isDir), !isDir.boolValue else { return nil }
            guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8),
                  let range = content.range(of: "gitdir:") else { return nil }
            let rawGitDir = content[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let wtRange = rawGitDir.range(of: "/.git/worktrees/") {
                return canonicalPath(String(rawGitDir[..<wtRange.lowerBound]))
            }
            return nil
        }

        for agentRoot in agentWorktreeRoots {
            guard fm.fileExists(atPath: agentRoot),
                  let level1 = try? fm.contentsOfDirectory(atPath: agentRoot) else { continue }
            for name1 in level1 where !name1.hasPrefix(".") {
                let path1 = (agentRoot as NSString).appendingPathComponent(name1)
                if let main = extractMainRepo(at: path1) {
                    linkedMains.append(main)
                    continue
                }
                guard let level2 = try? fm.contentsOfDirectory(atPath: path1) else { continue }
                for name2 in level2 where !name2.hasPrefix(".") {
                    let path2 = (path1 as NSString).appendingPathComponent(name2)
                    if let main = extractMainRepo(at: path2) {
                        linkedMains.append(main)
                    }
                }
            }
        }
        return linkedMains
    }

    /// 在主进程内串行预检一次受 TCC 保护的根目录；若用户拒绝授权，返回被拒绝根目录集合以便后续跳过
    private static func preflightProtectedRoots(neededFor searchRoots: [String]) -> Set<String> {
        let candidatePaths = searchRoots + collectAgentLinkedMainRepoPaths()
        let rootsToCheck = matchingProtectedRoots(for: candidatePaths)
        let fm = FileManager.default
        var denied = Set<String>()

        for tccRoot in rootsToCheck {
            do {
                _ = try fm.contentsOfDirectory(atPath: tccRoot)
            } catch let error as NSError {
                if (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
                    || (error.domain == NSPOSIXErrorDomain && (error.code == EPERM || error.code == EACCES)) {
                    denied.insert(tccRoot)
                }
            }
        }
        return denied
    }

    // MARK: - 2. 仓库与孤儿目录发现（2 层目录 + Agent 目录物理对账）

    private struct DiscoveryResult {
        var mainRepos: [String]
        var brokenOrphans: [String]
        var directoryOrphans: [String]
    }

    private static func discoverRepositoriesAndOrphans(
        searchRoots: [String],
        deniedRoots: Set<String>
    ) -> DiscoveryResult {
        let fm = FileManager.default
        var repos = Set<String>()
        var brokenOrphans = Set<String>()
        var directoryOrphans = Set<String>()

        func inspectGitFolder(_ dirPath: String) -> Bool {
            if isPath(dirPath, underAnyOf: deniedRoots) { return false }
            switch classifyGitFolder(dirPath) {
            case .mainRepo(let mainPath):
                if !isPath(mainPath, underAnyOf: deniedRoots) {
                    repos.insert(canonicalPath(mainPath))
                }
                return true
            case .linkedWorktree(let mainPath):
                if !isPath(mainPath, underAnyOf: deniedRoots) {
                    repos.insert(canonicalPath(mainPath))
                }
                return true
            case .brokenOrphan:
                brokenOrphans.insert(canonicalPath(dirPath))
                return true
            case .notGit:
                return false
            }
        }

        // A. 用户目录 0 -> 1 -> 2 层发现
        for root in searchRoots {
            if isPath(root, underAnyOf: deniedRoots) { continue }
            guard fm.fileExists(atPath: root) else { continue }
            _ = inspectGitFolder(root)

            guard let level1 = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name1 in level1 where !name1.hasPrefix(".") && !skipDiscoveryNames.contains(name1) {
                let path1 = (root as NSString).appendingPathComponent(name1)
                var isDir1: ObjCBool = false
                guard fm.fileExists(atPath: path1, isDirectory: &isDir1), isDir1.boolValue else { continue }
                let wasGit1 = inspectGitFolder(path1)

                // 如果一层已是主仓库，再检查其内置 .claude/worktrees 与 .worktrees
                if wasGit1 {
                    for hiddenWtRoot in ["\(path1)/.claude/worktrees", "\(path1)/.worktrees"] {
                        scanAgentWorktreeDir(
                            hiddenWtRoot,
                            deniedRoots: deniedRoots,
                            repos: &repos,
                            brokenOrphans: &brokenOrphans,
                            directoryOrphans: &directoryOrphans
                        )
                    }
                    continue
                }

                // 否则继续下潜第二层（如 ~/Projects/company/repo）
                guard let level2 = try? fm.contentsOfDirectory(atPath: path1) else { continue }
                for name2 in level2 where !name2.hasPrefix(".") && !skipDiscoveryNames.contains(name2) {
                    let path2 = (path1 as NSString).appendingPathComponent(name2)
                    var isDir2: ObjCBool = false
                    guard fm.fileExists(atPath: path2, isDirectory: &isDir2), isDir2.boolValue else { continue }
                    if inspectGitFolder(path2) {
                        for hiddenWtRoot in ["\(path2)/.claude/worktrees", "\(path2)/.worktrees"] {
                            scanAgentWorktreeDir(
                                hiddenWtRoot,
                                deniedRoots: deniedRoots,
                                repos: &repos,
                                brokenOrphans: &brokenOrphans,
                                directoryOrphans: &directoryOrphans
                            )
                        }
                    }
                }
            }
        }

        // B. 扫描 AI Agent 专用 Worktree 根目录，并对无 .git 的残留目录做物理对账
        for agentRoot in agentWorktreeRoots {
            scanAgentWorktreeDir(
                agentRoot,
                deniedRoots: deniedRoots,
                repos: &repos,
                brokenOrphans: &brokenOrphans,
                directoryOrphans: &directoryOrphans
            )
        }

        return DiscoveryResult(
            mainRepos: Array(repos).sorted(),
            brokenOrphans: Array(brokenOrphans).sorted(),
            directoryOrphans: Array(directoryOrphans).sorted()
        )
    }

    private static func scanAgentWorktreeDir(
        _ root: String,
        deniedRoots: Set<String>,
        repos: inout Set<String>,
        brokenOrphans: inout Set<String>,
        directoryOrphans: inout Set<String>
    ) {
        if isPath(root, underAnyOf: deniedRoots) { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root),
              let level1 = try? fm.contentsOfDirectory(atPath: root) else { return }

        for name1 in level1 where !name1.hasPrefix(".") {
            let path1 = (root as NSString).appendingPathComponent(name1)
            var isDir1: ObjCBool = false
            guard fm.fileExists(atPath: path1, isDirectory: &isDir1), isDir1.boolValue else { continue }

            switch classifyGitFolder(path1) {
            case .mainRepo(let main), .linkedWorktree(let main):
                if !isPath(main, underAnyOf: deniedRoots) {
                    repos.insert(canonicalPath(main))
                }
                continue
            case .brokenOrphan:
                brokenOrphans.insert(canonicalPath(path1))
                continue
            case .notGit:
                break
            }

            // 检查 2 层嵌套结构（例如 ~/.codex/worktrees/<id>/<repo>）
            guard let level2 = try? fm.contentsOfDirectory(atPath: path1) else { continue }
            var foundNestedGit = false
            for name2 in level2 where !name2.hasPrefix(".") {
                let path2 = (path1 as NSString).appendingPathComponent(name2)
                var isDir2: ObjCBool = false
                guard fm.fileExists(atPath: path2, isDirectory: &isDir2), isDir2.boolValue else { continue }
                switch classifyGitFolder(path2) {
                case .mainRepo(let main), .linkedWorktree(let main):
                    if !isPath(main, underAnyOf: deniedRoots) {
                        repos.insert(canonicalPath(main))
                    }
                    foundNestedGit = true
                case .brokenOrphan:
                    brokenOrphans.insert(canonicalPath(path2))
                    foundNestedGit = true
                case .notGit:
                    break
                }
            }

            // 若既不是 git 目录、也没有任何子目录是 git 目录，但里面有实质残骸文件，判定为断根/空壳孤儿目录
            if !foundNestedGit {
                let meaningful = level2.filter { $0 != ".DS_Store" && $0 != ".metadata_never_index" && $0 != ".codex-worktree-name" }
                if !meaningful.isEmpty {
                    directoryOrphans.insert(canonicalPath(path1))
                }
            }
        }
    }

    private enum GitFolderKind {
        case mainRepo(String)
        case linkedWorktree(String)
        case brokenOrphan
        case notGit
    }

    private static func classifyGitFolder(_ dirPath: String) -> GitFolderKind {
        let fm = FileManager.default
        let gitPath = (dirPath as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gitPath, isDirectory: &isDir) else { return .notGit }

        if isDir.boolValue {
            let wtDir = (gitPath as NSString).appendingPathComponent("worktrees")
            if fm.fileExists(atPath: wtDir) {
                return .mainRepo(dirPath)
            }
            return .notGit
        } else {
            guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8),
                  let range = content.range(of: "gitdir:") else { return .brokenOrphan }
            let rawGitDir = content[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let wtRange = rawGitDir.range(of: "/.git/worktrees/") {
                let mainRepo = String(rawGitDir[..<wtRange.lowerBound])
                if fm.fileExists(atPath: mainRepo) && fm.fileExists(atPath: rawGitDir) {
                    return .linkedWorktree(mainRepo)
                }
            }
            return .brokenOrphan
        }
    }

    // MARK: - 3. Git Worktree 枚举 & 体检

    private struct PorcelainEntry: Sendable {
        var path: String = ""
        var head: String = ""
        var branch: String = ""
        var isDetached: Bool = false
        var isLocked: Bool = false
        var isPrunable: Bool = false
    }

    private static func listPorcelainWorktrees(in mainRepo: String) async -> [PorcelainEntry] {
        let res = await ShellRunner.git(["worktree", "list", "--porcelain"], in: mainRepo)
        guard res.succeeded else { return [] }

        var entries: [PorcelainEntry] = []
        var current = PorcelainEntry()

        for rawLine in res.stdout.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if !current.path.isEmpty {
                    entries.append(current)
                    current = PorcelainEntry()
                }
                continue
            }
            if line.hasPrefix("worktree ") {
                current.path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                current.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                current.branch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            } else if line == "detached" {
                current.isDetached = true
            } else if line.hasPrefix("locked") {
                current.isLocked = true
            } else if line.hasPrefix("prunable") {
                current.isPrunable = true
            }
        }
        if !current.path.isEmpty {
            entries.append(current)
        }
        return entries
    }

    private static func inspectLinkedWorktree(
        mainRepo: String,
        entry: PorcelainEntry,
        agentTasks: [String],
        activeProcesses: [String],
        repoPRs: [String: PullRequestInfo]
    ) async -> WorktreeItem {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: entry.path)
        let repoName = URL(fileURLWithPath: mainRepo).lastPathComponent
        let source = detectSource(path: entry.path)
        let normPath = canonicalPath(entry.path)
        let prInfo = entry.branch.isEmpty ? nil : repoPRs[entry.branch]

        let lastMod: Date? = {
            guard exists,
                  let attrs = try? fm.attributesOfItem(atPath: entry.path),
                  let date = attrs[.modificationDate] as? Date else { return nil }
            return date
        }()

        guard exists && !entry.isPrunable else {
            let fallbackSummary = agentTasks.isEmpty
                ? nil
                : FeatureSummary(
                    baseBranch: nil,
                    totalCommitCount: 0,
                    branchCommits: [],
                    filesChangedCount: 0,
                    insertions: 0,
                    deletions: 0,
                    touchedAreas: [],
                    topFiles: [],
                    agentTasks: agentTasks
                )
            return WorktreeItem(
                id: normPath,
                path: entry.path,
                kind: .prunableMetadata,
                mainRepoPath: mainRepo,
                mainRepoName: repoName,
                branch: entry.branch,
                headCommit: entry.head,
                headSubject: "",
                lastModified: lastMod,
                isDetached: entry.isDetached,
                isLocked: entry.isLocked,
                directoryExists: exists,
                source: source,
                remoteName: nil,
                modifiedCount: 0,
                untrackedCount: 0,
                aheadCount: 0,
                hasUpstream: false,
                isMergedToDefault: false,
                isSquashMerged: false,
                prInfo: prInfo,
                changedFiles: [],
                unpushedCommits: [],
                activeProcesses: [],
                preciousIgnoredFiles: [],
                orphanFileCount: 0,
                featureSummary: fallbackSummary,
                diskSizeBytes: 0
            )
        }

        async let statusOut = ShellRunner.git(["status", "--porcelain=v1", "--ignored=matching", "-unormal"], in: entry.path)
        async let subjectOut = ShellRunner.git(["log", "-1", "--format=%s"], in: entry.path)
        async let upstreamOut = ShellRunner.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: entry.path)
        async let remoteOut = ShellRunner.git(["remote"], in: entry.path)
        async let baseBranchOut = detectDefaultBaseBranch(in: entry.path)

        let status = await statusOut
        let subject = await subjectOut
        let upstream = await upstreamOut
        let remotes = await remoteOut
        let baseBranch = await baseBranchOut

        let remoteList = remotes.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let preferredRemote = remoteList.contains("origin") ? "origin" : remoteList.first

        var modifiedCount = 0
        var untrackedCount = 0
        var changedFiles: [ChangedFileItem] = []

        if status.succeeded {
            for line in status.stdout.components(separatedBy: .newlines) where line.count >= 4 {
                let code = String(line.prefix(2))
                if code == "!!" { continue }
                let filePath = String(line.dropFirst(3))
                if code == "??" {
                    untrackedCount += 1
                } else {
                    modifiedCount += 1
                }
                if changedFiles.count < 80 {
                    changedFiles.append(ChangedFileItem(statusCode: code, path: filePath))
                }
            }
        }

        let preciousIgnored = parsePreciousIgnoredFiles(fromGitStatus: status.stdout)

        let hasUpstream = upstream.succeeded && !upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var aheadCount = 0
        var unpushedCommits: [UnpushedCommit] = []

        if hasUpstream {
            let logRes = await ShellRunner.git(["log", "@{u}..HEAD", "--oneline", "-n", "20"], in: entry.path)
            if logRes.succeeded {
                let lines = logRes.stdout
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                aheadCount = lines.count
                unpushedCommits = lines.map { line in
                    let parts = line.split(separator: " ", maxSplits: 1)
                    let hash = parts.first.map(String.init) ?? ""
                    let msg = parts.count > 1 ? String(parts[1]) : ""
                    return UnpushedCommit(id: hash, message: msg)
                }
            }
        }

        async let isMergedOut = checkMergedToBase(in: entry.path, baseBranch: baseBranch)
        async let featureSummaryOut = buildFeatureSummary(
            in: entry.path,
            baseBranch: baseBranch,
            agentTasks: agentTasks
        )

        let isMerged = await isMergedOut
        var isSquashMerged = false
        if !isMerged, let base = baseBranch {
            let cherry = await ShellRunner.git(["cherry", base, "HEAD"], in: entry.path)
            if cherry.succeeded {
                isSquashMerged = isSquashMergedOutput(cherry.stdout)
            }
        }

        let featureSummary = await featureSummaryOut

        return WorktreeItem(
            id: normPath,
            path: entry.path,
            kind: .linkedWorktree,
            mainRepoPath: mainRepo,
            mainRepoName: repoName,
            branch: entry.branch,
            headCommit: entry.head,
            headSubject: subject.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            lastModified: lastMod,
            isDetached: entry.isDetached,
            isLocked: entry.isLocked,
            directoryExists: true,
            source: source,
            remoteName: preferredRemote,
            modifiedCount: modifiedCount,
            untrackedCount: untrackedCount,
            aheadCount: aheadCount,
            hasUpstream: hasUpstream,
            isMergedToDefault: isMerged,
            isSquashMerged: isSquashMerged,
            prInfo: prInfo,
            changedFiles: changedFiles,
            unpushedCommits: unpushedCommits,
            activeProcesses: activeProcesses,
            preciousIgnoredFiles: preciousIgnored,
            orphanFileCount: 0,
            featureSummary: featureSummary,
            diskSizeBytes: nil
        )
    }

    private static func inspectOrphanDirectory(
        path: String,
        kind: WorktreeKind,
        agentTasks: [String],
        activeProcesses: [String]
    ) -> WorktreeItem {
        let fm = FileManager.default
        let normPath = canonicalPath(path)
        let source = detectSource(path: path)
        let lastMod = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        let children = ((try? fm.contentsOfDirectory(atPath: path)) ?? [])
            .filter { $0 != ".DS_Store" && $0 != ".metadata_never_index" && $0 != ".git" }

        let fallbackSummary = agentTasks.isEmpty
            ? nil
            : FeatureSummary(
                baseBranch: nil,
                totalCommitCount: 0,
                branchCommits: [],
                filesChangedCount: 0,
                insertions: 0,
                deletions: 0,
                touchedAreas: [],
                topFiles: [],
                agentTasks: agentTasks
            )

        return WorktreeItem(
            id: normPath,
            path: path,
            kind: kind,
            mainRepoPath: "",
            mainRepoName: "Orphaned",
            branch: URL(fileURLWithPath: path).lastPathComponent,
            headCommit: "",
            headSubject: "",
            lastModified: lastMod,
            isDetached: false,
            isLocked: false,
            directoryExists: fm.fileExists(atPath: path),
            source: source,
            remoteName: nil,
            modifiedCount: 0,
            untrackedCount: 0,
            aheadCount: 0,
            hasUpstream: false,
            isMergedToDefault: false,
            isSquashMerged: false,
            prInfo: nil,
            changedFiles: [],
            unpushedCommits: [],
            activeProcesses: activeProcesses,
            preciousIgnoredFiles: [],
            orphanFileCount: children.count,
            featureSummary: fallbackSummary,
            diskSizeBytes: nil
        )
    }

    // MARK: - 4. 纯逻辑检测与解析函数（含单测覆盖）

    /// 判断 git status --ignored 输出中的敏感高价值忽略文件（排除示例模板与已知依赖目录）
    public static func isPreciousIgnoredFile(_ relativePath: String) -> Bool {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/\""))
        guard !trimmed.isEmpty else { return false }

        // 跳过已知缓存/依赖目录内部文件
        let components = trimmed.split(separator: "/").map(String.init)
        if components.contains(where: { cacheDirectoryNames.contains($0) }) {
            return false
        }

        let fileName = (trimmed as NSString).lastPathComponent.lowercased()
        let templateSuffixes = [".example", ".sample", ".template", ".dist"]

        if fileName == ".env" || fileName.hasPrefix(".env.") {
            return !templateSuffixes.contains(where: { fileName.hasSuffix($0) })
        }

        let exactNames: Set<String> = [
            "secrets.json", "credentials.json", ".mcp.json",
            "local.properties", ".dev.vars", "dev.vars"
        ]
        if exactNames.contains(fileName) {
            return true
        }

        let preciousExtensions = [".pem", ".key", ".p12", ".mobileprovision", ".sqlite", ".sqlite3", ".db"]
        return preciousExtensions.contains(where: { fileName.hasSuffix($0) })
    }

    public static func parsePreciousIgnoredFiles(fromGitStatus stdout: String) -> [String] {
        var found: [String] = []
        for line in stdout.components(separatedBy: .newlines) where line.hasPrefix("!! ") {
            let path = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if isPreciousIgnoredFile(path), !found.contains(path) {
                found.append(path)
                if found.count >= 25 { break }
            }
        }
        return found
    }

    /// 解析 `git cherry <base> HEAD` 输出：非空且每行都以 `- ` 开头表示所有提交已被等价合入
    public static func isSquashMergedOutput(_ gitCherryStdout: String) -> Bool {
        let lines = gitCherryStdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { $0.hasPrefix("- ") }
    }

    /// 解析 `lsof -a -d cwd -Fpcn` 的输出，返回 (pid, command, cwd)
    public static func parseLsofCwdOutput(
        _ stdout: String,
        excludingPID: Int32 = -1
    ) -> [(pid: Int32, command: String, cwd: String)] {
        var results: [(Int32, String, String)] = []
        var currentPID: Int32?
        var currentCommand = ""

        for rawLine in stdout.components(separatedBy: .newlines) {
            guard let tag = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch tag {
            case "p":
                currentPID = Int32(value)
                currentCommand = ""
            case "c":
                currentCommand = value
            case "n":
                if let pid = currentPID, pid != excludingPID, value.hasPrefix("/") {
                    results.append((pid, currentCommand, canonicalPath(value)))
                }
            default:
                break
            }
        }
        return results
    }

    private static func matchingProcesses(
        for normPath: String,
        entries: [(pid: Int32, command: String, cwd: String)]
    ) -> [String] {
        var matched: [String] = []
        for entry in entries {
            if entry.cwd == normPath || entry.cwd.hasPrefix(normPath + "/") {
                let label = entry.command.isEmpty ? "PID \(entry.pid)" : "\(entry.command) (\(entry.pid))"
                if !matched.contains(label) {
                    matched.append(label)
                    if matched.count >= 5 { break }
                }
            }
        }
        return matched
    }

    public static func isCacheDirectoryName(_ name: String) -> Bool {
        cacheDirectoryNames.contains(name)
    }

    // MARK: - 5. 异步磁盘体积与构建缓存统计

    public static func populateDiskAndCacheStats(for item: WorktreeItem) async -> (diskBytes: Int64, cacheDirs: [CacheDirItem], cacheBytes: Int64) {
        guard item.directoryExists else { return (0, [], 0) }
        async let totalSizeOut = ShellRunner.directorySizeBytes(item.path)

        let cachePaths = findCacheDirectories(in: item.path)
        var cacheItems: [CacheDirItem] = []

        await withTaskGroup(of: CacheDirItem?.self) { group in
            for relPath in cachePaths {
                let fullPath = (item.path as NSString).appendingPathComponent(relPath)
                group.addTask {
                    guard let bytes = await ShellRunner.directorySizeBytes(fullPath), bytes >= 512 * 1024 else {
                        return nil
                    }
                    return CacheDirItem(id: fullPath, relativePath: relPath, sizeBytes: bytes)
                }
            }
            for await result in group {
                if let c = result {
                    cacheItems.append(c)
                }
            }
        }

        cacheItems.sort { $0.sizeBytes > $1.sizeBytes }
        let totalCacheBytes = cacheItems.reduce(0) { $0 + $1.sizeBytes }
        let totalBytes = (await totalSizeOut) ?? totalCacheBytes
        return (totalBytes, cacheItems, totalCacheBytes)
    }

    private static func findCacheDirectories(in rootPath: String) -> [String] {
        let fm = FileManager.default
        guard let topEntries = try? fm.contentsOfDirectory(atPath: rootPath) else { return [] }
        var found: [String] = []

        for name in topEntries where name != ".git" {
            let full1 = (rootPath as NSString).appendingPathComponent(name)
            var isDir1: ObjCBool = false
            guard fm.fileExists(atPath: full1, isDirectory: &isDir1), isDir1.boolValue else { continue }

            if isCacheDirectoryName(name) {
                found.append(name)
                continue
            }

            // 支持常见 monorepo 一级子目录（如 apps/web/node_modules 等往下第一级）
            if let subEntries = try? fm.contentsOfDirectory(atPath: full1) {
                for sub in subEntries where isCacheDirectoryName(sub) {
                    let full2 = (full1 as NSString).appendingPathComponent(sub)
                    var isDir2: ObjCBool = false
                    if fm.fileExists(atPath: full2, isDirectory: &isDir2), isDir2.boolValue {
                        found.append("\(name)/\(sub)")
                    }
                }
            }
        }
        return found
    }

    // MARK: - 6. 批处理 GitHub PR、分支与功能演化剖析

    private static func loadGitHubPullRequests(for mainRepos: [String]) async -> [String: [String: PullRequestInfo]] {
        guard let ghPath = ShellRunner.findExecutable(candidates: ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]) else {
            return [:]
        }

        var map: [String: [String: PullRequestInfo]] = [:]
        await withTaskGroup(of: (String, [String: PullRequestInfo]).self) { group in
            for repo in mainRepos {
                group.addTask {
                    let remoteRes = await ShellRunner.git(["remote", "get-url", "origin"], in: repo, timeout: 4)
                    guard remoteRes.succeeded, remoteRes.stdout.lowercased().contains("github.com") else {
                        return (repo, [:])
                    }
                    let ghRes = await ShellRunner.run(
                        ghPath,
                        arguments: ["pr", "list", "--state", "all", "--limit", "60", "--json", "number,headRefName,state,url"],
                        currentDirectory: repo,
                        timeout: 6
                    )
                    guard ghRes.succeeded,
                          let data = ghRes.stdout.data(using: .utf8),
                          let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                        return (repo, [:])
                    }

                    var repoPRs: [String: PullRequestInfo] = [:]
                    for entry in rawArray {
                        guard let number = entry["number"] as? Int,
                              let branch = entry["headRefName"] as? String,
                              let state = entry["state"] as? String,
                              let url = entry["url"] as? String else { continue }
                        if repoPRs[branch] == nil {
                            repoPRs[branch] = PullRequestInfo(number: number, state: state, url: url)
                        }
                    }
                    return (repo, repoPRs)
                }
            }
            for await (repo, prs) in group where !prs.isEmpty {
                map[repo] = prs
            }
        }
        return map
    }

    private static func detectDefaultBaseBranch(in worktreePath: String) async -> String? {
        let symRef = await ShellRunner.git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: worktreePath)
        if symRef.succeeded {
            let ref = symRef.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ref.isEmpty { return ref }
        }
        let candidates = ["origin/main", "origin/master", "main", "master"]
        for ref in candidates {
            let verify = await ShellRunner.git(["rev-parse", "--verify", "--quiet", ref], in: worktreePath)
            if verify.succeeded { return ref }
        }
        return nil
    }

    private static func checkMergedToBase(in worktreePath: String, baseBranch: String?) async -> Bool {
        guard let base = baseBranch else { return false }
        let ancestor = await ShellRunner.git(["merge-base", "--is-ancestor", "HEAD", base], in: worktreePath)
        return ancestor.succeeded
    }

    private static func buildFeatureSummary(
        in worktreePath: String,
        baseBranch: String?,
        agentTasks: [String]
    ) async -> FeatureSummary {
        guard let base = baseBranch else {
            let recent = await ShellRunner.git(["log", "-5", "--format=%h%x1f%cr%x1f%s"], in: worktreePath)
            let commits = parseBranchCommits(recent.stdout)
            return FeatureSummary(
                baseBranch: nil,
                totalCommitCount: commits.count,
                branchCommits: commits,
                filesChangedCount: 0,
                insertions: 0,
                deletions: 0,
                touchedAreas: [],
                topFiles: [],
                agentTasks: agentTasks
            )
        }

        async let countOut = ShellRunner.git(["rev-list", "--count", "\(base)..HEAD"], in: worktreePath)
        async let logOut = ShellRunner.git(["log", "\(base)..HEAD", "--format=%h%x1f%cr%x1f%s", "-n", "25"], in: worktreePath)
        async let numstatOut = ShellRunner.git(["diff", "--numstat", "\(base)...HEAD"], in: worktreePath)

        let countRes = await countOut
        let logRes = await logOut
        let numstatRes = await numstatOut

        let totalCount = Int(countRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let commits = parseBranchCommits(logRes.stdout)

        var fileStats: [DiffFileStat] = []
        var totalIns = 0
        var totalDel = 0
        var areaCounts: [String: Int] = [:]

        if numstatRes.succeeded {
            for line in numstatRes.stdout.components(separatedBy: .newlines) where !line.isEmpty {
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3 else { continue }
                let ins = Int(parts[0]) ?? 0
                let del = Int(parts[1]) ?? 0
                let filePath = String(parts[2])
                totalIns += ins
                totalDel += del
                fileStats.append(DiffFileStat(id: filePath, path: filePath, insertions: ins, deletions: del))

                let area = extractModuleArea(from: filePath)
                areaCounts[area, default: 0] += 1
            }
        }

        let topAreas = areaCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        let topFiles = fileStats.sorted { $0.totalDelta > $1.totalDelta }.prefix(10).map { $0 }

        return FeatureSummary(
            baseBranch: base,
            totalCommitCount: totalCount,
            branchCommits: commits,
            filesChangedCount: fileStats.count,
            insertions: totalIns,
            deletions: totalDel,
            touchedAreas: Array(topAreas),
            topFiles: Array(topFiles),
            agentTasks: agentTasks
        )
    }

    private static func parseBranchCommits(_ stdout: String) -> [BranchCommit] {
        stdout
            .components(separatedBy: .newlines)
            .compactMap { line -> BranchCommit? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.components(separatedBy: "\u{1F}")
                guard parts.count >= 3 else { return nil }
                return BranchCommit(id: parts[0], relativeDate: parts[1], subject: parts[2])
            }
    }

    private static func extractModuleArea(from filePath: String) -> String {
        let components = filePath.split(separator: "/").map(String.init)
        if components.count <= 1 { return "root" }
        if components.count == 2 { return components[0] }
        return "\(components[0])/\(components[1])"
    }

    private static func mergeTasks(
        codex: [String: [String]],
        claude: [String: [String]],
        path: String
    ) -> [String] {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var merged: [String] = []
        for t in (codex[path] ?? codex[parent] ?? []) + (claude[path] ?? []) {
            if !merged.contains(t) {
                merged.append(t)
                if merged.count >= 3 { break }
            }
        }
        return merged
    }

    private static func detectSource(path: String) -> WorktreeSource {
        if path.contains("/.codex/") { return .codex }
        if path.contains("/.claude/") { return .claude }
        if path.contains("/.cursor/") { return .cursor }
        if path.contains("/.trae") { return .trae }
        return .local
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - 7. Diff 预览

    public static func fetchDiff(for item: WorktreeItem) async -> String {
        guard item.directoryExists else { return "Directory no longer exists." }
        async let unstaged = ShellRunner.git(["diff", "--stat", "-p", "--no-color"], in: item.path)
        async let staged = ShellRunner.git(["diff", "--cached", "--stat", "-p", "--no-color"], in: item.path)
        let u = await unstaged.stdout
        let s = await staged.stdout

        var sections: [String] = []
        if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("=== Staged Changes ===\n\(s)")
        }
        if !u.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("=== Unstaged Changes ===\n\(u)")
        }
        if sections.isEmpty {
            if item.untrackedCount > 0 {
                let names = item.changedFiles.filter { $0.statusCode == "??" }.map(\.path).joined(separator: "\n")
                return "Untracked files only:\n\(names)"
            }
            return "Working tree is clean."
        }
        let full = sections.joined(separator: "\n\n")
        if full.count > 40_000 {
            return String(full.prefix(40_000)) + "\n\n… (Truncated to first 40,000 characters)"
        }
        return full
    }

    // MARK: - 8. 只清构建缓存（保留代码）

    public static func cleanBuildCaches(for item: WorktreeItem) async -> Result<Int64, Error> {
        let fm = FileManager.default
        var freed: Int64 = 0
        for cache in item.cacheDirs where fm.fileExists(atPath: cache.id) {
            do {
                try fm.trashItem(at: URL(fileURLWithPath: cache.id), resultingItemURL: nil)
                freed += cache.sizeBytes
            } catch {
                return .failure(error)
            }
        }
        return .success(freed)
    }

    // MARK: - 9. 一键拷回敏感被忽略文件到主仓库

    public static func copyPreciousFilesToMainRepo(for item: WorktreeItem) async -> Result<(copied: [String], skipped: [String]), Error> {
        let fm = FileManager.default
        guard !item.mainRepoPath.isEmpty, fm.fileExists(atPath: item.mainRepoPath) else {
            return .failure(CleanerError(message: "Main repository path does not exist."))
        }
        var copied: [String] = []
        var skipped: [String] = []

        for rel in item.preciousIgnoredFiles {
            let src = (item.path as NSString).appendingPathComponent(rel)
            let dst = (item.mainRepoPath as NSString).appendingPathComponent(rel)
            guard fm.fileExists(atPath: src) else { continue }
            if fm.fileExists(atPath: dst) {
                skipped.append(rel)
                continue
            }
            let parentDir = (dst as NSString).deletingLastPathComponent
            do {
                try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
                try fm.copyItem(atPath: src, toPath: dst)
                copied.append(rel)
            } catch {
                return .failure(error)
            }
        }
        return .success((copied, skipped))
    }

    // MARK: - 10. 快速推送到远端

    public static func pushWorktree(
        _ item: WorktreeItem,
        branchName: String,
        commitMessage: String?,
        deleteAfterPush: Bool,
        moveToTrash: Bool = true
    ) async -> Result<PushResultInfo, Error> {
        guard item.directoryExists, !item.isMissing, !item.isOrphan else {
            return .failure(CleanerError(message: "Worktree directory is unavailable for push."))
        }
        guard let remote = item.remoteName, !remote.isEmpty else {
            return .failure(CleanerError(message: "No Git remote configured."))
        }

        let targetBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetBranch.isEmpty else {
            return .failure(CleanerError(message: "Branch name cannot be empty."))
        }

        if item.isDetached {
            let checkout = await ShellRunner.git(["checkout", "-b", targetBranch], in: item.path)
            if !checkout.succeeded {
                return .failure(CleanerError(message: checkout.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }

        var didCommit = false
        if item.isDirty {
            let msg = (commitMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let finalMsg = msg.isEmpty ? item.suggestedCommitMessage : msg

            let addRes = await ShellRunner.git(["add", "-A"], in: item.path)
            if !addRes.succeeded {
                return .failure(CleanerError(message: addRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
            }

            let commitRes = await ShellRunner.git(["commit", "-m", finalMsg], in: item.path)
            if !commitRes.succeeded && !commitRes.stdout.contains("nothing to commit") {
                return .failure(CleanerError(message: commitRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            didCommit = true
        }

        let pushRes = await ShellRunner.git(
            ["push", "-u", remote, "HEAD:refs/heads/\(targetBranch)"],
            in: item.path,
            timeout: 45
        )
        if !pushRes.succeeded {
            let errText = pushRes.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CleanerError(message: errText.isEmpty ? "git push failed (\(pushRes.exitCode))" : errText))
        }

        var removed = false
        if deleteAfterPush {
            let removeRes = await removeWorktree(
                item,
                backupCommitFirst: false,
                moveToTrash: moveToTrash,
                deleteLocalBranch: false,
                force: true
            )
            if case .success = removeRes {
                removed = true
            }
        }

        return .success(PushResultInfo(
            remote: remote,
            branch: targetBranch,
            committedChanges: didCommit,
            removedAfterPush: removed
        ))
    }

    // MARK: - 11. 安全移除 Worktree（默认移入废纸篓后悔药 + Prune + 可选删本地分支）

    public static func removeWorktree(
        _ item: WorktreeItem,
        backupCommitFirst: Bool = false,
        moveToTrash: Bool = true,
        deleteLocalBranch: Bool = false,
        force: Bool = false
    ) async -> Result<Void, Error> {
        let fm = FileManager.default

        // 1. 仅剩 Git 幽灵元数据
        if item.isMissing {
            let res = await ShellRunner.git(["worktree", "prune"], in: item.mainRepoPath)
            if res.succeeded { return .success(()) }
            return .failure(CleanerError(message: res.stderr.isEmpty ? "git worktree prune failed" : res.stderr))
        }

        // 2. 孤儿目录直接移入废纸篓或永久删除
        if item.isOrphan {
            if fm.fileExists(atPath: item.path) {
                do {
                    if moveToTrash {
                        try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                    } else {
                        try fm.removeItem(atPath: item.path)
                    }
                    cleanupEmptyAgentParentIfNeeded(of: item.path)
                } catch {
                    return .failure(error)
                }
            }
            return .success(())
        }

        // 3. 如需先备份未提交改动
        var activeBranchName = item.branch
        if backupCommitFirst && item.isDirty {
            if item.isDetached {
                let stamp = Int(Date().timeIntervalSince1970)
                let safeName = item.folderName.replacingOccurrences(of: " ", with: "-")
                let backupBranch = "backup/wt-\(safeName)-\(stamp)"
                let checkout = await ShellRunner.git(["checkout", "-b", backupBranch], in: item.path)
                if !checkout.succeeded {
                    return .failure(CleanerError(message: "Failed to create backup branch: \(checkout.stderr)"))
                }
                activeBranchName = backupBranch
            }
            let addRes = await ShellRunner.git(["add", "-A"], in: item.path)
            if !addRes.succeeded {
                return .failure(CleanerError(message: "git add failed: \(addRes.stderr)"))
            }
            let commitRes = await ShellRunner.git(
                ["commit", "-m", "wip: auto-backup before worktree cleanup"],
                in: item.path
            )
            if !commitRes.succeeded && !commitRes.stdout.contains("nothing to commit") {
                return .failure(CleanerError(message: "Auto-commit backup failed: \(commitRes.stderr)"))
            }
        }

        // 4. 若锁定且强制清理，先解锁
        if item.isLocked && force {
            _ = await ShellRunner.git(["worktree", "unlock", item.path], in: item.mainRepoPath)
        }

        // 5. 移除目录：默认移入 macOS 废纸篓 + prune；否则原生 git worktree remove
        if moveToTrash {
            if fm.fileExists(atPath: item.path) {
                do {
                    try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                } catch {
                    return .failure(error)
                }
            }
            let pruneRes = await ShellRunner.git(["worktree", "prune"], in: item.mainRepoPath)
            if !pruneRes.succeeded {
                return .failure(CleanerError(message: pruneRes.stderr.isEmpty ? "git worktree prune failed" : pruneRes.stderr))
            }
        } else {
            var args = ["worktree", "remove"]
            if force || backupCommitFirst {
                args.append("--force")
            }
            args.append(item.path)

            let removeRes = await ShellRunner.git(args, in: item.mainRepoPath, timeout: 30)
            if !removeRes.succeeded {
                return .failure(CleanerError(message: removeRes.stderr.isEmpty ? "Failed to remove worktree" : removeRes.stderr))
            }
            _ = await ShellRunner.git(["worktree", "prune"], in: item.mainRepoPath)
        }

        cleanupEmptyAgentParentIfNeeded(of: item.path)

        // 6. 如用户勾选“同时删除已同步的本地分支”
        if deleteLocalBranch && item.canDeleteLocalBranch && !activeBranchName.isEmpty && !item.mainRepoPath.isEmpty {
            _ = await ShellRunner.git(["branch", "-D", activeBranchName], in: item.mainRepoPath)
        }

        return .success(())
    }

    public static func pruneAllMissing(items: [WorktreeItem]) async -> Int {
        let repos = Set(items.filter { $0.isMissing && !$0.mainRepoPath.isEmpty }.map(\.mainRepoPath))
        var pruned = 0
        for repo in repos {
            let res = await ShellRunner.git(["worktree", "prune"], in: repo)
            if res.succeeded { pruned += 1 }
        }
        return pruned
    }

    private static func cleanupEmptyAgentParentIfNeeded(of worktreePath: String) {
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: worktreePath).deletingLastPathComponent()
        let grandParent = parent.deletingLastPathComponent().path
        let isUnderAgentRoot = agentWorktreeRoots.contains { canonicalPath($0) == canonicalPath(grandParent) }
        guard isUnderAgentRoot else { return }

        if let contents = try? fm.contentsOfDirectory(atPath: parent.path) {
            let meaningful = contents.filter { $0 != ".DS_Store" && $0 != ".metadata_never_index" && $0 != ".codex-worktree-name" }
            if meaningful.isEmpty {
                try? fm.removeItem(at: parent)
            }
        }
    }

    public struct CleanerError: LocalizedError {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}

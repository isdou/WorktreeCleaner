import Foundation

/// Antigravity MCP Apps (SEP-1865) 原生 JSON-RPC 2.0 协议处理器
/// 与 macOS App 共用 100% 相同的 WorktreeScanner 引擎，通过 String 进出保证 Swift 6 严格并发安全
public actor MCPServerHandler {
    public static let appURI = "ui://worktree-cleaner/app.html"
    public static let appMimeType = "text/html;profile=mcp-app"
    public static let serverName = "worktree-cleaner-mcp"
    public static let serverVersion = "1.0.0"

    private let customHTMLPath: String?
    private let executablePath: String
    private var cachedItems: [WorktreeItem] = []
    private var lastSearchRoots: [String] = WorktreeScanner.defaultSearchRoots

    public init(
        customHTMLPath: String? = nil,
        executablePath: String = CommandLine.arguments.first ?? ""
    ) {
        self.customHTMLPath = customHTMLPath
        self.executablePath = executablePath
    }

    // MARK: - JSON-RPC 2.0 主入口（NDJSON 单行入 -> 单行出）

    public func handleJSONLine(_ rawLine: String) async -> String? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return serialize([
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": ["code": -32700, "message": "Parse error: invalid JSON"]
            ])
        }

        // JSON-RPC 通知（无 id）不返回响应
        guard let msgID = msg["id"] else { return nil }
        let method = (msg["method"] as? String) ?? ""
        let params = (msg["params"] as? [String: Any]) ?? [:]

        let response: [String: Any]
        switch method {
        case "initialize":
            let proto = (params["protocolVersion"] as? String) ?? "2025-03-26"
            response = [
                "jsonrpc": "2.0",
                "id": msgID,
                "result": [
                    "protocolVersion": proto,
                    "capabilities": [
                        "tools": ["listChanged": false],
                        "resources": ["subscribe": false, "listChanged": false]
                    ],
                    "serverInfo": [
                        "name": Self.serverName,
                        "version": Self.serverVersion
                    ]
                ]
            ]

        case "ping":
            response = ["jsonrpc": "2.0", "id": msgID, "result": [:] as [String: Any]]

        case "tools/list":
            response = [
                "jsonrpc": "2.0",
                "id": msgID,
                "result": ["tools": Self.toolDefinitions]
            ]

        case "tools/call":
            let toolName = (params["name"] as? String) ?? ""
            let args = (params["arguments"] as? [String: Any]) ?? [:]
            let result = await executeTool(name: toolName, arguments: args)
            response = ["jsonrpc": "2.0", "id": msgID, "result": result]

        case "resources/list":
            response = [
                "jsonrpc": "2.0",
                "id": msgID,
                "result": [
                    "resources": [
                        [
                            "uri": Self.appURI,
                            "name": "Worktree Cleaner Workbench",
                            "description": "Interactive visual inspector & safe cleaner for Git worktrees left behind by AI coding agents.",
                            "mimeType": Self.appMimeType,
                            "_meta": ["ui": ["prefersBorder": false]]
                        ]
                    ]
                ]
            ]

        case "resources/read":
            let uri = (params["uri"] as? String) ?? ""
            if uri != Self.appURI {
                response = [
                    "jsonrpc": "2.0",
                    "id": msgID,
                    "error": ["code": -32602, "message": "Unknown resource URI: \(uri)"]
                ]
            } else {
                switch loadAppHTML() {
                case .success(let html):
                    response = [
                        "jsonrpc": "2.0",
                        "id": msgID,
                        "result": [
                            "contents": [
                                [
                                    "uri": Self.appURI,
                                    "mimeType": Self.appMimeType,
                                    "text": html,
                                    "_meta": ["ui": ["prefersBorder": false]]
                                ]
                            ]
                        ]
                    ]
                case .failure(let err):
                    response = [
                        "jsonrpc": "2.0",
                        "id": msgID,
                        "error": ["code": -32603, "message": err.localizedDescription]
                    ]
                }
            }

        default:
            response = [
                "jsonrpc": "2.0",
                "id": msgID,
                "error": ["code": -32601, "message": "Method not found: \(method)"]
            ]
        }

        return serialize(response)
    }

    // MARK: - Tool 定义（含 Antigravity MCP Apps SEP-1865 元数据）

    public static var toolDefinitions: [[String: Any]] {
        let workbenchMeta: [String: Any] = [
            "ui": ["resourceUri": appURI],
            "ui/resourceUri": appURI,
            "com.google.antigravity/ui": [
                "entrypoints": [
                    ["type": "aux_pane", "title": "Worktree Cleaner"],
                    ["type": "global", "title": "Worktree Cleaner"]
                ]
            ]
        ]

        // 仅声明 _meta.ui.resourceUri（无 aux_pane/global），在聊天流中直接渲染内联交互卡片
        let inlineCardMeta: [String: Any] = [
            "ui": ["resourceUri": appURI],
            "ui/resourceUri": appURI
        ]

        // 安全隔离：所有破坏性/变更类工具仅对 UI 沙箱可见，对 LLM 完全隐藏，杜绝误删风险
        let appOnlyMeta: [String: Any] = [
            "ui": ["visibility": ["app"]]
        ]

        return [
            [
                "name": "open_worktree_cleaner",
                "title": "Worktree Cleaner",
                "description": "Open the full interactive Worktree Cleaner workbench in the Antigravity side pane or global plugin view to visually inspect Git worktrees (Codex/Claude tasks, diff, squash/PR merge status, active process locks, precious .env files), attach dirty worktrees to chat, slim caches, push branches, or safely move stale worktrees to Trash. All parameters are optional.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "filter": [
                            "type": "string",
                            "enum": ["all", "safe", "caution", "danger", "missing"],
                            "description": "Optional initial safety filter."
                        ],
                        "search": [
                            "type": "string",
                            "description": "Optional initial search query (repo, branch, or task keyword)."
                        ],
                        "roots": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional extra or override directories to scan."
                        ],
                        "freshnessHours": [
                            "type": "integer",
                            "description": "Freshness cooldown hours (default 24)."
                        ]
                    ],
                    "additionalProperties": false
                ],
                "_meta": workbenchMeta
            ],
            [
                "name": "show_worktrees_inline",
                "title": "Show Worktrees Inline Card",
                "description": "Render a compact interactive Worktree Cleaner card directly inline in the chat stream with checkboxes, disk usage breakdown, safety filters, attach-to-chat context pills, and Trash cleanup confirmation. Prefer this for quick in-chat checks (e.g. 'which worktrees can I delete?'); use open_worktree_cleaner for the full side-pane workbench.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "filter": [
                            "type": "string",
                            "enum": ["all", "safe", "caution", "danger", "missing"],
                            "description": "Optional initial safety filter."
                        ],
                        "search": [
                            "type": "string",
                            "description": "Optional initial search query (repo, branch, or task keyword)."
                        ],
                        "roots": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional extra or override directories to scan."
                        ],
                        "freshnessHours": [
                            "type": "integer",
                            "description": "Freshness cooldown hours (default 24)."
                        ]
                    ],
                    "additionalProperties": false
                ],
                "_meta": inlineCardMeta
            ],
            [
                "name": "scan_worktrees",
                "title": "Scan Git Worktrees",
                "description": "Read-only scan of local Git repositories and AI agent worktree directories (~/.codex/worktrees, ~/.claude/worktrees, etc.) returning full structured safety, merge/PR, and disk-size diagnostics.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "roots": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional list of root directories to scan."
                        ],
                        "includeDiskSizes": [
                            "type": "boolean",
                            "description": "Whether to compute disk and build-cache sizes (default true)."
                        ],
                        "freshnessHours": [
                            "type": "integer",
                            "description": "Freshness cooldown hours (default 24)."
                        ]
                    ],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "get_worktree_diff",
                "title": "Get Worktree Diff",
                "description": "Read-only inspection returning staged and unstaged git diff for a specific worktree path.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to the worktree directory."]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "slim_worktree_caches",
                "title": "Slim Worktree Build Caches",
                "description": "App-only action: move regenerable build/dependency caches (node_modules, .next, .build, target, DerivedData, .venv, etc.) inside a worktree to macOS Trash while keeping all source code and uncommitted edits intact.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to the worktree directory."]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ],
                "_meta": appOnlyMeta
            ],
            [
                "name": "copy_precious_files",
                "title": "Copy Precious Ignored Files to Main Repo",
                "description": "App-only action: safely copy precious ignored local files (.env, .env.local, secrets.json, *.sqlite, etc.) from a worktree back to its main repository without overwriting existing files.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to the worktree directory."]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ],
                "_meta": appOnlyMeta
            ],
            [
                "name": "push_worktree",
                "title": "Commit and Push Worktree",
                "description": "App-only action: push a worktree branch to its Git remote (optionally staging & committing dirty changes, creating a branch from Detached HEAD, and moving the worktree to Trash afterwards).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to the worktree directory."],
                        "branchName": ["type": "string", "description": "Target branch name (optional; defaults to current or suggested branch)."],
                        "commitMessage": ["type": "string", "description": "Commit message if worktree has uncommitted changes."],
                        "deleteAfterPush": ["type": "boolean", "description": "Whether to move the worktree to Trash after a successful push (default false)."],
                        "moveToTrash": ["type": "boolean", "description": "Move removed directory to macOS Trash (default true)."]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ],
                "_meta": appOnlyMeta
            ],
            [
                "name": "remove_worktree",
                "title": "Safely Remove Worktree",
                "description": "App-only action: remove a Git worktree or orphaned directory (moves to macOS Trash + git worktree prune by default, with optional auto-commit backup and optional synced local branch deletion).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to the worktree or orphan directory."],
                        "backupCommitFirst": ["type": "boolean", "description": "Auto-commit uncommitted changes into the branch before removal (default true)."],
                        "moveToTrash": ["type": "boolean", "description": "Move directory to macOS Trash instead of permanent rm (default true)."],
                        "deleteLocalBranch": ["type": "boolean", "description": "Also delete matching local branch (protected branches are never deleted; default false)."],
                        "force": ["type": "boolean", "description": "Force removal even if active processes or locks are detected (default false)."],
                        "skipRescan": ["type": "boolean", "description": "Skip immediate full rescan after removal (used during batch UI deletion; default false)."]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ],
                "_meta": appOnlyMeta
            ],
            [
                "name": "prune_missing_worktrees",
                "title": "Prune Ghost Worktree Metadata",
                "description": "App-only action: run git worktree prune on all repositories that have missing/stale worktree metadata entries.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ],
                "_meta": appOnlyMeta
            ],
            [
                "name": "open_in_finder",
                "title": "Reveal Worktree in Finder",
                "description": "App-only action to reveal a worktree path in macOS Finder.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to reveal in Finder."]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ],
                "_meta": appOnlyMeta
            ]
        ]
    }

    // MARK: - Tool 执行逻辑

    private func executeTool(name: String, arguments: [String: Any]) async -> [String: Any] {
        switch name {
        case "open_worktree_cleaner", "show_worktrees_inline":
            let isInline = (name == "show_worktrees_inline")
            let roots = (arguments["roots"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? lastSearchRoots
            let freshness = (arguments["freshnessHours"] as? Int) ?? 24
            let initialFilter = (arguments["filter"] as? String) ?? "all"
            let initialSearch = (arguments["search"] as? String) ?? ""

            let items = await performFullScan(roots: roots, includeDiskSizes: true)
            let payload = buildScanPayload(
                items: items,
                freshnessHours: freshness,
                initialFilter: initialFilter,
                initialSearch: initialSearch,
                displayMode: isInline ? "inline" : "workbench"
            )
            let textSummary = buildTextSummary(items: items, surface: isInline ? .inlineCard : .workbench)
            return [
                "content": [["type": "text", "text": textSummary]],
                "structuredContent": payload,
                "isError": false
            ]

        case "scan_worktrees":
            let roots = (arguments["roots"] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? lastSearchRoots
            let includeSizes = (arguments["includeDiskSizes"] as? Bool) ?? true
            let freshness = (arguments["freshnessHours"] as? Int) ?? 24

            let items = await performFullScan(roots: roots, includeDiskSizes: includeSizes)
            let payload = buildScanPayload(items: items, freshnessHours: freshness)
            let textSummary = buildTextSummary(items: items, surface: .headless)
            return [
                "content": [["type": "text", "text": textSummary]],
                "structuredContent": payload,
                "isError": false
            ]

        case "get_worktree_diff":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return errorResult("Missing required argument: path")
            }
            guard let item = await resolveItem(path: path) else {
                return errorResult("Worktree not found: \(path)")
            }
            let diff = await WorktreeScanner.fetchDiff(for: item)
            return [
                "content": [["type": "text", "text": diff]],
                "structuredContent": ["path": item.path, "diff": diff],
                "isError": false
            ]

        case "slim_worktree_caches":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return errorResult("Missing required argument: path")
            }
            guard let item = await resolveItem(path: path, ensureSizes: true) else {
                return errorResult("Worktree not found: \(path)")
            }
            let res = await WorktreeScanner.cleanBuildCaches(for: item)
            switch res {
            case .success(let freed):
                let sizeStr = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
                let refreshed = await performFullScan(roots: lastSearchRoots, includeDiskSizes: true)
                return [
                    "content": [["type": "text", "text": "Moved build caches in \(item.folderName) to Trash, freed ~\(sizeStr). Source code untouched."]],
                    "structuredContent": [
                        "freedBytes": freed,
                        "formattedFreed": sizeStr,
                        "scan": buildScanPayload(items: refreshed, freshnessHours: 24)
                    ],
                    "isError": false
                ]
            case .failure(let err):
                return errorResult(err.localizedDescription)
            }

        case "copy_precious_files":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return errorResult("Missing required argument: path")
            }
            guard let item = await resolveItem(path: path) else {
                return errorResult("Worktree not found: \(path)")
            }
            let res = await WorktreeScanner.copyPreciousFilesToMainRepo(for: item)
            switch res {
            case .success(let info):
                let msg = "Copied \(info.copied.count) file(s) to \(item.mainRepoName); skipped \(info.skipped.count) existing file(s)."
                return [
                    "content": [["type": "text", "text": msg]],
                    "structuredContent": [
                        "copied": info.copied,
                        "skipped": info.skipped,
                        "message": msg
                    ],
                    "isError": false
                ]
            case .failure(let err):
                return errorResult(err.localizedDescription)
            }

        case "push_worktree":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return errorResult("Missing required argument: path")
            }
            guard let item = await resolveItem(path: path) else {
                return errorResult("Worktree not found: \(path)")
            }
            let branch = (arguments["branchName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? item.suggestedPushBranchName
            let commitMsg = arguments["commitMessage"] as? String
            let deleteAfterPush = (arguments["deleteAfterPush"] as? Bool) ?? false
            let moveToTrash = (arguments["moveToTrash"] as? Bool) ?? true

            let res = await WorktreeScanner.pushWorktree(
                item,
                branchName: branch,
                commitMessage: commitMsg,
                deleteAfterPush: deleteAfterPush,
                moveToTrash: moveToTrash
            )
            switch res {
            case .success(let info):
                let refreshed = await performFullScan(roots: lastSearchRoots, includeDiskSizes: true)
                let msg = info.removedAfterPush
                    ? "Pushed to \(info.remote)/\(info.branch) and removed worktree."
                    : "Pushed to \(info.remote)/\(info.branch)."
                return [
                    "content": [["type": "text", "text": msg]],
                    "structuredContent": [
                        "remote": info.remote,
                        "branch": info.branch,
                        "committedChanges": info.committedChanges,
                        "removedAfterPush": info.removedAfterPush,
                        "message": msg,
                        "scan": buildScanPayload(items: refreshed, freshnessHours: 24)
                    ],
                    "isError": false
                ]
            case .failure(let err):
                return errorResult(err.localizedDescription)
            }

        case "remove_worktree":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return errorResult("Missing required argument: path")
            }
            guard let item = await resolveItem(path: path, ensureSizes: true) else {
                return errorResult("Worktree not found: \(path)")
            }
            let backup = (arguments["backupCommitFirst"] as? Bool) ?? true
            let moveToTrash = (arguments["moveToTrash"] as? Bool) ?? true
            let deleteBranch = (arguments["deleteLocalBranch"] as? Bool) ?? false
            let force = (arguments["force"] as? Bool) ?? false
            let skipRescan = (arguments["skipRescan"] as? Bool) ?? false

            if !item.activeProcesses.isEmpty && !force {
                let procs = item.activeProcesses.joined(separator: ", ")
                return errorResult("Refused to remove worktree while active processes are running inside it: \(procs). Stop them first or pass force=true.")
            }

            let res = await WorktreeScanner.removeWorktree(
                item,
                backupCommitFirst: backup,
                moveToTrash: moveToTrash,
                deleteLocalBranch: deleteBranch,
                force: force || item.safetyLevel == .danger
            )
            switch res {
            case .success:
                let actionDesc = moveToTrash ? "Moved to Trash and pruned" : "Removed"
                let msg = "\(actionDesc): \(item.mainRepoName) · \(item.displayBranch(language: .en))"
                var sc: [String: Any] = [
                    "removedPath": item.path,
                    "movedToTrash": moveToTrash,
                    "message": msg
                ]
                if !skipRescan {
                    let refreshed = await performFullScan(roots: lastSearchRoots, includeDiskSizes: true)
                    sc["scan"] = buildScanPayload(items: refreshed, freshnessHours: 24)
                }
                return [
                    "content": [["type": "text", "text": msg]],
                    "structuredContent": sc,
                    "isError": false
                ]
            case .failure(let err):
                return errorResult(err.localizedDescription)
            }

        case "prune_missing_worktrees":
            if cachedItems.isEmpty {
                _ = await performFullScan(roots: lastSearchRoots, includeDiskSizes: false)
            }
            let pruned = await WorktreeScanner.pruneAllMissing(items: cachedItems)
            let refreshed = await performFullScan(roots: lastSearchRoots, includeDiskSizes: true)
            let msg = "Pruned ghost worktree metadata across \(pruned) repository(s)."
            return [
                "content": [["type": "text", "text": msg]],
                "structuredContent": [
                    "prunedRepos": pruned,
                    "message": msg,
                    "scan": buildScanPayload(items: refreshed, freshnessHours: 24)
                ],
                "isError": false
            ]

        case "open_in_finder":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return errorResult("Missing required argument: path")
            }
            let res = await ShellRunner.run("/usr/bin/open", arguments: ["-R", path], timeout: 5)
            if res.succeeded {
                return [
                    "content": [["type": "text", "text": "Revealed in Finder: \(path)"]],
                    "structuredContent": ["opened": true, "path": path],
                    "isError": false
                ]
            }
            return errorResult(res.stderr.isEmpty ? "Failed to open Finder" : res.stderr)

        default:
            return errorResult("Unknown tool: \(name)")
        }
    }

    // MARK: - 扫描与数据精简序列化

    private func performFullScan(roots: [String], includeDiskSizes: Bool) async -> [WorktreeItem] {
        lastSearchRoots = roots
        var items = await WorktreeScanner.scanAll(searchRoots: roots)

        if includeDiskSizes {
            await withTaskGroup(of: (Int, Int64, [CacheDirItem], Int64).self) { group in
                for idx in items.indices where items[idx].directoryExists {
                    let target = items[idx]
                    group.addTask {
                        let stats = await WorktreeScanner.populateDiskAndCacheStats(for: target)
                        return (idx, stats.diskBytes, stats.cacheDirs, stats.cacheBytes)
                    }
                }
                for await (idx, diskBytes, cacheDirs, cacheBytes) in group {
                    items[idx].diskSizeBytes = diskBytes
                    items[idx].cacheDirs = cacheDirs
                    items[idx].reclaimableCacheBytes = cacheBytes
                }
            }
        }

        cachedItems = items
        return items
    }

    private func resolveItem(path: String, ensureSizes: Bool = false) async -> WorktreeItem? {
        let norm = URL(fileURLWithPath: path).standardizedFileURL.path
        if let existing = cachedItems.first(where: { $0.id == norm }) {
            if ensureSizes && existing.diskSizeBytes == nil {
                var updated = existing
                let stats = await WorktreeScanner.populateDiskAndCacheStats(for: existing)
                updated.diskSizeBytes = stats.diskBytes
                updated.cacheDirs = stats.cacheDirs
                updated.reclaimableCacheBytes = stats.cacheBytes
                return updated
            }
            return existing
        }
        let scanned = await performFullScan(roots: lastSearchRoots, includeDiskSizes: ensureSizes)
        return scanned.first(where: { $0.id == norm })
    }

    private enum SummarySurface {
        case workbench
        case inlineCard
        case headless
    }

    private func buildScanPayload(
        items: [WorktreeItem],
        freshnessHours: Int,
        initialFilter: String? = nil,
        initialSearch: String? = nil,
        displayMode: String? = nil
    ) -> [String: Any] {
        let safeItems = items.filter { $0.safetyLevel == .safe || $0.safetyLevel == .missing }
        let reclaimableBytes = safeItems.compactMap(\.diskSizeBytes).reduce(0, +)
        let totalBytes = items.compactMap(\.diskSizeBytes).reduce(0, +)
        let totalCacheBytes = items.reduce(0) { $0 + $1.reclaimableCacheBytes }
        let iso = ISO8601DateFormatter()

        let serializedItems: [[String: Any]] = items.map { item in
            var dict: [String: Any] = [
                "id": item.id,
                "path": item.path,
                "folderName": item.folderName,
                "kind": item.kind.rawValue,
                "mainRepoPath": item.mainRepoPath,
                "mainRepoName": item.mainRepoName,
                "branch": item.branch,
                "displayBranch": item.displayBranch(language: .en),
                "headCommit": String(item.headCommit.prefix(7)),
                "headSubject": item.headSubject,
                "isDetached": item.isDetached,
                "isLocked": item.isLocked,
                "isOrphan": item.isOrphan,
                "isMissing": item.isMissing,
                "directoryExists": item.directoryExists,
                "source": item.source.rawValue,
                "remoteName": item.remoteName ?? "",
                "safetyLevel": item.safetyLevel.key,
                "safetySummaryZh": item.safetySummary(language: .zhHans, freshnessHours: freshnessHours),
                "safetySummaryEn": item.safetySummary(language: .en, freshnessHours: freshnessHours),
                "isRecentlyActive": item.isWithinFreshnessWindow(hours: freshnessHours),
                "isDirty": item.isDirty,
                "modifiedCount": item.modifiedCount,
                "untrackedCount": item.untrackedCount,
                "aheadCount": item.aheadCount,
                "hasUpstream": item.hasUpstream,
                "isMerged": item.isEffectivelyMerged,
                "isSquashMerged": item.isSquashMerged,
                "canPush": item.canPush,
                "needsPush": item.needsPush,
                "canDeleteLocalBranch": item.canDeleteLocalBranch,
                "suggestedCommitMessage": item.suggestedCommitMessage,
                "suggestedPushBranchName": item.suggestedPushBranchName,
                "activeProcesses": item.activeProcesses,
                "preciousIgnoredFiles": Array(item.preciousIgnoredFiles.prefix(15)),
                "orphanFileCount": item.orphanFileCount,
                "diskSizeBytes": item.diskSizeBytes ?? 0,
                "formattedSize": item.formattedSize,
                "reclaimableCacheBytes": item.reclaimableCacheBytes,
                "formattedCacheSize": item.formattedCacheSize,
                "cacheDirs": item.cacheDirs.prefix(10).map { ["path": $0.relativePath, "sizeBytes": $0.sizeBytes] },
                "changedFiles": item.changedFiles.prefix(30).map { ["code": $0.badgeText, "path": $0.path] },
                "unpushedCommits": item.unpushedCommits.prefix(10).map { ["hash": $0.id, "message": $0.message] }
            ]

            if let mod = item.lastModified {
                dict["lastModified"] = iso.string(from: mod)
            }
            if let pr = item.prInfo {
                dict["pr"] = ["number": pr.number, "state": pr.state, "url": pr.url]
            }
            if let summary = item.featureSummary {
                dict["featureSummary"] = [
                    "baseBranch": summary.baseBranch ?? "",
                    "totalCommitCount": summary.totalCommitCount,
                    "filesChangedCount": summary.filesChangedCount,
                    "insertions": summary.insertions,
                    "deletions": summary.deletions,
                    "touchedAreas": summary.touchedAreas,
                    "agentTasks": summary.agentTasks,
                    "branchCommits": summary.branchCommits.prefix(10).map {
                        ["hash": $0.id, "relativeDate": $0.relativeDate, "subject": $0.subject]
                    },
                    "topFiles": summary.topFiles.prefix(8).map {
                        ["path": $0.path, "insertions": $0.insertions, "deletions": $0.deletions]
                    }
                ]
            }
            return dict
        }

        var payload: [String: Any] = [
            "generatedAt": iso.string(from: Date()),
            "freshnessHours": freshnessHours,
            "summary": [
                "totalCount": items.count,
                "safeCount": items.filter { $0.safetyLevel == .safe }.count,
                "cautionCount": items.filter { $0.safetyLevel == .caution }.count,
                "dangerCount": items.filter { $0.safetyLevel == .danger }.count,
                "missingCount": items.filter { $0.safetyLevel == .missing }.count,
                "reclaimableBytes": reclaimableBytes,
                "formattedReclaimable": ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file),
                "totalBytes": totalBytes,
                "formattedTotal": ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file),
                "totalCacheBytes": totalCacheBytes,
                "formattedTotalCache": ByteCountFormatter.string(fromByteCount: totalCacheBytes, countStyle: .file)
            ],
            "items": serializedItems
        ]
        if let initialFilter { payload["initialFilter"] = initialFilter }
        if let initialSearch { payload["initialSearch"] = initialSearch }
        if let displayMode { payload["displayMode"] = displayMode }
        return payload
    }

    private func buildTextSummary(items: [WorktreeItem], surface: SummarySurface) -> String {
        let safeCnt = items.filter { $0.safetyLevel == .safe }.count
        let cautionCnt = items.filter { $0.safetyLevel == .caution }.count
        let dangerCnt = items.filter { $0.safetyLevel == .danger }.count
        let missingCnt = items.filter { $0.safetyLevel == .missing }.count
        let reclaimable = items
            .filter { $0.safetyLevel == .safe || $0.safetyLevel == .missing }
            .compactMap(\.diskSizeBytes)
            .reduce(0, +)
        let reclaimableStr = ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file)

        switch surface {
        case .workbench:
            return "Opened Worktree Cleaner workbench (\(items.count) worktrees found: \(safeCnt) safe, \(cautionCnt) review, \(dangerCnt) active/dirty, \(missingCnt) ghost; ~\(reclaimableStr) safely reclaimable). Destructive actions are UI-confirmed only."
        case .inlineCard:
            return "Rendered interactive Worktree Cleaner card inline (\(items.count) worktrees: \(safeCnt) safe, \(cautionCnt) review, \(dangerCnt) active/dirty, \(missingCnt) ghost; ~\(reclaimableStr) safely reclaimable). Confirm selections directly in the card."
        case .headless:
            break
        }

        var lines = [
            "Found \(items.count) worktree(s): \(safeCnt) safe, \(cautionCnt) review, \(dangerCnt) active/dirty, \(missingCnt) ghost (~\(reclaimableStr) safely reclaimable)."
        ]
        for item in items.prefix(15) {
            lines.append("- [\(item.safetyLevel.key)] \(item.mainRepoName) · \(item.displayBranch(language: .en)) (\(item.formattedSize)) — \(item.path)")
        }
        if items.count > 15 {
            lines.append("...and \(items.count - 15) more.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 加载单文件 MCP App HTML

    private func loadAppHTML() -> Result<String, Error> {
        let fm = FileManager.default
        var candidates: [String] = []

        if let customHTMLPath, !customHTMLPath.isEmpty {
            candidates.append(customHTMLPath)
        }
        if let envPath = ProcessInfo.processInfo.environment["WORKTREE_CLEANER_APP_HTML"],
           !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(envPath.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if !executablePath.isEmpty {
            let binURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
            let binDir = binURL.deletingLastPathComponent()
            candidates.append(binDir.deletingLastPathComponent().appendingPathComponent("dist/worktree-cleaner-app.html").path)
            candidates.append(binDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("mcp-app/dist/worktree-cleaner-app.html").path)
        }

        for path in candidates where fm.fileExists(atPath: path) {
            do {
                let text = try String(contentsOfFile: path, encoding: .utf8)
                if !text.isEmpty {
                    return .success(text)
                }
            } catch {
                return .failure(error)
            }
        }

        return .failure(WorktreeScanner.CleanerError(
            message: "Bundled MCP App HTML not found. Checked: \(candidates.joined(separator: ", "))"
        ))
    }

    private func errorResult(_ message: String) -> [String: Any] {
        [
            "content": [["type": "text", "text": "Error: \(message)"]],
            "structuredContent": ["error": message],
            "isError": true
        ]
    }

    private func serialize(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }
}

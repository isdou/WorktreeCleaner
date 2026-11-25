import Foundation
import Testing
@testable import WorktreeCleanerCore

@Suite("WorktreeCleaner Core Tests")
struct WorktreeCleanerTests {

    @Test("Claude project directory name encoding")
    func testClaudeProjectEncoding() {
        let input = "/Users/alex/.codex/worktrees/ios-1.2-release"
        let encoded = AgentSessionStore.encodeClaudeProjectName(input)
        #expect(encoded == "-Users-alex--codex-worktrees-ios-1-2-release")
    }

    @Test("Claude JSONL title prefers custom-title and sanitizes fallback user prompt")
    func testClaudeJSONLExtraction() {
        let linesWithTitle = [
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>  Fix worktree\ncleanup bug  "}}"#,
            #"{"type":"custom-title","customTitle":"重构 Worktree 清理流程"}"#
        ]
        #expect(AgentSessionStore.extractClaudeTitle(fromJSONLLines: linesWithTitle) == "重构 Worktree 清理流程")

        let linesFallbackUser = [
            #"{"type":"file-history-snapshot","snapshot":{}}"#,
            #"{"type":"user","message":{"role":"user","content":"<local-command-caveat>ignored</local-command-caveat>   Add dark mode inner rim to FloatingCard  "}}"#
        ]
        #expect(AgentSessionStore.extractClaudeTitle(fromJSONLLines: linesFallbackUser) == "Add dark mode inner rim to FloatingCard")
    }

    @Test("Precious ignored file detection catches secrets and excludes templates/caches")
    func testPreciousIgnoredFiles() {
        let statusOutput = """
         M README.md
        !! .env
        !! .env.local
        !! .env.example
        !! .env.template
        !! config/secrets.json
        !! certs/dev.pem
        !! data/local.sqlite3
        !! node_modules/.env
        !! dist/app.sqlite
        """

        let parsed = WorktreeScanner.parsePreciousIgnoredFiles(fromGitStatus: statusOutput)
        #expect(parsed.contains(".env"))
        #expect(parsed.contains(".env.local"))
        #expect(parsed.contains("config/secrets.json"))
        #expect(parsed.contains("certs/dev.pem"))
        #expect(parsed.contains("data/local.sqlite3"))

        #expect(!parsed.contains(".env.example"))
        #expect(!parsed.contains(".env.template"))
        #expect(!parsed.contains("node_modules/.env"))
        #expect(!parsed.contains("dist/app.sqlite"))
    }

    @Test("git cherry squash merge output parsing")
    func testSquashMergeParsing() {
        let merged = """
        - 1234abcd feat: add feature A
        - 5678ef01 fix: polish UI
        """
        #expect(WorktreeScanner.isSquashMergedOutput(merged) == true)

        let unmerged = """
        - 1234abcd feat: add feature A
        + 9999aaaa wip: unmerged work
        """
        #expect(WorktreeScanner.isSquashMergedOutput(unmerged) == false)
        #expect(WorktreeScanner.isSquashMergedOutput("") == false)
    }

    @Test("lsof cwd output parsing excludes self PID")
    func testLsofParsing() {
        let sample = """
        p101
        cnode
        fcwd
        n/Users/alex/Projects/demo-wt
        p202
        cWorktreeCleaner
        fcwd
        n/Users/alex/Projects/demo-wt
        """

        let entries = WorktreeScanner.parseLsofCwdOutput(sample, excludingPID: 202)
        #expect(entries.count == 1)
        #expect(entries.first?.pid == 101)
        #expect(entries.first?.command == "node")
        #expect(entries.first?.cwd == "/Users/alex/Projects/demo-wt")
    }

    @Test("Safety level and freshness guard classification")
    func testSafetyLevelAndFreshnessGuard() {
        let now = Date()
        let oldDate = now.addingTimeInterval(-48 * 3600)
        let recentDate = now.addingTimeInterval(-2 * 3600)

        let safeOld = makeSampleItem(lastModified: oldDate, isMerged: true)
        #expect(safeOld.safetyLevel == .safe)
        #expect(safeOld.isWithinFreshnessWindow(hours: 24, now: now) == false)
        #expect(safeOld.isAutoSelectableSafe(freshnessHours: 24, now: now) == true)

        let safeRecent = makeSampleItem(lastModified: recentDate, isMerged: true)
        #expect(safeRecent.safetyLevel == .safe)
        #expect(safeRecent.isWithinFreshnessWindow(hours: 24, now: now) == true)
        #expect(safeRecent.isAutoSelectableSafe(freshnessHours: 24, now: now) == false)

        let activeProc = makeSampleItem(lastModified: oldDate, isMerged: true, activeProcesses: ["claude (421)"])
        #expect(activeProc.safetyLevel == .danger)

        let withPrecious = makeSampleItem(lastModified: oldDate, isMerged: true, preciousIgnoredFiles: [".env.local"])
        #expect(withPrecious.safetyLevel == .caution)

        let squashMerged = makeSampleItem(lastModified: oldDate, isMerged: false, isSquashMerged: true)
        #expect(squashMerged.safetyLevel == .safe)

        let prMerged = makeSampleItem(
            lastModified: oldDate,
            isMerged: false,
            prInfo: PullRequestInfo(number: 88, state: "MERGED", url: "https://github.com/example/repo/pull/88")
        )
        #expect(prMerged.safetyLevel == .safe)

        let orphan = makeSampleItem(kind: .directoryOrphan, lastModified: oldDate)
        #expect(orphan.safetyLevel == .caution)
        #expect(orphan.isOrphan == true)
    }

    @Test("TCC protected root matching and denied-path skipping")
    func testTCCProtectedRootMatching() {
        let protected = [
            "/Users/alex/Desktop",
            "/Users/alex/Downloads",
            "/Users/alex/Documents"
        ]
        let candidatePaths = [
            "/Users/alex/Projects/demo",
            "/Users/alex/Desktop/Gemini/WorktreeCleaner",
            "/Users/alex/Downloads/AI-Hub",
            "/Users/alex/DesktopTools/other"
        ]

        let matched = WorktreeScanner.matchingProtectedRoots(for: candidatePaths, protectedRoots: protected)
        #expect(matched == ["/Users/alex/Desktop", "/Users/alex/Downloads"])

        let denied: Set<String> = ["/Users/alex/Desktop"]
        #expect(WorktreeScanner.isPath("/Users/alex/Desktop", underAnyOf: denied) == true)
        #expect(WorktreeScanner.isPath("/Users/alex/Desktop/repo", underAnyOf: denied) == true)
        #expect(WorktreeScanner.isPath("/Users/alex/DesktopTools/repo", underAnyOf: denied) == false)
        #expect(WorktreeScanner.isPath("/Users/alex/Projects/repo", underAnyOf: denied) == false)
    }

    @Test("MCP App server advertises SEP-1865 tools, entrypoints, and UI HTML resource")
    func testMCPProtocolHandshakeAndMetadata() async throws {
        let tmpHTML = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wtc-mcp-test-\(UUID().uuidString).html")
        try "<!DOCTYPE html><html><body>Worktree Cleaner Test</body></html>".write(to: tmpHTML, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpHTML) }

        let handler = MCPServerHandler(customHTMLPath: tmpHTML.path)

        // 1. initialize
        let initReply = try #require(await handler.handleJSONLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#))
        let initObj = try #require(try JSONSerialization.jsonObject(with: Data(initReply.utf8)) as? [String: Any])
        let initResult = try #require(initObj["result"] as? [String: Any])
        let caps = try #require(initResult["capabilities"] as? [String: Any])
        #expect(caps["tools"] != nil)
        #expect(caps["resources"] != nil)

        // 2. tools/list
        let toolsReply = try #require(await handler.handleJSONLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let toolsObj = try #require(try JSONSerialization.jsonObject(with: Data(toolsReply.utf8)) as? [String: Any])
        let toolsResult = try #require(toolsObj["result"] as? [String: Any])
        let tools = try #require(toolsResult["tools"] as? [[String: Any]])

        let openTool = try #require(tools.first { ($0["name"] as? String) == "open_worktree_cleaner" })
        let openMeta = try #require(openTool["_meta"] as? [String: Any])
        let uiMeta = try #require(openMeta["ui"] as? [String: Any])
        #expect((uiMeta["resourceUri"] as? String) == MCPServerHandler.appURI)
        let agyMeta = try #require(openMeta["com.google.antigravity/ui"] as? [String: Any])
        let entrypoints = try #require(agyMeta["entrypoints"] as? [[String: Any]])
        #expect(entrypoints.count == 2)

        let finderTool = try #require(tools.first { ($0["name"] as? String) == "open_in_finder" })
        let finderUI = try #require((finderTool["_meta"] as? [String: Any])?["ui"] as? [String: Any])
        #expect((finderUI["visibility"] as? [String]) == ["app"])

        // 3. resources/read
        let readReply = try #require(await handler.handleJSONLine(#"{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"ui://worktree-cleaner/app.html"}}"#))
        let readObj = try #require(try JSONSerialization.jsonObject(with: Data(readReply.utf8)) as? [String: Any])
        let readResult = try #require(readObj["result"] as? [String: Any])
        let contents = try #require(readResult["contents"] as? [[String: Any]])
        #expect((contents.first?["mimeType"] as? String) == "text/html;profile=mcp-app")
        #expect((contents.first?["text"] as? String)?.contains("Worktree Cleaner Test") == true)
    }

    // MARK: - Helpers

    private func makeSampleItem(
        kind: WorktreeKind = .linkedWorktree,
        lastModified: Date?,
        isMerged: Bool = false,
        isSquashMerged: Bool = false,
        prInfo: PullRequestInfo? = nil,
        activeProcesses: [String] = [],
        preciousIgnoredFiles: [String] = []
    ) -> WorktreeItem {
        WorktreeItem(
            id: "/tmp/wt-sample",
            path: "/tmp/wt-sample",
            kind: kind,
            mainRepoPath: "/tmp/main-repo",
            mainRepoName: "main-repo",
            branch: "feat/demo",
            headCommit: "abcdef123456",
            headSubject: "demo",
            lastModified: lastModified,
            isDetached: false,
            isLocked: false,
            directoryExists: kind != .prunableMetadata,
            source: .codex,
            remoteName: "origin",
            modifiedCount: 0,
            untrackedCount: 0,
            aheadCount: 0,
            hasUpstream: false,
            isMergedToDefault: isMerged,
            isSquashMerged: isSquashMerged,
            prInfo: prInfo,
            changedFiles: [],
            unpushedCommits: [],
            activeProcesses: activeProcesses,
            preciousIgnoredFiles: preciousIgnoredFiles,
            orphanFileCount: kind == .directoryOrphan ? 2 : 0,
            featureSummary: nil,
            diskSizeBytes: 1024
        )
    }
}

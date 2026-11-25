import Foundation
import SQLite3

/// 只读提取 AI Coding Agent（Codex 与 Claude Code）的会话任务标题，用于唤醒用户的记忆
enum AgentSessionStore {

    // MARK: - 1. Codex (SQLite 只读索引)

    static func loadCodexThreadTitles(dbPath: String? = nil) -> [String: [String]] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let targetPath = dbPath ?? "\(home)/.codex/state_5.sqlite"
        guard FileManager.default.fileExists(atPath: targetPath) else { return [:] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(targetPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return [:]
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT cwd, title FROM threads WHERE cwd IS NOT NULL AND title IS NOT NULL ORDER BY updated_at DESC LIMIT 1500;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var map: [String: [String]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cwdCStr = sqlite3_column_text(stmt, 0),
                  let titleCStr = sqlite3_column_text(stmt, 1) else { continue }
            let cwd = canonicalPath(String(cString: cwdCStr))
            let rawTitle = normalizeSnippet(String(cString: titleCStr), maxLength: 140)
            guard !cwd.isEmpty, !rawTitle.isEmpty else { continue }

            var existing = map[cwd] ?? []
            if existing.count < 3 && !existing.contains(rawTitle) {
                existing.append(rawTitle)
                map[cwd] = existing
            }
        }
        return map
    }

    // MARK: - 2. Claude Code (~/.claude/projects/*.jsonl)

    /// 将物理路径编码为 Claude Code projects 目录名（非字母数字字符一律替换为 '-'）
    static func encodeClaudeProjectName(_ path: String) -> String {
        path.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
    }

    static func loadClaudeSessionTitles(
        for paths: [String],
        projectsRoot: String? = nil
    ) -> [String: [String]] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let root = projectsRoot ?? "\(home)/.claude/projects"
        guard fm.fileExists(atPath: root) else { return [:] }

        var result: [String: [String]] = [:]

        for rawPath in paths {
            let normPath = canonicalPath(rawPath)
            let parentPath = URL(fileURLWithPath: normPath).deletingLastPathComponent().path
            var candidateEncodedNames = [encodeClaudeProjectName(normPath)]
            if rawPath.contains("/.codex/worktrees/") || rawPath.contains("/.claude/worktrees/") {
                candidateEncodedNames.append(encodeClaudeProjectName(parentPath))
            }

            var titles: [String] = []
            for dirName in candidateEncodedNames {
                let projectDir = (root as NSString).appendingPathComponent(dirName)
                guard fm.fileExists(atPath: projectDir),
                      let entries = try? fm.contentsOfDirectory(atPath: projectDir) else { continue }

                // 按文件修改时间降序取最新的 5 个 jsonl 文件
                let jsonlFiles: [(path: String, date: Date)] = entries
                    .filter { $0.hasSuffix(".jsonl") }
                    .compactMap { file in
                        let full = (projectDir as NSString).appendingPathComponent(file)
                        let attrs = try? fm.attributesOfItem(atPath: full)
                        let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
                        return (full, date)
                    }
                    .sorted { $0.date > $1.date }
                    .prefix(5)
                    .map { $0 }

                for fileInfo in jsonlFiles {
                    guard let content = try? String(contentsOfFile: fileInfo.path, encoding: .utf8) else { continue }
                    let lines = content.components(separatedBy: .newlines).prefix(60)
                    if let extracted = extractClaudeTitle(fromJSONLLines: Array(lines)),
                       !titles.contains(extracted) {
                        titles.append(extracted)
                        if titles.count >= 3 { break }
                    }
                }
                if titles.count >= 3 { break }
            }

            if !titles.isEmpty {
                result[normPath] = titles
            }
        }
        return result
    }

    /// 从 Claude JSONL 文件前若干行中提取最有代表性的任务标题或首条用户指令
    static func extractClaudeTitle(fromJSONLLines lines: [String]) -> String? {
        var fallbackUserPrompt: String?

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            // 1. 优先提取显式会话标题或摘要
            if type == "custom-title", let title = obj["customTitle"] as? String {
                let cleaned = normalizeSnippet(title, maxLength: 140)
                if !cleaned.isEmpty { return cleaned }
            }
            if type == "summary", let summary = obj["summary"] as? String {
                let cleaned = normalizeSnippet(summary, maxLength: 140)
                if !cleaned.isEmpty { return cleaned }
            }

            // 2. 记录首条有效 user 文本作为回退
            if fallbackUserPrompt == nil, type == "user",
               let message = obj["message"] as? [String: Any],
               let content = message["content"] as? String {
                let cleaned = sanitizeUserPrompt(content)
                if !cleaned.isEmpty {
                    fallbackUserPrompt = cleaned
                }
            }
        }

        return fallbackUserPrompt
    }

    /// 过滤系统命令标签并压缩空白字符
    static func sanitizeUserPrompt(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "<local-command-[^>]*>[\\s\\S]*?</local-command-[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<command-name>[\\s\\S]*?</command-name>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<command-message>[\\s\\S]*?</command-message>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<command-args>[\\s\\S]*?</command-args>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<system-reminder>[\\s\\S]*?</system-reminder>", with: " ", options: .regularExpression)
        return normalizeSnippet(stripped, maxLength: 120)
    }

    private static func normalizeSnippet(_ text: String, maxLength: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "" }
        if collapsed.count <= maxLength { return collapsed }
        return String(collapsed.prefix(maxLength)) + "…"
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

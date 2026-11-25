import Foundation
import WorktreeCleanerCore

/// WorktreeCleanerMCP：原生 Swift stdio MCP App 服务端（SEP-1865）
@main
struct WorktreeCleanerMCPApp {
    static func main() async {
        let handler = MCPServerHandler(executablePath: CommandLine.arguments.first ?? "")

        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            if let reply = await handler.handleJSONLine(line) {
                if let data = (reply + "\n").data(using: .utf8) {
                    FileHandle.standardOutput.write(data)
                }
            }
        }
    }
}

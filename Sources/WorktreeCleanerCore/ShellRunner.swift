import Foundation

/// 轻量异步命令行执行器：带并发读取与超时保护，绝不阻塞主线程或因 pipe 写满挂起
public enum ShellRunner {
    public struct Output: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        public var succeeded: Bool { exitCode == 0 }

        public init(exitCode: Int32, stdout: String, stderr: String) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public static func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        timeout: TimeInterval = 15
    ) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let dir = currentDirectory, FileManager.default.fileExists(atPath: dir) {
                    process.currentDirectoryURL = URL(fileURLWithPath: dir)
                } else {
                    process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
                }

                // 避免 git 触发交互式凭证弹窗，保持英文输出便于统一解析
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["LC_ALL"] = "C"
                let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
                if !existingPath.contains("/opt/homebrew/bin") {
                    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
                }
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(exitCode: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }

                nonisolated(unsafe) var outData = Data()
                nonisolated(unsafe) var errData = Data()
                let ioGroup = DispatchGroup()

                ioGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    ioGroup.leave()
                }

                ioGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    ioGroup.leave()
                }

                let waitGroup = DispatchGroup()
                waitGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    waitGroup.leave()
                }

                if waitGroup.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    _ = ioGroup.wait(timeout: .now() + 1)
                    continuation.resume(returning: Output(exitCode: -2, stdout: "", stderr: "Command timed out"))
                    return
                }

                _ = ioGroup.wait(timeout: .now() + 2)
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""

                continuation.resume(returning: Output(
                    exitCode: process.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                ))
            }
        }
    }

    public static func git(_ arguments: [String], in directory: String, timeout: TimeInterval = 12) async -> Output {
        await run("/usr/bin/git", arguments: ["-C", directory] + arguments, timeout: timeout)
    }

    public static func findExecutable(candidates: [String]) -> String? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    public static func directorySizeBytes(_ path: String) async -> Int64? {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let res = await run("/usr/bin/du", arguments: ["-sk", path], timeout: 20)
        guard res.succeeded else { return nil }
        let firstToken = res.stdout.split(whereSeparator: { $0.isWhitespace }).first
        if let token = firstToken, let kb = Int64(token) {
            return kb * 1024
        }
        return nil
    }
}

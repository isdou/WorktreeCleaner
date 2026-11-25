import Foundation
import AppKit
import ServiceManagement

/// 本机已安装的外部编辑器或终端应用
public struct ExternalApp: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let appURL: URL
    public let isTerminal: Bool

    public init(id: String, name: String, appURL: URL, isTerminal: Bool) {
        self.id = id
        self.name = name
        self.appURL = appURL
        self.isTerminal = isTerminal
    }
}

/// 自动探测本机已安装的编辑器与终端，提供一键打开能力
public enum ExternalToolDetector {
    private static let editorCandidates: [(name: String, bundles: [String])] = [
        ("Cursor", ["Cursor.app"]),
        ("VS Code", ["Visual Studio Code.app", "Visual Studio Code - Insiders.app"]),
        ("Zed", ["Zed.app"]),
        ("Antigravity", ["Antigravity - Insiders.app", "Antigravity.app"]),
        ("Windsurf", ["Windsurf.app"]),
        ("Xcode", ["Xcode.app"]),
        ("Fork", ["Fork.app"])
    ]

    private static let terminalCandidates: [(name: String, bundles: [String])] = [
        ("Ghostty", ["Ghostty.app"]),
        ("Warp", ["Warp.app"]),
        ("iTerm", ["iTerm.app"]),
        ("Terminal", ["Terminal.app"])
    ]

    public static func detectInstalledApps() -> [ExternalApp] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let searchDirs = [
            "/Applications",
            "\(home)/Applications",
            "/System/Applications/Utilities"
        ]

        var results: [ExternalApp] = []

        func findApp(bundles: [String]) -> URL? {
            for dir in searchDirs {
                for bundle in bundles {
                    let full = (dir as NSString).appendingPathComponent(bundle)
                    if fm.fileExists(atPath: full) {
                        return URL(fileURLWithPath: full)
                    }
                }
            }
            return nil
        }

        for candidate in editorCandidates {
            if let url = findApp(bundles: candidate.bundles) {
                results.append(ExternalApp(id: url.path, name: candidate.name, appURL: url, isTerminal: false))
            }
        }

        for candidate in terminalCandidates {
            if let url = findApp(bundles: candidate.bundles) {
                results.append(ExternalApp(id: url.path, name: candidate.name, appURL: url, isTerminal: true))
            }
        }

        return results
    }

    @MainActor
    public static func open(directory path: String, with app: ExternalApp) {
        let dirURL = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([dirURL], withApplicationAt: app.appURL, configuration: config)
    }
}

/// 开机自启管理器（基于 SMAppService.mainApp，带未签名开发构建容错）
public enum LaunchAtLoginManager {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

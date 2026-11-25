import Foundation

/// 应用语言偏好（支持跟随系统 / 简体中文 / English 实时切换）
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case zhHans
    case en

    public var id: String { rawValue }

    public var isChinese: Bool {
        switch self {
        case .zhHans: return true
        case .en: return false
        case .system:
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        }
    }

    public func optionTitle(in currentLanguage: AppLanguage) -> String {
        switch self {
        case .system: return L10n.tr("跟随系统", "System", language: currentLanguage)
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

/// 轻量双语文本工具
public enum L10n {
    public static func tr(_ zh: String, _ en: String, language: AppLanguage) -> String {
        language.isChinese ? zh : en
    }

    public static func tr(_ zh: String, _ en: String, isChinese: Bool) -> String {
        isChinese ? zh : en
    }
}

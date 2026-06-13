import Foundation

/// Target languages for live translation. A curated subset of the 70+ codes the
/// Gemini Live Translate model accepts; `code` is the BCP-47 value sent in
/// `translationConfig.targetLanguageCode`. Source language is auto-detected, so
/// only the target is user-selectable.
enum TargetLanguage: String, CaseIterable, Codable, Identifiable, Hashable {
    case ukrainian = "uk"
    case english   = "en"
    case german    = "de"
    case spanish   = "es"
    case french    = "fr"
    case italian   = "it"
    case polish     = "pl"
    case portuguese = "pt-BR"
    case dutch     = "nl"
    case turkish   = "tr"
    case arabic    = "ar"
    case hindi     = "hi"
    case japanese  = "ja"
    case korean    = "ko"
    case chinese   = "zh-Hans"

    var id: String { rawValue }
    var code: String { rawValue }

    var displayName: String {
        switch self {
        case .ukrainian:  return "Українська"
        case .english:    return "English"
        case .german:     return "Deutsch"
        case .spanish:    return "Español"
        case .french:     return "Français"
        case .italian:    return "Italiano"
        case .polish:     return "Polski"
        case .portuguese: return "Português"
        case .dutch:      return "Nederlands"
        case .turkish:    return "Türkçe"
        case .arabic:     return "العربية"
        case .hindi:      return "हिन्दी"
        case .japanese:   return "日本語"
        case .korean:     return "한국어"
        case .chinese:    return "中文"
        }
    }

    var flag: String {
        switch self {
        case .ukrainian:  return "🇺🇦"
        case .english:    return "🇬🇧"
        case .german:     return "🇩🇪"
        case .spanish:    return "🇪🇸"
        case .french:     return "🇫🇷"
        case .italian:    return "🇮🇹"
        case .polish:     return "🇵🇱"
        case .portuguese: return "🇧🇷"
        case .dutch:      return "🇳🇱"
        case .turkish:    return "🇹🇷"
        case .arabic:     return "🇸🇦"
        case .hindi:      return "🇮🇳"
        case .japanese:   return "🇯🇵"
        case .korean:     return "🇰🇷"
        case .chinese:    return "🇨🇳"
        }
    }
}

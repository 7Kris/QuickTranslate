import Foundation
import Translation

enum AppleTranslatorError: LocalizedError {
    case unsupported
    case notInstalled(source: String, target: String)
    case translationFailed(underlying: Error)

    var isSetupError: Bool {
        switch self {
        case .unsupported, .notInstalled:
            return true
        case .translationFailed:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "This language pair is not supported by Apple Translation."
        case .notInstalled(let source, let target):
            return """
            Translation languages are not installed (\(source) -> \(target)).

            Please download them:
            System Settings > General > Language & Region > Translation Languages
            """
        case .translationFailed(let underlying):
            return """
            Translation failed: \(underlying.localizedDescription)

            Please check that translation languages are downloaded:
            System Settings > General > Language & Region > Translation Languages
            """
        }
    }
}

enum TranslationLanguage: String, CaseIterable, Identifiable {
    case japanese = "ja"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .japanese: return "日本語"
        case .english: return "English"
        }
    }

    var locale: Locale.Language {
        Locale.Language(identifier: rawValue)
    }

    static func detect(from text: String) -> TranslationLanguage {
        let japaneseCharSet = CharacterSet(charactersIn: "\u{3040}"..."\u{309F}")
            .union(CharacterSet(charactersIn: "\u{30A0}"..."\u{30FF}"))
            .union(CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}"))
        return text.rangeOfCharacter(from: japaneseCharSet) != nil ? .japanese : .english
    }
}

struct TranslationResult {
    let text: String
    let sourceLanguage: TranslationLanguage
    let targetLanguage: TranslationLanguage
}

@available(macOS 26.0, *)
struct AppleTranslator {
    func translate(text: String, source: TranslationLanguage? = nil, target: TranslationLanguage? = nil) async throws -> TranslationResult {
        let detectedSource = source ?? TranslationLanguage.detect(from: text)
        let resolvedTarget = target ?? (detectedSource == .japanese ? .english : .japanese)

        let availability = LanguageAvailability()
        let status = await availability.status(from: detectedSource.locale, to: resolvedTarget.locale)

        switch status {
        case .unsupported:
            throw AppleTranslatorError.unsupported
        case .supported:
            throw AppleTranslatorError.notInstalled(
                source: detectedSource.displayName,
                target: resolvedTarget.displayName
            )
        case .installed:
            break
        @unknown default:
            break
        }

        do {
            let session = TranslationSession(installedSource: detectedSource.locale, target: resolvedTarget.locale)
            try await session.prepareTranslation()
            let response = try await session.translate(text)
            return TranslationResult(text: response.targetText, sourceLanguage: detectedSource, targetLanguage: resolvedTarget)
        } catch {
            throw AppleTranslatorError.translationFailed(underlying: error)
        }
    }
}

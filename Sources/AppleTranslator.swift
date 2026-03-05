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

@available(macOS 26.0, *)
struct AppleTranslator {
    func translate(text: String) async throws -> String {
        let japaneseLocale = Locale.Language(identifier: "ja")
        let englishLocale = Locale.Language(identifier: "en")

        // Detect if the input text is Japanese by checking for CJK characters
        let japaneseCharSet = CharacterSet(charactersIn: "\u{3040}"..."\u{309F}")
            .union(CharacterSet(charactersIn: "\u{30A0}"..."\u{30FF}"))
            .union(CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}"))
        let isJapanese = text.rangeOfCharacter(from: japaneseCharSet) != nil

        let source = isJapanese ? japaneseLocale : englishLocale
        let target = isJapanese ? englishLocale : japaneseLocale

        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)

        switch status {
        case .unsupported:
            throw AppleTranslatorError.unsupported
        case .supported:
            throw AppleTranslatorError.notInstalled(
                source: isJapanese ? "Japanese" : "English",
                target: isJapanese ? "English" : "Japanese"
            )
        case .installed:
            break
        @unknown default:
            break
        }

        do {
            let session = TranslationSession(installedSource: source, target: target)
            try await session.prepareTranslation()
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            throw AppleTranslatorError.translationFailed(underlying: error)
        }
    }
}

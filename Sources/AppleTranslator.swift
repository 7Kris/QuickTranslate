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
        // 日本語文字数 (ひらがな・カタカナ・漢字)
        var japaneseCount = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x4E00...0x9FFF:
                japaneseCount += 1
            default:
                break
            }
        }
        guard japaneseCount > 0 else { return .english }

        // 日本語文字が混ざっていても、日付や固有名詞程度で英文が主体なら英語と判定する。
        // 単純な文字数比較だと長い英識別子を含む日本語文 (例:「TranslationSessionを呼ぶ」)
        // が英語に誤判定されるため、日本語文字数と「英単語の数」を比較する
        let englishWordCount = text.split(whereSeparator: { !($0.isASCII && $0.isLetter) }).count
        return japaneseCount >= englishWordCount ? .japanese : .english
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

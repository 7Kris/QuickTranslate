import Foundation

struct ClaudeTranslator {
    private let claudePath = "/Users/kenmaz/.local/bin/claude"

    func translate(text: String) async throws -> String {
        let systemPrompt = """
        You are a translator. Detect the language of the input text and translate it:
        - If the input is in English, translate it to Japanese.
        - If the input is in Japanese, translate it to English.
        - For other languages, translate to English.

        Output ONLY the translated text. Do not include any explanations, notes, or extra text.
        """

        let prompt = "\(systemPrompt)\n\nTranslate the following text:\n\(text)"

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = ["-p", prompt]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: TranslationError.processLaunchFailed(error.localizedDescription))
                return
            }

            process.waitUntilExit()

            let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            guard process.terminationStatus == 0 else {
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                continuation.resume(throwing: TranslationError.processError(exitCode: Int(process.terminationStatus), message: errorMessage))
                return
            }

            guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else {
                continuation.resume(throwing: TranslationError.noContent)
                return
            }

            continuation.resume(returning: output)
        }
    }
}

enum TranslationError: LocalizedError {
    case processLaunchFailed(String)
    case processError(exitCode: Int, message: String)
    case noContent

    var errorDescription: String? {
        switch self {
        case .processLaunchFailed(let message):
            return "claudeコマンドの起動に失敗しました: \(message)"
        case .processError(let exitCode, let message):
            return "claudeコマンドエラー (終了コード: \(exitCode)): \(message)"
        case .noContent:
            return "翻訳結果が空です"
        }
    }
}

import Foundation

struct ClaudeTranslator {
    private var claudePath: String {
        get throws {
            print("🔍 [DEBUG] claudeコマンドのパスを探しています...")
            
            // まず一般的な場所を直接チェック
            let commonPaths = [
                "/opt/homebrew/bin/claude",      // Apple Silicon Mac (M1/M2/M3)
                "/usr/local/bin/claude",          // Intel Mac
                NSHomeDirectory() + "/.local/bin/claude",  // ユーザーローカル
            ]
            
            for path in commonPaths {
                if FileManager.default.isExecutableFile(atPath: path) {
                    print("✅ [DEBUG] claudeコマンドが見つかりました: \(path)")
                    return path
                }
            }
            
            print("🔍 [DEBUG] 一般的な場所に見つからなかったので、whichコマンドを試します...")
            
            // PATHを拡張してwhichコマンドを実行
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = ["claude"]
            
            // PATH環境変数を拡張
            var environment = ProcessInfo.processInfo.environment
            let originalPath = environment["PATH"] ?? ""
            let additionalPaths = [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                NSHomeDirectory() + "/.local/bin",
            ]
            let expandedPath = (additionalPaths + [originalPath]).joined(separator: ":")
            environment["PATH"] = expandedPath
            process.environment = environment
            
            let pipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errorPipe
            
            print("🔍 [DEBUG] 拡張PATH: \(expandedPath)")
            print("🔍 [DEBUG] /usr/bin/which claude を実行中...")
            try process.run()
            process.waitUntilExit()
            
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            print("🔍 [DEBUG] 終了ステータス: \(process.terminationStatus)")
            print("🔍 [DEBUG] 標準出力: '\(output)'")
            print("🔍 [DEBUG] エラー出力: '\(errorOutput)'")
            
            if process.terminationStatus == 0, !output.isEmpty {
                print("✅ [DEBUG] claudeコマンドが見つかりました: \(output)")
                return output
            }
            
            // PATH環境変数を確認
            print("⚠️ [DEBUG] claudeコマンドが見つかりませんでした")
            print("🔍 [DEBUG] 元のPATH: \(originalPath)")
            print("💡 [DEBUG] ヒント: ターミナルで 'which claude' を実行して、claudeのパスを確認してください")
            
            throw TranslationError.processLaunchFailed("The file \"claude\" doesn't exist.")
        }
    }

    func translate(text: String) async throws -> String {
        print("📝 [DEBUG] 翻訳開始 - テキスト長: \(text.count)文字")
        
        let systemPrompt = """
        You are a translator. Detect the language of the input text and translate it:
        - If the input is in English, translate it to Japanese.
        - If the input is in Japanese, translate it to English.
        - For other languages, translate to English.

        Output ONLY the translated text. Do not include any explanations, notes, or extra text.
        """

        let prompt = "\(systemPrompt)\n\nTranslate the following text:\n\(text)"

        print("🔍 [DEBUG] claudePathを取得中...")
        let resolvedPath = try claudePath
        print("✅ [DEBUG] claudePath取得完了: \(resolvedPath)")
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: resolvedPath)
            process.arguments = ["-p", prompt, "--model", "haiku", "--max-turns", "1"]

            // PATH環境変数を拡張（nodeなどの依存コマンドを見つけるため）
            var environment = ProcessInfo.processInfo.environment
            let originalPath = environment["PATH"] ?? ""
            
            // 追加のパス候補
            var additionalPaths = [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                NSHomeDirectory() + "/.local/bin",
                "/usr/local/opt/node/bin",
            ]
            
            // nvmのNode.jsパスを探す
            let nvmDir = NSHomeDirectory() + "/.nvm/versions/node"
            if let nodeVersions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
                for version in nodeVersions {
                    additionalPaths.append("\(nvmDir)/\(version)/bin")
                }
            }
            
            let expandedPath = (additionalPaths + [originalPath]).joined(separator: ":")
            environment["PATH"] = expandedPath
            process.environment = environment
            
            print("🔍 [DEBUG] claude実行時のPATH: \(expandedPath)")

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
            
            let stdout = String(data: outputData, encoding: .utf8) ?? ""
            let stderr = String(data: errorData, encoding: .utf8) ?? ""
            
            print("🔍 [DEBUG] claude終了ステータス: \(process.terminationStatus)")
            print("🔍 [DEBUG] claude標準出力: \(stdout.prefix(200))")
            print("🔍 [DEBUG] claudeエラー出力: \(stderr)")

            guard process.terminationStatus == 0 else {
                let errorMessage = stderr.isEmpty ? "Unknown error" : stderr
                continuation.resume(throwing: TranslationError.processError(exitCode: Int(process.terminationStatus), message: errorMessage))
                return
            }

            let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !output.isEmpty else {
                continuation.resume(throwing: TranslationError.noContent)
                return
            }

            print("✅ [DEBUG] 翻訳成功 - 結果の長さ: \(output.count)文字")
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

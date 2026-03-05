import SwiftUI

@main
struct QuickTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyManager: HotKeyManager!
    private var translationWindowController: TranslationWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dockアイコンを非表示
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()
        setupHotKey()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "translate", accessibilityDescription: "QuickTranslate")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "翻訳ウインドウを開く", action: #selector(openTranslationWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "クリップボードから翻訳 (⌘D×2)", action: #selector(translateFromClipboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func setupHotKey() {
        hotKeyManager = HotKeyManager()
        hotKeyManager.register { [weak self] in
            self?.translateFromClipboard()
        }
    }

    @objc private func openTranslationWindow() {
        showTranslationWindow(original: "", result: "", isError: false)
    }

    @objc private func translateFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            showTranslationWindow(original: "", result: "クリップボードにテキストがありません", isError: true)
            return
        }

        showTranslationWindow(original: text, result: nil, isError: false)
        translateText(text)
    }

    private func translateText(_ text: String) {
        let engine = translationWindowController?.currentEngine ?? .claude
        Task {
            do {
                let result: String
                switch engine {
                case .claude:
                    result = try await ClaudeTranslator().translate(text: text)
                case .apple:
                    if #available(macOS 26.0, *) {
                        result = try await AppleTranslator().translate(text: text)
                    } else {
                        throw NSError(domain: "QuickTranslate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple Translation requires macOS 26.0 or later. Please download translation languages in System Settings > General > Language & Region > Translation Languages."])
                    }
                }
                await MainActor.run {
                    self.translationWindowController?.updateResult(result)
                }
            } catch let error as AppleTranslatorError where error.isSetupError {
                await MainActor.run {
                    self.showLanguageSetupAlert(error: error)
                    self.translationWindowController?.updateResult("エラー: \(error.localizedDescription)")
                    self.translationWindowController?.setError(true)
                }
            } catch {
                await MainActor.run {
                    self.translationWindowController?.updateResult("エラー: \(error.localizedDescription)")
                    self.translationWindowController?.setError(true)
                }
            }
        }
    }

    private func showTranslationWindow(original: String, result: String?, isError: Bool) {
        if translationWindowController == nil {
            translationWindowController = TranslationWindowController()
            translationWindowController?.onTranslate = { [weak self] text in
                self?.translationWindowController?.updateForRetranslation(original: text)
                self?.translateText(text)
            }
            translationWindowController?.onClose = {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        translationWindowController?.show(original: original, result: result, isError: isError)
        activateApp()
    }

    private func showLanguageSetupAlert(error: AppleTranslatorError) {
        let alert = NSAlert()
        alert.messageText = "翻訳言語がインストールされていません"
        alert.informativeText = "Apple翻訳を使用するには、システム設定から翻訳言語をダウンロードしてください。\n\nシステム設定 > 一般 > 言語と地域 > 翻訳言語"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "閉じる")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func activateApp() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

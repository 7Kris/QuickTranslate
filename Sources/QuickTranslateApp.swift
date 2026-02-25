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
        menu.addItem(NSMenuItem(title: "翻訳 (⌘D×2)", action: #selector(translateFromClipboard), keyEquivalent: ""))
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

    @objc private func translateFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            showTranslationWindow(original: "", result: "クリップボードにテキストがありません", isError: true)
            return
        }

        showTranslationWindow(original: text, result: nil, isError: false)

        Task {
            do {
                let translator = ClaudeTranslator()
                let result = try await translator.translate(text: text)
                await MainActor.run {
                    self.translationWindowController?.updateResult(result)
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
        }
        translationWindowController?.show(original: original, result: result, isError: isError)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
